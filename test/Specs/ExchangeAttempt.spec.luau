--!nonstrict
-- STEP 5: one same-server exchange, orchestrated end to end.
--
-- THE ORDERING IS THE PROOF, and it is what this file exists to pin. The taker's copy
-- of the payload must be durable on the taker's own key BEFORE any verdict record can
-- exist. If that holds, a Commit that authorises a giver to drop its escrow can never
-- destroy the only copy, and the whole "conservation without a bounded resolution
-- time" claim follows. If it does not hold, the design is unsound and no amount of
-- retrying fixes it.
--
-- So the verdict store here is not a stub that records calls. It REFUSES to decide
-- unless the precondition already holds, exactly as the design says to arm the sim.
-- An orchestrator that proposed too early does not quietly pass with a note in a log;
-- it fails to exchange at all, and every case below goes red.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_attempt_1"
	local A_ID, B_ID = 98001, 98002

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 100000 }),
				Inventory = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 99 }),
				}, { MaxKeys = 4 }),
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

	--- A verdict store that will not decide until the exchange has earned the right to.
	---
	--- `guard` is called before the transform runs and must return true; returning
	--- false raises, which is what an orchestrator proposing too early would meet.
	local function verdictStore(guard)
		local keys = {}
		return {
			Proposals = 0,
			UpdateAsync = function(self, key, transform)
				self.Proposals += 1
				if guard ~= nil and guard() ~= true then
					error("verdict refused: the stakes were not durable yet", 0)
				end
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

	--- Both players joined, each holding one item and some coins.
	local function pair(harness)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
		da.Inventory["sword"].Set({ Qty = 1 })
		da.Coins.Set(500)
		db.Inventory["shield"].Set({ Qty = 1 })
		db.Coins.Set(100)
		return {
			A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID, Legs = {} },
			B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID, Legs = {} },
			DataA = da,
			DataB = db,
			EntryA = ea,
			EntryB = eb,
		}
	end

	--- The basket used by most cases: A gives the sword and 200 coins, B gives the shield.
	local function basket(p)
		p.A.Legs = {
			{ Path = { "Inventory" }, Kind = "Key", Key = "sword" },
			{ Path = { "Coins" }, Kind = "Qty", Amount = 200 },
		}
		p.B.Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "shield" } }
	end

	it("commits an ordinary exchange and moves both baskets", function()
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local flushes = 0
			local outcome, err = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					flushes += 1
					return true
				end,
			}, p.A, p.B)

			expect(
				`{tostring(outcome)} err={tostring(err)} aSword={tostring(p.DataA.Inventory["sword"].Get())} aShield={tostring(
					p.DataA.Inventory["shield"].Get() ~= nil
				)} aCoins={p.DataA.Coins.Get()} bSword={tostring(p.DataB.Inventory["sword"].Get() ~= nil)} bCoins={p.DataB.Coins.Get()}`
			).to.equal("Committed err=nil aSword=nil aShield=true aCoins=300 bSword=true bCoins=300")
		end)
	end)

	it("clears both records and both inboxes once delivery lands", function()
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
			}, p.A, p.B)

			expect(
				`recA={tostring(p.EntryA.Tree.Reserved.Exchange[TID].Get())} recB={tostring(
					p.EntryB.Tree.Reserved.Exchange[TID].Get()
				)} inA={tostring(p.EntryA.Tree.Reserved.ExchangeInbox[TID].Get())} inB={tostring(
					p.EntryB.Tree.Reserved.ExchangeInbox[TID].Get()
				)}`
			).to.equal("recA=nil recB=nil inA=nil inB=nil")
		end)
	end)

	it("proposes no verdict until BOTH takes are recorded and both stakes have flushed", function()
		-- C3, at the orchestration level. The store refuses to decide unless the
		-- precondition already holds, so an orchestrator that proposed early cannot
		-- exchange at all rather than exchanging unsafely.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local flushed = 0
			local store = verdictStore(function()
				local recA = p.EntryA.Tree.Reserved.Exchange[TID].Get()
				local recB = p.EntryB.Tree.Reserved.Exchange[TID].Get()
				local takesRecorded = recA ~= nil and recA.Take ~= nil and recB ~= nil and recB.Take ~= nil
				return takesRecorded and flushed >= 2
			end)

			local outcome = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = store,
				Flush = function()
					flushed += 1
					return true
				end,
			}, p.A, p.B)

			expect(`{tostring(outcome)} proposals={store.Proposals} flushed={flushed}`).to.equal(
				"Committed proposals=1 flushed=4"
			)
		end)
	end)

	it("ABORTS and returns everything when a stake cannot be proved durable", function()
		-- A false from the forced flush is UNRESOLVED, never "failed", so the value
		-- cannot simply be handed back: the return has to be verdict-gated too.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local outcome = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return false
				end,
			}, p.A, p.B)

			expect(
				`{tostring(outcome)} aSword={tostring(p.DataA.Inventory["sword"].Get() ~= nil)} aCoins={p.DataA.Coins.Get()} bShield={tostring(
					p.DataB.Inventory["shield"].Get() ~= nil
				)} recA={tostring(p.EntryA.Tree.Reserved.Exchange[TID].Get())}`
			).to.equal("Aborted aSword=true aCoins=500 bShield=true recA=nil")
		end)
	end)

	it("ABORTS on the deadline rather than hanging", function()
		-- D2: the attempt is time bounded and cancels. The resolution is not bounded,
		-- but the ATTEMPT is, and a player is never left staring at a frozen exchange.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local outcome = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Deadline = -1,
				Flush = function()
					return true
				end,
			}, p.A, p.B)

			expect(
				`{tostring(outcome)} aSword={tostring(p.DataA.Inventory["sword"].Get() ~= nil)} aCoins={p.DataA.Coins.Get()}`
			).to.equal("Aborted aSword=true aCoins=500")
		end)
	end)

	it("REFUSES a player who already has an exchange in flight", function()
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local deps = {
				ExchangeId = TID,
				VerdictStore = verdictStore(function()
					return false
				end),
				Flush = function()
					return true
				end,
			}
			-- The first attempt cannot reach a verdict, so both records stay staked.
			Exchange.Attempt(deps, p.A, p.B)
			local staked = p.EntryA.Tree.Reserved.Exchange[TID].Get() ~= nil

			local outcome, err = Exchange.Attempt({
				ExchangeId = "tid_second",
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
			}, p.A, p.B)

			expect(
				`staked={tostring(staked)} outcome={tostring(outcome)} refused={tostring(
					err ~= nil and string.find(err, "already has an exchange in flight", 1, true) ~= nil
				)}`
			).to.equal("staked=true outcome=nil refused=true")
		end)
	end)

	it("REFUSES a player whose inbox is at the cap, before anything moves", function()
		-- The inbox is untyped and has no cap of its own, so unbounded accumulation
		-- ends in a profile that cannot save. Refused here for free rather than
		-- discovered as a slow death.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			for index = 1, 3 do
				p.EntryB.Tree.Reserved.ExchangeInbox[`old{index}`].Set({ Legs = {} })
			end

			local outcome, err = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
				Options = { MaxInbox = 3 },
			}, p.A, p.B)

			expect(
				`outcome={tostring(outcome)} refused={tostring(
					err ~= nil and string.find(err, "at the cap", 1, true) ~= nil
				)} aSword={tostring(p.DataA.Inventory["sword"].Get() ~= nil)}`
			).to.equal("outcome=nil refused=true aSword=true")
		end)
	end)

	it("REFUSES a player exchanging with themselves", function()
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local outcome, err = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
			}, p.A, p.A)
			expect(`outcome={tostring(outcome)} why={tostring(err)}`).to.equal(
				"outcome=nil why=a player cannot exchange with themselves"
			)
		end)
	end)

	it("leaves both profiles staked and resolvable when no verdict can be established", function()
		-- P5 in the crash matrix. No verdict is KNOWN, which is not the same as none
		-- existing, so nothing may be released. The value sits in escrow: unreachable,
		-- unspendable, conserved, and resolvable by the next attempt at the same exchange.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local deps = {
				ExchangeId = TID,
				VerdictStore = verdictStore(function()
					return false
				end),
				Flush = function()
					return true
				end,
			}
			local outcome, err = Exchange.Attempt(deps, p.A, p.B)

			local recA = p.EntryA.Tree.Reserved.Exchange[TID].Get()
			local recB = p.EntryB.Tree.Reserved.Exchange[TID].Get()
			expect(
				`outcome={tostring(outcome)} unresolved={tostring(
					err ~= nil and string.find(err, "no verdict", 1, true) ~= nil
				)} aStaked={tostring(recA ~= nil and recA.Phase)} bStaked={tostring(recB ~= nil and recB.Phase)} aSword={tostring(
					p.DataA.Inventory["sword"].Get()
				)}`
			).to.equal("outcome=nil unresolved=true aStaked=Staked bStaked=Staked aSword=nil")
		end)
	end)

	it("REFUSES to settle against a verdict that does not govern this exchange", function()
		-- Corruption, not an expected branch. Settling against another basket's verdict
		-- would move value nobody agreed to move, so both records are left in place for
		-- an operator instead. Found by a surviving mutation: nothing covered this path.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local store = verdictStore()
			local deps = {
				ExchangeId = TID,
				VerdictStore = store,
				Flush = function()
					return true
				end,
			}
			-- Someone else's verdict is already sitting on this exchange id.
			store:UpdateAsync(TID, function()
				return { V = "Commit", A = A_ID, B = B_ID, D = "a-different-basket" }
			end)

			local outcome, err = Exchange.Attempt(deps, p.A, p.B)
			local recA = p.EntryA.Tree.Reserved.Exchange[TID].Get()

			expect(
				`outcome={tostring(outcome)} refused={tostring(
					err ~= nil and string.find(err, "does not govern", 1, true) ~= nil
				)} kept={tostring(recA ~= nil)} aSword={tostring(p.DataA.Inventory["sword"].Get())}`
			).to.equal("outcome=nil refused=true kept=true aSword=nil")
		end)
	end)

	it("resolves an exchange that was left staked, without the original attempt", function()
		-- The same code a later load or cadence tick runs. An exchange nobody is watching
		-- any more still reaches a terminal state, which is what makes the frozen tail
		-- recoverable rather than an operator forensics job.
		harnessed(function(harness)
			local p = pair(harness)
			basket(p)
			local blocked = true
			local store = verdictStore(function()
				return not blocked
			end)
			local deps = {
				ExchangeId = TID,
				VerdictStore = store,
				Flush = function()
					return true
				end,
			}
			Exchange.Attempt(deps, p.A, p.B)
			expect(p.EntryA.Tree.Reserved.Exchange[TID].Get() ~= nil).to.equal(true)

			blocked = false
			local digest = p.EntryA.Tree.Reserved.Exchange[TID].Get().Digest
			local outcome = Exchange.Resolve(deps, p.A, p.B, TID, digest, "Commit", nil)

			expect(
				`{tostring(outcome)} aShield={tostring(p.DataA.Inventory["shield"].Get() ~= nil)} bSword={tostring(
					p.DataB.Inventory["sword"].Get() ~= nil
				)} recA={tostring(p.EntryA.Tree.Reserved.Exchange[TID].Get())}`
			).to.equal("Committed aShield=true bSword=true recA=nil")
		end)
	end)
end
