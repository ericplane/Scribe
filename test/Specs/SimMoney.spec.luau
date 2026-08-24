--!nonstrict
-- The two scenarios the capacity study left unrun: what a Robux receipt does when
-- the datastore is in outage, and what an oversized profile does to a session.
--
-- Both are money paths in the sense that matters -- one eats Robux if it is wrong,
-- the other silently stops persisting a player who has already paid for things.
-- They run against the real vendored ProfileStore over the modelled disk, so the
-- retry behaviour is the library's own rather than a guess about it.

return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Scribe = require(Root.Scribe)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet

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
			Seed = 20260817,
			Servers = 1,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	local function receipt(userId: number, productId: number, purchaseId: string)
		return {
			PlayerId = userId,
			ProductId = productId,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	--- Call a yielding Scribe API from the spec thread without parking it.
	local function call(uni, fn)
		local result, failed
		uni.Sched:Spawn(function()
			local ok, value = pcall(fn)
			if ok then
				result = value
			else
				failed = value
			end
		end)
		uni:Run(120)
		return result, failed
	end

	--- Drive a bundle into Outage with real DataStore failures.
	---
	--- The failures have to land INSIDE Health's window, which is the whole trick.
	--- An earlier version flushed in a loop, each flush advancing 120 virtual
	--- seconds while the window is 60 -- so twelve genuine failures were reported
	--- and no two ever counted together. Health stayed Healthy and it looked like
	--- Scribe was ignoring save failures. It was the harness pacing them apart.
	---
	--- It also has to fail SEVERAL profiles, which is newer. Health collapses
	--- repeated failures of one key into a single problem, because one profile
	--- failing forever -- an oversize one, say -- is that player's problem and
	--- must not refuse Robux for everyone else on the server. So an outage is
	--- now modelled the way a real one behaves: many keys failing, not one key
	--- failing many times.
	local function driveToOutage(uni, server, player)
		-- Joined BEFORE the fault is armed, or their loads fail instead.
		local others = {}
		for i = 1, 3 do
			local extra = FakePlayer.new(78100 + i)
			server:Join(78100 + i, extra)
			table.insert(others, extra)
		end
		uni:Run(2)
		uni.Disk:Arm({ Kind = "ServiceError", Count = 4000 })
		for i = 1, 12 do
			server.Bundle.Data.Get(player).Coins.Increment(1)
			uni.Sched:Spawn(function()
				pcall(function()
					return server.Bundle.Data.Flush(player, { Timeout = 20 })
				end)
			end)
			for _, extra in others do
				local data = server.Bundle.Data.Get(extra)
				if data then
					data.Coins.Increment(1)
					uni.Sched:Spawn(function()
						pcall(function()
							return server.Bundle.Data.Flush(extra, { Timeout = 20 })
						end)
					end)
				end
			end
			local _ = i
			uni:Run(2) -- close together: every failure inside one 60s window
		end
		uni:Run(30)
	end
	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("receipts while the datastore is in outage", function()
		local function moneyUniverse()
			return build({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = {
					Products = {
						CoinPack = {
							Id = 111,
							Grant = function(data)
								data.Coins.Increment(1000)
							end,
						},
					},
				},
				-- Deliberately tight, so a short burst of failures reaches Outage.
				-- Health derives its Outage threshold as max(FailCount*2, FailCount+1),
				-- so FailCount = 3 puts Outage at 6 failures inside the window.
				StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 2 },
			})
		end

		it("refuses the receipt rather than eating the Robux", function()
			local uni = moneyUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(50001)

			server:Join(50001, player)
			uni:Run(30)
			expect(server.Bundle.Health.GetStatus()).to.equal("Healthy")

			-- Drive the bundle into Outage with real DataStore failures.
			driveToOutage(uni, server, player)

			expect(server.Bundle.Health.GetStatus()).to.equal("Outage")

			local baseline = server.Bundle.Data.Get(player).Coins.Get()

			-- The purchase arrives mid-outage.
			local decision = call(uni, function()
				return server.Bundle.Data.HandleReceipt(receipt(50001, 111, "pid-outage-1"))
			end)

			-- Roblox will retry a NotProcessedYet receipt, so refusing is how the
			-- Robux stays with the player rather than being taken for a grant that
			-- could not be persisted.
			expect(decision).to.equal(NOT_PROCESSED)
			-- Compared against the balance going in, not against zero: driving the
			-- bundle into outage dirties the profile deliberately, so the baseline is
			-- whatever those writes left behind. What matters is that the 1000-coin
			-- grant did not land.
			expect(server.Bundle.Data.Get(player).Coins.Get()).to.equal(baseline)
		end)

		it("grants exactly once when the outage clears and Roblox retries", function()
			local uni = moneyUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(50002)

			server:Join(50002, player)
			uni:Run(30)

			driveToOutage(uni, server, player)
			expect(server.Bundle.Health.GetStatus()).to.equal("Outage")

			local baseline = server.Bundle.Data.Get(player).Coins.Get()

			-- Roblox retries the same PurchaseId repeatedly while it is refused.
			for _ = 1, 3 do
				expect(call(uni, function()
					return server.Bundle.Data.HandleReceipt(receipt(50002, 111, "pid-outage-2"))
				end)).to.equal(NOT_PROCESSED)
			end
			expect(server.Bundle.Data.Get(player).Coins.Get()).to.equal(baseline)

			-- The datastore recovers.
			uni.Disk:Heal()
			for _ = 1, 6 do
				call(uni, function()
					return server.Bundle.Data.Flush(player, { Timeout = 15 })
				end)
			end
			uni:Run(120)

			local recovered = server.Bundle.Health.GetStatus()
			local decision = call(uni, function()
				return server.Bundle.Data.HandleReceipt(receipt(50002, 111, "pid-outage-2"))
			end)

			-- The grant lands once, and stays once however many times Roblox
			-- re-delivers the same purchase.
			expect(decision).to.equal(GRANTED)
			expect(server.Bundle.Data.Get(player).Coins.Get()).to.equal(baseline + 1000)
			for _ = 1, 3 do
				expect(call(uni, function()
					return server.Bundle.Data.HandleReceipt(receipt(50002, 111, "pid-outage-2"))
				end)).to.equal(GRANTED)
			end
			expect(server.Bundle.Data.Get(player).Coins.Get()).to.equal(baseline + 1000)
			expect(recovered).never.to.equal("Outage")
		end)

		it("persists the grant it reported as durable", function()
			-- The claim behind PurchaseGranted is that the grant survived. Reporting
			-- it while the write is still in the air would be the expensive bug: the
			-- player is charged, Roblox stops retrying, and the coins never arrive.
			local uni = moneyUniverse()
			local server = uni:Server(1)
			local player = FakePlayer.new(50003)

			server:Join(50003, player)
			uni:Run(30)

			local decision = call(uni, function()
				return server.Bundle.Data.HandleReceipt(receipt(50003, 111, "pid-durable"))
			end)
			expect(decision).to.equal(GRANTED)

			-- Read the disk directly, without giving the server a chance to flush.
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_50003")
			expect(record).never.to.equal(nil)
			expect(record.Value.Data.Coins).to.equal(1000)
		end)
	end)

	describe("a profile that outgrows the datastore ceiling", function()
		local function bigUniverse(capBytes: number)
			return build({
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Blob = Scribe.String("", { MaxLength = 2000000 }),
				},
				-- The real ceiling is 4 MB. Building a genuine 4 MB profile inside a
				-- test budget is not viable, so the CAP moves instead of the data --
				-- the mechanism under test is what an unpersistable profile does, and
				-- that does not depend on the absolute number.
				ValueBytes = capBytes,
			})
		end

		it("keeps the last good save when a profile grows past the ceiling", function()
			local uni = bigUniverse(32 * 1024)
			local server = uni:Server(1)
			local player = FakePlayer.new(60001)

			server:Join(60001, player)
			uni:Run(30)

			-- A modest, saveable profile first.
			local data = server.Bundle.Data.Get(player)
			data.Coins.Set(4242)
			call(uni, function()
				return server.Bundle.Data.Flush(player, { Timeout = 30 })
			end)
			expect(uni.Disk.Keyspace:Read("Default", "PLAYER_60001").Value.Data.Coins).to.equal(4242)
			local versionBefore = uni.Disk.Keyspace:Version("Default", "PLAYER_60001")

			-- Now push it past the ceiling.
			data.Blob.Set(string.rep("x", 64 * 1024))
			local flushed = call(uni, function()
				return server.Bundle.Data.Flush(player, { Timeout = 30 })
			end)

			-- The oversized save cannot land...
			expect(flushed).never.to.equal(true)
			expect(uni.Disk.Keyspace:Version("Default", "PLAYER_60001")).to.equal(versionBefore)
			-- ...and crucially the previously-saved data is untouched, not corrupted
			-- or half-written.
			local record = uni.Disk.Keyspace:Read("Default", "PLAYER_60001")
			expect(record.Value.Data.Coins).to.equal(4242)
			expect(record.Value.Data.Blob).to.equal("")
		end)

		it(
			"retries an impossible save forever, without corrupting the last good one or stranding the player",
			function()
				-- ProfileStore pcalls every store call and turns each one into the same
				-- "did not happen", so a PERMANENT error is indistinguishable from a
				-- transient one and an ending-session save retries with backoff.
				--
				-- The previous version of this test was called "does not spin forever" and
				-- asserted only that the scheduler had not deadlocked -- which an
				-- infinitely-retrying-with-backoff save does not do. Measured, it DOES spin
				-- forever: the retry cadence holds at ~20 s out to 12 virtual hours and the
				-- lock is never released. So the title was wrong as well as unasserted.
				--
				-- What actually matters operationally is the pair below, and both are
				-- measured rather than assumed: the last good save is untouched, and the
				-- player is still recoverable on another server despite the held lock.
				-- Note that BOTH obvious guesses are false -- the lock is not released, and
				-- the player is not stranded.
				local uni = bigUniverse(32 * 1024)
				local server = uni:Server(1)
				local player = FakePlayer.new(60002)

				server:Join(60002, player)
				uni:Run(30)

				-- A good save first, so there is something specific to preserve.
				server.Bundle.Data.Get(player).Coins.Set(777)
				expect(call(uni, function()
					return server.Bundle.Data.Flush(player, { Timeout = 30 })
				end)).to.equal(true)
				local goodVersion = uni.Disk.Keyspace:Version("Default", "PLAYER_60002")

				-- Now make the profile unsaveable and leave, forcing the ending save.
				server.Bundle.Data.Get(player).Blob.Set(string.rep("y", 64 * 1024))

				-- Scribe must not report an unsaveable profile as durable. Asserted here as
				-- well as in the sibling test above, because this is the money-path failure
				-- that matters most and the two tests reach it by different routes: there
				-- the profile is still loaded, here it is on its way out.
				expect(call(uni, function()
					return server.Bundle.Data.Flush(player, { Timeout = 30 })
				end)).never.to.equal(true)

				local writesBefore = uni.Disk.Stats.Writes
				local before = uni.Sched.Now
				server:Leave(60002)
				while uni.Sched.Now - before < 3600 do
					uni:Run(60)
				end

				-- It does not take the simulation with it.
				expect(uni.Sched.Deadlocked).to.equal(false)
				expect(uni.Sched.Stalled).to.equal(false)
				-- Not one of those retries committed anything.
				expect(uni.Disk.Stats.Writes - writesBefore).to.equal(0)

				-- The lock is still held an hour later. This is the fact the old test
				-- printed and did not assert.
				local record = uni.Disk.Keyspace:Read("Default", "PLAYER_60002")
				local session = record.Value.MetaData.ActiveSession
				expect(session).never.to.equal(nil)
				expect(session[2]).to.equal("sim-server-1")

				-- ...and the last good save is exactly as it was: not corrupted, not
				-- half-written, not advanced by a retry.
				expect(uni.Disk.Keyspace:Version("Default", "PLAYER_60002")).to.equal(goodVersion)
				expect(record.Value.Data.Coins).to.equal(777)
				expect(record.Value.Data.Blob).to.equal("")

				-- The player is NOT stranded. Another server steals the stale lock and
				-- loads them with the last good data -- which is what makes an unreleased
				-- lock survivable rather than terminal.
				local rescue = uni:AddServer()
				local rejoined = FakePlayer.new(60002)
				rescue:Join(60002, rejoined)
				uni:Run(900)

				local recovered = rescue.Bundle.Data.Get(rejoined)
				expect(recovered).never.to.equal(nil)
				expect(recovered.Coins.Get()).to.equal(777)
				expect(recovered.Blob.Get()).to.equal("")
				local after = uni.Disk.Keyspace:Read("Default", "PLAYER_60002")
				expect(after.Value.MetaData.ActiveSession[2]).to.equal(rescue.JobId)
			end
		)

		it("warns before the profile becomes unsaveable", function()
			-- Scribe's only defence is a heuristic: it measures its own cheap
			-- approximation of the profile size and warns past 3.5 MiB, firing an
			-- OnAnomaly with Reason "ProfileSize". That warning is what turns an
			-- eventual silent save failure into something a developer can act on.
			--
			-- THREE things about this test are counter-intuitive and each was measured
			-- rather than reasoned, because the version before this one got all three
			-- wrong at once and asserted a tautology instead:
			--
			--  * The blob has to be bigger than the 3,600,000 the old test used.
			--    approxSize of a 3,600,000-char string is 3,600,021, and the threshold
			--    is 3.5 MiB = 3,670,016. It never crossed.
			--  * MaxLength has to be raised. The shared template caps Blob at 2,000,000,
			--    so the write was clamped long before size mattered.
			--  * The observable has to be the SERVER'S OWN signal. Requiring
			--    Internal.Log from a spec gets the harness's module instance, and a
			--    simulated server has a private copy -- so the old collector watched a
			--    ring buffer the code under test never wrote to, and saw nothing.
			local uni = build({
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Blob = Scribe.String("", { MaxLength = 8000000 }),
				},
				ValueBytes = 8 * 1024 * 1024,
			})
			local server = uni:Server(1)
			local player = FakePlayer.new(60003)

			local anomalies = {}
			server.Bundle.Ctx.Signals.OnAnomaly:Connect(function(info)
				table.insert(anomalies, tostring(info.Reason))
			end)

			server:Join(60003, player)
			uni:Run(30)
			-- Just over the 3.5 MiB warn threshold by Scribe's own measure, and under
			-- the cap, so the save itself still succeeds: this is the PROACTIVE path,
			-- not the post-failure one.
			server.Bundle.Data.Get(player).Blob.Set(string.rep("z", 3700000))
			local flushed = call(uni, function()
				return server.Bundle.Data.Flush(player, { Timeout = 60 })
			end)
			expect(flushed).to.equal(true)

			-- The write was not clamped, so size is what the warning saw.
			expect(#server.Bundle.Data.Get(player).Blob.Get()).to.equal(3700000)
			-- The Reason is asserted, not just the count. A count-only assertion passes
			-- for the wrong reason: with the old MaxLength the clamp fires its OWN
			-- anomaly ("OverMaxLength"), so `#anomalies == 1` stayed green with the
			-- size warning deleted entirely.
			expect(#anomalies).to.equal(1)
			expect(anomalies[1]).to.equal("ProfileSize")
		end)
	end)
end
