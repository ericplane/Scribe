--!strict
-- The simulation kernel: a seeded cooperative scheduler with a virtual clock.
--
-- Two ideas, and they are the whole reason a simulation can find bugs a test
-- suite cannot.
--
-- SEEDED INTERLEAVING. Which coroutine resumes next is drawn from a seeded RNG
-- rather than decided by the engine, so an ordering bug -- a save landing between
-- two writes, a rollback racing a listener -- is reproducible. Seed 4171 produces
-- exactly one run, every time, and a failure you saw once you can see again.
--
-- VIRTUAL TIME. `Now` is a counter, not a reading of a timer. Nothing advances it
-- except the scheduler, and it only advances when NOTHING can run: the loop
-- drains every runnable thread, then jumps straight to the next wake time. A
-- thread that asks to sleep for a day costs one comparison, so eight hours of
-- autosaves is microseconds of wall clock rather than eight hours of waiting.
--
-- This is a discrete-event loop, and the ordering rule matters: at equal wake
-- times threads are woken in registration order, then the RUNNABLE set is shuffled
-- by the seed. Waking in a seeded order as well would be more thorough, but it
-- would also make "which thread woke first" depend on the RNG rather than on the
-- durations the code actually asked for, and that costs more in confusing failures
-- than it buys in coverage.

local Rng = require(script.Parent.Rng)

local Scheduler = {}
Scheduler.__index = Scheduler

-- A run that never empties its ready set is a bug in the workload (a thread that
-- yields without ever finishing), not a reason to hang the suite.
local DEFAULT_STEP_LIMIT = 1000000

type Sleeper = { Thread: thread, WakeAt: number, Seq: number }

export type Scheduler = typeof(setmetatable(
	{} :: {
		Rng: Rng.Rng,
		Now: number,
		Steps: number,
		Live: number,
		Stalled: boolean,
		Deadlocked: boolean,
		_known: { [thread]: boolean },
		_ready: { thread },
		_sleeping: { Sleeper },
		_seq: number,
	},
	Scheduler
))

-- The sleeper set is a binary MIN-HEAP on wake time, not a list.
--
-- It began as a list with a linear scan for the earliest wake, which is fine when
-- threads share wake times: _advance runs once per DISTINCT time and releases a
-- whole batch. But the pattern this kernel exists to simulate is the opposite --
-- every in-flight storage request draws its own latency, so every wake time is
-- distinct, _advance runs once per sleeper, and each run rescans everything.
-- Measured, that was O(N^2): 17ms at 250 sleepers, 932ms at 2000, ratio 4.0 per
-- doubling. Ten thousand concurrent requests -- the whole point of the exercise --
-- would have taken about 23 seconds, past the harness's per-test timeout.
--
-- Ties break on insertion sequence, which preserves the documented rule that
-- threads with equal wake times resume in registration order. Without that the
-- heap would order equal keys arbitrarily and a seed would stop naming one run.
local function sleeperLess(a: Sleeper, b: Sleeper): boolean
	if a.WakeAt ~= b.WakeAt then
		return a.WakeAt < b.WakeAt
	end
	return a.Seq < b.Seq
end

local function heapPush(heap: { Sleeper }, item: Sleeper)
	local index = #heap + 1
	heap[index] = item
	while index > 1 do
		local parent = index // 2
		if sleeperLess(heap[index], heap[parent]) then
			heap[index], heap[parent] = heap[parent], heap[index]
			index = parent
		else
			break
		end
	end
end

local function heapPop(heap: { Sleeper }): Sleeper
	local top = heap[1]
	local last = #heap
	heap[1] = heap[last]
	heap[last] = nil
	local size = last - 1
	local index = 1
	while true do
		local left, right = index * 2, index * 2 + 1
		local smallest = index
		if left <= size and sleeperLess(heap[left], heap[smallest]) then
			smallest = left
		end
		if right <= size and sleeperLess(heap[right], heap[smallest]) then
			smallest = right
		end
		if smallest == index then
			break
		end
		heap[index], heap[smallest] = heap[smallest], heap[index]
		index = smallest
	end
	return top
end
function Scheduler.new(seed: number, startAt: number?): Scheduler
	return setmetatable({
		Rng = Rng.new(seed),
		-- A fixed, arbitrary epoch rather than the real clock: a simulation whose
		-- start time varies is not reproducible, and any persisted timestamp it
		-- writes would differ run to run.
		Now = startAt or 1700000000,
		Steps = 0,
		Live = 0,
		Stalled = false,
		Deadlocked = false,
		-- Weak-keyed: a thread the kernel started but that is now garbage must not
		-- be pinned alive by its own bookkeeping.
		_known = (setmetatable({}, { __mode = "k" }) :: any) :: { [thread]: boolean },
		_ready = {},
		_sleeping = {},
		_seq = 0,
	}, Scheduler)
