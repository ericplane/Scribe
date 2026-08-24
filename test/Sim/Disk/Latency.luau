--!nonstrict
-- How long a modelled disk operation takes.
--
-- HONESTY NOTE, and it is the most important thing in this file: Roblox publishes
-- NO latency figures for DataStore operations. Every number here is invented. They
-- are chosen to be plausible and are named so they can be corrected, but no
-- conclusion that depends on their exact values is a fact about Scribe.
--
-- That is why profiles exist rather than one hard-coded distribution. Any finding
-- that matters should be reproduced across at least Nominal and Slow; a result
-- that appears under one and vanishes under another is a property of this file,
-- and must be reported as model-dependent rather than as a property of the code
-- under test.
--
-- The draw comes from a NAMED Rng stream, separate from the scheduler's. If disk
-- latency drew from the scheduler's generator, changing a latency profile would
-- shift every subsequent thread-scheduling decision, and two profiles at one seed
-- would stop being comparable -- which is the whole reason to have a seed.

local Latency = {}
Latency.__index = Latency

export type Profile = {
	Read: { Min: number, Max: number, TailChance: number, TailMax: number },
	Write: { Min: number, Max: number, TailChance: number, TailMax: number },
}

-- All values in seconds. INVENTED -- see the note above.
Latency.PROFILES = {
	-- A healthy experience in a well-served region.
	Nominal = {
		Read = { Min = 0.02, Max = 0.09, TailChance = 0.02, TailMax = 0.45 },
		Write = { Min = 0.04, Max = 0.15, TailChance = 0.02, TailMax = 0.70 },
	},
	-- A bad day: everything slower, long tails more common. This is the profile
	-- that opens conflict windows wide enough for contention bugs to show.
	Slow = {
		Read = { Min = 0.15, Max = 0.60, TailChance = 0.10, TailMax = 2.50 },
		Write = { Min = 0.25, Max = 0.90, TailChance = 0.12, TailMax = 4.00 },
	},
	-- Degenerate, for isolating a specific interleaving. Every operation takes the
	-- same time, so orderings depend only on the scheduler.
	Fixed = {
		Read = { Min = 0.05, Max = 0.05, TailChance = 0, TailMax = 0.05 },
		Write = { Min = 0.05, Max = 0.05, TailChance = 0, TailMax = 0.05 },
	},
	-- Effectively instant, for unit specs where latency is noise rather than the
	-- subject. NOT zero: an operation that never yields cannot be interleaved, and
	-- a store that returns synchronously hides every ordering bug there is.
	Instant = {
		Read = { Min = 0.001, Max = 0.001, TailChance = 0, TailMax = 0.001 },
		Write = { Min = 0.001, Max = 0.001, TailChance = 0, TailMax = 0.001 },
	},
}

function Latency.new(rng, profileName: string?)
	local name = profileName or "Nominal"
	local profile = Latency.PROFILES[name]
	if profile == nil then
		error(`sim: unknown latency profile "{name}"`, 0)
	end
	return setmetatable({ Rng = rng, Name = name, Profile = profile }, Latency)
end

--- Draw a duration for `kind` ("Read" or "Write").
---
--- Bimodal on purpose: a uniform band plus an occasional long tail. Real storage
--- latency is not uniform, and the tail is where the interesting interleavings
--- live -- a save that takes two seconds while a steal lands is exactly the shape
--- of a lost write.
function Latency.Draw(self, kind: string): number
	local band = self.Profile[kind]
	if band == nil then
		error(`sim: unknown latency kind "{kind}"`, 0)
	end
	if band.TailChance > 0 and self.Rng:NextNumber() < band.TailChance then
		return band.Max + self.Rng:NextNumber() * (band.TailMax - band.Max)
	end
	return band.Min + self.Rng:NextNumber() * (band.Max - band.Min)
end

return Latency
