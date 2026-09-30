--!nonstrict
-- Exercise the public constructor, not the harness's separate compile path.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach
local afterEach = JestGlobals.afterEach
local afterAll = JestGlobals.afterAll

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Config = require(Root.Scribe.Internal.Config)
local Log = require(Root.Scribe.Internal.Log)
local Wire = require(Root.Scribe.Internal.Wire)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)
local StubTransport = require(Root.Test.Helpers.StubTransport)
local ConstructorScope = require(Root.Test.Helpers.ConstructorScope)
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local headless = typeof(RunService) ~= "Instance"
local itHeadless = if headless then it else it.skip
local fragmentAll = __SimHost ~= nil and __SimHost.Env ~= nil and __SimHost.Env.SCRIBE_FRAGMENT_ALL == "1"
local scope = ConstructorScope.new()
local restorers = {}
local savedConfig

local function replace(target, key, value)
	local original = target[key]
	target[key] = value
	local function restore()
		target[key] = original
	end
	table.insert(restorers, restore)
	return restore
end

local function options(store)
	local opts = {
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		ServerStore = store,
		ProfileStoreIndex = "ServerStoreEntrypoint",
		ProfileKeyPrefix = "PLAYER_",
		ProfileStore = FakeProfileStore.new(),
		Transport = StubTransport.new({ AutoPump = true }),
		Mode = "Mock",
		OwnReceipts = false,
		KickOnSessionEnd = false,
		StudioHook = false,
		Banner = false,
		IsRunning = true,
	}
	if fragmentAll then
		opts.MaxOutboundBytes = 256
	end
	return opts
end

local function construct(opts)
	local bundle = Scribe(opts)
	if opts.IsRunning and RunService:IsServer() then
		return bundle.Server
	end
	return scope.TrackClient(bundle.Client)
end

beforeEach(function()
	savedConfig = table.clone(Config)
	scope.Install()
end)

local function restoreGlobals()
	local failures = {}
	for i = #restorers, 1, -1 do
		local ok, err = pcall(restorers[i])
		if ok then
			table.remove(restorers, i)
		else
			table.insert(failures, tostring(err))
		end
	end
	if savedConfig ~= nil then
		Config.BundleConstructed = savedConfig.BundleConstructed
		Config.AutoSaveInterval = savedConfig.AutoSaveInterval
		Config.AutoSaveSource = savedConfig.AutoSaveSource
	end
	if #failures > 0 then
		error(table.concat(failures, "\n"), 0)
	end
end
afterEach(restoreGlobals)
afterEach(scope.Cleanup)
afterAll(restoreGlobals)
afterAll(scope.Cleanup)

it("builds writable server accessors through Scribe(options)", function()
	local data = construct(options({ Wave = Scribe.Int(1), Settings = { Title = "Lobby" } }))
	expect(data.ServerStore ~= nil).toBe(true)
	expect(data.ServerStore.Wave.Get()).toBe(1)
	data.ServerStore.Wave.Increment(2)
	data.ServerStore.Settings.Title.Set("Arena")
	expect(data.ServerStore.Wave.Get()).toBe(3)
	expect(data.ServerStore.Settings.Title.Get()).toBe("Arena")
end)

it("allows store root names that match accessor methods", function()
	local data = construct(options({ Get = 1, Changed = "Lobby" }))
	data.ServerStore.Get.Increment(1)
	data.ServerStore.Changed.Set("Arena")
	expect(data.ServerStore.Get.Get()).toBe(2)
	expect(data.ServerStore.Changed.Get()).toBe("Arena")
end)

it("freezes the store template and its nested tables", function()
	local store = { Wave = 1, Settings = { Title = "Lobby" } }
	construct(options(store))
	expect(table.isfrozen(store)).toBe(true)
	expect(table.isfrozen(store.Settings)).toBe(true)
	expect((pcall(function()
		store.Settings.Title = "changed"
	end))).toBe(false)
end)

it("recognizes ServerStore while still warning about misspelled options", function()
	if headless then
		replace(RunService, "IsStudio", function()
			return true
		end)
	end
	local flagged = {}
	local warn = Log.Warn
	replace(Log, "Warn", function(category, code, message, context)
		if code == "UNKNOWN_OPTION" then
			table.insert(flagged, context.Option)
		end
		warn(category, code, message, context)
	end)
	local opts = options({ Wave = 1 })
	opts.ServerStroe = {}
	construct(opts)
	expect(table.concat(flagged, ",")).toBe("ServerStroe")
end)

