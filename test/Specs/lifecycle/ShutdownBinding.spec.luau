--!nonstrict
-- Capture the real binding callback: calling Shutdown directly cannot prove that
-- retiring one temporary owner leaves other owners' close callbacks intact.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, jest = JestGlobals.it, JestGlobals.expect, JestGlobals.jest
local beforeEach, afterEach = JestGlobals.beforeEach, JestGlobals.afterEach
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)

-- Native DataModel methods cannot be replaced. The isolated Studio probe covers
-- actual engine close dispatch; these checks need a capturable binder.
local canCaptureBinding = typeof(game) ~= "Instance"
local runIt = if canCaptureBinding then it else it.skip
local callbacks, harnesses, releases

beforeEach(function()
	callbacks, harnesses, releases = {}, {}, {}
end)

afterEach(function()
	for _, harness in harnesses do
		harness.Cleanup()
	end
	for _, release in releases do
		release()
	end
	jest.restoreAllMocks()
end)

local function bindHarness()
	local harness = TestCtx.make({ Options = { LogRingLevel = "Info" } })
	table.insert(harnesses, harness)
	local previous = #callbacks
	-- Jest gives modules separate global proxies. Replace the binder used by this
	-- function, and restore immediately; a spy on this spec's game proxy can leave
	-- the cached production module referring to a restored old spy.
	local bindingGame = getfenv(harness.Ctx.Persistence.BindShutdown).game
	local original = bindingGame.BindToClose
	bindingGame.BindToClose = function(_self, callback)
		table.insert(callbacks, callback)
	end
	local ok, release = pcall(harness.Ctx.Persistence.BindShutdown)
	bindingGame.BindToClose = original
	if not ok then
		error(release, 0)
	end
	expect(type(release)).toBe("function")
	table.insert(releases, release)
	expect(#callbacks).toBe(previous + 1)
	return harness, callbacks[#callbacks], release
end

local function shutdownLogs()
	return #Scribe.GetRecentLogs({ Code = "SHUTDOWN_FLUSH", Limit = 500 })
		+ #Scribe.GetRecentLogs({ Code = "SHUTDOWN_DONE", Limit = 500 })
end

runIt("retires a drained owner's callback without more saves or shutdown logs", function()
	local harness, callback, release = bindHarness()
	local _player, _entry, data = harness.Join(952001)
	data.Coins.Set(41)
	harness.Ctx.Persistence.Shutdown(1)
	harness.Data.Stop()
	expect((next(harness.Fake.ActiveProfiles))).toBeNil()
	expect(harness.Fake.Persisted["Default/PLAYER_952001"].Coins).toBe(41)
	local writes = harness.Fake.SaveCounts["Default/PLAYER_952001"]
	local logs = shutdownLogs()
	local beginClose = jest.spyOn(harness.Fake, "BeginClose")
	local awaitClose = jest.spyOn(harness.Fake, "AwaitClose")
	release()
	release()
	callback()
	callback()
	expect(beginClose).never.toHaveBeenCalled()
	expect(awaitClose).never.toHaveBeenCalled()
	expect(harness.Fake.SaveCounts["Default/PLAYER_952001"]).toBe(writes)
	expect(shutdownLogs()).toBe(logs)
end)

runIt("keeps a stopped owner's callback responsible for its active session", function()
	local harness, callback = bindHarness()
	local _player, entry, data = harness.Join(952002)
	data.Coins.Set(42)
	harness.Data.Stop()
	expect(entry.Profile:IsActive()).toBe(true)
	expect(harness.Fake.IsClosing).toBe(false)
	callback()
	expect(harness.Fake.IsClosing).toBe(true)
	expect(entry.Profile:IsActive()).toBe(false)
	expect((next(harness.Fake.ActiveProfiles))).toBeNil()
	expect(harness.Fake.Persisted["Default/PLAYER_952002"].Coins).toBe(42)
end)

runIt("drains a stopped empty bundle's store-held profile", function()
	local harness, callback = bindHarness()
	local store = harness.Fake.New("Default", { Coins = 0 })
	local profile = store:StartSessionAsync("BINDING_STRAY")
	profile.Data.Coins = 43
	expect((next(harness.Ctx.Persistence.Entries))).toBeNil()
	harness.Data.Stop()
	callback()
	expect(profile:IsActive()).toBe(false)
	expect(harness.Fake.Persisted["Default/BINDING_STRAY"].Coins).toBe(43)
	expect((next(harness.Fake.ActiveProfiles))).toBeNil()
end)

runIt("waits for an in-flight store load even when the stopped bundle has no entries", function()
	local harness, callback = bindHarness()
	harness.Fake.YieldOnSessionStart = true
	local store = harness.Fake.New("Default", { Coins = 0 })
	local finished, returned = false, nil
	task.spawn(function()
		returned = store:StartSessionAsync("BINDING_PENDING")
		finished = true
	end)
	expect(harness.Fake.ActiveLoadJobs).toBe(1)
	expect((next(harness.Ctx.Persistence.Entries))).toBeNil()
	harness.Data.Stop()
	callback()
	expect(finished).toBe(true)
	expect(returned).toBeNil()
	expect(harness.Fake.ActiveLoadJobs).toBe(0)
	expect((next(harness.Fake.ActiveProfiles))).toBeNil()
end)

runIt("does not cancel an already-running drain when its binding is released", function()
	local harness, callback, release = bindHarness()
	local awaitClose = harness.Fake.AwaitClose
	local entered, continueDrain, finished = false, false, false
	harness.Fake.AwaitClose = function()
		entered = true
		while not continueDrain do
			task.wait()
		end
		awaitClose()
	end
	task.spawn(function()
		callback()
		finished = true
	end)
	expect(entered).toBe(true)
	expect(finished).toBe(false)
	release()
	continueDrain = true
	local deadline = os.clock() + 1
	while not finished and os.clock() < deadline do
		task.wait()
	end
	expect(finished).toBe(true)
	expect(harness.Fake.IsClosing).toBe(true)
	local logs = shutdownLogs()
	callback()
	expect(shutdownLogs()).toBe(logs)
end)
