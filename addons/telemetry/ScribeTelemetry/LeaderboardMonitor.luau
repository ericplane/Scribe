--!strict
-- Polls cached board status; never refreshes a leaderboard.

local Monitor = {}
Monitor.__index = Monitor

export type Entry = {
	BundleId: number,
	Name: string,
	Status: "Starting" | "Healthy" | "Degraded",
	PendingWrites: number,
	RetryingWrites: number,
	RejectedWrites: number,
	ReadAge: number?,
	LastReadError: string?,
	LastWriteError: string?,
}

local function nonnegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function copyEntry(value: any): Entry?
	if
		type(value) ~= "table"
		or not nonnegative(value.BundleId)
		or value.BundleId < 1
		or value.BundleId % 1 ~= 0
		or type(value.Name) ~= "string"
		or value.Name == ""
		or not table.find({ "Starting", "Healthy", "Degraded" }, value.Status)
	then
		return nil
	end
	for _, name in { "PendingWrites", "RetryingWrites", "RejectedWrites" } do
		if not nonnegative(value[name]) then
			return nil
		end
	end
	if value.ReadAge ~= nil and not nonnegative(value.ReadAge) then
		return nil
	end
	return {
		BundleId = value.BundleId,
		Name = value.Name,
		Status = value.Status,
		PendingWrites = value.PendingWrites,
		RetryingWrites = value.RetryingWrites,
		RejectedWrites = value.RejectedWrites,
		ReadAge = value.ReadAge,
		LastReadError = if type(value.LastReadError) == "string" then value.LastReadError else nil,
		LastWriteError = if type(value.LastWriteError) == "string" then value.LastWriteError else nil,
	}
end

function Monitor.new(scribe: any, config: any, clock: () -> number, report: (Entry, string?, number?) -> ())
	return setmetatable({
		scribe = scribe,
		config = config,
		clock = clock,
		report = report,
		Due = 0,
		Stopped = false,
		State = if config.LeaderboardsEnabled then "Unavailable" else "Disabled",
		Entries = {} :: { Entry },
		States = {} :: { [string]: { Status: string, Since: number, DegradedSince: number? } },
		Omitted = 0,
		ObservedAt = nil :: number?,
		LastError = nil :: string?,
	}, Monitor)
end

function Monitor.Poll(self: any)
	if self.Stopped or not self.config.LeaderboardsEnabled then
		return
	end
	local now = self.clock()
	self.Due = now + self.config.LeaderboardInterval
	local getter = self.scribe.GetLeaderboardSnapshot
	if type(getter) ~= "function" then
		self.State, self.LastError = "Unavailable", "this Scribe version has no leaderboard snapshot API"
		return
	end
	local ok, snapshot = pcall(getter)
	if self.Stopped then
		return
	end
	if not ok or type(snapshot) ~= "table" then
		self.State, self.LastError = "Unavailable", "leaderboard snapshot could not be read"
		return
	end
	local entries: { Entry } = {}
	local seen = {}
	for i = 1, math.min(#snapshot, self.config.MaxBoards) do
		local entry = copyEntry(snapshot[i])
		local key = if entry then `{entry.BundleId}:{entry.Name}` else ""
		if entry == nil or seen[key] then
			self.State, self.LastError = "Unavailable", "leaderboard snapshot contained an invalid or duplicate board"
			return
		end
		seen[key] = true
		table.insert(entries, entry)
	end
	local states = {}
	for _, entry in entries do
		local key = `{entry.BundleId}:{entry.Name}`
		local previous = self.States[key]
		local degradedSince = previous and previous.DegradedSince
		if entry.Status == "Degraded" and degradedSince == nil then
			self.report(entry, previous and previous.Status, previous and now - previous.Since)
			degradedSince = now
		elseif entry.Status == "Healthy" and degradedSince ~= nil then
			self.report(entry, "Degraded", now - degradedSince)
			degradedSince = nil
		end
		if self.Stopped then
			return
		end
		states[key] = {
			Status = entry.Status,
			Since = if previous and previous.Status == entry.Status then previous.Since else now,
			DegradedSince = degradedSince,
		}
	end
	self.States = states
	self.Entries = entries
	self.Omitted = math.max(0, #snapshot - #entries)
	self.ObservedAt = now
	self.State, self.LastError = "Available", nil
end

function Monitor.Tick(self: any)
	if self.config.LeaderboardsEnabled and self.clock() >= self.Due then
		self:Poll()
	end
end

function Monitor.Stop(self: any)
	self.State = "Stopped"
	self.Stopped = true
	self.report = function() end
	table.clear(self.States)
	table.clear(self.Entries)
end

return Monitor
