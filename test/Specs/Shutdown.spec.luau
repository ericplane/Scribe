--!nonstrict
-- Shutdown (BindToClose): stop accepting new sessions, flush the leaderboard
-- queue, end every profile session within the budget.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	it("drains sessions and the leaderboard queue on shutdown", function()
		local harness = TestCtx.make({
			Options = {
				Leaderboards = {
					TopCoins = { Stat = "Coins", Limit = 10 },
				},
			},
		})

		local _playerA, _entryA, dataA = harness.Join(7001)
		local _playerB, _entryB, dataB = harness.Join(7002)
		dataA.Coins.Set(150)
		dataB.Coins.Set(75)

		local writesBefore = Scribe.GetMetrics().LbWrites or 0

		-- The shutdown drain (what game:BindToClose invokes).
		harness.Ctx.Persistence.Shutdown(5)

		-- Every session ended and saved.
		expect(next(harness.Ctx.Persistence.Entries)).to.equal(nil)
		expect(harness.Fake.Persisted["Default/PLAYER_7001"].Coins).to.equal(150)
		expect(harness.Fake.Persisted["Default/PLAYER_7002"].Coins).to.equal(75)
		expect(next(harness.Fake.ActiveProfiles)).to.equal(nil)

		-- The paced leaderboard queue was force-drained.
		local writesAfter = Scribe.GetMetrics().LbWrites or 0
		expect(writesAfter - writesBefore >= 2).to.equal(true)

		-- Server leaderboard reads see the flushed scores (in-memory store).
		-- (The refresh cycle hasn't run; read the store through the public API
		-- after a manual refresh is out of scope here; flushed writes suffice.)

		-- New sessions are refused while closing.
		local latecomer = FakePlayer.new(7003)
		harness.Ctx.Persistence.OnPlayerAdded(latecomer)
		expect(harness.Ctx.Persistence.EntryFor(latecomer)).to.equal(nil)

		-- Structured shutdown logging.
		expect(#Scribe.GetRecentLogs({ Code = "SHUTDOWN_FLUSH", Limit = 3 }) > 0).to.equal(true)
		expect(#Scribe.GetRecentLogs({ Code = "SHUTDOWN_DONE", Limit = 3 }) > 0).to.equal(true)

		harness.Cleanup()
	end)

	it("marks trees dead after shutdown so late writes fail loudly", function()
		local harness = TestCtx.make()
		local _, entry, data = harness.Join()
		harness.Ctx.Persistence.Shutdown(5)

		expect(entry.Tree.Dead).to.equal(true)
		expect(function()
			data.Coins.Set(1)
		end).to.throw()

		harness.Cleanup()
	end)
	-- The STORE half of the drain, which CI could not see at all until
	-- FakeProfileStore learned BeginClose and AwaitClose. Persistence guards both
	-- calls with `type(...) == "function"`, so with the fake silent on them the
	-- whole handshake was two guarded calls to nothing: deleting either one from
	-- Persistence.Shutdown left the suite green.
	--
	-- Note these are about the STORE's flag, not Scribe's own `self.Closing`. The
	-- test above already covers Scribe refusing a latecomer through its own gate,
	-- and that assertion passes whether or not BeginClose is ever called.
	describe("the store half of the drain", function()
		it("tells the store to stop starting sessions, not just Scribe", function()
			local harness = TestCtx.make({})
			local _player, _entry, data = harness.Join(7101)
			data.Coins.Set(11)

			expect(harness.Fake.IsClosing).to.equal(false)
			harness.Ctx.Persistence.Shutdown(5)

			-- A session started straight off the store, bypassing Scribe entirely --
			-- which is the only way to ask whether the STORE was told.
			local direct = harness.Fake.New("Default", { Coins = 0 })
			local refused = direct:StartSessionAsync("SHUTDOWN_LATE", {
				Cancel = function()
					return false
				end,
			})
			expect(`closing={harness.Fake.IsClosing} refused={refused == nil}`).to.equal("closing=true refused=true")
			harness.Cleanup()
		end)

		it("releases a session the store holds that Scribe never registered", function()
			-- AwaitClose's documented job is to "sweep up any profile Scribe does not
			-- know about". Nothing produced one, so the sweep had never run against
			-- anything: measured, all ten AwaitClose calls in a full suite run saw
			-- `held=0 loadJobs=0`.
			--
			-- A second store over the same fake is such a profile: a real server can
			-- hold one through any ProfileStore consumer that is not Scribe.
			local harness = TestCtx.make({})
			local _player, _entry, data = harness.Join(7102)
			data.Coins.Set(22)

			local stray = harness.Fake.New("Default", { Coins = 0 })
			local strayProfile = stray:StartSessionAsync("SHUTDOWN_STRAY", {
				Cancel = function()
					return false
				end,
			})
			strayProfile:AddUserId(7102)
			strayProfile.Data.Coins = 33
			expect(strayProfile:IsActive()).to.equal(true)

			harness.Ctx.Persistence.Shutdown(5)

			-- Ended, and its last write is on disk -- the whole point of a drain.
			local stored = harness.Fake.Persisted["Default/SHUTDOWN_STRAY"]
			expect(`active={strayProfile:IsActive()} stored={stored and stored.Coins}`).to.equal(
				"active=false stored=33"
			)
			harness.Cleanup()
		end)

		it("leaves nothing behind for a load that lands mid-drain", function()
			-- The other half of "does not return while a load is still in flight": the
			-- drain waits for that load, and the load must not hand back a live session
			-- once it finishes.
			--
			-- The fork does this at ProfileStore.luau:2353 -- a load that claims a
			-- session and then finds the server closing releases it and returns nil,
			-- before decrementing its load-job count. That is why AwaitClose can clone
			-- its active list once, up front, and why the "window" I recorded against
			-- the fork in an earlier progress note does not exist. The fake reproduced
			-- the note rather than the fork, and left a live session behind: measured,
			-- `minted=true active=true` where the fork leaves nothing.
			--
			-- This is the arm of that check the FAKE can reach and the fork cannot.
			-- In the simulation the modelled disk has no yield between the transform's
			-- commit and the check, so a concurrent BeginClose always lands earlier;
			-- StoreAccessors reaches the same block through its `cancel_condition()`
			-- arm instead. Between them the block is held from both sides.
			local harness = TestCtx.make({})
			harness.Fake.YieldOnSessionStart = true

			local direct = harness.Fake.New("Default", { Coins = 0 })
			local returned, finished = nil, false
			task.spawn(function()
				returned = direct:StartSessionAsync("SHUTDOWN_MINTED", {
					Cancel = function()
						return false
					end,
				})
				finished = true
			end)
			-- Under way, and past the point where the closing flag would turn it away.
			expect(`inflight={harness.Fake.ActiveLoadJobs}`).to.equal("inflight=1")

			harness.Ctx.Persistence.Shutdown(5)

			local left = harness.Fake.ActiveProfiles["Default/SHUTDOWN_MINTED"]
			expect(`finished={finished} returned={returned ~= nil} left={left ~= nil}`).to.equal(
				"finished=true returned=false left=false"
			)
			harness.Cleanup()
		end)

		it("does not return while a load is still in flight", function()
			-- The job-drain half. AwaitClose waits on the store's outstanding load
			-- count, and without that wait Shutdown returns while a session is still
			-- being minted -- so a key can come back to life after the drain reported
			-- itself complete.
			--
			-- YieldOnSessionStart is what makes the window wide enough to observe; the
			-- real store's StartSessionAsync yields on every call.
			local harness = TestCtx.make({})
			harness.Fake.YieldOnSessionStart = true

			local direct = harness.Fake.New("Default", { Coins = 0 })
			local finished = false
			task.spawn(function()
				direct:StartSessionAsync("SHUTDOWN_INFLIGHT", {
					Cancel = function()
						return false
					end,
				})
				finished = true
			end)
			-- Parked inside the load, counted as outstanding.
			expect(`inflight={harness.Fake.ActiveLoadJobs} finished={finished}`).to.equal("inflight=1 finished=false")

			harness.Ctx.Persistence.Shutdown(5)

			-- Read the instant Shutdown returns: the load it was waiting on is done.
			expect(`inflight={harness.Fake.ActiveLoadJobs} finished={finished}`).to.equal("inflight=0 finished=true")
			harness.Cleanup()
		end)
	end)
end
