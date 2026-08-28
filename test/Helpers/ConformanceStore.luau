--!nonstrict
-- Which ProfileStore implementation the conformance suite runs against.
--
-- The suite exists to catch FakeProfileStore drifting from the store Scribe
-- actually ships. It is written once and run twice: headless under Lune against the
-- fake (every CI run), and in Studio against the real store and real DataStores
-- (before a release). An assertion that passes on one and fails on the other is a
-- fidelity bug, which is the class that has twice hidden a live defect: a view
-- reporting the wrong SessionLoadCount (which silently skipped every migration in a
-- dry run) and SetAsync throwing on failure (which let Scribe bank a Robux grant
-- that never persisted).
--
-- "REAL" MEANS THE VENDORED FORK, src/Internal/Store, and that changed with it.
-- This used to require ServerPackages.ProfileStore, which was upstream 1.0.3 pulled
-- in by Wally. That entry is gone -- Scribe owns its store now -- so pointing there
-- would either fail outright or, worse, succeed against a stale checkout and check
-- the fake against a build nobody ships. The fork is the real implementation, and
-- checking it against real DataStores is the thing this arm is for.
--
-- To run against the real library in Studio, build test.project.json, then set
--     require(<this module>).UseReal = true
-- before the test runner starts (top of test/RunTests.server.luau).
local Root = script.Parent.Parent.Parent

local ConformanceStore = {}

-- Flipped by the Studio runner. A plain module field rather than a global, so it
-- works identically under Lune and in Roblox with no environment assumptions.
ConformanceStore.UseReal = false

function ConformanceStore.IsReal(): boolean
	return ConformanceStore.UseReal == true
end

-- Returns (store, label). `store` is a ProfileStore-shaped module exposing .New.
function ConformanceStore.get(): (any, string)
	if ConformanceStore.IsReal() then
		local ok, real = pcall(function()
			return require(Root.Scribe.Internal.Store)
		end)
		if ok and real then
			return real, "real"
		end
		error("ConformanceStore.UseReal is set but src/Internal/Store could not be required")
	end
	return require(Root.Test.Helpers.FakeProfileStore).new(), "fake"
end

-- THE TWO ARMS, AND WHY THIS IS NOT `UseReal` ANY MORE.
--
-- `UseReal` was a Studio-only switch that defaulted off, so in CI this suite
-- compared the fake against the fake -- every run proving only that
-- FakeProfileStore is consistent with itself, which is the one thing that cannot
-- drift. It was off for the whole of the previous two tiers.
--
-- Flipping the default was not possible, and that is worth stating precisely
-- rather than leaving as folklore: the real branch is a plain `require` of the
-- harness module tree, and under Lune that dies at ProfileStore.luau's
-- `game:GetService("MessagingService")` -- the headless shim registers ten
-- services and that is not one of them. The `pcall` around the require turned
-- that into "could not be required" rather than a stack trace, which is part of
-- why it stayed unexamined.
--
-- The route that DOES work already exists twice in the repo and is not invented
-- here: `test/Specs/StoreAccessors.spec.luau` builds a one-server `Universe` and
-- reaches in for the store module that server loaded, and `test/Sim/Server.luau`
-- loads it with `Loader.LoadChunk(Loader.Source("src/Internal/Store/..."), env)`
-- into an environment from `test/Sim/Env.luau`, which supplies a real
-- MessagingService over `test/Sim/Bus`. `forkArm` below takes exactly that route.
--
-- WHAT AN ARM HAS TO PROVIDE, AND WHY IT IS MORE THAN A STORE. The two
-- implementations do not merely differ in behaviour, they differ in what TIME
-- means. The fake yields on the harness's `task.wait` and real seconds; the fork
-- yields on a modelled disk driven by a virtual scheduler that only advances
-- inside `uni:Run(...)`, and its calls must originate on a scheduler thread. So a
-- store handle alone is not enough to run one suite against both: the suite's
-- waiting has to be the arm's waiting. Hence `Run`, `Wait` and `Until`, and hence
-- the rule that every test body runs inside `Run`.
--
-- That is also why the spec no longer calls `task.wait` or `os.clock` directly.
-- It cannot: those are harness time, and against the fork arm they would block a
-- thread nothing is driving and surface as the runner's 10 s timeout -- a failure
-- mode that proves nothing (TIER-A-HANDOFF.md 3.6).

local ARM_BUDGET = 600 -- virtual seconds a single fork-arm test body may consume

local function fakeArm()
	local module = require(Root.Test.Helpers.FakeProfileStore).new()
	local ctx = {}
	ctx.Name = "fake"
	ctx.Module = module
	ctx.Store = module.New(ConformanceStore.STORE, { Coins = 0 })
	function ctx.Run(body: () -> ())
		body()
	end
	function ctx.Wait(seconds: number?)
		task.wait(seconds)
	end
	function ctx.Until(predicate: () -> boolean, budget: number)
		local deadline = os.clock() + budget
		while not predicate() and os.clock() < deadline do
			task.wait(0.1)
		end
	end
	function ctx.Finish() end
	return ctx
end

