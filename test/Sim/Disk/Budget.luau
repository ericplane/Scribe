--!nonstrict
-- Request budgets, in two tiers that are both spent on every request.
--
-- THE EXPERIENCE TIER IS THE POINT. Per server, writes accrue at 60 + n*40 per
-- minute; across the experience they accrue at 300 + CCU*20 -- HALF the per-player
-- rate. So the further up the CCU curve you go, the more certainly the experience
-- ceiling binds first, and a model with only per-server budgets would report write
-- headroom that does not exist. For a study whose entire question is high CCU,
-- that is the most misleading result it could produce.
--
-- REFILL IS LAZY, computed from the clock on each admission, and there is
-- deliberately NO refill thread. A thread that sleeps forever keeps the
-- scheduler's sleeper set non-empty, so a Run with no deadline never takes its
-- time exit, burns to the step limit, and sets the sticky Stalled flag -- which
-- then reads as a bug in the workload rather than in the harness. Scribe's own
-- rate buckets are lazy for the same reason.
--
-- THREE BEHAVIOURS AT ZERO, kept strictly apart. Collapsing them into
-- "throttled -> error" would massively overstate failure rates and understate
-- latency tails, which are the two numbers a capacity study is actually for:
--
--   1. budget exhausted    the request QUEUES and the caller keeps waiting.
--                          Not an error. This is the common case.
--   2. queue full          dropped with 301-306. The ONLY path to a throttle
--                          error code.
--   3. key throughput      queued but SKIPPED over, so one hot key cannot block
--                          the whole queue behind it.

local Errors = require(script.Parent.Errors)

local Budget = {}
Budget.__index = Budget

-- Per-minute limits. `n` is that server's player count.
--
-- CONFIDENCE: these follow Roblox's current published per-server quotas. Note
-- they contradict the older widely-quoted "60 + numPlayers * 10" -- which
-- ProfileStore's own source comment still assumes. Named constants so a
-- correction is a one-line edit rather than a redesign.
local SERVER_LIMITS = {
	StandardRead = function(n)
		return 60 + n * 40
	end,
	StandardWrite = function(n)
		return 60 + n * 40
	end,
	StandardRemove = function(n)
		return 60 + n * 40
	end,
	StandardList = function(n)
		return 5 + n * 2
	end,
	OrderedRead = function(n)
		return 60 + n * 40
	end,
	OrderedWrite = function(n)
		return 30 + n * 5
	end,
	OrderedRemove = function(n)
		return 30 + n * 5
	end,
	OrderedList = function(n)
		return 5 + n * 2
	end,
}

-- Per-experience, summed over every live server. `Write` at CCU*20 against the
-- per-server CCU*40 is the asymmetry described above.
local EXPERIENCE_LIMITS = {
	Read = function(ccu)
		return 300 + ccu * 40
	end,
	Write = function(ccu)
		return 300 + ccu * 20
	end,
	List = function(ccu)
		return 300 + ccu * 2
	end,
	Remove = function(ccu)
		return 300 + ccu * 40
	end,
}

-- Which experience pool a per-server kind draws from.
local EXPERIENCE_TIER = {
	StandardRead = "Read",
	OrderedRead = "Read",
	StandardWrite = "Write",
	OrderedWrite = "Write",
	StandardRemove = "Remove",
	OrderedRemove = "Remove",
	StandardList = "List",
	OrderedList = "List",
}

-- Which of the four queues a request waits in, and the error it is dropped with.
local QUEUE_OF = {
	StandardRead = "Get",
	StandardList = "Get",
	OrderedRead = "OrderedGet",
	OrderedList = "OrderedGet",
	StandardWrite = "Set",
	StandardRemove = "Set",
	OrderedWrite = "OrderedSet",
	OrderedRemove = "OrderedSet",
}

local DROP_ERROR = {
	GetAsync = "RequestQueueFull",
	ListVersionsAsync = "RequestQueueFull",
	SetAsync = "SetQueueFull",
	UpdateAsync = "UpdateQueueFull",
	RemoveAsync = "RemoveQueueFull",
}

