--!strict
-- Metrics counters. Library-level singleton.

local Metrics = {}

local counters: { [string]: number } = {}
local gauges: { [string]: number } = {}
local observations: { [string]: { Count: number, Sum: number, Max: number } } = {}

function Metrics.Add(name: string, n: number?)
	counters[name] = (counters[name] or 0) + (n or 1)
end

function Metrics.Set(name: string, value: number)
	gauges[name] = value
end

-- Record one sample of a distribution (durations, byte counts).
function Metrics.Observe(name: string, value: number)
	local obs = observations[name]
	if not obs then
		obs = { Count = 0, Sum = 0, Max = 0 }
		observations[name] = obs
	end
	obs.Count += 1
	obs.Sum += value
	if value > obs.Max then
		obs.Max = value
	end
end

function Metrics.Get(): { [string]: any }
	local out: { [string]: any } = table.clone(counters)
	for name, value in gauges do
		out[name] = value
	end
	for name, obs in observations do
		out[name] = {
			Count = obs.Count,
			Average = if obs.Count > 0 then obs.Sum / obs.Count else 0,
			Max = obs.Max,
		}
	end
	return out
end

return Metrics
