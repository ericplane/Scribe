--!nonstrict
-- Slow lifecycle work is observable without changing lock or save ordering.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Clock = require(Root.Scribe.Internal.Clock)
local Metrics = require(Root.Scribe.Internal.Metrics)
local Log = require(Root.Scribe.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local harness
local parked = {}

afterEach(function()
	for _, thread in parked do
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
	table.clear(parked)
	if harness then
		harness.Cleanup()
		harness = nil
	end
	Clock.Reset()
	Metrics.Reset()
end)

local function clock()
	local now = 1000
	local delayed = {}
	Clock.Install({
		Now = function()
			return 1000000 + now
		end,
		Monotonic = function()
			return now
		end,
		Delay = function(seconds, callback, ...)
			local args = table.pack(...)
			local thread = coroutine.create(function()
				callback(table.unpack(args, 1, args.n))
			end)
			table.insert(delayed, { At = now + seconds, Thread = thread })
			return thread
		end,
	})
	return {
		Skip = function(seconds)
			now += seconds
		end,
		Advance = function(seconds)
			now += seconds
			while true do
				local due
				for index, item in delayed do
					if item.At <= now then
						due = index
						break
					end
				end
				if due == nil then
					break
				end
				local item = table.remove(delayed, due)
				local ok, err = coroutine.resume(item.Thread)
				assert(ok, err)
			end
		end,
	}
end

local function make(options)
	local selected = { LogRingLevel = "Warn" }
	for key, value in options or {} do
		selected[key] = value
	end
	harness = TestCtx.make({ Template = { Coins = 0 }, Options = selected })
	Metrics.Reset()
	return harness
end

local function park()
	local thread = coroutine.running()
	table.insert(parked, thread)
	coroutine.yield()
end

local function resume()
	local thread = table.remove(parked, 1)
	assert(thread ~= nil, "expected a parked lifecycle callback")
	task.spawn(thread)
end

local function warnings(code, userId)
	local out = {}
	for _, entry in Log.GetRecent({ Code = code }) do
		if entry.Context and entry.Context.UserId == userId then
			table.insert(out, entry)
		end
	end
	return out
end

it("reports a held session once while unrelated players can load", function()
	local time = clock()
	local h = make()
	local id = 975001
	local start = h.Ctx.Persistence.Store.StartSessionAsync
	h.Ctx.Persistence.Store.StartSessionAsync = function(store, key, params)
		if key == `PLAYER_{id}` then
			park()
		end
		return start(store, key, params)
	end
	local player = FakePlayer.new(id)
	h.Ctx.Persistence.OnPlayerAdded(player)
	local state, phase = h.Data.GetState(player)
	expect(`{state}/{phase}`).toBe("Loading/AcquiringSession")
	time.Advance(9)
	expect(#warnings("SLOW_LOAD", id)).toBe(0)
	time.Advance(1)
	local slow = warnings("SLOW_LOAD", id)
	expect(#slow).toBe(1)
	expect(slow[1].Context.Phase).toBe("AcquiringSession")
	expect(slow[1].Context.Duration).toBe(10)
	local other = h.Join(id + 1)
	expect((h.Data.GetState(other))).toBe("Ready")
	expect((h.Data.GetState(player))).toBe("Loading")
	time.Advance(30)
	expect(#warnings("SLOW_LOAD", id)).toBe(1)
	resume()
	state, phase = h.Data.GetState(player)
	expect(`{state}/{tostring(phase)}`).toBe("Ready/nil")
	expect(#warnings("SLOW_LOAD", id)).toBe(1)
	expect(Metrics.Get().ProfileLoadDuration.Max).toBe(40)
	expect(Metrics.Get().LoadDuration.Max).toBe(40)
end)

it("identifies initialization separately from acquiring the profile", function()
	local time = clock()
	local id = 975011
	local h = make({ OnPlayerInit = park })
	local player = FakePlayer.new(id)
	h.Ctx.Persistence.OnPlayerAdded(player)
	local state, phase = h.Data.GetState(player)
	expect(`{state}/{phase}`).toBe("Loading/Initializing")
	time.Advance(10)
	expect(warnings("SLOW_LOAD", id)[1].Context.Phase).toBe("Initializing")
	expect(Metrics.Get().ProfileLoadDuration.Max).toBe(0)
	resume()
	expect(Metrics.Get().LoadDuration.Max).toBe(10)
end)

it("cancels a load warning when the player leaves before the threshold", function()
	local time = clock()
	local h = make()
	local id = 975021
	local start = h.Ctx.Persistence.Store.StartSessionAsync
	h.Ctx.Persistence.Store.StartSessionAsync = function(store, key, params)
		park()
		return start(store, key, params)
	end
	local player = FakePlayer.new(id)
	h.Ctx.Persistence.OnPlayerAdded(player)
	time.Advance(2)
	h.Leave(player)
	time.Advance(20)
	expect(#warnings("SLOW_LOAD", id)).toBe(0)
	resume()
	expect(h.Ctx.Persistence.EntryFor(player)).toBe(nil)
end)

it("does not warn after a fast load or create a leaving-hook sample without a hook", function()
	local time = clock()
	local h = make()
	local id = 975031
	local player, entry = h.Join(id)
	expect(entry.StopLoadWatchdog).toBe(nil)
	time.Advance(20)
	h.Leave(player)
	expect(#warnings("SLOW_LOAD", id)).toBe(0)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(0)
	expect(Metrics.Get().PlayerLeavingHookDuration).toBe(nil)
end)

it("releases a stopped bundle's load watchdog while its store call is still parked", function()
	local time = clock()
	local h = make()
	local id = 975081
	h.Ctx.Persistence.Store.StartSessionAsync = function()
		park()
		return nil
	end
	local player = FakePlayer.new(id)
	h.Ctx.Persistence.OnPlayerAdded(player)
	local entry = h.Ctx.Persistence.EntryFor(player)
	h.Data.Stop()
	expect(entry.StopLoadWatchdog).toBe(nil)
	time.Advance(20)
	expect(#warnings("SLOW_LOAD", id)).toBe(0)
	resume()
	expect(#warnings("SLOW_LOAD", id)).toBe(0)
end)

it("measures failed store attempts without reporting a successful join", function()
	local time = clock()
	local h = make()
	local start = h.Ctx.Persistence.Store.StartSessionAsync
	h.Ctx.Persistence.Store.StartSessionAsync = function(store, key, params)
		time.Skip(3)
		return start(store, key, params)
	end
	h.Fake.FailNextLoad = true
	h.Ctx.Persistence.OnPlayerAdded(FakePlayer.new(975041))
	expect(Metrics.Get().ProfileLoadDuration.Count).toBe(1)
	expect(Metrics.Get().ProfileLoadDuration.Max).toBe(3)
	expect(Metrics.Get().LoadDuration).toBe(nil)
end)

it("warns once during a slow leaving hook and saves its eventual writes", function()
	local time = clock()
	local calls = 0
	local id = 975051
	local h = make({
		OnPlayerLeaving = function(leaver, data)
			if leaver.UserId ~= id then
				return
			end
			calls += 1
			data.Coins.Increment(2)
			park()
			data.Coins.Increment(3)
		end,
	})
	local player, entry = h.Join(id)
	task.spawn(h.Leave, player)
	time.Advance(10)
	local slow = warnings("PLAYER_LEAVING_HOOK_SLOW", id)
	expect(#slow).toBe(1)
	expect(slow[1].Context.Reason).toBe("player-left")
	expect(slow[1].Context.Duration).toBe(10)
	expect(entry.Profile:IsActive()).toBe(true)
	local other = h.Join(id + 1)
	expect((h.Data.GetState(other))).toBe("Ready")
	time.Advance(10)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(1)
	resume()
	expect(h.Fake.Persisted[`Default/PLAYER_{id}`].Coins).toBe(5)
	expect(calls).toBe(1)
	expect(entry.StopLeavingHookWatchdog).toBe(nil)
	expect(Metrics.Get().PlayerLeavingHookDuration.Max).toBe(20)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(1)
end)

it("measures a throwing hook and preserves its writes before the error", function()
	local time = clock()
	local id = 975061
	local h = make({
		OnPlayerLeaving = function(_player, data)
			data.Coins.Set(7)
			time.Skip(11)
			error("hook failed")
		end,
	})
	local player = h.Join(id)
	h.Leave(player)
	expect(h.Fake.Persisted[`Default/PLAYER_{id}`].Coins).toBe(7)
	expect(Metrics.Get().PlayerLeavingHookDuration.Max).toBe(11)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(1)
	time.Advance(10)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(1)
end)

it("cancels fast-hook watchdogs without warning later", function()
	local time = clock()
	local h = make({ OnPlayerLeaving = function() end })
	local id = 975071
	local player, entry = h.Join(id)
	h.Leave(player)
	expect(entry.StopLeavingHookWatchdog).toBe(nil)
	time.Advance(20)
	expect(#warnings("PLAYER_LEAVING_HOOK_SLOW", id)).toBe(0)
	expect(Metrics.Get().PlayerLeavingHookDuration.Count).toBe(1)
end)