end

--- Start `fn` IMMEDIATELY, on the caller's stack, until it yields or returns --
--- matching task.spawn. Queuing it instead would be task.defer's behaviour under
--- task.spawn's name, and Scribe relies on the difference: a spawned load that
--- never yields has already finished by the time this returns.
---
--- The seeded shuffle applies to threads that have YIELDED and are waiting to be
--- resumed, which is where real interleaving nondeterminism actually lives.
--- Choosing who starts first as well would explore orderings the engine cannot
--- produce, and a simulation that reports impossible failures is worse than none.
function Scheduler.Spawn(self: Scheduler, fn: (...any) -> (), ...: any): thread
	local args = table.pack(...)
	local thread = coroutine.create(function()
		fn(table.unpack(args, 1, args.n))
	end)
	self.Live += 1
	self._known[thread] = true
	local ok, err = coroutine.resume(thread)
	if not ok then
		self.Live -= 1
		error(`sim: a spawned thread errored: {tostring(err)}`, 0)
	end
	if coroutine.status(thread) == "dead" then
		self.Live -= 1
	end
	return thread
end

--- Queue `fn` to run once the loop reaches it, matching task.defer.
function Scheduler.Defer(self: Scheduler, fn: (...any) -> (), ...: any): thread
	local args = table.pack(...)
	local thread = coroutine.create(function()
		fn(table.unpack(args, 1, args.n))
	end)
	self.Live += 1
	self._known[thread] = true
	table.insert(self._ready, thread)
	return thread
end

--- Resume a thread that is already blocked, immediately, matching the
--- task.spawn(thread, ...) overload.
---
--- Such a thread yielded through raw coroutine.yield rather than Wait, so the
--- loop is not tracking it in either set -- it is blocked on an answer, not on
--- time, and whoever holds the reference is the only thing that can wake it. It
--- still counts as Live, which is what makes a stuck request show up as a
--- simulation that will not settle rather than one that quietly finished.
--- Resuming a thread that is not suspended is an error here because it is an
--- error in the engine too. Swallowing it would make the simulation MORE
--- permissive than production, which is the one direction a simulation must
--- never diverge: a double-resume that crashes a live server would replay
--- clean, and the report would say the schedule was fine.
function Scheduler.Resume(self: Scheduler, thread: thread, ...: any)
	local status = coroutine.status(thread)
	if status ~= "suspended" then
		error(`sim: resumed a thread that was {status}, not suspended`, 0)
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		self.Live -= 1
		error(`sim: a resumed thread errored: {tostring(err)}`, 0)
	end
	if coroutine.status(thread) == "dead" then
		self.Live -= 1
	end
end

--- Yield the running thread for `seconds` of VIRTUAL time. Zero (or nil) puts it
--- straight back in the runnable set, which is how a loop cooperates without
--- claiming to have slept.
function Scheduler.Wait(self: Scheduler, seconds: number?): number
	local running = coroutine.running()
	local delay = seconds or 0
	if delay <= 0 then
		table.insert(self._ready, running)
	else
		self._seq += 1
		heapPush(self._sleeping, { Thread = running, WakeAt = self.Now + delay, Seq = self._seq })
	end
	coroutine.yield()
	return delay
end

--- Run `fn` after `seconds` of virtual time.
function Scheduler.Delay(self: Scheduler, seconds: number, fn: (...any) -> (), ...: any): thread
	local args = table.pack(...)
	return self:Spawn(function()
		self:Wait(seconds)
		fn(table.unpack(args, 1, args.n))
	end)
end

--- Advance to the next wake time when nothing is runnable. Returns false when the
--- simulation has nothing left to do at any time.
function Scheduler._advance(self: Scheduler): boolean
	if #self._sleeping == 0 then
		return false
	end
	-- Never move time backwards; a clock that can go back invalidates every
	-- deadline comparison in the system under test.
	self.Now = math.max(self.Now, self._sleeping[1].WakeAt)
	while #self._sleeping > 0 and self._sleeping[1].WakeAt <= self.Now do
		table.insert(self._ready, heapPop(self._sleeping).Thread)
	end
	return true
