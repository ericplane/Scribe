--!nonstrict
-- CHARACTERISATION. What a whole-element Set does with the fields it was NOT given.
--
-- This is pinned on its own, ahead of the feature that depends on it, because the
-- Exchange "Ignore" option is built entirely on one assumed behaviour: a payload that
-- OMITS a field leaves the receiver holding that field at its declared default. If a
-- partial Set instead stored nothing, or carried a stale value through, "ignored"
-- would be a word in a config table rather than a thing that happens.
--
-- The adjacent behaviours were already covered for Insert and for a leaf write onto a
-- fresh key (ContainerBehavior.spec: "fills declared fields an Insert omitted",
-- "materializes a fresh dict key from the element defaults"). Neither is the shape
-- ExchangeLeg.giveKey actually uses, which is `accessor[key].Set(partialTable)`, so
-- neither of them is evidence for it.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Pets = Scribe.DictOf({
					Level = Scribe.Int(1, { Min = 1, Max = 100 }),
					Kind = Scribe.String("common", { MaxLength = 16 }),
					Damage = Scribe.Int(0, { Min = 0, Max = 999999 }),
					Home = Scribe.Vector3(Vector3.new(7, 8, 9)),
					Note = Scribe.Optional(Scribe.String("", { MaxLength = 8 })),
				}, { MaxKeys = 4 }),
			},
		})
		local _player, entry, data = harness.Join()
		local ok, err = pcall(fn, data, entry, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	describe("a whole-element Set that omits declared fields", function()
		it("fills every omitted non-Optional field from its declared default", function()
			-- THE fact the Ignore option rests on. A payload carrying only what should
			-- travel leaves the rest at the element defaults, which is what makes
			-- "this field does not travel" mean "the receiver starts fresh".
			harnessed(function(data)
				data.Pets.Dragon.Set({ Level = 12, Kind = "fire" })
				local home = data.Pets.Dragon.Home.Get()
				expect(
					`level={data.Pets.Dragon.Level.Get()} kind={data.Pets.Dragon.Kind.Get()} damage={data.Pets.Dragon.Damage.Get()} home={typeof(
						home
					)},{home.X},{home.Y},{home.Z}`
				).to.equal("level=12 kind=fire damage=0 home=Vector3,7,8,9")
			end)
		end)

		it("leaves an omitted Optional field ABSENT rather than defaulting it", function()
			harnessed(function(data)
				data.Pets.Dragon.Set({ Level = 3 })
				expect(tostring(data.Pets.Dragon.Note.Get())).to.equal("nil")
			end)
		end)

		it("stores the omitted field for real, not merely as a read-time default", function()
			-- A default resolved on READ would satisfy the case above while persisting
			-- nothing, and an exchange payload has to survive a save. Read through the
			-- raw store instead of the accessor.
			harnessed(function(data, entry)
				data.Pets.Dragon.Set({ Level = 12 })
				local stored = entry.LiveData.Pets.Dragon
				expect(`damage={tostring(stored.Damage)} kind={tostring(stored.Kind)}`).to.equal("damage=0 kind=common")
			end)
		end)

		it("RESETS a field the payload omits when the key already exists", function()
			-- The other half, and the reason giveKey refuses an occupied destination
			-- rather than trusting a Set to merge: a whole-element Set REPLACES. An
			-- exchange that wrote over an occupied key would silently wipe whatever the
			-- receiver had in the fields the payload did not name.
			harnessed(function(data)
				data.Pets.Dragon.Set({ Level = 12, Kind = "fire", Damage = 500 })
				data.Pets.Dragon.Set({ Level = 13 })
				expect(
					`level={data.Pets.Dragon.Level.Get()} kind={data.Pets.Dragon.Kind.Get()} damage={data.Pets.Dragon.Damage.Get()}`
				).to.equal("level=13 kind=common damage=0")
			end)
		end)

		it("still refuses a field the element does not declare", function()
			-- The closed-shape rule is not relaxed by omitting others: a payload may be
			-- a subset of the declared fields, never a superset.
			harnessed(function(data)
				local ok, err = pcall(function()
					data.Pets.Dragon.Set({ Level = 2, Invented = true })
				end)
				expect(`ok={tostring(ok)} named={tostring(string.find(tostring(err), "Invented", 1, true) ~= nil)}`).to.equal(
					"ok=false named=true"
				)
			end)
		end)
	end)
end
