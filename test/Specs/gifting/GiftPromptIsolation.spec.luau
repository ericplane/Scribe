--!nonstrict
-- A paid gift keeps its recipient until settlement or a confirmed cancellation.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local TestCtx = require(Root.Test.Helpers.TestCtx)
local Clock = require(Root.Scribe.Internal.Clock)
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
local BUYER, FIRST, SECOND = 81201, 81202, 81203
local harnesses = {}
local now

local function signal()
	local listeners, callbacks = {}, {}
	local result = { Callbacks = callbacks }
	function result:Connect(fn)
		local connection = { Connected = true }
		function connection.Disconnect(handle)
			handle.Connected = false
			listeners[handle] = nil
		end
		listeners[connection] = fn
		table.insert(callbacks, fn)
		return connection
	end
	function result:Fire(...)
		for connection, fn in table.clone(listeners) do
			if connection.Connected then
				fn(...)
			end
		end
	end
	function result.Count()
		local count = 0
		for _ in listeners do
			count += 1
		end
		return count
	end
	return result
end

local function make(extra)
	local finished, prompted = signal(), {}
	local options = {
		Products = {
			Coins = {
				Id = 111,
				Grant = function(data)
					data.Coins.Increment(10)
				end,
			},
			Other = {
				Id = 222,
				Grant = function(data)
					data.Coins.Increment(20)
				end,
			},
		},
		GiftCooldown = 0,
		PromptProductPurchaseFinished = finished,
		PromptProductPurchase = function(player, productId)
			table.insert(prompted, { Player = player, ProductId = productId })
		end,
	}
	for key, value in extra or {} do
		options[key] = value
	end
	local harness = TestCtx.make({ Options = options })
	table.insert(harnesses, harness)
	return harness, finished, prompted
end

local function receipt(id)
	return {
		PlayerId = BUYER,
		ProductId = 111,
		PurchaseId = id,
		ProductPurchaseChannel = Enum.ProductPurchaseChannel.InExperience,
		CurrencySpent = 9,
	}
end

local function pending(entry)
	return entry.LiveData._Scribe.PendingGifts["111"]
end

beforeEach(function()
	now = 1700000000
	Clock.Install({
		Now = function()
			return now
		end,
		Monotonic = function()
			return now
		end,
	})
end)

afterEach(function()
	for _, harness in harnesses do
		harness.Cleanup()
	end
	table.clear(harnesses)
	Clock.Reset()
end)

