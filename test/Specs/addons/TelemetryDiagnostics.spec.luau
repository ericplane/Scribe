--!nonstrict
-- Optional summary diagnostics keep counters, gauges, and rolling samples distinct.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Diagnostics = require(Root.Addons.Telemetry.ScribeTelemetry.Diagnostics)

local function fields(metrics, previous, percentiles)
	local result = {}
	for _, field in Diagnostics.Fields(metrics or {}, previous or {}, percentiles or {}) do
		result[field.Name] = field.Value
	end
	return result
end

it("omits optional groups absent from the current snapshot", function()
	expect(#Diagnostics.Fields({}, { ReceiptHistoryRefusals = 3, LbWrites = 9 }, {})).toBe(0)
end)

it("reports interval receipt and sink counts with honest missing values", function()
	local result = fields({ ReceiptHistoryRefusals = 14, LogSinkDropped = 50 }, {
		ReceiptHistoryRefusals = 10,
		LogSinkDropped = 40,
		LogSinkErrors = 3,
	})
	expect(result.Receipts).toBe("4 history-capacity refusals")
	expect(result["Log delivery"]).toBe("10 dropped · n/a sink errors")
	expect(result["Leaderboard requests"]).toBe(nil)
end)

it("clamps reset counters without applying deltas to the queue gauge", function()
	local result = fields({
		ReceiptHistoryRefusals = 1,
		LogSinkDropped = 2,
		LogSinkErrors = 0,
		LbWrites = 300,
		LbWritesSkipped = 30,
		LbReadFailures = 3,
		LbWriteFailures = 5,
		LbQueueDepth = 2,
		LbBudgetDeferred = 20,
		LbQueueOverflow = 1,
	}, {
		ReceiptHistoryRefusals = 5,
		LogSinkDropped = 8,
		LogSinkErrors = 1,
		LbWrites = 250,
		LbWritesSkipped = 20,
		LbReadFailures = 1,
		LbWriteFailures = 2,
		LbQueueDepth = 90,
		LbBudgetDeferred = 15,
		LbQueueOverflow = 4,
	})
	expect(result.Receipts).toBe("0 history-capacity refusals")
	expect(result["Log delivery"]).toBe("0 dropped · 0 sink errors")
	expect(result["Leaderboard requests"]).toBe(
		"50 writes · 10 skipped\n2 read failures · 3 write failures\n2 last reported queue · 5 budget deferrals · 0 queue drops"
	)
end)

it("does not invent zeroes for optional leaderboard counters", function()
	local result = fields({ LbQueueDepth = 0 })
	expect(result["Leaderboard requests"]).toBe(
		"n/a writes · n/a skipped\nn/a read failures · n/a write failures\n0 last reported queue · n/a budget deferrals · n/a queue drops"
	)
end)

it("labels each rolling distribution with its sample window and age", function()
	local sample = { P50 = 0.4, P90 = 2.1, P99 = 35, Samples = 42, Window = 7200, Age = 90 }
	local result = fields({}, {}, {
		ProfileLoadDuration = sample,
		LoadDuration = sample,
		PlayerLeavingHookDuration = sample,
	})
	for _, name in { "Profile acquisition (rolling)", "Player load (rolling)", "Player leaving hook (rolling)" } do
		expect(result[name]).toBe("p50 0.40s · p90 2.10s · p99 35s (42 samples over 2h 0m, newest 1m 30s ago)")
	end
	expect(sample.Samples).toBe(42)
end)

it("shows empty distributions without formatting missing or nonfinite samples", function()
	local result = fields({ LoadDuration = { Count = 0 } }, {}, {
		ProfileLoadDuration = { Samples = 0 },
		PlayerLeavingHookDuration = { Samples = 2, P50 = 0 / 0, P90 = math.huge, P99 = -1 },
	})
	expect(result["Profile acquisition (rolling)"]).toBe("no samples")
	expect(result["Player load (rolling)"]).toBe("no samples")
	expect(result["Player leaving hook (rolling)"]).toBe(
		"p50 n/a · p90 n/a · p99 n/a (2 samples over n/a, newest n/a ago)"
	)
	expect(#Diagnostics.Fields({ LogSinkDropped = 0 / 0, LogSinkErrors = math.huge }, {}, {})).toBe(0)
end)

it("keeps all diagnostics within six compact Discord fields", function()
	local metrics = { ReceiptHistoryRefusals = 1e300, LogSinkDropped = 1e300, LogSinkErrors = 1e300 }
	for _, name in
		{
			"LbWrites",
			"LbWritesSkipped",
			"LbReadFailures",
			"LbWriteFailures",
			"LbQueueDepth",
			"LbBudgetDeferred",
			"LbQueueOverflow",
		}
	do
		metrics[name] = 1e300
	end
	local sample = { P50 = 1e300, P90 = 1e300, P99 = 1e300, Samples = 1e300, Window = 1e300, Age = 1e300 }
	local result = Diagnostics.Fields(metrics, {}, {
		ProfileLoadDuration = sample,
		LoadDuration = sample,
		PlayerLeavingHookDuration = sample,
	})
	expect(#result).toBe(6)
	local size = 0
	for _, field in result do
		expect(#field.Value <= 1024).toBe(true)
		size += #field.Name + #field.Value
	end
	expect(size < 2000).toBe(true)
	expect(metrics.LbWrites).toBe(1e300)
end)
