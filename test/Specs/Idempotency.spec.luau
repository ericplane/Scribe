--!nonstrict
-- Idempotency keys on Data.Purchase.
--
-- The audit measured three identical Data.Purchase calls producing three grants.
-- Receipts have been protected by PurchaseId all along; this is the same protection
-- for soft-currency purchases, for callers who have a natural key (a shop click id,
-- a quest reward id) and retry on failure.
--
-- The claim deliberately does NOT live in _Scribe.ProcessedPurchaseIds. That ring is
-- capped at 200 and its own eviction warning says an evicted un-expired id means a
-- retried receipt could be granted twice -- so pushing ordinary shop traffic through
-- it would flush real receipt ids. Claims get their own namespace in the Timed store.

local TestCtx = require(script.Parent.Parent.Helpers.TestCtx)

return function()
	local Wire = require(script.Parent.Parent.Parent.Scribe.Internal.Wire)

	local function spec(amount: number, key: string?, grant: ((any) -> ())?)
		return {
			Cost = { Path = "Coins", Amount = amount },
			Category = "Shop",
			ItemId = "Potion",
			IdempotencyKey = key,
			Grant = grant or function() end,
		}
	end

	describe("Data.Purchase with an idempotency key", function()
		it("applies a repeated purchase exactly once", function()
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80001)
			data.Coins.Set(1000)

			local grants = 0
			local function grant()
				grants += 1
			end

			for _ = 1, 3 do
				local ok, reason = harness.Data.Purchase(player, spec(100, "shop-click-1", grant))
				expect(ok).to.equal(true)
				expect(reason).to.equal(nil)
			end

			-- Debited once, granted once. Without the key this reads 700 and 3.
			expect(data.Coins.Get()).to.equal(900)
			expect(grants).to.equal(1)
			harness.Cleanup()
		end)

		it("returns the original outcome on a repeat, not a marker", function()
			-- Matches the receipt path: a duplicate answers what the first call
			-- answered, and the duplicate signal goes to logs and metrics rather than
			-- into the return value, where every caller would have to handle it.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80002)
			data.Coins.Set(500)

			local first, firstReason = harness.Data.Purchase(player, spec(50, "k"))
			local second, secondReason = harness.Data.Purchase(player, spec(50, "k"))

			expect(first).to.equal(second)
			expect(firstReason).to.equal(secondReason)
			harness.Cleanup()
		end)

		it("still charges separately for different keys", function()
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80003)
			data.Coins.Set(1000)

			harness.Data.Purchase(player, spec(100, "a"))
			harness.Data.Purchase(player, spec(100, "b"))

			expect(data.Coins.Get()).to.equal(800)
			harness.Cleanup()
		end)

		it("leaves the path unchanged when no key is given", function()
			-- The whole feature is opt-in; omitting the key must behave exactly as
			-- before, including charging for every call.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80004)
			data.Coins.Set(1000)

			for _ = 1, 3 do
				harness.Data.Purchase(player, spec(100, nil))
			end

			expect(data.Coins.Get()).to.equal(700)
			harness.Cleanup()
		end)
	end)

	describe("a failed purchase claims nothing", function()
		it("stays retryable after insufficient funds", function()
			-- The property that makes a claim safe to take at all. If a refusal
			-- claimed the key, a player who topped up could never complete the
			-- purchase they had already been refused.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80005)
			data.Coins.Set(50)

			local ok, reason = harness.Data.Purchase(player, spec(100, "retry-me"))
			expect(ok).to.equal(false)
			expect(reason).to.equal("insufficient funds")

			data.Coins.Set(500)
			local retried = harness.Data.Purchase(player, spec(100, "retry-me"))
			expect(retried).to.equal(true)
			expect(data.Coins.Get()).to.equal(400)
			harness.Cleanup()
		end)

		it("stays retryable after the Grant throws", function()
			-- The claim is taken INSIDE the transaction, so a Grant that throws rolls
			-- it back with the debit. A claim taken outside would survive the rollback
			-- and permanently block a purchase that never actually happened.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80006)
			data.Coins.Set(1000)

			local shouldThrow = true
			local function grant()
				if shouldThrow then
					error("grant blew up")
				end
			end

			local ok = harness.Data.Purchase(player, spec(100, "throwy", grant))
			expect(ok).to.equal(false)
			expect(data.Coins.Get()).to.equal(1000) -- rolled back

			shouldThrow = false
			local retried = harness.Data.Purchase(player, spec(100, "throwy", grant))
			expect(retried).to.equal(true)
			expect(data.Coins.Get()).to.equal(900)
			harness.Cleanup()
		end)
	end)

	describe("key validation", function()
		it("refuses a key that is empty, oversized or not a string", function()
			-- A key becomes a raw persisted table key, so an unbounded one is an
			-- unbounded profile and invalid UTF-8 would fail the whole save.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80007)
			data.Coins.Set(1000)

			for _, bad in { "", string.rep("k", Wire.MAX_IDEMPOTENCY_KEY_BYTES + 1), 12345 } do
				local ok, reason = harness.Data.Purchase(player, spec(10, bad :: any))
				expect(ok).to.equal(false)
				expect(reason).to.equal("invalid IdempotencyKey")
			end

			-- ...and nothing was charged for any of them.
			expect(data.Coins.Get()).to.equal(1000)
			harness.Cleanup()
		end)

		it("refuses a key with invalid UTF-8", function()
			-- A key becomes a raw persisted table key, bypassing the accessor write
			-- guard. Invalid UTF-8 there fails the WHOLE profile save with a DataStore
			-- 104, so this has to be caught at the boundary rather than at save time.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80009)
			data.Coins.Set(1000)

			local ok, reason = harness.Data.Purchase(player, spec(10, "bad" .. string.char(0xFF, 0xFE) .. "key"))
			expect(ok).to.equal(false)
			expect(reason).to.equal("invalid IdempotencyKey")
			expect(data.Coins.Get()).to.equal(1000)
			harness.Cleanup()
		end)

		it("accepts a key at exactly the cap", function()
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80008)
			data.Coins.Set(1000)

			local ok = harness.Data.Purchase(player, spec(10, string.rep("k", Wire.MAX_IDEMPOTENCY_KEY_BYTES)))
			expect(ok).to.equal(true)
			harness.Cleanup()
		end)

		it("takes the cap from Wire, so raising the shared constant moves the money path with it", function()
			-- Wire declares MAX_IDEMPOTENCY_KEY_BYTES shared, with the reason on the
			-- line above it: "A cap enforced on only one side is no cap." Commands and
			-- the client both source it from there; Monetization used to re-declare its
			-- own literal 64, so raising Wire's left Data.Purchase silently at 64 --
			-- and every spec above passes either way, because they only ever ask about
			-- the value Wire happens to hold.
			--
			-- Wire is a process singleton shared by every spec in the run, so the bump
			-- is restored BEFORE the first expect(): an assertion that throws between
			-- the two would otherwise leave the cap raised for the rest of the suite.
			local harness = TestCtx.make({})
			local player, _entry, data = harness.Join(80010)
			data.Coins.Set(1000)

			local original = Wire.MAX_IDEMPOTENCY_KEY_BYTES
			local raised = original * 2
			Wire.MAX_IDEMPOTENCY_KEY_BYTES = raised

			local out = {}
			local ran = pcall(function()
				out.atCap = harness.Data.Purchase(player, spec(10, string.rep("k", raised)))
				local ok, reason = harness.Data.Purchase(player, spec(10, string.rep("k", raised + 1)))
				out.overCap, out.overCapReason = ok, reason
			end)

			Wire.MAX_IDEMPOTENCY_KEY_BYTES = original

			expect(ran).to.equal(true)
			-- atCap is the half that catches the drift: over-cap is refused whichever
			-- constant is in force, so a spec that only checked it would prove nothing.
			expect(`atCap={out.atCap} over={out.overCap} reason={out.overCapReason}`).to.equal(
				"atCap=true over=false reason=invalid IdempotencyKey"
			)
			harness.Cleanup()
		end)
	end)

	describe("the claim primitive", function()
		-- Reached directly, because the purchase path short-circuits on a duplicate
		-- and so never re-enters Claim. These pin the two properties that short-circuit
		-- depends on being true.
		local Clock = require(script.Parent.Parent.Parent.Scribe.Internal.Clock)

		local function withClock(fn)
			local now = 1700000000
			Clock.Install({
				Now = function()
					return now
				end,
				Monotonic = function()
					return now
				end,
			})
			local ok, err = pcall(fn, function(seconds)
				now += seconds
			end)
			Clock.Reset()
			if not ok then
				error(err, 0)
			end
		end

		it("expires a claim once its window passes", function()
			withClock(function(advance)
				local harness = TestCtx.make({})
				local player, entry = harness.Join(80010)
				local _ = player

				harness.Ctx.Timed.Claim(entry, "@t|once", 60)
				expect(harness.Ctx.Timed.IsClaimed(entry, "@t|once")).to.equal(true)

				advance(61)
				-- A claim is a window, not a permanent mark: an idempotency key that
				-- never expired would grow the profile forever.
				expect(harness.Ctx.Timed.IsClaimed(entry, "@t|once")).to.equal(false)
				harness.Cleanup()
			end)
		end)

		it("does not push the deadline out when re-claimed", function()
			withClock(function(advance)
				local harness = TestCtx.make({})
				local player, entry = harness.Join(80011)
				local _ = player

				harness.Ctx.Timed.Claim(entry, "@t|fixed", 60)
				advance(50)
				harness.Ctx.Timed.Claim(entry, "@t|fixed", 60) -- must be a no-op
				advance(11)

				-- Still expired on the ORIGINAL deadline. If re-claiming extended it, a
				-- caller retrying in a loop could hold a claim alive indefinitely and
				-- the entry would never be swept.
				expect(harness.Ctx.Timed.IsClaimed(entry, "@t|fixed")).to.equal(false)
				harness.Cleanup()
			end)
		end)
	end)
end
