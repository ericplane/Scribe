--!nonstrict
-- OnPlayerInit exposes saved fields. Assignments to Session roots warn and are discarded.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

local USER = 88801
local KEY = `Default/PLAYER_{USER}`
local harnesses: { any } = {}

afterEach(function()
	for i = #harnesses, 1, -1 do
		harnesses[i].Cleanup()
	end
	table.clear(harnesses)
end)

local function make(fake, onPlayerInit)
	local harness = TestCtx.make({
		Template = {
			Coins = Scribe.Int(0),
			PlayerId = Scribe.Session(Scribe.ServerOnly(Scribe.Int(0))),
			JoinedAt = Scribe.Session(Scribe.Int(0)),
			StoredId = Scribe.ServerOnly(Scribe.Int(0)),
		},
		Fake = fake,
		Options = { OnPlayerInit = onPlayerInit },
	})
	table.insert(harnesses, harness)
	return harness
end

local function sessionLogs(): { any }
	return Scribe.GetRecentLogs({ Code = "ON_PLAYER_INIT_SESSION", Limit = 500 })
end

describe("OnPlayerInit and Scribe.Session fields", function()
	it("discards a Session assignment, keeps the saved ones, and names the field", function()
		local before = #sessionLogs()
		local harness = make(nil, function(player, rawData)
			rawData.PlayerId = player.UserId
			rawData.StoredId = player.UserId
			rawData.Coins = 5
		end)
		local player, _, data = harness.Join(USER)
		expect(harness.Data.Flush(player)).toBe(true)
		local saved = harness.Fake.Persisted[KEY]
		local logs = sessionLogs()
		local last = logs[#logs]
		local named = last ~= nil and string.find(last.Message, "PlayerId", 1, true) ~= nil
		expect(
			`read={data.PlayerId.Get()} saved={tostring(saved.PlayerId)} stored={data.StoredId.Get()} coins={saved.Coins} logs={#logs - before} named={named}`
		).toBe(`read=0 saved=nil stored={USER} coins=5 logs=1 named=true`)
	end)

	it("does not show a Session field in the hook's table, even one an older save left", function()
		local fake = FakeProfileStore.new()
		fake.Persisted[KEY] = { Coins = 1, PlayerId = USER }
		local seen = "unset"
		local harness = make(fake, function(_player, rawData)
			seen = `{tostring(rawData.PlayerId)} {tostring(rawData.JoinedAt)}`
		end)
		harness.Join(USER)
		expect(seen).toBe("nil nil")
	end)

	it("catches a reassignment of the value an older save already left behind", function()
		local fake = FakeProfileStore.new()
		fake.Persisted[KEY] = { Coins = 1, PlayerId = USER }
		local before = #sessionLogs()
		local harness = make(fake, function(player, rawData)
			rawData.PlayerId = player.UserId
		end)
		local _, _, data = harness.Join(USER)
		expect(`read={data.PlayerId.Get()} logs={#sessionLogs() - before}`).toBe("read=0 logs=1")
	end)

	it("leaves an older save's stray key in place when the hook does not touch it", function()
		local fake = FakeProfileStore.new()
		fake.Persisted[KEY] = { Coins = 1, PlayerId = USER }
		local before = #sessionLogs()
		local harness = make(fake, function(_player, rawData)
			rawData.Coins += 1
		end)
		local player = harness.Join(USER)
		expect(harness.Data.Flush(player)).toBe(true)
		local saved = harness.Fake.Persisted[KEY]
		expect(`coins={saved.Coins} stray={tostring(saved.PlayerId)} logs={#sessionLogs() - before}`).toBe(
			`coins=2 stray={USER} logs=0`
		)
	end)
end)
