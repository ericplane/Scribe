--!nonstrict
-- Consumer failures and mutations must not break dispatch.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Log = require(Root.Scribe.Internal.Log)
local Sched = require(Root.Scribe.Internal.Sched)
local Metrics = require(Root.Scribe.Internal.Metrics)
local removers = {}
local deferred = {}
local release = false

local function attach(callback, options)
	local remove = Log.AddSink(callback, options or { Level = "Debug" })
	table.insert(removers, remove)
	return remove
end

local function drainOne()
	local callback = table.remove(deferred, 1)
	callback()
end

beforeEach(function()
	release = false
	Log.SetLevel("Fatal")
	Log.SetRingLevel("Fatal")
	Sched.Install({
		Defer = function(callback)
			table.insert(deferred, callback)
			return coroutine.create(callback)
		end,
	})
end)

afterEach(function()
	release = true
	for _, remove in removers do
		remove()
	end
	table.clear(removers)
	table.clear(deferred)
	task.wait()
	Sched.Reset()
	Log.SetLevel("Debug")
	Log.SetRingLevel(nil)
end)

it("keeps the worker alive when an error cannot be converted to text", function()
	local calls = 0
	local before = Metrics.Get().LogSinkErrors or 0
	attach(function()
		calls += 1
		if calls == 1 then
			error(
				setmetatable({}, {
					__tostring = function()
						error("conversion failed", 0)
					end,
				}),
				0
			)
		end
	end)
	Log.Debug("Persistence", "PROFILE_SIZE", "one")
	Log.Debug("Persistence", "PROFILE_SIZE", "two")
	expect((pcall(drainOne))).toBe(true)
	expect(calls).toBe(2)
	expect((Metrics.Get().LogSinkErrors or 0) - before).toBe(1)
	Log.Debug("Persistence", "PROFILE_SIZE", "three")
	drainOne()
	expect(calls).toBe(3)
end)

it("uses original severity when another sink mutates queued entries", function()
	attach(function(entry)
		entry.Level = nil
	end)
	local seen = {}
	attach(function(entry)
		table.insert(seen, entry.Message)
	end, { Level = "Debug", MaxQueued = 3 })
	for _, message in { "one", "two", "three" } do
		Log.Debug("Persistence", "PROFILE_SIZE", message)
	end
	drainOne()
	expect((pcall(Log.Error, "Persistence", "PROFILE_SAVE_FAIL", "priority"))).toBe(true)
	drainOne()
	expect(table.concat(seen, ",")).toBe("two,three,priority")
end)

it("uses original severity when a log-history consumer edits an entry", function()
	Log.SetRingLevel("Debug")
	local seen = {}
	attach(function(entry)
		table.insert(seen, entry.Message)
	end, { Level = "Debug", MaxQueued = 1 })
	Log.Debug("Persistence", "PROFILE_SIZE", "editable")
	local entry = Log.GetRecent({ Code = "PROFILE_SIZE", Limit = 1 })[1]
	entry.Level = "custom severity"
	expect((pcall(Log.Error, "Persistence", "PROFILE_SAVE_FAIL", "replacement"))).toBe(true)
	drainOne()
	expect(seen[1]).toBe("replacement")
	entry.Level = "Debug"
end)

it("clears a stalled sink's waiting entries without disrupting other sinks", function()
	Sched.Reset()
	local calls, otherCalls = 0, 0
	local remove = attach(function()
		calls += 1
		while not release do
			task.wait()
		end
	end)
	attach(function()
		otherCalls += 1
	end)
	Log.Debug("Persistence", "PROFILE_SIZE", "in flight")
	task.wait()
	for _ = 1, 10 do
		Log.Debug("Persistence", "PROFILE_SIZE", "queued")
	end
	remove()
	release = true
	task.wait(0.03)
	expect(calls).toBe(1)
	expect(otherCalls).toBe(11)
	Log.Debug("Persistence", "PROFILE_SIZE", "after detach")
	task.wait()
	expect(calls).toBe(1)
	expect(otherCalls).toBe(12)
end)
