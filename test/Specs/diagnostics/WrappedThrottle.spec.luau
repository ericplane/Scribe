--!nonstrict
-- Wrapped 502 throttles share a health subject but stay Failed for refund safety.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Failure = require(Root.Scribe.Internal.Failure)

local runIt = if require(Root.Test.Sim.Available).Ready then it else it.skip

local WRAPPED = {
	"502: API Services rejected request with error. HTTP 429.",
	"502: API Services rejected request with error. HTTP 429 (Too Many Requests)",
	"502: API Services rejected request with error. Error code: 0 Reason: Too many requests",
	"502: API Services rejected request with error. Error code: 0 Reason: The request rate exceeds the allowed maximum for the key.",
	"DataStoreService: 502: API Services rejected request with error. HTTP 429.",
}
local PLAIN_502 =
	"502: API Services rejected request with error. Error code: 0 Reason: An internal server error occurred."

-- Isolate Health so this burst cannot affect later specs.
local function freshPair()
	local Loader = require(Root.Test.Sim.Loader)
	local overrides = {}
	for key, value in __SimHost.BaseGlobals do
		if key ~= "require" and key ~= "script" then
			overrides[key] = value
		end
	end
	local cache = Loader.NewCache()
	local Health = Loader.RequireFresh(Root.Scribe.Internal.Health, cache, overrides)
	local FreshFailure = Loader.RequireFresh(Root.Scribe.Internal.Failure, cache, overrides)
	return Health, FreshFailure
end

-- Report six failed loads through the same path as Persistence.
local function burst(message: string): string
	local Health, FreshFailure = freshPair()
	local class
	for i = 1, 6 do
		class = FreshFailure.Report({
			Subsystem = "ProfileStore",
			Key = `Default/PLAYER_{i}`,
			Error = message,
			Category = "Persistence",
			Code = "PROFILE_STORE_ERROR",
			Message = message,
		})
	end
	return `{class}/{Health.GetStatus()}`
end

describe("a throttle reported inside a 502", function()
	it("is still classed Failed, which is what a gift credit's refund reads", function()
		local seen = {}
		for _, message in WRAPPED do
			table.insert(seen, `{Failure.Classify(message)}:{Failure.IsThrottleLike(message)}`)
		end
		table.insert(seen, `{Failure.Classify(PLAIN_502)}:{Failure.IsThrottleLike(PLAIN_502)}`)
		expect(table.concat(seen, " ")).toBe("Failed:true Failed:true Failed:true Failed:true Failed:true Failed:false")
	end)

	it("reads only the 502 wrapper's own markers", function()
		-- Other 5xx errors must not count as throttles.
		expect(Failure.IsThrottleLike("503: DataStore Request successful, but too many requests")).toBe(false)
		expect(Failure.IsThrottleLike("504: Datastore request timed out. HTTP 429")).toBe(false)
		expect(Failure.IsThrottleLike("502: API Services rejected request with error. Status=Forbidden")).toBe(false)
		expect(Failure.IsThrottleLike("StandardWriteGameServerThrottled: StandardWrite request was throttled.")).toBe(
			true
		)
		expect(Failure.IsThrottleLike(nil)).toBe(false)
	end)

	runIt("counts as one shared problem, so a burst across six players does not reach Outage", function()
		local seen = {}
		for _, message in WRAPPED do
			table.insert(seen, burst(message))
		end
		expect(table.concat(seen, " ")).toBe(
			"Failed/Healthy Failed/Healthy Failed/Healthy Failed/Healthy Failed/Healthy"
		)
	end)

	runIt("leaves any other 502 counted per player, as before", function()
		expect(burst(PLAIN_502)).toBe("Failed/Outage")
	end)
end)
