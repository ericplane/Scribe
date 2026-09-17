--!strict
-- Groups repeated reports: the first goes out at once, later ones fold into one
-- follow-up per interval, and the group set stays bounded.

local Router = {}
Router.__index = Router

export type Record = {
	Category: string,
	Kind: string,
	Severity: string,
	Code: string,
	LogCategory: string,
	Subject: string?,
	Message: string,
	Context: { [string]: any }?,
	Repeats: number, -- upstream suppression the entry itself reported
	At: number,
}

export type Group = {
	Key: string,
	Sample: Record,
	FirstAt: number,
	LatestAt: number,
	Count: number, -- occurrences observed by the add-on since the group opened
	WindowCount: number, -- since the last follow-up
	Upstream: number, -- upstream repeats reported since the last follow-up
	SummaryDue: number?,
	LastSeen: number,
	Touched: number, -- offer sequence at the last occurrence; breaks ties in LastSeen
}

export type Callbacks = {
	First: (record: Record) -> (),
	Summary: (group: Group) -> (),
}

function Router.new(interval: number, expiry: number, maxGroups: number, monotonic: () -> number, callbacks: Callbacks)
	local self = setmetatable({}, Router)
	self.interval = interval
	self.expiry = expiry
	self.maxGroups = maxGroups
	self.monotonic = monotonic
	self.callbacks = callbacks
	self.groups = {} :: { [string]: Group }
	self.count = 0
	self.evicted = 0
	self.offers = 0
	return self
end

function Router.Key(record: Record): string
	return `{record.Category}|{record.Code}|{record.LogCategory}|{record.Subject or ""}`
end

local function summarise(self: any, group: Group)
	if group.WindowCount > 0 then
		self.callbacks.Summary(group)
		group.WindowCount = 0
		group.Upstream = 0
	end
	group.SummaryDue = nil
end

local function remove(self: any, key: string)
	if self.groups[key] ~= nil then
		self.groups[key] = nil
		self.count -= 1
	end
end

-- Least recently seen first, ties by offer sequence rather than hash order; its
-- follow-up goes out before it is dropped.
local function evictOne(self: any)
	local oldestKey: string? = nil
	local oldest = math.huge
	for key, group in self.groups do
		if group.Touched < oldest then
			oldest, oldestKey = group.Touched, key
		end
	end
	if oldestKey ~= nil then
		summarise(self, self.groups[oldestKey])
		remove(self, oldestKey)
		self.evicted += 1
	end
end

--- Offers a record. The first of its kind is reported now; a repetition waits for the
--- group's follow-up.
function Router.Offer(self: any, record: Record)
	local key = Router.Key(record)
	local now = self.monotonic()
	self.offers += 1
	local group: Group? = self.groups[key]
	if group ~= nil and now - group.LastSeen > self.expiry then
		summarise(self, group)
		remove(self, key)
		group = nil
	end
	if group == nil then
		if self.count >= self.maxGroups then
			evictOne(self)
		end
		group = {
			Key = key,
			Sample = record,
			FirstAt = record.At,
			LatestAt = record.At,
			Count = 1,
			WindowCount = 0,
			Upstream = 0,
			SummaryDue = now + self.interval,
			LastSeen = now,
			Touched = self.offers,
		}
		self.groups[key] = group
		self.count += 1
		self.callbacks.First(record)
		return
	end
	group.Count += 1
	group.WindowCount += 1
	group.LatestAt = record.At
	group.Upstream += record.Repeats
	group.LastSeen = now
	group.Touched = self.offers
	if group.SummaryDue == nil then
		group.SummaryDue = now + self.interval
	end
end

--- Sends the follow-ups whose interval has passed and forgets groups gone quiet.
function Router.Tick(self: any)
	local now = self.monotonic()
	for key, group in self.groups do
		if group.SummaryDue ~= nil and group.SummaryDue <= now then
			summarise(self, group)
		end
		if group.SummaryDue == nil and now - group.LastSeen > self.expiry then
			remove(self, key)
		end
	end
end

function Router.Clear(self: any)
	table.clear(self.groups)
	self.count = 0
end

return Router