local QUEUE_DEPTH = 30

-- How much unspent budget can bank. Roblox documents a startup burst but not its
-- size, so this is a guess with a name on it: one minute's worth. UNCERTAIN.
local MAX_FACTOR = 1

function Budget.new(config)
	return setmetatable({
		Mode = config.Mode or "Trickle",
		QueueDepth = config.QueueDepth or QUEUE_DEPTH,
		_sched = config.Sched,
		-- PlayerCount(jobId) and CCU() are supplied by the universe. Defaulting
		-- them to zero rather than something generous keeps an unwired simulation
		-- visibly starved instead of quietly unlimited.
		_playerCount = config.PlayerCount or function()
			return 0
		end,
		_ccu = config.CCU or function()
			return 0
		end,
		_servers = {}, -- per jobId: { Tokens, Last }
		_experience = { Tokens = {}, Last = {} },
		_queues = { Get = {}, Set = {}, OrderedGet = {}, OrderedSet = {} },
		_pumpScheduled = false,
		Stats = { Queued = 0, Dropped = 0, Stalls = 0, RefusedServer = 0, RefusedExperience = 0 },
	}, Budget)
end

function Budget.Now(self): number
	return self._sched.Now
end

local function poolFor(self, jobId: string)
	local pool = self._servers[jobId]
	if pool == nil then
		pool = { Tokens = {}, Last = {} }
		self._servers[jobId] = pool
	end
	return pool
end

--- Accrue and spend from one pool. Lazy: nothing runs between calls.
---
--- Trickle adds `limit/60` per second, which is smooth and forgiving. Bucket
--- grants the whole minute's allowance at once when the minute rolls over, which
--- is bursty and much harsher right after a rollover. Roblox does not document
--- which it does, so BOTH are implemented and the mode is swept -- a conclusion
--- that holds under one and not the other is a property of this choice, and has
--- to be reported that way rather than as a property of Scribe.
local function take(self, pool, key: string, limit: number, amount: number): boolean
	local now = self:Now()
	local last = pool.Last[key]
	local tokens = pool.Tokens[key]
	if last == nil then
		-- First touch: start full. A server that just booted has its allowance.
		tokens = limit
		last = now
	end

	local accrued
	if self.Mode == "Trickle" then
		accrued = (now - last) * (limit / 60)
	else
		accrued = if math.floor(now / 60) > math.floor(last / 60) then limit else 0
	end

	tokens = math.min(limit * MAX_FACTOR, tokens + accrued)
	pool.Last[key] = now

	if tokens < amount then
		pool.Tokens[key] = tokens
		return false
	end
	pool.Tokens[key] = tokens - amount
	return true
end

--- Try to spend one request on BOTH tiers. All-or-nothing: a request that cannot
--- pay the experience tier must not silently consume the server's allowance.
function Budget.TryTake(self, jobId: string, kind: string): boolean
	local serverLimit = SERVER_LIMITS[kind]
	if serverLimit == nil then
		error(`sim: unknown budget kind "{kind}"`, 0)
	end

	local pool = poolFor(self, jobId)
	local serverBefore = pool.Tokens[kind]
	if not take(self, pool, kind, serverLimit(self._playerCount(jobId)), 1) then
		self.Stats.RefusedServer += 1
		return false
	end

	local tier = EXPERIENCE_TIER[kind]
	if not take(self, self._experience, tier, EXPERIENCE_LIMITS[tier](self._ccu()), 1) then
		-- Refund the server tier. Without this the experience ceiling would
		-- silently drain per-server allowances too, and a queued request would
		-- pay twice for one eventual admission.
		pool.Tokens[kind] = if serverBefore ~= nil then serverBefore else pool.Tokens[kind] + 1
		self.Stats.RefusedExperience += 1
		return false
	end
	return true
end

