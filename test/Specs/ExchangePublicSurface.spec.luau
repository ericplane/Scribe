--!nonstrict
-- STEP 7: the surface a game actually calls.
--
-- Everything below this is specced, but a developer never touches any of it. They call
-- `Data.Exchange.Attempt` with two baskets and read one outcome, and they declare which paths
-- are exchangeable in one option. If that surface is wrong, none of the machinery underneath
-- matters.
--
-- The registration refusal is the load-bearing half. An exchangeable path that cannot be moved
-- safely is a CONFIGURATION error, and the only safe thing to do with one is refuse to
-- start: discovering it when two players are mid-exchange means discovering it with value
-- already in escrow.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local A_ID, B_ID = 92201, 92202

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		-- Declared in the template and deliberately NOT exchangeable: the allowlist is
		-- only worth anything if it refuses something the template allows.
		Level = Scribe.Int(1, { Min = 1, Max = 100 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 6 }),
	}

	local EXCHANGEABLE = {
		Item = { Path = { "Inventory" }, Kind = "Key" },
		Money = { Path = { "Coins" }, Kind = "Qty" },
	}

	local function harnessed(fn, exchangeable)
		local harness = TestCtx.make({
			Template = TEMPLATE,
			Options = { Exchangeable = if exchangeable ~= nil then exchangeable else EXCHANGEABLE },
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function pair(harness)
		local pa = harness.Join(A_ID)
		local pb = harness.Join(B_ID)
		local da, db = harness.Data.Get(pa), harness.Data.Get(pb)
		da.Inventory["blade"].Set({ Qty = 1 })
		da.Coins.Set(500)
		db.Inventory["shield"].Set({ Qty = 1 })
		db.Coins.Set(100)
		return pa, pb, da, db
	end

	describe("Data.Exchange.Attempt", function()
		it("exchanges two baskets between two loaded players", function()
			harnessed(function(harness)
				local pa, pb, da, db = pair(harness)

				local outcome, why = harness.Data.Exchange.Attempt(
					pa,
					{
						{ Path = { "Inventory" }, Kind = "Key", Key = "blade" },
						{ Path = { "Coins" }, Kind = "Qty", Amount = 250 },
					},
					pb,
					{
						{ Path = { "Inventory" }, Kind = "Key", Key = "shield" },
					}
				)

				expect(
					`{tostring(outcome)} why={tostring(why)} aShield={tostring(da.Inventory["shield"].Get() ~= nil)} bBlade={tostring(
						db.Inventory["blade"].Get() ~= nil
					)} aCoins={da.Coins.Get()} bCoins={db.Coins.Get()}`
				).to.equal("Committed why=nil aShield=true bBlade=true aCoins=250 bCoins=350")
			end)
		end)

		it("REFUSES when a player is not loaded on this server", function()
			harnessed(function(harness)
				local pa = harness.Join(A_ID)
				local absent = { UserId = 99999, Name = "Ghost", Parent = nil }
				local outcome, why = harness.Data.Exchange.Attempt(pa, {}, absent :: any, {})
				expect(
					`outcome={tostring(outcome)} named={tostring(
						why ~= nil and string.find(why, "must be loaded", 1, true) ~= nil
					)}`
				).to.equal("outcome=nil named=true")
			end)
		end)

		it("reports what a player still has open", function()
			harnessed(function(harness)
				local pa, pb = pair(harness)
				expect(#harness.Data.Exchange.Open(pa)).to.equal(0)

				local seen
				harness.Data.Exchange.Attempt(pa, { { Path = { "Inventory" }, Kind = "Key", Key = "blade" } }, pb, {})
				seen = harness.Data.Exchange.Open(pa)
				-- A committed exchange leaves nothing open; the count is the assertion, not
				-- the ids, because the id is generated.
				expect(#seen).to.equal(0)
			end)
		end)

		it("says WHAT is staked, not just that something is", function()
			-- Escrow takes value out of the balance on purpose, the way handing an item
			-- to a clerk does, and the resolution time is deliberately not bounded. A
			-- list of ids answers "is something open" and not "where did my coins go",
			-- which is the question the player actually asks. The game cannot read it any
			-- other way: the ledger is ServerOnly and the accessor refuses reserved-root
			-- reads.
			harnessed(function(harness)
				local pa, _pb, da = pair(harness)
				local entry = harness.Ctx.Persistence.EntryFor(pa)
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = pa.UserId }

				ExchangeLeg.Claim(ctx, "tid_open", { Digest = "d", Role = "A", Partner = B_ID })
				ExchangeLeg.Escrow(ctx, "tid_open", {
					{ Path = { "Inventory" }, Kind = "Key", Key = "blade" },
					{ Path = { "Coins" }, Kind = "Qty", Amount = 250 },
				})

				local open = harness.Data.Exchange.Open(pa)
				local first = open[1]
				local staked = {}
				for _, leg in first.Staked do
					table.insert(
						staked,
						`{table.concat(leg.Path, ".")}:{leg.Kind}:{tostring(leg.Key)}:{tostring(leg.Amount)}`
					)
				end
				table.sort(staked)

				expect(
					`n={#open} id={first.Id} state={first.State} partner={tostring(first.Partner)} legs={table.concat(
						staked,
						" "
					)} coins={da.Coins.Get()}`
				).to.equal(
					`n=1 id=tid_open state=Staked partner={B_ID} legs=Coins:Qty:nil:250 Inventory:Key:blade:nil coins=250`
				)
			end)
		end)

		it("carries no digest or role, and hands out no reference into the ledger", function()
			-- Two separate promises. The digest and the role are Scribe's bookkeeping and
			-- have no business in front of a player. And the returned tables are freshly
			-- built, so a game that edits what it was handed cannot reach the reserved
			-- root, which is the same hazard `Get()` already carries for containers.
			harnessed(function(harness)
				local pa = pair(harness)
				local entry = harness.Ctx.Persistence.EntryFor(pa)
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = pa.UserId }

				ExchangeLeg.Claim(ctx, "tid_open", { Digest = "secret-digest", Role = "A", Partner = B_ID })
				ExchangeLeg.Escrow(ctx, "tid_open", { { Path = { "Inventory" }, Kind = "Key", Key = "blade" } })

				local open = harness.Data.Exchange.Open(pa)[1]
				local leaked = (open :: any).Digest ~= nil or (open :: any).Role ~= nil
				-- Vandalise everything handed over, then read the ledger back.
				open.Staked[1].Key = "vandalised"
				table.clear(open.Staked[1].Path)
				local record = entry.Tree.Reserved.Exchange["tid_open"].Get()

				expect(
					`leaked={tostring(leaked)} key={tostring(record.Escrow[1].Key)} path={table.concat(
						record.Escrow[1].Path,
						"."
					)}`
				).to.equal("leaked=false key=blade path=Inventory")
			end)
		end)

		it("reports Delivering even when a record survives beside the inbox entry", function()
			-- Settle writes the inbox entry and removes the record in ONE transaction, so
			-- the two never coexist on a healthy profile. They can on a mangled one, and
			-- the later stage is the honest thing to tell a player: the verdict landed and
			-- the only thing left is putting the value somewhere.
			harnessed(function(harness)
				local pa = pair(harness)
				local entry = harness.Ctx.Persistence.EntryFor(pa)
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = pa.UserId }

				ExchangeLeg.Claim(ctx, "tid_both", { Digest = "d", Role = "A", Partner = B_ID })
				ExchangeLeg.Escrow(ctx, "tid_both", { { Path = { "Inventory" }, Kind = "Key", Key = "blade" } })
				entry.Tree.Reserved.ExchangeInbox["tid_both"].Set({
					Id = "tid_both",
					Verdict = "Commit",
					Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "prize" } },
				})

				local open = harness.Data.Exchange.Open(pa)[1]
				expect(`state={open.State} staked={#open.Staked} owed={tostring(open.Owed[1].Key)}`).to.equal(
					"state=Delivering staked=1 owed=prize"
				)
			end)
		end)

		it("reports a settled exchange as Delivering, with what is owed", function()
			harnessed(function(harness)
				local pa = pair(harness)
				local entry = harness.Ctx.Persistence.EntryFor(pa)
				entry.Tree.Reserved.ExchangeInbox["tid_owed"].Set({
					Id = "tid_owed",
					Verdict = "Commit",
					Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "prize", Value = { Qty = 2 } } },
					SettledAt = 1234,
				})

				local open = harness.Data.Exchange.Open(pa)[1]
				expect(
					`state={open.State} owed={#open.Owed} key={tostring(open.Owed[1].Key)} since={tostring(open.Since)} staked={#open.Staked}`
				).to.equal("state=Delivering owed=1 key=prize since=1234 staked=0")
			end)
		end)
	end)

	describe("the allowlist is enforced on the basket, not only at startup", function()
		-- ROUND 4, AND THE ONE THAT MATTERED MOST. Every refusal in the block below
		-- runs at STARTUP, against the specs the developer declared. Nothing was
		-- checking the legs a caller actually hands to Attempt, so the option gated a
		-- list nothing read: `self.Exchangeable` was assigned in the constructor and never
		-- looked at again. A game building a basket from client-influenced input, which
		-- is the natural shape for an exchange UI and precisely the shape the allowlist
		-- exists to make safe, would let a player name any DECLARED path.
		--
		-- The refusal has to be FREE, in the sense that nothing has moved and no slot
		-- has been claimed, so a rejected basket costs the player nothing and leaves no
		-- record for the sweep to resolve.

		it("REFUSES a leg on a path the template declares but Exchangeable does not", function()
			harnessed(function(harness)
				local pa, pb, da, db = pair(harness)
				da.Level.Set(40)

				local outcome, why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { "Level" }, Kind = "Qty", Amount = 30 } },
					pb,
					{ { Path = { "Inventory" }, Kind = "Key", Key = "shield" } }
				)

				expect(
					`outcome={tostring(outcome)} named={tostring(
						why ~= nil and string.find(why, "not exchangeable", 1, true) ~= nil
					)} level={da.Level.Get()} shield={tostring(db.Inventory["shield"].Get() ~= nil)} open={#harness.Data.Exchange.Open(
						pa
					)}`
				).to.equal("outcome=nil named=true level=40 shield=true open=0")
			end)
		end)

		it("REFUSES it in the SECOND basket too, which is not the same check", function()
			-- Dropping the second basket check survived every case above, because all
			-- of them put the offending leg in the first. Both baskets are attacker
			-- influenced and there is one check per basket, so there has to be one case
			-- per basket.
			harnessed(function(harness)
				local pa, pb, da, db = pair(harness)
				db.Level.Set(40)

				local outcome, why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { "Inventory" }, Kind = "Key", Key = "blade" } },
					pb,
					{ { Path = { "Level" }, Kind = "Qty", Amount = 30 } }
				)

				expect(
					`outcome={tostring(outcome)} named={tostring(
						why ~= nil and string.find(why, "not exchangeable", 1, true) ~= nil
					)} level={db.Level.Get()} blade={tostring(da.Inventory["blade"].Get() ~= nil)}`
				).to.equal("outcome=nil named=true level=40 blade=true")
			end)
		end)

		it("REFUSES a leg whose Kind is not the Kind that path was declared with", function()
			-- Coins is declared exchangeable as a quantity. Moving it as a KEY would reach
			-- an entirely different primitive, so the pair is the unit of approval and
			-- the path alone is not.
			harnessed(function(harness)
				local pa, pb, da = pair(harness)
				local outcome, why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { "Coins" }, Kind = "Key", Key = "500" } },
					pb,
					{ { Path = { "Inventory" }, Kind = "Key", Key = "shield" } }
				)
				expect(
					`outcome={tostring(outcome)} named={tostring(
						why ~= nil and string.find(why, "not exchangeable", 1, true) ~= nil
					)} coins={da.Coins.Get()}`
				).to.equal("outcome=nil named=true coins=500")
			end)
		end)

		it("REFUSES every leg when the bundle declared no Exchangeable at all", function()
			-- Trading is opt-in, so a bundle that never declared anything must refuse
			-- rather than exchange freely. The boot-with-no-Exchangeable control below proves
			-- such a bundle still STARTS; this proves it cannot move value.
			local harness = TestCtx.make({ Template = TEMPLATE })
			local ok, err = pcall(function()
				local pa = harness.Join(A_ID)
				local pb = harness.Join(B_ID)
				harness.Data.Get(pa).Inventory["blade"].Set({ Qty = 1 })

				local outcome, why = harness.Data.Exchange.Attempt(
					pa,
					{ { Path = { "Inventory" }, Kind = "Key", Key = "blade" } },
					pb,
					{}
				)
				expect(
					`outcome={tostring(outcome)} named={tostring(
						why ~= nil and string.find(why, "not exchangeable", 1, true) ~= nil
					)} blade={tostring(harness.Data.Get(pa).Inventory["blade"].Get() ~= nil)}`
				).to.equal("outcome=nil named=true blade=true")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)

		it("REFUSES a malformed leg instead of raising on it", function()
			-- The allowlist has to read Path to check it, so a leg with no Path reaches
			-- the lookup first. A raise here would surface to game code as a stack trace
			-- from inside Scribe rather than a refusal it can act on.
			harnessed(function(harness)
				local pa, pb = pair(harness)
				local pok, outcome, why = pcall(
					harness.Data.Exchange.Attempt,
					pa,
					{ { Kind = "Key", Key = "blade" } },
					pb,
					{ { Path = { "Inventory" }, Kind = "Key", Key = "shield" } }
				)
				expect(
					`raised={tostring(not pok)} outcome={tostring(outcome)} named={tostring(
						pok and why ~= nil and string.find(why, "not exchangeable", 1, true) ~= nil
					)}`
				).to.equal("raised=false outcome=nil named=true")
			end)
		end)
	end)

	describe("the Exchangeable registration", function()
		--- Build a bundle with one exchangeable spec and report whether it booted.
		local function boots(spec, template): string
			local ok, err = pcall(function()
				local harness = TestCtx.make({
					Template = template or TEMPLATE,
					Options = { Exchangeable = { probe = spec } },
				})
				harness.Cleanup()
			end)
			return if ok then "BOOTED" else tostring(err)
		end

		it("boots on a well-formed declaration, which is the control", function()
			expect(boots({ Path = { "Inventory" }, Kind = "Key" })).to.equal("BOOTED")
			expect(boots({ Path = { "Coins" }, Kind = "Qty" })).to.equal("BOOTED")
		end)

		it("REFUSES TO START on a misspelled path", function()
			-- The typo gate. Without it a misspelling resolves to a parent and the game
			-- exchanges a field nobody named.
			expect(string.find(boots({ Path = { "Inventry" }, Kind = "Key" }), "not a declared field", 1, true) ~= nil).to.equal(
				true
			)
		end)

		it("REFUSES TO START on a path into a field the element does not declare", function()
			-- The other way a path can be undeclared, and the one the strict-mode pass
			-- found untested. A misspelled ROOT key resolves to a synthesized AnyChild
			-- and is caught by the is-not-a-declared-field check; a misspelled key
			-- INSIDE a declared element record resolves to nothing at all, because a
			-- compiled element is Closed and ChildSchema refuses to synthesize onto it.
			-- Two different branches, and only the first had a case.
			expect(
				string.find(
					boots({ Path = { "Inventory", "anyItem", "Bogus" }, Kind = "Key" }),
					"has no declared field",
					1,
					true
				) ~= nil
			).to.equal(true)
		end)

		it("REFUSES TO START on a quantity path with no floor", function()
			local template = table.clone(TEMPLATE)
			template.Floating = Scribe.Int(0)
			expect(
				string.find(boots({ Path = { "Floating" }, Kind = "Qty" }, template), "declares no Min", 1, true) ~= nil
			).to.equal(true)
		end)

		it("REFUSES TO START on a Scribe.Big quantity, per D6", function()
			local template = table.clone(TEMPLATE)
			template.Shards = Scribe.Big(0, { Min = 0 })
			expect(
				string.find(boots({ Path = { "Shards" }, Kind = "Qty" }, template), "absorbs a small leg", 1, true)
					~= nil
			).to.equal(true)
		end)

		it("REFUSES TO START on the reserved root", function()
			expect(string.find(boots({ Path = { "_Scribe", "Perks" }, Kind = "Key" }), "reserved", 1, true) ~= nil).to.equal(
				true
			)
		end)

		it("emits EXCHANGE_REGISTRATION_REFUSED as well as raising", function()
			-- The code was declared and documented and emitted nowhere, because the
			-- refusal only ever raised. A raise stops the boot, which is the point, but
			-- it arrives as a stack trace; the log entry is what makes it a filterable
			-- diagnostic when it surfaces from a place-start in somebody else's CI.
			local before = #Log.GetRecent({ Code = "EXCHANGE_REGISTRATION_REFUSED" })
			local outcome = boots({ Path = { "Inventry" }, Kind = "Key" })
			local logged = #Log.GetRecent({ Code = "EXCHANGE_REGISTRATION_REFUSED" }) - before

			expect(`raised={tostring(outcome ~= "BOOTED")} logged={logged}`).to.equal("raised=true logged=1")
		end)

		it("boots with no Exchangeable option at all, so exchanging is opt-in", function()
			-- A game that never exchanges must not be made to care about any of this.
			local ok = pcall(function()
				local harness = TestCtx.make({ Template = TEMPLATE })
				harness.Cleanup()
			end)
			expect(ok).to.equal(true)
		end)
	end)

	describe("the operator verbs are on the surface", function()
		it("exposes discard, settle and redirect, and they refuse rather than raise", function()
			-- Reachable and safe to call blind: an operator typing an exchange id that does
			-- not exist should get a sentence, not a stack trace.
			harnessed(function(harness)
				pair(harness)
				local dOk, dWhy = harness.Data.Exchange.Discard("no-such-exchange")
				local sOk = harness.Data.Exchange.Settle("no-such-exchange")
				local rOk = harness.Data.Exchange.Redirect("no-such-exchange", A_ID, "anywhere")

				expect(
					`discard={tostring(dOk)} reason={tostring(dWhy ~= nil)} settle={tostring(sOk)} redirect={tostring(
						rOk
					)}`
				).to.equal("discard=false reason=true settle=false redirect=false")
			end)
		end)
	end)
end
