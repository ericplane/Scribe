--!strict
-- Metrics counters. Library-level singleton.
--
-- Pull only: a host reads Metrics.Get() (published as Scribe.GetMetrics) on whatever
-- cadence it wants, as DebugHook does on a 1 Hz timer. Do not add a sink hook to Add;
-- counters are bumped on hot paths, and a sink there would put arbitrary game code
-- inside a save.

local Metrics = {}

-- Samples kept per observed name, for percentiles. A ring, not a growing list: an
-- unbounded sample set on a metric observed once per save is a slow leak. 256
-- samples is about 2 KB per name and enough for a stable P99.
local RESERVOIR = 256

type Observation = {
	Count: number,
	Sum: number,
	Max: number,
	-- Ring of the most recent samples. `Filled` is how many slots are live, which
	-- is not the same as Count once the ring wraps.
	Samples: { number },
	Next: number,
	Filled: number,
}

local counters: { [string]: number } = {}
local gauges: { [string]: number } = {}
local observations: { [string]: Observation } = {}

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
		obs = {
			Count = 0,
			Sum = 0,
			Max = 0,
			Samples = table.create(RESERVOIR) :: { number },
			Next = 1,
			Filled = 0,
		}
		observations[name] = obs
	end
	obs.Count += 1
	obs.Sum += value
	if value > obs.Max then
		obs.Max = value
	end
	obs.Samples[obs.Next] = value
	obs.Next = (obs.Next % RESERVOIR) + 1
	if obs.Filled < RESERVOIR then
		obs.Filled += 1
	end
end

--- Nearest-rank percentiles over the retained samples, or nil if there are none. The
--- sort target is a fresh table per call, not a shared scratch buffer: a buffer left
--- longer by a previous name would mix that name's tail into this one's percentiles,
--- with no error to notice.
function Metrics.Percentiles(name: string): { P50: number, P90: number, P99: number }?
	local obs = observations[name]
	if obs == nil or obs.Filled == 0 then
		return nil
	end

	local sorted: { number } = table.create(obs.Filled) :: { number }
	table.move(obs.Samples, 1, obs.Filled, 1, sorted)
	table.sort(sorted)

	local function at(p: number): number
		local index = math.ceil((p / 100) * obs.Filled)
		return sorted[math.clamp(index, 1, obs.Filled)]
	end
	return { P50 = at(50), P90 = at(90), P99 = at(99) }
end

--- Percentiles for every observed name.
function Metrics.GetPercentiles(): { [string]: { P50: number, P90: number, P99: number } }
	local out = {}
	for name in observations do
		local p = Metrics.Percentiles(name)
		if p ~= nil then
			out[name] = p
		end
	end
	return out
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

--- Clear every counter, gauge and sample. Nothing else holds a reference into these
--- tables: Get returns a fresh one and the observation records are private, so
--- clearing them cannot strand a reader.
function Metrics.Reset()
	table.clear(counters)
	table.clear(gauges)
	table.clear(observations)
end

Metrics.RESERVOIR = RESERVOIR

return Metrics
