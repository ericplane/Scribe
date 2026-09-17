--!nonstrict
-- A Commit releases each escrow, so both takes must be on disk before the verdict exists.
-- Attempt proves that with forced flushes; the operator Settle did not.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_durable"
	local A_ID, B_ID = 94501, 94502
	local KEY_A, KEY_B = "Default/PLAYER_94501", "Default/PLAYER_94502"

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- Both sides staked and both takes filled, and nothing flushed since.
	local function taken(harness)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		harness.Data.Get(pa).Inventory["a_item"].Set({ Qty = 1 })
		harness.Data.Get(pb).Inventory["b_item"].Set({ Qty = 1 })
		harness.Data.Flush(pa)
		harness.Data.Flush(pb)
		local A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID }
		local B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID }
		ExchangeLeg.Claim(A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
		ExchangeLeg.Claim(B.Ctx, TID, { Digest = "d", Role = "B", Partner = A_ID })
		ExchangeLeg.Escrow(A.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "a_item" } })
		ExchangeLeg.Escrow(B.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "b_item" } })
		ExchangeLeg.FillTake(B.Ctx, TID, A.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
		ExchangeLeg.FillTake(A.Ctx, TID, B.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow)
		return A, B
	end

	local function persistedTake(harness, key): boolean
		local stored = harness.Fake.Persisted[key]
		local reserved = if type(stored) == "table" then stored._Scribe else nil
		local record = if type(reserved) == "table" and type(reserved.Exchange) == "table"
			then reserved.Exchange[TID]
			else nil
		return type(record) == "table" and type(record.Take) == "table" and record.Take[1] ~= nil
	end

	it("refuses to Commit while a record cannot be proved durable, and writes no verdict", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local A, B = taken(harness)
		harness.Fake.FailSaves = true
		local ok, reason = harness.Ctx.Exchanges.Settle(TID, "Commit")
		harness.Fake.FailSaves = false

		local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)
		expect(
			`ok={tostring(ok)} verdict={tostring(verdict and verdict.V)} recA={tostring(
				A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
			)} recB={tostring(B.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)} named={tostring(
				string.find(tostring(reason), "durable", 1, true) ~= nil
			)}`
		).to.equal("ok=false verdict=nil recA=true recB=true named=true")
		harness.Cleanup()
	end)

	it("puts both takes on disk before the Commit verdict exists", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		taken(harness)
		expect(`a={tostring(persistedTake(harness, KEY_A))} b={tostring(persistedTake(harness, KEY_B))}`).to.equal(
			"a=false b=false"
		)

		local ok, reason = harness.Ctx.Exchanges.Settle(TID, "Commit")
		local verdict = ExchangeVerdict.Read(harness.Ctx.Exchanges.VerdictStore(), TID)
		expect(
			`ok={tostring(ok)} verdict={tostring(verdict and verdict.V)} a={tostring(persistedTake(harness, KEY_A))} b={tostring(
				persistedTake(harness, KEY_B)
			)} reason={tostring(reason)}`
		).to.equal("ok=true verdict=Commit a=true b=true reason=settled as Commit")
		harness.Cleanup()
	end)

	it("Abort needs no durability proof, since it returns escrow to its owner", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local A, B = taken(harness)
		harness.Fake.FailSaves = true
		local ok = harness.Ctx.Exchanges.Settle(TID, "Abort")
		harness.Fake.FailSaves = false
		expect(
			`ok={tostring(ok)} a={tostring(A.Ctx.Tree.Accessor.Inventory["a_item"].Get() ~= nil)} b={tostring(
				B.Ctx.Tree.Accessor.Inventory["b_item"].Get() ~= nil
			)}`
		).to.equal("ok=true a=true b=true")
		harness.Cleanup()
	end)
end
