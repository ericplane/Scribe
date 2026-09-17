--!strict
-- Bounded asynchronous delivery: one lane per webhook URL and one worker per lane, so
-- a throttled or dead webhook never holds up another.

local Sanitize = require(script.Parent.Sanitize)

local Transport = {}
Transport.__index = Transport

export type Response = {
	Ok: boolean,
	Status: number?,
	Headers: { [string]: string }?,
	Body: string?,
	Error: string?,
}

export type Http = { Post: (url: string, body: string) -> Response }
export type Clock = { Now: () -> number, Monotonic: () -> number }
export type Scheduler = { Spawn: (fn: () -> ()) -> (), Wait: (seconds: number) -> () }
export type Json = { Encode: (value: any) -> string, Decode: (text: string) -> any }

export type Deps = {
	Http: Http,
	Clock: Clock,
	Scheduler: Scheduler,
	Json: Json,
	Jitter: () -> number, -- in [0, 1)
}

export type Dropped = {
	Overflow: number,
	Expired: number,
	Malformed: number,
	DeadDestination: number,
	Exhausted: number,
	Stopped: number,
	Coalesced: number,
}

function Transport.EmptyDropped(): Dropped
	return {
		Overflow = 0,
		Expired = 0,
		Malformed = 0,
		DeadDestination = 0,
		Exhausted = 0,
		Stopped = 0,
		Coalesced = 0,
	}
end

export type Stats = {
	Queued: number,
	QueuedBytes: number,
	Delivered: number,
	Retries: number,
	Uncertain: number,
	Dropped: Dropped,
	LastDeliveredAt: number?,
	Destinations: { [string]: DestinationStats },
}

export type Limits = {
	MaxQueued: number,
	MaxQueuedBytes: number,
	PerDestinationQueued: number,
	MaxAge: number,
	MaxAttempts: number,
	MaxRetryDelay: number,
}

type Item = {
	Id: string,
	Destination: string,
	Category: string,
	GroupKey: string?,
	Priority: number,
	Payload: string,
	Bytes: number,
	CreatedAt: number,
	ExpiresAt: number,
	NotBefore: number,
	Attempts: number,
	InFlight: boolean,
}

type Lane = {
	Url: string,
	Queue: { Item },
	Bytes: number,
	NotBefore: number, -- rate-limit pacing, monotonic
	Dead: boolean,
	Working: boolean,
}

export type DestinationStats = {
	State: string, -- Ready, Dead, Stopped
	Queued: number,
	Delivered: number,
	Failures: number,
	LastDeliveredAt: number?,
	LastError: string?,
}

local DEAD_STATUSES = { [401] = true, [403] = true, [404] = true, [410] = true }
local MALFORMED_STATUSES = { [400] = true, [413] = true, [422] = true }

local function header(headers: { [string]: string }?, name: string): string?
	if headers == nil then
		return nil
	end
	local lower = string.lower(name)
	for key, value in headers do
		if string.lower(key) == lower then
			return value
		end
	end
	return nil
end

function Transport.new(limits: Limits, deps: Deps)
	local self = setmetatable({}, Transport)
	self.limits = limits
	self.deps = deps
	self.running = true
	self.lanes = {} :: { [string]: Lane }
	self.destinationLane = {} :: { [string]: string }
	self.destinations = {} :: { [string]: DestinationStats }
	self.queued = 0
	self.queuedBytes = 0
	self.stats = {
		Delivered = 0,
		Retries = 0,
		Uncertain = 0,
		Dropped = Transport.EmptyDropped(),
		LastDeliveredAt = nil :: number?,
	}
	return self
end

--- Declares a destination. Two names on one URL share a lane.
function Transport.AddDestination(self: any, name: string, url: string)
	self.destinationLane[name] = url
	if self.lanes[url] == nil then
		self.lanes[url] = { Url = url, Queue = {}, Bytes = 0, NotBefore = 0, Dead = false, Working = false }
	end
	self.destinations[name] =
		{ State = "Ready", Queued = 0, Delivered = 0, Failures = 0, LastDeliveredAt = nil, LastError = nil }
end

local function take(self: any, lane: Lane, index: number): Item
	local item = table.remove(lane.Queue, index) :: Item
	lane.Bytes -= item.Bytes
	self.queued -= 1
	self.queuedBytes -= item.Bytes
	self.destinations[item.Destination].Queued -= 1
	return item
end

local function dropItem(self: any, lane: Lane, index: number, reason: string)
	take(self, lane, index)
	self.stats.Dropped[reason] += 1
end

-- Short, and carrying no URL, so an echoed body or error is safe in LastError.
local function shortBody(body: string?): string
	local text = if body then string.gsub(body, "%c", " ") else ""
	text = string.gsub(text, "https?://%S+", "[url]")
	return Sanitize.Truncate(text, 160)
end

-- Expired first, then the lowest priority no higher than `floor`, oldest among equals;
-- never the item in flight. Asked at most once per Enqueue, so it needs no plan.
local function victim(lane: Lane, now: number, floor: number): Item?
	local best: Item? = nil
	for _, item in lane.Queue do
		if item.InFlight then
			continue
		end
		if item.ExpiresAt <= now then
			return item
		end
		if item.Priority <= floor and (best == nil or item.Priority < best.Priority) then
			best = item
		end
	end
	return best
