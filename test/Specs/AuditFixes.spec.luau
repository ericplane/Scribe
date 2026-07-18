--!nonstrict
-- Regression tests for the release-audit findings.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	describe("cross-server offline write guard", function()
		it("refuses UpdateOffline when the profile is active on another server", function()
			local harness = TestCtx.make()
			local key = "Default/PLAYER_50001"
			-- Seed persisted data and an active session held elsewhere.
			harness.Fake.Persisted[key] = { Coins = 5 }
			harness.Fake.ActiveProfiles[key] = { PlaceId = 1, JobId = "other-server" }

			local ok, reason = harness.Data.UpdateOffline(50001, function(data)
				data.Coins = 9999
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "another server") ~= nil).to.equal(true)
			-- The live data was NOT overwritten.
			expect(harness.Fake.Persisted[key].Coins).to.equal(5)

			-- With no active session it proceeds.
			harness.Fake.ActiveProfiles[key] = nil
			expect(harness.Data.UpdateOffline(50001, function(data)
				data.Coins = 42
			end)).to.equal(true)
			expect(harness.Fake.Persisted[key].Coins).to.equal(42)

			harness.Cleanup()
		end)
	end)

	describe("ServerOnly visibility leak", function()
		it("strips a ServerOnly descendant from a whole-container diff", function()
			local template = TestCtx.defaultTemplate()
			template.Backpack = { Coins = 0, DevSecret = Scribe.ServerOnly(0) }
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Backpack.Set({ Coins = 10, DevSecret = 999 })
			harness.Ctx.Replication.FlushEntry(entry)

			-- The server keeps the secret; the client never sees it.
			expect(data.Backpack.DevSecret.Get()).to.equal(999)
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local op = diffs[#diffs].Ops[1]
			expect(op.Path[1]).to.equal("Backpack")
			expect(op.Value.Coins).to.equal(10)
			expect(op.Value.DevSecret).to.equal(nil)

			harness.Cleanup()
		end)

		it("strips a ServerOnly descendant from a Shared-root broadcast", function()
			local template = TestCtx.defaultTemplate()
			template.Pub = Scribe.Shared({ Title = "", Secret = Scribe.ServerOnly("") })
			local harness = TestCtx.make({ Template = template })

			local playerA, entryA, dataA = harness.Join(60001)
			harness.SendHello(playerA)
			dataA.Pub.Title.Set("hello")
			dataA.Pub.Secret.Set("classified")
			harness.Ctx.Replication.FlushEntry(entryA)

			local playerB = harness.Join(60002)
			harness.SendHello(playerB)

			local found = false
			for _, frame in harness.FramesFor(playerB, Wire.Frames.SharedInit) do
				if frame.UserId == 60001 then
					found = true
					expect(frame.Ops[1].Value.Title).to.equal("hello")
					expect(frame.Ops[1].Value.Secret).to.equal(nil)
				end
			end
			expect(found).to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("Data.Purchase amount guard", function()
		it("rejects a non-positive Cost.Amount", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			data.Coins.Set(100)

			local granted = false
			for _, amount in { -1000, 0 } do
				local ok, reason = harness.Data.Purchase(player, {
					Cost = { Path = "Coins", Amount = amount },
					Category = "Exploit",
					ItemId = "Free",
					Grant = function()
						granted = true
					end,
				})
				expect(ok).to.equal(false)
				expect(reason).to.equal("invalid Cost amount")
			end
			-- Never credited currency, never granted.
			expect(data.Coins.Get()).to.equal(100)
			expect(granted).to.equal(false)

			harness.Cleanup()
		end)
	end)

	describe("write validation depth + datatype finiteness", function()
		it("rejects a table nested deeper than the wire codec can encode", function()
			local harness = TestCtx.make()
			local _, _, data = harness.Join()
			-- Build a 30-level-deep table.
			local deep = {}
			local cursor = deep
			for _ = 1, 30 do
				cursor.child = {}
				cursor = cursor.child
			end
			expect(function()
				data.Inventory.Nest.Set(deep)
			end).to.throw()

			harness.Cleanup()
		end)

		it("rejects NaN/inf datatype components instead of persisting them", function()
			local template = TestCtx.defaultTemplate()
			template.Spawn = Scribe.Vector3(Vector3.zero)
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()

			expect(function()
				data.Spawn.Set(Vector3.new(0 / 0, 0, 0))
			end).to.throw()
			expect(function()
				data.Spawn.Set(Vector3.new(math.huge, 0, 0))
			end).to.throw()
			-- The stored value is still the finite default.
			harness.Data.Flush(player)
			local packed = entry.LiveData.Spawn
			expect(typeof(packed)).to.equal("buffer")
			expect(data.Spawn.Get().X).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("transaction rollback correctness", function()
		it("restores the true pre-transaction value when a parent and child are both written", function()
			local template = TestCtx.defaultTemplate()
			template.Bag = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			data.Bag.Slot.Set({ Amount = 3 })
			harness.Data.Flush(player)

			local ok = harness.Data.Transaction(player, function()
				data.Bag.Slot.Amount.Set(5) -- child write
				data.Bag.Slot.Set({ Amount = 10 }) -- whole-container write
				error("boom")
			end)
			expect(ok).to.equal(false)
			-- Must be exactly the pre-transaction value, not an intermediate.
			expect(data.Bag.Slot.Amount.Get()).to.equal(3)

			harness.Cleanup()
		end)

		it("prunes containers materialized inside a rolled-back transaction", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			expect(data.Dyn.Count()).to.equal(0)
			local ok = harness.Data.Transaction(player, function()
				data.Dyn.a.b.Set(5) -- materializes Dyn.a
				error("boom")
			end)
			expect(ok).to.equal(false)
			-- No phantom Dyn.a left behind.
			expect(data.Dyn.Count()).to.equal(0)
			expect(data.Dyn.a.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("restores a txn-created container to nil (not {}) when a later parent Set subsumes it", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			expect(data.Dyn.Count()).to.equal(0)
			local ok = harness.Data.Transaction(player, function()
				data.Dyn.a.b.Set(5) -- materializes Dyn.a (recorded in txn.Created)
				data.Dyn.a.Set({ x = 1 }) -- parent Set snapshots Dyn.a; reconstruction must be nil, not {}
				error("boom")
			end)
			expect(ok).to.equal(false)
			-- True pre-txn state was Dyn.a == nil; a phantom {} must NOT survive the rollback.
			expect(data.Dyn.a.Get()).to.equal(nil)
			expect(data.Dyn.Count()).to.equal(0)

			harness.Cleanup()
		end)

		it("strips a txn-created DESCENDANT container from the rollback of a subsuming parent Set", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			data.Dyn.a.Set({}) -- Dyn.a pre-exists as an empty container (NOT txn-created)
			expect(data.Dyn.a.Count()).to.equal(0)

			local ok = harness.Data.Transaction(player, function()
				data.Dyn.a.sub.x.Set(5) -- materializes Dyn.a.sub (a strict descendant, recorded in txn.Created)
				data.Dyn.a.Set({ y = 1 }) -- subsuming parent Set; reconstruction must drop the created sub
				error("boom")
			end)
			expect(ok).to.equal(false)
			-- Dyn.a pre-existed so it stays, but the phantom Dyn.a.sub must NOT survive the rollback.
			expect(data.Dyn.a.Get() ~= nil).to.equal(true)
			expect(data.Dyn.a.Count()).to.equal(0)
			expect(data.Dyn.a.sub.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("restores a PRE-EXISTING container deleted then recreated inside an aborted txn", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			data.Dyn.a.sub.Set({ y = 9 }) -- committed pre-txn state

			local ok = harness.Data.Transaction(player, function()
				data.Dyn.a.sub.Set(nil) -- delete (snapshots the true pre-txn value)
				data.Dyn.a.sub.x.Set(5) -- recreate: sub lands in txn.Created despite pre-existing
				data.Dyn.a.Set({ z = 1 }) -- subsuming parent Set triggers reconstruction
				error("boom")
			end)
			expect(ok).to.equal(false)
			-- The overlaid delete-snapshot is authoritative: rollback must restore the
			-- committed { y = 9 }, not strip sub as a phantom (silent data loss).
			expect(data.Dyn.a.sub.y.Get()).to.equal(9)
			expect(data.Dyn.a.sub.x.Get()).to.equal(nil)
			expect(data.Dyn.a.z.Get()).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("op coalescing preserves emission order", function()
		it("does not diverge the client when a container Set follows a child write", function()
			local template = TestCtx.defaultTemplate()
			template.Bag = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			-- Within one flush window: whole Set, child write, whole Set again.
			data.Bag.Slot.Set({ Gold = 1 })
			data.Bag.Slot.Gold.Set(2)
			data.Bag.Slot.Set({ Gold = 9 })
			harness.Ctx.Replication.FlushEntry(entry)

			-- Replay the emitted ops against a fresh mirror; must end at Gold=9.
			local diffs = harness.FramesFor(player, Wire.Frames.Diff)
			local mirror = { Bag = { Slot = { Gold = 0 } } }
			for _, frame in diffs do
				for _, op in frame.Ops do
					if op.Kind == "Set" then
						local c = mirror
						for i = 1, #op.Path - 1 do
							c[op.Path[i]] = c[op.Path[i]] or {}
							c = c[op.Path[i]]
						end
						c[op.Path[#op.Path]] = op.Value
					end
				end
			end
			expect(mirror.Bag.Slot.Gold).to.equal(9)
			expect(data.Bag.Slot.Gold.Get()).to.equal(9)

			harness.Cleanup()
		end)

		it("keeps the container-creating Set when a Clear on a fresh dynamic key follows it (same flush)", function()
			local template = TestCtx.defaultTemplate()
			template.Dict = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Dict.newKey.Set({ x = 1 }) -- creates a fresh dynamic key
			data.Dict.newKey.Clear() -- empties it, same flush
			harness.Ctx.Replication.FlushEntry(entry)

			-- The creating Set must survive compaction: Clear is a client no-op on an
			-- absent key, so dropping the Set would leave the client without the key.
			local sawSet, sawClear = false, false
			for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
				for _, op in frame.Ops do
					if op.Path[#op.Path] == "newKey" then
						if op.Kind == "Set" then
							sawSet = true
						elseif op.Kind == "Clear" then
							sawClear = true
						end
					end
				end
			end
			expect(sawSet).to.equal(true)
			expect(sawClear).to.equal(true)
			expect(data.Dict.newKey.Get() ~= nil).to.equal(true) -- server keeps it (empty)

			harness.Cleanup()
		end)
	end)

	describe("gift-credit durability", function()
		it("refunds the credit when reservation cannot be saved", function()
			local harness = TestCtx.make({
				Options = {
					Products = { GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" } },
					GiftCooldown = 0,
					PromptProductPurchase = function() end,
				},
			})
			local buyer = harness.Join(70001)
			-- Seed a gift credit directly on the reserved root.
			harness.Ctx.Persistence.EntryFor(buyer).Tree.Accessor._Scribe.GiftCredits.GiftVIP.Set(1)

			harness.Fake.FailSaves = true
			local ok, reason = harness.Data.PromptGift(buyer, "GiftVIP", 70002)
			expect(ok).to.equal(false)
			expect(string.find(tostring(reason), "reserve") ~= nil).to.equal(true)
			-- The credit was refunded (not consumed).
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(1)
			harness.Fake.FailSaves = false

			harness.Cleanup()
		end)
	end)

	describe("leaderboard GDPR erase", function()
		it("removes queued writes so an erased user does not reappear", function()
			local harness = TestCtx.make({
				Options = { Leaderboards = { TopCoins = { Stat = "Coins", Limit = 10 } } },
			})
			local player, _, data = harness.Join(80001)
			data.Coins.Set(500)
			harness.Leave(player) -- enqueues the final score

			-- Erase before the pacer drains the queue.
			harness.Ctx.Leaderboards.EraseUser(80001)

			-- Draining the queue now must not re-add the user.
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow()
			local top = harness.Data.GetLeaderboard("TopCoins", 10)
			for _, e in top do
				expect(e.UserId).never.to.equal(80001)
			end

			harness.Cleanup()
		end)
	end)

	describe("final-audit regressions", function()
		local function replayDiffs(harness, player, template)
			local mirror = template
			for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
				for _, op in frame.Ops do
					local c = mirror
					for i = 1, #op.Path - 1 do
						c[op.Path[i]] = c[op.Path[i]] or {}
						c = c[op.Path[i]]
					end
					local key = op.Path[#op.Path]
					if op.Kind == "Set" then
						c[key] = op.Value
					elseif op.Kind == "Clear" then
						c[key] = {}
					elseif op.Kind == "Insert" then
						c[key] = c[key] or {}
						table.insert(c[key], op.Index, op.Value)
					end
				end
			end
			return mirror
		end

		it("a nil Set after a child write does not reorder in the diff stream", function()
			local template = TestCtx.defaultTemplate()
			template.Bag = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Bag.Slot.Set({ Gold = 1 })
			data.Bag.Slot.Gold.Set(2)
			data.Bag.Slot.Set(nil) -- whole-container nil write; supersedes the above
			harness.Ctx.Replication.FlushEntry(entry)

			local mirror = replayDiffs(harness, player, { Bag = { Slot = { Gold = 0 } } })
			expect(mirror.Bag.Slot).to.equal(nil)
			expect(data.Bag.Slot.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("a later Set does not collapse ahead of a queued Insert", function()
			local template = TestCtx.defaultTemplate()
			template.Quests = {} :: { number }
			template.Inv = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, entry, data = harness.Join()
			harness.SendHello(player)

			data.Quests.Set({})
			data.Quests.Insert(7)
			data.Inv.Sword.Set({ Dmg = 1 }) -- unrelated whole write
			harness.Ctx.Replication.FlushEntry(entry)

			local mirror = replayDiffs(harness, player, { Quests = {}, Inv = {} })
			expect(mirror.Quests[1]).to.equal(7)
			expect(data.Quests.Get()[1]).to.equal(7)

			harness.Cleanup()
		end)

		it("Insert on a missing path leaves no phantom after a failed transaction", function()
			local template = TestCtx.defaultTemplate()
			template.Quests = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()

			local ok = harness.Data.Transaction(player, function()
				data.Quests.q1.Rewards.Insert("gold") -- materializes Quests.q1.Rewards
				error("boom")
			end)
			expect(ok).to.equal(false)
			expect(data.Quests.Count()).to.equal(0)
			expect(data.Quests.q1.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("a rejected Insert item does not mutate the tree", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			expect(function()
				data.Dyn.list.Insert(0 / 0) -- NaN item, rejected by validation
			end).to.throw()
			expect(data.Dyn.Count()).to.equal(0)
			expect(data.Dyn.list.Get()).to.equal(nil)

			harness.Cleanup()
		end)

		it("transaction rollback preserves a pre-existing empty container", function()
			local template = TestCtx.defaultTemplate()
			template.Inv = { Bag = {} :: { [string]: any } }
			local harness = TestCtx.make({ Template = template })
			local player, _, data = harness.Join()
			harness.Data.Flush(player)

			local ok = harness.Data.Transaction(player, function()
				data.Inv.Bag.Set(nil)
				data.Inv.Bag.Slot.Set(1)
				error("boom")
			end)
			expect(ok).to.equal(false)
			expect(typeof(data.Inv.Bag.Get())).to.equal("table") -- restored, not pruned
			expect(data.Inv.Bag.Count()).to.equal(0)

			harness.Cleanup()
		end)

		it("rejects non-integer and control-char dictionary keys", function()
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join()

			expect(function()
				data.Dyn.Set({ [1.5] = true })
			end).to.throw()
			expect(function()
				data.Dyn[`a{string.char(31)}b`].Set(1) -- separator injection
			end).to.throw()

			harness.Cleanup()
		end)

		it("Data.Purchase rejects a fractional cost on an int currency", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join()
			data.Coins.Set(100)
			local granted = false
			local ok, reason = harness.Data.Purchase(player, {
				Cost = { Path = "Coins", Amount = 0.25 },
				Category = "X",
				ItemId = "Y",
				Grant = function()
					granted = true
				end,
			})
			expect(ok).to.equal(false)
			expect(reason).to.equal("invalid Cost amount")
			expect(data.Coins.Get()).to.equal(100)
			expect(granted).to.equal(false)
			harness.Cleanup()
		end)

		it("newer-version profiles fail closed by default", function()
			local harness = TestCtx.make({ Options = { Migrations = { [2] = function() end } } })
			local key = "Default/PLAYER_90001"
			-- Seed a profile stamped at a version ahead of this server (current 2).
			harness.Fake.Persisted[key] = { Coins = 5, _Scribe = { Version = 99 } }

			local FakePlayer = require(Root.Test.Helpers.FakePlayer)
			local player = FakePlayer.new(90001)
			harness.Ctx.Persistence.OnPlayerAdded(player)
			local data, reason = harness.Ctx.Persistence.WaitForData(player)
			expect(data).to.equal(nil)
			expect(reason).to.be.ok()

			harness.Cleanup()
		end)

		it("forwards SaveInterval to ProfileStore, clamped to the floor", function()
			local ok = TestCtx.make({ Options = { SaveInterval = 60 } })
			expect(ok.Fake.Constants.AUTO_SAVE_PERIOD).to.equal(60)
			ok.Cleanup()

			-- Below the 15s floor is clamped, not rejected.
			local clamped = TestCtx.make({ Options = { SaveInterval = 3 } })
			expect(clamped.Fake.Constants.AUTO_SAVE_PERIOD).to.equal(15)
			clamped.Cleanup()

			-- Left unset, the ProfileStore default is untouched.
			local untouched = TestCtx.make()
			expect(untouched.Fake.Constants.AUTO_SAVE_PERIOD).to.equal(nil)
			untouched.Cleanup()
		end)

		it("rejects a non-positive SaveInterval at construction", function()
			expect(function()
				TestCtx.make({ Options = { SaveInterval = 0 } })
			end).to.throw()
			expect(function()
				TestCtx.make({ Options = { SaveInterval = -5 } })
			end).to.throw()
		end)

		it("requires an explicit ProfileStoreIndex and ProfileKeyPrefix", function()
			expect(function()
				TestCtx.make({ Options = { ProfileStoreIndex = "" } })
			end).to.throw()
			expect(function()
				TestCtx.make({ Options = { ProfileKeyPrefix = "" } })
			end).to.throw()
		end)

		it("gift retry after a failed buyer commit does not mint a duplicate credit", function()
			local harness = TestCtx.make({
				Options = {
					Products = { GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" } },
					GiftCooldown = 0,
					PromptProductPurchase = function() end,
				},
			})
			local buyer = harness.Join(91001)
			local recipient = harness.Join(91002)
			local entry = harness.Ctx.Persistence.EntryFor(buyer)

			expect(harness.Data.PromptGift(buyer, "GiftVIP", 91002)).to.equal(true)

			-- Deliver succeeds (recipient granted), but the buyer's confirming
			-- save fails -> NotProcessedYet with the intent still pending.
			harness.Fake.FailSaves = true
			local receipt = {
				PlayerId = entry.UserId,
				ProductId = 222,
				PurchaseId = "gc-1",
				CurrencySpent = 99,
				CurrencyType = Enum.CurrencyType.Robux,
				PlaceIdWherePurchased = 0,
			}
			harness.Data.HandleReceipt(receipt)
			expect(harness.Data.Owns(recipient, "VIP")).to.equal(true)
			harness.Fake.FailSaves = false

			-- The retry must settle as a completed delivery, NOT convert to a
			-- buyer credit on top of the already-delivered gift.
			harness.Data.HandleReceipt(receipt)
			expect(harness.Data.GetGiftCredits(buyer).GiftVIP).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("whole-module audit fixes", function()
		it("rejects a Scribe declarator nested inside an array-like container", function()
			expect(function()
				TestCtx.make({
					Options = {
						Template = {
							Board = { [1] = "a", [2] = "b", Meta = { Score = Scribe.Int(0) } },
						},
					},
				})
			end).to.throw()
		end)

		it("rejects a fractional numeric dictionary key at the accessor boundary", function()
			local harness = TestCtx.make()
			local _player, _, data = harness.Join(50100)
			-- Whole-table writes already reject fractional keys; the per-key accessor path must too.
			expect(function()
				data.Inventory[1.5].Set(3)
			end).to.throw()
			harness.Cleanup()
		end)
	end)

	describe("v1.0.6 release gate regressions", function()
		it("a listener connected during a Changed dispatch neither double-fires nor skips others", function()
			local harness = TestCtx.make()
			local _p, _e, data = harness.Join()
			local firstCount, lateCount = 0, 0
			data.Coins.Changed(function()
				firstCount += 1
				if firstCount == 1 then
					data.Coins.Changed(function()
						lateCount += 1
					end)
				end
			end)
			data.Coins.Set(1)
			-- The existing listener fires exactly once; the mid-dispatch connect does
			-- not receive the in-flight event (undefined-iteration double-fire/skip).
			expect(firstCount).to.equal(1)
			expect(lateCount).to.equal(0)
			data.Coins.Set(2)
			expect(firstCount).to.equal(2)
			expect(lateCount).to.equal(1)
			harness.Cleanup()
		end)

		it("rollback prune replicates: no phantom container survives in the client mirror", function()
			local Client = require(Root.Scribe.Client)
			local template = TestCtx.defaultTemplate()
			template.Dyn = {} :: { [string]: any }
			local harness = TestCtx.make({ AutoPump = false, Template = template })
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()

			local ok = harness.Data.Transaction(player, function()
				serverData.Dyn.a.b.Set(5) -- materializes Dyn.a inside the txn
				error("abort")
			end)
			expect(ok).to.equal(false)
			harness.Ctx.Replication.FlushEntry(entry)
			harness.Transport:PumpToClient()

			-- The emitted restore op (Set Dyn.a.b = nil) materializes Dyn.a on the client
			-- for parity; the prune must therefore ALSO replicate its removal, or the
			-- client keeps a phantom {} the server no longer has.
			expect(serverData.Dyn.Count()).to.equal(0)
			expect(clientData.Dyn.Count()).to.equal(0)
			expect(clientData.Dyn.a.Get()).to.equal(nil)
			harness.Cleanup()
		end)

		it("AwaitSave is not acked by a save whose payload predates the wait (save generations)", function()
			local harness = TestCtx.make()
			local _player, entry = harness.Join()
			local profile = entry.Profile
			local realSave = profile.Save
			profile.Save = function() end -- drive the save cycle manually

			profile.OnSave:Fire() -- an in-flight save whose payload predates the wait below
			local result: boolean? = nil
			task.spawn(function()
				result = harness.Ctx.Persistence.AwaitSave(entry, 5)
			end)
			task.wait() -- let the waiter register
			profile.OnAfterSave:Fire(profile.Data) -- completes the PRE-registration save
			task.wait()
			-- Must NOT be acked: this save serialized before the caller registered, so
			-- acking would report durability for data that may only exist in memory.
			expect(result).to.equal(nil)

			profile.OnSave:Fire() -- a save STARTED after registration covers the waiter
			profile.OnAfterSave:Fire(profile.Data)
			task.wait()
			expect(result).to.equal(true)
			profile.Save = realSave
			harness.Cleanup()
		end)

		it("client mirror keeps existence parity when a removal supersedes the creating op in one flush", function()
			local Client = require(Root.Scribe.Client)
			local template = TestCtx.defaultTemplate()
			template.Dict = {} :: { [string]: any }
			template.Dict2 = {} :: { [string]: any }
			local harness = TestCtx.make({ AutoPump = false, Template = template })
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()

			-- Variant 1: a nil-Set at the same path supersedes the creating Set; the
			-- server keeps the implicitly materialized parent container.
			serverData.Dict.newKey.sub.Set(5)
			serverData.Dict.newKey.sub.Set(nil)
			-- Variant 2: a Clear supersedes the descendant write that created the key.
			serverData.Dict2.k.x.Set(1)
			serverData.Dict2.k.Clear()
			harness.Ctx.Replication.FlushEntry(entry)
			harness.Transport:PumpToClient()

			expect(serverData.Dict.Count()).to.equal(1)
			expect(clientData.Dict.Count()).to.equal(1) -- parent materialized, parity holds
			expect(typeof(clientData.Dict.newKey.Get())).to.equal("table")
			expect(serverData.Dict2.Count()).to.equal(1)
			expect(clientData.Dict2.Count()).to.equal(1)
			expect(typeof(clientData.Dict2.k.Get())).to.equal("table")
			expect(clientData.Dict2.k.Count()).to.equal(0)
			harness.Cleanup()
		end)

		it("the Timed sweep does not clobber a SetTimed issued by a listener mid-sweep", function()
			local ScribeAny = require(Root.Scribe) :: any
			local template = TestCtx.defaultTemplate()
			template.BoostA = ScribeAny.Timed(false)
			template.BoostB = ScribeAny.Timed(false)
			local harness = TestCtx.make({ Template = template })
			local _p, entry, data = harness.Join()

			data.BoostA.SetTimed(true, 60)
			data.BoostB.SetTimed(true, 60)
			-- Whichever field the sweep resets first re-arms the OTHER via its listener.
			data.BoostA.Changed(function(newValue)
				if newValue == false then
					data.BoostB.SetTimed(true, 120)
				end
			end)
			data.BoostB.Changed(function(newValue)
				if newValue == false then
					data.BoostA.SetTimed(true, 120)
				end
			end)
			-- Lapse both, then sweep once.
			entry.LiveData._Scribe.Timed["BoostA"] = os.time() - 5
			entry.LiveData._Scribe.Timed["BoostB"] = os.time() - 5
			harness.Ctx.Timed.OnLoad(entry)

			-- The first-processed field resets and re-arms the second; the second must
			-- be SKIPPED (stale precollected entry), keeping its fresh timer and value.
			local aActive = (data.BoostA.Active())
			local bActive = (data.BoostB.Active())
			expect(aActive ~= bActive).to.equal(true) -- exactly one survived, none clobbered
			harness.Cleanup()
		end)

		it("client mirror converges when a listener writes during transaction rollback", function()
			local Client = require(Root.Scribe.Client)
			local harness = TestCtx.make({ AutoPump = false })
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)
			harness.Transport:PumpToServer()
			harness.Transport:PumpToClient()

			serverData.Coins.Set(10)
			serverData.Gems.Set(5)
			harness.Ctx.Replication.FlushEntry(entry)
			harness.Transport:PumpToClient()

			-- Fires on the ROLLBACK restore of Coins (back to 10) and writes Gems.
			serverData.Coins.Changed(function(newValue)
				if newValue == 10 then
					serverData.Gems.Set(1001)
				end
			end)
			local ok = harness.Data.Transaction(player, function()
				serverData.Coins.Set(99)
				serverData.Gems.Set(77)
				error("abort")
			end)
			expect(ok).to.equal(false)
			harness.Ctx.Replication.FlushEntry(entry)
			harness.Transport:PumpToClient()

			-- Whatever the restore order was, the mirror must equal the server exactly.
			expect(clientData.Coins.Get()).to.equal(serverData.Coins.Get())
			expect(clientData.Gems.Get()).to.equal(serverData.Gems.Get())
			harness.Cleanup()
		end)
	end)
end
