--!nonstrict
-- A message may only be retired by the same UpdateAsync that persists the data it
-- produced. Driven against the REAL fork, because that is where the rule lives.
--
-- ProfileStore's delivery is at-least-once by construction and Scribe depends on
-- it: processed() only sets a lock flag in memory, and the PHYSICAL removal of the
-- update from GlobalUpdates happens in a LATER save's transform -- the same
-- transform that writes profile.Data. Fusing those two halves is what makes the
-- guarantee hold. Acknowledge and persist together and a crash between them
-- redelivers; separate them and the message's effect can be discarded while the
-- message itself is gone, which is at-MOST-once with nothing to notice it.
--
-- The fork separated them. The sweep sat inside `if session_owns_profile` but
-- OUTSIDE the `scribe_release_only ~= true` gate, so a release that deliberately
-- writes no Data still deleted every acknowledged update: the gift was consumed
-- into profile.Data, profile.Data was then not written, and the message that would
-- have redelivered it was retired anyway.
--
-- WHY IT IS INVISIBLE TODAY, which is also why this drives the store directly
-- rather than through Scribe: Persistence registers its MessageHandler only once a
-- profile reaches Ready, and all three release-only call sites are pre-Ready load
-- paths. locked_global_updates is therefore always empty when they run, and the
-- sweep removes nothing. None of that is an invariant -- EndSessionWithoutSaving
-- is a public method on the profile -- so the rule is asserted at the layer that
-- owns it.
--
-- Driven inside a simulated universe rather than by requiring the store module
-- directly, for the reason StoreAccessors.spec gives: the fork reaches for
-- MessagingService, which the headless shim does not provide, while every
-- simulated server already loads it into an environment that has one.
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

	local universe

	local function forkStore()
		universe = Universe.new({
			Seed = 707070,
			Servers = 1,
			-- A store contract wants the store's own behaviour, not an autosave racing
			-- it: an autosave between the acknowledgement and the release would retire
			-- the update legitimately, and the spec would be measuring timing.
			Constants = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 },
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		local Module = universe:Server(1).Bundle.Options.ProfileStore
		return universe, Module.New("Default", { Coins = 0 })
	end

	--- Everything here yields on the modelled disk, so nothing can be called inline.
	--- A bounded run and an explicit error, rather than an unbounded wait: a call
	--- that never settles has to fail HERE and not as the runner's timeout.
	local function drive(uni, fn)
		local out = {}
		uni.Sched:Spawn(function()
			fn(out)
			out.Done = true
		end)
		uni:Run(120)
		if not out.Done then
			error("store call never settled", 2)
		end
		return out
	end

	local function session(store, key: string)
		return store:StartSessionAsync(key, {
			Cancel = function()
				return false
			end,
		})
	end

	--- Post a message to a profile this same server holds, and let the delivery
	--- complete before returning.
	---
	--- THE SEQUENCING HERE IS THE WHOLE SETUP, and it took a measurement to get
	--- right. MessageAsync does not only commit the update: when the recipient is
	--- active in this very server it calls profile:Save() itself, and THAT save is
	--- what delivers the message and locks it. Its own transform ran before anything
	--- was locked, so it sweeps nothing. Retirement therefore falls to whichever save
	--- comes NEXT -- which is precisely the save each test below arranges to be.
	---
	--- Written as a wait rather than a SaveAwait for that reason: a save issued here
	--- would be the sweeping one, and the test would have no move left to make.
	local function postAndDeliver(uni, store, key: string, message: any)
		store:MessageAsync(key, message)
		uni.Sched:Wait(5)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("a release that writes no Data", function()
		it("leaves acknowledged messages in storage, so the next session is handed them again", function()
			local uni, store = forkStore()
			local key = "REL_MSG_1"

			local first = drive(uni, function(out)
				local profile = session(store, key)
				out.Seen = {}
				profile:MessageHandler(function(message, processed)
					table.insert(out.Seen, message.Seq)
					-- Acknowledged: the id is locked in memory now, and a SAVE is what is
					-- supposed to retire it from the key.
					processed()
				end)

				postAndDeliver(uni, store, key, { Seq = 1 })
				out.Delivered = #out.Seen

				-- Act on the message the way a gift handler would, then release without
				-- writing. That is the fused-retirement violation in two lines: the
				-- effect exists only in memory, and the save about to run discards that
				-- memory while retiring the message that carried it.
				profile.Data.Coins = 40
				profile.scribe_release_only = true
				out.Release = profile:SaveAwait()

				profile:EndSession()
			end)

			-- The message was delivered and acknowledged before the release ran.
			-- Without this the redelivery below would prove nothing: a message that was
			-- never locked was never at risk of being swept.
			expect(first.Delivered).to.equal(1)
			expect(first.Seen[1]).to.equal(1)
			-- A successful write, not a failed one -- otherwise these assertions would
			-- also pass against a store whose release simply errored.
			expect(first.Release).to.equal("Saved")

			-- Let the ending session's release land and the lock clear before the next
			-- session asks for the key.
			uni:Run(60)

			local second = drive(uni, function(out)
				local profile = session(store, key)
				out.Coins = profile.Data.Coins
				out.Seen = {}
				profile:MessageHandler(function(message, processed)
					table.insert(out.Seen, message.Seq)
					processed()
				end)
				-- MessageHandler delivers pending updates through task.spawn, so give
				-- the scheduler a moment rather than reading on the next line.
				uni.Sched:Wait(1)
				profile:EndSession()
			end)

			-- The 40 coins were never written -- that is the whole point of a
			-- release-only save, and it is what makes the redelivery load-bearing
			-- rather than a harmless duplicate.
			expect(second.Coins).to.equal(0)
			-- So the message has to still be there. Dropping it here is the difference
			-- between at-least-once and a silently lost grant.
			expect(#second.Seen).to.equal(1)
			expect(second.Seen[1]).to.equal(1)
		end)

		it("does not stop an ORDINARY save from retiring them", function()
			-- The counterpart, and the reason the fix is one extra conjunct rather than
			-- deleting the sweep: a save that writes Data must still retire what it
			-- covered, or every message is redelivered forever and every gift lands
			-- twice.
			local uni, store = forkStore()
			local key = "REL_MSG_2"

			local first = drive(uni, function(out)
				local profile = session(store, key)
				out.Seen = {}
				profile:MessageHandler(function(message, processed)
					table.insert(out.Seen, message.Seq)
					processed()
				end)

				postAndDeliver(uni, store, key, { Seq = 7 })
				out.Delivered = #out.Seen

				profile.Data.Coins = 40
				-- No flag: an ordinary save, which persists the 40 AND retires the
				-- update it covers, in one UpdateAsync.
				out.Retire = profile:SaveAwait()

				profile:EndSession()
			end)

			expect(first.Delivered).to.equal(1)
			expect(first.Retire).to.equal("Saved")

			uni:Run(60)

			local second = drive(uni, function(out)
				local profile = session(store, key)
				out.Coins = profile.Data.Coins
				out.Seen = {}
				profile:MessageHandler(function(message, processed)
					table.insert(out.Seen, message.Seq)
					processed()
				end)
				uni.Sched:Wait(1)
				profile:EndSession()
			end)

			expect(second.Coins).to.equal(40)
			expect(#second.Seen).to.equal(0)
		end)
	end)
end
