--!nonstrict
-- Full client<->server handshake over a loopback transport, plus the command
-- channel. Requires a running simulation (Studio Run mode / the headless
-- runner); skipped in edit mode.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- Builds a server harness plus a real Client instance wired through the
	-- same loopback transport.
	local function makeLoopback(extraOptions)
		local options = { RequestTimeout = 0.25 }
		for key, value in extraOptions or {} do
			options[key] = value
		end
		local harness = TestCtx.make({ AutoPump = true, Options = options })
		local player, entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		return harness, player, entry, serverData, clientData
	end

	itRunning("performs the Hello/Init handshake and applies diffs to the mirror", function()
		local harness, _player, entry, serverData, clientData = makeLoopback()

		-- Client.new sent Hello synchronously over the loopback; the mirror is
		-- loaded with the snapshot.
		expect(clientData.Coins.Get()).to.equal(0)

		local observed = {}
		clientData.Coins.Observe(function(value)
			table.insert(observed, value)
		end)
		expect(#observed).to.equal(1)
		expect(observed[1]).to.equal(0)

		serverData.Coins.Set(42)
		harness.Ctx.Replication.FlushEntry(entry)
		expect(clientData.Coins.Get()).to.equal(42)
		expect(observed[2]).to.equal(42)

		-- ServerOnly stays invisible on the mirror.
		expect(clientData.Raw.Secret.Flagged.Get()).to.equal(nil)

		-- Dictionary events replay on the client when the diff applies.
		local addedKeys = {}
		clientData.Inventory.OnKeyAdded(function(key)
			table.insert(addedKeys, key)
		end)
		serverData.Inventory.Sword.Set({ Dmg = 3 })
		harness.Ctx.Replication.FlushEntry(entry)
		expect(#addedKeys).to.equal(1)
		expect(addedKeys[1]).to.equal("Sword")
		expect(clientData.Inventory.Sword.Dmg.Get()).to.equal(3)

		-- Buffers replicate byte-exact.
		serverData.Inventory.Chunk.Set(buffer.fromstring("XY\0Z"))
		harness.Ctx.Replication.FlushEntry(entry)
		expect(buffer.tostring(clientData.Inventory.Chunk.Get())).to.equal("XY\0Z")

		harness.Cleanup()
	end)

	itRunning("fires Observe/Changed for snapshot values at every depth when registered before Init", function()
		-- Regression: a whole-container snapshot Set used to fire Changed only on
		-- the container, so a nested Observe/Changed registered before Init missed
		-- its value (top-level leaves were unaffected).
		local harness = TestCtx.make({ AutoPump = false })
		local player, entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player

		-- Server state set BEFORE the client handshake.
		serverData.Coins.Set(5) -- top-level leaf
		serverData.Inventory.Test.Set(7) -- dynamic dict key
		serverData.Settings.Music.Set(false) -- nested static field

		local clientData = Client.new(harness.Options, harness.Compiled) -- Hello queued

		local coins, dictVal, music = {}, {}, {}
		local invChanged, keyAdded = 0, {}
		clientData.Coins.Observe(function(v)
			table.insert(coins, v)
		end)
		clientData.Inventory.Test.Observe(function(v)
			table.insert(dictVal, if v == nil then "NIL" else v)
		end)
		clientData.Settings.Music.Observe(function(v)
			table.insert(music, v)
		end)
		clientData.Inventory.Changed(function()
			invChanged += 1
		end)
		clientData.Inventory.OnKeyAdded(function(key)
			table.insert(keyAdded, key)
		end)

		harness.Transport:PumpToServer() -- Hello -> Init(snapshot)
		harness.Transport:PumpToClient()

		-- Every observer sees its snapshot value (dict/nested were missed before).
		expect(coins[#coins]).to.equal(5)
		expect(dictVal[#dictVal]).to.equal(7)
		expect(music[#music]).to.equal(false)
		-- Container observer fires exactly once (no double-fire from the replay).
		expect(invChanged).to.equal(1)
		-- OnKeyAdded intentionally does NOT replay snapshot keys (matches the
		-- top-level behavior; avoids a flood of "added" events on join).
		expect(#keyAdded).to.equal(0)

		-- A post-Init per-key update still fires the child observer.
		serverData.Inventory.Test.Set(9)
		harness.Ctx.Replication.FlushEntry(entry)
		harness.Transport:PumpToClient()
		expect(dictVal[#dictVal]).to.equal(9)

		harness.Cleanup()
	end)

	itRunning("fires Observe/Changed for a dynamic key created purely via post-Init diffs", function()
		-- roffcat's scenario, but with the writes happening AFTER the client is
		-- synced: a dynamic dict key that does NOT exist at Init time and is later
		-- created and updated via separate diffs must fire the child observer for
		-- every value (nil -> 5 -> 10), not just the last.
		local harness, _player, entry, serverData, clientData = makeLoopback()

		local seen, changes = {}, {}
		clientData.Inventory.Test.Observe(function(v)
			table.insert(seen, if v == nil then "NIL" else v)
		end)
		clientData.Inventory.Test.Changed(function(new, old)
			table.insert(changes, `{tostring(old)}->{tostring(new)}`)
		end)

		serverData.Inventory.Test.Set(5) -- key creation, its own flush/diff
		harness.Ctx.Replication.FlushEntry(entry)
		harness.Transport:PumpToClient()
		serverData.Inventory.Test.Set(10) -- value change, a separate flush/diff
		harness.Ctx.Replication.FlushEntry(entry)
		harness.Transport:PumpToClient()

		expect(seen[1]).to.equal("NIL") -- Observe's immediate call (absent key)
		expect(seen[2]).to.equal(5)
		expect(seen[3]).to.equal(10)
		expect(changes[1]).to.equal("nil->5")
		expect(changes[2]).to.equal("5->10")

		harness.Cleanup()
	end)

	itRunning("Mock fires nested observers registered before the Mock call (edit mode)", function()
		-- Same whole-root-Set root cause as Init, on the edit-mode path.
		local harness = TestCtx.make()
		-- Reuse the module-level RunService singleton (same object) rather than
		-- redeclaring it here, which would shadow it.
		local origIsRunning = RunService.IsRunning
		RunService.IsRunning = function() -- edit mode at construction
			return false
		end
		local clientData = Client.new({}, harness.Compiled)
		RunService.IsRunning = origIsRunning

		local dictVal, music = {}, {}
		clientData.Inventory.Test.Observe(function(v) -- nested dict key, BEFORE Mock
			table.insert(dictVal, if v == nil then "NIL" else v)
		end)
		clientData.Settings.Music.Observe(function(v) -- nested static, BEFORE Mock
			table.insert(music, v)
		end)

		clientData.Mock({ Inventory = { Test = 5 }, Settings = { Music = false } })

		expect(dictVal[#dictVal]).to.equal(5) -- was missed before the fix
		expect(music[#music]).to.equal(false) -- was missed before the fix

		harness.Cleanup()
	end)

	itRunning("exposes declared Min/Max on numeric fields (client and server, even before load)", function()
		local harness, _player, _entry, serverData, clientData = makeLoopback()
		-- Server reads the declared bounds.
		expect(serverData.Coins.Min()).to.equal(0)
		expect(serverData.Coins.Max()).to.equal(1000000)
		expect(serverData.Health.Max()).to.equal(100)
		expect(serverData.Gems.Max()).to.equal(nil) -- Max unbounded
		expect(serverData.Delta.Min()).to.equal(nil) -- both unbounded
		-- Client reads the same shared schema.
		expect(clientData.Coins.Min()).to.equal(0)
		expect(clientData.Coins.Max()).to.equal(1000000)
		harness.Cleanup()

		-- Bounds are static metadata, so they resolve before Init even lands.
		local harness2 = TestCtx.make({ AutoPump = false })
		local player2 = harness2.Join()
		harness2.Transport.LocalPlayer = player2
		local unloaded = Client.new(harness2.Options, harness2.Compiled)
		expect(unloaded.IsReady()).to.equal(false)
		expect(unloaded.Coins.Min()).to.equal(0)
		harness2.Cleanup()
	end)

	itRunning("exposes the declared Default of a field (client and server, incl. datatypes)", function()
		local Scribe = require(ScribeRoot) :: any
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Nick = Scribe.String("Guest", { MaxLength = 16 }),
				Team = Scribe.Enum("Red", { "Red", "Blue" }),
				Settings = { Music = true, Sfx = false },
				Home = Scribe.Vector3(Vector3.new(1, 2, 3)), -- packed datatype
			},
		})
		local player, _entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled) -- unloaded is fine

		expect(serverData.Coins.Default()).to.equal(0)
		expect(serverData.Nick.Default()).to.equal("Guest")
		expect(serverData.Team.Default()).to.equal("Red")
		-- Real datatype (not the packed buffer); compared by component since the
		-- headless Vector3 stub has no value equality.
		local home = serverData.Home.Default()
		expect(home.X).to.equal(1)
		expect(home.Y).to.equal(2)
		expect(home.Z).to.equal(3)

		-- Container default is a deep copy: mutating it can't affect the schema.
		local settings = serverData.Settings.Default()
		expect(settings.Music).to.equal(true)
		settings.Music = false
		expect(serverData.Settings.Default().Music).to.equal(true)

		-- Client reads the same shared schema (even before Init).
		expect(clientData.IsReady()).to.equal(false)
		expect(clientData.Coins.Default()).to.equal(0)
		expect(clientData.Home.Default().X).to.equal(1)

		harness.Cleanup()
	end)

	itRunning("returns a root accessor before Init without yielding in the metamethod", function()
		-- No AutoPump: Hello is never delivered, so Init never arrives and the
		-- client stays unloaded. Accessing a root field goes through the Data
		-- __index metamethod, which must NOT yield (Luau forbids yielding across
		-- a metamethod boundary) — it returns the accessor with template defaults.
		local harness = TestCtx.make({ AutoPump = false })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		local ok, coins = pcall(function()
			return clientData.Coins.Get()
		end)
		expect(ok).to.equal(true) -- would be false ("yield across metamethod") before the fix
		expect(coins).to.equal(0) -- template default until Init lands

		-- Unloaded: IsReady is false, and WaitForData times out (never hangs).
		expect(clientData.IsReady()).to.equal(false)
		expect(clientData.WaitForData(0.1)).to.equal(false)

		harness.Cleanup()
	end)

	itRunning("IsReady/WaitForData report loaded once Init has arrived", function()
		local harness, _, _, _, clientData = makeLoopback() -- AutoPump loads synchronously
		expect(clientData.IsReady()).to.equal(true)
		expect(clientData.WaitForData()).to.equal(true)
		harness.Cleanup()
	end)

	itRunning("client writes stay local; server ops always win", function()
		local harness, _, entry, serverData, clientData = makeLoopback()

		clientData.Coins.Set(999) -- optimistic UI only
		expect(clientData.Coins.Get()).to.equal(999)
		expect(serverData.Coins.Get()).to.equal(0)

		serverData.Coins.Set(5)
		harness.Ctx.Replication.FlushEntry(entry)
		expect(clientData.Coins.Get()).to.equal(5) -- server overwrote the local value

		harness.Cleanup()
	end)

	itRunning("requests a re-Init when an op arrives before Init", function()
		local options = { RequestTimeout = 0.25 }
		local harness = TestCtx.make({ AutoPump = false, Options = options })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		-- The client's Hello is sitting queued (no auto pump); force a protocol
		-- error by injecting a Diff before any Init was delivered.
		local sentBefore = #harness.Transport.SentToServerLog
		local rogue = Wire.EncodeOpsFrame(Wire.Frames.Diff, harness.Compiled, {
			{ Kind = "Set", Path = { "Coins" }, Value = 1 },
		})
		harness.Transport:InjectToClient(rogue)

		-- Client responded by re-sending Hello.
		expect(#harness.Transport.SentToServerLog).to.equal(sentBefore + 1)

		-- Deliver everything; the handshake completes normally.
		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()
		expect(clientData.Coins.Get()).to.equal(0)

		harness.Cleanup()
	end)

	itRunning("surfaces SEND_FAIL when the client cannot send its Hello (e.g. a Sandboxed Scribe)", function()
		-- Roblox blocks a sandboxed thread from firing a non-sandboxed RemoteEvent,
		-- so a Sandboxed Scribe silently fails to send its Hello and looks like a
		-- mysterious handshake timeout. The send failure must be logged (once),
		-- not swallowed and retried forever.
		local Scribe = require(ScribeRoot) :: any
		local harness = TestCtx.make({ AutoPump = false })
		local blocked = {
			Name = "Blocked",
			SendToServer = function()
				error("cannot fire 'Up': the calling thread is sandboxed")
			end,
			ListenClient = function() end,
			-- Present so Transport.Resolve's adapter validation passes; the client
			-- path only ever calls SendToServer/ListenClient.
			SendToClient = function() end,
			ListenServer = function() end,
		}
		local opts = table.clone(harness.Options)
		opts.Transport = blocked
		Client.new(opts, harness.Compiled)
		-- Let the connect coroutine run sendHello.
		for _ = 1, 6 do
			task.wait()
		end
		expect(#Scribe.GetRecentLogs({ Code = "SEND_FAIL", Limit = 5 }) > 0).to.equal(true)
		harness.Cleanup()
	end)

	itRunning("round-trips commands with validation and rate limiting", function()
		local harness, player, _, serverData, clientData = makeLoopback({ CommandRateLimit = 1000 })

		harness.Data.Command("EquipItem", { Args = { "string" } }, function(commandPlayer, itemId)
			expect(commandPlayer).to.equal(player)
			if itemId ~= "Sword" then
				return false, "not owned"
			end
			serverData.Nick.Set("armed")
			return true, "equipped"
		end)

		local ok, message = clientData.Request("EquipItem", "Sword")
		expect(ok).to.equal(true)
		expect(message).to.equal("equipped")
		expect(serverData.Nick.Get()).to.equal("armed")

		local ok2, reason2 = clientData.Request("EquipItem", "Missing")
		expect(ok2).to.equal(false)
		expect(reason2).to.equal("not owned")

		-- Shape rejection before the handler runs.
		local ok3, reason3 = clientData.Request("EquipItem", 123)
		expect(ok3).to.equal(false)
		expect(reason3).to.equal("bad-args")

		-- Unknown command -> rejected reply, never an error escape.
		local ok4, reason4 = clientData.Request("Nonexistent")
		expect(ok4).to.equal(false)
		expect(reason4).to.equal("unknown-command")

		harness.Cleanup()
	end)

	itRunning("rejects a command with too many arguments instead of silently dropping them", function()
		local harness, _, _, _, clientData = makeLoopback()
		harness.Data.Command("Many", function()
			return true
		end)
		-- 17 > Wire.MAX_COMMAND_ARGS: previously the client clamped to 16 and the
		-- handler ran with the trailing arguments missing.
		expect(function()
			clientData.Request("Many", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17)
		end).to.throw()
		harness.Cleanup()
	end)

	itRunning("returns 'error' when a command handler throws", function()
		local harness, _, _, _, clientData = makeLoopback()
		harness.Data.Command("Boom", function()
			error("kaboom")
		end)
		local ok, reason = clientData.Request("Boom")
		expect(ok).to.equal(false)
		expect(reason).to.equal("error")
		harness.Cleanup()
	end)

	itRunning("replies not-ready for a command before the player is Ready", function()
		local harness, _, entry, _, clientData = makeLoopback()
		harness.Data.Command("Ping", function()
			return true
		end)
		entry.State = "Loading" -- force the not-ready branch
		local ok, reason = clientData.Request("Ping")
		entry.State = "Ready" -- restore so teardown is clean
		expect(ok).to.equal(false)
		expect(reason).to.equal("not-ready")
		harness.Cleanup()
	end)

	itRunning("rate-limits command floods", function()
		local harness, _, _, _, clientData = makeLoopback({ CommandRateLimit = 5 })
		harness.Data.Command("Ping", function()
			return true
		end)

		local rejected = 0
		for _ = 1, 12 do
			local ok, reason = clientData.Request("Ping")
			if not ok and reason == "rate-limited" then
				rejected += 1
			end
		end
		expect(rejected > 0).to.equal(true)

		harness.Cleanup()
	end)

	itRunning("times out requests with no reply", function()
		local harness, _, _, _, clientData = makeLoopback()
		harness.Transport.AutoPump = false -- swallow the command frame

		local started = os.clock()
		local ok, reason = clientData.Request("Anything")
		expect(ok).to.equal(false)
		expect(reason).to.equal("timeout")
		expect(os.clock() - started >= 0.2).to.equal(true)

		harness.Transport.AutoPump = true
		harness.Cleanup()
	end)

	itRunning("broadcasts service status to clients", function()
		local harness, _, _, _, clientData = makeLoopback()
		expect(clientData.GetServiceStatus()).to.equal("Healthy")

		local seen = nil
		clientData.OnServiceStatus:Connect(function(status)
			seen = status
		end)
		harness.Ctx.Replication.BroadcastStatus()
		task.wait()
		expect(seen).to.equal("Healthy")

		harness.Cleanup()
	end)

	itRunning("OnSharedChanged fires (userId, shared) when another player's Shared data changes", function()
		local harness, _playerA, _entryA, _serverDataA, clientDataA = makeLoopback()

		local events = {}
		clientDataA.OnSharedChanged:Connect(function(userId, shared)
			table.insert(events, { UserId = userId, Shared = shared })
		end)

		-- A second player publishes Shared data; it broadcasts to A's ready client.
		local playerB, entryB, serverDataB = harness.Join(2002)
		harness.SendHello(playerB) -- B becomes a ready client so its Shared broadcasts
		serverDataB.Pub.Title.Set("HelloFromB")
		harness.Ctx.Replication.FlushEntry(entryB)

		local deadline = os.clock() + 1
		while os.clock() < deadline do
			task.wait()
			local latest = events[#events]
			if latest and latest.Shared and latest.Shared.Pub and latest.Shared.Pub.Title == "HelloFromB" then
				break
			end
		end

		local last = events[#events]
		expect(last).to.be.ok()
		expect(last.UserId).to.equal(2002)
		expect(last.Shared).to.be.ok() -- 2nd arg is the data, not a path
		expect(last.Shared.Pub.Title).to.equal("HelloFromB")

		harness.Cleanup()
	end)
end
