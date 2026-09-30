--!nonstrict
-- `StudioHook` gates both debug hooks. Attach is spied because its latch is a process
-- singleton (see DebugHookServerStop.spec); IsStudio is pinned true because the runner pins it false.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local afterAll = JestGlobals.afterAll

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Server = require(Root.Scribe.Server) :: any
local Client = require(Root.Scribe.Client) :: any
local ServerHook = require(Root.Scribe.Server.DebugHook) :: any
local ClientHook = require(Root.Scribe.Client.DebugHook) :: any
local Template = require(Root.Scribe.Internal.Template)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local StubTransport = require(Root.Test.Helpers.StubTransport)
local Config = require(Root.Scribe.Internal.Config)
local Log = require(Root.Scribe.Internal.Log)
local ConstructorScope = require(Root.Test.Helpers.ConstructorScope)

local scope = ConstructorScope.new()
local savedServerAttach, savedClientAttach, savedIsStudio, savedConstructed
beforeEach(function()
	savedServerAttach, savedClientAttach = ServerHook.Attach, ClientHook.Attach
	savedIsStudio = if typeof(RunService) ~= "Instance" then RunService.IsStudio else nil
	savedConstructed = Config.BundleConstructed
	scope.Install()
end)
afterEach(function()
	ServerHook.Attach, ClientHook.Attach = savedServerAttach, savedClientAttach
	if savedIsStudio ~= nil then
		RunService.IsStudio = savedIsStudio
	end
	Config.BundleConstructed = savedConstructed
end)
afterEach(scope.Cleanup)
afterAll(scope.Cleanup)

local compiled = Template.Compile({ Coins = Scribe.Int(0, { Min = 0 }) }, {})

local function serverOptions(extra)
	local options = {
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Transport = StubTransport.new(),
		ProfileStore = FakeProfileStore.new(),
		ProfileStoreIndex = "Default",
		ProfileKeyPrefix = "PLAYER_",
		UseMock = true,
		OwnReceipts = false,
		KickOnSessionEnd = false,
		LogLevel = "Fatal",
		Banner = false,
	}
	for key, value in extra or {} do
		options[key] = value
	end
	return options
end

local function inStudio(body)
	local realIsStudio = nil
	if not RunService:IsStudio() then
		realIsStudio = RunService.IsStudio
		RunService.IsStudio = function()
			return true
		end
	end
	local ok, err = pcall(body)
	if realIsStudio ~= nil then
		RunService.IsStudio = realIsStudio
	end
	if not ok then
		error(err, 0)
	end
end

local function withSpy(hook, counter, body)
	local real = hook.Attach
	hook.Attach = function()
		counter.n += 1
		return function() end
	end
	local ok, err = pcall(body)
	hook.Attach = real
	if not ok then
		error(err, 0)
	end
end

it("attaches the server hook only when StudioHook is true, even in Studio", function()
	local attaches = { n = 0 }
	inStudio(function()
		withSpy(ServerHook, attaches, function()
			local off = Server.new(serverOptions(), compiled)
			local offCount = attaches.n
			off.Stop()
			local explicitOff = Server.new(serverOptions({ StudioHook = false }), compiled)
			local explicitCount = attaches.n
			explicitOff.Stop()
			local on = Server.new(serverOptions({ StudioHook = true }), compiled)
			local onCount = attaches.n
			on.Stop()
			expect(`{offCount} {explicitCount} {onCount}`).toBe("0 0 1")
		end)
	end)
	-- Outside Studio the option is inert; headless only, the real service cannot be pinned false.
	if not RunService:IsStudio() then
		withSpy(ServerHook, attaches, function()
			local live = Server.new(serverOptions({ StudioHook = true }), compiled)
			live.Stop()
			expect(attaches.n).toBe(1)
		end)
	end
end)

it("attaches the client hook only when StudioHook is true", function()
	local harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
	local player = harness.Join()
	harness.Transport.LocalPlayer = player
	local attaches = { n = 0 }
	withSpy(ClientHook, attaches, function()
		local off = table.clone(harness.Options)
		off.DevMode = true
		off.IsClient = true
		scope.TrackClient(Client.new(off, harness.Compiled)).Stop()
		local offCount = attaches.n
		local on = table.clone(off)
		on.StudioHook = true
		scope.TrackClient(Client.new(on, harness.Compiled)).Stop()
		expect(`{offCount} {attaches.n}`).toBe("0 1")
	end)
	harness.Cleanup()
end)

it("is a known option, so Studio does not warn about the spelling", function()
	-- An uncompilable template reaches the scan and aborts before a bundle is built.
	local constructed = Config.BundleConstructed
	Config.BundleConstructed = false
	local before = #Log.GetRecent({ Code = "UNKNOWN_OPTION" })
	inStudio(function()
		pcall(Scribe, {
			Template = { [1] = 0 },
			ProfileStoreIndex = "D",
			ProfileKeyPrefix = "P_",
			Banner = false,
			StudioHook = true,
			StudioHok = true,
		})
	end)
	Config.BundleConstructed = constructed
	local flagged = {}
	local recent = Log.GetRecent({ Code = "UNKNOWN_OPTION" })
	for i = before + 1, #recent do
		table.insert(flagged, recent[i].Context and recent[i].Context.Option)
	end
	expect(table.concat(flagged, ",")).toBe("StudioHok")
end)
