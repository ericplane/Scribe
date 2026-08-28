--!strict
-- The randomness seam: every draw goes through here, so a simulation can replay a
-- run exactly. Next() returns a float in [0, 1) and nothing else. Not math.random,
-- whose state is shared with the game, and not Random.new, which does not exist
-- outside Roblox.
--
-- Seeded from JobId mixed with Clock.Now(): a fleet booted by one deploy reads
-- nearly the same wall clock, and a herd left synchronised by neighbouring seeds
-- is the failure that jitter exists to prevent. Clock.Now() covers Studio, where
-- JobId is empty. Seeded lazily, on the first draw, so a module that draws while
-- loading does not sample the clock before Clock.Install has run.

local Clock = require(script.Parent.Clock)

local Rng = {}

export type Impl = {
	Next: (() -> number)?,
}

-- xorshift32 has zero as a fixed point: seeded there it returns zero forever.
local ZERO_SEED_SUBSTITUTE = 0x9E3779B9

local state: number? = nil

--- FNV-1a over this server's job id, mixed with wall time. Inlined rather than
--- taken from Util to keep this seam's dependencies small.
local function makeSeed(): number
	local hash = 2166136261
	local jobId = tostring((game :: any).JobId)
	for i = 1, #jobId do
		hash = bit32.band(bit32.bxor(hash, string.byte(jobId, i)) * 16777619, 0xFFFFFFFF)
	end
	hash = bit32.bxor(hash, bit32.band(math.floor(Clock.Now()), 0xFFFFFFFF))
	if hash == 0 then
		return ZERO_SEED_SUBSTITUTE
	end
	return hash
end

local DEFAULT_NEXT: () -> number = function(): number
	local s = state or makeSeed()
	s = bit32.bxor(s, bit32.lshift(s, 13))
	s = bit32.bxor(s, bit32.rshift(s, 17))
	s = bit32.bxor(s, bit32.lshift(s, 5))
	state = s
	return s / 4294967296
end

Rng.Next = DEFAULT_NEXT

--- Replace the draw. Omitting it keeps the current value, matching Clock and Sched.
--- A replacement must stay inside [0, 1): jitter multiplies a delay by it, so a
--- larger value overruns the bound its caller reasoned about and a negative one
--- turns a wait into an immediate retry.
function Rng.Install(impl: Impl)
	if impl.Next ~= nil then
		Rng.Next = impl.Next
	end
end

-- How far a jittered delay may stray from nominal, in either direction.
local JITTER_FRACTION = 0.25

-- Floor for a jittered delay, guarding an installed Next that breaks its [0, 1)
-- contract. Must be strictly positive: the simulation scheduler re-queues a wait of
-- <= 0 without advancing virtual time, so the run stalls at its step limit and
-- reads as a deadlocked workload.
local MIN_DELAY = 1 / 60

--- `seconds`, moved up or down by up to a quarter. Two-sided and bounded at both
--- ends, so it is safe inside loops that already assert timing.
---
--- For delays, not for timeouts: a timeout is a promise about when a caller will be
--- answered, so moving it changes a contract.
function Rng.Jitter(seconds: number): number
	return math.max(seconds * (1 + (Rng.Next() - 0.5) * 2 * JITTER_FRACTION), MIN_DELAY)
end

--- Restore the default. A test that installs must reset, or it hands its generator
--- to every spec that runs afterwards. The default's own state is not rewound, so
--- nothing can depend on the sequence a reset produces.
function Rng.Reset()
	Rng.Next = DEFAULT_NEXT
end

return Rng
