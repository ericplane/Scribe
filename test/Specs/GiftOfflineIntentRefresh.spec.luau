--!nonstrict
-- F3's CONSEQUENCE SPEC: the offline receipt arm refreshes a retrying intent's Ts,
-- under the same GiftId guard the online arm carries.
--
-- A gift intent's age is measured on WALL time, because the stamp is persisted and
-- read back in a later session. So giftIntentTTL keeps running while Roblox retries
-- a receipt, and a retry cadence slower than the TTL burns through it. The ONLINE
-- failure arm has always re-stamped the intent for exactly that reason; the OFFLINE
-- arm did not, so an offline buyer's gift died at the TTL: the next attempt ignored
-- the intent, fell into the no-intent policy, granted the perk to the BUYER and
-- answered PurchaseGranted. Roblox then stops retrying, and the paid gift is gone.
--
-- The two traps this spec exists to hold shut:
--   * the refresh is NOT a bare field write. Offline there is no accessor tree to
--     raise on a write into an absent slot, so `PendingGifts[id].Ts = now` on a slot
--     cleared during the delivery yield materialises a phantom {Ts} intent with no
--     RecipientId and no GiftId -- read later as userId 0 and delivered there.
--   * identity is the GiftId. A slot taken over by a SECOND gift during the yield
--     is not ours to re-stamp; extending it would make the newer intent look older
--     than it is to the next reader.
--
-- SCOPE: this does NOT fix F1. The refresh only helps while the retry cadence is
-- shorter than the TTL; a retry that arrives after the TTL has already lapsed still
-- finds no intent, and the TTL double-grant is a separate problem needing a durable
-- per-purchaseId record.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local BUYER = 92001
	local RECIPIENT = 92002

	local function makeHarness(extraOptions)
		local options = {
			Products = {
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
			},
			GiftCooldown = 0,
			GiftIntentTTL = 300,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(purchaseId)
		return {
			PlayerId = BUYER,
			ProductId = 222,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	local function withClock(startAt: number, body: (advance: (n: number) -> ()) -> ())
		local now = startAt
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
		})
		local ok, err = pcall(body, function(n: number)
			now += n
		end)
		Clock.Reset()
		if not ok then
			error(err, 0)
		end
	end

	local function keyOf(harness, userId: number): string
		return "Default/" .. harness.Ctx.Persistence.KeyFor(userId)
	end

	--- The buyer's PERSISTED reserved root. The offline arm never touches a live
	--- tree, so this is the only place its work is visible.
	local function storedReserved(harness)
		return harness.Fake.Persisted[keyOf(harness, BUYER)]._Scribe
	end

	local function storedSlot(harness): any
		return storedReserved(harness).PendingGifts["222"]
	end

	--- Every slot that exists must carry BOTH halves of an intent's identity; a slot
	--- missing either is a phantom that later resolves to userId 0.
	local function census(reserved): string
		local out = {}
		for productIdStr, intent in reserved.PendingGifts do
			if type(intent) ~= "table" then
				table.insert(out, productIdStr .. "=NOT_A_TABLE")
			elseif intent.RecipientId == nil or intent.GiftId == nil then
				table.insert(out, productIdStr .. "=PHANTOM")
			else
				table.insert(out, productIdStr)
			end
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	--- The one seam that reaches into a cross-server delivery. `hook` returns true to
	--- let the send through, false to fail it -- and `false` is what puts the receipt
	--- on the failure arm this spec is about.
	local function interceptDelivery(harness, hook: (key: string, message: any) -> boolean)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function(selfStore, key, message)
			if hook(key, message) then
				return real(selfStore, key, message)
			end
			return false
		end
		return function()
			store.MessageAsync = real
		end
	end

	--- Seed a buyer with a live gift intent and leave them offline, so every receipt
	--- afterwards takes handleOfflineReceipt.
	local function seedOfflineBuyer(harness): string
		local buyer = harness.Join(BUYER)
		expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)
		harness.Data.Flush(buyer)
		harness.Leave(buyer)
		return tostring(storedSlot(harness).GiftId)
	end

	it("re-stamps the intent on every failed offline retry, so the TTL cannot outrun them", function()
		-- The measured timeline, offline: retries at t=0, t=200, t=400 against a
		-- GiftIntentTTL of 300. Delivery is down until the last one. Each failure has
		-- to carry the intent forward, or the third attempt finds a 400s-old record.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			seedOfflineBuyer(harness)
			expect(storedSlot(harness).Ts).to.equal(1700000000)

			local stamps = {}
			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt("f3-a"))).to.equal(NOT_PROCESSED)
			table.insert(stamps, storedSlot(harness).Ts)

			advance(200)
			expect(harness.Data.HandleReceipt(receipt("f3-a"))).to.equal(NOT_PROCESSED)
			table.insert(stamps, storedSlot(harness).Ts)

			advance(200)
			harness.Fake.FailMessages = false
			local final = harness.Data.HandleReceipt(receipt("f3-a"))

			local reserved = storedReserved(harness)
			expect(
				("stamps=%d,%d final=%s queued=%d buyerVIP=%s pending=[%s]"):format(
					stamps[1],
					stamps[2],
					if final == GRANTED then "GRANTED" else "NOT_PROCESSED",
					#(harness.Fake.Mailboxes[keyOf(harness, RECIPIENT)] or {}),
					tostring(reserved.Perks.VIP == true),
					census(reserved)
				)
			).to.equal("stamps=1700000000,1700000200 final=GRANTED queued=1 buyerVIP=false pending=[]")

			harness.Cleanup()
		end)
	end)

	it("matches the online arm stamp for stamp on that same timeline", function()
		-- The online arm's refresh is the thing being mirrored, so it is asserted here
		-- too: a future change that flattens the two arms must not be free to flatten
		-- them toward the broken one.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			local buyer, entry = harness.Join(BUYER)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)

			local function liveTs(): number
				return entry.LiveData._Scribe.PendingGifts["222"].Ts
			end

			local stamps = {}
			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt("f3-b"))).to.equal(NOT_PROCESSED)
			table.insert(stamps, liveTs())

			advance(200)
			expect(harness.Data.HandleReceipt(receipt("f3-b"))).to.equal(NOT_PROCESSED)
			table.insert(stamps, liveTs())

			advance(200)
			harness.Fake.FailMessages = false
			local final = harness.Data.HandleReceipt(receipt("f3-b"))
			harness.Data.Flush(buyer)

			local reserved = storedReserved(harness)
			expect(
				("stamps=%d,%d final=%s queued=%d buyerVIP=%s pending=[%s]"):format(
					stamps[1],
					stamps[2],
					if final == GRANTED then "GRANTED" else "NOT_PROCESSED",
					#(harness.Fake.Mailboxes[keyOf(harness, RECIPIENT)] or {}),
					tostring(reserved.Perks.VIP == true),
					census(reserved)
				)
			).to.equal("stamps=1700000000,1700000200 final=GRANTED queued=1 buyerVIP=false pending=[]")

			harness.Cleanup()
		end)
	end)

	it("cannot materialise a phantom when the slot is cleared during the delivery yield", function()
		-- THE TRAP. A bare `PendingGifts[id].Ts = now` here writes `{Ts = n}` into a
		-- slot nobody owns -- no RecipientId, no GiftId -- and offline there is no
		-- accessor to raise on it. A later retry reads `tonumber(RecipientId) or 0`
		-- and MessageAsyncs the paid gift to the DataStore key for userId 0.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			seedOfflineBuyer(harness)

			advance(100)
			local restore = interceptDelivery(harness, function()
				-- Another server settles the gift while this delivery is in flight.
				storedReserved(harness).PendingGifts["222"] = nil
				return false -- ...and this delivery fails, so the refresh arm runs
			end)
			expect(harness.Data.HandleReceipt(receipt("f3-phantom"))).to.equal(NOT_PROCESSED)
			restore()

			expect(
				("pending=[%s] zeroBox=%d"):format(
					census(storedReserved(harness)),
					#(harness.Fake.Mailboxes[keyOf(harness, 0)] or {})
				)
			).to.equal("pending=[] zeroBox=0")

			harness.Cleanup()
		end)
	end)

	it("leaves a slot alone once a SECOND gift has taken it over mid-flight", function()
		-- Identity is the GiftId, not the address. Re-stamping the newer intent would
		-- extend a stranger's escrow and teach the next reader it is fresher than it
		-- is -- which is what keeps PromptGift's overwrite window honest.
		withClock(1700000000, function(advance)
			local harness = makeHarness({ GiftIntentTTL = 3600 })
			local giftA = seedOfflineBuyer(harness)

			advance(200)
			local restore = interceptDelivery(harness, function()
				storedReserved(harness).PendingGifts["222"] = {
					RecipientId = 92003,
					GiftId = "gift-B",
					Ts = 1700000150,
					Product = "GiftVIP",
				}
				return false
			end)
			expect(harness.Data.HandleReceipt(receipt("f3-reassigned"))).to.equal(NOT_PROCESSED)
			restore()

			local live = storedSlot(harness)
			expect(
				("giftA=%s gift=%s to=%s ts=%s"):format(
					tostring(giftA ~= "gift-B"),
					tostring(live.GiftId),
					tostring(live.RecipientId),
					tostring(live.Ts)
				)
			).to.equal("giftA=true gift=gift-B to=92003 ts=1700000150")

			harness.Cleanup()
		end)
	end)

	it("is best effort: a refused offline write leaves the arm exactly as it was", function()
		-- The refresh must never change the ANSWER. NotProcessedYet is always safe and
		-- is what the arm returned before; a DataStore fault on the re-stamp degrades
		-- to precisely the old behaviour rather than to a new failure mode.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			seedOfflineBuyer(harness)

			advance(100)
			local restore = interceptDelivery(harness, function()
				harness.Fake.FailSaves = true -- the re-stamp's UpdateOffline will fail
				return false
			end)
			local decision = harness.Data.HandleReceipt(receipt("f3-nowrite"))
			restore()
			harness.Fake.FailSaves = false

			local reserved = storedReserved(harness)
			expect(
				("d=%s ts=%s pending=[%s] processed=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(storedSlot(harness).Ts),
					census(reserved),
					tostring(#(reserved.ProcessedPurchaseIds or {}))
				)
			).to.equal("d=NOT_PROCESSED ts=1700000000 pending=[222] processed=0")

			harness.Cleanup()
		end)
	end)

	it("does not re-stamp, or fail, when the buyer rejoins during the delivery yield", function()
		-- UpdateOffline refuses outright while a session for that user is live on this
		-- server. The refresh has to tolerate that: the buyer is back, so the ONLINE
		-- arm owns their next retry, and the intent is still inside its TTL.
		withClock(1700000000, function(advance)
			local harness = makeHarness()
			seedOfflineBuyer(harness)

			advance(100)
			local restore = interceptDelivery(harness, function()
				harness.Join(BUYER)
				return false
			end)
			local decision = harness.Data.HandleReceipt(receipt("f3-rejoin"))
			restore()

			local entry = harness.Ctx.Persistence.EntryForUserId(BUYER)
			expect(
				("d=%s live=%s ts=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(entry ~= nil),
					tostring(entry and entry.LiveData._Scribe.PendingGifts["222"].Ts)
				)
			).to.equal("d=NOT_PROCESSED live=true ts=1700000000")

			harness.Cleanup()
		end)
	end)

	it("still answers NotProcessedYet without granting the buyer anything", function()
		-- The whole point of the refresh is that the receipt keeps retrying. It must
		-- not have become a grant, a credit, or a processed marker along the way.
		withClock(1700000000, function()
			local harness = makeHarness()
			seedOfflineBuyer(harness)

			harness.Fake.FailMessages = true
			local decision = harness.Data.HandleReceipt(receipt("f3-answer"))
			harness.Fake.FailMessages = false

			local reserved = storedReserved(harness)
			local credits = 0
			for _, count in reserved.GiftCredits do
				credits += tonumber(count) or 0
			end
			expect(
				("d=%s vip=%s credits=%d processed=%d queued=%d"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(reserved.Perks.VIP == true),
					credits,
					#(reserved.ProcessedPurchaseIds or {}),
					#(harness.Fake.Mailboxes[keyOf(harness, RECIPIENT)] or {})
				)
			).to.equal("d=NOT_PROCESSED vip=false credits=0 processed=0 queued=0")

			harness.Cleanup()
		end)
	end)
end
