--!nonstrict
-- A ResetData wipe refused for an exchange still ran every step keyed on the option:
-- the version stamp, the Dynamic re-seed and the OnPlayerInit flag. Migrations were
-- skipped for good and the starter kit was granted twice.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_reset_migrate"
	local USER = 97801

	-- A per-profile seed, so a re-seed on a refused reset is visible as a changed value.
	local seeds = 0
	local function nextSeed()
		seeds += 1
		return seeds
	end
	local OLD = { Coins = Scribe.Int(0, { Min = 0, Max = 10000 }), Seed = Scribe.Dynamic(nextSeed) }
	local NEW = { Gold = Scribe.Int(0, { Min = 0, Max = 10000 }), Seed = Scribe.Dynamic(nextSeed) }

	--- A version-1 profile with Coins, holding a claimed exchange, saved and left.
	local function storedWithClaim()
		local first = TestCtx.make({ Template = OLD })
		local player, entry, data = first.Join(USER)
		data.Coins.Set(250)
		first.Data.Flush(player)
		local ctx = { Tree = entry.Tree, Entry = entry, Compiled = first.Compiled, UserId = USER }
		expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = 2 }))).to.equal(true)
		first.Data.Flush(player)
		first.Leave(player)
		return first
	end

	it("runs the migrations a refused reset would have skipped", function()
		local first = storedWithClaim()
		local ran = 0
		local initFlag = "unset"
		local second = TestCtx.make({
			Template = NEW,
			Fake = first.Fake,
			Options = {
				ResetData = true,
				Migrations = {
					[2] = function(data)
						ran += 1
						data.Gold = data.Coins or 0
						data.Coins = nil
					end,
				},
				OnPlayerInit = function(_player, _data, isNewProfile)
					initFlag = tostring(isNewProfile)
				end,
			},
		})
		local storedSeed = first.Fake.Persisted["Default/PLAYER_97801"].Seed
		local player, entry, data = second.Join(USER)
		local refused = #Log.GetRecent({ Code = "EXCHANGE_RESET_REFUSED", Limit = 5 }) > 0
		expect(
			`refused={tostring(refused)} ran={ran} gold={data.Gold.Get()} version={entry.LiveData._Scribe.Version} seedKept={tostring(
				data.Seed.Get() == storedSeed
			)} isNew={initFlag}`
		).to.equal("refused=true ran=1 gold=250 version=2 seedKept=true isNew=false")
		second.Leave(player)
		second.Cleanup()
		first.Cleanup()
	end)

	it("a reset that goes ahead still stamps and skips the chain, which is the control", function()
		local first = TestCtx.make({ Template = OLD })
		local player, _, data = first.Join(USER)
		data.Coins.Set(250)
		first.Data.Flush(player)
		first.Leave(player)

		local ran = 0
		local initFlag = "unset"
		local second = TestCtx.make({
			Template = NEW,
			Fake = first.Fake,
			Options = {
				ResetData = true,
				Migrations = {
					[2] = function()
						ran += 1
					end,
				},
				OnPlayerInit = function(_player, _data, isNewProfile)
					initFlag = tostring(isNewProfile)
				end,
			},
		})
		local p2, entry, d2 = second.Join(USER)
		expect(`ran={ran} gold={d2.Gold.Get()} version={entry.LiveData._Scribe.Version} isNew={initFlag}`).to.equal(
			"ran=0 gold=0 version=2 isNew=true"
		)
		second.Leave(p2)
		second.Cleanup()
		first.Cleanup()
	end)
end
