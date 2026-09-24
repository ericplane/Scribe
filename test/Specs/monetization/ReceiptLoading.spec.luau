--!nonstrict
-- Join receipts wait for the same player's initialized, durable profile.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local RETRY = Enum.ProductPurchaseDecision.NotProcessedYet
	local BUYER = 79101
	local universe

	local function build(extra)
		local grants = { Count = 0 }
		local options = {
			Products = {
				Coins = {
					Id = 901,
					Grant = function(data)
						grants.Count += 1
						data.Coins.Increment(100)
					end,
				},
			},
		}
		for key, value in extra or {} do
			options[key] = value
		end
		universe = Universe.new({
			Seed = 79101,
			Servers = 1,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = options,
		})
		Guard.Install(universe)
		return universe, universe:Server(1), grants
	end

	local function receipt(userId, id)
		return {
			PlayerId = userId,
			ProductId = 901,
			PurchaseId = id or "joining",
			CurrencySpent = 9,
			ProductPurchaseChannel = Enum.ProductPurchaseChannel.ExperienceDetailsPage,
		}
	end

	local function dispatch(server, info)
		local result = { Done = false }
		universe.Sched:Spawn(function()
			local ok, value = pcall(server.Bundle.Data.HandleReceipt, info)
			result.Ok, result.Value, result.Done = ok, value, true
		end)
		return result
	end

	local function expectDecision(result, decision)
		expect(result.Done).to.equal(true)
		expect(result.Ok).to.equal(true)
		expect(result.Value).to.equal(decision)
	end

	local function persisted(userId)
		local record = universe.Disk.Keyspace:Read("Default", `PLAYER_{userId}`)
		return if record then record.Value.Data else nil
	end

	local function pauseLoad(server, userId, fail)
		local store = server.Bundle.Ctx.Persistence.Store
		local start = store.StartSessionAsync
		local gate = {}
		store.StartSessionAsync = function(self, key, params)
			if key == `PLAYER_{userId}` then
				gate.Thread = coroutine.running()
				coroutine.yield()
				if fail then
					return nil
				end
			end
			return start(self, key, params)
		end
		function gate.Release()
			local thread = gate.Thread
			gate.Thread = nil
			universe.Sched:Resume(thread)
		end
		return gate
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	it("keeps the first receipt pending until the profile loads, then saves its grant", function()
		local uni, server, grants = build()
		local gate = pauseLoad(server, BUYER)
		local player = FakePlayer.new(BUYER)
		server:Join(BUYER, player)
		local result = dispatch(server, receipt(BUYER))
		uni:Run(20)
		expect(server.Bundle.Data.GetState(player)).to.equal("Loading")
		expect(result.Done).to.equal(false)
		expect(grants.Count).to.equal(0)
		expect(persisted(BUYER)).to.equal(nil)

		gate.Release()
		uni:Run(15)
		expectDecision(result, GRANTED)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER).Coins).to.equal(100)
		expect(persisted(BUYER)._Scribe.ProcessedPurchaseIds[1].Id).to.equal("joining")
	end)

	it("waits for OnPlayerInit before granting", function()
		local initThread
		local uni, server, grants = build({
			OnPlayerInit = function(_player, raw)
				initThread = coroutine.running()
				coroutine.yield()
				raw.Coins = 25
			end,
		})
		local player = FakePlayer.new(BUYER)
		server:Join(BUYER, player)
		uni:Run(2)
		expect(initThread ~= nil).to.equal(true)
		local result = dispatch(server, receipt(BUYER))
		uni:Run(2)
		expect(result.Done).to.equal(false)
		expect(grants.Count).to.equal(0)

		uni.Sched:Resume(initThread)
		uni:Run(15)
		expectDecision(result, GRANTED)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER).Coins).to.equal(125)
	end)

	it("claims concurrent duplicates before either can wait or grant again", function()
		local uni, server, grants = build()
		local gate = pauseLoad(server, BUYER)
		local persistence = server.Bundle.Ctx.Persistence
		local waitForData = persistence.WaitForData
		local waits = 0
		persistence.WaitForData = function(...)
			waits += 1
			return waitForData(...)
		end
		server:Join(BUYER, FakePlayer.new(BUYER))
		local first = dispatch(server, receipt(BUYER))
		local duplicate = dispatch(server, receipt(BUYER))
		expectDecision(duplicate, RETRY)
		expect(waits).to.equal(1)
		expect(first.Done).to.equal(false)

		gate.Release()
		uni:Run(15)
		expectDecision(first, GRANTED)
		expectDecision(dispatch(server, receipt(BUYER)), GRANTED)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER).Coins).to.equal(100)
	end)

	it("waits when the player is present before OnPlayerAdded creates an entry", function()
		local uni, server, grants = build()
		local player = FakePlayer.new(BUYER)
		player.Parent = server.Bundle.Players
		server._players[BUYER] = player
		server._playerCount = 1
		local result = dispatch(server, receipt(BUYER))
		uni:Run(2)
		expect(server.Bundle.Ctx.Persistence.EntryFor(player)).to.equal(nil)
		expect(result.Done).to.equal(false)
		expect(persisted(BUYER)).to.equal(nil)

		uni.Sched:Spawn(function()
			server.Bundle.Ctx.Persistence.OnPlayerAdded(player)
		end)
		uni:Run(15)
		expectDecision(result, GRANTED)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER).Coins).to.equal(100)
	end)

	it("does not hold another player's ready receipt behind a slow load", function()
		local uni, server, grants = build()
		local gate = pauseLoad(server, BUYER)
		server:Join(BUYER + 1, FakePlayer.new(BUYER + 1))
		uni:Run(2)
		server:Join(BUYER, FakePlayer.new(BUYER))
		local slow = dispatch(server, receipt(BUYER))
		local other = dispatch(server, receipt(BUYER + 1))
		uni:Run(15)
		expectDecision(other, GRANTED)
		expect(slow.Done).to.equal(false)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER + 1).Coins).to.equal(100)

		gate.Release()
		uni:Run(15)
		expectDecision(slow, GRANTED)
		expect(grants.Count).to.equal(2)
	end)

	for _, ending in { "leave", "load failure", "stop" } do
		it(`does not grant when waiting ends through {ending}`, function()
			local uni, server, grants = build()
			local gate = pauseLoad(server, BUYER, ending == "load failure")
			server:Join(BUYER, FakePlayer.new(BUYER))
			local result = dispatch(server, receipt(BUYER))
			expect(result.Done).to.equal(false)
			if ending == "leave" then
				server:Leave(BUYER)
			elseif ending == "stop" then
				server.Bundle.Data.Stop()
			end
			gate.Release()
			uni:Run(125)
			expectDecision(result, RETRY)
			expect(grants.Count).to.equal(0)
			local saved = persisted(BUYER)
			expect(saved == nil or saved.Coins == 0).to.equal(true)
		end)
	end

	it("times out without granting and allows a later receipt retry", function()
		local uni, server, grants = build({ LoadTimeout = 60, LoadFailurePolicy = "Wait" })
		local initThread
		server.Bundle.Options.OnPlayerInit = function()
			initThread = coroutine.running()
			coroutine.yield()
		end
		local player = FakePlayer.new(BUYER)
		server:Join(BUYER, player)
		uni:Run(2)
		local result = dispatch(server, receipt(BUYER))
		uni:Run(59)
		expect(result.Done).to.equal(false)
		uni:Run(2)
		expectDecision(result, RETRY)
		expect(grants.Count).to.equal(0)

		uni.Sched:Resume(initThread)
		uni:Run(2)
		expect(server.Bundle.Data.GetState(player)).to.equal("Ready")
		local retry = dispatch(server, receipt(BUYER))
		uni:Run(15)
		expectDecision(retry, GRANTED)
		expect(grants.Count).to.equal(1)
		expect(persisted(BUYER).Coins).to.equal(100)
	end)

	for _, case in { { Limit = 120 }, { Option = 5, Limit = 60 }, { Option = 180, Limit = 180 } } do
		it(`bounds the wait at {case.Limit}s for LoadTimeout {tostring(case.Option)}`, function()
			local initThread
			local uni, server, grants = build({
				LoadTimeout = case.Option,
				OnPlayerInit = function()
					initThread = coroutine.running()
					coroutine.yield()
				end,
			})
			server:Join(BUYER, FakePlayer.new(BUYER))
			uni:Run(2)
			local result = dispatch(server, receipt(BUYER))
			uni:Run(case.Limit - 1)
			expect(result.Done).to.equal(false)
			uni:Run(2)
			expectDecision(result, RETRY)
			expect(grants.Count).to.equal(0)
			uni.Sched:Resume(initThread)
			uni:Run(2)
		end)
	end

	it("does not turn a pre-registration wait into an offline grant after Stop", function()
		local uni, server, grants = build()
		local player = FakePlayer.new(BUYER)
		player.Parent = server.Bundle.Players
		server._players[BUYER] = player
		server._playerCount = 1
		local result = dispatch(server, receipt(BUYER))
		expect(result.Done).to.equal(false)
		server.Bundle.Data.Stop()
		uni:Run(125)
		expectDecision(result, RETRY)
		expect(grants.Count).to.equal(0)
		expect(persisted(BUYER)).to.equal(nil)
	end)

	it("releases the in-flight receipt when WaitForData raises", function()
		local uni, server, grants = build()
		local gate = pauseLoad(server, BUYER)
		server:Join(BUYER, FakePlayer.new(BUYER))
		local persistence = server.Bundle.Ctx.Persistence
		local waitForData = persistence.WaitForData
		persistence.WaitForData = function()
			error("wait failed")
		end
		local failed = dispatch(server, receipt(BUYER))
		expect(failed.Done).to.equal(true)
		expect(failed.Ok).to.equal(false)
		expect(string.find(tostring(failed.Value), "wait failed", 1, true) ~= nil).to.equal(true)

		persistence.WaitForData = waitForData
		local retry = dispatch(server, receipt(BUYER))
		expect(retry.Done).to.equal(false)
		gate.Release()
		uni:Run(15)
		expectDecision(retry, GRANTED)
		expect(grants.Count).to.equal(1)
	end)
end
