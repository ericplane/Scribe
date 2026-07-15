--!nonstrict
-- Replication: exact op streams, visibility stripping, and the client-ready
-- handshake (no data before Hello, Init then diffs).

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Scribe = require(ScribeRoot)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local deepEquals = require(Root.Test.Helpers.DeepEquals)

	local harness

	beforeEach(function()
		harness = TestCtx.make()
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
	end)
end