end
--- Resume exactly one thread, chosen by the seed. Returns false when there was
--- nothing to resume and no time left to advance to.
function Scheduler.Step(self: Scheduler): boolean
	if #self._ready == 0 and not self:_advance() then
		return false
	end
	if #self._ready == 0 then
		return false
	end
	local index = self.Rng:NextInteger(#self._ready)
	local thread = table.remove(self._ready, index) :: thread
	self.Steps += 1
	local ok, err = coroutine.resume(thread)
	if not ok then
		self.Live -= 1
		error(`sim: a scheduled thread errored: {tostring(err)}`, 0)
	end
	if coroutine.status(thread) == "dead" then
		self.Live -= 1
	end
	return true
end

--- Step until nothing is runnable, or `untilTime` is reached, or the step limit
--- trips. Sets `Stalled` rather than erroring on the limit, so a caller can
--- report the workload's own bug with its own context.
function Scheduler.Run(self: Scheduler, untilTime: number?, stepLimit: number?): number
	local limit = stepLimit or DEFAULT_STEP_LIMIT
	local before = self.Steps
	while self.Steps - before < limit do
		if untilTime ~= nil and #self._ready == 0 then
			-- Only stop on time when nothing is runnable: stopping with work
			-- pending would leave the system mid-operation and make any invariant
			-- checked afterwards meaningless.
			local nextWake = if #self._sleeping > 0 then self._sleeping[1].WakeAt else math.huge
			if nextWake > untilTime then
				self.Now = math.max(self.Now, untilTime)
				return self.Steps - before
			end
		end
		if not self:Step() then
			-- Nothing runnable and nothing asleep, but threads are still alive:
			-- they are blocked on an answer that will never arrive. This is a
			-- DEADLOCK, and it is the failure a storage simulation most needs to
			-- see -- "the save never completed" is precisely a request thread
			-- parked forever. Without this the run just ends and reports success.
			--
			-- Not raised as an error: a caller stopping early via `untilTime`
			-- legitimately leaves work pending, and only the caller knows which
			-- case it is in. Settled() is the question to ask.
			if self.Live > 0 then
				self.Deadlocked = true
			end
			return self.Steps - before
		end
	end
	-- The step limit tripped -- but that is only a STALL if work actually remains.
	-- A run whose final step happened to be its last allowed one finished
	-- perfectly well, and reporting that as stalled is a false alarm on a healthy
	-- run. A liveness signal that cries wolf is one nobody reads.
	self.Stalled = self.Live > 0
	return self.Steps - before
end

--- Did the run finish with every thread accounted for?
---
--- The predicate is exactly "nothing is left alive". `Deadlocked` and `Stalled`
--- are the DIAGNOSIS of an unsettled run, not extra conditions on top of it --
--- both imply live threads, so testing them here would be untestable dead
--- weight. Ask Settled() whether the world finished; read the two fields to find
--- out why it did not.
---
--- Any invariant checked after an unsettled run is checked on a half-built world,
--- so a simulation should assert this before it asserts anything else.
function Scheduler.Settled(self: Scheduler): boolean
	return self.Live == 0
end

--- coroutine.resume's exact contract -- returns (ok, ...) and never raises -- with
--- Live accounting attached.
---
--- This exists for FOREIGN resumes. ProfileStore parks a thread on its update
--- queue with a raw coroutine.yield() and wakes it with a raw coroutine.resume(),
--- neither of which the kernel can see. Live is decremented only where Spawn,
--- Step and Resume observe a thread reach "dead", so a thread that dies inside a
--- foreign resume leaks a Live count forever -- and because Run reports a deadlock
--- whenever nothing is runnable while Live > 0, EVERY clean run would report one.
---
--- A simulation therefore binds this as `coroutine.resume` in the environment it
--- hands the vendored module, which closes the accounting hole without patching
--- the library.
---
--- The _known gate matters: resuming a thread the kernel never started must not
--- push Live negative and mask a real leak in the other direction.
function Scheduler.ResumeRaw(self: Scheduler, co: thread, ...: any): ...any
	local tracked = self._known[co] == true and coroutine.status(co) == "suspended"
	local returned = table.pack(coroutine.resume(co, ...))
	if tracked and coroutine.status(co) == "dead" then
		self.Live -= 1
	end
	return table.unpack(returned, 1, returned.n)
end
--- The Scribe scheduling seam bound to this scheduler, for Sched.Install.
function Scheduler.SchedImpl(self: Scheduler)
	return {
		Spawn = function(fn: (...any) -> (), ...: any)
			return self:Spawn(fn, ...)
		end,
		Defer = function(fn: (...any) -> (), ...: any)
			return self:Defer(fn, ...)
		end,
		Resume = function(thread: thread, ...: any)
			return self:Resume(thread, ...)
		end,
	}
end

--- The Scribe clock seam bound to this scheduler, for Clock.Install.
function Scheduler.ClockImpl(self: Scheduler)
	return {
		Now = function()
			return math.floor(self.Now)
		end,
		Monotonic = function()
			return self.Now
		end,
		Wait = function(seconds: number?)
			return self:Wait(seconds)
		end,
		Delay = function(seconds: number, fn: (...any) -> (), ...: any)
			return self:Delay(seconds, fn, ...)
		end,
	}
end

return Scheduler
