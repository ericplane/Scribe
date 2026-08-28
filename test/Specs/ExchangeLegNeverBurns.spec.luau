--!nonstrict
-- ROUND 4: the two ways the settle/deliver pair can destroy value on the ordinary
-- path, with no crash, one server, one thread, everything reporting success.
--
-- Both were found by attacking the surface the fourth round was pointed at, and both
-- share a shape the earlier rounds did not reach: the primitive is correct about the
-- state it was written for and silently wrong about a state the protocol can also
-- reach. A guard that only holds for the shapes the happy path produces is not a
-- guard, and neither of these had a spec because every existing Key-leg case used a
-- RECORD element and every existing Settle case filled the Take first.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_burn_1"
	local COMMIT = { V = "Commit", D = "digest-1" }
	local ABORT = { V = "Abort", D = "digest-1" }

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000 }),
				-- A SCALAR-element container. First class: Template only rejects an
				-- element whose Children table is empty, so an int element compiles,
				-- and ExchangeLeg.Refuse accepts it as a Key path because the only shape
				-- test for Kind "Key" is that the container is not a Leaf.
				Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0, Max = 999 }), { MaxKeys = 4 }),
				-- The record-element control, which is the only shape the rest of the
				-- Key-leg battery has ever used.
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

	local function attempt(fn, ...): string
		local args = table.pack(...)
		local pok, ok, err = pcall(fn, table.unpack(args, 1, args.n))
		if not pok then
			return `RAISED {tostring(ok)}`
		end
		return if ok then "OK" else `REFUSED {tostring(err)}`
	end

	describe("a Key leg on a scalar-element container", function()
		it("delivers, rather than raising forever on a payload that is not a table", function()
			-- THE DEFECT. giveKey proves the content of a delivered element by walking
			-- its fields. On a scalar element the payload IS the value, so the walk
			-- iterates a number and raises inside the transaction. Deliver then rolls
			-- back and parks, identically, on every load and every sweep tick, for the
			-- life of the profile: the item is owed and can never be paid.
			harnessed(function(harness)
				local player, entry = harness.Join(70401)
				local ctx = ctxFor(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Resources["ore"].Set(7)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(attempt(ExchangeLeg.Escrow, ctx, TID, { { Path = { "Resources" }, Kind = "Key", Key = "ore" } })).to.equal(
					"OK"
				)
				-- Abort routes this profile own escrow back to its own inbox, which is
				-- the shortest ordinary route from a stake to a delivery.
				expect(attempt(ExchangeLeg.Settle, ctx, TID, ABORT)).to.equal("OK")

				expect(attempt(ExchangeLeg.Deliver, ctx, TID)).to.equal("OK")
				expect(
					`ore={tostring(data.Resources["ore"].Get())} inbox={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get()
					)}`
				).to.equal("ore=7 inbox=nil")
			end)
		end)

		it("still REFUSES a scalar payload that does not match what landed", function()
			-- The proof has to keep biting. A guard rewritten to skip the content check
			-- for non-table payloads would pass the case above while delivering a value
			-- nobody staked, so the scalar comparison is asserted independently. Max is
			-- 999, so a payload of 4000 clamps on write and cannot match itself.
			harnessed(function(harness)
				local player, entry = harness.Join(70402)
				local ctx = ctxFor(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Resources["ore"].Set(7)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(attempt(ExchangeLeg.Escrow, ctx, TID, { { Path = { "Resources" }, Kind = "Key", Key = "ore" } })).to.equal(
					"OK"
				)
				expect(attempt(ExchangeLeg.Settle, ctx, TID, ABORT)).to.equal("OK")

				local parked = entry.Tree.Reserved.ExchangeInbox[TID].Get()
				parked.Legs[1].Value = 4000
				entry.Tree.Reserved.ExchangeInbox[TID].Set(parked)

				local outcome = attempt(ExchangeLeg.Deliver, ctx, TID)
				expect(
					`outcome={if string.find(outcome, "did not store", 1, true) then "REFUSED-CONTENT" else outcome} ore={tostring(
						data.Resources["ore"].Get()
					)}`
				).to.equal("outcome=REFUSED-CONTENT ore=nil")
			end)
		end)
	end)

	describe("a Commit against a record whose Take was never filled", function()
		it("REFUSES rather than dropping the escrow, because the Take is the only copy", function()
			-- THE DEFECT. Settle Commit branch moves record.Take to the inbox and drops
			-- record.Escrow, and that is safe ONLY because the counterparty copy was
			-- made durable before any verdict could exist. With no Take the
			-- `type(moved) == "table"` test fails, nothing is written to the inbox, and
			-- control falls straight through to the record removal: the escrow, and the
			-- only record of what it held, are deleted together.
			--
			-- Reachable without any crash. Attempt writes exactly this state between
			-- Escrow and FillTake, and Resolve leaves the records untouched when no
			-- verdict can be established, so a single store hiccup parks a profile in
			-- Staked-with-no-Take. That is the exchange an operator is called in for, and
			-- Data.Exchange.Settle offers Commit and Abort as equals.
			harnessed(function(harness)
				local player, entry = harness.Join(70403)
				local ctx = ctxFor(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["mine"].Set({ Qty = 2 })
				data.Coins.Set(300)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(attempt(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Inventory" }, Kind = "Key", Key = "mine" },
					{ Path = { "Coins" }, Kind = "Qty", Amount = 100 },
				})).to.equal("OK")

				local outcome = attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)
				local record = entry.Tree.Reserved.Exchange[TID].Get()
				expect(
					`outcome={if string.find(outcome, "no take", 1, true) then "REFUSED-NO-TAKE" else outcome} legs={tostring(
						record ~= nil and #record.Escrow
					)} item={tostring(data.Inventory["mine"].Get() ~= nil)} coins={data.Coins.Get()}`
				).to.equal("outcome=REFUSED-NO-TAKE legs=2 item=false coins=200")
			end)
		end)

		it("ABORTS that same record cleanly, so the refusal names the verdict and not the state", function()
			-- The counterpart, and the reason the guard is on Commit alone. Abort moves
			-- the escrow back to its owner and is correct precisely because there is no
			-- Take. A guard that refused both would strand the value it was added to
			-- protect.
			harnessed(function(harness)
				local player, entry = harness.Join(70404)
				local ctx = ctxFor(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["mine"].Set({ Qty = 2 })

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(
					attempt(ExchangeLeg.Escrow, ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "mine" } })
				).to.equal("OK")

				expect(attempt(ExchangeLeg.Settle, ctx, TID, ABORT)).to.equal("OK")
				expect(attempt(ExchangeLeg.Deliver, ctx, TID)).to.equal("OK")
				expect(
					`item={tostring(data.Inventory["mine"].Get() ~= nil)} record={tostring(
						entry.Tree.Reserved.Exchange[TID].Get()
					)}`
				).to.equal("item=true record=nil")
			end)
		end)

		it("COMMITS a claim that never staked anything, so the guard only fires on real value", function()
			-- The second control, and it was MISSING: the mutation that drops the
			-- non-empty-escrow condition from the guard survived the whole suite. The
			-- refusal exists to stop a Commit destroying escrow, so it must not fire
			-- when there is no escrow to destroy. An operator forcing Commit on an exchange
			-- where one side claimed a slot and never staked into it would otherwise be
			-- refused forever, leaving a claim record that blocks that player from ever
			-- exchanging again.
			harnessed(function(harness)
				local player, entry = harness.Join(70406)
				local ctx = ctxFor(harness, player, entry)

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				expect(
					`record={tostring(entry.Tree.Reserved.Exchange[TID].Get())} inbox={tostring(
						entry.Tree.Reserved.ExchangeInbox[TID].Get()
					)}`
				).to.equal("record=nil inbox=nil")
			end)
		end)

		it("COMMITS normally once the Take is present, so the guard is not refusing every commit", function()
			-- The control. A guard that refused all commits would pass both cases above
			-- and break the entire feature.
			harnessed(function(harness)
				local player, entry = harness.Join(70405)
				local ctx = ctxFor(harness, player, entry)
				local data = harness.Data.Get(player)
				data.Inventory["mine"].Set({ Qty = 2 })

				expect(attempt(ExchangeLeg.Claim, ctx, TID, { Digest = "digest-1", Role = "A", Partner = 2 })).to.equal(
					"OK"
				)
				expect(
					attempt(ExchangeLeg.Escrow, ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "mine" } })
				).to.equal("OK")
				local record = entry.Tree.Reserved.Exchange[TID].Get()
				record.Take = { { Path = { "Inventory" }, Kind = "Key", Key = "theirs", Value = { Qty = 5 } } }
				entry.Tree.Reserved.Exchange[TID].Set(record)

				expect(attempt(ExchangeLeg.Settle, ctx, TID, COMMIT)).to.equal("OK")
				expect(attempt(ExchangeLeg.Deliver, ctx, TID)).to.equal("OK")
				expect(
					`theirs={tostring(data.Inventory["theirs"].Get() ~= nil)} mine={tostring(
						data.Inventory["mine"].Get() ~= nil
					)}`
				).to.equal("theirs=true mine=false")
			end)
		end)
	end)
end
