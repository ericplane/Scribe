--!nonstrict
-- An idle bundle makes no timed waits: the pacer and both sweeps park until work arrives,
-- and the frame flush visits only entries with something queued.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local Sched = require(Root.Scribe.Internal.Sched)
	local Template = require(Root.Scribe.Internal.Template)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local Wire = require(Root.Scribe.Internal.Wire)
	local Profile = require(Root.Scribe.Internal.Profile)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local realNow, realWait = Clock.Now, Clock.Wait
	local realSpan = Profile.SyncSpan
	afterEach(function()
		Clock.Install({ Now = realNow, Wait = realWait })
		Sched.Reset()
		Profile.SyncSpan = realSpan
	end)

	--- Count every Clock.Wait, each yielding a frame; the second return names the callers.
	local function countWaits(): (() -> number, () -> string)
		local waits = 0
		local callers = {}
		Clock.Install({
			Wait = function(seconds)
				local source, line = debug.info(2, "sl")
				waits += 1
				table.insert(callers, `{source}:{line}`)
				task.wait()
				return seconds
			end,
		})
		return function()
			return waits
		end, function()
			return if #callers == 0 then "" else ` from {table.concat(callers, " ")}`
		end
	end

	--- Whether `check` holds within `limit` frames.
	local function within(limit: number, check: () -> boolean): boolean
		for _ = 1, limit do
			if check() then
				return true
			end
			task.wait()
		end
		return check()
	end

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 6 }),
	}
	local EXCHANGEABLE = { Item = { Path = { "Inventory" }, Kind = "Key" } }

	it("makes no timed wait while nothing is queued, armed or open", function()
		local waits, callers = countWaits()
		local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
		local player = harness.Join(70101)
		for _ = 1, 10 do
			task.wait()
		end
		local idle = `waits={waits()}{callers()}`
		harness.Leave(player)
		harness.Cleanup()
		expect(idle).to.equal("waits=0")
	end)

	describe("Leaderboards", function()
		local function workers(options): string
			local harness = TestCtx.make({ Template = { Wins = Scribe.Int(0, { Min = 0 }) }, Options = options })
			local w = harness.Ctx.Leaderboards.Workers()
			harness.Cleanup()
			return `pacer={w.Pacer} refresh={w.Refresh}`
		end

		it("starts no worker without a board, and only the refresh worker for server boards", function()
			local none = workers({})
			local server =
				workers({ Leaderboards = { Wins = { Stat = "Wins", Scope = "Server", RefreshInterval = 60 } } })
			local global = workers({ Leaderboards = { Wins = { Stat = "Wins" } } })
			expect(`none: {none}; server: {server}; global: {global}`).to.equal(
				"none: pacer=false refresh=false; server: pacer=false refresh=true; global: pacer=true refresh=true"
			)
		end)

		it("parks the write pacer while its queue is empty and wakes it for a score", function()
			countWaits()
			local harness = TestCtx.make({
				Template = { Wins = Scribe.Int(0, { Min = 0 }) },
				Options = { Leaderboards = { Wins = { Stat = "Wins" } } },
			})
			local lb = harness.Ctx.Leaderboards
			local player, _, data = harness.Join(70102)
			-- The join queues the loaded score.
			local idle = within(200, function()
				return lb.Workers().PacerParked
			end)
			data.Wins.Set(3)
			local awake = not lb.Workers().PacerParked
			local parkedAgain = within(200, function()
				return lb.Workers().PacerParked
			end)
			harness.Leave(player)
			harness.Cleanup()
			expect(`idle={idle} awake={awake} parkedAgain={parkedAgain}`).to.equal(
				"idle=true awake=true parkedAgain=true"
			)
		end)

		it("leaves a pacer that is mid-wait alone, so a burst cannot shorten its tick", function()
			countWaits()
			local harness = TestCtx.make({
				Template = { Wins = Scribe.Int(0, { Min = 0 }) },
				Options = { Leaderboards = { Wins = { Stat = "Wins" } } },
			})
			local lb = harness.Ctx.Leaderboards
			local a, _, dataA = harness.Join(70113)
			local b, _, dataB = harness.Join(70114)
			within(200, function()
				return lb.Workers().PacerParked
			end)
			-- A wait now parks its caller.
			Clock.Install({
				Wait = function(seconds)
					coroutine.yield()
					return seconds
				end,
			})
			local writesBefore = Scribe.GetMetrics().LbWrites or 0
			dataA.Wins.Set(3)
			local mid = lb.Workers().PacerParked
			dataB.Wins.Set(4)
			for _ = 1, 60 do
				task.wait()
			end
			local landed = (Scribe.GetMetrics().LbWrites or 0) - writesBefore
			Clock.Install({ Wait = realWait })
			harness.Leave(a)
			harness.Leave(b)
			harness.Cleanup()
			expect(`mid={mid} landed={landed}`).to.equal("mid=false landed=0")
		end)
	end)

	describe("Timed", function()
		it("sweeps only entries holding a timer, and parks once the last one lapses", function()
			countWaits()
			local harness = TestCtx.make()
			local timed = harness.Ctx.Timed
			local player, entry = harness.Join(70103)
			local before = `active={timed.ActiveCount()} parked={timed.Parked()}`
			harness.Data.OnCooldown(player, "Daily", 3600)
			local armed = `active={timed.ActiveCount()} parked={timed.Parked()}`
			entry.LiveData[Template.RESERVED_ROOT].Timed[Template.COOLDOWN_PREFIX .. "Daily"] = os.time() - 1
			local lapsed = within(100, function()
				return timed.Parked()
			end)
			local after = `active={timed.ActiveCount()} cooldown={harness.Data.PeekCooldown(player, "Daily")}`
			harness.Leave(player)
			harness.Cleanup()
			expect(`{before} | {armed} | lapsed={lapsed} {after}`).to.equal(
				"active=0 parked=true | active=1 parked=false | lapsed=true active=0 cooldown=false"
			)
		end)

		it("resumes sweeping a timer restored from disk", function()
			countWaits()
			local harness = TestCtx.make()
			local timed = harness.Ctx.Timed
			local player = harness.Join(70104)
			harness.Data.OnCooldown(player, "Daily", 3600)
			harness.Leave(player)
			local released = within(100, function()
				return timed.ActiveCount() == 0
			end)
			local again = harness.Join(70104)
			local restored = timed.ActiveCount()
			harness.Leave(again)
			harness.Cleanup()
			expect(`released={released} restored={restored}`).to.equal("released=true restored=1")
		end)
	end)

	describe("Exchanges", function()
		it("tracks only the entries an attempt touched, and drops them once nothing is open", function()
			local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
			local ex = harness.Ctx.Exchanges
			local pa = harness.Join(70105)
			local pb = harness.Join(70106)
			harness.Data.Get(pa).Inventory["blade"].Set({ Qty = 1 })
			harness.Data.Get(pb).Inventory["shield"].Set({ Qty = 1 })
			local before = `candidates={ex.CandidateCount()} parked={ex.Parked()}`
			local outcome = ex.Attempt(
				pa,
				{ { Path = { "Inventory" }, Kind = "Key", Key = "blade" } },
				pb,
				{ { Path = { "Inventory" }, Kind = "Key", Key = "shield" } }
			)
			local during = `candidates={ex.CandidateCount()} parked={ex.Parked()}`
			ex.SweepCandidates()
			local after = `candidates={ex.CandidateCount()}`
			harness.Cleanup()
			expect(`{before} | {tostring(outcome)} {during} | {after}`).to.equal(
				"candidates=0 parked=true | Committed candidates=2 parked=false | candidates=0"
			)
		end)

		it("keeps an entry whose load-time resolve could not run, for the sweep to retry", function()
			local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
			local ex = harness.Ctx.Exchanges
			local pa, ea = harness.Join(70112)
			harness.Data.Get(pa).Inventory["blade"].Set({ Qty = 1 })
			local legCtx = { Tree = ea.Tree, Entry = ea, Compiled = harness.Compiled, UserId = pa.UserId }
			ExchangeLeg.Claim(legCtx, "tid_idle", { Digest = "d", Role = "A", Partner = 70113 })
			ExchangeLeg.Escrow(legCtx, "tid_idle", { { Path = { "Inventory" }, Kind = "Key", Key = "blade" } })
			ex.VerdictStore = function()
				return nil
			end
			local resolved = ex.Resolve(ea)
			local held = `resolved={resolved} candidates={ex.CandidateCount()} parked={ex.Parked()}`
			-- Too young to sweep.
			local young = ex.SweepCandidates()
			local keptYoung = ex.CandidateCount()
			-- Old enough, against a store that throws.
			Clock.Install({
				Now = function()
					return realNow() + 120
				end,
			})
			ex.VerdictStore = function()
				error("the verdict store is down", 0)
			end
			local swept = ex.SweepCandidates()
			local kept = ex.CandidateCount()
			harness.Cleanup()
			expect(`{held} young={young} keptYoung={keptYoung} swept={swept} kept={kept}`).to.equal(
				"resolved=0 candidates=1 parked=false young=0 keptYoung=1 swept=0 kept=1"
			)
		end)
	end)

	describe("Replication", function()
		it("visits only entries with queued ops each frame", function()
			local harness = TestCtx.make()
			local rep = harness.Ctx.Replication
			local player, _, data = harness.Join(70107)
			harness.Join(70108)
			harness.SendHello(player)
			harness.Step()
			harness.Step()
			local idle = rep.DirtyCount()
			data.Coins.Set(5)
			local marked = rep.DirtyCount()
			harness.Step()
			local flushed = rep.DirtyCount()
			harness.Cleanup()
			expect(`idle={idle} marked={marked} flushed={flushed}`).to.equal("idle=0 marked=1 flushed=0")
		end)

		it("flushes a Shared write from a player whose own handshake is still pending", function()
			local harness = TestCtx.make({ Template = { Public = Scribe.Shared({ Title = "" }) } })
			local rep = harness.Ctx.Replication
			local a = harness.Join(70115)
			harness.SendHello(a)
			harness.Step()
			local _, _, dataB = harness.Join(70116)
			harness.Step()
			local before = #harness.FramesFor(a, Wire.Frames.SharedDiff)
			dataB.Public.Title.Set("Champion")
			local marked = rep.DirtyCount()
			harness.Step()
			local diffs = #harness.FramesFor(a, Wire.Frames.SharedDiff) - before
			harness.Cleanup()
			expect(`marked={marked} sharedDiffs={diffs}`).to.equal("marked=1 sharedDiffs=1")
		end)
	end)

	describe("Teardown", function()
		local function tracked(harness): string
			local c = harness.Ctx
			return `dirty={c.Replication.DirtyCount()} active={c.Timed.ActiveCount()} candidates={c.Exchanges.CandidateCount()}`
		end

		--- An open record whose partner is not on this server.
		local function openRecord(harness, player, entry, id: string)
			harness.Data.Get(player).Inventory["blade"].Set({ Qty = 1 })
			local legCtx = { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
			ExchangeLeg.Claim(legCtx, id, { Digest = "d", Role = "A", Partner = player.UserId + 1 })
			ExchangeLeg.Escrow(legCtx, id, { { Path = { "Inventory" }, Kind = "Key", Key = "blade" } })
		end

		--- One player in every tracking set.
		local function populated(userId: number)
			local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
			local player, entry, data = harness.Join(userId)
			harness.SendHello(player)
			harness.Step()
			data.Coins.Set(5)
			harness.Data.OnCooldown(player, "Daily", 3600)
			openRecord(harness, player, entry, "tid_teardown")
			harness.Ctx.Exchanges.VerdictStore = function()
				return nil
			end
			harness.Ctx.Exchanges.Resolve(entry)
			return harness, player, entry
		end

		it("forgets a departed player before the next frame or sweep", function()
			local harness, player = populated(70117)
			local before = tracked(harness)
			harness.Leave(player)
			local after = tracked(harness)
			harness.Cleanup()
			expect(`{before} | {after}`).to.equal("dirty=1 active=1 candidates=1 | dirty=0 active=0 candidates=0")
		end)

		it("clears every tracking set on Stop", function()
			local harness = populated(70119)
			harness.Data.Stop()
			local after = tracked(harness)
			harness.Cleanup()
			expect(after).to.equal("dirty=0 active=0 candidates=0")
		end)

		it("does not re-add an entry torn down while its sweep was yielding", function()
			local harness = TestCtx.make({ Template = TEMPLATE, Options = { Exchangeable = EXCHANGEABLE } })
			local ex = harness.Ctx.Exchanges
			local player, entry = harness.Join(70121)
			openRecord(harness, player, entry, "tid_inflight")
			ex.VerdictStore = function()
				return nil
			end
			ex.Resolve(entry)
			Clock.Install({
				Now = function()
					return realNow() + 120
				end,
			})
			-- A verdict that yields.
			local keys = {}
			local slow = {
				UpdateAsync = function(_self, key, transform)
					for _ = 1, 4 do
						task.wait()
					end
					local value = transform(keys[key])
					if value == nil then
						return nil, nil
					end
					keys[key] = value
					return value, nil
				end,
				GetAsync = function(_self, key)
					return keys[key], nil
				end,
			}
			ex.VerdictStore = function()
				return slow
			end
			local finished = false
			Sched.Spawn(function()
				ex.SweepCandidates()
				finished = true
			end)
			harness.Leave(player)
			within(200, function()
				return finished
			end)
			local left = ex.CandidateCount()
			harness.Cleanup()
			expect(`finished={finished} candidates={left}`).to.equal("finished=true candidates=0")
		end)

		--- A send that removes `Victim` (else `target`), stops the bundle unless `KeepRunning`, and throws.
		local function tearingSend(harness, target, kind: number, opts: { Victim: any?, KeepRunning: boolean? }?)
			local realSend = harness.Transport.SendToClient
			local fired = false
			harness.Transport.SendToClient = function(self, player, bytes)
				if not fired and player == target and buffer.readu8(bytes, 0) == kind then
					fired = true
					harness.Leave(if opts and opts.Victim then opts.Victim else target)
					if not (opts and opts.KeepRunning) then
						harness.Data.Stop()
					end
					error("transport gone", 0)
				end
				return realSend(self, player, bytes)
			end
			return function()
				return fired
			end
		end

		it("does not re-add an entry a transport removed and stopped during its Diff", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join(70125)
			harness.SendHello(player)
			harness.Step()
			local fired = tearingSend(harness, player, Wire.Frames.Diff)
			data.Coins.Set(3)
			harness.Step()
			local left = harness.Ctx.Replication.DirtyCount()
			harness.Cleanup()
			expect(`fired={fired()} dirty={left}`).to.equal("fired=true dirty=0")
		end)

		it("does not re-add an entry a transport removed and stopped during its Init", function()
			local harness = TestCtx.make()
			local player, entry = harness.Join(70127)
			harness.SendHello(player)
			harness.Step()
			harness.Ctx.Replication.RequestResync(entry, "Spec")
			local fired = tearingSend(harness, player, Wire.Frames.Init)
			harness.Step()
			local left = harness.Ctx.Replication.DirtyCount()
			harness.Cleanup()
			expect(`fired={fired()} dirty={left}`).to.equal("fired=true dirty=0")
		end)

		it("does not re-add an entry torn down while its Shared diff went out with a repair pending", function()
			local harness = TestCtx.make({ Template = { Public = Scribe.Shared({ Title = "" }) } })
			local rep = harness.Ctx.Replication
			local a, entryA, dataA = harness.Join(70129)
			local b = harness.Join(70130)
			harness.SendHello(a)
			harness.SendHello(b)
			harness.Step()
			-- The second request is throttled and stays pending.
			rep.RequestResync(entryA, "Spec")
			harness.Step()
			rep.RequestResync(entryA, "Spec")
			local fired = tearingSend(harness, b, Wire.Frames.SharedDiff, { Victim = a })
			dataA.Public.Title.Set("Champion")
			harness.Step()
			local left = rep.DirtyCount()
			harness.Cleanup()
			expect(`fired={fired()} dirty={left}`).to.equal("fired=true dirty=0")
		end)

		it("drops an entry a transport removed during its Diff, with the bundle still running", function()
			local harness = TestCtx.make()
			local player, _, data = harness.Join(70131)
			harness.SendHello(player)
			harness.Step()
			local fired = tearingSend(harness, player, Wire.Frames.Diff, { KeepRunning = true })
			data.Coins.Set(3)
			harness.Step()
			local left = harness.Ctx.Replication.DirtyCount()
			harness.Cleanup()
			expect(`fired={fired()} dirty={left}`).to.equal("fired=true dirty=0")
		end)

		it("skips the frame flush entirely while nothing is dirty", function()
			local harness = TestCtx.make()
			local spans = 0
			Profile.SyncSpan = function(label, ...)
				if label == "Scribe.Flush" then
					spans += 1
				end
				return realSpan(label, ...)
			end
			local player, _, data = harness.Join(70123)
			harness.SendHello(player)
			harness.Step()
			spans = 0
			for _ = 1, 10 do
				harness.Step()
			end
			local idle = spans
			data.Coins.Set(1)
			harness.Step()
			local busy = spans
			Profile.SyncSpan = realSpan
			harness.Leave(player)
			harness.Cleanup()
			expect(`idle={idle} busy={busy}`).to.equal("idle=0 busy=1")
		end)
	end)

	describe("Monetization", function()
		local function listeners(options): number
			local harness = TestCtx.make({ Options = options })
			local count = harness.Ctx.Monetization.ListenerCount()
			harness.Cleanup()
			return count
		end

		it("listens for pass purchases only when a pass is declared", function()
			local without, with = listeners({}), listeners({ Passes = { VIP = { Id = 70109 } } })
			expect(`without={without} with={with}`).to.equal(`without={with - 1} with={with}`)
		end)

		it("checks ownership inline when no pass is declared", function()
			local function refreshSpawned(options): (boolean, boolean)
				local spawned = {}
				local realSpawn = Sched.Spawn
				Sched.Install({
					Spawn = function(fn, ...)
						table.insert(spawned, debug.info(fn, "n"))
						return realSpawn(fn, ...)
					end,
				})
				local harness = TestCtx.make({ Options = options })
				local player, entry = harness.Join(70110)
				local ready = entry.OwnershipReady == true
				harness.Leave(player)
				harness.Cleanup()
				Sched.Reset()
				return table.find(spawned, "refreshOwnership") ~= nil, ready
			end
			local withoutSpawn, withoutReady = refreshSpawned({})
			local withSpawn = refreshSpawned({ Passes = { VIP = { Id = 70111 } } })
			expect(`without={withoutSpawn} ready={withoutReady} with={withSpawn}`).to.equal(
				"without=false ready=true with=true"
			)
		end)
	end)
end
