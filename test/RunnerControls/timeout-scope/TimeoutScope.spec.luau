--!nonstrict
-- A runner deadline must release both an owned session and a load still yielding.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, afterEach = JestGlobals.it, JestGlobals.expect, JestGlobals.afterEach
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local HarnessScope = require(Root.Test.Helpers.HarnessScope)

local scope = HarnessScope.new()
local fake = FakeProfileStore.new()
local realNew = fake.New
local releaseLoad = false
local pendingLoads = 0
local joinFinished = false
local pendingAccessor
local tailRan = false
local cleanups = 0
local harness

fake.New = function(...)
	local store = realNew(...)
	local startSession = store.StartSessionAsync
	store.StartSessionAsync = function(self, key, params)
		if key == "PLAYER_951002" then
			pendingLoads += 1
			while not releaseLoad do
				task.wait()
			end
			pendingLoads -= 1
		end
		return startSession(self, key, params)
	end
	return store
end

afterEach(function()
	scope.Cleanup()
	-- The asynchronous load belongs to Scribe, not the timed-out test coroutine.
	-- Let its outstanding request return after Cleanup has unparented the player.
	releaseLoad = true
	local deadline = os.clock() + 1
	while not joinFinished and os.clock() < deadline do
		task.wait()
	end
	cleanups += 1
	expect(joinFinished).toBe(true)
	expect(pendingLoads).toBe(0)
	expect(fake.ActiveLoadJobs).toBe(0)
	expect(next(fake.ActiveProfiles)).toBeNil()
	expect(next(harness.Ctx.Persistence.Entries)).toBeNil()
end)

it("times out with one ready session and one pending load", function()
	harness = scope.Track(TestCtx.make({ Fake = fake }))
	local _player, _entry, data = harness.Join(951001)
	data.Coins.Set(27)
	task.spawn(function()
		local _pendingPlayer, _pendingEntry, accessor = harness.TryJoin(951002, 2)
		pendingAccessor = accessor
		joinFinished = true
	end)
	expect(pendingLoads).toBe(1)
	expect(fake.ActiveProfiles["Default/PLAYER_951001"]).never.toBeNil()
	print("SCRIBE_CONTROL_SCOPE_RESOURCES_ACQUIRED")
	task.wait(30)
	tailRan = true
end, 150)

it("sees no leaked session, late load, or skipped cleanup after the timeout", function()
	task.wait()
	expect(cleanups).toBe(1)
	expect(tailRan).toBe(false)
	expect(pendingAccessor).toBeNil()
	expect(fake.Persisted["Default/PLAYER_951001"].Coins).toBe(27)
	expect(fake.Persisted["Default/PLAYER_951002"]).toBeNil()
	expect(next(fake.ActiveProfiles)).toBeNil()
	expect(next(harness.Ctx.Persistence.Entries)).toBeNil()
	print("SCRIBE_CONTROL_SCOPE_TIMEOUT_CLEANUP_PROVEN")
end)
