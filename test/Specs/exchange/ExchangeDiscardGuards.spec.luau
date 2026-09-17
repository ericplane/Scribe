--!nonstrict
-- Discard removes a record without a verdict, so its two guards are the whole safety: a
-- failed verdict read is not an absent verdict, and a Claimed record with a take is owed
-- value. Without them a committed one-way transfer vanished from both profiles.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_discard"
	local A_ID, B_ID = 94401, 94402

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- A one-way transfer: B escrows nothing, so its record stays Claimed with a take.
	local function transfer(harness)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		harness.Data.Get(pa).Inventory["gift"].Set({ Qty = 1 })
		local A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID }
		local B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID }
		expect(select(1, ExchangeLeg.Claim(A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID }))).to.equal(true)
		expect(select(1, ExchangeLeg.Claim(B.Ctx, TID, { Digest = "d", Role = "B", Partner = A_ID }))).to.equal(true)
		expect(select(1, ExchangeLeg.Escrow(A.Ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "gift" } }))).to.equal(
			true
		)
		expect(select(1, ExchangeLeg.FillTake(B.Ctx, TID, A.Ctx.Tree.Reserved.Exchange[TID].Get().Escrow))).to.equal(
			true
		)
		expect(select(1, ExchangeLeg.FillTake(A.Ctx, TID, {}))).to.equal(true)
		return A, B
	end

	--- Where the gift is: in a bag, in an escrow, in a take, or in an inbox.
	local function whereabouts(A, B): string
		local places = {}
		for label, side in { A = A, B = B } do
			if side.Ctx.Tree.Accessor.Inventory["gift"].Get() ~= nil then
				table.insert(places, `{label}.bag`)
			end
			local record = side.Ctx.Tree.Reserved.Exchange[TID].Get()
			if type(record) == "table" then
				if type(record.Escrow) == "table" and record.Escrow[1] ~= nil then
					table.insert(places, `{label}.escrow`)
				end
				if type(record.Take) == "table" and record.Take[1] ~= nil then
					table.insert(places, `{label}.take`)
				end
			end
			if side.Ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil then
				table.insert(places, `{label}.inbox`)
			end
		end
		table.sort(places)
		return table.concat(places, ",")
	end

	it("refuses when the verdict key cannot be read, instead of treating the failure as no verdict", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local A, B = transfer(harness)
		local store = harness.Ctx.Exchanges.VerdictStore()
		local verdict = ExchangeVerdict.Propose(store, TID, { V = "Commit", A = A_ID, B = B_ID, D = "d" })
		-- The giver has settled, so B's take is the only copy left.
		expect(select(1, ExchangeLeg.Settle(A.Ctx, TID, verdict))).to.equal(true)
		expect(whereabouts(A, B)).to.equal("B.take")

		local realGet = store.GetAsync
		store.GetAsync = function()
			error("verdict store unreachable")
		end
		local ok, reason = harness.Ctx.Exchanges.Discard(TID)
		store.GetAsync = realGet

		expect(
			`ok={tostring(ok)} where={whereabouts(A, B)} named={tostring(
				string.find(tostring(reason), "read", 1, true) ~= nil
			)}`
		).to.equal("ok=false where=B.take named=true")

		expect(select(1, ExchangeLeg.Settle(B.Ctx, TID, verdict))).to.equal(true)
		expect(select(1, ExchangeLeg.Deliver(B.Ctx, TID))).to.equal(true)
		expect(whereabouts(A, B)).to.equal("B.bag")
		harness.Cleanup()
	end)

	it("refuses a Claimed record whose take already names incoming value", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local A, B = transfer(harness)
		expect(whereabouts(A, B)).to.equal("A.escrow,B.take")

		local ok, reason = harness.Ctx.Exchanges.Discard(TID)
		expect(`ok={tostring(ok)} where={whereabouts(A, B)} reason={tostring(reason ~= nil)}`).to.equal(
			"ok=false where=A.escrow,B.take reason=true"
		)
		harness.Cleanup()
	end)

	it("still drops a claim that took nothing, which is the control", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		local A = { Ctx = ctxFor(harness, pa, ea), UserId = A_ID }
		local B = { Ctx = ctxFor(harness, pb, eb), UserId = B_ID }
		ExchangeLeg.Claim(A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
		ExchangeLeg.Claim(B.Ctx, TID, { Digest = "d", Role = "B", Partner = A_ID })

		local ok = harness.Ctx.Exchanges.Discard(TID)
		expect(
			`ok={tostring(ok)} recA={tostring(A.Ctx.Tree.Reserved.Exchange[TID].Get())} recB={tostring(
				B.Ctx.Tree.Reserved.Exchange[TID].Get()
			)}`
		).to.equal("ok=true recA=nil recB=nil")
		harness.Cleanup()
	end)
end
