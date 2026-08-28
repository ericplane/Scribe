--!nonstrict
-- L1: the crash matrix. Every position an exchange can be interrupted in, resolved by the
-- thing a reload runs, with conservation checked after each one.
--
-- The design's whole liveness claim is that there is no position from which an exchange
-- cannot reach a terminal state on its own. Not "unlikely to get stuck": no such
-- position. That is only worth anything if the positions are enumerated and each one is
-- actually driven, so each case below constructs a state by hand and then runs
-- `Exchange.ResolveOne`, which is what a load or a cadence tick calls.
--
-- CONSERVATION IS CHECKED ON THE TREES, not the disk. The disk-level gate lives in
-- ExchangeConservationSim; here the point is the state machine, and a tree read keeps each
-- position constructible by hand rather than by racing a save.
--
-- Resolution proposes ABORT when no verdict exists. That is the conserving default: an
-- attempt that never reached its verdict has both baskets in escrow and an Abort returns
-- each to its owner. If the counterparty already committed, the proposal loses and reads
-- Commit back, which is the point of a first-writer-wins key.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_crash"
	local A_ID, B_ID = 98801, 98802

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 6 }),
			},
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- An in-memory verdict key with the same first-writer-wins contract.
	local function verdictStore(seed)
		local keys = seed or {}
		return {
			Keys = keys,
			UpdateAsync = function(_self, key, transform)
				local value = transform(keys[key])
				if value == nil then
					return nil, nil
				end
				keys[key] = value
				return value, nil
			end,
			GetAsync = function(_self, key)
				return keys[key], nil
			end,
		}
	end

	--- How many copies of one item exist anywhere across both profiles.
	---
	--- Game data, escrows, takes and inboxes, with the verdict deciding which of an
	--- escrow/take pair is the owner. Two copies with one owner is the ghost window and
	--- is conserving; two OWNERS is not.
	local function owners(sides, verdict, itemId): number
		local count = 0
		for _, side in sides do
			local data = side.Ctx.Tree.Accessor
			if data.Inventory[itemId].Get() ~= nil then
				count += 1
			end
			local record = side.Ctx.Tree.Reserved.Exchange[TID].Get()
			if type(record) == "table" then
				local decision = if type(verdict) == "table" then verdict.V else nil
				local function holds(legs)
					if type(legs) ~= "table" then
						return false
					end
					for _, leg in legs do
						if leg.Key == itemId then
							return true
						end
					end
					return false
				end
				if holds(record.Escrow) and decision ~= "Commit" then
					count += 1
				end
				if holds(record.Take) and decision == "Commit" then
					count += 1
				end
			end
			local inbox = side.Ctx.Tree.Reserved.ExchangeInbox[TID].Get()
			if type(inbox) == "table" and type(inbox.Legs) == "table" then
				for _, leg in inbox.Legs do
					if leg.Key == itemId then
						count += 1
					end
				end
			end
		end
		return count
	end

	--- Build an exchange at a chosen position and hand back both sides.
	---
	--- `upTo` names the last step that happened before the interruption.
	local function positioned(harness, upTo: string)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
		da.Inventory["a_item"].Set({ Qty = 1 })
		db.Inventory["b_item"].Set({ Qty = 1 })

		local sides = {
			A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID },
			B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID },
		}
		local digest = "digest-crash"
		local order = { "claimA", "claimB", "stakeA", "stakeB", "takeB", "takeA" }
		local reached = false

		-- A name that matches no step would run EVERY step and silently test the wrong
		-- position. P0 did exactly that on the first run: "none" is not a step, so the
		-- loop fell through and built a complete exchange while claiming nothing had
		-- happened. Refuse the typo rather than let it pick a position at random.
		if upTo ~= "none" then
			local known = false
			for _, step in order do
				known = known or step == upTo
			end
			if not known then
				error(`crash matrix: "{upTo}" is not a step; use "none" or one of the six`, 2)
			end
		end
		if upTo == "none" then
			return sides, digest, { da, db }
		end

		for _, step in order do
			if reached then
				break
			end
			if step == "claimA" then
				ExchangeLeg.Claim(sides.A.Ctx, TID, { Digest = digest, Role = "A", Partner = B_ID })
			elseif step == "claimB" then
				ExchangeLeg.Claim(sides.B.Ctx, TID, { Digest = digest, Role = "B", Partner = A_ID })
			elseif step == "stakeA" then
				ExchangeLeg.Escrow(sides.A.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "a_item" } })
			elseif step == "stakeB" then
				ExchangeLeg.Escrow(sides.B.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "b_item" } })
			elseif step == "takeB" then
				ExchangeLeg.FillTake(sides.B.Ctx, TID, sides.A.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
			elseif step == "takeA" then
				ExchangeLeg.FillTake(sides.A.Ctx, TID, sides.B.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
			end
			if step == upTo then
				reached = true
			end
		end
		return sides, digest, { da, db }
	end

	--- How many of the two items are sitting in game data, across both profiles.
	---
	--- Conservation alone cannot see a delivery that never ran: a parked inbox entry
	--- still holds the item, so the count stays right while the player cannot use it.
	--- A surviving mutation proved that, so the sheet reports where the value ended up.
	local function inGame(sides): number
		local count = 0
		for _, side in sides do
			for _, itemId in { "a_item", "b_item" } do
				if side.Ctx.Tree.Accessor.Inventory[itemId].Get() ~= nil then
					count += 1
				end
			end
		end
		return count
	end

	--- Resolve both sides the way two reloads would, and report the balance sheet.
	local function resolveBoth(sides, store): string
		local outcomeA = select(1, Exchange.ResolveOne({ VerdictStore = store }, sides.A, TID))
		local outcomeB = select(1, Exchange.ResolveOne({ VerdictStore = store }, sides.B, TID))
		local verdict = select(1, ExchangeVerdict.Read(store, TID))
		local list = { sides.A, sides.B }
		return `a={tostring(outcomeA)} b={tostring(outcomeB)} itemA={owners(list, verdict, "a_item")} itemB={owners(
			list,
			verdict,
			"b_item"
		)} recA={tostring(sides.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)} recB={tostring(
			sides.B.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
		)} inGame={inGame(list)}`
	end

	describe("every interrupted position resolves and conserves", function()
		it("P0: nothing written", function()
			harnessed(function(harness)
				local sides = positioned(harness, "none")
				expect(resolveBoth(sides, verdictStore())).to.equal(
					"a=Settled b=Settled itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P1: claims written, nothing staked", function()
			-- An abandoned claim carries no value, so resolution just clears it.
			harnessed(function(harness)
				local sides = positioned(harness, "claimB")
				expect(resolveBoth(sides, verdictStore())).to.equal(
					"a=Aborted b=Aborted itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P2: one side staked, the other only claimed", function()
			-- The lopsided position. A's item is in escrow with no verdict anywhere, so
			-- an Abort returns it and B's claim clears.
			harnessed(function(harness)
				local sides = positioned(harness, "stakeA")
				expect(resolveBoth(sides, verdictStore())).to.equal(
					"a=Aborted b=Aborted itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P3: both staked and durable, no verdict", function()
			harnessed(function(harness)
				local sides = positioned(harness, "takeA")
				expect(resolveBoth(sides, verdictStore())).to.equal(
					"a=Aborted b=Aborted itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P4: a Commit landed but the proposer never learned it", function()
			-- The indeterminate verdict. Nobody has settled, because settling requires
			-- reading the verdict back, so the next resolution reads the committed answer
			-- and both sides settle to it rather than to their own Abort proposal.
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				expect(resolveBoth(sides, store)).to.equal(
					"a=Committed b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P5: verdict read, nothing settled", function()
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				-- Nobody settles; the resolution does all of it.
				expect(resolveBoth(sides, store)).to.equal(
					"a=Committed b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P6: one side settled, the other not. THE GHOST WINDOW", function()
			-- Two copies of B's item exist at once: A holds the delivered one, B's escrow
			-- still holds the dispossessed copy. Exactly one is OWNED, and the resolution
			-- of B's side deletes the ghost.
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				local verdict = select(1, ExchangeVerdict.Read(store, TID))

				-- A settles and delivers; B has not looked yet.
				ExchangeLeg.Settle(sides.A.Ctx, TID, verdict)
				ExchangeLeg.Deliver(sides.A.Ctx, TID)
				local list = { sides.A, sides.B }
				local ghostWindow = `itemB={owners(list, verdict, "b_item")} bStillHasRecord={tostring(
					sides.B.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
				)}`

				local after = resolveBoth(sides, store)
				expect(`{ghostWindow} | {after}`).to.equal(
					"itemB=1 bStillHasRecord=true | a=Settled b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P7: a settle reverted, and re-settling from the same verdict is identical", function()
			-- Why the record removal is FUSED with the inbox move. Settling twice from
			-- one verdict must not move the value twice.
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				local verdict = select(1, ExchangeVerdict.Read(store, TID))

				ExchangeLeg.Settle(sides.A.Ctx, TID, verdict)
				ExchangeLeg.Settle(sides.A.Ctx, TID, verdict)
				ExchangeLeg.Settle(sides.A.Ctx, TID, verdict)

				expect(resolveBoth(sides, store)).to.equal(
					"a=Settled b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P8: a delivery reverted, and redelivering lands it exactly once", function()
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				local verdict = select(1, ExchangeVerdict.Read(store, TID))

				ExchangeLeg.Settle(sides.A.Ctx, TID, verdict)
				ExchangeLeg.Deliver(sides.A.Ctx, TID)
				-- A second delivery has nothing left to deliver and must not duplicate.
				pcall(ExchangeLeg.Deliver, sides.A.Ctx, TID)

				expect(resolveBoth(sides, store)).to.equal(
					"a=Settled b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("P9: fully settled and delivered, and resolving again changes nothing", function()
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })
				local first = resolveBoth(sides, store)
				local second = resolveBoth(sides, store)
				expect(`{first} | {second}`).to.equal(
					"a=Committed b=Committed itemA=1 itemB=1 recA=false recB=false inGame=2"
						.. " | a=Settled b=Settled itemA=1 itemB=1 recA=false recB=false inGame=2"
				)
			end)
		end)

		it("REFUSES a verdict that does not govern this exchange, and leaves the record alone", function()
			-- Nothing in the matrix presented a MISMATCHED verdict, so skipping the check
			-- entirely was a surviving mutation. Settling against another basket's verdict
			-- would move value nobody agreed to move, and the record must survive for an
			-- operator to look at rather than being consumed by the wrong answer.
			harnessed(function(harness)
				local sides = positioned(harness, "takeA")
				local store = verdictStore({
					[TID] = { V = "Commit", A = A_ID, B = B_ID, D = "a-different-basket" },
				})

				local outcome, err = Exchange.ResolveOne({ VerdictStore = store }, sides.A, TID)
				local list = { sides.A, sides.B }

				expect(
					`outcome={tostring(outcome)} refused={tostring(
						err ~= nil and string.find(err, "does not govern", 1, true) ~= nil
					)} kept={tostring(sides.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)} itemA={owners(
						list,
						nil,
						"a_item"
					)}`
				).to.equal("outcome=nil refused=true kept=true itemA=1")
			end)
		end)

		it("resolves a single side alone, with the counterparty never looking", function()
			-- The case that matters for a real server: the other player is offline or on
			-- another machine. This side must still reach a terminal state, and the item
			-- it is owed must be waiting when the other side eventually resolves.
			harnessed(function(harness)
				local sides, digest = positioned(harness, "takeA")
				local store = verdictStore({ [TID] = { V = "Commit", A = A_ID, B = B_ID, D = digest } })

				local outcome = select(1, Exchange.ResolveOne({ VerdictStore = store }, sides.A, TID))
				local list = { sides.A, sides.B }
				local verdict = select(1, ExchangeVerdict.Read(store, TID))

				expect(
					`{tostring(outcome)} aDone={tostring(sides.A.Ctx.Tree.Reserved.Exchange[TID].Get() == nil)} bUntouched={tostring(
						sides.B.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
					)} itemA={owners(list, verdict, "a_item")} itemB={owners(list, verdict, "b_item")}`
				).to.equal("Committed aDone=true bUntouched=true itemA=1 itemB=1")
			end)
		end)
	end)
end
