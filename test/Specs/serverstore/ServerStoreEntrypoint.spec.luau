--!nonstrict
-- Exercise the public constructor, not the harness's separate compile path.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Config = require(Root.Scribe.Internal.Config)
	local Log = require(Root.Scribe.Internal.Log)
	local Wire = require(Root.Scribe.Internal.Wire)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local RunService = game:GetService("RunService")
	local Players = game:GetService("Players")
	local headless = typeof(RunService) ~= "Instance"
	local itHeadless = if headless then it else itSKIP
	local fragmentAll = __SimHost ~= nil and __SimHost.Env ~= nil and __SimHost.Env.SCRIBE_FRAGMENT_ALL == "1"
	local active, restorers = {}, {}
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
		local api = if opts.IsRunning and RunService:IsServer() then bundle.Server else bundle.Client
		table.insert(active, api)
		return api
	end

	beforeEach(function()
		savedConfig = table.clone(Config)
	end)

	afterEach(function()
		for i = #active, 1, -1 do
			active[i].Stop()
		end
		table.clear(active)
		for i = #restorers, 1, -1 do
			restorers[i]()
		end
		table.clear(restorers)
		Config.BundleConstructed = savedConfig.BundleConstructed
		Config.AutoSaveInterval = savedConfig.AutoSaveInterval
		Config.AutoSaveSource = savedConfig.AutoSaveSource
	end)

	it("builds writable server accessors through Scribe(options)", function()
		local data = construct(options({ Wave = Scribe.Int(1), Settings = { Title = "Lobby" } }))
		expect(data.ServerStore ~= nil).to.equal(true)
		expect(data.ServerStore.Wave.Get()).to.equal(1)
		data.ServerStore.Wave.Increment(2)
		data.ServerStore.Settings.Title.Set("Arena")
		expect(data.ServerStore.Wave.Get()).to.equal(3)
		expect(data.ServerStore.Settings.Title.Get()).to.equal("Arena")
	end)

	it("allows store root names that match accessor methods", function()
		local data = construct(options({ Get = 1, Changed = "Lobby" }))
		data.ServerStore.Get.Increment(1)
		data.ServerStore.Changed.Set("Arena")
		expect(data.ServerStore.Get.Get()).to.equal(2)
		expect(data.ServerStore.Changed.Get()).to.equal("Arena")
	end)

	it("freezes the store template and its nested tables", function()
		local store = { Wave = 1, Settings = { Title = "Lobby" } }
		construct(options(store))
		expect(table.isfrozen(store)).to.equal(true)
		expect(table.isfrozen(store.Settings)).to.equal(true)
		expect(pcall(function()
			store.Settings.Title = "changed"
		end)).to.equal(false)
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
		expect(table.concat(flagged, ",")).to.equal("ServerStroe")
	end)

	it("keeps ServerStore absent when no store is declared", function()
		local data = construct(options(nil))
		expect(rawget(data, "ServerStore")).to.equal(nil)
	end)

	it("builds the store in the public edit-mode client", function()
		local opts = options({ Wave = Scribe.Int(4) })
		opts.IsRunning = false
		local data = construct(opts)
		expect(data.ServerStore ~= nil).to.equal(true)
		expect(data.ServerStore.Wave.Get()).to.equal(4)
	end)

	it("destroys store accessors when the public bundle stops", function()
		local data = construct(options({ Wave = 1 }))
		local calls = 0
		data.ServerStore.Wave.Changed(function()
			calls += 1
		end)
		data.ServerStore.Wave.Set(2)
		expect(calls).to.equal(1)
		data.Stop()
		local ok = pcall(data.ServerStore.Wave.Set, 3)
		expect(ok).to.equal(false)
		expect(calls).to.equal(1)
	end)

	it("rejects invalid store definitions at the public boundary", function()
		for _, invalid in { false, 123, "invalid" } do
			local ok, err = pcall(construct, options(invalid))
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "ServerStore must be a table", 1, true) ~= nil).to.equal(true)
		end
	end)

	it("rejects store roots that collide with the player template", function()
		local ok, err = pcall(construct, options({ Coins = 1 }))
		expect(ok).to.equal(false)
		expect(string.find(tostring(err), 'ServerStore declares "Coins"', 1, true) ~= nil).to.equal(true)
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
		expect(server.WaitForData(player, 1) ~= nil).to.equal(true)
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
		expect(client.ServerStore.Wave.Get()).to.equal(5)
		expect(client.ServerStore.Get.Get()).to.equal(2)
		expect(client.ServerStore.Changed.Get()).to.equal("Lobby")
		expect(client.ServerStore.Notice.Get()).to.equal(initialText)
		expect(client.ServerStore.Hidden.Get()).to.equal(nil)
		local initialFragments = fragmentCount()
		if fragmentAll then
			expect(initialFragments > 1).to.equal(true)
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
		expect(client.ServerStore.Wave.Get()).to.equal(8)
		expect(client.ServerStore.Get.Get()).to.equal(7)
		expect(client.ServerStore.Changed.Get()).to.equal("Arena")
		expect(client.ServerStore.Notice.Get()).to.equal(updatedText)
		expect(observed).to.equal(8)
		if fragmentAll then
			expect(fragmentCount() > initialFragments + 1).to.equal(true)
		end
		server.Flush(player, { Force = true })
		local stored = opts.ProfileStore.Persisted["ServerStoreEntrypoint/PLAYER_60181"]
		expect(stored.Wave).to.equal(nil)
		expect(stored.Hidden).to.equal(nil)
	end)
end
