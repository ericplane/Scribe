--!nonstrict
-- Purchase and leaderboard paths can include keys named after accessor methods.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Log = require(Root.Scribe.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

describe("a Cost.Path through a dictionary key named like a method", function()
	for _, key in { "Gems", "Max", "Default" } do
		it(`spends Wallet.{key}`, function()
			local harness = TestCtx.make({
				Template = { Wallet = Scribe.DictOf(Scribe.Int(0, { Min = 0 })) },
			})
			local player, _, data = harness.Join(77001)
			data.Wallet.Child(key).Set(100)
			local called, ok, _reason = pcall(harness.Data.Purchase, player, {
				Cost = { Path = `Wallet.{key}`, Amount = 30 },
				ItemId = "sword",
			})
			local after = data.Wallet.Child(key).Get()
			harness.Cleanup()
			expect(`called={called} ok={tostring(ok)} after={tostring(after)}`).toBe("called=true ok=true after=70")
		end)
	end
end)

describe("a leaderboard Stat through a dictionary key named like a method", function()
	for _, key in { "Arena", "Max" } do
		it(`ranks Wins.{key} live`, function()
			local before = #Log.GetRecent({ Code = "LB_STAT_RESOLVE_FAIL" })
			local harness = TestCtx.make({
				Template = { Wins = Scribe.DictOf(Scribe.Int(0, { Min = 0 })) },
				Options = { Leaderboards = { Board = { Stat = `Wins.{key}` } } },
			})
			local _, _, data = harness.Join(77002)
			data.Wins.Child(key).Set(9)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow("Board")
			local entries = harness.Data.GetLeaderboard("Board")
			local first = entries[1]
			local fails = #Log.GetRecent({ Code = "LB_STAT_RESOLVE_FAIL" }) - before
			harness.Cleanup()
			local ranked = if first then `{first.UserId}={tostring(first.Score)}` else "none"
			expect(`ranked={ranked} resolveFails={fails}`).toBe("ranked=77002=9 resolveFails=0")
		end)
	end
end)

describe("a server board over a derived stat named like a method", function()
	it("ranks Max, which only the accessor tree can read", function()
		-- Derived values are unsaved, so the raw-data fallback cannot hide a failed lookup.
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Max = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins)
					return coins * 2
				end),
			},
			Options = { Leaderboards = { Local = { Stat = "Max", Scope = "Server" } } },
		})
		local _, _, data = harness.Join(77003)
		data.Coins.Set(7)
		harness.Ctx.Leaderboards.RefreshNow("Local")
		local first = harness.Data.GetLeaderboard("Local")[1]
		harness.Cleanup()
		local ranked = if first then `{first.UserId}={tostring(first.Score)}` else "none"
		expect(ranked).toBe("77003=14")
	end)
end)
