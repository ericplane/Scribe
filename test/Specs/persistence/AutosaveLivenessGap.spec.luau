--!nonstrict
-- Departures must not stretch another profile's autosave gap.
-- Timing is scaled down 5x: a 60-second period and 126-second takeover threshold.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Universe = require(Root.Test.Sim.Universe)
local Guard = require(Root.Test.Sim.Guard)
local StubTransport = require(Root.Test.Helpers.StubTransport)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local runIt = if require(Root.Test.Sim.Available).Ready then it else it.skip

local PERIOD = 60
local ASSUME_DEAD = 126
local WATCHED = 91000
local OTHERS = 7

local universe

afterEach(function()
	Guard.Reset()
	universe = nil
end)

local function stampOf(uni, userId: number): number?
	for _, e in uni.Disk.Keyspace:Each() do
		if e.Key == `PLAYER_{userId}` then
			local value = e.Record.Value
			return if type(value) == "table" and type(value.MetaData) == "table" then value.MetaData.LastUpdate else nil
		end
	end
	return nil
end

describe("an emptying server", function()
	runIt("renews a staying session's stamp within one autosave period", function()
		universe = Universe.new({
			Seed = 20261014,
			Servers = 1,
			Constants = {
				AUTO_SAVE_PERIOD = PERIOD,
				SESSION_STEAL = 10,
				FIRST_LOAD_REPEAT = 2,
				LOAD_REPEAT_PERIOD = 3,
				ASSUME_DEAD = ASSUME_DEAD,
				START_SESSION_TIMEOUT = 60,
			},
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Fixed",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		})
		Guard.Install(universe)
		local server = universe:Server(1)
		server:Join(WATCHED, FakePlayer.new(WATCHED))
		local loaded: { [number]: number } = {}
		for i = 1, OTHERS do
			server:Join(WATCHED + i, FakePlayer.new(WATCHED + i))
		end
		universe:Run(5)
		for i = 1, OTHERS do
			loaded[WATCHED + i] = stampOf(universe, WATCHED + i) :: number
		end

		local last = stampOf(universe, WATCHED) :: number
		local renewals, maxGap, minGap = 0, 0, math.huge
		for _ = 1, PERIOD * 6 do
			universe:Run(1)
			-- A player whose stamp moved has just been autosaved: they leave now.
			for userId, stamp in loaded do
				local now = stampOf(universe, userId)
				if now ~= nil and now ~= stamp then
					loaded[userId] = nil
					server:Leave(userId)
				end
			end
			local stamp = stampOf(universe, WATCHED) :: number
			if stamp ~= last then
				renewals += 1
				minGap = math.min(minGap, stamp - last)
				last = stamp
			end
			maxGap = math.max(maxGap, math.floor(universe.Sched.Now) - last)
		end
		local left = OTHERS
		for _ in loaded do
			left -= 1
		end
		-- Measure across the drain and cap writes to catch an overactive backstop.
		local bounded = renewals >= 2 and renewals <= 7
		-- Backstop saves must also move the profile to the back of the rotation.
		local spaced = minGap >= PERIOD / 2
		expect(
			`left={left} renewals2to7={bounded} withinPeriod={maxGap <= PERIOD + 2} spaced={spaced} gaps={minGap}..{maxGap}`
		).toBe(`left={OTHERS} renewals2to7=true withinPeriod=true spaced=true gaps={minGap}..{maxGap}`)
	end)
end)
