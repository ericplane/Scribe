--!nonstrict
-- External purchases cannot borrow another purchase's gift intent.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
	local BUYER, RECIPIENT = 79801, 79802
	local EXTERNAL = Enum.ProductPurchaseChannel.ExperienceDetailsPage

	local function make()
		return TestCtx.make({
			Options = {
				Products = {
					VIP = { Id = 102, Grants = "VIP" },
					Coins = {
						Id = 101,
						Grant = function(data)
							data.Coins.Increment(5)
						end,
					},
				},
				GiftCooldown = 0,
				PromptProductPurchase = function() end,
			},
		})
	end

	local function receipt(channel, id, productId)
		return {
			PlayerId = BUYER,
			ProductId = productId or 102,
			PurchaseId = id or "external",
			CurrencySpent = 9,
			ProductPurchaseChannel = channel,
		}
	end

	local function stored(h)
		return h.Fake.Persisted[`Default/PLAYER_{BUYER}`]._Scribe
	end

	local function setup(archived)
		local h = make()
		local buyer, entry, buyerData = h.Join(BUYER)
		local recipient, recipientEntry = h.Join(RECIPIENT)
		expect(h.Data.PromptGift(buyer, "VIP", RECIPIENT)).to.equal(true)
		local gift = table.clone(entry.LiveData._Scribe.PendingGifts["102"])
		if archived then
			entry.Tree.Reserved.GiftAims["102"].Set(gift)
			entry.Tree.Reserved.PendingGifts["102"].Set(nil)
		end
		return h, buyer, entry, recipient, recipientEntry, gift, buyerData
	end

	local function expectUnchanged(reserved, archived, gift)
		local record = reserved[if archived then "GiftAims" else "PendingGifts"]["102"]
		expect(record ~= nil).to.equal(true)
		expect(record.GiftId).to.equal(gift.GiftId)
		expect(record.RecipientId).to.equal(gift.RecipientId)
		expect(record.Ts).to.equal(gift.Ts)
		expect(record.Product).to.equal(gift.Product)
	end

	for _, offline in { false, true } do
		local mode = if offline then "offline" else "online"
		for _, channel in
			{
				EXTERNAL,
				Enum.ProductPurchaseChannel.AdReward,
				Enum.ProductPurchaseChannel.CommerceProduct,
			}
		do
			it(`keeps {mode} intents and aims separate from {channel.Name} purchases`, function()
				for _, archived in { false, true } do
					local h, buyer, entry, recipient, _, gift = setup(archived)
					if offline then
						h.Leave(buyer)
					end
					local paid = receipt(channel)
					expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
					expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
					local reserved = if offline then stored(h) else entry.LiveData._Scribe
					expect(reserved.Perks.VIP).to.equal(true)
					expect(reserved.GiftCredits.VIP).to.equal(nil)
					expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
					expectUnchanged(reserved, archived, gift)
					expect(next(reserved.ReceiptReservations)).to.equal(nil)
					h.Cleanup()
				end
			end)
		end

		it(`preserves {mode} gifting for in-experience and legacy receipts`, function()
			for _, legacy in { false, true } do
				for _, archived in { false, true } do
					local h, buyer, entry, recipient = setup(archived)
					if offline then
						h.Leave(buyer)
					end
					local paid = receipt(if legacy then nil else Enum.ProductPurchaseChannel.InExperience)
					expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
					expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
					local reserved = if offline then stored(h) else entry.LiveData._Scribe
					expect(reserved.Perks.VIP).never.to.equal(true)
					expect(reserved.GiftCredits.VIP).to.equal(nil)
					expect(h.Data.Owns(recipient, "VIP")).to.equal(true)
					expect(reserved.PendingGifts["102"]).to.equal(nil)
					expect(reserved.GiftAims["102"]).to.equal(nil)
					h.Cleanup()
				end
			end
		end)

		it(`honors {mode} pinned and legacy receipt routes regardless of channel`, function()
			for _, legacy in { false, true } do
				local h, buyer, entry, recipient, _, gift = setup(false)
				entry.Tree.Reserved.ReceiptReservations.external.Set(if legacy
					then true
					else {
						Product = "VIP",
						ProductId = 102,
						RecipientId = RECIPIENT,
						GiftId = gift.GiftId,
						FromAim = false,
					})
				if offline then
					h.Leave(buyer)
				end
				expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
				local reserved = if offline then stored(h) else entry.LiveData._Scribe
				expect(reserved.Perks.VIP).never.to.equal(true)
				expect(reserved.GiftCredits.VIP).to.equal(nil)
				expect(h.Data.Owns(recipient, "VIP")).to.equal(true)
				expect(next(reserved.ReceiptReservations)).to.equal(nil)
				h.Cleanup()
			end
		end)

		it(`uses recipient proof before granting an {mode} external receipt again`, function()
			for _, archived in { false, true } do
				local h, buyer, entry, recipient, recipientEntry = setup(archived)
				recipientEntry.Tree.Reserved.Perks.VIP.Set(true)
				recipientEntry.Tree.Reserved.ProcessedPurchaseIds.Set({ { Id = "external", At = os.time() } })
				expect(h.Data.Flush(recipient)).to.equal(true)
				if offline then
					h.Leave(buyer)
				end
				expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
				local reserved = if offline then stored(h) else entry.LiveData._Scribe
				expect(reserved.Perks.VIP).never.to.equal(true)
				expect(reserved.GiftCredits.VIP).to.equal(nil)
				expect(#recipientEntry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
				h.Cleanup()
			end
		end)

		it(`holds an {mode} external receipt while old gift delivery is ambiguous`, function()
			local h, buyer, entry, recipient, _, gift = setup(false)
			h.Leave(recipient)
			if offline then
				h.Leave(buyer)
			end
			local get = h.Ctx.Persistence.GetOffline
			h.Ctx.Persistence.GetOffline = function(userId)
				return if userId == RECIPIENT then nil else get(userId)
			end
			expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(RETRY)
			local reserved = if offline then stored(h) else entry.LiveData._Scribe
			expect(reserved.Perks.VIP).never.to.equal(true)
			expectUnchanged(reserved, false, gift)
			h.Ctx.Persistence.GetOffline = get
			expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
			expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
			expectUnchanged(if offline then stored(h) else entry.LiveData._Scribe, false, gift)
			h.Cleanup()
		end)

		it(`keeps the {mode} no-intent credit policy for an external purchase`, function()
			local h, buyer, entry, recipient, _, gift = setup(false)
			entry.Tree.Reserved.Perks.VIP.Set(true)
			if offline then
				h.Leave(buyer)
			end
			expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
			expect(h.Data.HandleReceipt(receipt(EXTERNAL))).to.equal(GRANTED)
			local reserved = if offline then stored(h) else entry.LiveData._Scribe
			expect(reserved.GiftCredits.VIP).to.equal(1)
			expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
			expectUnchanged(reserved, false, gift)
			h.Cleanup()
		end)
	end

	it("does not infer gifts from an unrecognized channel value", function()
		for _, channel in { "FutureChannel", "InExperience", Enum.CurrencyType.Robux } do
			local h, _, entry, recipient, _, gift = setup(false)
			expect(h.Data.HandleReceipt(receipt(channel))).to.equal(GRANTED)
			expect(entry.LiveData._Scribe.Perks.VIP).to.equal(true)
			expect(h.Data.Owns(recipient, "VIP")).to.equal(false)
			expectUnchanged(entry.LiveData._Scribe, false, gift)
			h.Cleanup()
		end
	end)

	it("grants and deduplicates an external consumable without prompting", function()
		local h = make()
		local _, entry, data = h.Join(BUYER)
		local paid = receipt(EXTERNAL, "coins", 101)
		expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
		expect(h.Data.HandleReceipt(paid)).to.equal(GRANTED)
		expect(data.Coins.Get()).to.equal(5)
		expect(#entry.LiveData._Scribe.ProcessedPurchaseIds).to.equal(1)
		h.Cleanup()
	end)
end
