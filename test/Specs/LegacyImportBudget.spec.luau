--!nonstrict
-- Pacing a migration on the DataStore request budget.
--
-- A game adopting Scribe may read several legacy stores for one joining player: a main
-- store, a sharded copy, a board per OrderedDataStore. Twenty joiners doing that at once
-- throttle each other and everything else on the server. Without a queue they also poll
-- independently, so the allowance frees by three and all twenty fire, which is the herd
-- the hook is trying to escape.
--
-- Two properties carry the design and both are easy to lose in a refactor: a `nil`
-- budget GRANTS (it means "could not ask", and reading it as an empty allowance parks
-- every caller for the life of the process), and the queue is strictly FIFO (a large
-- request must not be overtaken by a small one, or a big migration never runs).

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Budget = require(ScribeRoot.Internal.Budget)
	local Sched = require(ScribeRoot.Internal.Sched)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }

	--- Drive the pump against a budget this spec owns. Returns a setter.
	local function fakeBudget(initial: number)
		local value = initial
		Budget.SetProbe(function()
			return value
		end)
		return function(new: number?)
			value = new
			return value
		end
	end

	--- Run `fn` on its own thread and report what it returned, without blocking here.
	local function spawnAwait(out: { any }, label: string, requestType: string, count: number?, timeout: number?)
		Sched.Spawn(function()
			local granted = Budget.Await(requestType, count, timeout)
			table.insert(out, `{label}={tostring(granted)}`)
		end)
	end

	afterEach(function()
		Budget.Reset()
	end)

	describe("Budget.Await", function()
		it("GRANTS when the engine cannot be asked, rather than parking forever", function()
			-- The single most important behaviour here. A headless server, or one with API
			-- access off, answers nil to every budget question; treating that as an empty
			-- allowance strands every migration for the life of the process.
			Budget.SetProbe(function()
				return nil
			end)
			expect(Budget.Await("GetAsync", 50)).to.equal(true)
		end)

		it("grants immediately when there is room", function()
			fakeBudget(100)
			expect(Budget.Await("GetAsync", 3)).to.equal(true)
		end)

		it("respects a reserve, so Scribe's own traffic keeps headroom", function()
			fakeBudget(10)
			Budget.SetReserve("GetAsync", 8)
			-- 10 remaining, 8 held back: 2 spare, so 5 must wait rather than be granted.
			local out = {}
			spawnAwait(out, "big", "GetAsync", 5, 0)
			expect(table.concat(out, ",")).to.equal("big=false")
		end)

		it("returns false on timeout without parking", function()
			fakeBudget(0)
			local out = {}
			spawnAwait(out, "a", "GetAsync", 1, 0)
			expect(table.concat(out, ",")).to.equal("a=false")
		end)

		it("debits a ledger, so two grants off one reading cannot both take it", function()
			-- Budget.Remaining reads the ENGINE, which has not moved between granting the
			-- first caller and that caller issuing its request. Without the ledger the
			-- second grant reads the same number and the herd returns in miniature.
			fakeBudget(4)
			local first = Budget.Await("GetAsync", 3)
			local out = {}
			spawnAwait(out, "second", "GetAsync", 3, 0)
			expect(`first={tostring(first)} {table.concat(out, ",")}`).to.equal("first=true second=false")
		end)
	end)

	describe("releasing a grant", function()
		-- Budget.Remaining reads the ENGINE, which has not moved between a grant and that
		-- caller issuing its request, so a grant is held against the ledger until it is
		-- presumed spent. The timer doing that has to assume the worst, because how long
		-- a hook takes to reach its reads is the hook's business. A release replaces the
		-- guess with the fact.

		it("retires the grant IMMEDIATELY, without waiting the presumed-unspent window", function()
			fakeBudget(4)
			local first, release = Budget.Await("GetAsync", 4)
			release()
			-- The engine reading has not moved, so this only fits if the first grant did.
			local second = Budget.Await("GetAsync", 4)
			expect(`first={first} second={second}`).to.equal("first=true second=true")
		end)

		it("still falls back to the TIMER for a hook that never releases", function()
			-- A hook that forgets must not spend the same allowance twice.
			fakeBudget(4)
			Budget.Await("GetAsync", 4)
			local out = {}
			spawnAwait(out, "second", "GetAsync", 4, 0)
			expect(table.concat(out, ",")).to.equal("second=false")
		end)

		it("releases ITS OWN grant, never whichever happens to be first", function()
			-- The SECOND grant, with different counts, on purpose: releasing the first by
			-- index looks identical to releasing it by identity, and proves nothing.
			fakeBudget(4)
			local _, releaseSmall = Budget.Await("GetAsync", 1)
			local _, releaseBig = Budget.Await("GetAsync", 2)
			releaseBig()
			releaseBig()
			-- Crediting the wrong entry leaves two outstanding, and then three does not fit.
			local out = {}
			spawnAwait(out, "wantsFour", "GetAsync", 4, 0)
			spawnAwait(out, "wantsThree", "GetAsync", 3, 0)
			expect(table.concat(out, ",")).to.equal("wantsFour=false,wantsThree=true")
			expect(typeof(releaseSmall)).to.equal("function")
		end)

		it("releases a grant that came through the QUEUE, not just the fast path", function()
			-- Two places hand out grants, the uncontended check inside Await and the pump,
			-- and they record the release differently.
			local set = fakeBudget(0)
			local out = {}
			Sched.Spawn(function()
				local granted, release = Budget.Await("GetAsync", 4, 30)
				if granted then
					release()
				end
				table.insert(out, `queued={tostring(granted)}`)
			end)
			set(4)
			for _ = 1, 12 do
				task.wait(0.2)
				if #out > 0 then
					break
				end
			end
			-- The engine still reads 4, so this only fits if the queued grant was retired.
			local after = Budget.Await("GetAsync", 4, 0)
			expect(`{table.concat(out, ",")} after={tostring(after)}`).to.equal("queued=true after=true")
		end)

		it("hands back a CALLABLE even when nothing was granted", function()
			-- So a hook can release unconditionally instead of testing for nil first.
			fakeBudget(0)
			local out = {}
			Sched.Spawn(function()
				local granted, release = Budget.Await("GetAsync", 1, 0)
				local ok = pcall(release)
				table.insert(out, `granted={tostring(granted)} callable={ok}`)
			end)
			expect(table.concat(out, ",")).to.equal("granted=false callable=true")
		end)
	end)

	describe("fairness", function()
		it("serves waiters FIRST COME FIRST SERVED", function()
			fakeBudget(0)
			local out = {}
			spawnAwait(out, "first", "GetAsync", 1, 30)
			spawnAwait(out, "second", "GetAsync", 1, 30)
			spawnAwait(out, "third", "GetAsync", 1, 30)
			expect(#out).to.equal(0) -- all three parked

			local set = fakeBudget(0)
			set(50)
			-- One pump pass per poll interval; let it drain.
			for _ = 1, 12 do
				task.wait(0.2)
				if #out >= 3 then
					break
				end
			end
			expect(table.concat(out, ",")).to.equal("first=true,second=true,third=true")
		end)

		it("does NOT let a small request overtake a large one", function()
			-- Strict FIFO is what stops a big migration never running: without it the
			-- one-request waiters behind it are granted forever and it starves.
			local set = fakeBudget(0)
			local out = {}
			spawnAwait(out, "big", "GetAsync", 10, 30)
			spawnAwait(out, "small", "GetAsync", 1, 30)
			set(3) -- enough for the small one, not the big one
			for _ = 1, 8 do
				task.wait(0.2)
				if #out > 0 then
					break
				end
			end
			expect(table.concat(out, ",")).to.equal("") -- neither: the head blocks

			set(50)
			for _ = 1, 12 do
				task.wait(0.2)
				if #out >= 2 then
					break
				end
			end
			expect(table.concat(out, ",")).to.equal("big=true,small=true")
		end)

		it("drops a cancelled waiter WITHOUT spending its allowance", function()
			-- A player leaving mid-hook. The waiter must unwind rather than park forever
			-- inside a hook that still holds the session, and the request it was queued for
			-- must go to the next waiter rather than being spent on nobody.
			local set = fakeBudget(0)
			local out = {}
			local gone = false
			Sched.Spawn(function()
				local granted = Budget.Await("GetAsync", 1, 30, nil, function()
					return gone
				end)
				table.insert(out, `head={tostring(granted)}`)
			end)
			spawnAwait(out, "next", "GetAsync", 1, 30)
			gone = true
			set(1) -- exactly one request spare, and two waiters
			for _ = 1, 12 do
				task.wait(0.2)
				if #out >= 2 then
					break
				end
			end
			-- The head unwinds false and the one spare request reaches the live waiter.
			expect(table.concat(out, ",")).to.equal("head=false,next=true")
		end)

		it("keeps the pools independent, so one exhausted queue does not block another", function()
			Budget.SetProbe(function(requestType)
				return if requestType == "GetSortedAsync" then 0 else 100
			end)
			local out = {}
			spawnAwait(out, "sorted", "GetSortedAsync", 1, 30)
			spawnAwait(out, "plain", "GetAsync", 1, 30)
			-- The plain waiter never queued at all: separate allowance, separate queue.
			expect(table.concat(out, ",")).to.equal("plain=true")
		end)
	end)

	describe("the GetSortedAsync reserve", function()
		-- Derived from the declared boards. The number that matters is not reads per
		-- second but whether a refresh tick still gets through while a migration drains
		-- the pool, which is one read per board.

		--- Join one player so syncBudgetReserves has run against `boards` leaderboards,
		--- then ask for `count` against a known allowance.
		local function grantsWith(boards: number, remaining: number, count: number): boolean
			-- Reset FIRST: a grant earlier in the same `it` is still outstanding, and would
			-- refuse the next ask for a reason that has nothing to do with reserves.
			Budget.Reset()
			local declared = {}
			for i = 1, boards do
				declared[`Board{i}`] = { Stat = "Coins", Limit = 10, RefreshInterval = 60 }
			end
			local harness = TestCtx.make({
				Template = template,
				Options = { Leaderboards = if boards > 0 then declared else nil },
			})
			harness.Join(81000 + boards)
			Budget.SetProbe(function()
				return remaining
			end)
			local granted = Budget.Await("GetSortedAsync", count, 0)
			harness.Cleanup()
			return granted
		end

		it("reserves NOTHING in a game that declares no leaderboards", function()
			-- The flat constant held four back from every migration, boards or not.
			expect(grantsWith(0, 10, 10)).to.equal(true)
		end)

		it("reserves ONE READ PER BOARD", function()
			expect(`spare8={grantsWith(2, 10, 8)} spare9={grantsWith(2, 10, 9)}`).to.equal("spare8=true spare9=false")
		end)

		it("CAPS it, so a board-heavy game cannot starve its own migration", function()
			expect(`spare6={grantsWith(6, 10, 6)} spare7={grantsWith(6, 10, 7)}`).to.equal("spare6=true spare7=false")
		end)
	end)

	describe("the hook argument", function()
		it("hands ImportLegacyData a migration context with AwaitBudget", function()
			fakeBudget(100)
			local seen = nil
			local harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function(_player, _userId, migration)
						seen = `type={typeof(migration)} await={typeof(migration and migration.AwaitBudget)}`
						return nil
					end,
				},
			})
			harness.TryJoin(79001)
			harness.Cleanup()
			expect(seen).to.equal("type=table await=function")
		end)

		it("reports Importing while the hook runs, and nothing once Ready", function()
			fakeBudget(100)
			local during = nil
			local harness
			harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function(player)
						local state, phase = harness.Data.GetState(player)
						during = `{state}/{tostring(phase)}`
						return nil
					end,
				},
			})
			local player = harness.TryJoin(79002)
			local after =
				`{select(1, harness.Data.GetState(player))}/{tostring(select(2, harness.Data.GetState(player)))}`
			harness.Cleanup()
			expect(`during={during} after={after}`).to.equal("during=Loading/Importing after=Ready/nil")
		end)

		it("reports ImportThrottled while the hook is queued on budget", function()
			local set = fakeBudget(0)
			local phases = {}
			local harness
			harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function(player, _userId, migration)
						Sched.Spawn(function()
							-- Sampled from outside the hook's thread, which is parked.
							task.wait(0.3)
							table.insert(phases, tostring(select(2, harness.Data.GetState(player))))
							set(100)
						end)
						migration.AwaitBudget("GetAsync", 5, 20)
						table.insert(phases, tostring(select(2, harness.Data.GetState(player))))
						return nil
					end,
				},
			})
			harness.TryJoin(79003)
			local seen = table.concat(phases, ",")
			harness.Cleanup()
			expect(seen).to.equal("ImportThrottled,Importing")
		end)

		it("clears the phase when the hook THROWS, and still kicks with the legacy wording", function()
			fakeBudget(100)
			local harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function()
						error("legacy store is down")
					end,
				},
			})
			local player, _entry, accessor = harness.TryJoin(79004)
			-- The entry is gone after a fail-closed load, so the phase cannot be read off
			-- it; what matters is that the kick still names the legacy import.
			local kicked = tostring(player.Kicked)
			harness.Cleanup()
			expect(
				`accessor={accessor ~= nil} legacy={string.find(kicked, "check your existing data", 1, true) ~= nil}`
			).to.equal("accessor=false legacy=true")
		end)

		it("rejects a non-string request type from inside the hook", function()
			fakeBudget(100)
			local err = nil
			local harness = TestCtx.make({
				Template = template,
				Options = {
					ImportLegacyData = function(_player, _userId, migration)
						local ok, e = pcall(migration.AwaitBudget, nil)
						err = if ok then "no error" else tostring(e)
						return nil
					end,
				},
			})
			harness.TryJoin(79005)
			harness.Cleanup()
			expect(string.find(err, "must be a string", 1, true) ~= nil).to.equal(true)
		end)

		it("hands OnPlayerInit the same context, for a game already on Scribe", function()
			-- ImportLegacyData only fires for a player who has never saved, so a game that
			-- adopted Scribe with stores still to move has nowhere else to do that work.
			fakeBudget(100)
			local seen, granted = nil, nil
			local harness = TestCtx.make({
				Template = template,
				Options = {
					OnPlayerInit = function(_player, _raw, _isNew, migration)
						seen = typeof(migration and migration.AwaitBudget)
						granted = migration.AwaitBudget("GetAsync", 2)
					end,
				},
			})
			harness.Join(79008)
			harness.Cleanup()
			expect(`await={seen} granted={tostring(granted)}`).to.equal("await=function granted=true")
		end)

		it("does NOT put OnPlayerInit behind the import concurrency cap", function()
			-- It runs for every join. Serialising all of them would throttle ordinary logins,
			-- which is a much worse failure than an unpaced migration.
			fakeBudget(100)
			local concurrent, peak = 0, 0
			local harness = TestCtx.make({
				Template = template,
				Options = {
					MigrationConcurrency = 1,
					OnPlayerInit = function()
						concurrent += 1
						peak = math.max(peak, concurrent)
						task.wait(0.1)
						concurrent -= 1
					end,
				},
			})
			Sched.Spawn(function()
				harness.TryJoin(79009)
			end)
			Sched.Spawn(function()
				harness.TryJoin(79010)
			end)
			for _ = 1, 15 do
				task.wait(0.1)
				if peak >= 2 then
					break
				end
			end
			harness.Cleanup()
			expect(peak >= 2).to.equal(true)
		end)

		it("CONTROL: a game with no ImportLegacyData never reports a phase", function()
			local harness = TestCtx.make({ Template = template })
			local player = harness.Join(79006)
			local state, phase = harness.Data.GetState(player)
			harness.Cleanup()
			expect(`{state}/{tostring(phase)}`).to.equal("Ready/nil")
		end)

		it("CONTROL: GetState's second return does not disturb single-value callers", function()
			local harness = TestCtx.make({ Template = template })
			local player = harness.Join(79007)
			local state = harness.Data.GetState(player)
			harness.Cleanup()
			expect(state).to.equal("Ready")
		end)
	end)
end
