--!nonstrict
-- S1, S2, S3: the settle is infallible by construction, and the inbox is a real
-- terminal state rather than a hope.
--
-- WHY S1 IS THE GATE FOR THE WHOLE DESIGN. Five earlier designs of this feature died
-- to the same pattern: a FALLIBLE operation sited AFTER the point of no return. The
-- restructure's answer is that after the verdict there are exactly two kinds of
-- operation, SETTLE which cannot be refused, and DELIVER which can fail but rolls
-- back leaving the inbox entry intact and is retried forever.
--
-- "Cannot be refused" is a claim about WHERE it writes. Nothing under the reserved
-- root has a declared shape, a cap, a bound, a Closed record, a Timed sweep, a derived
-- field or a seed path, so nothing data-dependent can refuse a write there. The moment
-- a settle touches one game path that claim is false, and the design is back to the
-- class that killed its five predecessors.
--
-- So S1 does not take that on trust and does not test it by inspection. It wraps the
-- tree's own op sink and records the path of EVERY write the settle emits.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local Util = require(Root.Scribe.Internal.Util)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RESERVED = Template.RESERVED_ROOT
	local TID = "tid_settle_1"
	local COMMIT = { V = "Commit", D = "digest-1" }
	local ABORT = { V = "Abort", D = "digest-1" }

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000 }),
				Inventory = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 99 }),
				}, { MaxKeys = 3 }),
			},
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function ctxFor(harness, player, entry)
		return {
			Tree = entry.Tree,
			Entry = entry,
			Compiled = harness.Compiled,
			UserId = player.UserId,
		}
	end

	local function attempt(fn, ...): string
		local args = table.pack(...)
		local pok, ok, err = pcall(fn, table.unpack(args, 1, args.n))
		if not pok then
			return `RAISED {tostring(ok)}`
		end
		return if ok then "OK" else `REFUSED {tostring(err)}`
	end

	--- Stake one item and one quantity, then hand this profile a Take, the way the
	--- counterparty's escrow fills it before any verdict exists.
	local function staked(harness, player, entry)
		local ctx = ctxFor(harness, player, entry)
		local data = harness.Data.Get(player)
		data.Inventory["mine"].Set({ Qty = 2 })
		data.Coins.Set(300)

		expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal("OK")
		expect(attempt(ExchangeLeg.Escrow, ctx, TID, {
			{ Path = { "Inventory" }, Kind = "Key", Key = "mine" },
			{ Path = { "Coins" }, Kind = "Qty", Amount = 100 },
		})).to.equal("OK")

		-- The Take: what the counterparty staked, already durable on this key.
		local record = entry.Tree.Reserved.Exchange[TID].Get()
		record.Take = { { Path = { "Inventory" }, Kind = "Key", Key = "theirs", Value = { Qty = 5 } } }
		return ctx, data
	end

	--- Deep equality over stored game data, so "nothing changed" is a real comparison.
	local function sameDeep(a, b): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for key, value in a do
			if not sameDeep(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end

	--- Record the path of every op the tree emits while `fn` runs.
	---
	--- Node emits one op per real write through applySet, and a transaction dispatches
	--- them on commit, so this sees exactly what the settle wrote and nothing else.
	local function opPathsDuring(entry, fn): { string }
		local params = entry.Tree.Params
		local original = params.OnOp
		local seen = {}
		params.OnOp = function(op, schema)
			table.insert(seen, Util.pathString(op.Path))
			if original then
				return original(op, schema)
			end
			return nil
		end
		local ok, err = pcall(fn)
		params.OnOp = original
		if not ok then
			error(err, 0)
		end
		return seen
	end

	describe("S1: a settle writes only under the reserved root", function()
		it("emits no op outside _Scribe on a Commit, and the op sink proves it", function()
			harnessed(function(harness)
				local player, entry = harness.Join(94001)
				local ctx = staked(harness, player, entry)

				local paths
				local result
				local ok = pcall(function()
					paths = opPathsDuring(entry, function()
						result = attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)
					end)
				end)

				local outside = {}
				for _, path in paths or {} do
					if string.sub(path, 1, #RESERVED) ~= RESERVED then
						table.insert(outside, path)
					end
				end
				-- The op count is asserted as a real number, not restated on both sides:
				-- a settle that emitted nothing at all would satisfy "no op outside
				-- _Scribe" perfectly while doing nothing.
				expect(
					`hook={tostring(ok)} settle={result} wrote={tostring(#(paths or {}) > 0)} outside={table.concat(
						outside,
						","
					)}`
				).to.equal("hook=true settle=OK wrote=true outside=")
			end)
		end)

		it("emits no op outside _Scribe on an Abort either, which returns the escrow", function()
			harnessed(function(harness)
				local player, entry = harness.Join(94002)
				local ctx = staked(harness, player, entry)

				local paths
				local result
				paths = opPathsDuring(entry, function()
					result = attempt(ExchangeLeg.Settle, ctx, TID, ABORT)
				end)

				local outside = {}
				for _, path in paths do
					if string.sub(path, 1, #RESERVED) ~= RESERVED then
						table.insert(outside, path)
					end
				end
				expect(`settle={result} outside={table.concat(outside, ",")}`).to.equal("settle=OK outside=")
				expect(#paths > 0).to.equal(true)
			end)
		end)

		it("leaves game data byte-identical across a settle, checked independently of the op sink", function()
			-- Belt and braces. The op sink proves nothing was WRITTEN; this proves
			-- nothing CHANGED, which is the property that actually matters and which
			-- would survive an op sink that silently stopped being called.
			harnessed(function(harness)
				local player, entry = harness.Join(94003)
				local ctx = staked(harness, player, entry)

				-- Snapshot every declared game root, not only the ones this exchange names.
				local before = {}
				for _, root in { "Coins", "Inventory" } do
					before[root] = Util.deepClone(entry.LiveData[root])
				end

				local result = attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)

				local drifted = {}
				for root, snapshot in before do
					if not sameDeep(snapshot, entry.LiveData[root]) then
						table.insert(drifted, root)
					end
				end
				table.sort(drifted)
				expect(`{result} drifted={table.concat(drifted, ",")}`).to.equal("OK drifted=")

				-- And the comparison can actually detect drift, or the case is vacuous.
				entry.LiveData.Coins = (entry.LiveData.Coins :: any) + 1
				expect(sameDeep(before.Coins, entry.LiveData.Coins)).to.equal(false)
			end)
		end)

		it("is idempotent: a second settle from the same verdict is a no-op", function()
			-- P7 in the crash matrix. A settle that reverted and re-ran must produce the
			-- identical result, which is why the record removal is fused with the move.
			harnessed(function(harness)
				local player, entry = harness.Join(94004)
				local ctx = staked(harness, player, entry)

				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				local firstInbox = Util.deepClone(entry.Tree.Reserved.ExchangeInbox[TID].Get())
				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				local secondInbox = entry.Tree.Reserved.ExchangeInbox[TID].Get()

				expect(
					`legs={#secondInbox.Legs} same={tostring(#firstInbox.Legs == #secondInbox.Legs)} record={tostring(
						entry.Tree.Reserved.Exchange[TID].Get()
					)}`
				).to.equal("legs=1 same=true record=nil")
			end)
		end)

		it("REFUSES to settle against a verdict for a different basket", function()
			harnessed(function(harness)
				local player, entry = harness.Join(94005)
				local ctx = staked(harness, player, entry)

				local result = attempt(ExchangeLeg.Settle, ctx, TID, { V = "Commit", D = "digest-OTHER" })
				expect(
					`refused={tostring(string.find(result, "digest does not match", 1, true) ~= nil)} record={tostring(
						entry.Tree.Reserved.Exchange[TID].Get() ~= nil
					)}`
				).to.equal("refused=true record=true")
			end)
		end)
	end)

	describe("the slot: one exchange at a time, and only an empty claim may be released", function()
		it("REFUSES a second claim while one is already in flight", function()
			-- The emptiness test runs inside the claim transaction, so there is no
			-- instant at which a profile already in an exchange advertises a free slot.
			harnessed(function(harness)
				local player, entry = harness.Join(94401)
				local ctx = ctxFor(harness, player, entry)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "d1" })).to.equal("OK")
				local second = attempt(ExchangeLeg.Claim, ctx, "tid_other", { Digest = "d2" })

				expect(
					`refused={tostring(string.find(second, "already has", 1, true) ~= nil)} other={tostring(
						entry.Tree.Reserved.Exchange["tid_other"].Get()
					)}`
				).to.equal("refused=true other=nil")
			end)
		end)

		it("releases a claim that never took value", function()
			harnessed(function(harness)
				local player, entry = harness.Join(94402)
				local ctx = ctxFor(harness, player, entry)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "d1" })).to.equal("OK")
				expect(attempt(ExchangeLeg.Unclaim, ctx, TID)).to.equal("OK")
				expect(entry.Tree.Reserved.Exchange[TID].Get()).to.equal(nil)

				-- And the slot is free again.
				expect(attempt(ExchangeLeg.Claim, ctx, "tid_next", { Digest = "d2" })).to.equal("OK")
			end)
		end)

		it("REFUSES to release a record that already holds escrowed value", function()
			-- Once any escrow has committed, the only exit is the verdict. Dropping a
			-- staked record here would destroy the value it holds with nothing left to
			-- say where it went, which is the shape the design forbids by name.
			harnessed(function(harness)
				local player, entry = harness.Join(94403)
				local ctx = staked(harness, player, entry)

				local result = attempt(ExchangeLeg.Unclaim, ctx, TID)
				expect(
					`refused={tostring(string.find(result, "only the verdict may release it", 1, true) ~= nil)} kept={tostring(
						entry.Tree.Reserved.Exchange[TID].Get() ~= nil
					)}`
				).to.equal("refused=true kept=true")
			end)
		end)
	end)

	describe("S2: a settle succeeds against a profile that can accept nothing", function()
		it("settles into the inbox with the inventory full, the balance at Max and the key occupied", function()
			-- Every destination the delivery could want is hostile. The settle must not
			-- care, because it does not touch any of them.
			harnessed(function(harness)
				local player, entry = harness.Join(94101)
				local ctx = staked(harness, player, entry)
				local data = harness.Data.Get(player)

				-- The staked item left a free slot; fill every one of them, and the balance.
				data.Inventory["a"].Set({ Qty = 1 })
				data.Inventory["b"].Set({ Qty = 1 })
				data.Inventory["theirs"].Set({ Qty = 1 })
				data.Coins.Set(1000)

				local result = attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)
				local inbox = entry.Tree.Reserved.ExchangeInbox[TID].Get()
				expect(
					`{result} inbox={tostring(inbox ~= nil)} legs={tostring(inbox and #inbox.Legs)} full={data.Inventory.Count()}`
				).to.equal("OK inbox=true legs=1 full=3")
			end)
		end)

		it("then PARKS the delivery instead of failing the exchange, and the value stays in the inbox", function()
			harnessed(function(harness)
				local player, entry = harness.Join(94102)
				local ctx = staked(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["a"].Set({ Qty = 1 })
				data.Inventory["b"].Set({ Qty = 1 })
				data.Inventory["theirs"].Set({ Qty = 1 })

				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				local delivered = attempt(ExchangeLeg.Deliver, ctx, TID)

				expect(
					`parked={tostring(delivered ~= "OK")} held={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
					)}`
				).to.equal("parked=true held=true")
			end)
		end)

		it("and delivers on a later retry once the player makes room, with nothing lost in between", function()
			-- This is what makes the inbox a terminal state rather than a nicer name for
			-- a stuck exchange. The value waits where the player can see it and lands the
			-- moment the destination stops being hostile.
			harnessed(function(harness)
				local player, entry = harness.Join(94103)
				local ctx = staked(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["a"].Set({ Qty = 1 })
				data.Inventory["b"].Set({ Qty = 1 })
				data.Inventory["theirs"].Set({ Qty = 1 })

				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				expect(attempt(ExchangeLeg.Deliver, ctx, TID) ~= "OK").to.equal(true)

				-- The player sells the blocker.
				data.Inventory["theirs"].Set(nil)
				local retried = attempt(ExchangeLeg.Deliver, ctx, TID)
				local landed = data.Inventory["theirs"].Get()

				expect(
					`{retried} qty={tostring(landed and landed.Qty)} inbox={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get()
					)}`
				).to.equal("OK qty=5 inbox=nil")
			end)
		end)
	end)

	describe("S3: no post-verdict failure is permanent", function()
		--- Settle, then try to deliver into a destination made hostile in one specific
		--- way, and report whether the value is still recoverable.
		local function parkThenRecover(harness, hostile, relieve): string
			local player, entry = harness.Join(94200 + math.random(1, 500))
			local ctx = staked(harness, player, entry)
			local data = harness.Data.Get(player)
			hostile(data)

			expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
			local first = attempt(ExchangeLeg.Deliver, ctx, TID)
			local heldAfterPark = entry.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
			relieve(data)
			local second = attempt(ExchangeLeg.Deliver, ctx, TID)
			local cleared = entry.Tree.Reserved.ExchangeInbox[TID].Get() == nil
			return `parked={tostring(first ~= "OK")} held={tostring(heldAfterPark)} retried={second} cleared={tostring(
				cleared
			)}`
		end

		it("an occupied destination key parks and then delivers", function()
			harnessed(function(harness)
				expect(parkThenRecover(harness, function(data)
					data.Inventory["theirs"].Set({ Qty = 1 })
				end, function(data)
					data.Inventory["theirs"].Set(nil)
				end)).to.equal("parked=true held=true retried=OK cleared=true")
			end)
		end)

		it("a full container parks and then delivers", function()
			harnessed(function(harness)
				expect(parkThenRecover(harness, function(data)
					data.Inventory["a"].Set({ Qty = 1 })
					data.Inventory["b"].Set({ Qty = 1 })
					data.Inventory["c"].Set({ Qty = 1 })
				end, function(data)
					data.Inventory["c"].Set(nil)
				end)).to.equal("parked=true held=true retried=OK cleared=true")
			end)
		end)

		it("never leaves the value in neither place: a parked delivery still holds every leg", function()
			-- The failure mode this whole section exists to exclude. A delivery that
			-- rolled back halfway would leave the inbox entry present but short a leg,
			-- and the retry would then deliver less than was staked.
			harnessed(function(harness)
				local player, entry = harness.Join(94301)
				local ctx = staked(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["theirs"].Set({ Qty = 1 })

				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				local before = #entry.Tree.Reserved.ExchangeInbox[TID].Get().Legs
				expect(attempt(ExchangeLeg.Deliver, ctx, TID) ~= "OK").to.equal(true)
				local after = #entry.Tree.Reserved.ExchangeInbox[TID].Get().Legs

				expect(`before={before} after={after}`).to.equal("before=1 after=1")
			end)
		end)
	end)
end
