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
