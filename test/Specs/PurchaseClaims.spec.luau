--!nonstrict
-- Data.Purchase's idempotency claims: whose namespace they live in, and how many
-- of them a profile can carry.
--
-- A caller-supplied IdempotencyKey becomes a claim in the flat _Scribe.Timed dict,
-- under "@pi|". That dict is also where a game's own cooldowns live, and sharing
-- it leaked in both directions.
--
-- Outwards, the leak was measurable: 51 keyed purchases produced 51
-- OnCooldownEnded fires carrying keys the game never set. Inwards was worse --
-- Data.ClearCooldown(player, "@pi|<key>") cleared a purchase claim, which is
-- precisely the operation that lets a retry apply a purchase twice.
--
-- ON PRUNING, and this corrects the finding that prompted the work: the claims
-- were NOT unpruned. Measured on 51 claims wound past their deadline, one sweep
-- clears every one of them, and a load sweep clears the ones that lapsed while the
-- player was away. What was unbounded is how many can be LIVE at once, because the
-- TTL defaults to a receipt's seven days -- so a heavy shop carries every keyed
-- purchase of the last week in every save (~39 bytes each, plus a 1 Hz sweep that
-- walks all of them for every online player). Both halves are pinned below: the
-- expiry, because a cap that quietly replaced it would be a regression, and the
-- cap, because expiry alone never bounded the live set.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)
	local Clock = require(Root.Scribe.Internal.Clock)

	local COOLDOWN_PREFIX = Template.COOLDOWN_PREFIX
	local CLAIM_PREFIX = "@pi|"

	local function timedStore(entry: any)
		return entry.LiveData[Template.RESERVED_ROOT].Timed
	end

	--- How many live purchase claims the profile carries.
	local function claimCount(entry: any): number
		local n = 0
		for pathKey in timedStore(entry) do
			if string.sub(pathKey, 1, #COOLDOWN_PREFIX + #CLAIM_PREFIX) == COOLDOWN_PREFIX .. CLAIM_PREFIX then
				n += 1
			end
		end
		return n
	end

	local function buy(harness, player, key: string?, amount: number?)
		return harness.Data.Purchase(player, {
			Cost = { Path = "Coins", Amount = amount or 1 },
			Category = "Test",
			ItemId = "Widget",
			IdempotencyKey = key,
			Grant = function() end,
		})
	end

	local function makeHarness(options)
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = options,
		})
		local player, entry, data = harness.Join(87000 + math.floor(os.clock() * 1000) % 900)
		data.Coins.Set(1000000)
		return harness, player, entry, data
	end

	describe("the reserved namespace", function()
		it("does not announce Scribe's own claims through OnCooldownEnded", function()
			-- The confirmed leak. Before this, every lapsed claim arrived at a game's
			-- own cooldown handler wearing a key that game had never set.
			local harness, player, entry = makeHarness()

			local announced = {}
			harness.Data.OnCooldownEnded:Connect(function(_, key)
				table.insert(announced, key)
			end)

			for i = 1, 20 do
				buy(harness, player, "order-" .. i)
			end
			expect(claimCount(entry)).to.equal(20)

			-- Wind every claim past its deadline and sweep.
			local store = timedStore(entry)
			for pathKey in store do
				store[pathKey] = os.time() - 1
			end
			harness.Ctx.Timed.Sweep(entry)

			expect(#announced).to.equal(0)
			-- ...and they really did lapse, so this is not passing because nothing
			-- happened. This is also the half that shows claims DO get pruned.
			expect(claimCount(entry)).to.equal(0)
			harness.Cleanup()
		end)

		it("still announces the game's own cooldowns", function()
			-- The suppression has to be narrow. A signal that stopped firing for
			-- everything would pass the spec above and break every game using it.
			local harness, player, entry = makeHarness()

			local announced = {}
			harness.Data.OnCooldownEnded:Connect(function(_, key)
				table.insert(announced, key)
			end)

			harness.Data.OnCooldown(player, "DailyChest", 3600)
			buy(harness, player, "order-1")

			local store = timedStore(entry)
			for pathKey in store do
				store[pathKey] = os.time() - 1
			end
			harness.Ctx.Timed.Sweep(entry)

			expect(#announced).to.equal(1)
			expect(announced[1]).to.equal("DailyChest")
			harness.Cleanup()
		end)

		it("refuses a reserved key from the public cooldown API", function()
			local harness, player = makeHarness()
			for _, call in
				{
					function()
						harness.Data.OnCooldown(player, "@pi|order-1", 60)
					end,
					function()
						harness.Data.PeekCooldown(player, "@pi|order-1")
					end,
					function()
						harness.Data.ClearCooldown(player, "@pi|order-1")
					end,
				}
			do
				local ok, err = pcall(call)
				expect(ok).to.equal(false)
				expect(string.find(tostring(err), "reserved", 1, true) ~= nil).to.equal(true)
			end
			harness.Cleanup()
		end)

		it("so a game can no longer clear a purchase claim through ClearCooldown", function()
			-- The consequence, driven end to end rather than asserted on the error
			-- string: the claim survives the attempt, so the retry is still refused.
			local harness, player, _entry, data = makeHarness()
			expect(buy(harness, player, "order-1", 100)).to.equal(true)
			local afterFirst = data.Coins.Get()

			pcall(function()
				harness.Data.ClearCooldown(player, CLAIM_PREFIX .. "order-1")
			end)

			-- Still claimed: the duplicate answers what the first call answered and
			-- spends nothing.
			expect(buy(harness, player, "order-1", 100)).to.equal(true)
			expect(data.Coins.Get()).to.equal(afterFirst)
			harness.Cleanup()
		end)

		it("leaves an ordinary cooldown key working, reserved prefix or not", function()
			local harness, player = makeHarness()
			expect(harness.Data.OnCooldown(player, "pi|order-1", 60)).to.equal(false)
			expect(harness.Data.PeekCooldown(player, "pi|order-1")).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("the live-claim cap", function()
		it("bounds how many claims a profile carries at once", function()
			local harness, player, entry = makeHarness({ MaxPurchaseClaims = 8 })
			for i = 1, 30 do
				buy(harness, player, "order-" .. i)
			end
			-- Every purchase succeeded; only the bookkeeping is bounded.
			expect(claimCount(entry)).to.equal(8)
			harness.Cleanup()
		end)

		it("says so, loudly, because an evicted claim can be applied twice", function()
			-- The one eviction in Scribe that can cost money silently. It does not.
			local harness, player = makeHarness({ MaxPurchaseClaims = 4 })
			for i = 1, 12 do
				buy(harness, player, "order-" .. i)
			end
			local logs = Scribe.GetRecentLogs({ Code = "PURCHASE_CLAIM_EVICTED", Limit = 20 })
			expect(#logs > 0).to.equal(true)
			expect((Scribe.GetMetrics().PurchaseClaimsEvicted or 0) > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("evicts the claim closest to expiring, not an arbitrary one", function()
			-- Claims share a TTL, so nearest-to-expiring is the oldest -- the one whose
			-- retry window is closest to over anyway. The newest claim must survive:
			-- it is the one a retry is most likely to be about.
			local harness, player, entry = makeHarness({ MaxPurchaseClaims = 3 })
			for i = 1, 3 do
				buy(harness, player, "keep-" .. i)
				-- Push each claim's deadline out so the order is unambiguous rather than
				-- a property of table layout.
				timedStore(entry)[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-" .. i] = os.time() + 1000 + i * 100
			end
			buy(harness, player, "newest")

			local store = timedStore(entry)
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-1"]).to.equal(nil) -- soonest
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-3"]).never.to.equal(nil)
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "newest"]).never.to.equal(nil)
			expect(claimCount(entry)).to.equal(3)
			harness.Cleanup()
		end)

		it("rolls a completed eviction back when the purchase then aborts", function()
			-- The eviction runs inside the transaction alongside the claim it makes room
			-- for. If it survived a rollback, a purchase that never happened would have
			-- thrown away the protection for one that did.
			--
			-- The abort has to land AFTER the claim, or the prune never runs and the
			-- spec is vacuous -- which is exactly what a first draft of it was, and what
			-- a surviving mutation exposed. A throwing Grant is too early; the purchase
			-- log append is the last step in the transaction, and an unpersistable Meta
			-- makes the accessor refuse it there.
			local harness, player, entry = makeHarness({ MaxPurchaseClaims = 2 })
			buy(harness, player, "keep-a")
			buy(harness, player, "keep-b")
			local store = timedStore(entry)
			-- Pin the order so the eviction's victim is unambiguous.
			store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-a"] = os.time() + 100
			store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-b"] = os.time() + 900
			expect(claimCount(entry)).to.equal(2)

			local ok = harness.Data.Purchase(player, {
				Cost = { Path = "Coins", Amount = 1 },
				Category = "Test",
				ItemId = "Widget",
				IdempotencyKey = "doomed",
				Meta = { fn = print }, -- refused by the write guard, after the claim
				Grant = function() end,
			})
			expect(ok).to.equal(false)

			-- keep-a WAS evicted inside the transaction and is back; doomed's own claim
			-- is not, and the count is exactly where it started.
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-a"]).never.to.equal(nil)
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "keep-b"]).never.to.equal(nil)
			expect(store[COOLDOWN_PREFIX .. CLAIM_PREFIX .. "doomed"]).to.equal(nil)
			expect(claimCount(entry)).to.equal(2)
			harness.Cleanup()
		end)

		it("rolls the prune back on its own, inside any transaction", function()
			-- The primitive, separated from the purchase path: a caller that prunes
			-- inside a Data.Transaction that then aborts gets every claim back.
			local harness, player, entry = makeHarness()
			for i = 1, 4 do
				harness.Ctx.Timed.Claim(entry, CLAIM_PREFIX .. "k" .. i, 600)
			end
			expect(claimCount(entry)).to.equal(4)

			local dropped = 0
			local ok = harness.Data.Transaction(player, function()
				dropped = harness.Ctx.Timed.PruneClaims(entry, CLAIM_PREFIX, 2)
				error("abort")
			end)

			expect(ok).to.equal(false)
			-- It really did evict inside the transaction...
			expect(dropped).to.equal(3)
			-- ...and every one came back.
			expect(claimCount(entry)).to.equal(4)
			harness.Cleanup()
		end)
	end)

	describe("the claim TTL", function()
		it("expires a claim on its own, with no cap involved", function()
			-- The correction to the record: claims always did expire. A cap that
			-- quietly became the only thing bounding them would be a regression.
			local now = 1700000000
			Clock.Install({
				Now = function()
					return now
				end,
				Monotonic = function()
					return now
				end,
			})
			local ok, err = pcall(function()
				local harness, player, entry = makeHarness({ PurchaseClaimTTL = 300 })
				buy(harness, player, "short-lived")
				expect(claimCount(entry)).to.equal(1)

				now += 301
				harness.Ctx.Timed.Sweep(entry)
				expect(claimCount(entry)).to.equal(0)

				-- And the claim is genuinely gone, not merely swept out of the dict:
				-- the same key is purchasable again.
				expect(buy(harness, player, "short-lived")).to.equal(true)
				expect(claimCount(entry)).to.equal(1)
				harness.Cleanup()
			end)
			Clock.Reset()
			if not ok then
				error(err, 0)
			end
		end)

		it("is independent of the receipt TTL, which governs real money", function()
			-- Shortening PurchaseIdTTL to bound claims would also shorten how long a
			-- Roblox receipt is remembered, and Roblox's retry window is not the
			-- game's to shorten. The two knobs are separate for exactly that reason.
			local now = 1700000000
			Clock.Install({
				Now = function()
					return now
				end,
				Monotonic = function()
					return now
				end,
			})
			local ok, err = pcall(function()
				local harness, player, entry = makeHarness({ PurchaseClaimTTL = 60, PurchaseIdTTL = 7 * 24 * 3600 })
				buy(harness, player, "claim")
				now += 61
				harness.Ctx.Timed.Sweep(entry)
				expect(claimCount(entry)).to.equal(0)
				harness.Cleanup()
			end)
			Clock.Reset()
			if not ok then
				error(err, 0)
			end
		end)

		it("defaults to the receipt TTL, so an existing game is unchanged", function()
			local now = 1700000000
			Clock.Install({
				Now = function()
					return now
				end,
				Monotonic = function()
					return now
				end,
			})
			local ok, err = pcall(function()
				local harness, player, entry = makeHarness({ PurchaseIdTTL = 900 })
				buy(harness, player, "claim")
				now += 899
				harness.Ctx.Timed.Sweep(entry)
				expect(claimCount(entry)).to.equal(1)
				now += 2
				harness.Ctx.Timed.Sweep(entry)
				expect(claimCount(entry)).to.equal(0)
				harness.Cleanup()
			end)
			Clock.Reset()
			if not ok then
				error(err, 0)
			end
		end)
	end)
end