end

-- Across every lane, oldest among equals: for a limit every lane shares.
local function globalVictim(self: any, now: number, floor: number, planned: { [Item]: boolean }): (Lane?, Item?)
	local bestLane: Lane? = nil
	local best: Item? = nil
	for _, lane in self.lanes do
		for _, item in lane.Queue do
			if item.InFlight or planned[item] then
				continue
			end
			if item.ExpiresAt <= now then
				return lane, item
			end
			if item.Priority > floor then
				continue
			end
			if
				best == nil
				or item.Priority < best.Priority
				or (item.Priority == best.Priority and item.CreatedAt < best.CreatedAt)
			then
				bestLane, best = lane, item
			end
		end
	end
	return bestLane, best
end

--- Queues `payload` for `destination`. Returns false with a reason when it was refused.
function Transport.Enqueue(
	self: any,
	destination: string,
	id: string,
	category: string,
	groupKey: string?,
	priority: number,
	payload: string
): (boolean, string?)
	if not self.running then
		return false, "stopped"
	end
	local url = self.destinationLane[destination]
	local lane: Lane? = if url then self.lanes[url] else nil
	if lane == nil then
		return false, "unknown-destination"
	end
	if lane.Dead then
		self.stats.Dropped.DeadDestination += 1
		return false, "dead-destination"
	end
	local now = self.deps.Clock.Monotonic()
	local bytes = #payload
	-- A repetition summary supersedes the one still waiting for the same group.
	if groupKey ~= nil then
		for _, queued in lane.Queue do
			if queued.GroupKey == groupKey and not queued.InFlight then
				if self.queuedBytes + bytes - queued.Bytes > self.limits.MaxQueuedBytes then
					self.stats.Dropped.Overflow += 1
					return false, "overflow"
				end
				lane.Bytes += bytes - queued.Bytes
				self.queuedBytes += bytes - queued.Bytes
				queued.Payload = payload
				queued.Bytes = bytes
				queued.Id = id
				queued.CreatedAt = now
				queued.ExpiresAt = now + self.limits.MaxAge
				self.stats.Dropped.Coalesced += 1
				return true, nil
			end
		end
	end
	-- Planned first, so a report no eviction could admit leaves the queue untouched. A full
	-- lane gives up one of its own; a shared limit takes the lowest priority anywhere.
	local planned: { [Item]: boolean } = {}
	local plan: { { Lane: Lane, Item: Item } } = {}
	local laneCount, count, queuedBytes = #lane.Queue, self.queued, self.queuedBytes
	while
		laneCount >= self.limits.PerDestinationQueued
		or count >= self.limits.MaxQueued
		or queuedBytes + bytes > self.limits.MaxQueuedBytes
	do
		local target: Lane? = lane
		local item: Item? = nil
		if laneCount >= self.limits.PerDestinationQueued then
			item = victim(lane, now, priority)
		else
			target, item = globalVictim(self, now, priority, planned)
		end
		if target == nil or item == nil then
			self.stats.Dropped.Overflow += 1
			return false, "overflow"
		end
		local chosenLane, chosen = target :: Lane, item :: Item
		planned[chosen] = true
		table.insert(plan, { Lane = chosenLane, Item = chosen })
		count -= 1
		queuedBytes -= chosen.Bytes
		if chosenLane == lane then
			laneCount -= 1
		end
	end
	for _, entry in plan do
		local index = table.find(entry.Lane.Queue, entry.Item)
		if index ~= nil then
			dropItem(self, entry.Lane, index, "Overflow")
		end
	end
	table.insert(lane.Queue, {
		Id = id,
		Destination = destination,
		Category = category,
		GroupKey = groupKey,
		Priority = priority,
		Payload = payload,
		Bytes = bytes,
		CreatedAt = now,
		ExpiresAt = now + self.limits.MaxAge,
		NotBefore = 0,
		Attempts = 0,
		InFlight = false,
	})
	lane.Bytes += bytes
	self.queued += 1
	self.queuedBytes += bytes
	self.destinations[destination].Queued += 1
	self:startWorker(lane)
	return true, nil
end

-- A zero would post again without yielding.
local RETRY_AFTER_MIN = 1

local function retryAfterSeconds(self: any, response: Response): number
	local body = response.Body
	local delay: number? = nil
	if body ~= nil and body ~= "" then
		local ok, decoded = pcall(self.deps.Json.Decode, body)
		if ok and type(decoded) == "table" and type(decoded.retry_after) == "number" then
			delay = decoded.retry_after
		end
	end
	if delay == nil then
		delay = tonumber(header(response.Headers, "Retry-After") or header(response.Headers, "X-RateLimit-Reset-After"))
	end
	return math.max(RETRY_AFTER_MIN, delay or 5)
end

