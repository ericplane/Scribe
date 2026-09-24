--!nonstrict
-- Historical handlers settle paid value without reopening sales.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local BUYER, RECIPIENT = 78401, 78402

	local function make(extra)
		local prompts = 0
		local options = {
			Products = { New = { Id = 201, Grants = "NewPerk" } },
			RetiredProducts = { Old = { Id = 202, Grants = "OldPerk" } },
			GiftCooldown = 0,
			PromptProductPurchase = function()
				prompts += 1
			end,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options }), function()
			return prompts
		end
	end

	for _, offline in { false, true } do
		it(`settles a retired {if offline then "offline" else "online"} receipt once`, function()
			local h = make()
			local buyer = h.Join(BUYER)
			if offline then
				h.Leave(buyer)
			end
			local receipt = { PlayerId = BUYER, ProductId = 202, PurchaseId = "old-paid" }
			expect(h.Data.HandleReceipt(receipt)).to.equal(GRANTED)
			expect(h.Data.HandleReceipt(receipt)).to.equal(GRANTED)
			if offline then
				buyer = h.Join(BUYER)
			end
			expect(h.Data.Owns(buyer, "OldPerk")).to.equal(true)
			expect(h.Data.GetGiftCredits(buyer).Old).to.equal(nil)
			h.Cleanup()
		end)
	end

	it("drains old paid messages alongside active products", function()
		local h = make()
		for _, product in { "Old", "New" } do
			h.Ctx.Persistence.Store:MessageAsync(`PLAYER_{RECIPIENT}`, {
				ScribeGift = true,
				Product = product,
				PurchaseId = product,
				GiftId = product,
				FromUserId = BUYER,
			})
		end
		local player = h.Join(RECIPIENT)
		expect(h.Data.Owns(player, "OldPerk")).to.equal(true)
		expect(h.Data.Owns(player, "NewPerk")).to.equal(true)
		h.Data.Flush(player, { Force = true })
		expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).to.equal(0)
		h.Cleanup()
	end)

	it("refuses new prompts but lets existing credits be spent", function()
		local h, prompts = make()
		local buyer, entry = h.Join(BUYER)
		local recipient = h.Join(RECIPIENT)
		expect(h.Data.PromptPurchase(buyer, "Old")).to.equal(false)
		local ok, reason = h.Data.PromptGift(buyer, "Old", RECIPIENT)
		expect(ok).to.equal(false)
		expect(reason).to.equal("product retired")
		entry.Tree.Reserved.GiftCredits.Old.Set(1)
		expect(h.Data.PromptGift(buyer, "Old", RECIPIENT)).to.equal(true)
		expect(h.Data.Owns(recipient, "OldPerk")).to.equal(true)
		expect(h.Data.GetGiftCredits(buyer).Old).to.equal(nil)
		expect(prompts()).to.equal(0)
		h.Cleanup()
	end)

	it("keeps genuinely unknown paid messages for recovery", function()
		local h = make()
		h.Ctx.Persistence.Store:MessageAsync(`PLAYER_{RECIPIENT}`, {
			ScribeGift = true,
			Product = "Missing",
			PurchaseId = "missing",
			GiftId = "missing",
			FromUserId = BUYER,
		})
		local player = h.Join(RECIPIENT)
		h.Data.Flush(player, { Force = true })
		expect(#h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`]).to.equal(1)
		h.Cleanup()
	end)

	it("rejects ambiguous active and retired registrations", function()
		for _, retired in
			{
				{ New = { Id = 202, Grants = "OldPerk" } },
				{ Old = { Id = 201, Grants = "OldPerk" } },
			}
		do
			expect(pcall(make, { RetiredProducts = retired })).to.equal(false)
		end
	end)
end