it("keeps ServerStore absent when no store is declared", function()
	local data = construct(options(nil))
	expect(rawget(data, "ServerStore")).toBe(nil)
end)

it("builds the store in the public edit-mode client", function()
	local opts = options({ Wave = Scribe.Int(4) })
	opts.IsRunning = false
	local data = construct(opts)
	expect(data.ServerStore ~= nil).toBe(true)
	expect(data.ServerStore.Wave.Get()).toBe(4)
end)

it("destroys store accessors when the public bundle stops", function()
	local data = construct(options({ Wave = 1 }))
	local calls = 0
	data.ServerStore.Wave.Changed(function()
		calls += 1
	end)
	data.ServerStore.Wave.Set(2)
	expect(calls).toBe(1)
	data.Stop()
	local ok = pcall(data.ServerStore.Wave.Set, 3)
	expect(ok).toBe(false)
	expect(calls).toBe(1)
end)

it("rejects invalid store definitions at the public boundary", function()
	for _, invalid in { false, 123, "invalid" } do
		local ok, err = pcall(construct, options(invalid))
		expect(ok).toBe(false)
		expect(string.find(tostring(err), "ServerStore must be a table", 1, true) ~= nil).toBe(true)
	end
end)

it("rejects store roots that collide with the player template", function()
	local ok, err = pcall(construct, options({ Coins = 1 }))
	expect(ok).toBe(false)
	expect(string.find(tostring(err), 'ServerStore declares "Coins"', 1, true) ~= nil).toBe(true)
end)

itHeadless("replicates the snapshot and later writes between public bundles", function()
	local initialText, updatedText = string.rep("a", 1024), string.rep("b", 1024)
	local opts = options({
		Wave = Scribe.Int(1),
		Get = 2,
		Changed = "Lobby",
		Notice = Scribe.String(initialText, { MaxLength = 2048 }),
		Hidden = Scribe.ServerOnly(9),
	})
	local function fragmentCount()
		local count = 0
		for _, frame in opts.Transport.SentToClientLog do
			if buffer.readu8(frame.Bytes, 0) == Wire.Frames.Fragment then
				count += 1
			end
		end
		return count
	end
	local server = construct(opts)
	server.ServerStore.Wave.Set(5)
	local player = FakePlayer.new(60181)
	Players.PlayerAdded:Fire(player)
	expect(server.WaitForData(player, 1) ~= nil).toBe(true)
	opts.Transport.LocalPlayer = player
	local restoreServer = replace(RunService, "IsServer", function()
		return false
	end)
	local restoreClient = replace(RunService, "IsClient", function()
		return true
	end)
	local client = construct(opts)
	restoreClient()
	restoreServer()
	expect(client.ServerStore.Wave.Get()).toBe(5)
	expect(client.ServerStore.Get.Get()).toBe(2)
	expect(client.ServerStore.Changed.Get()).toBe("Lobby")
	expect(client.ServerStore.Notice.Get()).toBe(initialText)
	expect(client.ServerStore.Hidden.Get()).toBe(nil)
	local initialFragments = fragmentCount()
	if fragmentAll then
		expect(initialFragments > 1).toBe(true)
	end
	local observed = 0
	client.ServerStore.Wave.Changed(function(value)
		observed = value
	end)
	server.ServerStore.Wave.Set(8)
	server.ServerStore.Get.Set(7)
	server.ServerStore.Changed.Set("Arena")
	server.ServerStore.Notice.Set(updatedText)
	RunService.PostSimulation:Fire(1 / 60)
	expect(client.ServerStore.Wave.Get()).toBe(8)
	expect(client.ServerStore.Get.Get()).toBe(7)
	expect(client.ServerStore.Changed.Get()).toBe("Arena")
	expect(client.ServerStore.Notice.Get()).toBe(updatedText)
	expect(observed).toBe(8)
	if fragmentAll then
		expect(fragmentCount() > initialFragments + 1).toBe(true)
	end
	server.Flush(player, { Force = true })
	local stored = opts.ProfileStore.Persisted["ServerStoreEntrypoint/PLAYER_60181"]
	expect(stored.Wave).toBe(nil)
	expect(stored.Hidden).toBe(nil)
end)
