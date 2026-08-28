--!nonstrict
-- L2: the operator verbs are verdict-gated, and the gate can prove one that is not.
--
-- These are the sharpest tools in the feature. They exist for the one case the automatic
-- machinery cannot finish: an exchange whose verdict key is unreachable, or whose records
-- disagree, where a person has to decide. Every one of them can move value that two
-- players already believe is theirs.
--
-- THE LAST CATASTROPHE CAME FROM A VERB LIKE THESE. A terminal verb duplicated an entire
-- basket in its ORDINARY use, not in some edge case, because it decided from state it had
-- read before a yielding store call rather than from the verdict. The verb that replaced
-- it reintroduced the same shape. So the last case in this file does not test a verb at
-- all: it builds the wrong one on purpose, runs it, and asserts the conservation gate
-- FAILS. A gate that cannot catch the known-bad verb cannot vouch for the good ones.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_verb"
	local A_ID, B_ID = 94301, 94302

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
		-- A Set, where the key IS the value. Registration accepts one as a Key path,
		-- so redirect can be pointed at it, and re-keying there is not a relocation.
		Badges = Scribe.SetOf(Scribe.String("x", { MaxLength = 24 }), { MaxItems = 4 }),
	}

	local function harnessed(fn)
		local harness = TestCtx.make({ Template = TEMPLATE })
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- Two players, each holding one item, with the exchange taken to `upTo`.
	local function staged(harness, upTo: string)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
		da.Inventory["a_item"].Set({ Qty = 1 })
		db.Inventory["b_item"].Set({ Qty = 1 })

		local A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID }
		local B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID }

		ExchangeLeg.Claim(A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
		ExchangeLeg.Claim(B.Ctx, TID, { Digest = "d", Role = "B", Partner = A_ID })
		if upTo == "claimed" then
			return { A = A, B = B, DA = da, DB = db }
		end

		ExchangeLeg.Escrow(A.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "a_item" } })
		ExchangeLeg.Escrow(B.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "b_item" } })
		if upTo == "escrowed" then
			-- The state between the escrows and the takes. Every stage this helper had
			-- ran both FillTakes, so the one state where a Commit is provably unsafe
			-- was the one no verb was ever tested against.
			return { A = A, B = B, DA = da, DB = db, PA = pa, PB = pb }
		end

		ExchangeLeg.FillTake(B.Ctx, TID, A.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
		ExchangeLeg.FillTake(A.Ctx, TID, B.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
		return { A = A, B = B, DA = da, DB = db, PA = pa, PB = pb }
	end

	--- Copies of one item that are OWNED, across both profiles.
	local function owned(p, verdict, itemId): number
		local count = 0
		for _, side in { p.A, p.B } do
			if side.Ctx.Tree.Accessor.Inventory[itemId].Get() ~= nil then
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
				-- A Commit excuses the escrow ONLY when the Take it points at exists.
				-- Without one the escrow is not a ghost owed for deletion, it is the
				-- only copy, and excusing it lets a Commit that destroys both baskets
				-- score as conserved.
				local excused = decision == "Commit" and type(record.Take) == "table"
				if holds(record.Escrow) and not excused then
					count += 1
				end
				if holds(record.Take) and decision == "Commit" then
					count += 1
				end
			end
			local parked = side.Ctx.Tree.Reserved.ExchangeInbox[TID].Get()
			if type(parked) == "table" and type(parked.Legs) == "table" then
				for _, leg in parked.Legs do
					if leg.Key == itemId then
						count += 1
					end
				end
			end
		end
		return count
	end

	describe("discard", function()
		it("drops an abandoned claim that never took value", function()
			harnessed(function(harness)
				local p = staged(harness, "claimed")
				local ok, reason = harness.Ctx.Exchanges.Discard(TID)
				expect(
					`ok={tostring(ok)} reason={tostring(reason)} recA={tostring(
						p.A.Ctx.Tree.Reserved.Exchange[TID].Get()
					)} recB={tostring(p.B.Ctx.Tree.Reserved.Exchange[TID].Get())}`
				).to.equal("ok=true reason=nil recA=nil recB=nil")
			end)
		end)

		it("REFUSES once a verdict exists, however innocent the records look", function()
			-- must-fix 12. "Both records are present, so nobody settled" is true at the
			-- read and false at the write, and the store call between them yields. The
			-- verdict key is the only durable statement, so it is what gets consulted.
			harnessed(function(harness)
				local p = staged(harness, "claimed")
				local store = harness.Ctx.Exchanges.VerdictStore()
				ExchangeVerdict.Propose(store, TID, { V = "Commit", A = A_ID, B = B_ID, D = "d" })

				local ok, reason = harness.Ctx.Exchanges.Discard(TID)
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "use settle, not discard", 1, true) ~= nil
					)} recA={tostring(p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)}`
				).to.equal("ok=false named=true recA=true")
			end)
		end)

		it("REFUSES a record that already holds staked value", function()
			-- Unclaim refuses anything past Claimed, so discard cannot drop value even
			-- when no verdict exists yet.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local ok, reason = harness.Ctx.Exchanges.Discard(TID)
				expect(
					`ok={tostring(ok)} nothing={tostring(
						string.find(tostring(reason), "nothing to discard", 1, true) ~= nil
					)} recA={tostring(p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)}`
				).to.equal("ok=false nothing=true recA=true")
			end)
		end)
	end)

	describe("settle", function()
		it("REFUSES without an explicit verdict, because there is no safe default", function()
			-- must-fix 13. Inheriting the resolver's "propose Abort when the key is empty"
			-- would, in exactly the state this verb exists for, land a fresh Abort against
			-- a Commit the other side already settled.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local ok, reason = harness.Ctx.Exchanges.Settle(TID)
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "explicit verdict", 1, true) ~= nil
					)} recA={tostring(p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)}`
				).to.equal("ok=false named=true recA=true")
			end)
		end)

		it("settles both sides under an explicit Commit, and conserves", function()
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local ok = harness.Ctx.Exchanges.Settle(TID, "Commit")
				local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)

				expect(
					`ok={tostring(ok)} v={tostring(verdict and verdict.V)} itemA={owned(p, verdict, "a_item")} itemB={owned(
						p,
						verdict,
						"b_item"
					)} bGotA={tostring(p.DB.Inventory["a_item"].Get() ~= nil)}`
				).to.equal("ok=true v=Commit itemA=1 itemB=1 bGotA=true")
			end)
		end)

		it("settles under an explicit Abort, returning each basket to its owner", function()
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local ok = harness.Ctx.Exchanges.Settle(TID, "Abort")
				local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)

				expect(
					`ok={tostring(ok)} v={tostring(verdict and verdict.V)} aKept={tostring(
						p.DA.Inventory["a_item"].Get() ~= nil
					)} bKept={tostring(p.DB.Inventory["b_item"].Get() ~= nil)}`
				).to.equal("ok=true v=Abort aKept=true bKept=true")
			end)
		end)

		it("loses to a verdict that already exists rather than overwriting it", function()
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local store = harness.Ctx.Exchanges.VerdictStore()
				ExchangeVerdict.Propose(store, TID, { V = "Commit", A = A_ID, B = B_ID, D = "d" })

				harness.Ctx.Exchanges.Settle(TID, "Abort")
				local verdict = ExchangeVerdict.Read(store, TID)
				expect(`v={tostring(verdict and verdict.V)} bGotA={tostring(p.DB.Inventory["a_item"].Get() ~= nil)}`).to.equal(
					"v=Commit bGotA=true"
				)
			end)
		end)
	end)

	describe("settle, against the states the verb is actually called for", function()
		-- ROUND 4. Every settle case above stages an exchange with BOTH takes filled, which
		-- is the state the automatic machinery produces. The verb exists for the states
		-- it does NOT produce, and in one of those a Commit is provably unsafe.

		it("REFUSES Commit on a record whose Take was never filled, without burning the key", function()
			-- A Commit drops the escrow because the counterparty already holds a durable
			-- copy, and the Take is the evidence of that. With no Take there is no
			-- counterparty copy to point at.
			--
			-- "Without burning the key" is the load-bearing half. The verdict key is
			-- permanent and first-writer-wins, so proposing Commit and only then
			-- discovering the settle cannot be applied leaves the exchange marked Commit
			-- for ever with neither side able to act on it. The check has to come first.
			harnessed(function(harness)
				local p = staged(harness, "escrowed")
				local ok, reason = harness.Ctx.Exchanges.Settle(TID, "Commit")
				local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)

				expect(
					`ok={tostring(ok)} named={tostring(string.find(tostring(reason), "no take", 1, true) ~= nil)} verdict={tostring(
						verdict and verdict.V
					)} itemA={owned(p, verdict, "a_item")} itemB={owned(p, verdict, "b_item")}`
				).to.equal("ok=false named=true verdict=nil itemA=1 itemB=1")
			end)
		end)

		it("still ABORTS that same exchange, which is the conserving answer", function()
			-- The verb must keep working on the state it just started refusing, or the
			-- refusal has stranded the value it was protecting.
			harnessed(function(harness)
				local p = staged(harness, "escrowed")
				local ok = harness.Ctx.Exchanges.Settle(TID, "Abort")
				expect(
					`ok={tostring(ok)} aKept={tostring(p.DA.Inventory["a_item"].Get() ~= nil)} bKept={tostring(
						p.DB.Inventory["b_item"].Get() ~= nil
					)}`
				).to.equal("ok=true aKept=true bKept=true")
			end)
		end)

		it("REFUSES Commit when only one side is loaded, because the other cannot be proved", function()
			-- The verdict is permanent and global, so a Commit forced from one loaded
			-- side binds the absent one too. The verb cannot read that profile, so it
			-- cannot know whether its Take was ever filled, and a Commit it cannot apply
			-- strands the exchange rather than finishing it. Abort stays available and is
			-- conserving from one side.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				harness.Leave(p.PB)

				local ok, reason = harness.Ctx.Exchanges.Settle(TID, "Commit")
				local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)
				expect(
					`ok={tostring(ok)} named={tostring(string.find(tostring(reason), "both sides", 1, true) ~= nil)} verdict={tostring(
						verdict and verdict.V
					)}`
				).to.equal("ok=false named=true verdict=nil")
			end)
		end)
	end)

	describe("redirect", function()
		it("REFUSES to collapse a parked entry that holds more than one key leg", function()
			-- ROUND 4, AND THE WORST OF THE VERB DEFECTS. The rewrite loop pointed EVERY
			-- key leg at the one new key. A two item basket came out with both legs
			-- naming the same key and the original keys gone: undeliverable for ever,
			-- because the second leg can only ever find its destination occupied by the
			-- first, and unrecoverable, because no later redirect can tell them apart
			-- again. The one repair verb destroyed what it was repairing.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Set({
					Id = TID,
					Verdict = "Commit",
					Legs = {
						{ Path = { "Inventory" }, Kind = "Key", Key = "first", Value = { Qty = 1 } },
						{ Path = { "Inventory" }, Kind = "Key", Key = "second", Value = { Qty = 2 } },
					},
				})

				local ok, reason = harness.Ctx.Exchanges.Redirect(TID, B_ID, "merged")
				local parked = p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Get()
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "more than one key leg", 1, true) ~= nil
					)} keys={tostring(parked and parked.Legs[1].Key)},{tostring(parked and parked.Legs[2].Key)}`
				).to.equal("ok=false named=true keys=first,second")
			end)
		end)

		it("REFUSES a container whose key IS the value, where re-keying mints", function()
			-- On a Set the key is the member. Re-keying does not relocate the delivery,
			-- it substitutes a different item: the one that was staked is destroyed and
			-- one the operator named is created, with delivery reporting success.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Set({
					Id = TID,
					Verdict = "Commit",
					Legs = { { Path = { "Badges" }, Kind = "Key", Key = "veteran", Value = "veteran" } },
				})

				local ok, reason = harness.Ctx.Exchanges.Redirect(TID, B_ID, "founder")
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "the key is the value", 1, true) ~= nil
					)} founder={tostring(p.DB.Badges.Has("founder"))}`
				).to.equal("ok=false named=true founder=false")
			end)
		end)

		it("HOLDS the exchange while it writes, rather than only checking whether it is held", function()
			-- Redirect tested `operatorHold[exchangeId]` and never set it, so it was the one
			-- verb a sweep could run underneath: it rewrites a key and then delivers,
			-- with the sweep free to resolve the same exchange in between. Observed at the
			-- moment of the write itself through the op sink, because the hold is only
			-- worth anything while the verb is mid-write.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				p.DB.Inventory["a_item"].Set({ Qty = 9 })
				harness.Ctx.Exchanges.Settle(TID, "Commit")

				local heldDuringWrite = false
				local params = p.B.Ctx.Tree.Params
				local original = params.OnOp
				params.OnOp = function(op, schema)
					if harness.Ctx.Exchanges.OperatorHold[TID] then
						heldDuringWrite = true
					end
					if original then
						return original(op, schema)
					end
					return nil
				end
				local ok = harness.Ctx.Exchanges.Redirect(TID, B_ID, "a_item_recovered")
				params.OnOp = original

				expect(
					`ok={tostring(ok)} heldDuringWrite={tostring(heldDuringWrite)} releasedAfter={tostring(
						harness.Ctx.Exchanges.OperatorHold[TID] == nil
					)}`
				).to.equal("ok=true heldDuringWrite=true releasedAfter=true")
			end)
		end)

		it("lands a parked delivery on a different key of the same container", function()
			-- The park this exists for: the destination key is occupied and stays that
			-- way. Only the KEY moves, so a redirect cannot reach a path registration
			-- never approved.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				-- Occupy the destination so delivery parks.
				p.DB.Inventory["a_item"].Set({ Qty = 9 })
				harness.Ctx.Exchanges.Settle(TID, "Commit")
				expect(`parked={tostring(p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil)}`).to.equal(
					"parked=true"
				)

				local ok, reason = harness.Ctx.Exchanges.Redirect(TID, B_ID, "a_item_recovered")
				expect(
					`ok={tostring(ok)} delivered={tostring(
						string.find(tostring(reason), "and delivered", 1, true) ~= nil
					)} landed={tostring(p.DB.Inventory["a_item_recovered"].Get() ~= nil)} inbox={tostring(
						p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Get()
					)}`
				).to.equal("ok=true delivered=true landed=true inbox=nil")
			end)
		end)

		it("REFUSES an exchange with no parked delivery for that player", function()
			harnessed(function(harness)
				staged(harness, "staked")
				local ok, reason = harness.Ctx.Exchanges.Redirect(TID, B_ID, "somewhere")
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "has no parked delivery for", 1, true) ~= nil
					)}`
				).to.equal("ok=false named=true")
			end)
		end)

		it("REFUSES an entry with nothing to re-key, because a quantity has no key", function()
			-- A quantity leg parks when a credit would exceed Max, and no amount of
			-- re-keying helps: there is no key. Refusing is the honest answer, and
			-- without this case the guard that says so was never exercised.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Set({
					Id = TID,
					Verdict = "Commit",
					Legs = { { Path = { "Coins" }, Kind = "Qty", Amount = 50 } },
				})

				local ok, reason = harness.Ctx.Exchanges.Redirect(TID, B_ID, "anywhere")
				expect(
					`ok={tostring(ok)} named={tostring(
						string.find(tostring(reason), "no key leg to redirect", 1, true) ~= nil
					)} kept={tostring(p.B.Ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil)}`
				).to.equal("ok=false named=true kept=true")
			end)
		end)
	end)

	describe("the operator hold", function()
		it("keeps the sweep off an exchange a verb is working on", function()
			-- A verb reads state, decides, and writes, with a yielding store call in the
			-- middle. A sweep that resolved the same exchange in that gap would act on state
			-- the verb had already ruled on, and the verb would then write its decision
			-- over the top.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				-- Old enough that the age floor would otherwise let the sweep straight in.
				p.A.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)
				p.B.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)

				-- Same exchange, same state, swept twice. The ONLY difference is the hold,
				-- which is what makes the second sweep evidence rather than a coincidence.
				harness.Ctx.Exchanges.OperatorHold[TID] = true
				local held = harness.Ctx.Exchanges.Sweep()
				local keptWhileHeld = p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil

				harness.Ctx.Exchanges.OperatorHold[TID] = nil
				local released = harness.Ctx.Exchanges.Sweep()

				expect(
					`held={held} keptWhileHeld={tostring(keptWhileHeld)} released={released > 0} gone={tostring(
						p.A.Ctx.Tree.Reserved.Exchange[TID].Get() == nil
					)}`
				).to.equal("held=0 keptWhileHeld=true released=true gone=true")
			end)
		end)
	end)

	describe("the verb that must NOT exist", function()
		it("proves the gate catches a single-sided forget, which duplicated a basket", function()
			-- Not a test of Scribe. A test of the CHECK.
			--
			-- `forget` drops one side's record without consulting the verdict. Run under a
			-- Commit, side A settles normally and B's record is simply deleted, so B's
			-- escrow disappears while A already holds the delivered copy. That is one
			-- basket destroyed and, with the roles reversed, one duplicated.
			--
			-- If the conservation check cannot see this, it cannot vouch for the verbs
			-- above either, and every case in this file is decoration.
			harnessed(function(harness)
				local p = staged(harness, "staked")
				local store = harness.Ctx.Exchanges.VerdictStore()
				ExchangeVerdict.Propose(store, TID, { V = "Commit", A = A_ID, B = B_ID, D = "d" })
				local verdict = ExchangeVerdict.Read(store, TID)

				-- A settles properly and receives B's item.
				ExchangeLeg.Settle(p.A.Ctx, TID, verdict)
				ExchangeLeg.Deliver(p.A.Ctx, TID)
				local healthy = `itemB={owned(p, verdict, "b_item")}`

				-- THE BAD VERB: drop B's side wholesale, verdict unread.
				p.B.Ctx.Tree.Reserved.Exchange.Remove(TID)

				-- B's item now exists only on A. B's own item, which B staked and which
				-- the Commit says A owns, is fine. But A's item, which B was owed and
				-- which lived in B's now-deleted Take, is gone from everywhere.
				local afterForget = `itemA={owned(p, verdict, "a_item")}`

				expect(`{healthy} {afterForget}`).to.equal("itemB=1 itemA=0")
			end)
		end)
	end)
end
