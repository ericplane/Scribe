--!strict
-- DataStore request budgets: what the engine says is left, whether a deferrable
-- background request should wait, and a FIFO queue for callers willing to wait.

local Clock = require(script.Parent.Clock)
local Sched = require(script.Parent.Sched)
local Metrics = require(script.Parent.Metrics)
local Defaults = require(script.Parent.Defaults)

local Budget = {}

-- The request types Scribe's own traffic spends. Saves ride UpdateAsync;
-- leaderboards ride the two Sorted pools, which are a separate allowance, so
-- gating a leaderboard write can never starve a save.
local REQUEST_TYPES = { "GetAsync", "SetIncrementAsync", "UpdateAsync", "GetSortedAsync", "SetIncrementSortedAsync" }

export type Snapshot = {
	Available: boolean, -- false when the engine could not be asked at all
	Reason: string?, -- why not, when Available is false
	Budgets: { [string]: number }, -- remaining requests, by DataStoreRequestType name
	At: number,
}

-- Resolved per call, never stored. A cached handle latches whatever one unlucky
-- pcall caught, a module-load `game:GetService` cannot be retried, and a simulated
-- server without a disk has no DataStoreService at all, so a stored handle would
-- take the whole bundle down at require time.
local function service(): (any?, string?)
	local ok, resolved = pcall(function()
		return game:GetService("DataStoreService")
	end)
	if not ok or resolved == nil then
		return nil, "DataStoreService is unavailable"
	end
	return resolved, nil
end

-- Test seam: a spec drives the pump against a budget it controls. nil restores the
-- engine, and Reset clears it.
local probe: ((requestType: string) -> number?)? = nil

function Budget.SetProbe(fn: ((requestType: string) -> number?)?)
	probe = fn
end

--- Requests left for one type, or nil when the engine cannot answer. nil and 0 are
--- different: 0 means the allowance is spent, nil means the question could not be
--- asked, and a gate that reads nil as 0 stalls forever in a headless or
--- API-disabled environment.
function Budget.Remaining(requestType: string): number?
	if probe ~= nil then
		return probe(requestType)
	end
	local handle = service()
	if handle == nil then
		return nil
	end
	local ok, value = pcall(function()
		return handle:GetRequestBudgetForRequestType((Enum :: any).DataStoreRequestType[requestType])
	end)
	if not ok or type(value) ~= "number" or value ~= value then
		return nil
	end
	return value
end

--- Everything Budget.Remaining can answer, in one record.
function Budget.Snapshot(): Snapshot
	local handle, reason = service()
	if handle == nil then
		return { Available = false, Reason = reason, Budgets = {}, At = Clock.Now() }
	end
	local budgets: { [string]: number } = {}
	local answered = 0
	for _, requestType in REQUEST_TYPES do
		local value = Budget.Remaining(requestType)
		if value ~= nil then
			budgets[requestType] = value
			answered += 1
		end
	end
	if answered == 0 then
		-- The service exists but answers nothing (Studio with API access off, or a
		-- stub): a table of zeroes would read as a real exhausted allowance.
		return {
			Available = false,
			Reason = "DataStoreService did not answer any request type",
			Budgets = {},
			At = Clock.Now(),
		}
	end
	return { Available = true, Reason = nil, Budgets = budgets, At = Clock.Now() }
end

-- Pacing ----------------------------------------------------------------------
--
-- For a caller that may spend many requests for one player (ImportLegacyData). Without
-- a queue, N joiners poll independently and all fire the moment the allowance frees.
-- Only the head is ever considered, so FIFO is structural. One queue PER REQUEST TYPE:
-- the pools are separate allowances, so an exhausted one must not block another.

local POLL_INTERVAL = 1
-- Backstop for callers that never release. Over-counting delays, under-counting brings
-- the herd back, so it errs high; the exact value stops mattering once callers release.
local GRANT_TTL = 4

-- Stands in when nothing was granted, so a caller can release unconditionally.
local function noRelease() end

type Waiter = {
	Thread: thread,
	Count: number,
	Deadline: number,
	EnqueuedAt: number,
	-- A predicate, not a flag: the caller is suspended inside Await with nowhere to set
	-- one from.
	ShouldCancel: (() -> boolean)?,
	OnState: ((waiting: boolean) -> ())?,
	-- Read by Await when the pump settled it on the calling stack, before it yielded.
	Result: boolean?,
	-- Set by the pump when it granted, so Await can hand the release to its caller.
	Release: (() -> ())?,
}

local queues: { [string]: { Waiter } } = {}
local pumping: { [string]: boolean } = {}
-- Granted but presumed unspent. Budget.Remaining reads the ENGINE, which has not moved
-- between a grant and that caller issuing its request, so granting the next one off the
-- same reading over-grants.
local outstanding: { [string]: { { Count: number, At: number } } } = {}
-- Held back from pacing callers, sized by the server.
local reserves: { [string]: number } = {}

--- Sum of grants still inside GRANT_TTL, pruning the rest.
local function outstandingFor(requestType: string): number
	local held = outstanding[requestType]
	if held == nil then
		return 0
	end
	local now = Clock.Monotonic()
	local total, keep = 0, 1
	for i = 1, #held do
		local entry = held[i]
		if now - entry.At < GRANT_TTL then
			held[keep] = entry
			keep += 1
			total += entry.Count
		end
	end
	for i = #held, keep, -1 do
		held[i] = nil
	end
	return total
