--!nonstrict
-- OnPlayerInit can change game data but cannot access the ledger.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local USER = 88701
local harnesses: { any } = {}

afterEach(function()
	for i = #harnesses, 1, -1 do
		harnesses[i].Cleanup()
	end
	table.clear(harnesses)
end)

local function template()
	return {
		Coins = Scribe.Int(0, { Min = 0 }),
		Settings = { Music = true },
	}
end

local function make(fake, onPlayerInit)
	local harness = TestCtx.make({
		Template = template(),
		Fake = fake,
		Options = { Perks = { "VIP" }, OnPlayerInit = onPlayerInit },
	})
	table.insert(harnesses, harness)
	return harness
end

-- Save a perk and an undeclared Legacy key for the next session.
local function earlierSession()
	local fake = FakeProfileStore.new()
	local first = make(fake, nil)
	local player, entry = first.Join(USER)
	first.Data.GrantPerk(player, "VIP")
	entry.LiveData.Legacy = "old"
	expect(first.Data.Flush(player)).toBe(true)
	first.Leave(player)
	return fake
end

local function ledgerLogs(): number
	return #Scribe.GetRecentLogs({ Code = "ON_PLAYER_INIT_LEDGER", Limit = 500 })
end

describe("OnPlayerInit's data table", function()
	it("does not hold _Scribe", function()
		local fake = earlierSession()
		local seen
		local harness = make(fake, function(_player, data)
			seen = type(data._Scribe)
		end)
		local player = harness.Join(USER)
		expect(`seen={seen} owns={harness.Data.Owns(player, "VIP")}`).toBe("seen=nil owns=true")
	end)

	it("discards an assignment of _Scribe and reports it", function()
		local fake = earlierSession()
		local before = ledgerLogs()
		local harness = make(fake, function(_player, data)
			data._Scribe = {}
		end)
		local player, entry = harness.Join(USER)
		local reserved = entry.LiveData._Scribe
		expect(
			`owns={harness.Data.Owns(player, "VIP")} version={reserved.Version} `
				.. `receipts={type(reserved.ProcessedPurchaseIds)} logged={ledgerLogs() - before}`
		).toBe("owns=true version=1 receipts=table logged=1")
	end)

	it("keeps the hook's top-level assignments, removals and nested edits", function()
		local fake = earlierSession()
		local harness = make(fake, function(_player, data)
			data.Coins = 999
			data.Legacy = nil
			data.Settings.Music = false
		end)
		local _player, entry, data = harness.Join(USER)
		expect(`coins={data.Coins.Get()} legacy={entry.LiveData.Legacy} music={data.Settings.Music.Get()}`).toBe(
			"coins=999 legacy=nil music=false"
		)
	end)

	it("saves what the hook assigned when the player leaves while it yields", function()
		-- Leaving during the hook must save its top-level changes so far.
		local resume: thread? = nil
		local harness = make(FakeProfileStore.new(), function(_player, data)
			data.Coins = 777
			data.Legacy = "moved"
			resume = coroutine.running()
			coroutine.yield()
		end)
		local player = FakePlayer.new(USER)
		task.spawn(harness.Ctx.Persistence.OnPlayerAdded, player)
		local parked = resume ~= nil
		harness.Leave(player)
		if resume then
			task.spawn(resume)
		end
		local stored = harness.Fake.Persisted[`Default/PLAYER_{USER}`]
		expect(`parked={parked} coins={stored and stored.Coins} legacy={stored and stored.Legacy}`).toBe(
			"parked=true coins=777 legacy=moved"
		)
	end)

	it("keeps the ledger out of a save that runs while the hook yields", function()
		-- A mid-hook save must also discard ledger replacements.
		local fake = earlierSession()
		local resume: thread? = nil
		local harness = make(fake, function(_player, data)
			data._Scribe = {}
			resume = coroutine.running()
			coroutine.yield()
		end)
		local player = FakePlayer.new(USER)
		task.spawn(harness.Ctx.Persistence.OnPlayerAdded, player)
		local parked = resume ~= nil
		harness.Leave(player)
		if resume then
			task.spawn(resume)
		end
		local stored = harness.Fake.Persisted[`Default/PLAYER_{USER}`]
		local reserved = stored and stored._Scribe
		expect(
			`parked={parked} VIP={reserved and reserved.Perks and reserved.Perks.VIP} `
				.. `receipts={type(reserved and reserved.ProcessedPurchaseIds)}`
		).toBe("parked=true VIP=true receipts=table")
	end)

	it("keeps an assignment the hook makes after it yields", function()
		local fake = earlierSession()
		local harness = make(fake, function(_player, data)
			task.wait()
			data.Coins = 7
		end)
		local _player, _entry, data = harness.Join(USER)
		expect(data.Coins.Get()).toBe(7)
	end)
end)
