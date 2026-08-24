--!nonstrict
-- How loud a failing leaderboard store is allowed to be.
--
-- Every OrderedDataStore call fails for the whole session when Studio API access is off,
-- and the three failure sites logged one Warn per attempt: per queued write, per write
-- abandoned after retries, and per board per refresh. The Output filled with the same
-- line. Metrics (LbReadFailures, LbWriteFailures) still count every attempt; only the
-- logging is bounded.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Clock = require(ScribeRoot.Internal.Clock)
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local API_OFF = "403: Studio access to APIs is not allowed"

	local function makeHarness()
		return TestCtx.make({
			Options = { Leaderboards = { TopCoins = { Stat = "Coins", Limit = 10 } } },
		})
	end

	--- Make every read on the board's store fail with `err`.
	local function breakReads(harness, err: string)
		local store = harness.Ctx.Leaderboards.MockStoreFor("TopCoins")
		store.GetSortedAsync = function()
			error(err, 0)
		end
		return store
	end

	local function readFailsDuring(body: () -> ()): { string }
		local seen = {}
		local unsubscribe = Scribe.AddLogSink(function(entry)
			if entry.Code == "LB_READ_FAIL" then
				table.insert(seen, tostring(entry.Message))
			end
		end)
		local ok, err = pcall(body)
		if unsubscribe then
			unsubscribe()
		end
		if not ok then
			error(err, 0)
		end
		return seen
	end

	describe("a leaderboard store that keeps failing", function()
		afterEach(function()
			Clock.Reset()
		end)

		it("reports the Studio API setting once, however many times it fails", function()
			local harness = makeHarness()
			breakReads(harness, API_OFF)
			local before = Metrics.Get().LbReadFailures or 0

			local logged = readFailsDuring(function()
				for _ = 1, 25 do
					harness.Ctx.Leaderboards.RefreshNow("TopCoins")
				end
			end)

			-- One line, and it names the setting rather than repeating the raw error.
			expect(#logged).to.equal(1)
			expect(string.find(logged[1], "Studio API access is off", 1, true) ~= nil).to.equal(true)
			expect(string.find(logged[1], "Enable Studio Access to API Services", 1, true) ~= nil).to.equal(true)

			-- Every attempt is still counted, which is what stays accurate while it is quiet.
			expect((Metrics.Get().LbReadFailures or 0) - before).to.equal(25)

			harness.Cleanup()
		end)

		it("throttles an ordinary store error rather than silencing it", function()
			local now = 0
			Clock.Install({
				Now = function()
					return now
				end,
				Monotonic = function()
					return now
				end,
			})

			local harness = makeHarness()
			breakReads(harness, "502: API Services rejected request")

			-- Ten failures inside one window produce one line...
			local first = readFailsDuring(function()
				for _ = 1, 10 do
					harness.Ctx.Leaderboards.RefreshNow("TopCoins")
				end
			end)
			expect(#first).to.equal(1)

			-- ...and it carries what it suppressed on the NEXT one through, once the
			-- window has passed. This is the half that proves it is a throttle and not
			-- a permanent silence.
			now += 31
			local second = readFailsDuring(function()
				harness.Ctx.Leaderboards.RefreshNow("TopCoins")
			end)
			expect(#second).to.equal(1)
			expect(string.find(second[1], "more since the last of these", 1, true) ~= nil).to.equal(true)

			harness.Cleanup()
		end)

		it("says nothing at all while the store is healthy", function()
			local harness = makeHarness()
			local logged = readFailsDuring(function()
				for _ = 1, 10 do
					harness.Ctx.Leaderboards.RefreshNow("TopCoins")
				end
			end)
			expect(#logged).to.equal(0)
			harness.Cleanup()
		end)
	end)
end
