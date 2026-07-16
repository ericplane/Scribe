--!nonstrict
-- Scribe.Dynamic: per-new-profile default factories (creation timestamps, etc.).
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("runs the factory on a new profile only, and packs datatype results", function()
		local value = "SEED_A"
		local harness = TestCtx.make({
			Template = {
				-- declaration already sampled the factory (baseline = "SEED_A").
				WHO = Scribe.Dynamic(function()
					return value
				end),
				POS = Scribe.Dynamic(function()
					return Vector3.new(1, 2, 3)
				end),
			},
		})

		-- Brand-new profile: the factory runs with the CURRENT value, overriding
		-- the baseline, and datatype results are packed then unpacked on read.
		value = "SEED_B"
		local player, _entry, data = harness.Join(555)
		expect(data.WHO.Get()).to.equal("SEED_B") -- seeded, not the baseline "SEED_A"
		expect(data.POS.Get().X).to.equal(1)
		expect(data.POS.Get().Z).to.equal(3)
		harness.Data.Flush(player) -- persist
		harness.Leave(player)

		-- Returning profile (same key): the factory does NOT re-run.
		value = "SEED_C"
		local _p2, _e2, data2 = harness.Join(555)
		expect(data2.WHO.Get()).to.equal("SEED_B") -- stored value, not a fresh "SEED_C"

		harness.Cleanup()
	end)

	it("seeds a field the stored profile is missing (added after creation), leaving existing data untouched", function()
		local value = "OLD"
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0),
				WHO = Scribe.Dynamic(function()
					return value
				end),
			},
		})
		-- An existing profile from BEFORE the WHO field was added: it has Coins but
		-- no WHO, and it is a returning profile (SessionLoadCount > 1), not new.
		harness.Fake.Persisted["Default/PLAYER_777"] = { Coins = 123, _Scribe = { Version = 1 } }

		value = "NEW"
		local _p, _e, data = harness.Join(777)
		expect(data.Coins.Get()).to.equal(123) -- existing value untouched
		expect(data.WHO.Get()).to.equal("NEW") -- the missing field is seeded on materialization
		harness.Cleanup()
	end)

	it("compiles and seeds a Dynamic nested inside containers (datatype result)", function()
		-- Regression: a Scribe.Dynamic nested in a plain container used to crash
		-- Template.Compile ("unsupported value type function") because
		-- checkDefaultValue walked the raw container into the marker's
		-- Meta.Factory before the marker was stripped.
		local harness = TestCtx.make({
			Template = {
				Files = {
					Latest = {
						LandingDate = Scribe.Dynamic(function()
							return DateTime.now()
						end),
						Fpm = Scribe.Int(0),
					},
				},
			},
		})
		local _p, entry, data = harness.Join(558)
		local landed = data.Files.Latest.LandingDate.Get()
		expect(typeof(landed)).to.equal("DateTime") -- seeded and unpacked
		-- Stored in packed (buffer) form, like any datatype leaf.
		expect(type(entry.LiveData.Files.Latest.LandingDate)).to.equal("buffer")
		harness.Cleanup()
	end)

	it("survives a throwing factory, keeping the baseline and logging", function()
		local boom = false
		local harness = TestCtx.make({
			Template = {
				-- Sampled at declaration with boom=false (baseline 42); the seed-time
				-- call below throws.
				BOOM = Scribe.Dynamic(function()
					if boom then
						error("boom")
					end
					return 42
				end),
			},
		})

		boom = true
		local _p, _e, data = harness.Join(556) -- new profile -> seed runs -> factory throws
		expect(data.BOOM.Get()).to.equal(42) -- kept the baseline; load did not crash
		expect(#Scribe.GetRecentLogs({ Code = "DYNAMIC_DEFAULT_FAILED", Limit = 3 }) > 0).to.equal(true)

		harness.Cleanup()
	end)
end
