--!nonstrict
-- Historical handlers settle paid value without reopening sales.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

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
		expect(h.Data.HandleReceipt(receipt)).toBe(GRANTED)
		expect(h.Data.HandleReceipt(receipt)).toBe(GRANTED)
		if offline then
			buyer = h.Join(BUYER)
		end
		expect(h.Data.Owns(buyer, "OldPerk")).toBe(true)
		expect(h.Data.GetGiftCredits(buyer).Old).toBe(nil)
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
	expect(h.Data.Owns(player, "OldPerk")).toBe(true)
	expect(h.Data.Owns(player, "NewPerk")).toBe(true)
	h.Data.Flush(player, { Force = true })
	expect(#(h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`] or {})).toBe(0)
	h.Cleanup()
end)

it("refuses new prompts but lets existing credits be spent", function()
	local h, prompts = make()
	local buyer, entry = h.Join(BUYER)
	local recipient = h.Join(RECIPIENT)
	expect((h.Data.PromptPurchase(buyer, "Old"))).toBe(false)
	local ok, reason = h.Data.PromptGift(buyer, "Old", RECIPIENT)
	expect(ok).toBe(false)
	expect(reason).toBe("product retired")
	entry.Tree.Reserved.GiftCredits.Old.Set(1)
	expect((h.Data.PromptGift(buyer, "Old", RECIPIENT))).toBe(true)
	expect(h.Data.Owns(recipient, "OldPerk")).toBe(true)
	expect(h.Data.GetGiftCredits(buyer).Old).toBe(nil)
	expect(prompts()).toBe(0)
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
	expect(#h.Fake.Mailboxes[`Default/PLAYER_{RECIPIENT}`]).toBe(1)
	h.Cleanup()
end)

it("rejects ambiguous active and retired registrations", function()
	for _, retired in
		{
			{ New = { Id = 202, Grants = "OldPerk" } },
			{ Old = { Id = 201, Grants = "OldPerk" } },
		}
	do
		expect((pcall(make, { RetiredProducts = retired }))).toBe(false)
	end
end)
