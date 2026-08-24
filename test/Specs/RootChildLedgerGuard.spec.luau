--!nonstrict
-- The reserved-root read guard has to hold on the ROOT accessor's child events too.
--
-- `_Scribe` is the library's own ledger: the purchase dedupe ring, the gift
-- credits, the perk flags. Game code may read it and may not hold it, and Scribe
-- enforces that in two places -- `accessorIndex` refuses writes through it, and
-- `readOut` hands a DETACHED DEEP COPY to any read of it made by an unprivileged
-- accessor. The comment on `readOut` states the exact bug the copy exists to stop:
-- get the live ring, `table.clear` it, and the next receipt Roblox retries is
-- granted a second time on one payment.
--
-- Both guards are derived from `isPublicReserved`, which asks whether the
-- ACCESSOR'S OWN PATH starts at `_Scribe`. On the ROOT accessor that path is
-- empty, so the answer is false -- correctly, for the root itself. But the root's
-- `OnChildChanged` fires once per changed CHILD, and one of those children is
-- `_Scribe`. The guard never looks at the key, so the listener was handed the live
-- ledger by reference: the same hole, through a door the write refusal does not
-- cover and the copy-on-read never saw.
--
-- No mutator anywhere has to mention `_Scribe` for this to happen. Binding
-- `data.OnChildChanged` -- an ordinary, documented thing to do -- is enough.
return function()
	local Root = script.Parent.Parent.Parent
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local function receipt(userId, purchaseId)
		return {
			PlayerId = userId,
			ProductId = 111,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	local function makeHarness()
		local grants = 0
		local harness = TestCtx.make({
			Options = {
				Products = {
					Coins1000 = {
						Id = 111,
						Category = "Currency",
						Grant = function(data)
							grants += 1
							data.Coins.Increment(1000)
						end,
					},
				},
			},
		})
		return harness, function()
			return grants
		end
	end

	describe("the root accessor's child events", function()
		it("still hand game code the LIVE table for an ordinary declared child", function()
			-- THE CONTROL, and it has to come first: containers are handed out live by
			-- reference on purpose, everywhere except the reserved root. A fix that
			-- copied every child value would break that documented behaviour and would
			-- charge every listener for a guard that protects one key.
			local harness = makeHarness()
			local player, entry = harness.Join(91101)
			local data = harness.Data.Get(player)

			local captured
			data.OnChildChanged(function(key, new)
				if key == "Inventory" then
					captured = new
				end
			end)
			data.Inventory.Set({ Sword = { Qty = 1 } })

			expect(captured).to.be.ok()
			expect(captured).to.equal(entry.LiveData.Inventory)

			harness.Cleanup()
		end)

		it("hands a DETACHED copy of the reserved root, not the live ledger", function()
			-- The defect, stated as identity: the value a root child listener receives
			-- for `_Scribe` must not be the table Scribe writes its ledger into.
			local harness = makeHarness()
			local player, entry = harness.Join(91102)
			local data = harness.Data.Get(player)

			local captured
			data.OnChildChanged(function(key, new)
				if key == Template.RESERVED_ROOT then
					captured = new
				end
			end)

			expect(harness.Data.HandleReceipt(receipt(91102, "leak-guard-1"))).to.equal(GRANTED)
			expect(captured).to.be.ok()
			expect(captured == entry.LiveData[Template.RESERVED_ROOT]).to.equal(false)

			harness.Cleanup()
		end)

		it("copies DEEPLY, so clearing what a listener received cannot un-dedupe a receipt", function()
			-- The consequence, driven end to end and measured in grants rather than in
			-- table identity. One payment, one grant -- even after the listener does
			-- the exact thing readOut's comment names.
			local harness, grantCount = makeHarness()
			local player = harness.Join(91103)
			local data = harness.Data.Get(player)

			local captured
			data.OnChildChanged(function(key, new)
				if key == Template.RESERVED_ROOT then
					captured = new
				end
			end)

			expect(harness.Data.HandleReceipt(receipt(91103, "leak-guard-2"))).to.equal(GRANTED)
			expect(grantCount()).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)

			-- What a listener can do with what it was handed. Both levels: the ring
			-- itself and the `{ Id, At }` records inside it, because a shallow copy
			-- would leave the hole open exactly one level down.
			expect(captured.ProcessedPurchaseIds).to.be.ok()
			for _, record in captured.ProcessedPurchaseIds do
				if type(record) == "table" then
					record.Id = nil
				end
			end
			table.clear(captured.ProcessedPurchaseIds)

			-- Roblox retries an unacknowledged receipt with the SAME PurchaseId.
			expect(harness.Data.HandleReceipt(receipt(91103, "leak-guard-2"))).to.equal(GRANTED)
			expect(grantCount()).to.equal(1)
			expect(data.Coins.Get()).to.equal(1000)

			harness.Cleanup()
		end)

		it("does not reach the reserved root through OnKeyAdded or OnKeyRemoved at all", function()
			-- STATED, rather than guarded, and the difference matters. OnKeyAdded and
			-- OnKeyRemoved at the root share the exact wrapper OnChildChanged uses, so
			-- the same guard is applied to all three. But `_Scribe` is created with the
			-- tree and never appears or disappears, so neither of these two can fire
			-- for it -- and a test that merely said "if it fired, it was copied" would
			-- pass forever without ever running its own assertion.
			--
			-- So this pins the REACHABILITY claim the fix rests on. If a later change
			-- ever makes a root key come or go, this goes red and the guard on those
			-- two wrappers stops being belt-and-braces and starts being load-bearing.
			local harness = makeHarness()
			local player, entry = harness.Join(91104)
			local data = harness.Data.Get(player)

			local fired = {}
			data.OnKeyAdded(function(key)
				table.insert(fired, `added:{key}`)
			end)
			data.OnKeyRemoved(function(key)
				table.insert(fired, `removed:{key}`)
			end)

			expect(entry.LiveData[Template.RESERVED_ROOT]).to.be.ok()
			expect(harness.Data.HandleReceipt(receipt(91104, "leak-guard-3"))).to.equal(GRANTED)
			harness.Data.Get(player).Inventory.Set({ Sword = { Qty = 1 } })

			for _, event in fired do
				if string.find(event, Template.RESERVED_ROOT, 1, true) then
					error(`a root key event reached the reserved root: {event}`)
				end
			end

			harness.Cleanup()
		end)

		it("leaves Scribe's own privileged writes reaching the live ledger", function()
			-- The other direction, and the reason the guard is by CALLER rather than by
			-- key: Tree.Reserved and everything under it is PRIVILEGED and must keep
			-- getting the real table, or the library would be copying its own ledger on
			-- every internal read. Driven through the library's own path: a receipt
			-- grant writes through Tree.Reserved and must still land.
			local harness, grantCount = makeHarness()
			local player, entry = harness.Join(91105)

			expect(harness.Data.HandleReceipt(receipt(91105, "leak-guard-4"))).to.equal(GRANTED)
			local ring = entry.LiveData[Template.RESERVED_ROOT].ProcessedPurchaseIds
			expect(#ring).to.equal(1)
			-- The library's own write reached the LIVE ledger, so the retry is deduped:
			-- acknowledged again (Roblox must stop retrying) but NOT granted again.
			expect(harness.Data.HandleReceipt(receipt(91105, "leak-guard-4"))).to.equal(GRANTED)
			expect(#entry.LiveData[Template.RESERVED_ROOT].ProcessedPurchaseIds).to.equal(1)
			expect(grantCount()).to.equal(1)
			expect(harness.Data.Get(player).Coins.Get()).to.equal(1000)

			harness.Cleanup()
		end)
	end)

	it("refuses an unknown product, so the harness above is really deciding", function()
		-- A guard on the guard: every assertion above reads GRANTED, so pin that the
		-- harness can say anything else at all.
		local harness = makeHarness()
		harness.Join(91106)
		expect(harness.Data.HandleReceipt({
			PlayerId = 91106,
			ProductId = 999,
			PurchaseId = "leak-guard-unknown",
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		})).to.equal(NOT_PROCESSED)
		harness.Cleanup()
	end)
end
