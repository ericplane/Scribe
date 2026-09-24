--!nonstrict
-- Paid gift routes survive crashes, replacement, and ambiguous reads.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Util = require(Root.Scribe.Internal.Util)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
	local BUYER, RECIPIENT, OTHER = 79401, 79402, 79403

	local function make()
		return TestCtx.make({
			Options = {
				Products = {
					Coins = {
						Id = 101,
						Grant = function(data)
							data.Coins.Increment(1)
						end,
					},
					VIP = { Id = 102, Grants = "VIP" },
				},
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
	end

	local function receipt(id)
		return { PlayerId = BUYER, ProductId = 101, PurchaseId = id, CurrencySpent = 9 }
	end

	local function stored(h, userId)
		return h.Fake.Persisted[`Default/PLAYER_{userId}`]
	end

	local function withClock(body)
		local now = 1700000000
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
		})
		local ok, err = pcall(body, function(seconds)
			now += seconds
		end)
		Clock.Reset()
		if not ok then
			error(err, 0)
		end
	end

	local function loseBuyerCommit(h, offline)
		local buyer = h.Join(BUYER)
		expect(h.Data.PromptGift(buyer, "Coins", RECIPIENT)).to.equal(true)
		if offline then
			h.Leave(buyer)
		end
		local store = h.Ctx.Persistence.Store
		local send = store.MessageAsync
		store.MessageAsync = function(self, key, message)
			local route = stored(h, BUYER)._Scribe.ReceiptReservations.paid
			expect(route.RecipientId).to.equal(RECIPIENT)
			expect(route.ProductId).to.equal(101)
			local result = send(self, key, message)
			h.Fake.FailSaves = true
			return result
		end
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
		store.MessageAsync = send
		if not offline then
			h.Leave(buyer)
		end
		h.Fake.FailSaves = false
		local recipient, recipientEntry, data = h.Join(RECIPIENT)
		expect(data.Coins.Get()).to.equal(1)
		expect(h.Data.Flush(recipient)).to.equal(true)
		expect(#stored(h, BUYER)._Scribe.ProcessedPurchaseIds).to.equal(0)
		return recipient, recipientEntry, data
	end

	for _, offline in { false, true } do
		it(`keeps an {if offline then "offline" else "online"} gift route alongside unresolved aged aims`, function()
			withClock(function(advance)
				local h = make()
				local _, _, recipientData = loseBuyerCommit(h, offline)
				advance(8 * 86400)
				local buyer, entry, buyerData = h.Join(BUYER)
				expect(entry.LiveData._Scribe.GiftAims["101"].RecipientId).to.equal(RECIPIENT)
				for i = 1, 63 do
					entry.Tree.Reserved.GiftAims[tostring(1000 + i)].Set({
						RecipientId = OTHER,
						GiftId = `old-{i}`,
						Product = `old-{i}`,
						Ts = 1,
					})
				end
				expect(h.Data.PromptGift(buyer, "VIP", OTHER)).to.equal(false)
				expect(entry.LiveData._Scribe.GiftAims["101"].RecipientId).to.equal(RECIPIENT)
				if offline then
					h.Leave(buyer)
				end
				expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
				expect(recipientData.Coins.Get()).to.equal(1)
				expect(if offline then stored(h, BUYER).Coins else buyerData.Coins.Get()).to.equal(0)
				expect(next(stored(h, BUYER)._Scribe.ReceiptReservations)).to.equal(nil)
				h.Cleanup()
			end)
		end)

		it(`keeps an {if offline then "offline" else "online"} gift route when the product slot is replaced`, function()
			withClock(function(advance)
				local h = make()
				local _, _, recipientData = loseBuyerCommit(h, offline)
				advance(121)
				local buyer, entry, buyerData = h.Join(BUYER)
				-- A legacy writer replaces the slot while the purchase keeps its pinned route.
				entry.Tree.Reserved.PendingGifts["101"].Set({
					RecipientId = OTHER,
					GiftId = "replacement",
					Product = "Coins",
					Ts = Clock.Now(),
				})
				local newGift = entry.LiveData._Scribe.PendingGifts["101"].GiftId
				if offline then
					h.Leave(buyer)
				end
				expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
				expect(stored(h, BUYER)._Scribe.PendingGifts["101"].GiftId).to.equal(newGift)
				expect(recipientData.Coins.Get()).to.equal(1)
				expect(#(h.Fake.Mailboxes[`Default/PLAYER_{OTHER}`] or {})).to.equal(0)
				expect(if offline then stored(h, BUYER).Coins else buyerData.Coins.Get()).to.equal(0)
				h.Cleanup()
			end)
		end)

		it(
			`settles an {if offline then "offline" else "online"} old intent without discarding its recipient`,
			function()
				local h = make()
				local buyer, entry, data = h.Join(BUYER)
				entry.Tree.Reserved.PendingGifts["101"].Set({
					RecipientId = RECIPIENT,
					GiftId = "old",
					Product = "Coins",
					Ts = 1,
				})
				if offline then
					h.Leave(buyer)
				end
				local get = h.Ctx.Persistence.GetOffline
				h.Ctx.Persistence.GetOffline = function(userId)
					return if userId == RECIPIENT then nil else get(userId)
				end
				expect(h.Data.HandleReceipt(receipt("unknown"))).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt("unknown"))).to.equal(GRANTED)
				local reserved = if offline then stored(h, BUYER)._Scribe else entry.LiveData._Scribe
				expect(reserved.PendingGifts["101"]).to.equal(nil)
				expect(#reserved.ProcessedPurchaseIds).to.equal(1)
				expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(1)
				expect(if offline then stored(h, BUYER).Coins else data.Coins.Get()).to.equal(0)
				h.Ctx.Persistence.GetOffline = get
				h.Cleanup()
			end
		)

		it(`holds an {if offline then "offline" else "online"} legacy reservation without a destination`, function()
			local h = make()
			local buyer, entry, data = h.Join(BUYER)
			entry.Tree.Reserved.ReceiptReservations.paid.Set(true)
			if offline then
				h.Leave(buyer)
			end
			expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
			expect(if offline then stored(h, BUYER).Coins else data.Coins.Get()).to.equal(0)
			h.Cleanup()
		end)
	end

	it("does not deliver an online gift until its route save succeeds", function()
		local h = make()
		local buyer, entry = h.Join(BUYER)
		local _, _, recipientData = h.Join(RECIPIENT)
		expect(h.Data.PromptGift(buyer, "Coins", RECIPIENT)).to.equal(true)
		local save = h.Ctx.Persistence.AwaitSave
		h.Ctx.Persistence.AwaitSave = function(target, ...)
			return if target == entry then false else save(target, ...)
		end
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
		expect(recipientData.Coins.Get()).to.equal(0)
		h.Ctx.Persistence.AwaitSave = save
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
		expect(recipientData.Coins.Get()).to.equal(1)
		h.Cleanup()
	end)

	it("clears the matching archived aim when its pending route finally completes", function()
		withClock(function(advance)
			local h = make()
			local _, _, recipientData = loseBuyerCommit(h, false)
			advance(3601)
			local _, entry, buyerData = h.Join(BUYER)
			expect(entry.LiveData._Scribe.GiftAims["101"] ~= nil).to.equal(true)
			expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(GRANTED)
			expect(entry.LiveData._Scribe.PendingGifts["101"]).to.equal(nil)
			expect(entry.LiveData._Scribe.GiftAims["101"]).to.equal(nil)
			expect(h.Data.HandleReceipt(receipt("new"))).to.equal(GRANTED)
			expect(recipientData.Coins.Get()).to.equal(1)
			expect(buyerData.Coins.Get()).to.equal(1)
			h.Cleanup()
		end)
	end)

	it("holds a route with a mismatched product instead of reinterpreting the purchase", function()
		local h = make()
		local _, entry, data = h.Join(BUYER)
		entry.Tree.Reserved.ReceiptReservations.paid.Set({
			Product = "OldCoins",
			ProductId = 101,
			RecipientId = RECIPIENT,
			GiftId = "old",
			FromAim = false,
		})
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
		expect(data.Coins.Get()).to.equal(0)
		expect(entry.LiveData._Scribe.ReceiptReservations.paid.Product).to.equal("OldCoins")
		h.Cleanup()
	end)

	it("counts prospective route metadata against the profile byte guard", function()
		local h = make()
		local _, entry, data = h.Join(BUYER)
		entry.Tree.Reserved.PendingGifts["101"].Set({
			RecipientId = RECIPIENT,
			GiftId = string.rep("g", 100),
			Product = "Coins",
			Ts = os.time(),
		})
		entry.LiveData.Inventory.Padding = string.rep("x", 3800000 - Util.approxSize(entry.LiveData) - 64)
		expect(h.Data.HandleReceipt(receipt("paid"))).to.equal(RETRY)
		expect(next(entry.LiveData._Scribe.ReceiptReservations)).to.equal(nil)
		expect(data.Coins.Get()).to.equal(0)
		expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(0)
		entry.LiveData.Inventory.Padding = nil
		h.Cleanup()
	end)
end