--- What `kind` has left for `jobId`, WITHOUT spending any of it.
---
--- Exists because the engine exposes exactly this (GetRequestBudgetForRequestType)
--- and Scribe's budget-aware paths read it. Mirrors take()'s accrual rather than
--- reusing it, because take() writes back: a query that quietly advanced the
--- accrual clock would make merely LOOKING at the budget change it.
---
--- An untouched pool reports its FULL allowance, matching take()'s "first touch
--- starts full" rule. Reporting zero there would tell a freshly booted server it
--- had nothing, which is the opposite of true.
function Budget.Peek(self, jobId: string, kind: string): number
	local serverLimit = SERVER_LIMITS[kind]
	if serverLimit == nil then
		error(`sim: unknown budget kind "{kind}"`, 0)
	end
	local limit = serverLimit(self._playerCount(jobId))
	local pool = poolFor(self, jobId)
	local tokens = pool.Tokens[kind]
	if pool.Last[kind] == nil or tokens == nil then
		return limit
	end
	local accrued
	if self.Mode == "Trickle" then
		accrued = (self:Now() - pool.Last[kind]) * (limit / 60)
	else
		accrued = if math.floor(self:Now() / 60) > math.floor(pool.Last[kind] / 60) then limit else 0
	end
	return math.min(limit * MAX_FACTOR, tokens + accrued)
end

--- Admit one request, waiting in a queue if the budget is spent.
---
--- Returns normally when admitted. Raises 301-306 ONLY when the queue is full.
function Budget.Admit(self, jobId: string, kind: string, op: string)
	if self:TryTake(jobId, kind) then
		return
	end

	local queueName = QUEUE_OF[kind]
	local queue = self._queues[queueName]
	if #queue >= self.QueueDepth then
		self.Stats.Dropped += 1
		Errors.Raise(DROP_ERROR[op] or "RequestQueueFull")
	end

	self.Stats.Queued += 1
	self.Stats.Stalls += 1
	local entry = {
		Thread = coroutine.running(),
		JobId = jobId,
		Kind = kind,
		Admitted = false,
	}
	table.insert(queue, entry)
	self:_pump()

	-- Parked on a raw yield: the pump owns when this resumes. Waiting on a timer
	-- instead would mean guessing the wait, and a guess that is too short spins
	-- while one that is too long invents latency the budget did not cause.
	while not entry.Admitted do
		coroutine.yield()
	end
end

--- Serve whatever the budget can currently afford, head-first.
---
--- Runs on arrivals and completions rather than on a thread of its own, for the
--- same reason refill is lazy. When nothing is servable it schedules exactly ONE
--- timer, so the sleeper set stays bounded and Run still terminates.
function Budget._pump(self)
	local servedAny = false

	for _, queue in self._queues do
		local index = 1
		while index <= #queue do
			local entry = queue[index]
			-- Skipped rather than blocked: a request held up by its key's
			-- throughput window must not stall everything behind it, which is what
			-- head-of-line blocking on one hot key would do.
			if self.Skip ~= nil and self:Skip(entry) then
				index += 1
			elseif self:TryTake(entry.JobId, entry.Kind) then
				table.remove(queue, index)
				entry.Admitted = true
				servedAny = true
				self._sched:Resume(entry.Thread)
			else
				-- Budget is spent for this kind; later entries of the same kind
				-- cannot do better, but other queues might.
				break
			end
		end
	end

	local pending = 0
	for _, queue in self._queues do
		pending += #queue
	end
	if pending == 0 or self._pumpScheduled then
		return servedAny
	end

	-- One timer, not one per waiter. A second's granularity is well below the
	-- per-minute accrual the queue is waiting on.
	self._pumpScheduled = true
	self._sched:Delay(1, function()
		self._pumpScheduled = false
		self:_pump()
	end)
	return servedAny
end

--- Call when a request finishes, so its successor can be served promptly.
function Budget.Release(self)
	self:_pump()
end

Budget.SERVER_LIMITS = SERVER_LIMITS
Budget.EXPERIENCE_LIMITS = EXPERIENCE_LIMITS
Budget.QUEUE_DEPTH = QUEUE_DEPTH

return Budget
