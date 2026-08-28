--!strict
-- Structured logger. Library-level singleton.
-- Every entry: { At, Level, Category, Code, Message, Context }.

local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Util = require(script.Parent.Util)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Parent.Types)
local Clock = require(script.Parent.Clock)
local Sched = require(script.Parent.Sched)

type LogEntry = Types.LogEntry

-- Entries retained for Log.GetRecent; the bundle option LogRingSize raises it for
-- runs long enough that 512 truncates the interesting part.
local DEFAULT_RING_SIZE = 512
local ringSize = DEFAULT_RING_SIZE
local MAX_STRUCTURED_CONTEXT_BYTES = 1000 -- keep structured-log context under ~1 KiB

local LEVEL_ORDER: { [string]: number } = {
	Debug = 1,
	Info = 2,
	Warn = 3,
	Error = 4,
	Fatal = 5,
}

local Log = {}

Log.OnIssue = Signal.new() :: Signal.Signal<Types.LogEntry> -- fires (entry) for every Error/Fatal entry

local minLevel = if RunService:IsStudio() then LEVEL_ORDER.Debug else LEVEL_ORDER.Warn
local ring: { LogEntry } = table.create(ringSize) :: any
local ringNext = 1
local ringCount = 0
local sinks: { (entry: LogEntry) -> () } = {}

-- LogService structured logging, feature-detected with a print/warn fallback.
local structuredAvailable = pcall(function()
	return typeof((LogService :: any).Output) == "function"
end) and typeof((LogService :: any).Output) == "function"

local function trimContext(context: { [string]: any }?): { [string]: any }?
	if context == nil then
		return nil
	end
	local sanitized = Util.sanitizeContext(context)
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, sanitized)
	if ok and #encoded <= MAX_STRUCTURED_CONTEXT_BYTES then
		return sanitized
	end
	-- Too large for the cloud pipeline: keep only shallow scalar fields.
	local slim = {}
	if type(sanitized) == "table" then
		for k, v in sanitized do
			local vt = type(v)
			if vt == "string" or vt == "number" or vt == "boolean" then
				slim[k] = v
			end
		end
	end
	slim._trimmed = true
	return slim
end

local function defaultSink(entry: LogEntry)
	-- Stable template per code, never the message: Creator Analytics aggregates by
	-- template, and a caller-supplied string would mint unbounded cardinality.
	local template = `Scribe {entry.Code}`
	if structuredAvailable then
		local context: { [string]: any } = trimContext(entry.Context) or {}
		context.code = entry.Code
		context.category = entry.Category
		context.message = entry.Message
		local ok = pcall(function()
			local ls = LogService :: any
			if entry.Level == "Debug" then
				ls:Output(template, context)
			elseif entry.Level == "Info" then
				ls:Info(template, context)
			elseif entry.Level == "Warn" then
				ls:Warn(template, context)
			else
				ls:Error(template, context)
			end
		end)
		if ok then
			return
		end
	end
	local suffix = ""
	if entry.Context then
		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, Util.sanitizeContext(entry.Context))
		if ok then
			suffix = " " .. encoded
		end
	end
	if LEVEL_ORDER[entry.Level] >= LEVEL_ORDER.Warn then
		warn(`[Scribe][{entry.Category}][{entry.Code}] {entry.Message}{suffix}`)
	else
		print(`[Scribe][{entry.Category}][{entry.Code}] {entry.Message}{suffix}`)
	end
end

local MAX_MESSAGE_LEN = 400

local function emit(
	level: Types.LogLevel,
	category: Types.LogCategory,
	code: Types.LogCode,
	message: string,
	context: { [string]: any }?
)
	-- Capped so a client-supplied string or a long traceback cannot bloat the ring
	-- buffer, the console fallback, or the structured context.
	if #message > MAX_MESSAGE_LEN then
		message = string.sub(message, 1, MAX_MESSAGE_LEN) .. "…"
	end
	local entry: LogEntry = {
		At = Clock.Now(),
		Level = level,
		Category = category,
		Code = code,
		Message = message,
		Context = context,
	}

	-- Ring buffer always records the full, untrimmed entry.
	ring[ringNext] = entry
	ringNext = (ringNext % ringSize) + 1
	ringCount = math.min(ringCount + 1, ringSize)

	if LEVEL_ORDER[level] >= minLevel then
		defaultSink(entry)
	end

	for _, sink in sinks do
		Sched.Spawn(function()
			local ok, err = pcall(sink :: any, entry)
			if not ok then
				warn(`[Scribe] log sink error: {err}`)
			end
		end)
	end

	if LEVEL_ORDER[level] >= LEVEL_ORDER.Error then
		Log.OnIssue:Fire(entry)
	end
