--!nonstrict
-- Failure injection: an armed queue for exact unit assertions, plus probabilistic
-- rates for soaks.
--
-- INDETERMINATE IS THE ONE THAT EARNS ITS KEEP. The write COMMITS and then the
-- call raises, so the caller cannot know whether it happened. Every Roblox
-- DataStore mock in circulation models only success and failure, and that missing
-- third outcome is exactly where the expensive bugs live: ProfileStore treats
-- every error as "did not happen" and an ending-session save retries, so a
-- committed-then-failed write is a double-apply path. Jepsen calls this outcome
-- `:info` and treats it as first-class; so does this.
--
-- Determinism note: probabilistic draws come from the "disk.fault" stream and are
-- taken ONLY when a rate has been set. A run with rates and a run without are
-- different configurations and must never be compared as if they were the same
-- seed -- so whether any rate was set is recorded, not inferred.

local Errors = require(script.Parent.Errors)

local Faults = {}
Faults.__index = Faults

-- Which catalogued error each fault kind raises. Deliberately reusing the real
-- catalogue rather than inventing messages: what the code under test sees has to
-- be indistinguishable from the real thing, or a consumer could special-case it.
local RAISES = {
	ServiceError = "ApiRejected",
	Throttled = "RequestQueueFull",
	Indeterminate = "RequestTimedOut",
	ShuttingDown = "ApiRejected",
}

function Faults.new(config)
	return setmetatable({
		_rng = config.Rng,
		_armed = {},
		_rates = {},
		_anyRateSet = false,
		Stats = {
			Injected = 0,
			IndeterminateCommits = 0,
			Lost = 0,
		},
	}, Faults)
end

--- Arm a specific fault, for a spec that wants an exact scenario.
---
--- `Count` fires that many times then retires. Op/Store/Key narrow the match; the
--- most specific armed entry wins, so a broad arm cannot mask a targeted one.
function Faults.Arm(self, spec)
	table.insert(self._armed, {
		Kind = spec.Kind,
		Op = spec.Op,
		Store = spec.Store,
		Key = spec.Key,
		Remaining = spec.Count or 1,
	})
end

--- Set probabilistic rates, for soaks. Values are per-request probabilities.
function Faults.SetRate(self, rates)
	for kind, rate in rates do
		self._rates[kind] = rate
		if rate > 0 then
			self._anyRateSet = true
		end
	end
end

--- Disarm everything. The liveness gate's off switch: a soak injects faults, then
--- heals and asserts the system SETTLES. Without a way back to a healthy world,
--- "it never recovered" and "it was still being broken" are indistinguishable.
function Faults.Heal(self)
	self._armed = {}
	self._rates = {}
	self._anyRateSet = false
end

function Faults.AnyRateSet(self): boolean
	return self._anyRateSet
end

local function specificity(entry): number
	local score = 0
	if entry.Op ~= nil then
		score += 1
	end
	if entry.Store ~= nil then
		score += 2
	end
	if entry.Key ~= nil then
		score += 4
	end
	return score
end

--- Decide whether this request fails, and how. Returns a kind or nil.
function Faults.Next(self, op: string, store: string, key: string): string?
	local best, bestIndex, bestScore = nil, nil, -1
	for index, entry in self._armed do
		local matches = (entry.Op == nil or entry.Op == op)
			and (entry.Store == nil or entry.Store == store)
			and (entry.Key == nil or entry.Key == key)
		if matches then
			local score = specificity(entry)
			if score > bestScore then
				best, bestIndex, bestScore = entry, index, score
			end
		end
	end

	if best ~= nil then
		best.Remaining -= 1
		if best.Remaining <= 0 then
			table.remove(self._armed, bestIndex)
		end
		self.Stats.Injected += 1
		return best.Kind
	end

	-- An unconfigured run must consume NOTHING from the fault stream, or adding a
	-- rate later would renumber every subsequent draw and quietly change what a
	-- seed means.
	--
	-- Note what actually enforces that: the `and` below short-circuits, so
	-- NextNumber is never reached unless a rate is above zero. This early return
	-- is a statement of intent and a cheap exit, NOT the guarantee -- removing it
	-- changes no behaviour. Recorded because a comment claiming otherwise would
	-- invite someone to reorder the condition and break the real protection.
	if not self._anyRateSet then
		return nil
	end
	for kind, rate in self._rates do
		if rate > 0 and self._rng:NextNumber() < rate then
			self.Stats.Injected += 1
			return kind
		end
	end
	return nil
end

--- Raise `kind` as the backend would.
function Faults.Raise(_self, kind: string)
	local name = RAISES[kind]
	if name == nil then
		error(`sim: fault kind "{kind}" has no error mapping`, 0)
	end
	Errors.Raise(name)
end

Faults.RAISES = RAISES

return Faults
