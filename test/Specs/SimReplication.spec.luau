--!nonstrict
-- Replication inside the simulation: real Client mirrors, real Scribe, real
-- vendored ProfileStore, real modelled disk, on virtual time.
--
-- WHY THIS FILE EXISTS, stated precisely, because the wrong version of that
-- sentence would make it duplicate work that is already done well elsewhere.
--
-- The replication MECHANISM is covered, thoroughly, by the non-sim specs:
-- Replication.spec (op emission, coalescing, Init, throttles), VisibilityMatrix
-- (all six shapes, behaviourally), ContainerReplication (ServerOnly stripping),
-- InitWindow (the snapshot/diff race) and ClientLoopback (a real Client half).
-- Re-testing those here would add runtime and no coverage.
--
-- What the simulation adds is everything those cannot express:
--
--   * The PRODUCTION flush loop runs. RunService.PostSimulation is the thing that
--     turns queued ops into frames (src/Server/Replication.luau:319), and before
--     this file existed it had never fired under the simulation -- measured with
--     probes on sendInit, the Diff encode and flushSharedQueue: 183 sim tests,
--     zero Init frames, zero Diff frames, zero SharedDiff flushes. A change that
--     dropped every diff, or sent ServerOnly data to every client, passed.
--   * Clients are genuinely INDEPENDENT. test/Helpers/StubTransport holds one
--     client listener and one LocalPlayer, so a two-client assertion there has to
--     swap LocalPlayer between constructions. Here every client has its own
--     listener and its own address, so "B never received A's data" is a fact
--     about the wire rather than about the order the spec built things in.
--   * Replication survives events only the simulation can produce: a genuine
--     session steal between two servers over one key space, a wipe-guard block on
--     the real store, a save that cannot land.
--
-- So the assertions here are about replication UNDER SIMULATED CONDITIONS. Where
-- one of them also happens to pin the mechanism, that is defence in depth, not
-- the reason it is here.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Wire = require(Root.Scribe.Internal.Wire)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- Shortened so a bounded run reaches conflict resolution and dead-session
	-- recovery, which at production values take 40 and 630 seconds.
	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 30,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 60,
	}

	--- One template carrying every visibility shape at once, so a fix for one that
	--- breaks another cannot pass.
	local function template()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Nick = Scribe.String("", { MaxLength = 16 }),
			Bag = {}, -- dynamic dictionary
			Secret = Scribe.ServerOnly({ Flagged = false }),
			Pub = Scribe.Shared({ Title = "", Feed = {} }),
			Runtime = Scribe.Session({ InCombat = false }),
		}
	end

	local universe

	--- A universe with NO Transport, so each server mints its own Link.
	---
	--- That is the whole difference from every other sim spec, and it is not a
	--- style choice. Universe.AddServer hands `config.Transport` to every server,
	--- and src/Server/Replication.luau:634 calls transport:ListenServer once per
	--- bundle -- so one shared StubTransport across a three-server universe leaves
	--- only the LAST server able to receive an inbound frame. Omitting it gives
	--- each server its own link, which is the shape a fleet actually has.
	local function newUniverse(overrides)
		local config = {
			Seed = 606060,
			Servers = 1,
			Constants = CONSTANTS,
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = template(),
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	--- Join a player, run the load, attach a client and complete the handshake.
	local function joined(server, userId: number)
		local player = FakePlayer.new(userId)
		server:Join(userId, player)
		universe:Run(30)
		local client = server:AttachClient(player)
		expect(server:SettleClients()).to.equal(true)
		return player, client, server.Bundle.Data.Get(player)
	end

	--- Every decoded frame type ever sent to `player`, in order.
	local function frameTypes(server, player)
		local out = {}
		for _, frame in server.Link:AddressedTo(player) do
			local reader = Wire.NewReader(frame.Bytes)
			table.insert(out, Wire.RU8(reader))
		end
		return out
	end

	local function countOf(list, wanted)
		local n = 0
		for _, value in list do
			if value == wanted then
				n += 1
			end
		end
		return n
	end

	afterEach(function()
		-- The flush loop runs inside a pcall per handler, so a throw would be
		-- collected rather than raised. Asserting it here means no individual spec
		-- has to remember, and a silently-swallowed encode failure cannot read as a
		-- pass -- which is the exact failure this whole file exists to remove.
		if universe then
			for _, server in universe.Servers do
				expect(#server.Bundle.FrameErrors).to.equal(0)
			end
		end
		Guard.Reset()
		universe = nil
	end)

	describe("the handshake, under the simulation", function()
		it("completes Hello -> Init and drives the mirror from the production flush loop", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local _player, client, data = joined(server, 70001)

			expect(client.IsReady()).to.equal(true)
			expect(client.Coins.Get()).to.equal(0)

			-- The write is NOT flushed by hand. It reaches the client only if
			-- RunService.PostSimulation fired and FlushEntry did its job.
			data.Coins.Set(101)
			data.Nick.Set("ada")
			server:Frame()
			expect(client.Coins.Get()).to.equal(101)
			expect(client.Nick.Get()).to.equal("ada")

			-- ...and the loop is observably the thing that did it. Without this the
			-- suite cannot tell "the loop runs" from "the loop runs and does work":
			-- measured before this file, the loop fired 43,959 times across the whole
			-- simulation and called FlushEntry zero times.
			local metrics = server.Bundle.Scribe.GetMetrics()
			expect(metrics.DiffFlushes > 0).to.equal(true)
			expect(metrics.Handshakes > 0).to.equal(true)
		end)

		it("sends exactly one Init for one Hello, and asks again when a diff arrives first", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local player, client = joined(server, 70002)

			expect(countOf(frameTypes(server, player), Wire.Frames.Init)).to.equal(1)

			-- A garbage frame is absorbed: logged, not fatal, and the mirror is
			-- untouched. Injected straight into the client so the server's own encoder
			-- is not what is under test.
			local garbage = Wire.NewWriter(4)
			Wire.U8(garbage, 250) -- not a frame type Scribe issues
			Wire.U32(garbage, 0xDEADBEEF)
			server.Link:InjectToClient(player, Wire.Finish(garbage))
			expect(client.IsReady()).to.equal(true)
			expect(client.Coins.Get()).to.equal(0)

			-- The re-Init path proper. A SECOND player attaches a client and, before its
			-- Hello is ever delivered, receives a Diff -- which is a protocol error the
			-- client answers by asking for a snapshot again. Deliberately a separate
			-- player: the point is a client with no mirror to apply the diff to, and the
			-- one above is loaded.
			local fresh = FakePlayer.new(70012)
			server:Join(70012, fresh)
			uni:Run(30)
			server:AttachClient(fresh) -- Hello queued, NOT delivered
			local helloCount = #server.Link.SentToServerLog

			local rogue = Wire.EncodeOpsFrame(Wire.Frames.Diff, server.Bundle.Compiled, {
				{ Kind = "Set", Path = { "Coins" }, Value = 1 },
			})
			server.Link:InjectToClient(fresh, rogue)
			expect(#server.Link.SentToServerLog).to.equal(helloCount + 1)

			-- ...and the handshake then completes normally.
			expect(server:SettleClients()).to.equal(true)
			expect(countOf(frameTypes(server, fresh), Wire.Frames.Init) >= 1).to.equal(true)
		end)

		it("recovers a client whose Init frame was lost on the wire", function()
			-- The one handshake property only a simulation can express, and nothing else
			-- in the suite covers it: no other spec drops an Init.
			--
			-- The client's recovery is a retry loop with jittered backoff
			-- (src/Client/init.luau:329-339), and the server throttles repeated snapshots
			-- with REINIT_COOLDOWN (Replication.luau:548). Those two have to be compatible
			-- or a client that loses one frame never loads at all -- and checking that
			-- means letting seconds of backoff pass, which on wall-clock time is a spec
			-- nobody would keep. On virtual time it is free.
			local uni = newUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(70801)
			server:Join(70801, player)
			uni:Run(30)

			local data = server.Bundle.Data.Get(player)
			data.Coins.Set(33)

			local client = server:AttachClient(player)
			-- Deliver the Hello, let the server answer, then lose the answer BEFORE it
			-- is delivered. Not server:Frame(), which would pump it to the client in
			-- the same call and leave nothing to drop.
			server.Link:PumpToServer()
			server.Link:DropToClient()
			expect(client.IsReady()).to.equal(false)

			-- Virtual time passes; the retry loop asks again and the server, past its
			-- cooldown, answers with a fresh snapshot carrying the value written before
			-- the first attempt.
			local readyAt = nil
			for second = 1, 60 do
				uni:Run(1)
				if client.IsReady() then
					readyAt = second
					break
				end
			end

			expect(client.IsReady()).to.equal(true)
			expect(client.Coins.Get()).to.equal(33)
			-- Two snapshots were sent in total: the lost one and the replacement.
			expect(countOf(frameTypes(server, player), Wire.Frames.Init)).to.equal(2)

			-- PROMPTLY, and the bound is the whole point rather than a tidy extra.
			-- Measured, there are TWO routes back: the client's own retry loop gets
			-- there in 6 virtual seconds, and a much later accident does too -- the
			-- server still believes the handshake completed, so the next autosave's
			-- diff reaches an unloaded client, which answers OP_BEFORE_INIT with a
			-- Hello. That second route arrived at t=33, tied to AUTO_SAVE_PERIOD, and
			-- would not exist at all for a player nothing writes to. An
			-- eventually-ready assertion passes on it and therefore cannot tell the
			-- retry loop from a Scribe that has no retry loop at all -- measured:
			-- deleting the retry send left the unbounded version green.
			expect(readyAt).never.to.equal(nil)
			expect(readyAt <= 12).to.equal(true)
		end)

		it("preserves op order within a single flush", function()
			-- Three writes to DIFFERENT paths inside one frame, so nothing coalesces
			-- and the order on the wire is the order they were made. A Diff that
			-- reordered ops would still leave the final mirror correct for scalars,
			-- which is why this reads the FRAME rather than the mirror.
			local uni = newUniverse()
			local server = uni:Server(1)
			local player, _client, data = joined(server, 70003)
			local before = #server.Link.SentToClientLog

			data.Coins.Set(1)
			data.Nick.Set("z")
			data.Bag.Sword.Set(3)
			server:Frame()

			local diffs = {}
			for index = before + 1, #server.Link.SentToClientLog do
				local frame = server.Link.SentToClientLog[index]
				if frame.Player == player then
					local reader = Wire.NewReader(frame.Bytes)
					if Wire.RU8(reader) == Wire.Frames.Diff then
						for _, op in Wire.DecodeOps(reader, server.Bundle.Compiled) do
							table.insert(diffs, table.concat(op.Path, "."))
						end
					end
				end
			end

			expect(#diffs).to.equal(3)
			expect(diffs[1]).to.equal("Coins")
			expect(diffs[2]).to.equal("Nick")
			expect(diffs[3]).to.equal("Bag.Sword")
		end)
	end)

	describe("the harness itself", function()
		it("keeps the client half in its own module realm, so status cannot leak either way", function()
			-- A harness self-test, and it is here because the first version of this file
			-- did NOT hold it and nothing would have noticed.
			--
			-- Client.GetServiceStatus() is literally `return Health.GetStatus()`
			-- (src/Client/init.luau:610), and a Status frame makes the client call
			-- Health.AdoptBroadcast (:240), which is setStatus and fires OnStatusChanged
			-- -- which src/Server/Replication.luau:628 has wired to BroadcastStatus. Build
			-- the client from the server's module cache and both directions break at once:
			-- every status assertion passes with the transport disconnected, and a client
			-- can drive its own server into Outage, which gates gifts, restores, erases
			-- and receipts.
			local uni = newUniverse()
			local server = uni:Server(1)
			local _player, client = joined(server, 70901)

			local serverHealth = server.Bundle.Health
			local realm = server.Bundle:ClientRealm()
			expect(realm.Health).never.to.equal(serverHealth)

			-- The two halves compile the template independently, as production does, so
			-- the handshake's schema-hash check is genuinely exercised rather than
			-- trivially satisfied by a shared table. A mismatch fails the handshake
			-- closed, which is why `joined` asserting IsReady above is also this
			-- assertion's control.
			expect(realm.Compiled.Hash).to.equal(server.Bundle.Compiled.Hash)

			-- Move the SERVER's health without sending a frame; the client must not see it.
			expect(client.GetServiceStatus()).to.equal("Healthy")
			-- SetCritical, not a pile of failures: this universe deliberately puts
			-- FailCount at 1000 so contention specs cannot stumble into Outage, so the
			-- count route is out of reach here by design.
			serverHealth.SetCritical(true)
			for _ = 1, 12 do
				serverHealth.ReportFailure("HarnessProbe")
			end
			expect(serverHealth.GetStatus()).never.to.equal("Healthy")
			expect(client.GetServiceStatus()).to.equal("Healthy")

			-- ...and once a frame carries it, the client adopts it without writing back
			-- into the server's copy.
			server.Bundle.Ctx.Replication.BroadcastStatus()
			server.Link:Pump()
			expect(client.GetServiceStatus()).to.equal(serverHealth.GetStatus())

			-- Walk the server's Health back so the shared-nothing claim above is not
			-- quietly paid for by the next spec.
			serverHealth.SetCritical(false)
			for _ = 1, 12 do
				serverHealth.ReportSuccess("HarnessProbe")
			end
		end)
	end)

	describe("command dispatch, from a real client", function()
		--- Call a yielding client API without parking the spec thread.
		---
		--- Client.Request yields on the SIMULATION's scheduler (Clock.Delay for the
		--- timeout, Sched.Defer for the send), and the spec body is an ordinary Lune
		--- thread the simulation does not own -- so calling it directly deadlocks
		--- rather than failing.
		local function request(uni, server, client, ...)
			local packed = table.pack(...)
			local results
			uni.Sched:Spawn(function()
				results = table.pack(client.Request(table.unpack(packed, 1, packed.n)))
			end)
			for _ = 1, 30 do
				if results ~= nil then
					break
				end
				uni.Sched:Run(uni.Sched.Now + 1 / 60)
				server:Frame()
			end
			return results
		end

		it("round-trips a command and rejects a bad argument shape", function()
			-- The command channel has never run under the simulation: every sim spec
			-- passed a transport nothing pumped, so no inbound frame was ever delivered
			-- to a simulated server at all. WireFuzz covers the decoder against hostile
			-- bytes through the non-sim harness; what is new here is the whole path --
			-- real client, real encoder, real dispatcher -- on virtual time.
			local uni = newUniverse({ Options = { CommandRateLimit = 1000, RequestTimeout = 5 } })
			local server = uni:Server(1)
			local player, client, data = joined(server, 71001)

			server.Bundle.Data.Command("Equip", { Args = { "string" } }, function(who, item)
				expect(who).to.equal(player)
				if item ~= "Sword" then
					return false, "not-owned"
				end
				data.Nick.Set("armed")
				return true, "equipped"
			end)

			local ok = request(uni, server, client, "Equip", "Sword")
			expect(ok).to.be.ok()
			expect(ok[1]).to.equal(true)
			expect(ok[2]).to.equal("equipped")
			-- The handler's write came back down the same frame loop.
			expect(client.Nick.Get()).to.equal("armed")

			local denied = request(uni, server, client, "Equip", "Shield")
			expect(denied[1]).to.equal(false)
			expect(denied[2]).to.equal("not-owned")

			-- Shape rejection happens before the handler, so Nick is untouched.
			local bad = request(uni, server, client, "Equip", 7)
			expect(bad[1]).to.equal(false)
			expect(bad[2]).to.equal("bad-args")

			local unknown = request(uni, server, client, "NoSuchCommand")
			expect(unknown[1]).to.equal(false)
			expect(unknown[2]).to.equal("unknown-command")
		end)

		it("rate-limits a flood without breaking the session", function()
			local uni = newUniverse({ Options = { CommandRateLimit = 5, RequestTimeout = 5 } })
			local server = uni:Server(1)
			local player, client = joined(server, 71002)

			server.Bundle.Data.Command("Ping", function()
				return true
			end)

			local limited = 0
			for _ = 1, 15 do
				local res = request(uni, server, client, "Ping")
				if res and res[1] == false and res[2] == "rate-limited" then
					limited += 1
				end
			end
			expect(limited > 0).to.equal(true)

			-- The session survives the flood: still Ready, still mirroring.
			local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
			expect(entry.State).to.equal("Ready")
			server.Bundle.Data.Get(player).Coins.Set(8)
			server:Frame()
			expect(client.Coins.Get()).to.equal(8)
		end)
	end)

	describe("the visibility matrix, with two live clients", function()
		it("keeps ServerOnly off the wire entirely, for the owner and for everyone else", function()
			-- The security edge. Asserted on the BYTES, not on the mirror: a mirror
			-- assertion passes if the client received the value and chose not to
			-- surface it, which is not the same claim at all.
			local uni = newUniverse()
			local server = uni:Server(1)
			local playerA, clientA, dataA = joined(server, 70101)
			local playerB, clientB = joined(server, 70102)

			dataA.Secret.Flagged.Set(true)
			dataA.Coins.Set(9)
			server:Frame()

			-- The server holds it...
			expect(server.Bundle.Data.Get(playerA).Secret.Flagged.Get()).to.equal(true)
			-- ...and neither mirror has it.
			expect(clientA.Raw.Secret.Flagged.Get()).to.equal(nil)
			expect(clientB.Raw.Secret.Flagged.Get()).to.equal(nil)

			-- And the string never appears in any frame sent to either client. A
			-- byte-level check, because it is the only one that also fails when the
			-- value rides along inside a whole-container Set.
			local function mentionsSecret(target)
				for _, frame in server.Link:FramesFor(target) do
					if string.find(buffer.tostring(frame.Bytes), "Flagged", 1, true) then
						return true
					end
				end
				return false
			end
			expect(mentionsSecret(playerA)).to.equal(false)
			expect(mentionsSecret(playerB)).to.equal(false)
			local _ = playerB
		end)

		it("gives Shared to the other player and owner data to nobody else", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local _playerA, clientA, dataA = joined(server, 70201)
			local _playerB, clientB, dataB = joined(server, 70202)

			dataA.Pub.Title.Set("from-a")
			dataA.Coins.Set(11)
			dataB.Pub.Title.Set("from-b")
			server:Frame()

			-- Each sees the other's Shared root...
			expect(clientB.GetShared(70201).Pub.Title).to.equal("from-a")
			expect(clientA.GetShared(70202).Pub.Title).to.equal("from-b")
			-- ...and its own owner data, and NOT the other's.
			expect(clientA.Coins.Get()).to.equal(11)
			expect(clientB.Coins.Get()).to.equal(0)
			expect(clientB.GetShared(70201).Coins).to.equal(nil)

			-- ...and neither client carries a Shared mirror of ITSELF. The owner's own
			-- Diff already carries every Shared value (PushOp queues a Shared op in
			-- both queues), so broadcasting it back is redundant bytes to every player
			-- on the server -- and it is silent, because the value agrees.
			expect(clientA.GetShared(70201)).to.equal(nil)
			expect(clientB.GetShared(70202)).to.equal(nil)
		end)

		it("does not persist Session data, but still replicates it to the owner", function()
			-- The two axes moving independently, checked through a REAL store and a
			-- REAL disk rather than through a fake. Session's whole contract is that
			-- it reaches the client and never reaches the key.
			local uni = newUniverse()
			local server = uni:Server(1)
			local player, client, data = joined(server, 70301)

			data.Runtime.InCombat.Set(true)
			data.Coins.Set(5)
			server:Frame()
			expect(client.Runtime.InCombat.Get()).to.equal(true)

			server:Leave(70301)
			uni:Run(120)
			uni:Quiesce()
			expect(uni:Settle(120)).to.equal(true)

			local stored = uni.Disk.Keyspace:Read("Default", `PLAYER_{70301}`).Value.Data
			expect(stored.Coins).to.equal(5)
			expect(stored.Runtime).to.equal(nil)
			local _ = player
		end)
	end)

	describe("Shared fanout", function()
		it("reaches every other ready client on the server, and none of them twice", function()
			local uni = newUniverse()
			local server = uni:Server(1)
			local _a, _clientA, dataA = joined(server, 70401)
			local _b, clientB = joined(server, 70402)
			local _c, clientC = joined(server, 70403)

			dataA.Pub.Title.Set("broadcast")
			server:Frame()

			expect(clientB.GetShared(70401).Pub.Title).to.equal("broadcast")
			expect(clientC.GetShared(70401).Pub.Title).to.equal("broadcast")

			-- THE double-apply case, and it needs all three of its conditions to bite.
			--
			-- Insert, not Set: an Insert is not idempotent, so applying it twice is
			-- visible where a repeated scalar Set is not. NOT flushed before the joiner
			-- arrives: the op has to still be sitting in A's SharedQueue when the new
			-- client snapshots, because that is the only moment it can be both reflected
			-- in the snapshot AND re-broadcast on the next flush. And a joiner that
			-- handshakes in that same frame -- which `joined` does, since a frame delivers
			-- the Hello before it runs the flush loop.
			--
			-- Without the drain in sendInit (src/Server/Replication.luau:461) D ends up
			-- with two copies. Measured: inverting that gate leaves every other assertion
			-- in this file green.
			-- D is LOADED first and only then attaches a client, with no universe tick
			-- in between. That ordering is the entire test: `joined` runs the universe
			-- to complete the load, and a universe tick fires a frame, which flushes
			-- A's SharedQueue -- so the naive version of this test drains the queue
			-- before the joiner ever arrives and cannot fail.
			local d = FakePlayer.new(70404)
			server:Join(70404, d)
			uni:Run(30)

			dataA.Pub.Feed.Insert("evt") -- queued, NOT yet flushed
			expect(#server.Bundle.Ctx.Persistence.EntryFor(_a).SharedQueue > 0).to.equal(true)

			local clientD = server:AttachClient(d)
			expect(server:SettleClients()).to.equal(true)
			server:Frame()

			expect(clientD.GetShared(70401).Pub.Title).to.equal("broadcast")
			expect(#clientD.GetShared(70401).Pub.Feed).to.equal(1)
			expect(clientD.GetShared(70401).Pub.Feed[1]).to.equal("evt")
			-- ...and the players who were already ready got it exactly once too.
			expect(#clientB.GetShared(70401).Pub.Feed).to.equal(1)
			expect(#clientC.GetShared(70401).Pub.Feed).to.equal(1)

			local sharedFrames = 0
			for _, frame in server.Link:FramesFor(nil) do
				local reader = Wire.NewReader(frame.Bytes)
				local kind = Wire.RU8(reader)
				if kind == Wire.Frames.SharedDiff or kind == Wire.Frames.SharedInit then
					sharedFrames += 1
				end
			end
			expect(sharedFrames > 0).to.equal(true)
		end)

		it("repairs a client that missed a SharedDiff, without double-applying it on the rest", function()
			-- The Shared half of the send-discard defect, and the reason the repair is
			-- a re-snapshot rather than a replay.
			--
			-- A SharedDiff is ONE frame addressed to every other ready client. If it
			-- reaches two of three, the missed client cannot simply be sent it again
			-- later -- the frame carries an Insert, which is not idempotent, and
			-- re-broadcasting it would give the two that already have it a second
			-- copy. So the missed client gets a whole new snapshot instead, and the
			-- others get nothing. `b=1 c=1` is the assertion that separates a real fix
			-- from both failure modes: `b=0 c=1` is the defect, `b=1 c=2` is the
			-- replay-shaped overcorrection.
			--
			-- Two clients cannot share a StubTransport (test/Sim/SCOPE.md), so this
			-- case can only live here.
			local uni = newUniverse()
			local server = uni:Server(1)
			local _a, _clientA, dataA = joined(server, 70601)
			local b, clientB = joined(server, 70602)
			local _c, clientC = joined(server, 70603)

			-- Refuse exactly one frame addressed to B, then heal. Patching the
			-- memoised adapter rather than setting MaxFrameBytes: the size ceiling is
			-- far too coarse to drop one specific frame to one specific player.
			local adapter = server.Link:ServerAdapter()
			local real = adapter.SendToClient
			adapter.SendToClient = function(selfRef: any, player: any, bytes: buffer)
				if player == b then
					adapter.SendToClient = real
					error("sim link: refused", 0)
				end
				return real(selfRef, player, bytes)
			end

			dataA.Pub.Feed.Insert("evt")
			for _ = 1, 4 do
				server:Frame()
			end

			expect(`b={#clientB.GetShared(70601).Pub.Feed} c={#clientC.GetShared(70601).Pub.Feed}`).to.equal("b=1 c=1")
			-- ...and B's own mirror of itself survived the repair.
			expect(clientB.IsReady()).to.equal(true)
		end)

		it("repairs a client that missed a SharedGone, so no ghost mirror survives", function()
			-- SharedGone is the ONLY frame that tells a client to drop its mirror of a
			-- player who left. Nothing later re-sends it, so a client that missed one
			-- keeps a mirror of a player who is no longer on the server -- for the rest
			-- of its session.
			local uni = newUniverse()
			local server = uni:Server(1)
			local _a, _clientA, dataA = joined(server, 70701)
			local b, clientB = joined(server, 70702)

			dataA.Pub.Title.Set("present")
			server:Frame()
			expect(clientB.GetShared(70701)).never.to.equal(nil)

			local adapter = server.Link:ServerAdapter()
			local real = adapter.SendToClient
			adapter.SendToClient = function(selfRef: any, player: any, bytes: buffer)
				if player == b then
					adapter.SendToClient = real
					error("sim link: refused", 0)
				end
				return real(selfRef, player, bytes)
			end

			server:Leave(70701)
			uni:Run(5)
			for _ = 1, 4 do
				server:Frame()
			end

			expect(`ghost={clientB.GetShared(70701) ~= nil}`).to.equal("ghost=false")
		end)

		it("repairs a client that missed a joiner's SharedInit", function()
			-- The mirror image of the SharedGone case: an already-ready client that
			-- misses the SharedInit for a player who joins AFTER it has no mirror of
			-- that player at all, and nothing re-sends one.
			--
			-- The joiner deliberately writes NOTHING after joining. A SharedDiff
			-- creates the mirror if it is absent (`sharedMirrors[userId] or {}`), so a
			-- single later write would repair this by accident and the test would pass
			-- with the fix removed -- which is exactly what the first draft of it did.
			local uni = newUniverse()
			local server = uni:Server(1)
			local a, clientA = joined(server, 70801)
			server:Frame() -- settle A, so it has no owner ops pending

			-- Refuse exactly ONE SharedInit addressed to A, and nothing else. Refusing
			-- every frame to A instead would work too, but it would also be repaired by
			-- the owner-Diff site -- so the OnEntryReady fan-out's own resync could be
			-- deleted and the test would still pass. Matching on the frame type is what
			-- makes this pin the line it is about. (Nothing fragments here: the sim
			-- sets no MaxFrameBytes, and if a frame ever did split, the first byte
			-- would read as Fragment, no refusal would happen, and this test would fail
			-- loudly rather than pass for the wrong reason.)
			local adapter = server.Link:ServerAdapter()
			local real = adapter.SendToClient
			local refusedOne = false
			adapter.SendToClient = function(selfRef: any, player: any, bytes: buffer)
				if not refusedOne and player == a and buffer.readu8(bytes, 0) == Wire.Frames.SharedInit then
					refusedOne = true
					error("sim link: refused", 0)
				end
				return real(selfRef, player, bytes)
			end

			local b = FakePlayer.new(70802)
			server:Join(70802, b)
			uni:Run(30)
			server:AttachClient(b)
			for _ = 1, 5 do
				server:Frame()
			end

			expect(`refused={refusedOne}`).to.equal("refused=true")
			local mirrorOfB = clientA.GetShared(70802)
			expect(`sees={mirrorOfB ~= nil}`).to.equal("sees=true")
		end)

		it("repairs a JOINER that missed an existing player's SharedInit", function()
			-- The third Shared site, and the one the audit noted was already CHECKED
			-- and then forgotten: sendInit's joiner loop tested `sendBuffer(...)` only
			-- to decide whether to add the frame to JoinBytes. A joiner that misses an
			-- existing player's snapshot has no mirror of them for the whole session.
			--
			-- Matched on the RECIPIENT as well as the frame type: a join sends two
			-- SharedInits in opposite directions -- one to the joiner for each existing
			-- player, one to each existing player for the joiner -- and refusing the
			-- wrong one tests the previous spec over again.
			local uni = newUniverse()
			local server = uni:Server(1)
			local _a, _clientA, dataA = joined(server, 70851)
			dataA.Pub.Title.Set("incumbent")
			server:Frame()

			local b = FakePlayer.new(70852)
			local adapter = server.Link:ServerAdapter()
			local real = adapter.SendToClient
			local refusedOne = false
			adapter.SendToClient = function(selfRef: any, player: any, bytes: buffer)
				if not refusedOne and player == b and buffer.readu8(bytes, 0) == Wire.Frames.SharedInit then
					refusedOne = true
					error("sim link: refused", 0)
				end
				return real(selfRef, player, bytes)
			end

			server:Join(70852, b)
			uni:Run(30)
			local clientB = server:AttachClient(b)
			for _ = 1, 6 do
				server:Frame()
			end

			expect(`refused={refusedOne}`).to.equal("refused=true")
			local mirrorOfA = clientB.GetShared(70851)
			expect(`sees={mirrorOfA ~= nil} title={if mirrorOfA then mirrorOfA.Pub.Title else "<none>"}`).to.equal(
				"sees=true title=incumbent"
			)
		end)

		it("repairs a client that missed the Status frame in its handshake", function()
			-- The fourth discarded sendBuffer. A missed Status leaves the client
			-- believing the service is Healthy while the server is in Outage, and
			-- nothing re-sends it: BroadcastStatus only fires on a TRANSITION, so if
			-- the server's status never moves again the client is wrong for the rest of
			-- its session.
			local uni = newUniverse()
			local server = uni:Server(1)
			local serverHealth = server.Bundle.Health

			-- Put the server somewhere other than Healthy BEFORE the client joins, so
			-- the handshake's Status frame carries something the client does not
			-- already believe. A missed "Healthy" is unobservable by construction.
			serverHealth.SetCritical(true)
			for _ = 1, 12 do
				serverHealth.ReportFailure("StatusProbe")
			end
			expect(serverHealth.GetStatus()).never.to.equal("Healthy")

			local player = FakePlayer.new(70951)
			local adapter = server.Link:ServerAdapter()
			local real = adapter.SendToClient
			local refusedOne = false
			adapter.SendToClient = function(selfRef: any, target: any, bytes: buffer)
				if not refusedOne and target == player and buffer.readu8(bytes, 0) == Wire.Frames.Status then
					refusedOne = true
					error("sim link: refused", 0)
				end
				return real(selfRef, target, bytes)
			end

			server:Join(70951, player)
			uni:Run(30)
			local client = server:AttachClient(player)
			for _ = 1, 6 do
				server:Frame()
			end

			expect(`refused={refusedOne}`).to.equal("refused=true")
			expect(`client={client.GetServiceStatus()} server={serverHealth.GetStatus()}`).to.equal(
				`client={serverHealth.GetStatus()} server={serverHealth.GetStatus()}`
			)
			serverHealth.SetCritical(false)
		end)

		it("applies Remove and Clear on a foreign mirror, not only Set and Insert", function()
			-- Pinning specs for the client's Shared-mirror apply. Measured: deleting
			-- applyPlainOp's Remove branch, and deleting its Clear branch, EACH left
			-- the whole suite green. Every `.Remove(` and `.Clear()` elsewhere in
			-- test/Specs is on an OWNER root, which goes through the accessor tree --
			-- a different code path that happens to be well covered.
			--
			-- One frame per op on purpose: compaction would collapse an Insert and the
			-- Remove that follows it inside a single flush, and the collapsed frame
			-- never reaches the branch this pins.
			local uni = newUniverse()
			local server = uni:Server(1)
			local _a, _clientA, dataA = joined(server, 71001)
			local _b, clientB = joined(server, 71002)

			dataA.Pub.Feed.Insert("a")
			dataA.Pub.Feed.Insert("b")
			dataA.Pub.Feed.Insert("c")
			server:Frame()
			expect(table.concat(clientB.GetShared(71001).Pub.Feed, ",")).to.equal("a,b,c")

			dataA.Pub.Feed.Remove(2)
			server:Frame()
			expect(table.concat(clientB.GetShared(71001).Pub.Feed, ",")).to.equal("a,c")

			dataA.Pub.Feed.Clear()
			server:Frame()
			expect(`n={#clientB.GetShared(71001).Pub.Feed}`).to.equal("n=0")
		end)

		it("still delivers owner diffs for a template that declares no Shared root at all", function()
			-- The HasShared gating (src/Server/Replication.luau:461 and :485) skips two
			-- whole loops when no Shared root exists. Cheap to get wrong in the
			-- direction that also skips something else, and nothing else measures it
			-- from the outside.
			local uni = newUniverse({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			})
			local server = uni:Server(1)
			local _player, client, data = joined(server, 70501)
			expect(server.Bundle.Compiled.HasShared).to.equal(false)

			data.Coins.Set(64)
			server:Frame()
			expect(client.Coins.Get()).to.equal(64)
			expect(client.GetShared(70501)).to.equal(nil)
		end)
	end)

	describe("the mirror across events only the simulation produces", function()
		it("stops mirroring to a client whose session was stolen by another server", function()
			-- Two servers, one key space, one genuine steal. The losing server must
			-- not keep streaming a profile it no longer owns -- a mirror that carried
			-- on updating would show the player data the winning server is about to
			-- overwrite.
			local uni = newUniverse({ Servers = 2 })
			local a, b = uni:Server(1), uni:Server(2)
			local playerA, clientA, dataA = joined(a, 70601)
			local entryA = a.Bundle.Ctx.Persistence.EntryFor(playerA)

			dataA.Coins.Set(21)
			a:Frame()
			expect(clientA.Coins.Get()).to.equal(21)

			-- B takes the session.
			b:Join(70601, FakePlayer.new(70601))
			uni:Run(180)

			-- Captured BEFORE the steal: the losing server tears the entry down, so
			-- EntryFor answers nil afterwards -- itself part of the claim.
			expect(entryA.Profile:IsActive()).to.equal(false)
			expect(a.Bundle.Ctx.Persistence.EntryFor(playerA)).to.equal(nil)

			-- A writes into a profile it has lost. Whatever the server does locally,
			-- none of it may reach the wire.
			local framesBefore = #a.Link:AddressedTo(playerA)
			pcall(function()
				a.Bundle.Data.Get(playerA).Coins.Set(999)
			end)
			a:Frame()
			a:Frame()
			expect(#a.Link:AddressedTo(playerA)).to.equal(framesBefore)
			expect(clientA.Coins.Get()).to.equal(21)
		end)

		it("keeps the mirror equal to the server tree while a wipe guard is blocking saves", function()
			-- The wipe guard blocks the SAVE, not the replication: a player whose
			-- profile is being held back from disk must still see their own live data,
			-- or the guard turns a storage problem into a visible one.
			local uni = newUniverse({
				Options = { WipeGuardPolicy = "Block", WipeGuardShrinkRatio = 0.5 },
			})
			local server = uni:Server(1)
			local player, client, data = joined(server, 70701)

			data.Bag.A.Set(1)
			data.Bag.B.Set(2)
			data.Bag.C.Set(3)
			data.Coins.Set(500)
			server:Frame()
			expect(client.Coins.Get()).to.equal(500)

			-- A drastic shrink: the guard's whole trigger.
			data.Bag.A.Set(nil)
			data.Bag.B.Set(nil)
			data.Bag.C.Set(nil)
			data.Coins.Set(1)
			server:Frame()
			uni:Run(90)

			-- The mirror follows the SERVER TREE, whatever the guard decided about
			-- the bytes.
			local entry = server.Bundle.Ctx.Persistence.EntryFor(player)
			expect(client.Coins.Get()).to.equal(entry.LiveData.Coins)
			expect(client.Coins.Get()).to.equal(1)
			expect(client.Bag.A.Get()).to.equal(nil)
		end)
	end)
end