end

--- Records a grant and returns its release. By identity: outstandingFor compacts the
--- list in place, so a position taken now means nothing later.
local function debit(requestType: string, count: number): () -> ()
	local held = outstanding[requestType]
	if held == nil then
		held = {}
		outstanding[requestType] = held
	end
	local entry = { Count = count, At = Clock.Monotonic() }
	table.insert(held, entry)
	local released = false
	return function()
		-- Repeat calls are no-ops.
		if released then
			return
		end
		released = true
		local current = outstanding[requestType]
		local index = if current ~= nil then table.find(current, entry) else nil
		if current ~= nil and index ~= nil then
			table.remove(current, index)
		end
	end
end

--- What a pacing caller may take now, or nil when the engine cannot be asked. nil and
--- 0 differ: reading nil as 0 parks the caller forever in a headless server.
local function spare(requestType: string): number?
	local remaining = Budget.Remaining(requestType)
	if remaining == nil then
		return nil
	end
	return remaining - outstandingFor(requestType) - (reserves[requestType] or 0)
end

--- Remove the head, record the outcome, then resume it.
local function waiting(): number
	local total = 0
	for _, queue in queues do
		total += #queue
	end
	return total
end

local function settle(queue: { Waiter }, head: Waiter, result: boolean)
	table.remove(queue, 1)
	Metrics.Set("BudgetWaiters", waiting())
	Metrics.Observe("BudgetWaitSeconds", Clock.Monotonic() - head.EnqueuedAt)
	Metrics.Add(if result then "BudgetGranted" else "BudgetTimedOut")
	head.Result = result
	if head.OnState then
		head.OnState(false)
	end
	-- Spawn is immediate, so the pump can run on the waiter's own stack before it has
	-- yielded. That waiter reads Result; resuming it here raises.
	if coroutine.status(head.Thread) == "suspended" then
		Sched.Resume(head.Thread, result)
	end
end

--- One pump per queue, never a thread per waiter. Only the head is examined, so a
--- caller cannot be overtaken however small the request behind it.
local function pump(requestType: string)
	local queue = queues[requestType]
	while queue ~= nil and #queue > 0 do
		local head = queue[1]
		local cancelled = head.ShouldCancel ~= nil and head.ShouldCancel()
		if cancelled or Clock.Monotonic() >= head.Deadline then
			-- False, and WITHOUT a debit: a caller going away must unwind rather than park
			-- inside a hook still holding its session, and its allowance goes to the next.
			settle(queue, head, false)
		else
			local available = spare(requestType)
			-- nil grants: the engine will never answer, so parking is forever.
			if available == nil or available >= head.Count then
				head.Release = debit(requestType, head.Count)
				settle(queue, head, true)
			else
				Clock.Wait(POLL_INTERVAL)
			end
		end
	end
	pumping[requestType] = false
end

--- Hold `count` requests of this type back from pacing callers.
function Budget.SetReserve(requestType: string, count: number)
	reserves[requestType] = math.max(0, count)
end

--- Yield until `count` requests are spare, or `timeout` passes. `onState(waiting)`
--- reports entering and leaving the queue, which is what surfaces a throttled caller.
function Budget.Await(
	requestType: string,
	count: number?,
	timeout: number?,
	onState: ((waiting: boolean) -> ())?,
	shouldCancel: (() -> boolean)?
): (boolean, () -> ())
	local want = math.max(1, count or 1)
	local queue = queues[requestType]
	-- Only with nobody queued: behind a queue it would let a late caller jump everyone.
	if queue == nil or #queue == 0 then
		local available = spare(requestType)
		if available == nil or available >= want then
			Metrics.Add("BudgetGranted")
			return true, debit(requestType, want)
		end
	end

	if queue == nil then
		queue = {}
		queues[requestType] = queue
	end
	local waiter: Waiter = {
		Thread = coroutine.running(),
		Count = want,
		Deadline = Clock.Monotonic() + (timeout or Defaults.AwaitBudget),
		EnqueuedAt = Clock.Monotonic(),
		ShouldCancel = shouldCancel,
		OnState = onState,
		Result = nil,
	}
	table.insert(queue, waiter)
	Metrics.Add("BudgetQueued")
	Metrics.Set("BudgetWaiters", waiting())
	if onState then
		onState(true)
	end
	if not pumping[requestType] then
		pumping[requestType] = true
		Sched.Spawn(pump, requestType)
	end
	-- A pump that settled this waiter on its first pass ran on this stack, so yielding
	-- now would never return. Read the outcome: a zero timeout settles false there.
	if waiter.Result ~= nil then
		return waiter.Result, waiter.Release or noRelease
	end
	local granted = coroutine.yield()
	return granted, waiter.Release or noRelease
end

--- Module-global, because the allowance is per process rather than per bundle, so a
--- test that paces has to reset.
function Budget.Reset()
	queues = {}
	pumping = {}
	outstanding = {}
	reserves = {}
	Budget.SetProbe(nil)
end

Budget.REQUEST_TYPES = REQUEST_TYPES

return Budget