local function forkArm()
	local Scribe = require(Root.Scribe) :: any
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	-- Same constants StoreAccessors uses, for the same reason: a store contract
	-- test wants the store's own behaviour, not an autosave racing it.
	local uni = Universe.new({
		Seed = 4242,
		Servers = 1,
		Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
		Transport = StubTransport.new({ AutoPump = false }),
		LatencyProfile = "Instant",
		NoBudget = true,
		StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Options = {},
	})
	Guard.Install(uni)

	local module = uni:Server(1).Bundle.Options.ProfileStore
	local ctx = {}
	ctx.Name = "fork"
	ctx.Universe = uni
	ctx.Module = module
	ctx.Store = module.New(ConformanceStore.STORE, { Coins = 0 })

	--- Run the whole body on a scheduler thread and pump until it finishes.
	---
	--- The error is re-raised rather than swallowed, and `Done` is set before it is
	--- re-raised: a body that throws must fail on ITS assertion, not on "never
	--- settled", or every real failure in this arm would read as a harness problem.
	function ctx.Run(body: () -> ())
		local done, failure = false, nil
		uni.Sched:Spawn(function()
			local ok, err = pcall(body)
			done = true
			if not ok then
				failure = err
			end
		end)
		local spent = 0
		while not done and spent < ARM_BUDGET do
			uni:Run(10)
			spent += 10
		end
		if not done then
			error(`conformance (fork arm): body never settled within {ARM_BUDGET} virtual seconds`, 2)
		end
		if failure ~= nil then
			error(failure, 0)
		end
	end

	function ctx.Wait(seconds: number?)
		uni.Sched:Wait(seconds or 0)
	end

	function ctx.Until(predicate: () -> boolean, budget: number)
		local deadline = uni.Sched.Now + budget
		while not predicate() and uni.Sched.Now < deadline do
			uni.Sched:Wait(0.1)
		end
	end

	function ctx.Finish()
		Guard.Reset()
	end

	return ctx
end

--- The arms this suite runs, in order. Both run in CI, on every change.
---
--- The fake arm is first and is the fast one; the fork arm is the one that can
--- catch drift, because the fake cannot disagree with itself. Measured cost of
--- adding the second arm is recorded in TIER-B-PROGRESS.md.
---
--- `Ready` is what the spec reads to decide between `it` and `itSKIP`, and it is
--- decided HERE rather than in the spec because this is where the dependency lives:
--- forkArm's route to the real store is a `Universe`, and a universe needs the
--- headless runner (test/Sim/Available). Under Studio the fork arm cannot be built
--- at all, so its twenty nodes report SKIP; the fake arm's twenty still run, which
--- is the half a Studio session can honestly check. Under Lune both are true and
--- nothing changes.
function ConformanceStore.arms(): { { Name: string, Ready: boolean, New: () -> any } }
	local simReady = require(Root.Test.Sim.Available).Ready
	return {
		{ Name = "fake", Ready = true, New = fakeArm },
		{ Name = "fork", Ready = simReady, New = forkArm },
	}
end

-- A key namespace that is safe to write to. Against the real library this touches a
-- real DataStore, so it is deliberately its own store name and prefix.
ConformanceStore.STORE = "ScribeConformance"
ConformanceStore.PREFIX = "CONF_"

-- Roblox refuses repeated writes to the same key at roughly one per six seconds.
-- Persistence.luau names the same number. Seven because the limit is approximate and a
-- rejected write costs a retry with backoff.
ConformanceStore.KEY_WRITE_WINDOW = 7

--- Let the write window on a key clear before writing to it again.
---
--- Not the same limit as AwaitBudget. A 502 "Too many requests" is the BACKEND refusing;
--- exhausting the client-side allowance makes a call queue and yield, never throw, so
--- pacing on the request budget does not prevent one. The real-backend specs were making
--- four writes to one key inside two seconds and died on it.
---
--- The logs do not cleanly separate a per-key limit from a place-wide one. Both want
--- fewer writes and more space between them, which is what this and the shared round
--- trips in ExchangeRealBackend do.
function ConformanceStore.AwaitKeyWindow(seconds: number?)
	task.wait(seconds or ConformanceStore.KEY_WRITE_WINDOW)
end

--- Wait until the engine has room for roughly `needed` more UpdateAsync requests.
---
--- The client-side allowance only, and the lesser limit here. It refills at about
--- (60 + 10 * players) per minute for the whole server rather than per DataStore, so a
--- Studio plugin polling its own store competes for it.
---
--- Returns the budget last seen, or -1 when the engine cannot be asked, which is every
--- headless run. Never blocks then: treating "cannot ask" as "none left" would hang CI.
function ConformanceStore.AwaitBudget(needed: number, timeout: number?): number
	local Budget = require(Root.Scribe.Internal.Budget)
	local deadline = os.clock() + (timeout or 90)
	local seen = Budget.Remaining("UpdateAsync")
	if seen == nil then
		return -1
	end
	while seen < needed and os.clock() < deadline do
		task.wait(1)
		local now = Budget.Remaining("UpdateAsync")
		if now == nil then
			return -1
		end
		seen = now
	end
	return seen
end

return ConformanceStore
