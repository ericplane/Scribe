--!nonstrict
-- OnPlayerInit removals bypass the wipe guard's missing-key check.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

local USER = 88791
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

local function make(fake, options)
	local opts = { WipeGuardPolicy = "Block" }
	for k, v in options or {} do
		opts[k] = v
	end
	local harness = TestCtx.make({ Template = template(), Fake = fake, Options = opts })
	table.insert(harnesses, harness)
	return harness
end

local function earlierSession()
	local fake = FakeProfileStore.new()
	local first = make(fake, nil)
	local player, entry = first.Join(USER)
	entry.LiveData.Legacy = "old"
	expect(first.Data.Flush(player)).toBe(true)
	first.Leave(player)
	return fake
end

local function count(code: string): number
	return #Scribe.GetRecentLogs({ Code = code, Limit = 500 })
end

describe("a top-level key OnPlayerInit removes", function()
	it("OnPlayerInit removal of a top-level key, then gameplay, then two flushes (Block)", function()
		local fake = earlierSession()
		local tripsBefore = count("WIPE_GUARD_TRIPPED")
		local harness = make(fake, {
			OnPlayerInit = function(_player, data)
				data.Legacy = nil
			end,
		})
		local player, _entry, data = harness.Join(USER)
		data.Coins.Set(50)
		local first = harness.Data.Flush(player)
		data.Coins.Set(60)
		local second = harness.Data.Flush(player)
		local stored = fake.Persisted[`Default/PLAYER_{USER}`]
		local trips = count("WIPE_GUARD_TRIPPED") - tripsBefore
		expect(`flush1={first} flush2={second} coins={stored.Coins} legacy={stored.Legacy} trips={trips}`).toBe(
			"flush1=true flush2=true coins=60 legacy=nil trips=0"
		)
	end)

	it("the stall survives a rejoin (Block)", function()
		local fake = earlierSession()
		local hook = function(_player, data)
			data.Legacy = nil
		end
		local results = {}
		for session = 1, 2 do
			local harness = make(fake, { OnPlayerInit = hook })
			local player, _entry, data = harness.Join(USER)
			data.Coins.Set(10 * session)
			local ok = harness.Data.Flush(player)
			harness.Leave(player)
			local stored = fake.Persisted[`Default/PLAYER_{USER}`]
			table.insert(results, `s{session}: flush={ok} coins={stored.Coins} legacy={stored.Legacy}`)
			harness.Cleanup()
		end
		expect(table.concat(results, " | ")).toBe(
			"s1: flush=true coins=10 legacy=nil | s2: flush=true coins=20 legacy=nil"
		)
	end)

	it("the same removal done by a migration (Block)", function()
		local fake = earlierSession()
		local tripsBefore = count("WIPE_GUARD_TRIPPED")
		local harness = make(fake, {
			Migrations = {
				[2] = function(d)
					d.Legacy = nil
				end,
			},
		})
		local player, _entry, data = harness.Join(USER)
		data.Coins.Set(50)
		local first = harness.Data.Flush(player)
		local stored = fake.Persisted[`Default/PLAYER_{USER}`]
		local trips = count("WIPE_GUARD_TRIPPED") - tripsBefore
		expect(`flush1={first} coins={stored.Coins} legacy={stored.Legacy} trips={trips}`).toBe(
			"flush1=true coins=50 legacy=nil trips=0"
		)
	end)

	it("OnPlayerInit removal under the default Warn policy", function()
		local fake = earlierSession()
		local tripsBefore = count("WIPE_GUARD_TRIPPED")
		local harness = make(fake, {
			WipeGuardPolicy = "Warn",
			OnPlayerInit = function(_player, data)
				data.Legacy = nil
			end,
		})
		local player, _entry, data = harness.Join(USER)
		data.Coins.Set(50)
		local first = harness.Data.Flush(player)
		local trips = count("WIPE_GUARD_TRIPPED") - tripsBefore
		expect(`flush1={first} trips={trips}`).toBe("flush1=true trips=0")
	end)

	it("guards the key again once the first save has gone through", function()
		-- After a successful save, later removals must trigger the guard again.
		local fake = earlierSession()
		local harness = make(fake, {
			OnPlayerInit = function(_player, data)
				data.Legacy = nil
			end,
		})
		local player, entry, data = harness.Join(USER)
		data.Coins.Set(50)
		local first = harness.Data.Flush(player)
		entry.LiveData.Legacy = "back"
		data.Coins.Set(51)
		local second = harness.Data.Flush(player)
		local tripsBefore = count("WIPE_GUARD_TRIPPED")
		entry.LiveData.Legacy = nil
		data.Coins.Set(52)
		local third = harness.Data.Flush(player)
		local stored = fake.Persisted[`Default/PLAYER_{USER}`]
		expect(
			`flush={first},{second},{third} trips={count("WIPE_GUARD_TRIPPED") - tripsBefore} legacy={stored.Legacy}`
		).toBe("flush=true,true,false trips=1 legacy=back")
	end)
end)
