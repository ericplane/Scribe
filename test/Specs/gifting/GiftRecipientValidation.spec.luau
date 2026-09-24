--!nonstrict
-- Malformed gift destinations cannot become paid deliveries or self purchases.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
	local BUYER, RECIPIENT = 81301, 81302
	local NOW = 1700000000
	local harnesses = {}

	local function make()
		local h = TestCtx.make({
			Options = {
				Products = {
					Coins = {
						Id = 101,
						Grant = function(data)
							data.Coins.Increment(10)
						end,
					},
					VIP = { Id = 102, Grants = "VIP" },
				},
			},
		})
		table.insert(harnesses, h)
		return h
	end

	local function stored(h)
		return h.Fake.Persisted[`Default/PLAYER_{BUYER}`]
	end

	local function receipt(productId)
		return {
			PlayerId = BUYER,
			ProductId = productId or 101,
			PurchaseId = "paid",
			CurrencySpent = 9,
			ProductPurchaseChannel = Enum.ProductPurchaseChannel.InExperience,
		}
	end

	local function record()
		return { RecipientId = RECIPIENT, GiftId = "gift", Product = "Coins", Ts = NOW }
	end

	local function route()
		return { RecipientId = RECIPIENT, GiftId = "pinned", Product = "Coins", ProductId = 101, FromAim = false }
	end

	local function prepare(offline, container, intent, productId)
		local h = make()
		local buyer, entry = h.Join(BUYER)
		local _, _, recipientData = h.Join(RECIPIENT)
		if offline then
			h.Leave(buyer)
		end
		local data = if offline then stored(h) else entry.LiveData
		data._Scribe[container][tostring(productId or 101)] = intent
		return h, data, recipientData, buyer
	end

	local function expectHeld(h, data, recipientData, ownsVIP)
		expect(data.Coins).to.equal(0)
		expect(data._Scribe.Perks.VIP == true).to.equal(ownsVIP == true)
		expect(next(data._Scribe.GiftCredits)).to.equal(nil)
		expect(next(data._Scribe.ReceiptReservations)).to.equal(nil)
		expect(#data._Scribe.ProcessedPurchaseIds).to.equal(0)
		expect(recipientData.Coins.Get()).to.equal(0)
		expect(h.Ctx.Persistence.EntryForUserId(RECIPIENT).LiveData._Scribe.Perks.VIP == true).to.equal(false)
		for _, mailbox in h.Fake.Mailboxes do
			expect(#mailbox).to.equal(0)
		end
	end

	beforeEach(function()
		Clock.Install({
			Now = function()
				return NOW
			end,
			Monotonic = function()
				return NOW
			end,
		})
	end)

	afterEach(function()
		for _, h in harnesses do
			h.Cleanup()
		end
		table.clear(harnesses)
		Clock.Reset()
	end)

	for _, offline in { false, true } do
		for _, container in { "PendingGifts", "GiftAims" } do
			local label = `{if offline then "offline" else "online"} {container}`
			for _, invalid in
				{
					{ Name = "missing" },
					{ Name = "zero", Value = 0 },
					{ Name = "negative", Value = -1 },
					{ Name = "fractional", Value = 1.5 },
					{ Name = "NaN", Value = 0 / 0 },
					{ Name = "infinite", Value = math.huge },
					{ Name = "negative infinity", Value = -math.huge },
					{ Name = "nonnumeric", Value = "invalid" },
				}
			do
				it(`holds {label} with a {invalid.Name} recipient`, function()
					local intent = record()
					intent.RecipientId = invalid.Value
					local h, data, recipientData = prepare(offline, container, intent)
					expect(h.Data.HandleReceipt(receipt())).to.equal(RETRY)
					expectHeld(h, if offline then stored(h) else data, recipientData)
				end)
			end

			for _, invalid in
				{
					{ Name = "missing" },
					{ Name = "empty", Value = "" },
					{ Name = "numeric", Value = 123 },
				}
			do
				it(`holds {label} with a {invalid.Name} gift ID`, function()
					local intent = record()
					intent.GiftId = invalid.Value
					local h, data, recipientData = prepare(offline, container, intent)
					expect(h.Data.HandleReceipt(receipt())).to.equal(RETRY)
					expectHeld(h, if offline then stored(h) else data, recipientData)
				end)
			end

			it(`accepts a numeric string recipient in {label}`, function()
				local intent = record()
				intent.RecipientId = tostring(RECIPIENT)
				local h, data, recipientData = prepare(offline, container, intent)
				expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
				expect(recipientData.Coins.Get()).to.equal(10)
				expect((if offline then stored(h) else data).Coins).to.equal(0)
			end)

			it(`does not convert malformed {label} into a buyer perk`, function()
				local h, data, recipientData = prepare(offline, container, { Product = "VIP", Ts = NOW }, 102)
				expect(h.Data.HandleReceipt(receipt(102))).to.equal(RETRY)
				expectHeld(h, if offline then stored(h) else data, recipientData)
			end)

			it(`does not convert malformed {label} into an owned buyer's gift credit`, function()
				local h, data, recipientData = prepare(offline, container, { Product = "VIP", Ts = NOW }, 102)
				data._Scribe.Perks.VIP = true
				expect(h.Data.HandleReceipt(receipt(102))).to.equal(RETRY)
				expectHeld(h, if offline then stored(h) else data, recipientData, true)
			end)

			it(`keeps completed receipt precedence over malformed {label}`, function()
				local h, data, recipientData = prepare(offline, container, { Ts = NOW })
				data._Scribe.ProcessedPurchaseIds = { { Id = "paid", At = NOW } }
				expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
				expect(recipientData.Coins.Get()).to.equal(0)
				expect(next(data._Scribe.ReceiptReservations)).to.equal(nil)
				expect(data.Coins).to.equal(0)
			end)

			it(`keeps a pinned route ahead of malformed {label}`, function()
				local h, data, recipientData = prepare(offline, container, { Ts = NOW })
				data._Scribe.ReceiptReservations.paid = route()
				local info = receipt()
				info.ProductPurchaseChannel = Enum.ProductPurchaseChannel.ExperienceDetailsPage
				expect(h.Data.HandleReceipt(info)).to.equal(GRANTED)
				expect(h.Data.HandleReceipt(info)).to.equal(GRANTED)
				expect(recipientData.Coins.Get()).to.equal(10)
				expect((if offline then stored(h) else data).Coins).to.equal(0)
			end)

			it(`ignores malformed {label} for an unrelated external purchase`, function()
				local h, data, recipientData = prepare(offline, container, { Ts = NOW }, 102)
				local info = receipt(102)
				info.ProductPurchaseChannel = Enum.ProductPurchaseChannel.ExperienceDetailsPage
				expect(h.Data.HandleReceipt(info)).to.equal(GRANTED)
				expect((if offline then stored(h) else data)._Scribe.Perks.VIP).to.equal(true)
				expect(recipientData.Coins.Get()).to.equal(0)
				expect(h.Ctx.Persistence.EntryForUserId(RECIPIENT).LiveData._Scribe.Perks.VIP == true).to.equal(false)
				expect((if offline then stored(h) else data)._Scribe[container]["102"] ~= nil).to.equal(true)
			end)
		end
	end

	for _, container in { "PendingGifts", "GiftAims" } do
		it(`preserves malformed {container} through rejoin instead of granting to the buyer`, function()
			local h = make()
			local buyer = h.Join(BUYER)
			local _, _, recipientData = h.Join(RECIPIENT)
			h.Leave(buyer)
			stored(h)._Scribe[container]["101"] = { Product = "Coins", Ts = 1 }
			local _, entry = h.Join(BUYER)
			expect(h.Data.HandleReceipt(receipt())).to.equal(RETRY)
			expectHeld(h, entry.LiveData, recipientData)
		end)

		it(`revalidates {container} inside the offline reservation write`, function()
			local h, _, recipientData = prepare(true, container, record())
			local update = h.Ctx.Persistence.UpdateOffline
			local injected = false
			h.Ctx.Persistence.UpdateOffline = function(userId, fn, ...)
				if userId == BUYER and not injected then
					injected = true
					stored(h)._Scribe[container]["101"].RecipientId = 0
				end
				return update(userId, fn, ...)
			end
			expect(h.Data.HandleReceipt(receipt())).to.equal(RETRY)
			expect(injected).to.equal(true)
			expectHeld(h, stored(h), recipientData)
		end)

		it(`holds a replacement {container} before the first offline reservation`, function()
			local h, _, recipientData = prepare(true, container, record())
			local update = h.Ctx.Persistence.UpdateOffline
			local injected = false
			h.Ctx.Persistence.UpdateOffline = function(userId, fn, ...)
				if userId == BUYER and not injected then
					injected = true
					local replacement = record()
					replacement.RecipientId = RECIPIENT + 1
					replacement.GiftId = "replacement"
					stored(h)._Scribe[container]["101"] = replacement
				end
				return update(userId, fn, ...)
			end
			expect(h.Data.HandleReceipt(receipt())).to.equal(RETRY)
			expect(injected).to.equal(true)
			expectHeld(h, stored(h), recipientData)
			expect(stored(h)._Scribe[container]["101"].GiftId).to.equal("replacement")
		end)
	end

	it("honours a valid route saved after the offline view before a malformed slot is checked", function()
		local h, _, recipientData = prepare(true, "PendingGifts", record())
		local update = h.Ctx.Persistence.UpdateOffline
		local injected = false
		h.Ctx.Persistence.UpdateOffline = function(userId, fn, ...)
			if userId == BUYER and not injected then
				injected = true
				stored(h)._Scribe.PendingGifts["101"] = { Ts = NOW }
				stored(h)._Scribe.ReceiptReservations.paid = route()
			end
			return update(userId, fn, ...)
		end
		expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
		expect(injected).to.equal(true)
		expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
		expect(recipientData.Coins.Get()).to.equal(10)
		expect(stored(h).Coins).to.equal(0)
	end)

	it("honours completion saved after the offline view without delivering again", function()
		local h, _, recipientData = prepare(true, "PendingGifts", record())
		local update = h.Ctx.Persistence.UpdateOffline
		local injected = false
		h.Ctx.Persistence.UpdateOffline = function(userId, fn, ...)
			if userId == BUYER and not injected then
				injected = true
				stored(h)._Scribe.PendingGifts["101"] = { Ts = NOW }
				stored(h)._Scribe.ProcessedPurchaseIds = { { Id = "paid", At = NOW } }
			end
			return update(userId, fn, ...)
		end
		expect(h.Data.HandleReceipt(receipt())).to.equal(GRANTED)
		expect(injected).to.equal(true)
		expect(recipientData.Coins.Get()).to.equal(0)
		expect(next(stored(h)._Scribe.ReceiptReservations)).to.equal(nil)
		expect(stored(h).Coins).to.equal(0)
	end)
end
