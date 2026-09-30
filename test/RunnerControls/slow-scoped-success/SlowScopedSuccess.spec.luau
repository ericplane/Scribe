--!nonstrict
-- An explicit integration budget covers real yields without relaxing other tests.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, afterEach = JestGlobals.it, JestGlobals.expect, JestGlobals.afterEach
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local HarnessScope = require(Root.Test.Helpers.HarnessScope)

local scope = HarnessScope.new()
local fake = FakeProfileStore.new()
local realNew = fake.New
local harness
fake.New = function(...)
	local store = realNew(...)
	local startSession = store.StartSessionAsync
	store.StartSessionAsync = function(self, ...)
		task.wait(0.2)
		return startSession(self, ...)
	end
	return store
end

afterEach(function()
	scope.Cleanup()
	expect(next(fake.ActiveProfiles)).toBeNil()
	expect(next(harness.Ctx.Persistence.Entries)).toBeNil()
	expect(fake.Persisted["Default/PLAYER_951301"].Coins).toBe(73)
	print("SCRIBE_CONTROL_SLOW_SCOPED_SUCCESS_RELEASED")
end)

it("loads and saves within its explicit budget despite the short default", function()
	harness = scope.Track(TestCtx.make({ Fake = fake }))
	local started = os.clock()
	local _player, _entry, data = harness.Join(951301)
	expect(os.clock() - started >= 0.2).toBe(true)
	data.Coins.Set(73)
	expect(data.Coins.Get()).toBe(73)
end, 1000)
