--!nonstrict
-- The Stack leg: moving PART of a stacked entry, and the Ignore option that stops a move
-- carrying the giver's analytics with it.
--
-- A Key leg moves a whole entry, so a game storing `Inventory.Emberblade = { Qty = 5 }`
-- could not trade two of five. The obvious workaround, a Qty leg at
-- `{ "Inventory", "Emberblade", "Qty" }`, is refused at boot because crediting a key the
-- receiver does not hold materialises the whole element from its defaults.
--
-- What makes this Kind different: a split DUPLICATES the fields it does not drop.
-- `{ Qty = 5, Rarity = 3 }` split by two is right for Rarity and a mint for TimesUsed,
-- and no per-leg proof can tell them apart because the count is exact either way. So the
-- developer classifies every element field as Identity or Ignore, and boot refuses any
-- field in neither.
--
-- The load-bearing case here is therefore NOT one of the arithmetic ones. It is
-- "REFUSES TO BOOT on an element field nobody classified".

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_stack"

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
		-- A record element: a count, something that describes the item, and something
		-- that describes the OWNER'S history with it.
		Inventory = Scribe.DictOf({
			Qty = Scribe.Int(1, { Min = 1, Max = 99 }),
			Rarity = Scribe.Int(3, { Min = 1, Max = 5 }),
			TimesUsed = Scribe.Int(0, { Min = 0, Max = 999999 }),
		}, { MaxKeys = 4 }),
		-- A scalar element: the stored value IS the count, so there is nothing
		-- alongside it to duplicate and nothing to declare.
		Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 }), { MaxKeys = 4 }),
	}

	local EXCHANGEABLE = {
		Item = {
			Path = { "Inventory" },
			Kind = "Stack",
			Count = "Qty",
			Identity = { "Rarity" },
			Ignore = { "TimesUsed" },
		},
		Ore = { Path = { "Resources" }, Kind = "Stack" },
		WholeItem = { Path = { "Inventory" }, Kind = "Key", Ignore = { "TimesUsed" } },
	}

	--- Boot a bundle with one exchangeable spec and report the outcome as a string.
	local function boots(spec, template): string
		local ok, err = pcall(function()
			local harness = TestCtx.make({
				Template = template or TEMPLATE,
				Options = { Exchangeable = { probe = spec } },
			})
			harness.Cleanup()
		end)
		return if ok then "BOOTED" else tostring(err)
	end

	--- "refused because <reason>", or the outcome verbatim so a failure prints it.
	local function why(result: string, reason: string): string
		if string.find(result, reason, 1, true) ~= nil then
			return `refused because {reason}`
		end
		return result
	end

	local function harnessed(fn)
		local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	--- What ExchangeLeg needs, INCLUDING the declared rules the Stack primitives read.
	local function ctxFor(harness, player, entry)
		return {
			Tree = entry.Tree,
			Entry = entry,
			Compiled = harness.Compiled,
			UserId = player.UserId,
			Plans = ExchangeLeg.Approve(EXCHANGEABLE),
		}
	end

	--- Run a leg and report the outcome as one string, so a failure prints what
	--- happened rather than only "false".
	local function attempt(fn, ...): string
		local args = table.pack(...)
		local pok, ok, err = pcall(fn, table.unpack(args, 1, args.n))
		if not pok then
			return `RAISED {tostring(ok)}`
		end
		if ok then
			return "OK"
		end
		return `REFUSED {tostring(err)}`
	end

	--- A claimed, ready-to-stake context for one fresh player.
	local function staker(harness, seed)
		local player, entry, data = harness.Join()
		if seed then
			seed(data)
		end
		local ctx = ctxFor(harness, player, entry)
		ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 999 })
		return ctx, data, player, entry
	end

	--------------------------------------------------------------------------------
	-- Registration
	--------------------------------------------------------------------------------

	describe("what a Stack declaration must account for", function()
		it("REFUSES TO BOOT on an element field nobody classified, which is the silent mint", function()
			-- THE case. TimesUsed left out of both lists would be DUPLICATED onto the
			-- receiver on every split, and no per-leg proof can see it: the count term
			-- is exact whether or not the analytics rode along. Boot is the only place
			-- this is visible, so boot is where it is refused.
			expect(
				why(
					boots({ Path = { "Inventory" }, Kind = "Stack", Count = "Qty", Identity = { "Rarity" } }),
					"does not account for element field"
				)
			).to.equal("refused because does not account for element field")
		end)

		it("BOOTS once every field is classified, which is the control", function()
			expect(boots({
				Path = { "Inventory" },
				Kind = "Stack",
				Count = "Qty",
				Identity = { "Rarity" },
				Ignore = { "TimesUsed" },
			})).to.equal("BOOTED")
		end)

		it("BOOTS a scalar element with nothing declared, because there is nothing to declare", function()
			expect(boots({ Path = { "Resources" }, Kind = "Stack" })).to.equal("BOOTED")
		end)

		it("REFUSES a name in Ignore the element does not declare, so a typo cannot mean nothing", function()
			-- An Ignore that silently ignores nothing is worse than no option: the
			-- analytics would LOOK stripped and travel anyway.
			expect(why(
				boots({
					Path = { "Inventory" },
					Kind = "Stack",
					Count = "Qty",
					Identity = { "Rarity" },
					Ignore = { "TimesUsedd" },
				}),
				"which the element does not declare"
			)).to.equal("refused because which the element does not declare")
		end)

		it("REFUSES a field listed in BOTH Identity and Ignore", function()
			expect(why(
				boots({
					Path = { "Inventory" },
					Kind = "Stack",
					Count = "Qty",
					Identity = { "Rarity", "TimesUsed" },
					Ignore = { "TimesUsed" },
				}),
				"BOTH Identity and Ignore"
			)).to.equal("refused because BOTH Identity and Ignore")
		end)

		it("REFUSES ignoring the Count field, which is the thing being moved", function()
			expect(why(
				boots({
					Path = { "Inventory" },
					Kind = "Stack",
					Count = "Qty",
					Identity = { "Rarity" },
					Ignore = { "Qty", "TimesUsed" },
				}),
				"which is the field being moved"
			)).to.equal("refused because which is the field being moved")
		end)

		it("REFUSES a dotted name, rather than ignoring nothing under a shape it cannot reach", function()
			expect(why(
				boots({
					Path = { "Inventory" },
					Kind = "Stack",
					Count = "Qty",
					Identity = { "Rarity" },
					Ignore = { "Stats.Kills" },
				}),
				"only top-level element fields"
			)).to.equal("refused because only top-level element fields")
		end)

		it("REFUSES a Count the element does not declare, and one that is missing entirely", function()
			expect(
				`{why(
					boots({ Path = { "Inventory" }, Kind = "Stack", Count = "Nope", Identity = { "Rarity" } }),
					"which the element does not declare"
				)} | {why(boots({ Path = { "Inventory" }, Kind = "Stack" }), "must declare Count")}`
			).to.equal("refused because which the element does not declare | refused because must declare Count")
		end)

		it("REFUSES a Count that cannot conserve, by the same rules a Qty leg obeys", function()
			local template = {
				Bags = Scribe.DictOf({
					Loose = Scribe.Int(0), -- no Min: no floor
					Soft = Scribe.Number(0, { Min = 0, Max = 1e12 }),
					Huge = Scribe.Big(0, { Min = 0 }),
					Name = Scribe.String("x", { MaxLength = 8 }),
				}, { MaxKeys = 4 }),
			}
			local function refusal(count: string, fragment: string): string
				return why(
					boots({
						Path = { "Bags" },
						Kind = "Stack",
						Count = count,
						Identity = { "Loose", "Soft", "Huge", "Name" },
						Ignore = {},
					}, template),
					fragment
				)
			end
			expect(
				`{refusal("Loose", "declaring no Min")} | {refusal("Soft", "Scribe.Number")} | {refusal(
					"Huge",
					"Scribe.Big"
				)} | {refusal("Name", "which is not a count")}`
			).to.equal(
				"refused because declaring no Min | refused because Scribe.Number | refused because Scribe.Big "
					.. "| refused because which is not a count"
			)
		end)

		it("REFUSES a Stack on a SetOf and on an ArrayOf, which have no keyed stack", function()
			local template = {
				Badges = Scribe.SetOf(Scribe.String("x", { MaxLength = 8 }), { MaxItems = 4 }),
				Deck = Scribe.ArrayOf({ Card = Scribe.String("x", { MaxLength = 8 }) }, { MaxItems = 4 }),
			}
			expect(
				`{why(boots({ Path = { "Badges" }, Kind = "Stack" }, template), "only a DictOf or MapOf")} | {why(
					boots({ Path = { "Deck" }, Kind = "Stack", Count = "Card" }, template),
					"only a DictOf or MapOf"
				)}`
			).to.equal("refused because only a DictOf or MapOf | refused because only a DictOf or MapOf")
		end)

		it("REFUSES Count and Identity on a scalar element, whose element IS the count", function()
			expect(
				`{why(boots({ Path = { "Resources" }, Kind = "Stack", Count = "Qty" }), "which IS the count")} | {why(
					boots({ Path = { "Resources" }, Kind = "Stack", Identity = { "x" } }),
					"with no other fields"
				)}`
			).to.equal("refused because which IS the count | refused because with no other fields")
		end)

		it("REFUSES Count or Identity on a Key or Qty leg, where neither means anything", function()
			expect(
				`{why(boots({ Path = { "Inventory" }, Kind = "Key", Count = "Qty" }), "only meaningful for a Stack")} `
					.. `| {why(
						boots({ Path = { "Coins" }, Kind = "Qty", Identity = { "x" } }),
						"only meaningful for a Stack"
					)}`
			).to.equal("refused because only meaningful for a Stack | refused because only meaningful for a Stack")
		end)

		it("REFUSES Ignore on a quantity leg and on a scalar element, which have no fields", function()
			expect(
				`{why(boots({ Path = { "Coins" }, Kind = "Qty", Ignore = { "x" } }), "which has no fields")} | {why(
					boots({ Path = { "Resources" }, Kind = "Key", Ignore = { "x" } }),
					"no fields to ignore"
				)}`
			).to.equal("refused because which has no fields | refused because no fields to ignore")
		end)

		it("REFUSES a container field listed in Identity, which a split would duplicate wholesale", function()
			local template = {
				Bags = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 9 }),
					Gems = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 4 }),
				}, { MaxKeys = 4 }),
			}
			expect(
				why(
					boots({ Path = { "Bags" }, Kind = "Stack", Count = "Qty", Identity = { "Gems" } }, template),
					"duplicate the whole collection"
				)
			).to.equal("refused because duplicate the whole collection")
		end)
	end)

	--------------------------------------------------------------------------------
	-- The split
	--------------------------------------------------------------------------------

	describe("the debit takes exactly what was asked for and leaves the rest", function()
		it("splits a stack, leaving the remainder AND its residual untouched", function()
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				local outcome = attempt(
					ExchangeLeg.Escrow,
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
				)
				local left = data.Inventory.Emberblade.Get()
				expect(
					`{outcome} qty={left.Qty} rarity={left.Rarity} used={left.TimesUsed} keys={data.Inventory.Count()}`
				).to.equal("OK qty=3 rarity=4 used=12 keys=1")
			end)
		end)

		it("REMOVES the key when the whole stack moves, rather than leaving a zero entry", function()
			-- A zero-count entry is an item the player still appears to own and can name
			-- in a later basket, and every proof would pass on it.
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				local outcome = attempt(
					ExchangeLeg.Escrow,
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 5 } }
				)
				expect(`{outcome} held={tostring(data.Inventory.Emberblade.Get())} keys={data.Inventory.Count()}`).to.equal(
					"OK held=nil keys=0"
				)
			end)
		end)

		it("REFUSES more than the stack holds, and stakes nothing", function()
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				local outcome = attempt(
					ExchangeLeg.Escrow,
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 6 } }
				)
				expect(`{why(outcome, "moves 6 of 5 held")} qty={data.Inventory.Emberblade.Get().Qty}`).to.equal(
					"refused because moves 6 of 5 held qty=5"
				)
			end)
		end)

		it("REFUSES an amount that is not a positive whole number", function()
			harnessed(function(harness)
				local ctx = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				local function move(amount): string
					return attempt(
						ExchangeLeg.Escrow,
						ctx,
						TID,
						{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = amount } }
					)
				end
				expect(
					`{why(move(0), "positive amount")} | {why(move(-1), "positive amount")} | {why(
						move(1.5),
						"whole number"
					)} | {why(move(0 / 0), "finite Amount")} | {why(move(nil), "finite Amount")}`
				).to.equal(
					"refused because positive amount | refused because positive amount | refused because whole number "
						.. "| refused because finite Amount | refused because finite Amount"
				)
			end)
		end)

		it("REFUSES a key the profile does not hold, rather than staking an empty record", function()
			harnessed(function(harness)
				local ctx = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				expect(
					why(
						attempt(
							ExchangeLeg.Escrow,
							ctx,
							TID,
							{ { Path = { "Inventory" }, Kind = "Stack", Key = "Nothing", Amount = 1 } }
						),
						"holds nothing to stake"
					)
				).to.equal("refused because holds nothing to stake")
			end)
		end)

		it("splits a SCALAR element, where the stored value itself is the count", function()
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Resources.ore.Set(50)
				end)
				local outcome = attempt(
					ExchangeLeg.Escrow,
					ctx,
					TID,
					{ { Path = { "Resources" }, Kind = "Stack", Key = "ore", Amount = 20 } }
				)
				expect(`{outcome} left={data.Resources.ore.Get()} keys={data.Resources.Count()}`).to.equal(
					"OK left=30 keys=1"
				)
			end)
		end)

		it("REFUSES a Stack leg with no declared rules, rather than guessing the count field", function()
			-- A bundle whose Exchangeable never named this path has no Count to read,
			-- and inventing one would move whatever field happened to be numeric.
			harnessed(function(harness)
				local player, entry, data = harness.Join()
				data.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				local bare = {
					Tree = entry.Tree,
					Entry = entry,
					Compiled = harness.Compiled,
					UserId = player.UserId,
				}
				ExchangeLeg.Claim(bare, TID, { Digest = "d", Role = "A", Partner = 999 })
				expect(
					why(
						attempt(
							ExchangeLeg.Escrow,
							bare,
							TID,
							{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
						),
						"no declared Stack rules"
					)
				).to.equal("refused because no declared Stack rules")
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- A stack with a floor above one
	--------------------------------------------------------------------------------

	describe("a count field whose Min is above one", function()
		-- Every case above uses Min = 1, where a split can never violate the floor:
		-- `amount < have` already implies at least one is left and at least one moves.
		-- A higher floor is what makes both halves checkable, and it found a real bug.
		local FLOOR_TEMPLATE = {
			Bundles = Scribe.DictOf({ Qty = Scribe.Int(3, { Min = 3, Max = 99 }) }, { MaxKeys = 4 }),
		}
		local FLOOR_EXCHANGEABLE = { Bundle = { Path = { "Bundles" }, Kind = "Stack", Count = "Qty" } }

		local function floored(fn)
			local harness = TestCtx.make({
				Template = FLOOR_TEMPLATE,
				Options = { Exchangeable = FLOOR_EXCHANGEABLE },
			})
			local ok, err = pcall(function()
				local player, entry, data = harness.Join()
				data.Bundles.crate.Set({ Qty = 10 })
				local ctx = {
					Tree = entry.Tree,
					Entry = entry,
					Compiled = harness.Compiled,
					UserId = player.UserId,
					Plans = ExchangeLeg.Approve(FLOOR_EXCHANGEABLE),
				}
				ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 999 })
				fn(ctx, data, harness)
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end

		local function move(ctx, amount): string
			return attempt(
				ExchangeLeg.Escrow,
				ctx,
				TID,
				{ { Path = { "Bundles" }, Kind = "Stack", Key = "crate", Amount = amount } }
			)
		end

		it("REFUSES a split whose MOVED half is below the floor, which would park for ever", function()
			-- THE BUG this template found. Before the guard, moving 2 off 10 escrowed
			-- cleanly and debited the giver, and then could never be delivered: the
			-- credit writes Qty 2, the default Clamp policy rounds it to 3, and the
			-- content proof refuses the mismatch. Nothing was lost, because that proof
			-- held, but the value parked and every retry failed identically.
			floored(function(ctx, data)
				expect(`{why(move(ctx, 2), "below the smallest legal stack")} left={data.Bundles.crate.Get().Qty}`).to.equal(
					"refused because below the smallest legal stack left=10"
				)
			end)
		end)

		it("REFUSES a split whose REMAINDER is below the floor", function()
			floored(function(ctx, data)
				expect(`{why(move(ctx, 8), "below the smallest legal stack")} left={data.Bundles.crate.Get().Qty}`).to.equal(
					"refused because below the smallest legal stack left=10"
				)
			end)
		end)

		it("ALLOWS a split where both halves sit exactly on the floor", function()
			floored(function(ctx, data)
				expect(`{move(ctx, 7)} left={data.Bundles.crate.Get().Qty}`).to.equal("OK left=3")
			end)
		end)

		it("ALLOWS the WHOLE stack, which is legal by construction however high the floor", function()
			-- The exemption is not an oversight: the element travels as it stands, so
			-- there is no half to be too small.
			floored(function(ctx, data)
				expect(`{move(ctx, 10)} held={tostring(data.Bundles.crate.Get())}`).to.equal("OK held=nil")
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- Ignore
	--------------------------------------------------------------------------------

	describe("the fields declared not to travel", function()
		it("drops an ignored field from the STAKE, which is where the giver's copy is still readable", function()
			harnessed(function(harness)
				local ctx = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				ExchangeLeg.Escrow(
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
				)
				local staked = ctx.Tree.Reserved.Exchange[TID].Get().Escrow[1].Value
				expect(`qty={staked.Qty} rarity={staked.Rarity} used={tostring(staked.TimesUsed)}`).to.equal(
					"qty=2 rarity=4 used=nil"
				)
			end)
		end)

		it(
			"drops it from a whole-entry KEY leg too, which is where a traded pet inherits a stranger's stats",
			function()
				harnessed(function(harness)
					local ctx = staker(harness, function(d)
						d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
					end)
					ExchangeLeg.Escrow(ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "Emberblade" } })
					local staked = ctx.Tree.Reserved.Exchange[TID].Get().Escrow[1].Value
					expect(`qty={staked.Qty} rarity={staked.Rarity} used={tostring(staked.TimesUsed)}`).to.equal(
						"qty=5 rarity=4 used=nil"
					)
				end)
			end
		)

		it("leaves the GIVER's own copy of an ignored field alone", function()
			-- Ignore is about what travels, never about deleting the giver's history.
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				ExchangeLeg.Escrow(
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
				)
				expect(`used={data.Inventory.Emberblade.Get().TimesUsed}`).to.equal("used=12")
			end)
		end)

		it("REFUSES to deliver a payload that acquired an ignored field after it was staked", function()
			-- The second half of the guard. Escrow proves the drop happened; this proves
			-- the record has not grown the field back, which is the only way the giver's
			-- value could still reach a receiver.
			harnessed(function(harness)
				local ctx, data = staker(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end)
				ExchangeLeg.Escrow(
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
				)
				ExchangeLeg.Settle(ctx, TID, { V = "Abort", A = 1, B = 2, D = "d" })
				-- Tamper: put the analytics back into the parked payload.
				ctx.Tree.Reserved.ExchangeInbox[TID].Legs[1].Value.TimesUsed.Set(999)
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				-- The giver's own history is untouched throughout: the split never wrote
				-- it, and the refused delivery rolled back.
				expect(`{why(outcome, "carries ignored field")} used={data.Inventory.Emberblade.Get().TimesUsed}`).to.equal(
					"refused because carries ignored field used=12"
				)
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- The credit
	--------------------------------------------------------------------------------

	describe("the credit lands on a fresh key or merges into one already held", function()
		--- Stake `amount` off A, abort it back, and hand the caller the parked entry.
		--- Abort returns the basket to its owner, which is the shortest route to a
		--- delivery whose destination this file controls.
		local function parked(harness, seedGiver, amount, leg)
			local ctx, data = staker(harness, seedGiver)
			local one = leg or { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = amount }
			ExchangeLeg.Escrow(ctx, TID, { one })
			ExchangeLeg.Settle(ctx, TID, { V = "Abort", A = 1, B = 2, D = "d" })
			return ctx, data
		end

		it("writes a fresh key at exactly the amount moved, with the ignored field at its DEFAULT", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				-- Clear the giver's side so the credit lands on a genuinely vacant key.
				data.Inventory.Remove("Emberblade")
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				local got = data.Inventory.Emberblade.Get()
				expect(`{outcome} qty={got.Qty} rarity={got.Rarity} used={got.TimesUsed}`).to.equal(
					"OK qty=2 rarity=4 used=0"
				)
			end)
		end)

		it("MERGES into a key already held, adding the counts and keeping the receiver's own history", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				local got = data.Inventory.Emberblade.Get()
				expect(`{outcome} qty={got.Qty} rarity={got.Rarity} used={got.TimesUsed} keys={data.Inventory.Count()}`).to.equal(
					"OK qty=5 rarity=4 used=12 keys=1"
				)
			end)
		end)

		it("PARKS rather than merging when the residual differs, because neither side may win", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				-- The destination is now a DIFFERENT item under the same name.
				data.Inventory.Emberblade.Rarity.Set(1)
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				local got = data.Inventory.Emberblade.Get()
				expect(
					`{why(outcome, "destination differs at")} qty={got.Qty} rarity={got.Rarity} parked={tostring(
						ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because destination differs at qty=3 rarity=1 parked=true")
			end)
		end)

		it("PARKS rather than clamping when the merge would pass Max", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				data.Inventory.Emberblade.Qty.Set(99)
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				expect(
					`{why(outcome, "above Max")} qty={data.Inventory.Emberblade.Get().Qty} parked={tostring(
						ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because above Max qty=99 parked=true")
			end)
		end)

		it("PARKS rather than failing when the container is full and the key is new", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				data.Inventory.Remove("Emberblade")
				for index = 1, 4 do
					data.Inventory[`filler{index}`].Set({ Qty = 1, Rarity = 1, TimesUsed = 0 })
				end
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				expect(
					`{why(outcome, "destination is full")} parked={tostring(
						ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because destination is full parked=true")
			end)
		end)

		it("delivers on the retry once the destination makes room, with nothing lost in between", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				end, 2)
				data.Inventory.Emberblade.Qty.Set(99)
				attempt(ExchangeLeg.Deliver, ctx, TID)
				data.Inventory.Emberblade.Qty.Set(10)
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				expect(
					`{outcome} qty={data.Inventory.Emberblade.Get().Qty} parked={tostring(
						ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("OK qty=12 parked=false")
			end)
		end)

		it("merges a SCALAR element, which has no residual to compare", function()
			harnessed(function(harness)
				local ctx, data = parked(harness, function(d)
					d.Resources.ore.Set(50)
				end, nil, { Path = { "Resources" }, Kind = "Stack", Key = "ore", Amount = 20 })
				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				expect(`{outcome} ore={data.Resources.ore.Get()} keys={data.Resources.Count()}`).to.equal(
					"OK ore=50 keys=1"
				)
			end)
		end)
	end)

	--------------------------------------------------------------------------------
	-- End to end
	--------------------------------------------------------------------------------

	describe("through the public surface", function()
		it("moves two of five between players and conserves every term", function()
			harnessed(function(harness)
				local a, _ea, da = harness.Join()
				local b, _eb, db = harness.Join()
				da.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })

				local outcome, err = harness.Data.Exchange.Attempt(
					a,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } },
					b,
					{}
				)
				local mine = da.Inventory.Emberblade.Get()
				local theirs = db.Inventory.Emberblade.Get()
				expect(
					`{tostring(outcome)} err={tostring(err)} a={mine.Qty} b={theirs.Qty} total={mine.Qty + theirs.Qty} `
						.. `rarity={theirs.Rarity} used={theirs.TimesUsed} mineUsed={mine.TimesUsed}`
				).to.equal("Committed err=nil a=3 b=2 total=5 rarity=4 used=0 mineUsed=12")
			end)
		end)

		it("REFUSES a Stack leg on a path declared only as a Key, so the Kind is part of the allowlist", function()
			harnessed(function(harness)
				local a, _ea, da = harness.Join()
				local b = harness.Join()
				da.Resources.ore.Set(50)
				-- Resources is declared Stack, Coins is declared as nothing at all.
				local outcome, err = harness.Data.Exchange.Attempt(
					a,
					{ { Path = { "Coins" }, Kind = "Stack", Key = "ore", Amount = 5 } },
					b,
					{}
				)
				-- Attempt answers a nil outcome with a reason, so the refusal is the pair.
				expect(`{tostring(outcome)} {why(tostring(err), "is not exchangeable as a Stack leg")}`).to.equal(
					"nil refused because is not exchangeable as a Stack leg"
				)
			end)
		end)

		it("reports HOW MANY a stalled split staked, not merely that something is open", function()
			-- Escrow takes the count out of the balance on purpose, the way handing an
			-- item to a clerk does, and resolution is deliberately unbounded. A player
			-- whose exchange stalls has to be shown the amount, or the game cannot tell
			-- them where two of their five went.
			harnessed(function(harness)
				local player, entry, data = harness.Join()
				data.Inventory.Emberblade.Set({ Qty = 5, Rarity = 4, TimesUsed = 12 })
				local ctx = ctxFor(harness, player, entry)
				ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 999 })
				ExchangeLeg.Escrow(
					ctx,
					TID,
					{ { Path = { "Inventory" }, Kind = "Stack", Key = "Emberblade", Amount = 2 } }
				)
				local open = harness.Data.Exchange.Open(player)
				local leg = open[1] and open[1].Staked and open[1].Staked[1]
				expect(
					`open={#open} kind={tostring(leg and leg.Kind)} key={tostring(leg and leg.Key)} amount={tostring(
						leg and leg.Amount
					)} left={data.Inventory.Emberblade.Get().Qty}`
				).to.equal("open=1 kind=Stack key=Emberblade amount=2 left=3")
			end)
		end)
	end)
end
