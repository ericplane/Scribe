--!nonstrict
-- X1: what happened is decided by RE-READING the tree, never by the pcall boundary.
--
-- `pcall(Data.Transaction, ...)` returning false has FIVE distinct causes in Node and
-- only one of them is "nothing committed":
--
--   a dead tree                          nothing committed
--   a nested transaction                 nothing committed
--   a transaction open on another player nothing committed
--   a FAILED ROLLBACK                    nothing committed, tree possibly PARTIAL
--   a throw from OnOp / OnEconomy        the writes ALREADY COMMITTED
--
-- The last one is the trap. Those handlers are dispatched unguarded AFTER `_txn` is
-- cleared, so by the time the throw reaches the caller the transaction has committed
-- and the record is on the tree. A module that reads `raised == true` as "the step did
-- not happen" will unclaim a slot that is genuinely held, or re-run a stake that has
-- already moved value, and it will do it while reporting success.
--
-- The inverse is just as wrong and is why "did it raise?" is the wrong question in
-- both directions. The only sound answer is to look at what is actually there.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local Util = require(Root.Scribe.Internal.Util)
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RESERVED = Template.RESERVED_ROOT
	local TID = "tid_x1"
	local A_ID, B_ID = 96501, 96502

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
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

	--- Make the tree's op sink throw once a write lands on a path under `prefix`.
	---
	--- This reproduces the OnOp throw exactly: Node dispatches the sink after clearing
	--- `_txn`, so the write is already committed when the error escapes.
	local function throwAfterWriteTo(entry, prefix: string)
		local params = entry.Tree.Params
		local original = params.OnOp
		local armed = true
		params.OnOp = function(op, schema)
			local result = if original then original(op, schema) else nil
			if armed and string.sub(Util.pathString(op.Path), 1, #prefix) == prefix then
				armed = false
				error("post-commit listener exploded", 0)
			end
			return result
		end
		return function()
			params.OnOp = original
		end
	end

	local function verdictStore()
		local keys = {}
		return {
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

	it("MEASURES the trap: a post-commit listener throw leaves the write committed", function()
		-- The premise, pinned before anything is asserted about how Exchange reacts to it.
		-- If Node ever stopped committing in this case, every case below would be
		-- testing a situation that cannot arise.
		harnessed(function(harness)
			local player, entry = harness.Join(A_ID)
			local ctx = ctxFor(harness, player, entry)
			local restore = throwAfterWriteTo(entry, RESERVED)

			local pok, ok = pcall(ExchangeLeg.Claim, ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			restore()

			local record = entry.Tree.Reserved.Exchange[TID].Get()
			expect(`raised={tostring(not pok)} returned={tostring(ok)} committed={tostring(record ~= nil)}`).to.equal(
				"raised=true returned=post-commit listener exploded committed=true"
			)
		end)
	end)

	it("does not abandon a claim that COMMITTED just because the call raised", function()
		-- The defect this spec exists for. A raise after the commit means the slot is
		-- genuinely held. Treating it as "the claim did not happen" abandons an exchange
		-- that is already half constructed, and on the other side it would unclaim a
		-- record that is holding value.
		harnessed(function(harness)
			local pa, ea = harness.Join(A_ID)
			local pb, eb = harness.Join(B_ID)
			local da = harness.Data.Get(pa)
			da.Inventory["sword"].Set({ Qty = 1 })

			local restore = throwAfterWriteTo(ea, RESERVED)
			local outcome, err = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
			}, {
				Ctx = ctxFor(harness, pa, ea),
				UserId = A_ID,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "sword" } },
			}, { Ctx = ctxFor(harness, pb, eb), UserId = B_ID, Legs = {} })
			restore()

			-- The exchange must go through. A listener that throws is the game's bug, not a
			-- reason to lose an exchange whose steps all landed.
			expect(
				`outcome={tostring(outcome)} err={tostring(err)} moved={tostring(
					harness.Data.Get(pb).Inventory["sword"].Get() ~= nil
				)}`
			).to.equal("outcome=Committed err=nil moved=true")
		end)
	end)

	it("still abandons when the step genuinely did NOT commit", function()
		-- The other direction, and the control. If the module simply ignored raises it
		-- would pass the case above while being just as wrong. A step that really left
		-- nothing behind must still abandon, and nothing may move.
		harnessed(function(harness)
			local pa, ea = harness.Join(A_ID)
			local pb, eb = harness.Join(B_ID)
			local da = harness.Data.Get(pa)
			da.Inventory["sword"].Set({ Qty = 1 })
			da.Coins.Set(10)

			local outcome, err = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				Flush = function()
					return true
				end,
			}, {
				Ctx = ctxFor(harness, pa, ea),
				UserId = A_ID,
				-- A leg that cannot apply: the balance is 10 and the leg wants 9999.
				Legs = { { Path = { "Coins" }, Kind = "Qty", Amount = 9999 } },
			}, { Ctx = ctxFor(harness, pb, eb), UserId = B_ID, Legs = {} })

			expect(
				`outcome={tostring(outcome)} refused={tostring(err ~= nil)} sword={tostring(
					da.Inventory["sword"].Get() ~= nil
				)} coins={da.Coins.Get()} record={tostring(ea.Tree.Reserved.Exchange[TID].Get())}`
			).to.equal("outcome=nil refused=true sword=true coins=10 record=nil")
		end)
	end)

	it("does not treat a stake that COMMITTED as unstaked, which would double-move value", function()
		-- The most expensive version of the same mistake. If a post-commit throw on the
		-- escrow transaction were read as "the stake did not happen", the module would
		-- either abandon a profile that is already holding escrowed value, or re-run the
		-- stake against a container the first run already emptied.
		harnessed(function(harness)
			local player, entry = harness.Join(A_ID)
			local ctx = ctxFor(harness, player, entry)
			local data = harness.Data.Get(player)
			data.Inventory["sword"].Set({ Qty = 1 })

			expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = B_ID }))).to.equal(true)

			local restore = throwAfterWriteTo(entry, RESERVED)
			pcall(ExchangeLeg.Escrow, ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "sword" } })
			restore()

			-- Whatever the call reported, the tree is the authority: the item left game
			-- data and is sitting in the escrow exactly once.
			local record = entry.Tree.Reserved.Exchange[TID].Get()
			local escrowed = if record and record.Escrow then #record.Escrow else 0
			expect(
				`inGame={tostring(data.Inventory["sword"].Get() ~= nil)} escrowed={escrowed} phase={tostring(
					record and record.Phase
				)}`
			).to.equal("inGame=false escrowed=1 phase=Staked")
		end)
	end)
end
