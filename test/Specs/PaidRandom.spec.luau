--!nonstrict
-- Paid random items: one policy read per player, every purchase path refusing while it is
-- unknown or restricted, and one function behind the query and the prompt.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local LOOT_ID, PET_ID, BAG_ID, VIP_ID = 5001, 5002, 5003, 777

	--- Frames for spawned reads and deferred flushes. Nothing here sleeps real time.
	local function settle(frames: number?)
		for _ = 1, frames or 6 do
			task.wait()
		end
	end

	--- A policy service stand-in keyed by user id: true restricts, false allows, "error"
	--- raises, "hang" parks the read until Release. Counts every call.
	local function fakePolicy(modes)
		local calls = 0
		local parked = {}
		local function fake(player)
			calls += 1
			local mode = modes[player.UserId]
			if mode == "error" then
				error("policy: unavailable")
			elseif mode == "hang" then
				table.insert(parked, coroutine.running())
				coroutine.yield()
				mode = modes[player.UserId]
			end
			return { ArePaidRandomItemsRestricted = mode == true }
		end
		local function release()
			local threads = parked
			parked = {}
			for _, thread in threads do
				task.spawn(thread)
			end
		end
		return fake, function()
			return calls
		end, release
	end

	local function harnessed(modes, fn, extra)
		local fake, calls, release = fakePolicy(modes)
		local prompted = {}
		local options = {
			Products = {
				LootBox = {
					Id = LOOT_ID,
					PaidRandom = true,
					Grant = function(data)
						data.Boxes.Increment(1)
					end,
				},
				MysteryPet = { Id = PET_ID, PaidRandom = true, Grants = "Pet" },
				CoinBag = {
					Id = BAG_ID,
					Grant = function(data)
						data.Coins.Increment(100)
					end,
				},
			},
			Passes = { VIPPass = { Id = VIP_ID } },
			GetPolicyInfoAsync = fake,
			PromptProductPurchase = function(player, id)
				table.insert(prompted, `product {player.UserId}:{id}`)
			end,
			PromptGamePassPurchase = function(player, id)
				table.insert(prompted, `pass {player.UserId}:{id}`)
			end,
			UserOwnsGamePassAsync = function()
				return false
			end,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(10, { Min = 0 }), Boxes = Scribe.Int(0, { Min = 0 }) },
			Options = options,
		})
		local ok, err = pcall(fn, harness, { Prompted = prompted, Calls = calls, Release = release, Modes = modes })
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	--- The prompt outcome as one string, so a failure prints the reason.
	local function attempt(harness, player, name): string
		local ok, why = harness.Data.PromptPurchase(player, name)
		return `{tostring(ok)} why={tostring(why)}`
	end

	local function logCount(code: string): number
		return #Scribe.GetRecentLogs({ Code = code, Limit = 100 })
	end

	--- Retry backoff as frames, and a movable clock, restored afterwards.
	local function withFrameClock(monotonicOffset: () -> number, fn)
		local wait, monotonic = Clock.Wait, Clock.Monotonic
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
			Monotonic = function()
				return monotonic() + monotonicOffset()
			end,
		})
		local ok, err = pcall(fn)
		Clock.Install({ Wait = wait, Monotonic = monotonic })
		if not ok then
			error(err, 0)
		end
	end

	describe("the prompt", function()
		it("REFUSES a flagged product for a restricted player, prompting nothing", function()
			harnessed({ [1] = true }, function(harness, t)
				local player = harness.Join(1)
				settle()
				local product = attempt(harness, player, "LootBox")
				expect(`{product} | prompts={#t.Prompted}`).to.equal("false why=paid-random-restricted | prompts=0")
			end)
		end)

		it("answers policy-pending while the read is in flight, and purchasable once it lands", function()
			harnessed({ [2] = "hang" }, function(harness, t)
				local player = harness.Join(2)
				settle()
				local before = attempt(harness, player, "LootBox")
				t.Modes[2] = false
				t.Release()
				settle()
				local after = attempt(harness, player, "LootBox")
				expect(`{before} | {after} | prompts={table.concat(t.Prompted, ",")}`).to.equal(
					"false why=policy-pending | true why=nil | prompts=product 2:5001"
				)
			end)
		end)

		it("prompts an unrestricted player, and a flagged read in flight never touches an unflagged entry", function()
			harnessed({ [4] = false, [6] = "hang" }, function(harness, t)
				local player = harness.Join(4)
				settle()
				local loot = attempt(harness, player, "LootBox")
				local hanging = harness.Join(6)
				settle()
				local bag = attempt(harness, hanging, "CoinBag")
				local vip = attempt(harness, hanging, "VIPPass")
				expect(`{loot} | {bag} | {vip} | prompts={table.concat(t.Prompted, ",")}`).to.equal(
					"true why=nil | true why=nil | true why=nil | prompts=product 4:5001,product 6:5003,pass 6:777"
				)
			end)
		end)

		it("reads no policy at all for a bundle with no flagged entry", function()
			harnessed({ [5] = true }, function(harness, t)
				local player = harness.Join(5)
				settle(10)
				local bag = attempt(harness, player, "CoinBag")
				expect(`calls={t.Calls()} {bag}`).to.equal("calls=0 true why=nil")
			end, {
				Products = { CoinBag = { Id = BAG_ID } },
				Passes = { VIPPass = { Id = VIP_ID } },
			})
		end)
	end)

	describe("the state is the refusal", function()
		it("answers the exact string the prompt refuses with, for every state", function()
			harnessed({ [7] = true, [8] = "hang", [9] = false }, function(harness)
				local restricted = harness.Join(7)
				local hanging = harness.Join(8)
				local owner = harness.Join(9)
				settle()
				harness.Data.GrantPerk(owner, "Pet")
				local stranger = FakePlayer.new(10)
				local rows = {}
				for _, row in
					{
						{ restricted, "LootBox" },
						{ hanging, "LootBox" },
						{ owner, "MysteryPet" },
						{ stranger, "LootBox" },
					}
				do
					local state = harness.Data.GetProductState(row[1], row[2])
					local _, why = harness.Data.PromptPurchase(row[1], row[2])
					table.insert(rows, `{state}={tostring(why)}`)
				end
				expect(table.concat(rows, " ")).to.equal(
					"paid-random-restricted=paid-random-restricted policy-pending=policy-pending owned=owned not-loaded=not-loaded"
				)
			end)
		end)

		it("reports owned for a held pass and a held perk, and never for a consumable", function()
			harnessed({ [11] = false }, function(harness)
				local player = harness.Join(11)
				settle()
				harness.Data.GrantPerk(player, "Pet")
				-- A perk that happens to share the consumable's name is not ownership of it.
				harness.Data.GrantPerk(player, "LootBox")
				local rows = {}
				for _, name in { "VIPPass", "MysteryPet", "LootBox", "CoinBag" } do
					table.insert(rows, `{name}={harness.Data.GetProductState(player, name)}`)
				end
				expect(table.concat(rows, " ")).to.equal(
					"VIPPass=owned MysteryPet=owned LootBox=purchasable CoinBag=purchasable"
				)
			end, {
				UserOwnsGamePassAsync = function(_, passId)
					return passId == VIP_ID
				end,
			})
		end)

		it("tells a restricted player who also owns the perk the restriction, not the ownership", function()
			harnessed({ [12] = true }, function(harness)
				local player = harness.Join(12)
				settle()
				harness.Data.GrantPerk(player, "Pet")
				expect(harness.Data.GetProductState(player, "MysteryPet")).to.equal("paid-random-restricted")
			end)
		end)

		it("RAISES for a name that is not declared, naming the API", function()
			harnessed({ [13] = false }, function(harness)
				local player = harness.Join(13)
				local ok, err = pcall(harness.Data.GetProductState, player, "Nope")
				expect(`ok={ok} named={string.find(tostring(err), 'Scribe.GetProductState: "Nope"', 1, true) ~= nil}`).to.equal(
					"ok=false named=true"
				)
			end)
		end)

		it(
			"exports the strings on Scribe.ProductState, and the two refusals on PurchaseReason and GiftReason",
			function()
				local p, r, g = Scribe.ProductState, Scribe.PurchaseReason, Scribe.GiftReason
				expect(
					`{p.Purchasable} {p.Owned} {p.PaidRandomRestricted} {p.PolicyPending} {p.NotLoaded} `
						.. `{r.PaidRandomRestricted} {r.PolicyPending} {g.PaidRandomRestricted} {g.PolicyPending}`
				).to.equal(
					"purchasable owned paid-random-restricted policy-pending not-loaded "
						.. "paid-random-restricted policy-pending paid-random-restricted policy-pending"
				)
			end
		)
	end)

	describe("the other paths", function()
		it("Purchase refuses a flagged spec for a restricted player and debits nothing", function()
			harnessed({ [14] = true }, function(harness)
				local player, _, data = harness.Join(14)
				settle()
				local spec = {
					Cost = { Path = "Coins", Amount = 1 },
					ItemId = "box",
					PaidRandom = true,
					Grant = function(d)
						d.Boxes.Increment(1)
					end,
				}
				local ok, why = harness.Data.Purchase(player, spec)
				spec.PaidRandom = nil
				local plainOk = harness.Data.Purchase(player, spec)
				expect(`{ok} why={why} coins={data.Coins.Get()} boxes={data.Boxes.Get()} plain={plainOk}`).to.equal(
					"false why=paid-random-restricted coins=9 boxes=1 plain=true"
				)
			end)
		end)

		it("PromptGift refuses a restricted buyer, an unreadable recipient, and a restricted one", function()
			harnessed({ [15] = true, [16] = false, [17] = false, [18] = true }, function(harness)
				local restrictedBuyer = harness.Join(15)
				local buyer = harness.Join(16)
				local buyer2 = harness.Join(17)
				harness.Join(18)
				settle()
				local _, a = harness.Data.PromptGift(restrictedBuyer, "MysteryPet", 99)
				local _, b = harness.Data.PromptGift(buyer, "MysteryPet", 99)
				local _, c = harness.Data.PromptGift(buyer2, "MysteryPet", 18)
				expect(`{a} | {b} | {c}`).to.equal("paid-random-restricted | policy-pending | paid-random-restricted")
			end)
		end)

		it(
			"PromptGift still goes out between two unrestricted players here, and unflagged gifts need nobody",
			function()
				harnessed({ [19] = false, [20] = false, [21] = false }, function(harness, t)
					local buyer = harness.Join(19)
					harness.Join(20)
					local other = harness.Join(21)
					settle()
					local flagged, whyFlagged = harness.Data.PromptGift(buyer, "MysteryPet", 20)
					local plain, whyPlain = harness.Data.PromptGift(other, "CoinBag", 97)
					expect(
						`flagged={flagged} {tostring(whyFlagged)} plain={plain} {tostring(whyPlain)} prompts={table.concat(
							t.Prompted,
							","
						)}`
					).to.equal("flagged=true nil plain=true nil prompts=product 19:5002,product 21:5003")
				end)
			end
		)

		it("a receipt from a restricted player is still granted, once, and logged", function()
			harnessed({ [22] = true }, function(harness)
				local _, _, data = harness.Join(22)
				settle()
				local before = logCount("PAID_RANDOM_RECEIPT")
				local receipt = {
					PlayerId = 22,
					ProductId = LOOT_ID,
					PurchaseId = "pr-22",
					CurrencySpent = 99,
					CurrencyType = Enum.CurrencyType.Robux,
					PlaceIdWherePurchased = 0,
				}
				local decision = harness.Data.HandleReceipt(receipt)
				harness.Data.HandleReceipt(receipt)
				local granted = decision == Enum.ProductPurchaseDecision.PurchaseGranted
				expect(`granted={granted} boxes={data.Boxes.Get()} logged={logCount("PAID_RANDOM_RECEIPT") - before}`).to.equal(
					"granted=true boxes=1 logged=1"
				)
			end)
		end)
	end)

	describe("the read", function()
		it("retries with backoff, logs POLICY_READ_FAIL once, and re-arms one read after 30 seconds", function()
			local offset = 0
			withFrameClock(function()
				return offset
			end, function()
				harnessed({ [23] = "error" }, function(harness, t)
					local before = logCount("POLICY_READ_FAIL")
					local player = harness.Join(23)
					settle(12)
					local failed = `calls={t.Calls()} state={harness.Data.GetProductState(player, "LootBox")}`
					harness.Data.GetProductState(player, "LootBox")
					settle()
					local early = `calls={t.Calls()}`
					offset = 31
					harness.Data.GetProductState(player, "LootBox")
					settle()
					local rearmed = `calls={t.Calls()} state={harness.Data.GetProductState(player, "LootBox")}`
					t.Modes[23] = false
					offset = 62
					harness.Data.GetProductState(player, "LootBox")
					settle()
					local late = `calls={t.Calls()} state={harness.Data.GetProductState(player, "LootBox")}`
					expect(`{failed} | {early} | {rearmed} | {late} | logged={logCount("POLICY_READ_FAIL") - before}`).to.equal(
						"calls=3 state=policy-pending | calls=3 | calls=4 state=policy-pending | calls=5 state=purchasable | logged=1"
					)
				end)
			end)
		end)

		it("never delays Ready: a read that hangs leaves the join alone", function()
			harnessed({ [24] = "hang" }, function(harness, t)
				local player, joined = nil, false
				task.spawn(function()
					player = harness.Join(24)
					joined = true
				end)
				local ready = harness.StepUntil(function()
					return joined
				end, 60)
				local state = if player then harness.Data.GetProductState(player, "LootBox") else "no player"
				t.Modes[24] = false
				t.Release()
				settle()
				expect(`ready={ready} state={state} after={harness.Data.GetProductState(player, "LootBox")}`).to.equal(
					"ready=true state=policy-pending after=purchasable"
				)
			end)
		end)

		it("a rejoin is a fresh session, so the policy is read again", function()
			harnessed({ [25] = true }, function(harness, t)
				local player = harness.Join(25)
				settle()
				harness.Leave(player)
				settle()
				t.Modes[25] = false
				local again = harness.Join(25)
				settle()
				expect(`calls={t.Calls()} state={harness.Data.GetProductState(again, "LootBox")}`).to.equal(
					"calls=2 state=purchasable"
				)
			end)
		end)
	end)

	describe("registration", function()
		local function build(products, passes)
			return pcall(function()
				local harness = TestCtx.make({
					Template = { Coins = Scribe.Int(0) },
					Options = { Products = products, Passes = passes },
				})
				harness.Cleanup()
			end)
		end

		it("REJECTS a non-boolean PaidRandom on a product, and any PaidRandom on a pass", function()
			local okProduct, errProduct = build({ Bad = { Id = 1, PaidRandom = "yes" } }, nil)
			local okPass, errPass = build(nil, { Bad = { Id = 2, PaidRandom = true } })
			expect(
				`product={okProduct} {string.find(
					tostring(errProduct),
					'product "Bad" PaidRandom must be a boolean',
					1,
					true
				) ~= nil} `
					.. `pass={okPass} {string.find(tostring(errPass), 'pass "Bad" cannot be PaidRandom', 1, true) ~= nil}`
			).to.equal("product=false true pass=false true")
		end)

		it("accepts true, false and nil", function()
			local ok =
				build({ A = { Id = 1, PaidRandom = true }, B = { Id = 2, PaidRandom = false }, C = { Id = 3 } }, nil)
			expect(ok).to.equal(true)
		end)
	end)
end
