--!strict
-- Optional runtime diagnostics for the periodic summary.

local Format = require(script.Parent.Format)

local Diagnostics = {}

local function number(value: any): number?
	return if type(value) == "number" and value >= 0 and value < math.huge then value else nil
end

local function countText(value: number?): string
	if value == nil then
		return "n/a"
	end
	return if value >= 1e9 then string.format("%.3g", value) else tostring(value)
end

local function duration(value: any): string
	local seconds = number(value)
	if seconds == nil then
		return "n/a"
	elseif seconds < 10 then
		return string.format("%.2fs", seconds)
	elseif seconds < 60 then
		return `{math.floor(seconds)}s`
	elseif seconds < 3600 then
		return `{math.floor(seconds / 60)}m {math.floor(seconds % 60)}s`
	end
	return `{countText(math.floor(seconds / 3600))}h {math.floor((seconds % 3600) / 60)}m`
end

local function distribution(p: any): string
	if type(p) ~= "table" or number(p.Samples) == 0 then
		return "no samples"
	end
	return `p50 {duration(p.P50)} · p90 {duration(p.P90)} · p99 {duration(p.P99)} ({countText(number(p.Samples))} samples over {duration(
		p.Window
	)}, newest {duration(p.Age)} ago)`
end

function Diagnostics.Fields(
	metrics: { [string]: any },
	previous: { [string]: any },
	percentiles: { [string]: any }
): { Format.Field }
	local fields: { Format.Field } = {}
	local function present(names: { string }): boolean
		for _, name in names do
			if number(metrics[name]) ~= nil then
				return true
			end
		end
		return false
	end
	local function count(name: string): string
		local current = number(metrics[name])
		return countText(if current == nil then nil else math.max(0, current - (number(previous[name]) or 0)))
	end
	local function add(name: string, value: string, inline: boolean?)
		table.insert(fields, { Name = name, Value = value, Inline = inline })
	end
	if present({ "ReceiptHistoryRefusals" }) then
		add("Receipts", `{count("ReceiptHistoryRefusals")} history-capacity refusals`, true)
	end
	if present({ "LogSinkDropped", "LogSinkErrors" }) then
		add("Log delivery", `{count("LogSinkDropped")} dropped · {count("LogSinkErrors")} sink errors`, true)
	end
	if
		present({
			"LbWrites",
			"LbWritesSkipped",
			"LbReadFailures",
			"LbWriteFailures",
			"LbQueueDepth",
			"LbBudgetDeferred",
			"LbQueueOverflow",
		})
	then
		add(
			"Leaderboard requests",
			`{count("LbWrites")} writes · {count("LbWritesSkipped")} skipped\n{count("LbReadFailures")} read failures · {count(
				"LbWriteFailures"
			)} write failures\n{countText(number(metrics.LbQueueDepth))} last reported queue · {count(
				"LbBudgetDeferred"
			)} budget deferrals · {count("LbQueueOverflow")} queue drops`
		)
	end
	for _, definition in
		{
			{ "ProfileLoadDuration", "Profile acquisition (rolling)" },
			{ "LoadDuration", "Player load (rolling)" },
			{ "PlayerLeavingHookDuration", "Player leaving hook (rolling)" },
		}
	do
		local key, label = definition[1], definition[2]
		if type(metrics[key]) == "table" or type(percentiles[key]) == "table" then
			add(label, distribution(percentiles[key]))
		end
	end
	return fields
end

return Diagnostics
