--!nonstrict
-- A cleanup timeout must restore the constructor before yielding and leave the
-- unfinished fixture registered for a later drain, including its real binding.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect = JestGlobals.it, JestGlobals.expect
local afterEach, afterAll = JestGlobals.afterEach, JestGlobals.afterAll
local Scribe = require(Root.Scribe)
local Server = require(Root.Scribe.Server)
local Template = require(Root.Scribe.Internal.Template)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)
local StubTransport = require(Root.Test.Helpers.StubTransport)
local ConstructorScope = require(Root.Test.Helpers.ConstructorScope)

local scope = ConstructorScope.new()
local originalBuild = Server.build
local fake = FakeProfileStore.new()
local awaitClose = fake.AwaitClose
local ctx, profile
local bindings, releases, drainAttempts = 0, 0, 0
local cleanupTailRan = false

local function observedBuild(options, compiled)
	local data, context = originalBuild(options, compiled)
	ctx = context
	local bindShutdown = ctx.Persistence.BindShutdown
	ctx.Persistence.BindShutdown = function()
		-- Run the real engine binder; observe only the release it returns.
		local release = bindShutdown()
		bindings += 1
		return function()
			releases += 1
			release()
		end
	end
	return data, ctx
end

afterEach(function()
	scope.Cleanup()
end, 150)

afterEach(function()
	local restoredBeforeDrain = Server.build == observedBuild
	-- Restore both seams before assertions so afterAll can retry a failed drain.
	Server.build = originalBuild
	fake.AwaitClose = awaitClose
	expect(restoredBeforeDrain).toBe(true)
	expect(drainAttempts).toBe(1)
	expect(cleanupTailRan).toBe(false)
	expect(bindings).toBe(1)
	expect(releases).toBe(0)
	expect(profile:IsActive()).toBe(true)
	expect((next(ctx.Persistence.Entries))).never.toBeNil()
	expect(ctx.Persistence.Stopped).toBe(false)
	print("SCRIBE_CONTROL_CONSTRUCTOR_RESTORED_BEFORE_DRAIN_TIMEOUT")
end)

afterAll(function()
	scope.Cleanup()
	scope.Cleanup()
	expect(Server.build).toBe(originalBuild)
	expect(profile:IsActive()).toBe(false)
	expect(next(fake.ActiveProfiles)).toBeNil()
	expect(fake.ActiveLoadJobs).toBe(0)
	expect(next(ctx.Persistence.Entries)).toBeNil()
	expect(ctx.Persistence.Stopped).toBe(true)
	expect(fake.Persisted["ConstructorTimeout/PLAYER_953001"].Coins).toBe(73)
	expect(bindings).toBe(1)
	expect(releases).toBe(1)
	print("SCRIBE_CONTROL_CONSTRUCTOR_TIMEOUT_RETRY_RELEASED_ONCE")
end)

it("retains a public constructor fixture when its cleanup times out", function()
	Server.build = observedBuild
	scope.Install()
	local template = { Coins = Scribe.Int(0, { Min = 0 }) }
	local data = Server.new({
		Template = template,
		ProfileStore = fake,
		ProfileStoreIndex = "ConstructorTimeout",
		ProfileKeyPrefix = "PLAYER_",
		Transport = StubTransport.new(),
		Mode = "Mock",
		OwnReceipts = false,
		KickOnSessionEnd = false,
		LogLevel = "Fatal",
		Banner = false,
	}, Template.Compile(template, {}))
	local player = FakePlayer.new(953001)
	ctx.Persistence.OnPlayerAdded(player)
	local accessor = data.WaitForData(player, 1)
	expect(accessor).never.toBeNil()
	accessor.Coins.Set(73)
	profile = fake.ActiveProfiles["ConstructorTimeout/PLAYER_953001"]
	expect(profile:IsActive()).toBe(true)
	expect(bindings).toBe(1)
	fake.AwaitClose = function()
		drainAttempts += 1
		task.wait(30)
		cleanupTailRan = true
		awaitClose()
	end
	print("SCRIBE_CONTROL_CONSTRUCTOR_TIMEOUT_RESOURCES_ACQUIRED")
end)
