--!nonstrict
-- What Scribe's own shutdown drain costs, measured on a clock that cannot lie.
--
-- The drain is the one production path the simulation could not previously reach:
-- a bundle is built with Server.build, and BindToClose is wired in Server.new, so
-- Server.Stop has only ever run ProfileStore's handler. Server.Drain runs Scribe's
-- and reports how long the call itself took in virtual seconds -- read inside the
-- drain thread at the instant Shutdown returns, because the scheduler's own run
-- bound would otherwise be the number a spec was measuring.
--
-- Virtual time is what makes this an assertion rather than a stopwatch. A hook
-- that waits three tenths of a second costs zero real milliseconds here, so
-- twenty players' worth of them is a number the spec can state exactly.

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
	-- The BUNDLE's clock, which is the simulated one. Requiring Clock from the spec
	-- would get the process-wide copy and turn every hook wait into a real sleep --
	-- and, worse, an unnoticed one: the hook runs under a pcall, so a hook that
	-- reaches for a clock that is not there yet is swallowed as a LISTENER_ERROR
	-- and the spec measures a drain with no hook in it.
	local simClock

	--- A one-server universe whose leaving hook waits `hookSeconds` of virtual time.
	local function build(hookSeconds: number?, hook)
		local options = {}
		if hook then
			options.OnPlayerLeaving = hook
		elseif hookSeconds then
			options.OnPlayerLeaving = function()
				simClock.Wait(hookSeconds)
			end
		end
		universe = Universe.new({
			Seed = 8811,
			Servers = 1,
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = options,
		})
		Guard.Install(universe)
		local server = universe:Server(1)
		simClock = server.Bundle.Clock
		return universe, server
	end

	local function join(uni, server, n: number): { any }
		local players = {}
		for i = 1, n do
			local userId = 88000 + i
			local player = FakePlayer.new(userId)
			table.insert(players, player)
			server:Join(userId, player)
		end
		uni:Run(2)
		return players
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	it("costs one scheduler tick with no hook to run, however many players", function()
		-- The control arm, and a claim in its own right. It is tempting to read the
		-- drain's closing `while next(Entries) ~= nil` as a wait for the final saves;
		-- it is not one. Ending a session tears its entry down synchronously, inside
		-- EndSession and before its first yield, so that loop's condition is already
		-- false when it is reached. What the budget funds is the hook phase and the
		-- leaderboard flush.
		--
		-- This used to assert exactly zero. It is now one tick, and the extra tick is
		-- the point rather than a regression: the drain hands back to the store at the
		-- end (AwaitClose) to wait for the saves its releases started. That wait used
		-- to happen in the store's OWN BindToClose, running concurrently -- which is
		-- exactly the race that cost every leaving hook when the store won it. Same
		-- total shutdown time; it is inside the measurement now instead of beside it.
		--
		-- What matters is that it is CONSTANT, so both populations are asserted: a
		-- per-player cost here would be the thing that blows the 30s window.
		local uni, server = build(nil)
		join(uni, server, 10)
		local ten = server:Drain(25)

		Guard.Reset()
		local uni2, server2 = build(nil)
		join(uni2, server2, 1)
		local one = server2:Drain(25)

		expect(`ten={ten} one={one}`).to.equal(`ten={one} one={one}`)
		expect(ten < 0.05).to.equal(true)
	end)

	it("does not charge one hook's wait per player", function()
		-- Ten players, three tenths of a second each. Serially that is three
		-- seconds, which overruns the budget the drain was handed; concurrently it
		-- is one hook's wait plus the granularity of the join poll.
		local uni, server = build(0.3)
		join(uni, server, 10)

		local elapsed = server:Drain(2)

		-- Bounded on BOTH sides deliberately. An upper bound alone would be
		-- satisfied by a harness that reported nothing, or by a drain that skipped
		-- the hooks entirely; the lower bound says one hook's wait really was paid.
		expect(`elapsed={elapsed ~= nil and elapsed >= 0.3 and elapsed <= 0.4}`).to.equal("elapsed=true")
	end)

	it("still gets every player's hook run, and their data saved", function()
		-- Concurrency that dropped hooks would pass the timing spec above and be
		-- worthless. Both halves have to hold at once.
		local ran = 0
		local uni, server = build(nil, function(_player, data)
			ran += 1
			data.Coins.Increment(5)
			simClock.Wait(0.3)
		end)
		local players = join(uni, server, 10)
		for _, player in players do
			server.Bundle.Data.Get(player).Coins.Set(20)
		end
		uni:Run(1)

		local elapsed = server:Drain(2)
		uni:Run(5) -- let the final saves land

		expect(`ran={ran}`).to.equal("ran=10")
		expect(`elapsed={elapsed ~= nil and elapsed >= 0.3 and elapsed <= 0.4}`).to.equal("elapsed=true")
		for _, player in players do
			local record = uni.Disk.Keyspace:Read("Default", `PLAYER_{player.UserId}`)
			-- 25, not 20: the hook's increment reached the final save, on every one
			-- of ten sessions ending at once.
			expect(`{player.UserId} coins={record and record.Value.Data.Coins}`).to.equal(`{player.UserId} coins=25`)
		end
	end)

	it("stops waiting on hooks that outlast the budget", function()
		-- No amount of concurrency helps against a hook that simply does not come
		-- back. The drain has to give up on it and save without the rest of its
		-- writes, or one player's `task.wait` holds the closing server open for
		-- everybody.
		local uni, server = build(30)
		join(uni, server, 3)

		local elapsed = server:Drain(4)

		-- Three quarters of a four second budget is three seconds, and that is what
		-- the drain should spend before giving up -- not thirty, and not nothing.
		expect(`elapsed={elapsed ~= nil and elapsed >= 2.5 and elapsed <= 3.5}`).to.equal("elapsed=true")
		expect(`timedOut={server.Bundle.Scribe.GetMetrics().LeavingHooksTimedOut}`).to.equal("timedOut=3")
	end)
end
