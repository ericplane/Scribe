--!strict
-- A seeded pseudo-random source for the simulation.
--
-- Deliberately NOT math.random or Random.new. math.random is a process global
-- that any spec can reseed, and Roblox's Random gives no promise that its
-- sequence is stable across engine versions -- either would mean a seed stopped
-- meaning one specific run, which is the whole value of seeding it.
--
-- This is xorshift32, evaluated entirely through bit32. Its statistical quality
-- is unremarkable and that is fine: the job is to choose which thread runs next
-- and which operation to perform, not to be cryptographic.
--
-- It REPLACES a textbook LCG (state = (1103515245 * state + 12345) % 2^31) that
-- was silently broken, and the reason is worth keeping because it is easy to
-- reintroduce. Luau numbers are doubles with a 53-bit mantissa. 1103515245 is
-- about 2^30, so multiplying it by a state near 2^31 produces ~2^61 -- past the
-- mantissa -- and the product is rounded to a multiple of 2^8. The low eight bits
-- are therefore always zero, and `state % n` for any even n collapses:
-- NextInteger(2) returned 1 on 99.577% of draws (measured, 200k samples).
--
-- The scheduler picks the next thread with NextInteger(#ready), so the kernel was
-- effectively FIFO at every even-sized ready set -- it looked like it was
-- searching interleavings while running one fixed order. Odd n was unaffected,
-- which is exactly why reproducibility and range tests passed and nothing caught
-- it. Distribution is now asserted (see SimKernel.spec).
--
-- bit32 operates on exact 32-bit values, so every step here stays representable.

local Rng = {}
Rng.__index = Rng

-- xorshift32 has one fixed point: zero maps to zero forever. Any seed that lands
-- on it is replaced, or that "seed" would name a constant sequence.
local ZERO_SEED_SUBSTITUTE = 0x9E3779B9 -- golden-ratio constant, arbitrary but nonzero

export type Rng = typeof(setmetatable(
	{} :: {
		_state: number,
	},
	Rng
))

function Rng.new(seed: number): Rng
	local state = bit32.band(math.floor(math.abs(seed)), 0xFFFFFFFF)
	if state == 0 then
		state = ZERO_SEED_SUBSTITUTE
	end
	return setmetatable({ _state = state }, Rng)
end

local function advance(state: number): number
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	return state
end

--- Next integer in [1, n]. Returns 1 for n <= 1 so callers can pass a count
--- without guarding an empty range.
---
--- The modulo is biased by at most one part in 2^32/n, which for the thread
--- counts and operation tables this picks between is far below the noise of the
--- generator itself.
function Rng.NextInteger(self: Rng, n: number): number
	if n <= 1 then
		return 1
	end
	self._state = advance(self._state)
	return (self._state % n) + 1
end

--- An independent stream from one master seed, named by `label`.
---
--- Use this instead of Rng.new(seed + k). `Rng.new` does a bare floor/band with no
--- mixing, so adjacent seeds start one step apart in the same sequence rather than
--- in different ones.
---
--- The point is stream INDEPENDENCE. If the disk drew its latencies from the
--- scheduler's generator, changing a latency distribution would shift every
--- subsequent thread-scheduling decision, and two configurations at the same seed
--- would stop being comparable -- the thing a seed exists to make possible. Names
--- also make the streams stable: adding a new one cannot renumber the others.
function Rng.Stream(seed: number, label: string): Rng
	local hash = 2166136261
	for i = 1, #label do
		hash = bit32.band(bit32.bxor(hash, string.byte(label, i)) * 16777619, 0xFFFFFFFF)
	end
	return Rng.new(bit32.bxor(bit32.band(math.floor(math.abs(seed)), 0xFFFFFFFF), hash))
end

--- Next float in [0, 1).
function Rng.NextNumber(self: Rng): number
	self._state = advance(self._state)
	return self._state / 4294967296
end

--- Pick one entry of an array. Returns nil for an empty one.
function Rng.Pick<T>(self: Rng, items: { T }): T?
	if #items == 0 then
		return nil
	end
	return items[self:NextInteger(#items)]
end

--- True with probability `p`.
function Rng.Chance(self: Rng, p: number): boolean
	return self:NextNumber() < p
end

return Rng
