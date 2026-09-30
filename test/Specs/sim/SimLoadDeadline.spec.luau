--!nonstrict
-- Scribe's own deadline on a session load, and why one is needed at all.
--
-- ProfileStore already has a session-load timeout. It is disabled by accident,
-- and Scribe is what disables it: the timeout applies only `if params.Cancel ==
-- nil`, and Scribe always passes a Cancel closure. So the hook meant to BOUND the
-- load is exactly what unbounds it, and during a real DataStore outage
-- StartSessionAsync never returns. Everything below that call -- the
-- PROFILE_LOAD_FAIL log, the ProfileLoadFailures metric, LoadFailurePolicy itself
-- -- was unreachable code during the one incident it exists for.
--
-- THESE HAVE TO BE SIM SPECS. Every existing test that reaches LoadFailurePolicy
-- does so through a synthetic fast-nil or a thrown error that the real library
-- never produces during an outage, which is exactly how the gap survived 903
-- tests. Only the simulation runs the unmodified vendored ProfileStore over a
-- disk that can actually fail.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Universe = require(Root.Test.Sim.Universe)
local Guard = require(Root.Test.Sim.Guard)
-- Sim-backed: every node below needs a simulated universe, which only the headless
-- runner can build. Under Studio they report SKIP instead of each failing with the
-- same missing capability -- see test/Sim/Available for why it cannot be provided.
local runIt = if require(Root.Test.Sim.Available).Ready then it else it.skip
local StubTransport = require(Root.Test.Helpers.StubTransport)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

-- Production values. The deadline has to be reasoned about against the REAL
-- session-conflict path, so shortening those constants here would hide the
-- interaction the floor exists to protect.
local PRODUCTION = {
	AUTO_SAVE_PERIOD = 300,
	SESSION_STEAL = 40,
	FIRST_LOAD_REPEAT = 5,
	LOAD_REPEAT_PERIOD = 10,
	ASSUME_DEAD = 630,
	START_SESSION_TIMEOUT = 120,
}

local universe

local function build(overrides)
	local config = {
		Seed = 90210,
		Servers = 1,
		Constants = PRODUCTION,
		Transport = StubTransport.new({ AutoPump = false }),
		LatencyProfile = "Nominal",
		NoBudget = true,
		-- Far out of reach: an Outage status gates receipts, gifts and restores,
		-- and this spec is about the load path, not about Health.
		StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Options = {},
	}
	for key, value in overrides or {} do
		config[key] = value
	end
	universe = Universe.new(config)
	Guard.Install(universe)
	return universe
end

afterEach(function()
	Guard.Reset()
	universe = nil
end)

