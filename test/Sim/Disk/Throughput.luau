--!nonstrict
-- Per-key throughput: 4 MB/min written, 25 MB/min read, over a 60-second rolling
-- window.
--
-- This REPLACES the folklore 6-second per-key write cooldown, which Roblox
-- removed in June 2023 and which is absent from current documentation. Modelling
-- the cooldown would manufacture failures production cannot produce; this is the
-- backpressure that actually exists on a hot key, and at high CCU it is the limit
-- a shared key hits first.
--
-- Worth flagging where it lands: Scribe's own MIN_SAVE_INTERVAL floor is
-- justified in-code by "Roblox throttles per-key writes (~1 per 6s)". That
-- premise is stale. The floor may still be worth keeping for other reasons, but
-- the model must not be built to validate the reason given.
--
-- A 60-slot ring, indexed by second, each slot stamped with the second it belongs
-- to so stale slots zero themselves on read. O(1) per request, no scan, and --
-- like the budget -- no thread: a sweeper that never finishes would keep the
-- scheduler's sleeper set non-empty and stop runs terminating.

local Throughput = {}
Throughput.__index = Throughput

local WINDOW = 60

-- CONFIDENCE: both figures are documented per-key limits.
local WRITE_BYTES_PER_MIN = 4 * 1024 * 1024
local READ_BYTES_PER_MIN = 25 * 1024 * 1024

-- Roblox bills per KiB, so a stream of tiny writes costs far more than their
-- byte sum -- which is exactly the shape of a chatty autosave.
local KIB = 1024

function Throughput.new(config)
	return setmetatable({
		_sched = config.Sched,
		_keys = {},
		WriteLimit = config.WriteBytesPerMin or WRITE_BYTES_PER_MIN,
		ReadLimit = config.ReadBytesPerMin or READ_BYTES_PER_MIN,
		Stats = { Throttles = 0, BytesWritten = 0, BytesRead = 0 },
	}, Throughput)
end

local function ringFor(self, id: string, direction: string)
	local key = self._keys[id]
	if key == nil then
		key = { Write = { Slots = {}, Stamps = {} }, Read = { Slots = {}, Stamps = {} } }
		self._keys[id] = key
	end
	return key[direction]
end

--- Bytes moved on this key in the last 60 seconds.
local function total(ring, now: number): number
	local sum = 0
	local oldest = now - WINDOW
	for slot = 0, WINDOW - 1 do
		local stamp = ring.Stamps[slot]
		if stamp ~= nil and stamp > oldest then
			sum += ring.Slots[slot]
		end
	end
	return sum
end

--- Would `bytes` more on this key breach the window?
---
--- Asked BEFORE the request is admitted, so a breach can skip the request rather
--- than fail it -- the caller waits for the window to roll instead of seeing an
--- error the real backend would not have produced.
function Throughput.WouldExceed(self, id: string, direction: string, bytes: number): boolean
	local ring = ringFor(self, id, direction)
	local now = math.floor(self._sched.Now)
	local limit = if direction == "Write" then self.WriteLimit else self.ReadLimit
	return total(ring, now) + math.ceil(bytes / KIB) * KIB > limit
end

--- Record bytes moved.
function Throughput.Charge(self, id: string, direction: string, bytes: number)
	local ring = ringFor(self, id, direction)
	local now = math.floor(self._sched.Now)
	local slot = now % WINDOW
	-- A slot whose stamp is not this second belongs to a previous minute; reuse
	-- rather than accumulate, which is what makes the window roll without a sweep.
	if ring.Stamps[slot] ~= now then
		ring.Stamps[slot] = now
		ring.Slots[slot] = 0
	end
	local charged = math.ceil(bytes / KIB) * KIB
	ring.Slots[slot] += charged
	if direction == "Write" then
		self.Stats.BytesWritten += charged
	else
		self.Stats.BytesRead += charged
	end
end

function Throughput.Used(self, id: string, direction: string): number
	return total(ringFor(self, id, direction), math.floor(self._sched.Now))
end

Throughput.WINDOW = WINDOW
Throughput.WRITE_BYTES_PER_MIN = WRITE_BYTES_PER_MIN
Throughput.READ_BYTES_PER_MIN = READ_BYTES_PER_MIN

return Throughput