end

function Log.SetLevel(level: string)
	minLevel = LEVEL_ORDER[level] or minLevel
end

function Log.Debug(category: Types.LogCategory, code: Types.LogCode, message: string, context: { [string]: any }?)
	emit("Debug", category, code, message, context)
end

function Log.Info(category: Types.LogCategory, code: Types.LogCode, message: string, context: { [string]: any }?)
	emit("Info", category, code, message, context)
end

function Log.Warn(category: Types.LogCategory, code: Types.LogCode, message: string, context: { [string]: any }?)
	emit("Warn", category, code, message, context)
end

function Log.Error(category: Types.LogCategory, code: Types.LogCode, message: string, context: { [string]: any }?)
	emit("Error", category, code, message, context)
end

function Log.Fatal(category: Types.LogCategory, code: Types.LogCode, message: string, context: { [string]: any }?)
	emit("Fatal", category, code, message, context)
end

--- Register a sink, and hand back a function that removes it. Every entry spawns one
--- thread per sink, so a sink nobody detaches keeps costing on the hottest failure
--- path. The remover is idempotent: calling it twice is a no-op rather than removing
--- whatever has since taken that index.
function Log.AddSink(fn: (entry: LogEntry) -> ()): () -> ()
	table.insert(sinks, fn)
	return function()
		local index = table.find(sinks, fn)
		if index ~= nil then
			table.remove(sinks, index)
		end
	end
end

export type LogFilter = {
	Level: Types.LogLevel?,
	Category: Types.LogCategory?,
	Code: Types.LogCode?,
	Limit: number?,
}

--- Resize the retained-entry ring, keeping the most recent entries. A resize is a
--- configuration change, not a request to forget what already happened.
function Log.SetRingSize(size: number?)
	local next = if type(size) == "number" and size >= 1 then math.floor(size) else DEFAULT_RING_SIZE
	if next == ringSize then
		return
	end

	local kept: { LogEntry } = {}
	for i = 1, ringCount do
		local idx = ((ringNext - 1 - ringCount + i - 1) % ringSize) + 1
		local entry = ring[idx]
		if entry then
			table.insert(kept, entry)
		end
	end
	while #kept > next do
		table.remove(kept, 1) -- drop oldest first
	end

	ringSize = next
	ring = table.create(ringSize) :: any
	for i, entry in kept do
		ring[i] = entry
	end
	ringCount = #kept
	ringNext = (#kept % ringSize) + 1
end

--- Entries currently retained, and the configured capacity.
function Log.RingInfo(): { Size: number, Count: number }
	return { Size = ringSize, Count = ringCount }
end
-- Retained entries, oldest first, optionally filtered by level, category or code.
function Log.GetRecent(filter: LogFilter?): { LogEntry }
	local out = {}
	local minFilter = if filter and filter.Level then LEVEL_ORDER[filter.Level] else nil
	for i = 1, ringCount do
		-- Oldest first: start after the write cursor.
		local idx = ((ringNext - 1 - ringCount + i - 1) % ringSize) + 1
		local entry = ring[idx]
		if entry then
			if minFilter and LEVEL_ORDER[entry.Level] < minFilter then
				continue
			end
			if filter and filter.Category and entry.Category ~= filter.Category then
				continue
			end
			if filter and filter.Code and entry.Code ~= filter.Code then
				continue
			end
			table.insert(out, entry)
		end
	end
	if filter and filter.Limit and #out > filter.Limit then
		local trimmed = table.create(filter.Limit) :: { LogEntry }
		for i = #out - filter.Limit + 1, #out do
			table.insert(trimmed, out[i])
		end
		return trimmed
	end
	return out
end

return Log