describe("a load that cannot complete", function()
	runIt("gives up after the deadline, making LoadFailurePolicy reachable", function()
		-- Without a Scribe-owned deadline this player waits in Loading for the
		-- entire outage, however long it lasts.
		local uni = build({ Options = { LoadTimeout = 60 } })
		local server = uni:Server(1)
		uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })

		local player = FakePlayer.new(4101)
		server:Join(4101, player)

		-- Well into the outage but short of the deadline: still trying, because
		-- a deadline that fired early would break ordinary handoffs.
		uni:Run(30)
		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("Loading")
		expect(`kicked={player.Kicked}`).toBe("kicked=nil")

		-- Past it, but still short of the 120s DEFAULT: the run stops at ~95s, so
		-- this only passes if the configured 60 was actually used. Allowing 35s
		-- past the deadline is deliberate -- ProfileStore only re-checks Cancel at
		-- its retry-loop head, whose backoff caps at 20s.
		uni:Run(65)

		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("SessionEnded")
		expect(server.Bundle.Ctx.Persistence.EntryFor(player)).toBe(nil)
		-- The default policy is Kick, and it finally happens. Asserted on the
		-- MESSAGE, because FakePlayer stores the reason rather than a flag --
		-- `never.to.equal(true)` would have been vacuous in the negative cases
		-- above, since a kicked player holds a string that is also never `true`.
		expect(player.Kicked).toBe("We couldn't load your data. Please rejoin!")
		-- The load-scoped telemetry that was dead code during an outage.
		expect((server.Bundle.Scribe.GetMetrics().ProfileLoadFailures or 0) > 0).toBe(true)
		expect(#server.Bundle.Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Limit = 5 }) > 0).toBe(true)
	end)

	runIt("measures the deadline on the monotonic clock, not on wall time", function()
		-- Wall time can jump: a machine clock correction moves it forwards or
		-- backwards, and a deadline read from it would fire early or never. The
		-- monotonic clock cannot. Separated here by freezing Now while virtual
		-- time keeps advancing -- if the deadline consulted Now, it would never
		-- come due and this player would wait out the whole outage.
		local uni = build({ Options = { LoadTimeout = 60 } })
		local server = uni:Server(1)
		local frozen = server.Bundle.Clock.Now()
		server.Bundle.Clock.Install({
			Now = function()
				return frozen
			end,
		})
		uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })

		local player = FakePlayer.new(4106)
		server:Join(4106, player)
		uni:Run(150)

		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("SessionEnded")
	end)

	runIt("keeps retrying under the Wait policy instead of ending the session", function()
		-- "Wait" promises never to fall back to template data on a live account.
		-- The deadline must not turn that into a kick; it turns one endless park
		-- into a visible retry cycle, so the outer attempt counter finally moves.
		local uni = build({ Options = { LoadTimeout = 60, LoadFailurePolicy = "Wait" } })
		local server = uni:Server(1)
		uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })

		local player = FakePlayer.new(4102)
		server:Join(4102, player)
		uni:Run(400)

		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("Loading")
		expect(`kicked={player.Kicked}`).toBe("kicked=nil")
		-- More than one attempt has now been reported, which is the whole
		-- difference: before the deadline there was exactly one, forever.
		local logs = server.Bundle.Scribe.GetRecentLogs({ Code = "PROFILE_LOAD_FAIL", Limit = 20 })
		expect(`attempts={#logs > 1}`).toBe("attempts=true")
	end)

	runIt("recovers normally once the outage clears", function()
		-- The liveness half. A deadline that abandoned its load thread inside
		-- ProfileStore's retry would leave the session unrecoverable.
		local uni = build({ Options = { LoadTimeout = 60, LoadFailurePolicy = "Wait" } })
		local server = uni:Server(1)
		uni.Disk:Arm({ Kind = "ServiceError", Count = 100000 })

		local player = FakePlayer.new(4103)
		server:Join(4103, player)
		uni:Run(150)
		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("Loading")

		uni.Disk:Heal()
		uni:Run(200)

		expect((server.Bundle.Ctx.Persistence.GetState(player))).toBe("Ready")
		expect(uni.Sched.Deadlocked).never.toBe(true)
	end)
end)

describe("a load that is merely slow", function()
	runIt("does not abort a legitimate cross-server handoff", function()
		-- The regression the 60s floor exists to prevent, and the reason the
		-- default is 120 rather than something brisk. A handoff is not a
		-- failure: the second server force-loads, polls, and STEALS the session
		-- after SESSION_STEAL (40s). A deadline under that would abort every one
		-- of them and turn an ordinary rejoin into a kick.
		local uni = build({ Servers = 2, Options = { LoadTimeout = 60 } })
		local a, b = uni:Server(1), uni:Server(2)

		local first = FakePlayer.new(4104)
		a:Join(4104, first)
		uni:Run(10)
		expect((a.Bundle.Ctx.Persistence.GetState(first))).toBe("Ready")

		-- The same user arrives on another server while the first still holds
		-- the lock. This takes tens of seconds by design.
		local second = FakePlayer.new(4104)
		b:Join(4104, second)
		uni:Run(120)

		expect((b.Bundle.Ctx.Persistence.GetState(second))).toBe("Ready")
		expect(`kicked={second.Kicked}`).toBe("kicked=nil")
	end)

	runIt("floors a too-short LoadTimeout rather than honouring it", function()
		-- A game that asked for a 5s deadline would break every handoff above.
		-- The floor is applied silently because the option is new: nobody's
		-- existing configuration changes meaning.
		local uni = build({ Servers = 2, Options = { LoadTimeout = 5 } })
		local a, b = uni:Server(1), uni:Server(2)

		local first = FakePlayer.new(4105)
		a:Join(4105, first)
		uni:Run(10)

		local second = FakePlayer.new(4105)
		b:Join(4105, second)
		uni:Run(120)

		expect((b.Bundle.Ctx.Persistence.GetState(second))).toBe("Ready")
		expect(`kicked={second.Kicked}`).toBe("kicked=nil")
	end)
end)
