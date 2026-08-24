--!nonstrict
-- Replication: exact op streams, visibility stripping, and the client-ready
-- handshake (no data before Hello, Init then diffs).

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Log = require(ScribeRoot.Internal.Log)
	local Scribe = require(ScribeRoot)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	local harness

	beforeEach(function()
		-- Pinned well above any burst below. Several specs inject frame floods to
		-- exercise a per-KIND budget (the malformed limit needs 40 frames to cross
		-- MALFORMED_MAX), and the raw inbound frame ceiling is a different limit that
		-- must not be what stops them. Left at its default -- max(60, CommandRateLimit
		-- * 4) -- a burst sized against one budget silently starts tripping the other,
		-- and the spec fails for a reason it does not name. Tests that DO exercise the
		-- frame ceiling build their own harness with an explicit low rate.
		harness = TestCtx.make({ Options = { MaxInboundFrameRate = 1000 } })
	end)

	afterEach(function()
		harness.Cleanup()
	end)

	local function expectDeepEqual(a, b)
		local ok, why = deepEquals(a, b)
		if not ok then
			error(`deep-equal failed: {why}`, 2)
		end
	end

	local function joinAndHandshake(userId)
		local player, entry, data = harness.Join(userId)
		harness.SendHello(player)
		return player, entry, data
	end

	describe("handshake", function()
		it("never streams before Hello", function()
			local player, entry, data = harness.Join()
			data.Coins.Set(5)
			harness.Ctx.Replication.FlushEntry(entry)
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(0)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(0)
		end)

		it("responds to Hello with a full snapshot, then streams diffs", function()
			local player, entry, data = harness.Join()
			data.Coins.Set(11) -- pre-Hello mutation: superseded by the snapshot

			harness.SendHello(player)
			local inits = harness.FramesFor(player, Wire.Frames.Init)
			expect(#inits).to.equal(1)

			-- Snapshot ops are root Sets; collect by root key.
			local roots = {}
			for _, op in inits[1].Ops do
				expect(op.Kind).to.equal("Set")
				expect(#op.Path).to.equal(1)
				roots[op.Path[1]] = op.Value
			end
			expect(roots.Coins).to.equal(11)
			expect(roots.Settings.Music).to.equal(true)
			expect(roots.Runtime.InCombat).to.equal(false) -- Session root replicates

			-- The pre-Hello diff queue was superseded, not replayed.
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(0)

			-- Post-handshake mutations stream as diffs.
			data.Coins.Set(12)
			harness.Ctx.Replication.FlushEntry(entry)
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			expect(#diffs).to.equal(1)
			expect(diffs[1].Ops[1].Value).to.equal(12)
		end)

		it("strips ServerOnly roots and _Scribe internals from the snapshot", function()
			local player = harness.Join()
			harness.Ctx.Monetization.GrantPerk(player, "VIP")
			harness.SendHello(player)

			local init = harness.FramesFor(player, Wire.Frames.Init)[1]
			local roots = {}
			for _, op in init.Ops do
				roots[op.Path[1]] = op.Value
			end
			expect(roots.Secret).to.equal(nil) -- ServerOnly: absent by construction

			local reserved = roots._Scribe
			expect(reserved).to.be.ok()
			expect(reserved.Perks.VIP).to.equal(true) -- owner-visible subkeys
			expect(reserved.GiftCredits).to.be.ok()
			expect(reserved.PurchaseLogs).to.equal(nil) -- server-only by default
			expect(reserved.Version).to.equal(nil) -- server-only subkeys
			expect(reserved.ProcessedPurchaseIds).to.equal(nil)
			expect(reserved.PendingGifts).to.equal(nil)
			expect(reserved.Timed).to.equal(nil)
		end)

		it("replicates purchase logs only when opted in", function()
			local optIn = TestCtx.make({
				Options = { PurchaseLog = { ReplicateRobux = true } },
			})
			local player = optIn.Join()
			optIn.SendHello(player)

			local init = optIn.FramesFor(player, Wire.Frames.Init)[1]
			local logs
			for _, op in init.Ops do
				if op.Path[1] == "_Scribe" then
					logs = op.Value.PurchaseLogs
				end
			end
			expect(logs).to.be.ok()
			expect(logs.Robux).to.be.ok()
			expect(logs.InGame).to.equal(nil) -- not opted in: still server-only

			optIn.Cleanup()
		end)

		it("broadcasts the service status on handshake", function()
			local player = harness.Join()
			harness.SendHello(player)
			expect(#harness.FramesFor(player, Wire.Frames.Status)).to.equal(1)
		end)

		it("throttles repeated Hellos instead of re-encoding snapshots", function()
			local player, entry = joinAndHandshake()
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(1)

			-- A Hello flood must not force full-snapshot encodes.
			harness.SendHello(player)
			harness.SendHello(player)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(1)

			-- After the cooldown a genuine re-Init request is honored.
			entry.LastInitAt = os.clock() - 30
			harness.SendHello(player)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(2)
		end)
	end)

	describe("op stream", function()
		it("emits the exact op for a leaf Set", function()
			local player, entry, data = joinAndHandshake()
			data.Coins.Set(5)
			harness.Ctx.Replication.FlushEntry(entry)
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			expect(#diffs).to.equal(1)
			expect(#diffs[1].Ops).to.equal(1)
			expectDeepEqual(diffs[1].Ops[1], { Kind = "Set", Path = { "Coins" }, Value = 5 })
		end)

		it("collapses consecutive Sets on the same path to the last one", function()
			local player, entry, data = joinAndHandshake()
			data.Coins.Set(1)
			data.Coins.Set(2)
			data.Coins.Set(3)
			data.Gems.Set(7)
			harness.Ctx.Replication.FlushEntry(entry)
			local ops = harness.FramesFor(player, Wire.Frames.Diff)[1].Ops
			expect(#ops).to.equal(2)
			expectDeepEqual(ops[1], { Kind = "Set", Path = { "Coins" }, Value = 3 })
			expectDeepEqual(ops[2], { Kind = "Set", Path = { "Gems" }, Value = 7 })
		end)

		it("preserves array op order (no collapsing)", function()
			local player, entry, data = joinAndHandshake()
			data.Quests.Insert("A")
			data.Quests.Insert("B", 1)
			data.Quests.Remove(2)
			harness.Ctx.Replication.FlushEntry(entry)
			local ops = harness.FramesFor(player, Wire.Frames.Diff)[1].Ops
			expect(#ops).to.equal(3)
			expectDeepEqual(ops[1], { Kind = "Insert", Path = { "Quests" }, Value = "A", Index = 1 })
			expectDeepEqual(ops[2], { Kind = "Insert", Path = { "Quests" }, Value = "B", Index = 1 })
			expectDeepEqual(ops[3], { Kind = "Remove", Path = { "Quests" }, Index = 2 })
		end)

		it("emits a single Clear op with bulk semantics", function()
			local player, entry, data = joinAndHandshake()
			data.Inventory.A.Set(1)
			data.Inventory.B.Set(2)
			harness.Ctx.Replication.FlushEntry(entry)

			local removals = 0
			data.Inventory.OnKeyRemoved(function()
				removals += 1
			end)
			local parentChanges = 0
			data.Inventory.Changed(function()
				parentChanges += 1
			end)

			data.Inventory.Clear()
			harness.Ctx.Replication.FlushEntry(entry)
			local frames = harness.FramesFor(player, Wire.Frames.Diff)
			local ops = frames[#frames].Ops
			expect(#ops).to.equal(1)
			expect(ops[1].Kind).to.equal("Clear")
			expect(removals).to.equal(0) -- per-entry events deliberately silent
			expect(parentChanges).to.equal(1)
			expect(data.Inventory.Count()).to.equal(0)
		end)

		it("never queues ops for ServerOnly paths", function()
			local player, entry, data = joinAndHandshake()
			data.Secret.Flagged.Set(true)
			harness.Ctx.Replication.FlushEntry(entry)
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(0)
			expect(data.Secret.Flagged.Get()).to.equal(true) -- still persisted state
		end)

		it("honors Set(value, false) replication skip", function()
			local player, entry, data = joinAndHandshake()
			data.Coins.Set(9, false)
			harness.Ctx.Replication.FlushEntry(entry)
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(0)
			expect(data.Coins.Get()).to.equal(9)
		end)

		it("fires dictionary key events on the server tree", function()
			local _, _, data = joinAndHandshake()
			local added, removed = {}, {}
			data.Inventory.OnKeyAdded(function(key, value)
				table.insert(added, { key, value })
			end)
			data.Inventory.OnKeyRemoved(function(key)
				table.insert(removed, key)
			end)
			data.Inventory.Sword.Set({ Dmg = 1 })
			local old = data.Inventory.Remove("Sword")
			expect(#added).to.equal(1)
			expect(added[1][1]).to.equal("Sword")
			expect(#removed).to.equal(1)
			expect(removed[1]).to.equal("Sword")
			expect(old.Dmg).to.equal(1)
		end)
	end)

	describe("Shared roots", function()
		it("broadcasts Shared diffs to other ready clients, and SharedInit to new joiners", function()
			local _playerA, entryA, dataA = joinAndHandshake(1001)
			dataA.Pub.Title.Set("Hello")
			harness.Ctx.Replication.FlushEntry(entryA)

			local playerB = harness.Join(1002)
			harness.SendHello(playerB)

			-- New joiner receives A's Shared snapshot.
			local sharedInits = harness.FramesFor(playerB, Wire.Frames.SharedInit)
			local found = false
			for _, frame in sharedInits do
				if frame.UserId == 1001 then
					found = true
					expect(frame.Ops[1].Value.Title).to.equal("Hello")
				end
			end
			expect(found).to.equal(true)

			-- Subsequent Shared mutations broadcast as SharedDiff.
			dataA.Pub.Title.Set("Again")
			harness.Ctx.Replication.FlushEntry(entryA)
			local sharedDiffs = harness.FramesFor(playerB, Wire.Frames.SharedDiff)
			expect(#sharedDiffs).to.equal(1)
			expect(sharedDiffs[1].UserId).to.equal(1001)
			expectDeepEqual(sharedDiffs[1].Ops[1].Path, { "Pub", "Title" })
			expect(sharedDiffs[1].Ops[1].Value).to.equal("Again")
		end)
	end)

	describe("inbound hard rules", function()
		it("drops oversized inbound frames", function()
			local player, entry = joinAndHandshake()
			local before = Scribe.GetMetrics().InboundOversize or 0
			harness.Transport:InjectToServer(player, buffer.create(8193))
			expect((Scribe.GetMetrics().InboundOversize or 0) - before).to.equal(1)
			expect(entry.MalformedCount).to.equal(0) -- dropped before decode
		end)

		it("drops malformed frames, counts them, and fires OnAnomaly", function()
			local player, entry = joinAndHandshake()
			local anomalies = 0
			harness.Ctx.Signals.OnAnomaly:Connect(function(info)
				if info.Reason == "MalformedFrame" then
					anomalies += 1
				end
			end)
			local garbage = buffer.create(8)
			buffer.writeu8(garbage, 0, Wire.Frames.Command)
			for i = 1, 7 do
				buffer.writeu8(garbage, i, 0xFF)
			end
			harness.Transport:InjectToServer(player, garbage)
			task.wait()
			expect(entry.MalformedCount).to.equal(1)
			expect(anomalies).to.equal(1)
		end)

		local function garbageFrame()
			local g = buffer.create(8)
			buffer.writeu8(g, 0, Wire.Frames.Command)
			for i = 1, 7 do
				buffer.writeu8(g, i, 0xFF)
			end
			return g
		end

		it("throttles the anomaly AND the log together under a flood, counting every frame", function()
			-- The anomaly and the log share ONE gate, deliberately: MALFORMED_FRAME's
			-- throttle window wraps both the Log.Warn and the OnAnomaly:Fire, so a
			-- crafted-frame flood can spam neither the diagnostic ring nor a game's
			-- OnAnomaly handler. Only the anomaly half was asserted, which left the log
			-- half free to drift out of the gate -- and that is exactly the coupling any
			-- future merge of these throttles into a shared helper would have to keep,
			-- since a helper that only wraps the log cannot gate the anomaly with it.
			local player, entry = joinAndHandshake()
			local anomalies = 0
			harness.Ctx.Signals.OnAnomaly:Connect(function(info)
				if info.Reason == "MalformedFrame" then
					anomalies += 1
				end
			end)
			-- The log ring is a process singleton; count the delta across the window.
			local logsBefore = #Log.GetRecent({ Code = "MALFORMED_FRAME" })
			for _ = 1, 5 do
				harness.Transport:InjectToServer(player, garbageFrame())
			end
			task.wait()
			local logged = #Log.GetRecent({ Code = "MALFORMED_FRAME" }) - logsBefore
			expect(entry.MalformedCount).to.equal(5)
			-- Both throttled to one, and both counted -- the metric still sees all five.
			expect(`anomalies={anomalies} logged={logged}`).to.equal("anomalies=1 logged=1")
		end)

		it("stops dispatching a player's frames after too many malformed frames", function()
			local player, entry = joinAndHandshake()
			for _ = 1, 40 do -- MALFORMED_MAX is 32
				harness.Transport:InjectToServer(player, garbageFrame())
			end
			task.wait()
			expect(entry.MalformedBlocked).to.equal(true)
			local countWhenBlocked = entry.MalformedCount
			harness.Transport:InjectToServer(player, garbageFrame())
			task.wait()
			-- Blocked frames are dropped before parsing, so the count does not grow.
			expect(entry.MalformedCount).to.equal(countWhenBlocked)
		end)

		it("drops raw frames past MaxInboundFrameRate, before they are parsed", function()
			local limited = TestCtx.make({ Options = { MaxInboundFrameRate = 5 } })
			local player, entry = limited.Join()
			limited.SendHello(player)

			-- Seed the bucket so the assertion does not depend on how many frames the
			-- handshake above happened to spend.
			entry.FrameTokens = 5
			entry.FrameLast = os.clock()

			local before = Scribe.GetMetrics().InboundRateLimited or 0
			for _ = 1, 25 do
				limited.Transport:InjectToServer(player, garbageFrame())
			end
			task.wait()

			-- Only the budget reaches the decoder. The rest are dropped before parsing,
			-- so the malformed counter stops moving and this counter takes over --
			-- which is the point: every other budget is per-kind, this one is not.
			expect(entry.MalformedCount).to.equal(5)
			expect((Scribe.GetMetrics().InboundRateLimited or 0) - before).to.equal(20)

			limited.Cleanup()
		end)

		it("spends the frame budget on oversized frames, which no other budget counts", function()
			local limited = TestCtx.make({ Options = { MaxInboundFrameRate = 5 } })
			local player, entry = limited.Join()
			entry.FrameTokens = 5
			entry.FrameLast = os.clock()

			local before = Scribe.GetMetrics().InboundOversize or 0
			for _ = 1, 25 do
				limited.Transport:InjectToServer(player, buffer.create(8193))
			end
			task.wait()

			-- Oversize frames are excluded from the malformed budget by design, so
			-- before this limit existed they were free to send without bound.
			expect((Scribe.GetMetrics().InboundOversize or 0) - before).to.equal(5)
			expect(entry.MalformedCount).to.equal(0)

			limited.Cleanup()
		end)

		it("blocks a player past the oversize limit, on a budget of its own", function()
			local player, entry = joinAndHandshake()
			for _ = 1, 40 do -- OVERSIZE_MAX is 32
				harness.Transport:InjectToServer(player, buffer.create(8193))
			end
			task.wait()
			expect(entry.OversizeBlocked).to.equal(true)
			-- Its own counter: an oversize frame was never read, a malformed one was
			-- decoded and failed, and a shared count would let either mask the other.
			expect(entry.MalformedCount).to.equal(0)
			expect(entry.MalformedBlocked).never.to.equal(true)

			local countWhenBlocked = entry.OversizeCount
			harness.Transport:InjectToServer(player, buffer.create(8193))
			task.wait()
			expect(entry.OversizeCount).to.equal(countWhenBlocked)
		end)

		it("fails closed on a schema-hash mismatch (no Init sent)", function()
			local player, entry = harness.Join()
			local w = Wire.NewWriter(8)
			Wire.U8(w, Wire.Frames.Hello)
			Wire.U32(w, (harness.Compiled.Hash + 1) % 4294967296) -- deliberately wrong hash
			Wire.U8(w, Wire.PROTOCOL_VERSION)
			harness.Transport:InjectToServer(player, Wire.Finish(w))
			task.wait()
			expect(entry.HelloReceived).never.to.equal(true)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(0)
		end)

		it("refuses a Hello whose protocol version differs, and still serves a matching one", function()
			-- R3, DRIVEN RATHER THAN ASSERTED. Two other specs pin
			-- `Wire.PROTOCOL_VERSION == N` as a constant, and a constant is exactly
			-- the kind of pin whoever changes the layout re-pins in the same edit
			-- without the refusal ever executing. Nothing in the repo drove a
			-- MISMATCHED version through the real onHello: deleting the whole
			-- `if protocolVersion ~= Wire.PROTOCOL_VERSION` block left the suite
			-- green, which means a drifted client would have decoded a v(N-1) frame
			-- against a vN reader instead of failing closed.
			--
			-- Both halves matter. The refusal alone would pass against a handshake
			-- that refused EVERY Hello, so the same harness then sends a matching
			-- version and is required to load.
			local player, entry = harness.Join()
			local function hello(version)
				local w = Wire.NewWriter(8)
				Wire.U8(w, Wire.Frames.Hello)
				Wire.U32(w, harness.Compiled.Hash % 4294967296) -- the hash is RIGHT
				Wire.U8(w, version)
				harness.Transport:InjectToServer(player, Wire.Finish(w))
				task.wait()
			end

			-- One below and one above: a `<` or `>` in place of `~=` fails on one of
			-- them, where a single drifted value would let either through.
			local before = Scribe.GetMetrics().ProtocolMismatch or 0
			hello(Wire.PROTOCOL_VERSION - 1)
			hello(Wire.PROTOCOL_VERSION + 1)
			expect(entry.HelloReceived).never.to.equal(true)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(0)
			expect((Scribe.GetMetrics().ProtocolMismatch or 0) - before).to.equal(2)

			hello(Wire.PROTOCOL_VERSION)
			expect(entry.HelloReceived).to.equal(true)
			expect(#harness.FramesFor(player, Wire.Frames.Init)).to.equal(1)
			expect((Scribe.GetMetrics().ProtocolMismatch or 0) - before).to.equal(2)
		end)
	end)
	describe("the Shared queue at handshake", function()
		it("does not re-broadcast, as a diff, ops the SharedInit snapshot already carries", function()
			-- Pins `entry.SharedQueue = {}` in OnEntryReady, which was a surviving
			-- mutation: deleting it left 1345/0.
			--
			-- Reaching it at all takes a write into a Shared root BEFORE OnEntryReady
			-- runs, and no test template produced one -- measured, by counting the queue
			-- at that line across a whole run: 0 occurrences in 1,346 tests. The seam
			-- that does reach it is SeedDerived, which Persistence runs before every
			-- subsystem hook precisely so the Init snapshot carries real values: a
			-- Shared derived field whose stored input differs from the template default
			-- recomputes there, and that recompute is a replicated write, so it lands in
			-- SharedQueue while the snapshot has not been taken yet.
			--
			-- The snapshot then carries the same value, so without the clear the next
			-- flush broadcasts it AGAIN as a SharedDiff to the same recipients (both
			-- pass exceptEntry = entry). Harmless for this Set and permanently wrong for
			-- an Insert, which is what the code comment warns about -- but the redundant
			-- frame is the same defect either way, and it is the half that can be
			-- observed without a non-idempotent op.
			local h = TestCtx.make({
				AutoPump = false,
				Template = {
					Score = Scribe.Int(0, { Min = 0 }),
					Pub = Scribe.Shared(Scribe.Derived(Scribe.Int(0), { "Score" }, function(score: number): number
						return score * 2
					end)),
				},
			})
			-- B is ready first, so it is a recipient of whatever A broadcasts.
			local playerB = h.Join(77002)
			h.SendHello(playerB)

			-- A first session stores Score = 7, so the rejoin's SeedDerived has
			-- something to recompute. Pub is derived, so it is never written directly.
			local playerA0, _entryA0, dataA0 = h.Join(77001)
			dataA0.Score.Set(7)
			h.Leave(playerA0)
			h.Step()

			local before = #h.Transport.SentToClientLog
			local _playerA = h.Join(77001)
			h.Step()
			local shared = { Init = 0, Diff = 0 }
			for i = before + 1, #h.Transport.SentToClientLog do
				local frame = h.Transport.SentToClientLog[i]
				local kind = buffer.readu8(frame.Bytes, 0)
				if kind == Wire.Frames.SharedInit then
					shared.Init += 1
				elseif kind == Wire.Frames.SharedDiff then
					shared.Diff += 1
				end
			end
			-- One snapshot, and no diff repeating it.
			expect(`sharedInit={shared.Init} sharedDiff={shared.Diff}`).to.equal("sharedInit=1 sharedDiff=0")
			h.Cleanup()
		end)
	end)
end
