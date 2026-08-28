--!nonstrict
-- T1/T2/T3: the total-apply primitive, with no exchange protocol around it.
--
-- Every case here is about ONE claim: a leg that reports success actually moved value,
-- and a leg that cannot move value refuses instead of reporting success. Scribe has
-- several writes that report success while storing nothing, and each of the invariants
-- below closes one of them.
--
-- The REFUSAL cases carry as much weight as the success cases. A primitive that only
-- gets tested on the happy path is exactly how the five earlier design rounds of this
-- feature died: no crash, one server, one thread, everything succeeding, value gone.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_apply_1"

	local function harnessed(fn, options)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
				-- Deliberately NO Min: the floor is what makes a debit refusable, and
				-- its absence is the defect the review found.
				Floating = Scribe.Int(0),
				-- Large enough that a small positive amount falls below its ULP, which
				-- is the only way a leg is absorbed while still being well-formed.
				Float = Scribe.Number(0, { Min = 0, Max = 1e12 }),
				Inventory = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 999 }),
				}, { MaxKeys = 3 }),
				-- One declared datatype field, so the element's stored form is packed
				-- and the payload must travel packed or not at all.
				Relics = Scribe.DictOf({
					Where = Scribe.Vector3(Vector3.new(0, 0, 0)),
					Tier = Scribe.Int(1, { Min = 1, Max = 9 }),
				}, { MaxKeys = 3 }),
				Badges = Scribe.SetOf(Scribe.String("x", { MaxLength = 24 }), { MaxItems = 3 }),
			},
			Options = options,
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	--- What ExchangeLeg needs: the tree for its writes, the entry for the raw store, the
	--- compiled template for schema, and the owner for the record.
	local function ctxFor(harness, player, entry)
		return {
			Tree = entry.Tree,
			Entry = entry,
			Compiled = harness.Compiled,
			UserId = player.UserId,
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

	--- "refused because <reason>", or the outcome verbatim so a failure prints it.
	---
	--- Every refusal case asserts the REASON. A bare "it refused" passes when the leg
	--- refused for an unrelated reason, and five guard mutations survived this battery
	--- before the reason was pinned: one was masked by a duplicate check in the module
	--- and one by a downstream nil-compare that failed a line later.
	local function why(result: string, reason: string): string
		if string.find(result, reason, 1, true) ~= nil then
			return `refused because {reason}`
		end
		return result
	end

	describe("escrow proves the value left", function()
		it("moves a dict key out of game data and records its payload under the reserved root", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93001)
				local data = harness.Data.Get(player)
				data.Inventory["sword"].Set({ Qty = 4 })

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Inventory" }, Kind = "Key", Key = "sword" },
				})

				local record = entry.Tree.Reserved.Exchange[TID].Get()
				expect(
					`{result} gone={tostring(data.Inventory["sword"].Get() == nil)} staked={tostring(
						record ~= nil and record.Escrow[1].Value.Qty
					)}`
				).to.equal("OK gone=true staked=4")
			end)
		end)

		it("debits a quantity by exactly the amount", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93002)
				local data = harness.Data.Get(player)
				data.Coins.Set(500)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Coins" }, Kind = "Qty", Amount = 120 },
				})
				expect(`{result} coins={data.Coins.Get()}`).to.equal("OK coins=380")
			end)
		end)

		it("REFUSES a debit larger than the balance, instead of storing a negative", function()
			-- THE DEFECT THE REVIEW FOUND. Without a floor check, Set(-500) is not a
			-- no-op, returns the negative unchanged, and reads back as the negative, so
			-- every "prove it twice" assertion passes exactly while 1000 units are
			-- credited to the counterparty. The conservation gate cannot see it either,
			-- because -500 + 1000 sums to the starting total.
			harnessed(function(harness)
				local player, entry = harness.Join(93003)
				local data = harness.Data.Get(player)
				data.Coins.Set(100)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Coins" }, Kind = "Qty", Amount = 600 },
				})
				expect(`{why(result, "would store below Min")} coins={data.Coins.Get()}`).to.equal(
					"refused because would store below Min coins=100"
				)
				expect(entry.Tree.Reserved.Exchange[TID].Get()).to.equal(nil)
			end)
		end)

		it("REFUSES a quantity path that declares no Min, because it has no floor at all", function()
			-- Scribe.Int(0) compiles Min = nil, and validateWrite then skips its whole
			-- bounds clause. Such a field cannot be made safe at leg time, so it is
			-- refused outright rather than guarded.
			harnessed(function(harness)
				local player, entry = harness.Join(93004)
				local data = harness.Data.Get(player)
				data.Floating.Set(50)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Floating" }, Kind = "Qty", Amount = 10 },
				})
				expect(`{why(result, "has no declared Min")} value={data.Floating.Get()}`).to.equal(
					"refused because has no declared Min value=50"
				)
			end)
		end)

		it("REFUSES a quantity leg with no Amount at all", function()
			-- The finiteness guard had no case, which the strict-mode pass turned up: it
			-- is what discharges the one cast in applyQty, and a mutation deleting it
			-- left the whole suite green. A missing Amount is the shape a caller reaches
			-- by building a Qty leg and forgetting the field.
			harnessed(function(harness)
				local player, entry = harness.Join(93016)
				local data = harness.Data.Get(player)
				data.Coins.Set(500)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Coins" }, Kind = "Qty" },
				})
				expect(`{why(result, "has no finite Amount")} coins={data.Coins.Get()}`).to.equal(
					"refused because has no finite Amount coins=500"
				)
			end)
		end)

		it("REFUSES a NaN or infinite Amount, and names where it was caught", function()
			-- These never reach applyQty's finiteness guard, and finding that out is the
			-- point of the case. The record is written to the reserved root BEFORE the
			-- legs are applied, so Node's own write validation refuses the payload
			-- first. Both layers are load-bearing and neither one is the other's spare:
			-- this one catches the value on its way into the ledger, and the guard above
			-- catches a shape the ledger would have accepted.
			harnessed(function(harness)
				local player, entry = harness.Join(93017)
				local data = harness.Data.Get(player)
				data.Coins.Set(500)
				local ctx = ctxFor(harness, player, entry)

				local outcomes = {}
				for label, value in { nan = 0 / 0, positive = math.huge, negative = -math.huge } do
					local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
						{ Path = { "Coins" }, Kind = "Qty", Amount = value },
					})
					table.insert(outcomes, `{label}={why(result, "NaN/inf")}`)
				end
				table.sort(outcomes)

				expect(`{table.concat(outcomes, " ")} coins={data.Coins.Get()}`).to.equal(
					"nan=refused because NaN/inf negative=refused because NaN/inf "
						.. "positive=refused because NaN/inf coins=500"
				)
			end)
		end)

		it("REFUSES a leg of zero, which moves nothing by construction", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93005)
				local data = harness.Data.Get(player)
				data.Coins.Set(500)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Coins" }, Kind = "Qty", Amount = 0 },
				})
				expect(`{why(result, "must move a positive amount")} coins={data.Coins.Get()}`).to.equal(
					"refused because must move a positive amount coins=500"
				)
			end)
		end)

		it("REFUSES a positive leg the balance ABSORBS, which is what I1 actually guards", function()
			-- I1, exercised properly. A zero amount is caught by the positive-amount
			-- guard long before the interlock, so a zero case leaves I1 untested: the
			-- interlock mutation survived this battery until this case existed.
			--
			-- 1e-8 against a balance of 1e10 is below the double's ULP there (about
			-- 2e-6), so the subtraction returns the balance unchanged. applySet would
			-- then take its no-op early-out, return the OLD value, and read back the old
			-- value, so the return check and the post-read BOTH agree with an intent
			-- that never landed while the counterparty is credited.
			harnessed(function(harness)
				local player, entry = harness.Join(93008)
				local data = harness.Data.Get(player)
				data.Float.Set(1e10)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Float" }, Kind = "Qty", Amount = 1e-8 },
				})
				expect(`{why(result, "would not change the balance")} value={data.Float.Get()}`).to.equal(
					"refused because would not change the balance value=10000000000"
				)
				expect(entry.Tree.Reserved.Exchange[TID].Get()).to.equal(nil)
			end)
		end)

		it("REFUSES a key leg the profile does not hold, rather than recording an empty stake", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93006)
				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Inventory" }, Kind = "Key", Key = "absent" },
				})
				expect(`{why(result, "holds nothing to stake")}`).to.equal("refused because holds nothing to stake")
				expect(entry.Tree.Reserved.Exchange[TID].Get()).to.equal(nil)
			end)
		end)

		it("rolls the whole stake back when a later leg in the same call refuses", function()
			-- All-or-nothing across legs. A partial stake is a duplicate: the first leg's
			-- value would be in the escrow AND out of game data with no exchange to settle it.
			harnessed(function(harness)
				local player, entry = harness.Join(93007)
				local data = harness.Data.Get(player)
				data.Inventory["sword"].Set({ Qty = 1 })
				data.Coins.Set(10)

				local ctx = ctxFor(harness, player, entry)
				local result = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Inventory" }, Kind = "Key", Key = "sword" },
					{ Path = { "Coins" }, Kind = "Qty", Amount = 9999 },
				})
				expect(
					`{why(result, "would store below Min")} sword={tostring(data.Inventory["sword"].Get() ~= nil)} coins={data.Coins.Get()}`
				).to.equal("refused because would store below Min sword=true coins=10")
				expect(entry.Tree.Reserved.Exchange[TID].Get()).to.equal(nil)
			end)
		end)
	end)

	describe("delivery proves the value landed", function()
		--- Plant an inbox entry the way a settle would leave one.
		local function inbox(entry, legs)
			entry.Tree.Reserved.ExchangeInbox[TID].Set({ Legs = legs })
		end

		it("writes a dict element onto a vacant key and clears the inbox entry", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93101)
				local data = harness.Data.Get(player)
				inbox(entry, { { Path = { "Inventory" }, Kind = "Key", Key = "gift", Value = { Qty = 3 } } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				local landed = data.Inventory["gift"].Get()
				expect(
					`{result} qty={tostring(landed and landed.Qty)} inbox={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get()
					)}`
				).to.equal("OK qty=3 inbox=nil")
			end)
		end)

		it("REFUSES an occupied destination key, which would otherwise clobber it silently", function()
			-- I2. A record element does not no-op on an occupied key, it CLOBBERS: both
			-- equality tests are false for tables, so the write lands and destroys what
			-- was there while every assertion passes.
			harnessed(function(harness)
				local player, entry = harness.Join(93102)
				local data = harness.Data.Get(player)
				data.Inventory["gift"].Set({ Qty = 7 })
				inbox(entry, { { Path = { "Inventory" }, Kind = "Key", Key = "gift", Value = { Qty = 3 } } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				local held = data.Inventory["gift"].Get()
				expect(
					`{why(result, "is occupied")} qty={tostring(held and held.Qty)} parked={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because is occupied qty=7 parked=true")
			end)
		end)

		it("REFUSES a full destination BEFORE writing, and leaves the entry parked", function()
			-- The cap fires only when the key is new, so without a pre-check the credit
			-- raises after the debit has already committed on the other profile.
			harnessed(function(harness)
				local player, entry = harness.Join(93103)
				local data = harness.Data.Get(player)
				for index = 1, 3 do
					data.Inventory[`slot{index}`].Set({ Qty = 1 })
				end
				inbox(entry, { { Path = { "Inventory" }, Kind = "Key", Key = "gift", Value = { Qty = 3 } } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				expect(
					`{why(result, "destination is full")} count={data.Inventory.Count()} parked={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because destination is full count=3 parked=true")
			end)
		end)

		it("REFUSES a quantity credit that would exceed Max, rather than letting Clamp destroy it", function()
			-- T2. BoundsPolicy defaults to Clamp, under which a credit over Max stores
			-- Max, returns Max and reads back Max. Nothing in the write reports the loss,
			-- so the leg has to refuse before calling.
			harnessed(function(harness)
				local player, entry = harness.Join(93104)
				local data = harness.Data.Get(player)
				data.Coins.Set(999000)
				inbox(entry, { { Path = { "Coins" }, Kind = "Qty", Amount = 500000 } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				expect(
					`{why(result, "would store above Max")} coins={data.Coins.Get()} parked={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because would store above Max coins=999000 parked=true")
			end)
		end)

		it("REFUSES a set member the destination already owns, which would deduplicate away", function()
			-- Crediting an owned member leaves the store unchanged: the entry is cleared,
			-- the counterparty's copy is already gone, and the item ceases to exist.
			harnessed(function(harness)
				local player, entry = harness.Join(93105)
				local data = harness.Data.Get(player)
				data.Badges.Add("veteran")
				inbox(entry, { { Path = { "Badges" }, Kind = "Key", Key = "veteran" } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				expect(
					`{why(result, "already holds its member")} count={data.Badges.Count()} parked={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("refused because already holds its member count=1 parked=true")
			end)
		end)

		it("credits a set member the destination does not own", function()
			harnessed(function(harness)
				local player, entry = harness.Join(93106)
				local data = harness.Data.Get(player)
				inbox(entry, { { Path = { "Badges" }, Kind = "Key", Key = "veteran" } })

				local result = attempt(ExchangeLeg.Deliver, ctxFor(harness, player, entry), TID)
				expect(`{result} has={tostring(data.Badges.Has("veteran"))} count={data.Badges.Count()}`).to.equal(
					"OK has=true count=1"
				)
			end)
		end)
	end)

	describe("a datatype rides in the payload, packed", function()
		it("escrows and delivers an element carrying a Vector3 without unpacking it", function()
			-- T3 under D6. A Big may not be a quantity leg, but a datatype MAY ride
			-- inside a exchanged item, and the only form that survives the untyped escrow
			-- container is the packed one: the unpacked value is userdata, which the
			-- generic gate refuses outright.
			harnessed(function(harness)
				local player, entry = harness.Join(93201)
				local data = harness.Data.Get(player)
				data.Relics["orb"].Set({ Where = Vector3.new(3, 4, 5), Tier = 6 })

				local ctx = ctxFor(harness, player, entry)
				local staked = attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Relics" }, Kind = "Key", Key = "orb" },
				})
				local record = entry.Tree.Reserved.Exchange[TID].Get()
				expect(`{staked} gone={tostring(data.Relics["orb"].Get() == nil)}`).to.equal("OK gone=true")

				-- Hand the staked payload back through the inbox, the way a settle does.
				entry.Tree.Reserved.ExchangeInbox[TID].Set({ Legs = record.Escrow })
				local delivered = attempt(ExchangeLeg.Deliver, ctx, TID)

				local back = data.Relics["orb"].Get()
				expect(
					`{delivered} type={typeof(back and back.Where)} xyz={back.Where.X},{back.Where.Y},{back.Where.Z} tier={back.Tier}`
				).to.equal("OK type=Vector3 xyz=3,4,5 tier=6")
			end)
		end)
	end)
end
