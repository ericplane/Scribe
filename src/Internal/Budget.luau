--!strict
-- DataStore request budgets: what the engine says is left, and whether a deferrable
-- background request should wait for more. Read-only and inert unless asked for; the
-- two leaderboard loops are the only callers that act on it, and only when
-- BudgetPolicy says so.

local Clock = require(script.Parent.Clock)

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

--- Requests left for one type, or nil when the engine cannot answer. nil and 0 are
--- different: 0 means the allowance is spent, nil means the question could not be
--- asked, and a gate that reads nil as 0 stalls forever in a headless or
--- API-disabled environment.
function Budget.Remaining(requestType: string): number?
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

Budget.REQUEST_TYPES = REQUEST_TYPES

return Budget
