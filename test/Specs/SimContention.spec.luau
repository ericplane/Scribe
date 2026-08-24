--!nonstrict
-- Many servers, one key space: the scenario the whole simulation exists for.
--
-- Everything here runs the REAL session-lock protocol. Nothing about stealing,
-- force-loading or dead-session recovery is modelled -- the vendored ProfileStore
-- does it, and the simulation only supplies the clock, the scheduler, the disk and
-- the message bus. A hand-written imitation of this protocol would be asserting
-- the model against itself, which is the one thing that would make all of it
-- worthless.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	-- Production puts conflict resolution at 40s and dead-session recovery at 630s.
	-- Both are reachable at those values -- virtual time is free -- but shortening
	-- them keeps each spec's step budget small.
	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 20,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	local function newUniverse(overrides)
		local config = {
			Seed = 4171,
			Servers = 2,
			Constants = CONSTANTS,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			-- Deliberately far out of reach: these specs study contention, and a
			-- bundle that slipped into Outage would refuse the very operations
			-- being measured.
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
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

	describe("session handoff between live servers", function()
		it("hands a player from one server to another, carrying their data", function()
			local uni = newUniverse()
			local a, b = uni:Server(1), uni:Server(2)

			local onA = FakePlayer.new(501)
			a:Join(501, onA)
			uni:Run(30)
			a.Bundle.Data.Get(onA).Coins.Set(1234)

			-- The player hops servers WITHOUT A's session being released first --
			-- which is what happens when a player teleports, or rejoins fast enough
			-- that the old server has not finished letting go.
			local onB = FakePlayer.new(501)
			b:Join(501, onB)
			uni:Run(180)

			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_501")
			expect(record).never.to.equal(nil)
			-- B holds the lock now...
			expect(record.Value.MetaData.ActiveSession[2]).to.equal(b.JobId)
			-- ...the session load count moved, which is how ownership is actually
			-- detected (not by watching ActiveSession change)...
			expect(record.Value.MetaData.SessionLoadCount >= 2).to.equal(true)
			-- ...and A's write was not lost in the handoff.
			expect(record.Value.Data.Coins).to.equal(1234)
		end)

		it("tells the losing server it lost, rather than letting it save on", function()
			-- A server that discovers it no longer owns a profile must drop it
			-- locally with NO final save, and -- the half this test used to miss --
			-- must not RECORD one either.
			--
			-- entry.SessionStolen (src/Server/Persistence.luau:2181) exists for
			-- exactly that: onProfileSaved returns early at :1000 when the entry was
			-- torn down by a steal, suppressing LastResult = "Ok", SavesOk,
			-- Health.ReportSuccess and the public OnSave signal for a save that
			-- reported success but did not persist THIS server's data.
			--
			-- The version before this one asserted only `Profile:IsActive() == false`,
			-- which is a property of the vendored store and holds whatever Scribe
			-- does. Measured: forcing SessionStolen false left every assertion in this
			-- file green while producing 14 extra SavesOk records.
			--
			-- Two things that look like the right assertion and are not, both measured:
			--   * `SaveInfo.LastResult ~= "Ok"` FAILS on correct code -- it is already
			--     "Ok" from an autosave that legitimately succeeded before the steal.
			--   * `entry.SessionStolen == true` passes, but it mirrors the field rather
			--     than its consequence, and would survive any rename that kept the bug.
			local uni = newUniverse()
			local a, b = uni:Server(1), uni:Server(2)

			local onA = FakePlayer.new(502)
			-- Connected BEFORE the load runs, and reading `entry` at fire time.
			-- Measured: A completes no successful save between the steal starting and
			-- the end of the run, so a listener attached after the load observes
			-- nothing at all on correct code -- and an assertion that the listener saw
			-- SOMETHING is what stops the one below passing on a dead signal.
			local entry
			local okSaves, okAfterTeardown = 0, 0
			a.Bundle.Ctx.Signals.OnSave:Connect(function(info)
				if info.Ok then
					okSaves += 1
					if entry ~= nil and entry.TornDown then
						okAfterTeardown += 1
					end
				end
			end)

			a:Join(502, onA)
			uni:Run(30)

			entry = a.Bundle.Ctx.Persistence.EntryFor(onA)
			expect(entry).never.to.equal(nil)

			b:Join(502, FakePlayer.new(502))
			uni:Run(180)

			-- A's profile is no longer active. ProfileStore reports this through
			-- the session-end path Scribe distinguishes from a local release.
			expect(entry.Profile:IsActive()).to.equal(false)
			expect(entry.TornDown).to.equal(true)

			-- A saved successfully at least once while it still owned the profile, so
			-- the signal is wired and the assertion below is not vacuous...
			expect(okSaves > 0).to.equal(true)
			-- ...and not once after it stopped owning it.
			expect(okAfterTeardown).to.equal(0)
		end)

		it("recovers a crashed server's lock without any cooperation", function()
			-- The other steal path. A crash releases nothing: the lock stays on
			-- disk with a stale timestamp, and recovery depends entirely on the
			-- ASSUME_DEAD deadline being reached -- which is why os.time has to be
			-- shared across servers, since the timestamp was written by the server
			-- that died.
			local uni = newUniverse()
			local a, b = uni:Server(1), uni:Server(2)

			local onA = FakePlayer.new(503)
			a:Join(503, onA)
			uni:Run(30)
			a.Bundle.Data.Get(onA).Coins.Set(555)
			uni:Run(30) -- let an autosave land

			local heldBefore = uni.Disk.Keyspace:Read("Default", "PLAYER_503")
			expect(heldBefore.Value.MetaData.ActiveSession[2]).to.equal(a.JobId)

			uni:Crash(1)

			-- B picks the player up. Nothing releases A's lock; only the deadline
			-- passing makes it stealable.
			b:Join(503, FakePlayer.new(503))
			uni:Run(300)

			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_503")
			expect(record.Value.MetaData.ActiveSession[2]).to.equal(b.JobId)
			expect(record.Value.Data.Coins).to.equal(555)
		end)
	end)

	describe("determinism across the whole stack", function()
		it("replays a contended multi-server run to an identical digest", function()
			-- The claim everything else rests on, made under contention rather than
			-- in a quiet single-server run: same seed, same interleaving, same
			-- stolen sessions, same bytes on disk.
			local function run()
				local uni = newUniverse({ Servers = 3 })
				for i = 1, 9 do
					local server = uni:Server((i % 3) + 1)
					server:Join(600 + i, FakePlayer.new(600 + i))
					uni:Run(4)
				end
				-- Contend: every server tries to take the same three players.
				for i = 1, 3 do
					uni:Server(3):Join(600 + i, FakePlayer.new(600 + i))
				end
				uni:Run(240)
				uni:Quiesce()
				uni:Settle(240)
				local digest = uni:Digest()
				Guard.Reset()
				universe = nil
				return digest
			end

			expect(run()).to.equal(run())
		end)

		it("gives different seeds different runs", function()
			-- If this failed, the scheduler would not be exploring anything and
			-- every contention result would be one fixed ordering reported as a
			-- search.
			local function digestFor(seed: number)
				local uni = newUniverse({ Seed = seed, Servers = 3 })
				for i = 1, 6 do
					uni:Server((i % 3) + 1):Join(700 + i, FakePlayer.new(700 + i))
				end
				uni:Server(1):Join(701, FakePlayer.new(701))
				uni:Run(180)
				uni:Quiesce()
				uni:Settle(180)
				local digest = uni:Digest()
				Guard.Reset()
				universe = nil
				return digest
			end

			local seen = {}
			local distinct = 0
			for seed = 1, 6 do
				local digest = digestFor(seed)
				if seen[digest] == nil then
					seen[digest] = true
					distinct += 1
				end
			end
			expect(distinct > 1).to.equal(true)
		end)
	end)

	describe("the message bus", function()
		it("delivers steal notifications, out of order and after a delay", function()
			-- Unordered on purpose. Roblox guarantees no ordering, so a FIFO model
			-- could HIDE a bug production has, while a reordering model can at worst
			-- surface one production hides. Only the second error is acceptable.
			local uni = newUniverse()
			local delivered = {}

			uni.Bus:Subscribe("test-topic", function(message)
				table.insert(delivered, message.Data.Index)
			end)
			for i = 1, 12 do
				uni.Bus:Publish("test-topic", { Index = i })
			end
			uni:Run(30)

			expect(#delivered).to.equal(12)
			local inOrder = true
			for i = 1, 12 do
				if delivered[i] ~= i then
					inOrder = false
					break
				end
			end
			expect(inOrder).to.equal(false)
		end)

		it("makes two subscribers hear the same message at different times", function()
			-- What the per-subscriber jitter uniquely buys. Delivery order alone does
			-- not prove it: the scheduler shuffles its ready set, so messages arrive
			-- out of order even on a fixed delay. Two servers listening to one topic
			-- genuinely do not hear it at the same instant, and collapsing that would
			-- remove an interleaving that exists.
			local uni = newUniverse()
			local heardAt = {}

			for listener = 1, 2 do
				uni.Bus:Subscribe("shared-topic", function()
					heardAt[listener] = uni.Sched.Now
				end)
			end
			uni.Bus:Publish("shared-topic", { Index = 1 })
			uni:Run(30)

			expect(heardAt[1]).never.to.equal(nil)
			expect(heardAt[2]).never.to.equal(nil)
			expect(heardAt[1]).never.to.equal(heardAt[2])
		end)

		it("does not deliver to a subscriber that disconnected mid-flight", function()
			-- A message can be in flight when its recipient goes away -- a crash, or
			-- ProfileStore tearing down a session subscription. Delivering into a
			-- torn-down handler would be a harness error dressed up as a finding.
			local uni = newUniverse()
			local heard = 0
			local service = uni.Bus:ServiceFor("listener")

			local connection
			uni.Sched:Spawn(function()
				connection = service:SubscribeAsync("doomed", function()
					heard += 1
				end)
			end)
			uni:Run(1)

			uni.Bus:Publish("doomed", { Index = 1 })
			-- Disconnect while the message is still on its way (bus latency is 1.5s).
			connection.Disconnect()
			uni:Run(30)

			expect(heard).to.equal(0)
		end)

		it("refuses to build a universe without StatusThresholds", function()
			-- Health flips to Degraded at three failures in a minute and Outage at
			-- six, and Outage refuses gifts, restores, erases and receipts. A
			-- realistic throttle model at high CCU crosses that trivially, so a
			-- scenario that never chose its thresholds would stumble into Outage and
			-- report the same finding every run -- an artefact presented as a
			-- property of Scribe.
			local ok, err = pcall(function()
				return Universe.new({ Seed = 1, Servers = 1 })
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "StatusThresholds", 1, true) ~= nil).to.equal(true)
		end)
		it("drops a publish rather than raising", function()
			-- ProfileStore calls PublishAsync bare inside a task.spawn with the
			-- error uncaught, so a bus that threw would abort the entire run and
			-- report a harness artefact as a Scribe failure.
			local uni = newUniverse({ BusDropRate = 1.0 })
			local delivered = 0
			uni.Bus:Subscribe("lossy", function()
				delivered += 1
			end)

			local ok = pcall(function()
				uni.Bus:Publish("lossy", { Index = 1 })
			end)
			uni:Run(30)

			expect(ok).to.equal(true)
			expect(delivered).to.equal(0)
			expect(uni.Bus.Stats.Dropped > 0).to.equal(true)
		end)

		it("still hands off when every message is lost", function()
			-- Best-effort really is best-effort: with the bus fully down the handoff
			-- has to complete on ProfileStore's polling path alone. A simulation
			-- that only worked with a healthy bus would be unable to say anything
			-- about the case that actually worries people.
			local uni = newUniverse({ BusDropRate = 1.0 })
			local a, b = uni:Server(1), uni:Server(2)

			a:Join(504, FakePlayer.new(504))
			uni:Run(30)
			b:Join(504, FakePlayer.new(504))
			uni:Run(300)

			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_504")
			expect(record.Value.MetaData.ActiveSession[2]).to.equal(b.JobId)
		end)
	end)
end
