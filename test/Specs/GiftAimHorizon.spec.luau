--!nonstrict
-- THE DURABLE GIFT AIM: its own contract, measured.
--
-- GiftIntentHorizon.spec is the net for the DEFECT (F1: one payment, two grants,
-- because the load sweep deleted the only record of who a gift was aimed at). This
-- file is the net for the MECHANISM that closed it, and everything the mechanism
-- must not become. Nothing here is a characterisation of a defect: every block is
-- behaviour that must stay true.
--
-- THE SHAPE, in one paragraph. A stale intent is no longer deleted at load; it is
-- MOVED into `_Scribe.GiftAims`, keyed by product Id, carrying the recipient, the
-- GiftId, the product name and the ORIGINAL prompt timestamp. When a receipt lands
-- with no live intent, two questions are asked before the buyer can be granted:
--
--   PROOF       -- is this exact PurchaseId already in the recipient's dedupe ring?
--                  A self-purchase's id can never be, so a hit is not a guess. NO
--                  CLOCK: it holds at any age, and it is what stops the double
--                  grant coming back on day eight.
--   PRESUMPTION -- no proof, but an ARCHIVED aim says a gift of this product was
--                  aimed somewhere and never settled, so this receipt is presumed
--                  to be it. A guess, so it is bounded: archived aims only, and
--                  only inside giftAimTTL.
--
-- THE THREE THINGS MOST WORTH BREAKING, and each has a block below:
--   1. the presumption escaping its bounds -- onto a STALE SLOT still in hand
--      (which this library has always called an abandoned prompt), or past the
--      horizon. Both would misroute ordinary self-purchases.
--   2. the proof acquiring a clock, which puts F1-A back for a late retry.
--   3. the store evicting a LIVE aim to make room, which is the receipt ring's
--      documented count-eviction flaw rebuilt in a new container.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Metrics = require(Root.Scribe.Internal.Metrics)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

	local BUYER = 94201
	local RECIPIENT = 94202
	local T0 = 1700000000

	local INTENT_TTL = 3600 -- the default, unchanged by this work
	-- The aim's presumption horizon: max(7 days, PurchaseIdTTL), and PurchaseIdTTL
	-- defaults to 7 days. Spelled out rather than imported so a silent change to
	-- either constant fails here instead of passing quietly.
	local AIM_TTL = 7 * 24 * 3600
	local AIM_CAP = 64

	local function makeHarness(extraOptions, products)
		local options = {
			Products = products or {
				Coins1000 = {
					Id = 111,
					Category = "Currency",
					Grant = function(data)
						data.Coins.Increment(1000)
					end,
				},
				GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
				GiftPRO = { Id = 333, Category = "Gamepass", Grants = "PRO" },
			},
			GiftCooldown = 0,
			PromptProductPurchase = function() end,
		}
		for key, value in extraOptions or {} do
			options[key] = value
		end
		return TestCtx.make({ Options = options })
	end

	local function receipt(productId: number, purchaseId: string, userId: number?)
		return {
			PlayerId = userId or BUYER,
			ProductId = productId,
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

	local function storedReserved(harness, userId: number)
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		return (profile and profile._Scribe) or {}
	end

	local function mailbox(harness, userId: number): number
		return #(harness.Fake.Mailboxes[keyOf(harness, userId)] or {})
	end

	local function owns(reserved, perk: string): boolean
		return type(reserved.Perks) == "table" and reserved.Perks[perk] == true
	end

	local function coinsOf(harness, userId: number): number
		local profile = harness.Fake.Persisted[keyOf(harness, userId)]
		return tonumber(profile and profile.Coins) or 0
	end

	local function ledger(reserved): string
		local out = {}
		for _, line in (reserved.PurchaseLogs and reserved.PurchaseLogs.Robux) or {} do
			table.insert(out, tostring(line.From and line.From.Type))
		end
		return table.concat(out, ",")
	end

	--- Every archived aim, as `productId->recipientId`, sorted.
	local function aimsOf(reserved): string
		local out = {}
		for productIdStr, aim in reserved.GiftAims or {} do
			table.insert(out, `{productIdStr}->{tostring(type(aim) == "table" and aim.RecipientId or "?")}`)
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	local function aimCount(reserved): number
		local n = 0
		for _ in reserved.GiftAims or {} do
			n += 1
		end
		return n
	end

	--- One-shot seam into the cross-server delivery, so a spec can sever the BUYER's
	--- leg at the exact moment the recipient's has committed.
	local function onceOnDelivery(harness, hook: (key: string, message: any) -> boolean)
		local store = harness.Ctx.Persistence.Store
		local real = store.MessageAsync
		store.MessageAsync = function(selfStore, key, message)
			store.MessageAsync = real
			if hook(key, message) then
				return real(selfStore, key, message)
			end
			return false
		end
		return function()
			store.MessageAsync = real
		end
	end

	local function armGiftAndLeave(harness, productName: string, recipientId: number?)
		local buyer = harness.Join(BUYER)
		expect(harness.Data.PromptGift(buyer, productName, recipientId or RECIPIENT)).to.equal(true)
		harness.Data.Flush(buyer)
		harness.Leave(buyer)
	end

	local function recipientCollects(harness, userId: number?)
		local player = harness.Join(userId or RECIPIENT)
		harness.Data.Flush(player)
		harness.Leave(player)
	end

	--------------------------------------------------------------------------------
	-- THE THREE F1 TIMELINES AS FUNCTIONS OF AGE.
	-- The whole point of the fix is that these stop depending on the age at all
	-- (inside the horizon), so they are written once and called at several ages.
	--------------------------------------------------------------------------------

	--- F1-A: the ONLINE retry. Delivery committed, the buyer's commit did not, the
	--- buyer rejoins (so the sweep archives the aim) and Roblox retries.
	local function onlineRetryAfter(age: number): string
		local out
		withClock(T0, function(advance)
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			expect(harness.Data.PromptGift(buyer, "Coins1000", RECIPIENT)).to.equal(true)
			harness.Data.Flush(buyer)

			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			harness.Data.HandleReceipt(receipt(111, "aim-a"))
			restore()
			harness.Leave(buyer)
			harness.Fake.FailSaves = false

			recipientCollects(harness)
			advance(age)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(111, "aim-a"))
			harness.Data.Flush(rejoined)

			out = ("d=%s buyerCoins=%d rcpCoins=%d total=%d ledger=[%s]"):format(
				if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
				coinsOf(harness, BUYER),
				coinsOf(harness, RECIPIENT),
				coinsOf(harness, BUYER) + coinsOf(harness, RECIPIENT),
				ledger(storedReserved(harness, BUYER))
			)
			harness.Cleanup()
		end)
		return out
	end

	--- F1-B: the OFFLINE retry. Same split, but the buyer never comes back, so
	--- nothing is ever archived and the stale intent is still in its slot.
	local function offlineRetryAfter(age: number): string
		local out
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			harness.Data.HandleReceipt(receipt(222, "aim-b"))
			restore()
			harness.Fake.FailSaves = false

			recipientCollects(harness)
			advance(age)
			local decision = harness.Data.HandleReceipt(receipt(222, "aim-b"))

			out = ("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s]"):format(
				if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
				tostring(owns(storedReserved(harness, BUYER), "VIP")),
				tostring(owns(storedReserved(harness, RECIPIENT), "VIP")),
				ledger(storedReserved(harness, BUYER))
			)
			harness.Cleanup()
		end)
		return out
	end

	--- F1-C: no failure anywhere. The buyer arms, flushes, leaves, rejoins, and only
	--- then does Roblox invoke ProcessReceipt for the first time.
	local function deferredReceiptAfter(age: number): string
		local out
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(age)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "aim-c"))
			harness.Data.Flush(rejoined)

			out = ("d=%s buyerVIP=%s queued=%d ledger=[%s] aims=[%s]"):format(
				if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
				tostring(owns(storedReserved(harness, BUYER), "VIP")),
				mailbox(harness, RECIPIENT),
				ledger(storedReserved(harness, BUYER)),
				aimsOf(storedReserved(harness, BUYER))
			)
			harness.Cleanup()
		end)
		return out
	end

	--------------------------------------------------------------------------------
	-- 1. THE BOUNDARY. The two seconds that used to decide everything.
	--------------------------------------------------------------------------------

	describe("the intent TTL is no longer a cliff", function()
		it("settles the ONLINE retry identically on both sides of GiftIntentTTL", function()
			-- A fix proven in the middle of the window is not proven. These are the
			-- exact ages the defect discriminated on, and the answers must now match
			-- each other AND the literal -- agreeing on the wrong answer is not a fix.
			local inside = onlineRetryAfter(INTENT_TTL - 1)
			local past = onlineRetryAfter(INTENT_TTL + 1)
			expect(("%s | %s"):format(inside, past)).to.equal(
				"d=GRANTED buyerCoins=0 rcpCoins=1000 total=1000 ledger=[GiftSent] "
					.. "| d=GRANTED buyerCoins=0 rcpCoins=1000 total=1000 ledger=[GiftSent]"
			)
		end)

		it("settles the OFFLINE retry identically on both sides of GiftIntentTTL", function()
			local inside = offlineRetryAfter(INTENT_TTL - 1)
			local past = offlineRetryAfter(INTENT_TTL + 1)
			expect(("%s | %s"):format(inside, past)).to.equal(
				"d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent] "
					.. "| d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent]"
			)
		end)

		it("delivers a clean deferred receipt identically on both sides, and ON the boundary", function()
			-- The exact second is included because `>` and `>=` are one keystroke
			-- apart in both the sweep and the horizon comparison.
			local inside = deferredReceiptAfter(INTENT_TTL - 1)
			local exact = deferredReceiptAfter(INTENT_TTL)
			local past = deferredReceiptAfter(INTENT_TTL + 1)
			expect(inside == exact and exact == past).to.equal(true)
			expect(past).to.equal("d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aims=[]")
		end)
	end)

	--------------------------------------------------------------------------------
	-- 2. THE PRESUMPTION HORIZON, and which way it fails past it.
	--------------------------------------------------------------------------------

	describe("the presumption horizon", function()
		it("still delivers a deferred receipt a day, and six days, after the prompt", function()
			expect(("%s | %s"):format(deferredReceiptAfter(86400), deferredReceiptAfter(6 * 86400))).to.equal(
				"d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aims=[] "
					.. "| d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aims=[]"
			)
		end)

		it("holds to the last second of the horizon and lapses on the next one", function()
			-- THE NEW BOUNDARY, pinned as sharply as the old one. Past it the receipt
			-- is GRANTED to the buyer -- never refused. Refusing would be a permanent
			-- NotProcessedYet, which eats the player's Robux, and this module's
			-- standing rule is that value may go to the wrong player but is never
			-- destroyed. The aim is left behind rather than deleted, still naming the
			-- recipient, because it can still PROVE a delivery (see below) and because
			-- it is what an operator compensates from.
			expect(("%s | %s"):format(deferredReceiptAfter(AIM_TTL), deferredReceiptAfter(AIM_TTL + 1))).to.equal(
				"d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aims=[] "
					.. "| d=GRANTED buyerVIP=true queued=0 ledger=[Purchase] aims=[222->94202]"
			)
		end)

		it("PROOF carries no horizon at all, so the double grant cannot come back on day eight", function()
			-- The sharpest asymmetry in the design, and the one a "tidying" change
			-- would flatten first. Presumption is a GUESS about which purchase a
			-- receipt belongs to, so it expires. Proof is a PurchaseId match in the
			-- recipient's own dedupe ring, which no self-purchase can forge, so it
			-- does not. Give proof the horizon too and this line reads
			-- `buyerCoins=1000 ... total=2000` again -- F1-A, eight days late.
			expect(onlineRetryAfter(8 * 86400)).to.equal(
				"d=GRANTED buyerCoins=0 rcpCoins=1000 total=1000 ledger=[GiftSent]"
			)
			expect(offlineRetryAfter(8 * 86400)).to.equal("d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent]")
		end)
	end)

	--------------------------------------------------------------------------------
	-- 3. WHAT THE PRESUMPTION MAY NOT DO.
	--------------------------------------------------------------------------------

	describe("the presumption stays inside its bounds", function()
		it("a STALE SLOT still in hand is an abandoned prompt, not an aim -- online", function()
			-- The rule this library has always applied, and which Receipts.spec,
			-- GiftArmParity row 2 and GiftIntentNet all pin from their own angles: a
			-- buyer who sat through the whole intent TTL, online, with no receipt has
			-- abandoned the prompt, and the receipt that arrives afterwards is a new
			-- purchase. Nothing is archived here -- no load ever happened -- so there
			-- is no aim, and the slot in hand does not earn one.
			withClock(T0, function(advance)
				local harness = makeHarness()
				local buyer = harness.Join(BUYER)
				expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)
				harness.Data.Flush(buyer)

				advance(INTENT_TTL + 1)
				local decision = harness.Data.HandleReceipt(receipt(222, "abandoned-online"))
				harness.Data.Flush(buyer)

				local reserved = storedReserved(harness, BUYER)
				expect(
					("d=%s buyerVIP=%s queued=%d ledger=[%s] aims=[%s]"):format(
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						mailbox(harness, RECIPIENT),
						ledger(reserved),
						aimsOf(reserved)
					)
				).to.equal("d=GRANTED buyerVIP=true queued=0 ledger=[Purchase] aims=[]")

				harness.Cleanup()
			end)
		end)

		it("a STALE SLOT still in hand is an abandoned prompt, not an aim -- offline", function()
			-- Arm parity. The arm a receipt takes is decided by whether the buyer
			-- happens to still be on this server, which is not a fact about the
			-- purchase, so the two must answer alike.
			withClock(T0, function(advance)
				local harness = makeHarness()
				armGiftAndLeave(harness, "GiftVIP")

				advance(INTENT_TTL + 1)
				local decision = harness.Data.HandleReceipt(receipt(222, "abandoned-offline"))

				local reserved = storedReserved(harness, BUYER)
				expect(
					("d=%s buyerVIP=%s queued=%d ledger=[%s] aims=[%s]"):format(
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						mailbox(harness, RECIPIENT),
						ledger(reserved),
						aimsOf(reserved)
					)
				).to.equal("d=GRANTED buyerVIP=true queued=0 ledger=[Purchase] aims=[]")

				harness.Cleanup()
			end)
		end)

		it("an aim for one product never touches a receipt for another", function()
			withClock(T0, function(advance)
				local harness = makeHarness()
				armGiftAndLeave(harness, "GiftVIP")

				advance(INTENT_TTL + 1)
				local rejoined = harness.Join(BUYER) -- sweeps 222 into the aim store
				local decision = harness.Data.HandleReceipt(receipt(333, "other-product"))
				harness.Data.Flush(rejoined)

				local reserved = storedReserved(harness, BUYER)
				expect(
					("d=%s pro=%s queued=%d aims=[%s]"):format(
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "PRO")),
						mailbox(harness, RECIPIENT),
						aimsOf(reserved)
					)
				).to.equal("d=GRANTED pro=true queued=0 aims=[222->94202]")

				harness.Cleanup()
			end)
		end)

		it("an aim is spent by the receipt that claims it, so the NEXT purchase is the buyer's", function()
			-- One aim, one receipt. Without the clear, every later self-purchase of
			-- that product would be routed to the same stale recipient for as long as
			-- the horizon lasts -- an aim that fires once is a bounded misroute, an aim
			-- that fires forever is a broken product.
			withClock(T0, function(advance)
				local harness = makeHarness()
				armGiftAndLeave(harness, "GiftVIP")

				advance(INTENT_TTL + 1)
				local rejoined = harness.Join(BUYER)
				expect(harness.Data.HandleReceipt(receipt(222, "claims-the-aim"))).to.equal(GRANTED)
				local afterFirst = aimsOf(storedReserved(harness, BUYER))

				local decision = harness.Data.HandleReceipt(receipt(222, "buyers-own"))
				harness.Data.Flush(rejoined)

				local reserved = storedReserved(harness, BUYER)
				expect(
					("aimsAfterFirst=[%s] d=%s buyerVIP=%s queued=%d ledger=[%s]"):format(
						afterFirst,
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						mailbox(harness, RECIPIENT),
						ledger(reserved)
					)
				).to.equal("aimsAfterFirst=[] d=GRANTED buyerVIP=true queued=1 ledger=[GiftSent,Purchase]")

				harness.Cleanup()
			end)
		end)

		it("a retired product reusing the Id does not inherit the old aim", function()
			-- The same guard intentFor makes on a live intent. The aim stores the
			-- product NAME, and a mismatch means the recipient was aimed at something
			-- else entirely; honouring it would ship the new product to them.
			withClock(T0, function(advance)
				local harness = makeHarness()
				armGiftAndLeave(harness, "GiftVIP")

				advance(INTENT_TTL + 1)
				local rejoined = harness.Join(BUYER)
				-- The deploy that retired GiftVIP and gave 222 to something else.
				rejoined = rejoined
				local reservedLive = harness.Ctx.Persistence.EntryFor(rejoined).LiveData._Scribe
				reservedLive.GiftAims["222"].Product = "RetiredCoinPack"

				local decision = harness.Data.HandleReceipt(receipt(222, "reused-id"))
				harness.Data.Flush(rejoined)

				local reserved = storedReserved(harness, BUYER)
				expect(
					("d=%s buyerVIP=%s queued=%d ledger=[%s]"):format(
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						mailbox(harness, RECIPIENT),
						ledger(reserved)
					)
				).to.equal("d=GRANTED buyerVIP=true queued=0 ledger=[Purchase]")

				harness.Cleanup()
			end)
		end)
	end)

	describe("a phantom never becomes an aim, and an aim is never a phantom", function()
		-- A phantom is the `{ Ts = n }` shape a blind timestamp write leaves in a slot:
		-- no RecipientId, no GiftId. GiftIntentNet pins what honouring one costs -- a
		-- paid gift MessageAsync'd to the DataStore key for userId 0, with the receipt
		-- answering PurchaseGranted. The aim store adds a second door into that, and
		-- both sides of it are shut: the sweep will not archive a phantom, and the
		-- reader will not honour one it somehow finds.

		it("the sweep refuses to archive an incomplete intent", function()
			withClock(T0, function(advance)
				local harness = makeHarness()
				local buyer, entry = harness.Join(BUYER)
				entry.Tree.Reserved.PendingGifts["222"].Set({ Ts = Clock.Now() })
				harness.Data.Flush(buyer)
				harness.Leave(buyer)

				advance(INTENT_TTL + 1)
				local rejoined = harness.Join(BUYER) -- the sweep runs on this load
				local decision = harness.Data.HandleReceipt(receipt(222, "phantom-swept"))
				harness.Data.Flush(rejoined)

				local zeroKey = "Default/" .. harness.Ctx.Persistence.KeyFor(0)
				local reserved = storedReserved(harness, BUYER)
				expect(
					("aims=[%s] d=%s buyerVIP=%s toUserZero=%d"):format(
						aimsOf(reserved),
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						#(harness.Fake.Mailboxes[zeroKey] or {})
					)
				).to.equal("aims=[] d=GRANTED buyerVIP=true toUserZero=0")

				harness.Cleanup()
			end)
		end)

		it("a phantom sitting in the aim store is not honoured", function()
			-- Planted directly, because with the sweep's guard intact there is no
			-- reachable way to MAKE one -- exactly as GiftIntentNet plants its phantom
			-- intent. This is the guard for a store written by an older deploy, a
			-- migration, or a future caller.
			withClock(T0, function()
				local harness = makeHarness()
				local buyer, entry = harness.Join(BUYER)
				entry.Tree.Reserved.GiftAims["222"].Set({ Ts = Clock.Now(), Product = "GiftVIP" })

				local decision = harness.Data.HandleReceipt(receipt(222, "phantom-aim"))
				harness.Data.Flush(buyer)

				local zeroKey = "Default/" .. harness.Ctx.Persistence.KeyFor(0)
				local reserved = storedReserved(harness, BUYER)
				expect(
					("d=%s buyerVIP=%s toUserZero=%d ledger=[%s]"):format(
						if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
						tostring(owns(reserved, "VIP")),
						#(harness.Fake.Mailboxes[zeroKey] or {}),
						ledger(reserved)
					)
				).to.equal("d=GRANTED buyerVIP=true toUserZero=0 ledger=[Purchase]")

				harness.Cleanup()
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- 4. DURABILITY. The aim is worth nothing if it does not survive the session.
	--------------------------------------------------------------------------------

	it("PROOF settles a stale slot the buyer is STILL ONLINE for, with no aim involved", function()
		-- The arm nothing else reaches, and it is a real timeline rather than a
		-- constructed one: the intent is FRESH at load (so the sweep leaves it alone
		-- and no aim is ever created) and crosses the TTL later in the same session,
		-- with the gift already delivered and the buyer's own commit lost. The slot in
		-- hand cannot be PRESUMED on -- that is the abandoned-prompt rule -- so what
		-- has to save this receipt is the proof leg reading the recipient's ring.
		--
		-- Read the slot BEFORE intentFor rather than after and this goes red: intentFor
		-- clears the slot as it expires it, and the recipient's identity leaves with it.
		withClock(T0, function(advance)
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)
			harness.Data.Flush(buyer)

			-- Delivery commits; the buyer's leg is severed and stays severed through
			-- the session end, so the cleared intent never reaches disk.
			local restore = onceOnDelivery(harness, function()
				harness.Fake.FailSaves = true
				return true
			end)
			expect(harness.Data.HandleReceipt(receipt(222, "still-online"))).to.equal(NOT_PROCESSED)
			restore()
			harness.Leave(buyer)
			harness.Fake.FailSaves = false

			recipientCollects(harness)

			-- Back inside the TTL, so the sweep leaves the intent in its slot.
			advance(60)
			local rejoined = harness.Join(BUYER)
			expect(aimsOf(storedReserved(harness, BUYER))).to.equal("")
			-- ...and it goes stale while they are sitting here.
			advance(INTENT_TTL + 1)
			local decision = harness.Data.HandleReceipt(receipt(222, "still-online"))
			harness.Data.Flush(rejoined)

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s rcpVIP=%s ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(reserved, "VIP")),
					tostring(owns(storedReserved(harness, RECIPIENT), "VIP")),
					ledger(reserved)
				)
			).to.equal("d=GRANTED buyerVIP=false rcpVIP=true ledger=[GiftSent]")

			harness.Cleanup()
		end)
	end)

	it("a failed delivery refreshes the AIM's stamp, so retries cannot run it past the horizon", function()
		-- The aim inherits the problem the intent had (F3): its age is measured on WALL
		-- time, which keeps running while Roblox retries. Without the refresh a gift
		-- that is actively retrying crosses the horizon mid-flight, the presumption
		-- lapses, and the next attempt hands the perk to the buyer and answers
		-- PurchaseGranted -- so Roblox stops retrying and the paid gift is gone. The
		-- refresh is guarded on the GiftId and writes into the AIM's container, not the
		-- intent slot the aim no longer occupies.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER) -- archived, stamped at the prompt time

			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt(222, "retrying"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailMessages = false

			-- Just inside the horizon measured from the REFRESH, and past it measured
			-- from the prompt.
			advance(AIM_TTL - 10)
			local decision = harness.Data.HandleReceipt(receipt(222, "retrying"))
			harness.Data.Flush(rejoined)

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s queued=%d ledger=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(reserved, "VIP")),
					mailbox(harness, RECIPIENT),
					ledger(reserved)
				)
			).to.equal("d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent]")

			harness.Cleanup()
		end)
	end)

	it("the OFFLINE arm refreshes the aim's stamp too, through its compare-and-set", function()
		-- Arm parity for the refresh. Offline there is no accessor tree to raise on a
		-- write into the wrong container or into an absent slot, so this is the arm
		-- where getting it wrong is silent.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER)
			harness.Data.Flush(rejoined)
			harness.Leave(rejoined)

			harness.Fake.FailMessages = true
			expect(harness.Data.HandleReceipt(receipt(222, "retrying-offline"))).to.equal(NOT_PROCESSED)
			harness.Fake.FailMessages = false

			advance(AIM_TTL - 10)
			local decision = harness.Data.HandleReceipt(receipt(222, "retrying-offline"))

			local reserved = storedReserved(harness, BUYER)
			expect(
				("d=%s buyerVIP=%s queued=%d ledger=[%s] aims=[%s]"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(reserved, "VIP")),
					mailbox(harness, RECIPIENT),
					ledger(reserved),
					aimsOf(reserved)
				)
			).to.equal("d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aims=[]")

			harness.Cleanup()
		end)
	end)

	it("the aim reaches disk at the sweep and settles a receipt a whole session later, OFFLINE", function()
		-- The production shape, and the one nothing else measures: the sweep archives
		-- during session N, the buyer leaves, and Roblox invokes ProcessReceipt while
		-- they are offline. The offline arm has to read the aim off the profile it
		-- already fetched -- no live tree, no accessor.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER)
			harness.Data.Flush(rejoined)
			local onDisk = aimsOf(storedReserved(harness, BUYER))
			harness.Leave(rejoined)

			advance(600)
			local decision = harness.Data.HandleReceipt(receipt(222, "cross-session"))

			local reserved = storedReserved(harness, BUYER)
			expect(
				("onDisk=[%s] d=%s buyerVIP=%s queued=%d ledger=[%s] aimsAfter=[%s]"):format(
					onDisk,
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(reserved, "VIP")),
					mailbox(harness, RECIPIENT),
					ledger(reserved),
					aimsOf(reserved)
				)
			).to.equal("onDisk=[222->94202] d=GRANTED buyerVIP=false queued=1 ledger=[GiftSent] aimsAfter=[]")

			harness.Cleanup()
		end)
	end)

	it("the sweep archives the aim without costing the buyer gift capacity", function()
		-- The slot still has to be reclaimed. GiftMaxPending counts PendingGifts and
		-- must not start counting aims, or a player who abandons prompts loses the
		-- ability to gift for the whole horizon rather than the intent TTL.
		withClock(T0, function(advance)
			local harness = makeHarness({ GiftMaxPending = 1 })
			armGiftAndLeave(harness, "GiftVIP")

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER)
			local ok, reason = harness.Data.PromptGift(rejoined, "GiftPRO", RECIPIENT)
			harness.Data.Flush(rejoined)

			expect(
				("regift=%s/%s aims=[%s]"):format(
					tostring(ok),
					tostring(reason),
					aimsOf(storedReserved(harness, BUYER))
				)
			).to.equal("regift=true/nil aims=[222->94202]")

			harness.Cleanup()
		end)
	end)

	it("the settlement names the recipient in the buyer's ledger, so it is reconcilable", function()
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP")

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER)
			expect(harness.Data.HandleReceipt(receipt(222, "traceable"))).to.equal(GRANTED)
			harness.Data.Flush(rejoined)

			local line
			for _, entry in storedReserved(harness, BUYER).PurchaseLogs.Robux do
				if entry.PurchaseId == "traceable" then
					line = entry
				end
			end
			expect(
				("type=%s to=%s intendedFor=%s giftId=%s"):format(
					tostring(line.From.Type),
					tostring(line.From.ToUserId),
					tostring(line.From.IntendedFor),
					tostring(line.From.GiftId ~= nil)
				)
			).to.equal("type=GiftSent to=94202 intendedFor=94202 giftId=true")

			harness.Cleanup()
		end)
	end)

	it("an in-window gift settles WITHOUT IntendedFor, so the aim-settled lines stay findable", function()
		-- The other half of the previous block. IntendedFor is the marker for
		-- "settled from an aim after the intent window closed"; if every GiftSent
		-- line carried it, the query that finds the population to reconcile would
		-- return every gift the game has ever sent.
		withClock(T0, function()
			local harness = makeHarness()
			local buyer = harness.Join(BUYER)
			expect(harness.Data.PromptGift(buyer, "GiftVIP", RECIPIENT)).to.equal(true)
			expect(harness.Data.HandleReceipt(receipt(222, "in-window"))).to.equal(GRANTED)
			harness.Data.Flush(buyer)

			local line = storedReserved(harness, BUYER).PurchaseLogs.Robux[1]
			expect(
				("type=%s to=%s intendedFor=%s"):format(
					tostring(line.From.Type),
					tostring(line.From.ToUserId),
					tostring(line.From.IntendedFor)
				)
			).to.equal("type=GiftSent to=94202 intendedFor=nil")

			harness.Cleanup()
		end)
	end)

	--------------------------------------------------------------------------------
	-- 5. THE CAP, AND WHAT IT REFUSES.
	--------------------------------------------------------------------------------

	describe("the aim store's cap", function()
		--- A catalogue big enough to overrun the cap, one perk each.
		local function manyProducts(n: number)
			local products = {}
			for i = 1, n do
				products["P" .. i] = { Id = 1000 + i, Category = "Gamepass", Grants = "PK" .. i }
			end
			return products
		end

		--- Arm one gift per product and let each go stale across a session boundary,
		--- so every one of them is archived. Returns the first refusal, if any.
		local function fillAims(harness, advance, count: number): (number?, string?)
			local refusedAt, reason = nil, nil
			for i = 1, count do
				local buyer = harness.Join(BUYER)
				local ok, why = harness.Data.PromptGift(buyer, "P" .. i, RECIPIENT)
				if not ok and refusedAt == nil then
					refusedAt, reason = i, why
				end
				harness.Data.Flush(buyer)
				harness.Leave(buyer)
				advance(INTENT_TTL + 1) -- the next join sweeps this intent into the store
			end
			return refusedAt, reason
		end

		it("refuses the PROMPT at the cap -- before any money moves -- rather than evicting a live aim", function()
			-- CONSTRAINT (c) of the fix brief, from the other side. The receipt-dedupe
			-- ring's count backstop drops its OLDEST entry and its own comment says a
			-- retry for that entry would be granted twice. This store must never
			-- inherit that: an aim inside the horizon may be the last durable record of
			-- a gift already paid for, so at the cap the answer is to refuse INTAKE at
			-- the prompt -- the same fail-closed move the Outage check makes, and the
			-- one point where refusing costs nothing because nothing has been charged.
			withClock(T0, function(advance)
				local harness = makeHarness({ GiftMaxPending = 200 }, manyProducts(AIM_CAP + 6))
				local refusedAt, reason = fillAims(harness, advance, AIM_CAP + 6)

				local buyer = harness.Join(BUYER)
				harness.Data.Flush(buyer)
				expect(
					("stored=%d refusedAt=%s reason=%s"):format(
						aimCount(storedReserved(harness, BUYER)),
						tostring(refusedAt),
						tostring(reason)
					)
				).to.equal("stored=64 refusedAt=65 reason=too many unsettled gift purchases; try again later")

				harness.Cleanup()
			end)
		end)

		it("re-arming a product that already HOLDS an aim is never refused: it needs no new room", function()
			withClock(T0, function(advance)
				local harness = makeHarness({ GiftMaxPending = 200 }, manyProducts(AIM_CAP))
				fillAims(harness, advance, AIM_CAP)

				local buyer = harness.Join(BUYER)
				local ok, reason = harness.Data.PromptGift(buyer, "P1", RECIPIENT)
				harness.Data.Flush(buyer)
				expect(
					("ok=%s reason=%s stored=%d"):format(
						tostring(ok),
						tostring(reason),
						aimCount(storedReserved(harness, BUYER))
					)
				).to.equal("ok=true reason=nil stored=64")

				harness.Cleanup()
			end)
		end)

		it("reclaims PAST-HORIZON aims to make room, loudly, and only those", function()
			-- The one eviction that exists. It cannot double-grant because what it
			-- drops has already lost the right to claim a receipt on its own say-so;
			-- and it says which recipient and which product went, because that line is
			-- all an operator has left to compensate from.
			withClock(T0, function(advance)
				local harness = makeHarness({ GiftMaxPending = 200 }, manyProducts(AIM_CAP + 1))
				fillAims(harness, advance, AIM_CAP)

				local expiredBefore = Metrics.Get().GiftAimsExpired or 0
				-- Every stored aim is now well past the horizon, so the cap yields.
				advance(AIM_TTL)
				local buyer = harness.Join(BUYER)
				local ok, reason = harness.Data.PromptGift(buyer, "P" .. (AIM_CAP + 1), RECIPIENT)
				harness.Data.Flush(buyer)
				task.wait()

				local logs = Scribe.GetRecentLogs({ Code = "GIFT_AIM_EXPIRED", Limit = 200 })
				expect(
					("ok=%s reason=%s stored=%d dropped=%d logged=%s"):format(
						tostring(ok),
						tostring(reason),
						aimCount(storedReserved(harness, BUYER)),
						(Metrics.Get().GiftAimsExpired or 0) - expiredBefore,
						tostring(#logs > 0)
					)
				).to.equal("ok=true reason=nil stored=0 dropped=64 logged=true")

				harness.Cleanup()
			end)
		end)

		it("the SWEEP holds the cap too, when a whole session's intents go stale at once", function()
			-- The prompt-time refusal is not the only door, and this is the other one.
			-- PromptGift checks the store as it stands NOW; a buyer who arms many gifts
			-- in ONE session passes that check every time (the store is still empty) and
			-- then has all of them swept together at the next load. The sweep has to
			-- hold the line itself, and it holds it the same way: it refuses to record
			-- the overflow rather than evicting an aim already in the store, and it says
			-- which recipient it could not record.
			withClock(T0, function(advance)
				local count = AIM_CAP + 6
				local harness = makeHarness({ GiftMaxPending = 500 }, manyProducts(count))
				local buyer = harness.Join(BUYER)
				-- The prompt now refuses past the cap, so only the first AIM_CAP are armed
				-- and the overflow never reaches the sweep. The sweep's own cap check stays
				-- exercised by GiftAimReservation's sweep-side control, and what this block
				-- still proves is the outcome: the store lands exactly full, no intent is
				-- left stranded, and the cap is reported.
				local accepted, refused = 0, 0
				for i = 1, count do
					if harness.Data.PromptGift(buyer, "P" .. i, RECIPIENT) then
						accepted += 1
					else
						refused += 1
					end
				end
				expect(("accepted=%d refused=%d"):format(accepted, refused)).to.equal("accepted=64 refused=6")
				harness.Data.Flush(buyer)
				harness.Leave(buyer)

				advance(INTENT_TTL + 1)
				local rejoined = harness.Join(BUYER) -- one sweep, `count` stale intents
				harness.Data.Flush(rejoined)
				task.wait()

				local logs = Scribe.GetRecentLogs({ Code = "GIFT_AIM_CAP_REACHED", Limit = 200 })
				local reserved = storedReserved(harness, BUYER)
				local pendingLeft = 0
				for _ in reserved.PendingGifts or {} do
					pendingLeft += 1
				end
				expect(("aims=%d pending=%d logged=%s"):format(aimCount(reserved), pendingLeft, tostring(#logs > 0))).to.equal(
					"aims=64 pending=0 logged=true"
				)

				harness.Cleanup()
			end)
		end)

		it("the aim store does not grow with the number of SETTLED gift purchases", function()
			-- The storage rule GiftIntentHorizon.spec pins for the profile as a whole,
			-- asked of this container directly: a gift that settles clears its record,
			-- so an ordinary gifter never accumulates aims at all.
			withClock(T0, function(advance)
				local harness = makeHarness()
				local buyer = harness.Join(BUYER)
				for i = 1, 300 do
					expect(harness.Data.PromptGift(buyer, "GiftVIP", 950000 + i)).to.equal(true)
					expect(harness.Data.HandleReceipt(receipt(222, `bulk-{i}`))).to.equal(GRANTED)
					advance(1)
				end
				harness.Data.Flush(buyer)

				expect(("aims=%d"):format(aimCount(storedReserved(harness, BUYER)))).to.equal("aims=0")

				harness.Cleanup()
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- 6. THE COST OF THE PRESUMPTION, recorded rather than hidden.
	--------------------------------------------------------------------------------

	it("KNOWN COST: an abandoned prompt the buyer LEFT behind can misroute one later self-purchase", function()
		-- Recorded deliberately, because it is the price of closing F1-C and it should
		-- be visible to whoever reads this file rather than discovered in production.
		--
		-- The buyer arms a gift, never completes the Robux dialog, leaves, and comes
		-- back; the sweep archives the aim because from the outside this is
		-- indistinguishable from a purchase Roblox has not delivered yet. If they then
		-- buy the SAME product for themselves inside the horizon, that purchase is
		-- presumed to be the gift and goes to the stale recipient.
		--
		-- WHAT BOUNDS IT: one product, one receipt (the aim is spent), inside the
		-- horizon, and only for a buyer who left between the prompt and the purchase.
		-- It is also LOUD -- GIFT_AIM_SETTLED names the recipient and the PurchaseId.
		-- The same buyer staying online is unaffected (the abandoned-prompt blocks
		-- above).
		--
		-- THE CLEAN CLOSE, deliberately NOT taken here because it is a scope call:
		-- MarketplaceService.PromptProductPurchaseFinished reports isPurchased=false
		-- when the dialog is dismissed, which would let the intent be dropped at that
		-- moment and never archived at all. Scribe already connects the game-pass
		-- twin of that signal in Monetization.Start.
		withClock(T0, function(advance)
			local harness = makeHarness()
			armGiftAndLeave(harness, "GiftVIP") -- prompt armed, never paid

			advance(INTENT_TTL + 1)
			local rejoined = harness.Join(BUYER)
			local decision = harness.Data.HandleReceipt(receipt(222, "self-buy-later"))
			harness.Data.Flush(rejoined)
			task.wait()

			local logs = Scribe.GetRecentLogs({ Code = "GIFT_AIM_SETTLED", Limit = 5 })
			expect(
				("d=%s buyerVIP=%s queued=%d loud=%s"):format(
					if decision == GRANTED then "GRANTED" else "NOT_PROCESSED",
					tostring(owns(storedReserved(harness, BUYER), "VIP")),
					mailbox(harness, RECIPIENT),
					tostring(#logs > 0)
				)
			).to.equal("d=GRANTED buyerVIP=false queued=1 loud=true")

			harness.Cleanup()
		end)
	end)
end
