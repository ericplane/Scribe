--!nonstrict
-- Shutdown runs TWO BindToClose handlers, and they race.
--
-- Scribe registers one during Scribe() construction (Server/init.luau, via
-- BindShutdown). ProfileStore registers its own at module scope, but behind
-- `while DataStoreState == "NotReady" do task.wait() end` -- so on a real server
-- Scribe lands first, by accident of a DataStore round trip rather than by design.
--
-- The accident matters because the two handlers want opposite things in the same
-- instant. Scribe's drain snapshots the entries whose profile is still
-- `IsActive()` and runs each player's OnPlayerLeaving hook before ending the
-- session. ProfileStore's handler immediately spawns SaveProfileAsync(profile,
-- true, ...) for every active profile, and that calls RemoveProfileFromAutoSave --
-- which is what makes IsActive() false -- synchronously, before any DataStore
-- call. Whoever runs first wins outright, because neither yields before it has
-- claimed what it needs.
--
-- Roblox does not document the order it invokes bound callbacks in. So the
-- invariant is not "Scribe goes first"; it is "the leaving hooks run either way",
-- and both orders are asserted here. A game that constructs Scribe lazily -- after
-- an async init, on first join, behind a flag -- gets the other order.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local universe
	local hookRuns

	local function build()
		hookRuns = 0
		universe = Universe.new({
			Seed = 4242,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {
				-- The hook writes, because "the hook ran" is only half the promise.
				-- A hook that runs after the session has been saved and released has
				-- not done anything, and a spec that only counted invocations would
				-- call that a pass.
				OnPlayerLeaving = function(_player, data)
					hookRuns += 1
					data.Coins.Set(777)
				end,
			},
		})
		Guard.Install(universe)
		return universe, universe:Server(1)
	end

	local function join(uni, server, n: number)
		for i = 1, n do
			local userId = 42000 + i
			server:Join(userId, FakePlayer.new(userId))
		end
		uni:Run(2)
	end

	--- What actually reached the disk for every player, from the modelled store.
	local function persistedCoins(uni): { number }
		local out = {}
		for _, entry in uni.Disk.Keyspace:Each() do
			local value = entry.Record.Value
			if type(value) == "table" and type(value.Data) == "table" and value.Data.Coins ~= nil then
				table.insert(out, value.Data.Coins)
			end
		end
		table.sort(out)
		return out
	end

	local function allEqual(values: { number }, expected: number): boolean
		for _, v in values do
			if v ~= expected then
				return false
			end
		end
		return #values > 0
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("both BindToClose handlers run", function()
		-- CONTROL: the order production happens to get today.
		it("runs every leaving hook, and persists its write, with Scribe first", function()
			local uni, server = build()
			join(uni, server, 5)

			server:Close(25, true)

			expect(hookRuns).to.equal(5)
			local coins = persistedCoins(uni)
			expect(#coins).to.equal(5)
			expect(allEqual(coins, 777)).to.equal(true)
		end)

		-- THE RACE: the order a lazily-constructed Scribe gets.
		--
		-- This FAILED until Scribe took shutdown over from the store, and it is the
		-- acceptance test for that work. Measured before: hookRuns was 0 -- not "the
		-- hooks ran and their writes were lost", but none ran at all, because the
		-- store's handler calls RemoveProfileFromAutoSave synchronously inside
		-- SaveProfileAsync, so every profile was already inactive when the drain
		-- built `draining` from IsActive(), and an empty list skips nothing.
		--
		-- The fix is not to win the race but to stop having one: the store's own
		-- BindToClose stands down (ProfileStore.ExternalShutdown, set in
		-- Persistence.new) and Scribe's drain drives BeginClose -> hooks -> end
		-- sessions -> AwaitClose in one handler. Order is then Scribe's to choose
		-- rather than Roblox's to decide, which is why both arms below now pass.
		it("runs every leaving hook, and persists its write, with ProfileStore first", function()
			local uni, server = build()
			join(uni, server, 5)

			server:Close(25, false)

			expect(hookRuns).to.equal(5)
			local coins = persistedCoins(uni)
			expect(#coins).to.equal(5)
			expect(allEqual(coins, 777)).to.equal(true)
		end)
	end)
end
