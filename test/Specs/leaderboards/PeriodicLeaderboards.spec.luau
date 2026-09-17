--!nonstrict
-- Daily and weekly boards. Time is driven through Clock.Now, never slept.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Clock = require(Root.Scribe.Internal.Clock)
	local Big = require(Root.Scribe.Internal.Big)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local DAY = 86400
	-- Patching the name service needs the shim.
	local itHeadless = if typeof(RunService.PostSimulation) ~= "RBXScriptSignal" then it else itSKIP
	-- Day 0 of the epoch was a Thursday. Day 4 is the first Monday, day 3 the first Sunday.

	--- A wall clock the spec moves by hand; afterEach restores it.
	local realNow = Clock.Now
	local function fixedClock(start: number)
		local now = start
		Clock.Install({
			Now = function()
				return now
			end,
		})
		return function(t: number)
			now = t
		end, function()
			Clock.Install({ Now = realNow })
		end
	end

	afterEach(function()
		Clock.Install({ Now = realNow })
	end)

	local function makeHarness(extraOptions)
		local options = {
			Leaderboards = {
				Wins = { Stat = "Wins" },
				WinsDaily = { Stat = "Wins", Period = "Daily" },
				WinsWeekly = { Stat = "Wins", Period = "Weekly" },
				BestDaily = { Stat = "Combo", Period = "Daily", Mode = "Peak" },
				RichDaily = { Stat = "Wealth", Period = "Daily" },
			},
		}
		for k, v in extraOptions or {} do
			options[k] = v
		end
		return TestCtx.make({
			Template = {
				Wins = Scribe.Int(0, { Min = 0 }),
				Combo = Scribe.Int(0, { Min = 0 }),
				Wealth = Scribe.Big(0),
			},
			Options = options,
		})
	end

	--- What a store holds, as userId -> score, straight from the mock.
	local function stored(harness, name: string, offset: number?): { [number]: number }
		local store = harness.Ctx.Leaderboards.MockStoreFor(name, offset)
		local out = {}
		for _, item in store:GetSortedAsync(false, 100):GetCurrentPage() do
			out[tonumber(item.key)] = item.value
		end
		return out
	end

	--- Drain and refresh, then read the board through the public surface.
	local function board(harness, name: string, offset: number?)
		harness.Ctx.Leaderboards.FlushAllBlocking(1)
		harness.Ctx.Leaderboards.RefreshNow(name)
		return harness.Data.GetLeaderboard(name, nil, offset)
	end

	local function top(entries): string
		local parts = {}
		for _, e in entries do
			table.insert(parts, `{e.UserId}={tostring(e.Score)}`)
		end
		return table.concat(parts, ",")
	end

	describe("the period index", function()
		it("counts days from the epoch and weeks from the first Monday, at offset 0", function()
			local set, restore = fixedClock(0)
			local harness = makeHarness()
			local lb = harness.Ctx.Leaderboards
			local rows = {}
			for _, t in { 0, DAY - 1, DAY, 3 * DAY, 4 * DAY, 11 * DAY } do
				set(t)
				table.insert(rows, `{t // DAY}:d{lb.CurrentPeriod("WinsDaily")}/w{lb.CurrentPeriod("WinsWeekly")}`)
			end
			local names =
				`{lb.BoardStoreName("WinsDaily")} {lb.BoardStoreName("WinsWeekly")} {lb.BoardStoreName("Wins")}`
			harness.Cleanup()
			restore()
			expect(table.concat(rows, " ")).to.equal("0:d0/w0 0:d0/w0 1:d1/w0 3:d3/w0 4:d4/w1 11:d11/w2")
			expect(names).to.equal("LB_WinsDaily_d11 LB_WinsWeekly_w2 LB_Wins")
		end)

		it("rolls the day at the UtcOffset hour and the week on the WeekStart day", function()
			local set, restore = fixedClock(0)
			local harness = makeHarness({ PeriodReset = { UtcOffset = -8, WeekStart = "Sunday" } })
			local lb = harness.Ctx.Leaderboards
			set(8 * 3600 - 1)
			local beforeEight = lb.CurrentPeriod("WinsDaily")
			set(8 * 3600)
			local atEight = lb.CurrentPeriod("WinsDaily")
			-- Sunday is day 3; with the offset the local day 3 begins at 3 * DAY + 8h.
			set(3 * DAY + 8 * 3600 - 1)
			local saturday = lb.CurrentPeriod("WinsWeekly")
			set(3 * DAY + 8 * 3600)
			local sunday = lb.CurrentPeriod("WinsWeekly")
			harness.Cleanup()
			restore()
			expect(`day {beforeEight}->{atEight} week {saturday}->{sunday}`).to.equal("day -1->0 week 0->1")
		end)

		it("refuses an offset outside -12..14, a bad day name, and a Mode with no Period", function()
			local function build(options, template)
				return pcall(function()
					TestCtx.make({ Template = template or { Wins = Scribe.Int(0) }, Options = options }).Cleanup()
				end)
			end
			local rows = {}
			for label, options in
				{
					offset = { PeriodReset = { UtcOffset = 15 } },
					day = { PeriodReset = { WeekStart = "Someday" } },
					mode = { Leaderboards = { B = { Stat = "Wins", Mode = "Peak" } } },
					period = { Leaderboards = { B = { Stat = "Wins", Period = "Hourly" } } },
					scope = { Leaderboards = { B = { Stat = "Wins", Scope = "Galaxy" } } },
					ok = {
						Leaderboards = { B = { Stat = "Wins", Period = "Weekly", Mode = "Peak" } },
						PeriodReset = { UtcOffset = 5.5 },
					},
				}
			do
				rows[label] = (build(options))
			end
			expect(
				`offset={rows.offset} day={rows.day} mode={rows.mode} period={rows.period} scope={rows.scope} ok={rows.ok}`
			).to.equal("offset=false day=false mode=false period=false scope=false ok=true")
		end)
	end)

	describe("time to the reset", function()
		it("counts down to the end of the day and of the week, on the reset clock", function()
			local set, restore = fixedClock(10 * DAY + 100)
			local harness = makeHarness()
			local d = harness.Data
			-- Day 10 is a Sunday; the week ends at day 11.
			local daily, weekly = d.GetLeaderboardResetIn("WinsDaily"), d.GetLeaderboardResetIn("WinsWeekly")
			set(4 * DAY)
			local fullWeek = d.GetLeaderboardResetIn("WinsWeekly")
			set(11 * DAY - 1)
			local lastSecond = d.GetLeaderboardResetIn("WinsDaily")
			set(11 * DAY)
			local atRollover = d.GetLeaderboardResetIn("WinsDaily")
			local lifetime = d.GetLeaderboardResetIn("Wins")
			harness.Cleanup()
			restore()
			expect(
				`daily={daily} weekly={weekly} fullWeek={fullWeek} last={lastSecond} atRollover={atRollover} lifetime={tostring(
					lifetime
				)}`
			).to.equal("daily=86300 weekly=86300 fullWeek=604800 last=1 atRollover=86400 lifetime=nil")
		end)

		it("counts down on the offset clock, not UTC", function()
			local _, restore = fixedClock(10 * DAY + 8 * 3600 + 100)
			local harness = makeHarness({ PeriodReset = { UtcOffset = -8 } })
			local daily = harness.Data.GetLeaderboardResetIn("WinsDaily")
			harness.Cleanup()
			restore()
			expect(daily).to.equal(86300)
		end)
	end)

	describe("what a periodic board ranks", function()
		it("Gain: the increase since the period began, with the lifetime board untouched", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1001)
			data.Wins.Set(5)
			local first = top(board(harness, "WinsDaily"))
			data.Wins.Set(8)
			local second = top(board(harness, "WinsDaily"))
			local lifetime = top(board(harness, "Wins"))
			harness.Cleanup()
			restore()
			expect(`{first} | {second} | {lifetime}`).to.equal("1001=5 | 1001=8 | 1001=8")
		end)

		it("Gain floors a fall below the period start at zero, and the store never sees a negative", function()
			-- Only a value below the period start floors; the rollover puts the baseline at 8.
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1002)
			data.Wins.Set(8)
			board(harness, "WinsDaily")
			set(11 * DAY)
			data.Wins.Set(3)
			local after = top(board(harness, "WinsDaily"))
			local raw = stored(harness, "WinsDaily")[1002]
			local yesterday = stored(harness, "WinsDaily", -1)[1002]
			harness.Cleanup()
			restore()
			expect(`{after} raw={raw} yesterday={yesterday}`).to.equal("1002=0 raw=0 yesterday=8")
		end)

		it("Peak: the highest value seen this period, kept when the stat falls", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1003)
			data.Combo.Set(7)
			data.Combo.Set(3)
			local peak = top(board(harness, "BestDaily"))
			harness.Cleanup()
			restore()
			expect(peak).to.equal("1003=7")
		end)

		it("a Scribe.Big stat gains through Big subtraction", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1004)
			data.Wealth.Set("1e20")
			data.Wealth.Set("3e20")
			local entries = board(harness, "RichDaily")
			local score = entries[1] and Big.toString(entries[1].Score) or "none"
			harness.Cleanup()
			restore()
			expect(score).to.equal("3e20")
		end)

		it("keeps the baseline across leave and rejoin within the period", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1005)
			data.Wins.Set(5)
			board(harness, "WinsDaily")
			harness.Leave(player)
			local _, _, again = harness.Join(1005)
			again.Wins.Set(9)
			local after = top(board(harness, "WinsDaily"))
			harness.Cleanup()
			restore()
			expect(after).to.equal("1005=9")
		end)
	end)

	describe("the rollover", function()
		it("resets the baseline to the write's OLD value, so the first gain after midnight counts", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1006)
			data.Wins.Set(8)
			board(harness, "WinsDaily")
			set(11 * DAY)
			data.Wins.Set(10)
			local today = top(board(harness, "WinsDaily"))
			local yesterday = stored(harness, "WinsDaily", -1)[1006]
			harness.Cleanup()
			restore()
			expect(`today={today} yesterday={yesterday}`).to.equal("today=1006=2 yesterday=8")
		end)

		it("starts a player loaded after a rollover at zero", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1007)
			data.Wins.Set(8)
			board(harness, "WinsDaily")
			harness.Leave(player)
			set(11 * DAY)
			local _, _, again = harness.Join(1007)
			local fresh = top(board(harness, "WinsDaily"))
			again.Wins.Set(9)
			local gained = top(board(harness, "WinsDaily"))
			harness.Cleanup()
			restore()
			expect(`{fresh} | {gained}`).to.equal("1007=0 | 1007=1")
		end)

		it("drains a queued write to the period it was computed for", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1008)
			data.Wins.Set(6) -- queued against day 10, not yet flushed
			set(11 * DAY)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local dayTen = stored(harness, "WinsDaily", -1)[1008]
			local dayEleven = stored(harness, "WinsDaily")[1008]
			harness.Cleanup()
			restore()
			expect(`d10={dayTen} d11={tostring(dayEleven)}`).to.equal("d10=6 d11=nil")
		end)

		it("reads the new store after a rollover, and offset -1 reads the old one", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1009)
			data.Wins.Set(4)
			board(harness, "WinsDaily")
			set(11 * DAY)
			local current = top(board(harness, "WinsDaily"))
			local previous = top(harness.Data.GetLeaderboard("WinsDaily", nil, -1))
			local lifetimePrevious = #harness.Data.GetLeaderboard("Wins", nil, -1)
			harness.Cleanup()
			restore()
			expect(`current={current} previous={previous} lifetimePrevious={lifetimePrevious}`).to.equal(
				"current= previous=1009=4 lifetimePrevious=0"
			)
		end)

		it("conserves: the daily gains across three days sum to the lifetime delta", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1010)
			local gains = {}
			for day, target in { [10] = 5, [11] = 8, [12] = 12 } do
				set(day * DAY)
				data.Wins.Set(target)
				harness.Ctx.Leaderboards.FlushAllBlocking(1)
			end
			for offset = -2, 0 do
				table.insert(gains, stored(harness, "WinsDaily", offset)[1010])
			end
			local lifetime = top(board(harness, "Wins"))
			harness.Cleanup()
			restore()
			expect(`gains={table.concat(gains, "+")} lifetime={lifetime}`).to.equal("gains=5+3+4 lifetime=1010=12")
		end)
	end)

	describe("erase", function()
		it("sweeps every period from the first write to now, then deletes the profile", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1011)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(12 * DAY) -- day 11 skipped entirely
			data.Wins.Set(5)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			local ok = harness.Data.Erase(1011)
			local left = {}
			for offset = -2, 0 do
				table.insert(left, tostring(stored(harness, "WinsDaily", offset)[1011]))
			end
			local profileGone = harness.Fake.Persisted["Default/PLAYER_1011"] == nil
			harness.Cleanup()
			restore()
			expect(`ok={ok} left={table.concat(left, ",")} profileGone={profileGone}`).to.equal(
				"ok=true left=nil,nil,nil profileGone=true"
			)
		end)

		it("resumes a failed sweep where it stopped", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1013)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(14 * DAY)
			harness.Leave(player)
			local dayTwelve = harness.Ctx.Leaderboards.MockStoreFor("WinsDaily", -2)
			local realRemove = dayTwelve.RemoveAsync
			local refusals = 0
			dayTwelve.RemoveAsync = function(...)
				if refusals == 0 then
					refusals += 1
					error("store refused")
				end
				return realRemove(...)
			end
			local function removes(): number
				return Scribe.GetMetrics().LbEraseRemoves or 0
			end
			local base = removes()
			local firstOk = harness.Data.Erase(1013)
			local firstRemoves = removes() - base
			local profile = harness.Fake.Persisted["Default/PLAYER_1013"]
			local cursor = profile and profile._Scribe.Erase and profile._Scribe.Erase.Cursors.WinsDaily
			local secondOk = harness.Data.Erase(1013)
			local secondRemoves = removes() - base - firstRemoves
			local gone = harness.Fake.Persisted["Default/PLAYER_1013"] == nil
			harness.Cleanup()
			restore()
			-- The first pass also sweeps the other boards, which the retry then skips.
			expect(
				`first={firstOk} removes={firstRemoves >= 3} cursor={cursor and cursor.Next} second={secondOk} removes={secondRemoves} gone={gone}`
			).to.equal("first=false removes=true cursor=12 second=true removes=3 gone=true")
		end)

		it("stops at the next checkpoint once the erase is lost", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness({ Leaderboards = { WinsDaily = { Stat = "Wins", Period = "Daily" } } })
			local player, _, data = harness.Join(1014)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(40 * DAY)
			harness.Leave(player)
			local ranges = harness.Fake.Persisted["Default/PLAYER_1014"]._Scribe.Boards
			local saves = 0
			local progress = {
				Done = {},
				Cursors = {},
				Save = function()
					saves += 1
					return false
				end,
			}
			local base = Scribe.GetMetrics().LbEraseRemoves or 0
			local ok, reason = harness.Ctx.Leaderboards.EraseUser(1014, ranges, progress)
			local removes = (Scribe.GetMetrics().LbEraseRemoves or 0) - base
			harness.Cleanup()
			restore()
			expect(`ok={ok} reason={reason} saves={saves} removes={removes} done={next(progress.Done) == nil}`).to.equal(
				"ok=false reason=the erase was finished or replaced elsewhere saves=1 removes=25 done=true"
			)
		end)

		it("leaves the remaining boards alone once the erase is lost", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness({
				Leaderboards = {
					WinsDaily = { Stat = "Wins", Period = "Daily" },
					WinsDailyToo = { Stat = "Wins", Period = "Daily" },
				},
			})
			local player, _, data = harness.Join(1015)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(14 * DAY)
			harness.Leave(player)
			local ranges = harness.Fake.Persisted["Default/PLAYER_1015"]._Scribe.Boards
			local saves = 0
			local progress = {
				Done = {},
				Cursors = {},
				Save = function()
					saves += 1
					return false
				end,
			}
			local base = Scribe.GetMetrics().LbEraseRemoves or 0
			local ok = harness.Ctx.Leaderboards.EraseUser(1015, ranges, progress)
			local removes = (Scribe.GetMetrics().LbEraseRemoves or 0) - base
			local doneCount = 0
			for _ in progress.Done do
				doneCount += 1
			end
			harness.Cleanup()
			restore()
			expect(`ok={ok} saves={saves} removes={removes} done={doneCount}`).to.equal(
				"ok=false saves=1 removes=5 done=1"
			)
		end)

		it("does not touch a lifetime board once the erase is lost", function()
			local harness = makeHarness({ Leaderboards = { Wins = { Stat = "Wins" }, WinsToo = { Stat = "Wins" } } })
			local player, _, data = harness.Join(1016)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			-- Both stores refuse, so whichever board comes first loses the erase at its checkpoint.
			for _, name in { "Wins", "WinsToo" } do
				harness.Ctx.Leaderboards.MockStoreFor(name).RemoveAsync = function()
					error("store refused")
				end
			end
			local saves = 0
			local progress = {
				Done = {},
				Cursors = {},
				Save = function()
					saves += 1
					return false
				end,
			}
			local base = Scribe.GetMetrics().LbEraseRemoves or 0
			local ok, reason = harness.Ctx.Leaderboards.EraseUser(1016, nil, progress)
			local removes = (Scribe.GetMetrics().LbEraseRemoves or 0) - base
			harness.Cleanup()
			expect(`ok={ok} reason={reason} saves={saves} removes={removes}`).to.equal(
				"ok=false reason=the erase was finished or replaced elsewhere saves=1 removes=1"
			)
		end)

		it("renews the lease on time as well as on count", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness({ Leaderboards = { WinsDaily = { Stat = "Wins", Period = "Daily" } } })
			local player, _, data = harness.Join(1017)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(19 * DAY)
			harness.Leave(player)
			local ranges = harness.Fake.Persisted["Default/PLAYER_1017"]._Scribe.Boards
			-- Every monotonic read moves the clock, so a ten-period sweep spans minutes.
			local realMonotonic = Clock.Monotonic
			local tick = 0
			Clock.Install({
				Monotonic = function()
					tick += 16
					return tick
				end,
			})
			local saves = 0
			local progress = {
				Done = {},
				Cursors = {},
				Save = function()
					saves += 1
					return true
				end,
			}
			local ok = harness.Ctx.Leaderboards.EraseUser(1017, ranges, progress)
			Clock.Install({ Monotonic = realMonotonic })
			harness.Cleanup()
			restore()
			expect(`ok={ok} renewed={saves > 1}`).to.equal("ok=true renewed=true")
		end)

		it("renews the lease across a run of lifetime boards", function()
			local harness = makeHarness({
				Leaderboards = { Wins = { Stat = "Wins" }, WinsToo = { Stat = "Wins" }, WinsThree = { Stat = "Wins" } },
			})
			local player, _, data = harness.Join(1018)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			local realMonotonic = Clock.Monotonic
			local tick = 0
			Clock.Install({
				Monotonic = function()
					tick += 16
					return tick
				end,
			})
			local saves = 0
			local progress = {
				Done = {},
				Cursors = {},
				Save = function()
					saves += 1
					return true
				end,
			}
			local ok = harness.Ctx.Leaderboards.EraseUser(1018, nil, progress)
			Clock.Install({ Monotonic = realMonotonic })
			harness.Cleanup()
			expect(`ok={ok} renewed={saves >= 1}`).to.equal("ok=true renewed=true")
		end)

		it("stops the sweep when the lease cannot be renewed, and a retry waits for the lease", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness({ Leaderboards = { WinsDaily = { Stat = "Wins", Period = "Daily" } } })
			local player, _, data = harness.Join(1019)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(40 * DAY)
			harness.Leave(player)
			local fake = harness.Fake
			local commits = 0
			-- The first offline commit is the claim; every one after it fails.
			fake.MidOfflineCommit = function()
				commits += 1
				if commits >= 2 then
					error("store down")
				end
			end
			local base = Scribe.GetMetrics().LbEraseRemoves or 0
			local ok, reason = harness.Data.Erase(1019)
			local removes = (Scribe.GetMetrics().LbEraseRemoves or 0) - base
			fake.MidOfflineCommit = nil
			local kept = fake.Persisted["Default/PLAYER_1019"] ~= nil
			local retryOk, retryReason = harness.Data.Erase(1019)
			harness.Cleanup()
			restore()
			local stopped = string.find(tostring(reason), "the erase lease could not be renewed", 1, true) ~= nil
			expect(`ok={ok} stopped={stopped} removes={removes} kept={kept} retry={retryOk} busy={retryReason}`).to.equal(
				"ok=false stopped=true removes=25 kept=true retry=false busy=another erase of this profile is still running"
			)
		end)

		it("rides out a single failed renewal", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness({ Leaderboards = { WinsDaily = { Stat = "Wins", Period = "Daily" } } })
			local player, _, data = harness.Join(1020)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(40 * DAY)
			harness.Leave(player)
			local fake = harness.Fake
			local commits = 0
			fake.MidOfflineCommit = function()
				commits += 1
				if commits == 2 then
					error("blip")
				end
			end
			local base = Scribe.GetMetrics().LbEraseRemoves or 0
			local ok, reason = harness.Data.Erase(1020)
			local removes = (Scribe.GetMetrics().LbEraseRemoves or 0) - base
			fake.MidOfflineCommit = nil
			local gone = fake.Persisted["Default/PLAYER_1020"] == nil
			harness.Cleanup()
			restore()
			expect(`ok={ok} reason={tostring(reason)} removes={removes} gone={gone}`).to.equal(
				"ok=true reason=nil removes=31 gone=true"
			)
		end)

		it("keeps the profile when the sweep fails, so a retry can resume it", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1012)
			data.Wins.Set(2)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			set(11 * DAY)
			harness.Leave(player)
			local yesterday = harness.Ctx.Leaderboards.MockStoreFor("WinsDaily", -1)
			local realRemove = yesterday.RemoveAsync
			yesterday.RemoveAsync = function()
				error("store refused")
			end
			local firstOk = harness.Data.Erase(1012)
			local profileKept = harness.Fake.Persisted["Default/PLAYER_1012"] ~= nil
			yesterday.RemoveAsync = realRemove
			local secondOk = harness.Data.Erase(1012)
			local swept = stored(harness, "WinsDaily", -1)[1012] == nil
			local profileGone = harness.Fake.Persisted["Default/PLAYER_1012"] == nil
			harness.Cleanup()
			restore()
			expect(`first={firstOk} kept={profileKept} second={secondOk} swept={swept} gone={profileGone}`).to.equal(
				"first=false kept=true second=true swept=true gone=true"
			)
		end)

		it("leaves the previous-period cache too, once its reads are spent", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1013)
			data.Wins.Set(5)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			set(11 * DAY)
			-- Both previous reads spent, so nothing re-reads the store after the erase.
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			local before = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Leave(player)
			local ok = harness.Data.Erase(1013)
			local previous = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			local afterRefresh = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`ok={ok} before={before} previous={previous} afterRefresh={afterRefresh}`).to.equal(
				"ok=true before=1 previous=0 afterRefresh=0"
			)
		end)

		--- Parks the next read of a store between taking the page and returning it; returns a resume.
		local function parkNextRead(harness, name: string, offset: number?): () -> ()
			local store = harness.Ctx.Leaderboards.MockStoreFor(name, offset)
			local realRead = store.GetSortedAsync
			local parked: thread? = nil
			store.GetSortedAsync = function(self, ...)
				store.GetSortedAsync = realRead
				local page = realRead(self, ...)
				parked = coroutine.running()
				coroutine.yield()
				return page
			end
			return function()
				task.spawn(parked :: thread)
			end
		end

		--- Runs `fn` on its own thread and answers whether it has returned.
		local function inBackground(fn: () -> ()): () -> boolean
			local done = false
			task.spawn(function()
				fn()
				done = true
			end)
			return function()
				for _ = 1, 200 do
					if done then
						break
					end
					task.wait(0.01)
				end
				return done
			end
		end

		it("runs a refresh started during another one after it, so a rollover between them is seen", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1021)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily", -1)
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			set(11 * DAY)
			local landed = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			resume()
			local done = landed()
			local current = #harness.Data.GetLeaderboard("WinsDaily")
			local previous = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`landed={done} current={current} previous={previous}`).to.equal("landed=true current=0 previous=1")
		end)

		it("runs a refresh started during another's current-period read after it", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1022)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			set(11 * DAY)
			local landed = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			resume()
			local done = landed()
			local current = #harness.Data.GetLeaderboard("WinsDaily")
			local previous = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`landed={done} current={current} previous={previous}`).to.equal("landed=true current=0 previous=1")
		end)

		it("lets the later of two refreshes read what landed in the previous period between them", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1023)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			-- A leave flush lands in yesterday while the first refresh holds an older page of it.
			local resume = parkNextRead(harness, "WinsDaily", -1)
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			harness.Ctx.Leaderboards.MockStoreFor("WinsDaily", -1):SetAsync("1023", 5)
			local landed = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			resume()
			local done = landed()
			local previous = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`landed={done} previous={previous}`).to.equal("landed=true previous=1")
		end)

		itHeadless("runs a refresh started during another's name lookup after it", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1024)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local parked: thread? = nil
			Players.GetNameFromUserIdAsync = function(self, userId)
				Players.GetNameFromUserIdAsync = realLookup
				parked = coroutine.running()
				coroutine.yield()
				return realLookup(self, userId)
			end
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			set(11 * DAY)
			local landed = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			task.spawn(parked :: thread)
			local done = landed()
			local current = #harness.Data.GetLeaderboard("WinsDaily")
			local previous = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`landed={done} current={current} previous={previous}`).to.equal("landed=true current=0 previous=1")
		end)

		it("lands a slow refresh even with another waiting behind it", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1025)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resumeFirst = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			-- The next read of the store belongs to the second refresh, whenever it runs.
			local store = harness.Ctx.Leaderboards.MockStoreFor("WinsDaily")
			local realRead = store.GetSortedAsync
			local parkedSecond: thread? = nil
			store.GetSortedAsync = function(self, ...)
				store.GetSortedAsync = realRead
				local page = realRead(self, ...)
				parkedSecond = coroutine.running()
				coroutine.yield()
				return page
			end
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			resumeFirst()
			for _ = 1, 200 do
				if parkedSecond then
					break
				end
				task.wait(0.01)
			end
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			task.spawn(parkedSecond :: thread)
			harness.Cleanup()
			restore()
			expect(`secondParked={parkedSecond ~= nil} shown={shown}`).to.equal("secondParked=true shown=1")
		end)

		--- Counts reads of the board's current store from now on.
		local function countReads(harness, name: string): () -> number
			local store = harness.Ctx.Leaderboards.MockStoreFor(name)
			local realRead = store.GetSortedAsync
			local reads = 0
			store.GetSortedAsync = function(self, ...)
				reads += 1
				return realRead(self, ...)
			end
			return function()
				return reads
			end
		end

		it("shares one waiting refresh among callers that find one in flight", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1026)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local reads = countReads(harness, "WinsDaily")
			local second = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			local third = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			resume()
			local secondDone, thirdDone = second(), third()
			local extra = reads()
			harness.Cleanup()
			restore()
			expect(`second={secondDone} third={thirdDone} reads={extra}`).to.equal("second=true third=true reads=1")
		end)

		it("does not start a waiting refresh once the bundle has stopped", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1027)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local reads = countReads(harness, "WinsDaily")
			local waiting = inBackground(function()
				harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			end)
			harness.Ctx.Leaderboards.Stop()
			-- Woken by Stop itself, not by the refresh in flight, which is still parked.
			local returned = waiting()
			resume()
			task.wait(0.05)
			local extra = reads()
			harness.Cleanup()
			restore()
			expect(`returned={returned} reads={extra}`).to.equal("returned=true reads=0")
		end)

		it("drops a scheduled refresh that finds the last one still running", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1028)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local reads = countReads(harness, "WinsDaily")
			harness.Ctx.Leaderboards.RefreshTick()
			harness.Ctx.Leaderboards.RefreshTick()
			resume()
			task.wait(0.05)
			local extra = reads()
			harness.Cleanup()
			restore()
			expect(`reads={extra}`).to.equal("reads=0")
		end)

		--- Counts OnLeaderboard fires for the board from now on.
		local function countFires(harness, name: string): () -> number
			local fires = 0
			harness.Ctx.Signals.OnLeaderboard:Connect(function(fired)
				if fired == name then
					fires += 1
				end
			end)
			return function()
				return fires
			end
		end

		it("goes no further after Stop when parked in its previous-period read", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1029)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily", -1)
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local reads = countReads(harness, "WinsDaily")
			local fires = countFires(harness, "WinsDaily")
			harness.Ctx.Leaderboards.Stop()
			resume()
			task.wait(0.05)
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`reads={reads()} fires={fires()} shown={shown}`).to.equal("reads=0 fires=0 shown=0")
		end)

		it("goes no further after Stop when parked in its current-period read", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local _, _, data = harness.Join(1030)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local fires = countFires(harness, "WinsDaily")
			harness.Ctx.Leaderboards.Stop()
			resume()
			task.wait(0.05)
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`fires={fires()} shown={shown}`).to.equal("fires=0 shown=0")
		end)

		itHeadless("goes no further after Stop when parked in a name lookup", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1031)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local parked: thread? = nil
			Players.GetNameFromUserIdAsync = function(self, userId)
				Players.GetNameFromUserIdAsync = realLookup
				parked = coroutine.running()
				coroutine.yield()
				return realLookup(self, userId)
			end
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local fires = countFires(harness, "WinsDaily")
			harness.Ctx.Leaderboards.Stop()
			task.spawn(parked :: thread)
			task.wait(0.05)
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`fires={fires()} shown={shown}`).to.equal("fires=0 shown=0")
		end)

		--- Two offline, uncached players on the board, so a refresh needs two name lookups.
		local function twoOffline(harness)
			for _, userId in { 1032, 1033 } do
				local player, _, data = harness.Join(userId)
				data.Wins.Set(3)
				harness.Ctx.Leaderboards.FlushAllBlocking(1)
				harness.Leave(player)
			end
		end

		itHeadless("looks up no names after Stop when parked in its current-period read", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			twoOffline(harness)
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local lookups = 0
			Players.GetNameFromUserIdAsync = function(self, userId)
				lookups += 1
				return realLookup(self, userId)
			end
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			harness.Ctx.Leaderboards.Stop()
			resume()
			task.wait(0.05)
			Players.GetNameFromUserIdAsync = realLookup
			harness.Cleanup()
			restore()
			expect(`lookups={lookups}`).to.equal("lookups=0")
		end)

		itHeadless("looks up no further names after Stop when parked in a lookup", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			twoOffline(harness)
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local lookups = 0
			local parked: thread? = nil
			Players.GetNameFromUserIdAsync = function(self, userId)
				lookups += 1
				if lookups == 1 then
					parked = coroutine.running()
					coroutine.yield()
				end
				return realLookup(self, userId)
			end
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			harness.Ctx.Leaderboards.Stop()
			task.spawn(parked :: thread)
			task.wait(0.05)
			Players.GetNameFromUserIdAsync = realLookup
			harness.Cleanup()
			restore()
			expect(`lookups={lookups}`).to.equal("lookups=1")
		end)

		it("does not let a read in flight at the erase resurrect the user", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1014)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			harness.Leave(player)
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local ok = harness.Data.Erase(1014)
			resume()
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`ok={ok} shown={shown}`).to.equal("ok=true shown=0")
		end)

		it("does not let a previous-period read in flight at the erase resurrect the user", function()
			local set, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1016)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow("WinsDaily")
			harness.Leave(player)
			set(11 * DAY)
			-- The first refresh after a rollover reads yesterday.
			local resume = parkNextRead(harness, "WinsDaily", -1)
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local ok = harness.Data.Erase(1016)
			resume()
			local shown = #harness.Data.GetLeaderboard("WinsDaily", nil, -1)
			harness.Cleanup()
			restore()
			expect(`ok={ok} shown={shown}`).to.equal("ok=true shown=0")
		end)

		itHeadless("does not let a name lookup in flight at the erase resurrect the user", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1017)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			-- Offline and uncached, so the refresh asks the service for the name.
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local parked: thread? = nil
			Players.GetNameFromUserIdAsync = function(self, userId)
				Players.GetNameFromUserIdAsync = realLookup
				parked = coroutine.running()
				coroutine.yield()
				return realLookup(self, userId)
			end
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local ok = harness.Data.Erase(1017)
			task.spawn(parked :: thread)
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`ok={ok} shown={shown}`).to.equal("ok=true shown=0")
		end)

		itHeadless("does not look up the name of a user erased since the page was read", function()
			local _, restore = fixedClock(10 * DAY)
			local harness = makeHarness()
			local player, _, data = harness.Join(1018)
			data.Wins.Set(3)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Leave(player)
			local Players = game:GetService("Players")
			local realLookup = Players.GetNameFromUserIdAsync
			local lookups = 0
			Players.GetNameFromUserIdAsync = function(self, userId)
				lookups += 1
				return realLookup(self, userId)
			end
			local resume = parkNextRead(harness, "WinsDaily")
			task.spawn(harness.Ctx.Leaderboards.RefreshNow, "WinsDaily")
			local ok = harness.Data.Erase(1018)
			resume()
			Players.GetNameFromUserIdAsync = realLookup
			local shown = #harness.Data.GetLeaderboard("WinsDaily")
			harness.Cleanup()
			restore()
			expect(`ok={ok} shown={shown} lookups={lookups}`).to.equal("ok=true shown=0 lookups=0")
		end)
	end)
end
