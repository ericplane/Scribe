--!nonstrict
-- Every expiry Scribe writes has to be a finite number.
--
-- `_Scribe.Timed` is persisted RAW into the profile, so its values go through the
-- DataStore JSON round trip. `MAX_TIMED_SECONDS` (~126 years) exists for exactly
-- that reason, and `clampSeconds` -- floor, at least 1, capped finite -- is
-- applied at every write site but one. `Timed.Claim` open-codes
-- `math.max(1, math.floor(seconds))` instead, with no ceiling.
--
-- `math.floor(math.huge)` is `math.huge`, so a `PurchaseClaimTTL = math.huge`
-- writes `inf` into the persisted dict. That is not a large number; it is an
-- unserializable one, and the profile's own guards then classify the profile as
-- unpersistable. The player's Robux receipts can never be granted offline again,
-- every `Data.UpdateOffline` on them is refused, and the anomaly raised blames
-- developer code for it.
--
-- `clampSeconds` is byte-for-byte the same arithmetic for every finite input at or
-- below the cap, so the only inputs whose behaviour changes are the ones that
-- currently produce a value the library refuses to store.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local MAX_TIMED_SECONDS = 4e9

	local function makeHarness(ttl)
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { PurchaseClaimTTL = ttl },
		})
	end

	--- Every value in the persisted `_Scribe.Timed` dict, live.
	local function liveTimed(entry)
		local reserved = entry.LiveData._Scribe
		return (reserved and reserved.Timed) or {}
	end

	local function purchase(harness, player, key)
		return harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = 10 },
			IdempotencyKey = key,
			Category = "Test",
			ItemId = "Widget",
			Grant = function() end,
		})
	end

	describe("the claim TTL", function()
		it("writes an ordinary finite TTL through unchanged", function()
			-- THE CONTROL. clampSeconds must not perturb the values that already work,
			-- so this pins an exact stored expiry rather than a range.
			local harness = makeHarness(600)
			local player, entry = harness.Join(910001)
			harness.Data.Get(player).Coins.Set(1000)

			local before = os.time()
			expect(purchase(harness, player, "order-control")).to.equal(true)

			local count, only = 0, nil
			for _, value in liveTimed(entry) do
				count += 1
				only = value
			end
			expect(count).to.equal(1)
			expect(type(only)).to.equal("number")
			expect(only >= before + 600).to.equal(true)
			expect(only <= os.time() + 600).to.equal(true)

			harness.Cleanup()
		end)

		it("floors to whole seconds and never arms for less than one", function()
			-- The other two thirds of clampSeconds, which the open-coded version at this
			-- site did have and which a ceiling-only fix would silently drop. Expiries
			-- are compared against Clock.Now() in whole seconds everywhere else, and a
			-- sub-second TTL that floored to 0 would be a claim that expires the instant
			-- it is written -- i.e. no idempotency at all.
			for _, case in { { ttl = 600.7, expect = 600 }, { ttl = 0.4, expect = 1 }, { ttl = 0, expect = 1 } } do
				local harness = makeHarness(case.ttl)
				local player, entry = harness.Join(910005)
				harness.Data.Get(player).Coins.Set(1000)

				local before = os.time()
				expect(purchase(harness, player, `order-{case.ttl}`)).to.equal(true)

				local only
				for _, value in liveTimed(entry) do
					only = value
				end
				expect(only).to.be.ok()
				expect(only % 1).to.equal(0)
				expect(only >= before + case.expect).to.equal(true)
				expect(only <= os.time() + case.expect).to.equal(true)

				harness.Cleanup()
			end
		end)

		it("stores a FINITE expiry even for an infinite TTL", function()
			-- The defect, at the value it is written at. `inf` is not a big number in
			-- a persisted dict; it is a value the profile cannot be saved with.
			local harness = makeHarness(math.huge)
			local player, entry = harness.Join(910002)
			harness.Data.Get(player).Coins.Set(1000)

			expect(purchase(harness, player, "order-inf")).to.equal(true)

			local count = 0
			for pathKey, value in liveTimed(entry) do
				count += 1
				if type(value) ~= "number" or value ~= value or value == math.huge then
					error(`{pathKey} stored a non-finite expiry: {tostring(value)}`)
				end
				expect(value <= os.time() + MAX_TIMED_SECONDS).to.equal(true)
			end
			expect(count).to.equal(1)

			harness.Cleanup()
		end)

		it("keeps the profile persistable, and the value survives the round trip", function()
			-- The consequence, and the reason this is worse than a wrong number: the
			-- write has to make it to the key, and come back as the same value.
			local harness = makeHarness(math.huge)
			local player, entry = harness.Join(910003)
			harness.Data.Get(player).Coins.Set(1000)
			expect(purchase(harness, player, "order-inf-2")).to.equal(true)

			expect(harness.Data.Flush(player, { Force = true })).to.equal(true)
			local stored = harness.Fake.Persisted["Default/PLAYER_910003"]
			expect(stored).to.be.ok()
			local persistedTimed = stored._Scribe and stored._Scribe.Timed
			expect(persistedTimed).to.be.ok()
			for pathKey, value in persistedTimed do
				if value == math.huge or value ~= value then
					error(`{pathKey} persisted a non-finite expiry: {tostring(value)}`)
				end
			end
			-- Live and stored agree, so nothing was silently dropped on the way out.
			for pathKey, value in liveTimed(entry) do
				expect(persistedTimed[pathKey]).to.equal(value)
			end

			harness.Cleanup()
		end)

		it("still refuses a duplicate purchase inside the TTL", function()
			-- The behaviour the TTL is FOR. Clamping an infinity to 126 years must not
			-- turn "effectively permanent" into "expired", so the idempotency key it
			-- guards still has to deduplicate.
			local harness = makeHarness(math.huge)
			local player = harness.Join(910004)
			harness.Data.Get(player).Coins.Set(1000)

			expect(purchase(harness, player, "order-dupe")).to.equal(true)
			expect(harness.Data.Get(player).Coins.Get()).to.equal(990)
			-- Same key again: charged once, not twice.
			purchase(harness, player, "order-dupe")
			expect(harness.Data.Get(player).Coins.Get()).to.equal(990)

			harness.Cleanup()
		end)
	end)
end