it("keeps the first recipient when its initial receipt is delayed past 120 seconds", function()
	local harness, finished, prompted = make()
	local buyer, entry, buyerData = harness.Join(BUYER)
	local _, _, firstData = harness.Join(FIRST)
	local _, _, secondData = harness.Join(SECOND)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	local giftId = pending(entry).GiftId
	finished:Fire(BUYER, 111, true)
	now += 121
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(false)
	expect(#prompted).toBe(1)
	expect(pending(entry).GiftId).toBe(giftId)
	expect(harness.Data.HandleReceipt(receipt("first"))).toBe(GRANTED)
	expect(firstData.Coins.Get()).toBe(10)
	expect(secondData.Coins.Get()).toBe(0)
	expect(buyerData.Coins.Get()).toBe(0)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(true)
	finished:Fire(BUYER, 111, true)
	expect(harness.Data.HandleReceipt(receipt("second"))).toBe(GRANTED)
	expect(secondData.Coins.Get()).toBe(10)
	expect(harness.Data.HandleReceipt(receipt("first"))).toBe(GRANTED)
	expect(firstData.Coins.Get()).toBe(10)
end)

it("keeps an unresolved intent locked past its TTL in the same session", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	local giftId = pending(entry).GiftId
	finished:Fire(BUYER, 111, true)
	now += 3601
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(false)
	expect(pending(entry).GiftId).toBe(giftId)
end)

it("keeps an archived aim locked after rejoining", function()
	local harness, finished = make()
	local buyer = harness.Join(BUYER)
	local _, _, recipient = harness.Join(FIRST)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	finished:Fire(BUYER, 111, true)
	harness.Leave(buyer)
	now += 3601
	local returned, entry = harness.Join(BUYER)
	expect(entry.LiveData._Scribe.GiftAims["111"].RecipientId).toBe(FIRST)
	expect((harness.Data.PromptGift(returned, "Coins", SECOND))).toBe(false)
	expect((harness.Data.PromptPurchase(returned, "Coins"))).toBe(false)
	expect(harness.Data.HandleReceipt(receipt("archived"))).toBe(GRANTED)
	expect(recipient.Coins.Get()).toBe(10)
end)

it("does not reclaim an unresolved aim to allow a later gift of its product", function()
	local harness, finished = make()
	local buyer = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	finished:Fire(BUYER, 111, true)
	harness.Leave(buyer)
	now += 31 * 86400
	local returned = harness.Join(BUYER)
	expect((harness.Data.PromptGift(returned, "Coins", SECOND))).toBe(false)
end)

it("clears a canceled gift and permits a fresh recipient", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	expect(finished.Count()).toBe(1)
	finished:Fire(BUYER, 111, false)
	expect(pending(entry)).toBe(nil)
	expect(finished.Count()).toBe(0)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(true)
	expect(pending(entry).RecipientId).toBe(SECOND)
end)

it("confirms cancellation is saved before opening a same-product ordinary purchase", function()
	local harness
	local prompts, savedWhenPrompted = 0, false
	local finished
	harness, finished = make({
		PromptProductPurchase = function()
			prompts += 1
			if prompts == 2 then
				local saved = harness.Fake.Persisted["Default/PLAYER_81201"]
				savedWhenPrompted = saved._Scribe.PendingGifts["111"] == nil
			end
		end,
	})
	local buyer = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	harness.Fake.FailSaves = true
	finished:Fire(BUYER, 111, false)
	expect((harness.Data.PromptPurchase(buyer, "Coins"))).toBe(false)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(false)
	expect(prompts).toBe(1)
	expect(harness.Fake.Persisted["Default/PLAYER_81201"]._Scribe.PendingGifts["111"].RecipientId).toBe(FIRST)
	harness.Fake.FailSaves = false
	expect((harness.Data.PromptPurchase(buyer, "Coins"))).toBe(true)
	expect(savedWhenPrompted).toBe(true)
	expect(prompts).toBe(2)
end)

it("rechecks ownership after waiting for a cancellation save", function()
	local harness, finished, prompted = make({
		Products = { Coins = { Id = 111, Grants = "VIP" } },
	})
	local buyer = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	harness.Fake.FailSaves = true
	finished:Fire(BUYER, 111, false)
	harness.Fake.FailSaves = false
	local original = harness.Ctx.Persistence.AwaitSave
	local changed = false
	harness.Ctx.Persistence.AwaitSave = function(entry, timeout)
		local saved = original(entry, timeout)
		if not changed then
			changed = true
			harness.Data.GrantPerk(buyer, "VIP")
		end
		return saved
	end
	local ok, reason = harness.Data.PromptPurchase(buyer, "Coins")
	expect(changed).toBe(true)
	expect(ok).toBe(false)
	expect(reason).toBe("owned")
	expect(#prompted).toBe(1)
end)

it("closes a paid dialog without clearing its unresolved recipient", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	finished:Fire(BUYER, 111, true)
	expect(finished.Count()).toBe(0)
	expect(pending(entry).RecipientId).toBe(FIRST)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(false)
	expect((harness.Data.PromptGift(buyer, "Other", SECOND))).toBe(true)
end)

it("ignores completion signals for another player or product", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	finished:Fire(SECOND, 111, false)
	finished:Fire(BUYER, 222, false)
	expect(finished.Count()).toBe(1)
	expect(pending(entry).RecipientId).toBe(FIRST)
	expect((harness.Data.PromptGift(buyer, "Other", SECOND))).toBe(false)
end)

it("makes duplicate cancellation callbacks harmless to a later gift", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	local previous = finished.Callbacks[#finished.Callbacks]
	finished:Fire(BUYER, 111, false)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(true)
	local giftId = pending(entry).GiftId
	previous(BUYER, 111, false)
	previous(BUYER, 111, true)
	expect(pending(entry).GiftId).toBe(giftId)
	expect(finished.Count()).toBe(1)
end)

it("does not let a cancellation erase a receipt-bound gift", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	harness.Fake.FailMessages = true
	expect(harness.Data.HandleReceipt(receipt("bound"))).toBe(RETRY)
	expect(entry.LiveData._Scribe.ReceiptReservations.bound.RecipientId).toBe(FIRST)
	finished:Fire(BUYER, 111, false)
	expect(pending(entry).RecipientId).toBe(FIRST)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(false)
	harness.Fake.FailMessages = false
	expect(harness.Data.HandleReceipt(receipt("bound"))).toBe(GRANTED)
	expect((harness.Data.PromptGift(buyer, "Coins", SECOND))).toBe(true)
end)

it("releases listeners on leave without discarding an unresolved gift", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	local previous = finished.Callbacks[#finished.Callbacks]
	local giftId = pending(entry).GiftId
	harness.Leave(buyer)
	expect(finished.Count()).toBe(0)
	local returned, nextEntry = harness.Join(BUYER)
	previous(BUYER, 111, false)
	expect(pending(nextEntry).GiftId).toBe(giftId)
	expect((harness.Data.PromptGift(returned, "Coins", SECOND))).toBe(false)
end)

it("releases listeners on Stop without accepting further callbacks", function()
	local harness, finished = make()
	local buyer = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	local previous = finished.Callbacks[#finished.Callbacks]
	harness.Data.Stop()
	expect(finished.Count()).toBe(0)
	expect((pcall(previous, BUYER, 111, false))).toBe(true)
	expect(harness.Fake.Persisted["Default/PLAYER_81201"]._Scribe.PendingGifts["111"].RecipientId).toBe(FIRST)
end)

it("subscribes before opening a dialog that cancels immediately", function()
	local immediate
	local harness, finished = make({
		PromptProductPurchase = function(player, productId)
			immediate:Fire(player.UserId, productId, false)
		end,
	})
	immediate = finished
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	expect(pending(entry)).toBe(nil)
	expect(immediate.Count()).toBe(0)
end)

it("clears intent and listener when opening the dialog raises", function()
	local harness, finished = make({
		PromptProductPurchase = function()
			error("prompt failed")
		end,
	})
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(false)
	expect(pending(entry)).toBe(nil)
	expect(finished.Count()).toBe(0)
end)

for _, failure in { "prompt", "save acknowledgement" } do
	it(`confirms rollback after a failed {failure} before accepting an ordinary purchase`, function()
		local harness
		local calls, clearedBeforePurchase = 0, false
		harness = make({
			PromptProductPurchase = function()
				calls += 1
				if failure == "prompt" and calls == 1 then
					harness.Fake.FailSaves = true
					error("prompt failed")
				end
				local saved = harness.Fake.Persisted["Default/PLAYER_81201"]
				clearedBeforePurchase = saved._Scribe.PendingGifts["111"] == nil
			end,
		})
		local buyer = harness.Join(BUYER)
		if failure == "save acknowledgement" then
			local original = harness.Ctx.Persistence.AwaitSave
			local first = true
			harness.Ctx.Persistence.AwaitSave = function(entry, timeout)
				local saved = original(entry, timeout)
				if first then
					first = false
					harness.Fake.FailSaves = true
					return false
				end
				return saved
			end
		end
		expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(false)
		expect((harness.Data.PromptPurchase(buyer, "Coins"))).toBe(false)
		expect(harness.Fake.Persisted["Default/PLAYER_81201"]._Scribe.PendingGifts["111"].RecipientId).toBe(FIRST)
		harness.Fake.FailSaves = false
		expect((harness.Data.PromptPurchase(buyer, "Coins"))).toBe(true)
		expect(clearedBeforePurchase).toBe(true)
	end)
end

it("refuses an unsaved intent before opening any dialog or listener", function()
	local harness, finished, prompted = make()
	local buyer, entry = harness.Join(BUYER)
	harness.Fake.FailSaves = true
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(false)
	expect(pending(entry)).toBe(nil)
	expect(finished.Count()).toBe(0)
	expect(#prompted).toBe(0)
	harness.Fake.FailSaves = false
end)

for _, stage in { "save", "Connect" } do
	for _, ending in { "leave", "Stop" } do
		it(`removes an unopened intent when {ending} happens during {stage}`, function()
			local harness, finished, prompted = make()
			local buyer = harness.Join(BUYER)
			local closed = false
			local function close()
				if closed then
					return
				end
				closed = true
				if ending == "leave" then
					harness.Leave(buyer)
				else
					harness.Data.Stop()
				end
			end
			if stage == "save" then
				local original = harness.Ctx.Persistence.AwaitSave
				harness.Ctx.Persistence.AwaitSave = function(entry, timeout)
					local saved = original(entry, timeout)
					close()
					return saved
				end
			else
				local original = finished.Connect
				finished.Connect = function(self, fn)
					local connection = original(self, fn)
					close()
					return connection
				end
			end
			expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(false)
			expect(closed).toBe(true)
			expect(#prompted).toBe(0)
			expect(finished.Count()).toBe(0)
			local saved = harness.Fake.Persisted["Default/PLAYER_81201"]
			expect(saved._Scribe.PendingGifts["111"]).toBe(nil)
		end)
	end
end

it("shares the active-dialog guard with ordinary purchases", function()
	local harness, finished = make()
	local buyer, entry = harness.Join(BUYER)
	expect((harness.Data.PromptPurchase(buyer, "Other"))).toBe(true)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(false)
	expect(pending(entry)).toBe(nil)
	finished:Fire(BUYER, 222, false)
	expect((harness.Data.PromptGift(buyer, "Coins", FIRST))).toBe(true)
	expect((harness.Data.PromptPurchase(buyer, "Other"))).toBe(false)
	finished:Fire(BUYER, 111, true)
	expect((harness.Data.PromptPurchase(buyer, "Coins"))).toBe(false)
	expect((harness.Data.PromptPurchase(buyer, "Other"))).toBe(true)
end)

for _, offline in { false, true } do
	for _, bound in { false, true } do
		it(
			`{if bound then "uses a pinned route" else "holds ambiguous legacy intents"} {if offline
				then "offline"
				else "online"}`,
			function()
				local harness = make()
				local buyer, entry = harness.Join(BUYER)
				local _, _, firstData = harness.Join(FIRST)
				local _, _, secondData = harness.Join(SECOND)
				entry.Tree.Reserved.PendingGifts["111"].Set({
					RecipientId = FIRST,
					GiftId = "first",
					Product = "Coins",
					Ts = now,
				})
				entry.Tree.Reserved.GiftAims["111"].Set({
					RecipientId = SECOND,
					GiftId = "second",
					Product = "Coins",
					Ts = now - 4000,
				})
				if bound then
					entry.Tree.Reserved.ReceiptReservations.legacy.Set({
						RecipientId = FIRST,
						GiftId = "first",
						Product = "Coins",
						ProductId = 111,
						FromAim = false,
					})
				end
				if offline then
					harness.Leave(buyer)
				end
				expect(harness.Data.HandleReceipt(receipt("legacy"))).toBe(if bound then GRANTED else RETRY)
				expect(firstData.Coins.Get()).toBe(if bound then 10 else 0)
				expect(secondData.Coins.Get()).toBe(0)
				local raw = if offline then harness.Fake.Persisted["Default/PLAYER_81201"] else entry.LiveData
				expect(raw.Coins).toBe(0)
				expect(raw._Scribe.GiftAims["111"].GiftId).toBe("second")
				if not bound then
					expect(raw._Scribe.PendingGifts["111"].GiftId).toBe("first")
					expect(raw._Scribe.ReceiptReservations.legacy).toBe(nil)
				end
			end
		)
	end
end
