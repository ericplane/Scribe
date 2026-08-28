--!nonstrict
-- WHICH SHAPES OF SCRIBE DATA CAN BE EXCHANGED, and what happens to the ones that
-- cannot.
--
-- Every case here came from auditing the declarator surface against the exchange
-- primitives, and every one of them was a declaration that BOOTED CLEAN and then
-- misbehaved. That is the exact failure the registration refusal exists to prevent:
-- the guide promises a configuration mistake is a startup error, by name, because
-- discovering it mid-exchange means discovering it with value already in escrow.
--
-- Two of them were worse than late. They were silent:
--
--   a path reaching THROUGH a container mints, because crediting a key the receiver
--   does not hold materialises the whole element from its declared defaults, and every
--   per-leg proof still passes because the quantity term itself is exact;
--
--   a plain Scribe.Number quantity mints or burns a sub-ULP remainder on every trade,
--   because nothing asserts the debit and the credit are equal and opposite. It is the
--   same argument that already refuses Scribe.Big, one magnitude down.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_shape"

	--- Boot a bundle with one exchangeable spec and report the outcome as a string.
	local function boots(spec, template): string
		local ok, err = pcall(function()
			local harness = TestCtx.make({ Template = template, Options = { Exchangeable = { probe = spec } } })
			harness.Cleanup()
		end)
		return if ok then "BOOTED" else tostring(err)
	end

	--- "refused because <reason>", or the outcome verbatim so a failure prints it.
	local function why(result: string, reason: string): string
		if string.find(result, reason, 1, true) ~= nil then
			return `refused because {reason}`
		end
		return result
	end

	describe("a path may not reach through a container", function()
		local TEMPLATE = {
			Coins = Scribe.Int(0, { Min = 0, Max = 100000 }),
			Inventory = Scribe.DictOf({
				Qty = Scribe.Int(1, { Min = 1, Max = 99 }),
				Rarity = Scribe.Int(3, { Min = 1, Max = 5 }),
			}, { MaxKeys = 8 }),
			Resources = Scribe.DictOf(Scribe.Int(5, { Min = 0, Max = 999 }), { MaxKeys = 8 }),
		}

		it("REFUSES a quantity inside a container element, which would MINT the element", function()
			-- The whole element is seeded from its declared defaults when a write lands
			-- under a key the profile does not hold, so crediting `Inventory.Potion.Qty`
			-- to somebody without a Potion creates its Rarity too. Nobody staked that,
			-- and the leg's own proofs cannot see it, because the quantity term is exact.
			expect(why(boots({ Path = { "Inventory", "Potion", "Qty" }, Kind = "Qty" }, TEMPLATE), "reaches through")).to.equal(
				"refused because reaches through"
			)
		end)

		it("REFUSES a key inside a container element for the same reason", function()
			expect(why(boots({ Path = { "Resources", "ore" }, Kind = "Qty" }, TEMPLATE), "reaches through")).to.equal(
				"refused because reaches through"
			)
		end)

		it("still boots on the single-segment paths, which are the whole supported surface", function()
			expect(boots({ Path = { "Coins" }, Kind = "Qty" }, TEMPLATE)).to.equal("BOOTED")
			expect(boots({ Path = { "Inventory" }, Kind = "Key" }, TEMPLATE)).to.equal("BOOTED")
			expect(boots({ Path = { "Resources" }, Kind = "Key" }, TEMPLATE)).to.equal("BOOTED")
		end)
	end)

	describe("a quantity must be exactly conserved", function()
		it("REFUSES a plain Scribe.Number, whose arithmetic loses a sub-ULP remainder", function()
			-- Doubles do not conserve. Giver 1e12 debited 1e-3 loses 0.0009765625 while
			-- the receiver gains 0.001: a mint of 2.34e-5 that every per-leg proof
			-- passes, because each side is internally consistent and nothing compares
			-- the two. Scribe.Big is already refused for the same reason.
			local template = { Float = Scribe.Number(0, { Min = 0, Max = 1e12 }) }
			expect(why(boots({ Path = { "Float" }, Kind = "Qty" }, template), "not exactly conserved")).to.equal(
				"refused because not exactly conserved"
			)
		end)

		it("REFUSES a Scribe.Optional quantity, which the receiver cannot be credited", function()
			-- Optional keeps its Min, so it passes every existing rule. The debit half
			-- works whenever the payer holds a value, which is what makes it look
			-- healthy. The CREDIT half fails on a receiver who has never written the
			-- field: Get() and Default() are both nil, so there is no balance to add to,
			-- and that failure lands AFTER the verdict, where it parks for ever and no
			-- operator verb can un-park a quantity leg.
			local template = { Tokens = Scribe.Optional(Scribe.Int(0, { Min = 0, Max = 1000 })) }
			expect(why(boots({ Path = { "Tokens" }, Kind = "Qty" }, template), "Scribe.Optional")).to.equal(
				"refused because Scribe.Optional"
			)
		end)

		it("still boots on a bounded integer, which is the shape that does conserve", function()
			expect(boots({ Path = { "Coins" }, Kind = "Qty" }, { Coins = Scribe.Int(0, { Min = 0, Max = 1000 }) })).to.equal(
				"BOOTED"
			)
		end)
	end)

	describe("an array element may carry a datatype", function()
		-- Escrow's array branch used to stake the CALLER'S needle instead of the stored
		-- form, so a datatype element reached the reserved root as live userdata and the
		-- write validator refused it. It was the one branch that did not do what the
		-- comment above it says. Reading the store fixes it, and also closes a second
		-- hole: the old branch staked a payload it never proved the container held,
		-- because `held == nil` is satisfied by any non-nil argument.
		local TEMPLATE = {
			Placed = Scribe.ArrayOf({
				Where = Scribe.Vector3(Vector3.new(1, 2, 3)),
				Id = Scribe.String("x", { MaxLength = 16 }),
			}, { MaxItems = 8 }),
			Deck = Scribe.ArrayOf(Scribe.String("x", { MaxLength = 16 }), { MaxItems = 8 }),
		}

		local function withArray(fn)
			local harness = TestCtx.make({
				Template = TEMPLATE,
				Options = {
					Exchangeable = {
						Placed = { Path = { "Placed" }, Kind = "Key" },
						Card = { Path = { "Deck" }, Kind = "Key" },
					},
				},
			})
			local ok, err = pcall(fn, harness)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end

		it("boots, and moves an entry whose element holds a Vector3", function()
			withArray(function(harness)
				local player, entry = harness.Join(98901)
				local data = harness.Data.Get(player)
				data.Placed.Insert({ Where = Vector3.new(4, 5, 6), Id = "totem" })
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }

				local needle = data.Placed.Get()[1]
				expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 }))).to.equal(true)
				local eok, ereason =
					ExchangeLeg.Escrow(ctx, TID, { { Path = { "Placed" }, Kind = "Key", Key = needle } })
				expect(`{tostring(eok)} {tostring(ereason)}`).to.equal("true nil")
				expect(`staked={#data.Placed.Get()}`).to.equal("staked=0")

				expect(select(1, ExchangeLeg.Settle(ctx, TID, { V = "Abort", D = "d" }))).to.equal(true)
				expect(select(1, ExchangeLeg.Deliver(ctx, TID))).to.equal(true)

				-- Compared by COMPONENT, not by tostring: under the Lune shim a Vector3
				-- stringifies as "table: 0x...", so a tostring assertion fails on a
				-- correct value and says nothing about what came back.
				local back = data.Placed.Get()[1]
				local where = back and back.Where
				expect(
					`n={#data.Placed.Get()} kind={typeof(where)} at={tostring(where and where.X)},{tostring(
						where and where.Y
					)},{tostring(where and where.Z)} id={tostring(back and back.Id)}`
				).to.equal("n=1 kind=Vector3 at=4,5,6 id=totem")
			end)
		end)

		it("REFUSES a needle the array does not hold, rather than staking it anyway", function()
			-- The second hole the same branch had: it cloned whatever it was handed without
			-- ever proving the container held it.
			withArray(function(harness)
				local player, entry = harness.Join(98902)
				local data = harness.Data.Get(player)
				data.Deck.Insert("ace")
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }

				ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 })
				local pok, okOrErr, reason = pcall(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Deck" }, Kind = "Key", Key = "never-inserted" },
				})
				local text = if pok then tostring(reason) else tostring(okOrErr)
				expect(
					`named={tostring(string.find(text, "holds nothing to stake", 1, true) ~= nil)} kept={#data.Deck.Get()}`
				).to.equal("named=true kept=1")
			end)
		end)

		it("still boots on an array of plain strings", function()
			withArray(function(harness)
				local player, entry = harness.Join(98903)
				local data = harness.Data.Get(player)
				data.Deck.Insert("ace")
				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
				ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 })
				expect(select(1, ExchangeLeg.Escrow(ctx, TID, { { Path = { "Deck" }, Kind = "Key", Key = "ace" } }))).to.equal(
					true
				)
				expect(`left={#data.Deck.Get()}`).to.equal("left=0")
			end)
		end)
	end)

	describe("a map keyed by integer is exchangeable", function()
		-- Scribe.MapOf accepts keyType "integer" and its own docstring uses a UserId map
		-- as the motivating example, but the leg key guard demanded a string. The
		-- declaration booted clean and then every attempt died inside Escrow, which is
		-- the failure the startup refusal exists to prevent.
		local TEMPLATE = {
			Pets = Scribe.MapOf("integer", { Name = Scribe.String("pet", { MaxLength = 16 }) }, { MaxKeys = 8 }),
		}

		it("boots, and moves an entry keyed by a number", function()
			local harness = TestCtx.make({
				Template = TEMPLATE,
				Options = { Exchangeable = { Pet = { Path = { "Pets" }, Kind = "Key" } } },
			})
			local ok, err = pcall(function()
				local player, entry = harness.Join(98801)
				local data = harness.Data.Get(player)
				data.Pets[7].Set({ Name = "Rex" })

				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
				expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 }))).to.equal(true)
				expect(select(1, ExchangeLeg.Escrow(ctx, TID, { { Path = { "Pets" }, Kind = "Key", Key = 7 } }))).to.equal(
					true
				)
				expect(`staked={tostring(data.Pets[7].Get() == nil)}`).to.equal("staked=true")

				-- Straight back out again, which is the delivery half.
				expect(select(1, ExchangeLeg.Settle(ctx, TID, { V = "Abort", D = "d" }))).to.equal(true)
				expect(select(1, ExchangeLeg.Deliver(ctx, TID))).to.equal(true)
				local back = data.Pets[7].Get()
				expect(`name={tostring(back and back.Name)}`).to.equal("name=Rex")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)

		it("REFUSES to REDIRECT a parked delivery into it, because a redirect names a string", function()
			-- The leg moves, but the repair verb cannot address the destination: Redirect
			-- takes a string key, and this container's keys are numbers. Saying so is the
			-- whole point, because the operator reaching for Redirect on a stuck delivery
			-- otherwise gets a failure that names nothing.
			local harness = TestCtx.make({
				Template = TEMPLATE,
				Options = { Exchangeable = { Pet = { Path = { "Pets" }, Kind = "Key" } } },
			})
			local ok, err = pcall(function()
				local player, entry = harness.Join(98803)
				local data = harness.Data.Get(player)
				-- Occupy the destination so the delivery has somewhere to be stuck.
				data.Pets[7].Set({ Name = "Rex" })
				entry.Tree.Reserved.ExchangeInbox[TID].Set({
					Id = TID,
					Verdict = "Commit",
					Legs = { { Path = { "Pets" }, Kind = "Key", Key = 7, Value = { Name = "Fido" } } },
				})

				local redirected, reason = harness.Ctx.Exchanges.Redirect(TID, 98803, "8")
				expect(
					`ok={tostring(redirected)} named={tostring(
						string.find(tostring(reason), "keyed by integer", 1, true) ~= nil
					)}`
				).to.equal("ok=false named=true")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)

		it("REFUSES a string key on an integer-keyed map, rather than storing a second shape", function()
			local harness = TestCtx.make({
				Template = TEMPLATE,
				Options = { Exchangeable = { Pet = { Path = { "Pets" }, Kind = "Key" } } },
			})
			local ok, err = pcall(function()
				local player, entry = harness.Join(98802)
				local data = harness.Data.Get(player)
				data.Pets[7].Set({ Name = "Rex" })

				local ctx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
				ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 })
				-- Escrow returns (ok, reason) through RunTransaction, so a successful
				-- pcall yields THREE values and the reason is the third. Reading the
				-- second gives the literal `false` and matches nothing.
				local pok, okOrErr, reason = pcall(ExchangeLeg.Escrow, ctx, TID, {
					{ Path = { "Pets" }, Kind = "Key", Key = "7" },
				})
				local text = if pok then tostring(reason) else tostring(okOrErr)
				expect(
					`named={tostring(string.find(text, "takes an integer key", 1, true) ~= nil)} kept={tostring(
						data.Pets[7].Get() ~= nil
					)}`
				).to.equal("named=true kept=true")
			end)
			harness.Cleanup()
			if not ok then
				error(err, 0)
			end
		end)
	end)
end
