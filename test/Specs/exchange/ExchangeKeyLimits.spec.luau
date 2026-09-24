--!nonstrict
-- DataStore key limits and recovery of legacy escrow records.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local A_ID, B_ID = 123456789, 9876543210
	local GUID = "12345678-1234-4321-8123-123456789abc"
	local LEGACY_ID = `{A_ID}-{B_ID}-{GUID}`
	local LEGACY_KEY = `legacy:{GUID}`
	local TEMPLATE = {
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 8 }),
	}
	local EXCHANGEABLE = { Items = { Path = { "Inventory" }, Kind = "Key" } }

	local function strictStore()
		local values, keys = {}, {}
		local function validate(key)
			assert(type(key) == "string" and #key > 0 and #key <= 50, "102: Key name exceeds the 50 character limit.")
			table.insert(keys, key)
		end
		local store = {
			UpdateAsync = function(_self, key, transform)
				validate(key)
				local result = transform(values[key])
				if result ~= nil then
					values[key] = result
				end
				return result
			end,
			GetAsync = function(_self, key)
				validate(key)
				return values[key]
			end,
		}
		return store, values, keys
	end

	local function proposal(kind, id)
		return { V = kind, A = A_ID, B = B_ID, D = `{id}#digest` }
	end

	local function harnessed(fn)
		local h = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
		local store, values, keys = strictStore()
		h.Ctx.Exchanges.VerdictStore = function()
			return store
		end
		local ok, err = pcall(fn, h, store, values, keys)
		h.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function pair(h)
		local pa, ea, da = h.Join(A_ID)
		local pb, eb, db = h.Join(B_ID)
		da.Inventory["blade"].Set({ Qty = 1 })
		db.Inventory["shield"].Set({ Qty = 1 })
		local function side(player, entry, item)
			return {
				Ctx = { Tree = entry.Tree, Entry = entry, Compiled = h.Compiled, UserId = player.UserId },
				UserId = player.UserId,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = item } },
			}
		end
		return {
			A = side(pa, ea, "blade"),
			B = side(pb, eb, "shield"),
			PA = pa,
			PB = pb,
			DA = da,
			DB = db,
		}
	end

	local function stage(p, id, claimedOnly)
		local digest = proposal("Abort", id).D
		assert(ExchangeLeg.Claim(p.A.Ctx, id, { Digest = digest, Role = "A", Partner = B_ID }))
		assert(ExchangeLeg.Claim(p.B.Ctx, id, { Digest = digest, Role = "B", Partner = A_ID }))
		if claimedOnly then
			return
		end
		assert(ExchangeLeg.Escrow(p.A.Ctx, id, p.A.Legs))
		assert(ExchangeLeg.Escrow(p.B.Ctx, id, p.B.Legs))
		assert(ExchangeLeg.FillTake(p.A.Ctx, id, p.B.Ctx.Tree.Reserved.Exchange[id].Get().Escrow))
		assert(ExchangeLeg.FillTake(p.B.Ctx, id, p.A.Ctx.Tree.Reserved.Exchange[id].Get().Escrow))
	end

	local function inventories(p)
		return `{tostring(p.DA.Inventory.blade.Get() ~= nil)}/{tostring(p.DA.Inventory.shield.Get() ~= nil)}`
			.. ` {tostring(p.DB.Inventory.blade.Get() ~= nil)}/{tostring(p.DB.Inventory.shield.Get() ~= nil)}`
	end

	describe("bounded verdict keys", function()
		it("commits a public trade between players with modern user ids", function()
			harnessed(function(h, _store, _values, keys)
				local p = pair(h)
				local outcome, why = h.Data.Exchange.Attempt(p.PA, p.A.Legs, p.PB, p.B.Legs)
				expect(`{outcome}/{tostring(why)}`).to.equal("Committed/nil")
				expect(#keys[1]).to.equal(36)
				expect(inventories(p)).to.equal("false/true true/false")
				expect(#h.Data.Exchange.Open(p.PA) + #h.Data.Exchange.Open(p.PB)).to.equal(0)
			end)
		end)

		it("refuses overlong and invalid UTF-8 new ids before claiming or staking", function()
			harnessed(function(h, store, _values, keys)
				local p = pair(h)
				local flushes = 0
				for _, id in { LEGACY_ID, string.rep("x", 51), string.char(255) } do
					local outcome, why = Exchange.Attempt({
						ExchangeId = id,
						VerdictStore = store,
						Flush = function()
							flushes += 1
							return true
						end,
					}, p.A, p.B)
					expect(outcome).to.equal(nil)
					expect(string.find(why, "at most 50", 1, true) ~= nil).to.equal(true)
				end
				expect(flushes + #keys).to.equal(0)
				expect(inventories(p)).to.equal("true/false false/true")
				expect(#h.Data.Exchange.Open(p.PA) + #h.Data.Exchange.Open(p.PB)).to.equal(0)
			end)
		end)

		it("keeps existing short and exactly-50-character verdict keys", function()
			local store, values, keys = strictStore()
			for _, id in { "existing-exchange", `940001-940002-{GUID}` } do
				values[id] = proposal("Commit", id)
				local verdict, decided = ExchangeVerdict.Propose(store, id, proposal("Abort", id))
				expect(verdict.V).to.equal("Commit")
				expect(decided).to.equal(false)
				expect(ExchangeVerdict.Read(store, id)).to.equal(values[id])
				expect(keys[#keys]).to.equal(id)
			end
		end)

		it("uses the same legacy key for proposal, retry, and read", function()
			local store, values, keys = strictStore()
			local first, decided, err = ExchangeVerdict.Propose(store, LEGACY_ID, proposal("Commit", LEGACY_ID))
			expect(`{first.V}/{tostring(decided)}/{tostring(err)}`).to.equal("Commit/true/nil")
			local retry, retryDecided = ExchangeVerdict.Propose(store, LEGACY_ID, proposal("Abort", LEGACY_ID))
			expect(retry.V).to.equal("Commit")
			expect(retryDecided).to.equal(false)
			expect(ExchangeVerdict.Read(store, LEGACY_ID)).to.equal(first)
			expect(first.Id).to.equal(LEGACY_ID)
			expect(first.D).to.equal(proposal("Commit", LEGACY_ID).D)
			expect(values[LEGACY_ID]).to.equal(nil)
			for _, key in keys do
				expect(key).to.equal(LEGACY_KEY)
			end
		end)

		it("refuses malformed legacy ids without touching the store", function()
			local store, _values, keys = strictStore()
			for _, id in { string.rep("x", 51), `{A_ID}-{B_ID}-{string.rep("g", 36)}`, LEGACY_ID .. "x" } do
				local verdict, _decided, err = ExchangeVerdict.Propose(store, id, proposal("Abort", id))
				expect(verdict).to.equal(nil)
				expect(type(err)).to.equal("string")
				local read, readErr = ExchangeVerdict.Read(store, id)
				expect(read).to.equal(nil)
				expect(readErr).to.equal(err)
			end
			expect(#keys).to.equal(0)
		end)

		it("refuses a legacy GUID collision without replacing its verdict", function()
			local store, values = strictStore()
			local first = ExchangeVerdict.Propose(store, LEGACY_ID, proposal("Commit", LEGACY_ID))
			local other = `{B_ID}-{A_ID}-{GUID}`
			local verdict, _decided, err = ExchangeVerdict.Propose(store, other, proposal("Abort", other))
			expect(verdict).to.equal(nil)
			expect(err).to.equal("verdict key belongs to another exchange")
			local read, readErr = ExchangeVerdict.Read(store, other)
			expect(read).to.equal(nil)
			expect(readErr).to.equal(err)
			expect(values[LEGACY_KEY]).to.equal(first)
		end)
	end)

	describe("legacy escrow recovery", function()
		it("aborts and returns both players' saved escrows after rejoining", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID)
				expect(inventories(p)).to.equal("false/false false/false")
				h.Leave(p.PA)
				h.Leave(p.PB)
				local pa, _ea, da = h.Join(A_ID)
				local pb, _eb, db = h.Join(B_ID)
				expect(inventories({ DA = da, DB = db })).to.equal("true/false false/true")
				expect(#h.Data.Exchange.Open(pa) + #h.Data.Exchange.Open(pb)).to.equal(0)
				expect(ExchangeVerdict.Read(store, LEGACY_ID).V).to.equal("Abort")
			end)
		end)

		it("honors an established legacy Commit during automatic recovery", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID)
				ExchangeVerdict.Propose(store, LEGACY_ID, proposal("Commit", LEGACY_ID))
				expect(h.Ctx.Exchanges.Resolve(p.A.Ctx.Entry)).to.equal(1)
				expect(h.Ctx.Exchanges.Resolve(p.B.Ctx.Entry)).to.equal(1)
				expect(inventories(p)).to.equal("false/true true/false")
				expect(h.Ctx.Exchanges.Resolve(p.A.Ctx.Entry)).to.equal(0)
				expect(inventories(p)).to.equal("false/true true/false")
			end)
		end)

		it("lets an operator abort legacy escrow and retry without duplicating items", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID)
				expect(h.Ctx.Exchanges.Settle(LEGACY_ID, "Abort")).to.equal(true)
				expect(inventories(p)).to.equal("true/false false/true")
				expect(h.Ctx.Exchanges.Settle(LEGACY_ID, "Abort")).to.equal(false)
				expect(inventories(p)).to.equal("true/false false/true")
				expect(ExchangeVerdict.Read(store, LEGACY_ID).V).to.equal("Abort")
			end)
		end)

		it("uses the mapped read when discarding an unstaked legacy claim", function()
			harnessed(function(h, _store, _values, keys)
				local p = pair(h)
				stage(p, LEGACY_ID, true)
				expect(h.Ctx.Exchanges.Discard(LEGACY_ID)).to.equal(true)
				expect(keys[#keys]).to.equal(LEGACY_KEY)
				expect(#h.Data.Exchange.Open(p.PA) + #h.Data.Exchange.Open(p.PB)).to.equal(0)
				expect(inventories(p)).to.equal("true/false false/true")
			end)
		end)

		it("refuses to discard a legacy claim with an existing verdict", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID, true)
				ExchangeVerdict.Propose(store, LEGACY_ID, proposal("Abort", LEGACY_ID))
				local ok, why = h.Ctx.Exchanges.Discard(LEGACY_ID)
				expect(ok).to.equal(false)
				expect(string.find(why, "already has a Abort verdict", 1, true) ~= nil).to.equal(true)
				expect(#h.Data.Exchange.Open(p.PA) + #h.Data.Exchange.Open(p.PB)).to.equal(2)
			end)
		end)

		it("keeps escrow intact when the mapped verdict belongs to another exchange", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID)
				local other = `{B_ID}-{A_ID}-{GUID}`
				ExchangeVerdict.Propose(store, other, proposal("Commit", other))
				expect(h.Ctx.Exchanges.Resolve(p.A.Ctx.Entry)).to.equal(0)
				expect(h.Ctx.Exchanges.Settle(LEGACY_ID, "Abort")).to.equal(false)
				expect(inventories(p)).to.equal("false/false false/false")
				expect(h.Data.Exchange.Open(p.PA)[1].State).to.equal("Staked")
				expect(#p.A.Ctx.Tree.Reserved.Exchange[LEGACY_ID].Get().Escrow).to.equal(1)
			end)
		end)

		it("refuses operator settlement against mismatched participants", function()
			harnessed(function(h, store)
				local p = pair(h)
				stage(p, LEGACY_ID)
				local wrong = proposal("Commit", LEGACY_ID)
				wrong.B = B_ID + 1
				ExchangeVerdict.Propose(store, LEGACY_ID, wrong)
				local ok, why = h.Ctx.Exchanges.Settle(LEGACY_ID, "Abort")
				expect(ok).to.equal(false)
				expect(string.find(why, "participant mismatch", 1, true) ~= nil).to.equal(true)
				expect(inventories(p)).to.equal("false/false false/false")
				expect(#h.Data.Exchange.Open(p.PA) + #h.Data.Exchange.Open(p.PB)).to.equal(2)
			end)
		end)
	end)
end