local function markDead(self: any, lane: Lane, err: string)
	lane.Dead = true
	for name, url in self.destinationLane do
		if url == lane.Url then
			local stats = self.destinations[name]
			stats.State = "Dead"
			stats.LastError = err
		end
	end
	while #lane.Queue > 0 do
		dropItem(self, lane, 1, "DeadDestination")
	end
end

function Transport.startWorker(self: any, lane: Lane)
	if lane.Working then
		return
	end
	lane.Working = true
	self.deps.Scheduler.Spawn(function()
		self:work(lane)
		lane.Working = false
	end)
end

function Transport.work(self: any, lane: Lane)
	local limits: Limits = self.limits
	while self.running and not lane.Dead do
		local item: Item? = lane.Queue[1]
		if item == nil then
			return
		end
		local now = self.deps.Clock.Monotonic()
		if item.ExpiresAt <= now then
			dropItem(self, lane, 1, "Expired")
			continue
		end
		local notBefore = math.max(lane.NotBefore, item.NotBefore)
		if notBefore > now then
			if notBefore >= item.ExpiresAt then
				dropItem(self, lane, 1, "Expired")
				continue
			end
			self.deps.Scheduler.Wait(notBefore - now)
			continue
		end

		local stats: DestinationStats = self.destinations[item.Destination]
		item.InFlight = true
		local ok, response = pcall(self.deps.Http.Post, lane.Url, item.Payload)
		item.InFlight = false
		if not self.running then
			return
		end
		local res: Response = if ok then response else { Ok = false, Error = tostring(response) }
		now = self.deps.Clock.Monotonic()
		-- Still the head: evictions skip it and enqueues append.
		local index = 1

		if res.Ok and res.Status ~= nil and res.Status >= 200 and res.Status < 300 then
			take(self, lane, index)
			self.stats.Delivered += 1
			self.stats.LastDeliveredAt = self.deps.Clock.Now()
			stats.Delivered += 1
			stats.Failures = 0
			stats.LastDeliveredAt = self.stats.LastDeliveredAt
			stats.State = "Ready"
			if header(res.Headers, "X-RateLimit-Remaining") == "0" then
				lane.NotBefore = now + (tonumber(header(res.Headers, "X-RateLimit-Reset-After")) or 1)
			end
			continue
		end

		local status = res.Status
		if status == 429 then
			local delay = retryAfterSeconds(self, res)
			lane.NotBefore = now + delay
			self.stats.Retries += 1
			continue
		end
		if status ~= nil and DEAD_STATUSES[status] then
			local reason = `webhook refused with HTTP {status}`
			if status == 403 and string.match(lane.Url, "^https://[%w%.%-]*discord%.com/") then
				reason ..= "; Discord refuses requests from Roblox servers, so route the webhook through a proxy"
			end
			markDead(self, lane, reason)
			return
		end
		if status ~= nil and MALFORMED_STATUSES[status] then
			stats.LastError = `HTTP {status}: {shortBody(res.Body)}`
			dropItem(self, lane, index, "Malformed")
			continue
		end

		-- Transient; a timeout may have landed, hence Uncertain.
		if res.Error ~= nil and string.find(string.lower(res.Error), "time", 1, true) then
			self.stats.Uncertain += 1
		end
		stats.Failures += 1
		stats.LastError = if status then `HTTP {status}` else shortBody(tostring(res.Error or "request failed"))
		item.Attempts += 1
		if item.Attempts >= limits.MaxAttempts then
			dropItem(self, lane, index, "Exhausted")
			continue
		end
		local backoff = math.min(limits.MaxRetryDelay, 2 ^ (item.Attempts - 1)) * (0.5 + self.deps.Jitter())
		item.NotBefore = now + backoff
		self.stats.Retries += 1
		if item.NotBefore >= item.ExpiresAt then
			dropItem(self, lane, index, "Expired")
		end
	end
end

--- Waits until every lane is empty, or `timeout` seconds. Returns whether it drained.
function Transport.Flush(self: any, timeout: number): boolean
	local deadline = self.deps.Clock.Monotonic() + timeout
	while self.running and self.queued > 0 do
		if self.deps.Clock.Monotonic() >= deadline then
			return false
		end
		self.deps.Scheduler.Wait(0.05)
	end
	return self.queued == 0
end

--- Stops delivery. Queued items are released; a request already in flight may complete,
--- but its result starts nothing.
function Transport.Stop(self: any)
	if not self.running then
		return
	end
	self.running = false
	for _, lane in self.lanes do
		while #lane.Queue > 0 do
			dropItem(self, lane, 1, "Stopped")
		end
	end
	for _, stats in self.destinations do
		stats.State = "Stopped"
	end
end

function Transport.Stats(self: any): Stats
	local destinations = {}
	for name, stats in self.destinations do
		destinations[name] = table.clone(stats)
	end
	return {
		Queued = self.queued,
		QueuedBytes = self.queuedBytes,
		Delivered = self.stats.Delivered,
		Retries = self.stats.Retries,
		Uncertain = self.stats.Uncertain,
		Dropped = table.clone(self.stats.Dropped),
		LastDeliveredAt = self.stats.LastDeliveredAt,
		Destinations = destinations,
	}
end

return Transport
