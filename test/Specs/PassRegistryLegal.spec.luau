--!nonstrict
-- ADVERSARIAL COVER FOR THE NEW BOOT REFUSAL in src/Server/Monetization.luau.
--
-- PassRegistry.spec pins that a duplicate gamepass Id is refused. This file pins the
-- other half, which is the half a new boot-time `error` actually threatens: every
-- config that is LEGAL must still boot. A guard that is too eager does not fail the
-- duplicate spec at all -- it fails silently, in someone else's game, at startup.
--
-- The cases here are the ones the duplicate spec does not reach:
--
--   * `Passes = {}` and `Passes` absent entirely, which are the shapes a data-only or
--     product-only game ships. Both take the `options.Passes or {}` path.
--   * More than two passes with distinct Ids, so the guard is about the Id and not
--     about arity.
--   * Id `0` and a negative Id, which are numbers a guard written with a truthiness
--     or a `> 0` test would mishandle.
--   * `7100` and `7100.0`, which Lua stores under ONE table key and Roblox treats as
--     one gamepass, so the refusal here is correct rather than overreach.
--   * The refusal is order-independent. `pairs()` decides which of the two colliding
--     names is visited second, and the message names neither on purpose; this asserts
--     the config dies with the SAME text every time rather than intermittently.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Same helper shape as PassRegistry.spec: (threw, message, harness).
	local function boot(passes: { [string]: any }?, extra: { [string]: any }?): (boolean, string?, any)
		local options: { [string]: any } = {}
		if passes ~= nil then
			options.Passes = passes
		end
		for key, value in extra or {} do
			options[key] = value
		end
		local ok, result = pcall(TestCtx.make, { Options = options })
		if ok then
			return false, nil, result
		end
		return true, tostring(result), nil
	end

	describe("the duplicate pass Id guard must not fire on a legal config", function()
		it("boots with an EMPTY Passes table", function()
			local threw, err, harness = boot({})
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			-- And the bundle is usable, not merely constructed: Owns answers false for an
			-- unregistered key rather than erroring on the empty registry.
			local player = harness.Join(70301)
			expect(harness.Data.Owns(player, "AnyPass")).to.equal(false)
			harness.Cleanup()
		end)

		it("boots with Passes ABSENT entirely", function()
			local threw, err, harness = boot(nil)
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			local player = harness.Join(70302)
			expect(harness.Data.Owns(player, "AnyPass")).to.equal(false)
			harness.Cleanup()
		end)

		it("boots with Passes absent and Products PRESENT", function()
			-- The product loop runs first and has always refused its own duplicates. A
			-- guard that leaked across the two loops would surface here.
			local threw, err, harness = boot(nil, { Products = { Coins = { Id = 7200 }, Gems = { Id = 7201 } } })
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			harness.Cleanup()
		end)

		it("boots with FOUR passes on distinct Ids", function()
			local threw, err, harness = boot({
				Flight = { Id = 7300 },
				Radar = { Id = 7301, Category = "Gear" },
				Cloak = { Id = 7302 },
				Boost = { Id = 7303, Category = "Gear" },
			})
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			harness.Cleanup()
		end)

		it("boots with a zero and a negative Id", function()
			-- Neither is a real gamepass Id, but neither is a COLLISION, and the guard's
			-- job is collisions. `if passNamesById[config.Id]` keys on the number and
			-- tests the stored NAME, so 0 is an ordinary key here; a guard that had
			-- reached for `config.Id > 0` or for the Id's own truthiness would refuse
			-- these and refuse them for the wrong reason.
			local threw, err, harness = boot({ Zero = { Id = 0 }, Negative = { Id = -7400 } })
			expect(threw).to.equal(false)
			expect(err).to.equal(nil)
			harness.Cleanup()
		end)

		it("REFUSES 7100 and 7100.0, which are one gamepass and one table key", function()
			-- Not overreach: Lua stores both under the same numeric key, so passNamesById
			-- would lose one name exactly as it does for two identical integers.
			local threw, err = boot({ Alpha = { Id = 7100 }, Beta = { Id = 7100.0 } })
			expect(threw).to.equal(true)
			expect(string.find(err :: string, "duplicate pass Id", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a duplicate with the SAME message on every boot, whatever pairs() order", function()
			-- Which name is visited second is hash order and can differ run to run. The
			-- message names the Id and neither name for that reason; this is the arm that
			-- would catch a future edit that helpfully starts naming them.
			local expected = "Scribe: duplicate pass Id 7500; two pass names cannot share one gamepass Id, "
				.. "because a purchase reports only the Id and Scribe could credit just one of them"
			for _ = 1, 12 do
				local threw, err = boot({
					Alpha = { Id = 7500 },
					Beta = { Id = 7500 },
					Gamma = { Id = 7501 },
					Delta = { Id = 7502 },
				})
				expect(threw).to.equal(true)
				expect(err).to.equal(expected)
			end
		end)
	end)
end
