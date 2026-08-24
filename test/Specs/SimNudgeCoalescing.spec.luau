--!nonstrict
-- A cross-server nudge that arrives inside the throttle window is DEFERRED, not
-- dropped -- and the window itself does not move.
--
-- WHAT WAS WRONG. ProfileStore answers a MessagingService nudge at most once every
-- six seconds, and upstream wrote that throttle as a bare
--     if os.clock() - last_roblox_message > 6 then ... end
-- with no else branch. A second nudge inside those six seconds was DISCARDED.
--
-- That reads like a 6x delay and it is not one. The nudge is the ONLY thing that
-- gets a cross-server request acted on quickly: MessageAsync asking the holding
-- server to "auto-save sooner and receive the message", and a session steal asking
-- it to release. Lose the packet and the request does not arrive six seconds late
-- -- it falls off the ~1s path onto the next autosave, AUTO_SAVE_PERIOD, 300
-- seconds by default. One dropped nudge is a 300x cliff, and two servers touching
-- the same player within six seconds of each other is ordinary traffic.
--
-- WHAT THIS SPEC PINS, and it is deliberately BOTH halves, because a fix that gets
-- only one of them is a different bug rather than a partial one:
--   * COALESCING -- ten nudges inside one window produce exactly ONE deferred
--     save. A fix that queued them instead would turn a lost write into eleven
--     writes and spend the DataStore budget the throttle exists to protect.
--   * SPACING -- that deferred save lands strictly MORE than six seconds after the
--     save before it. The maximum save rate this subscription can produce has to
--     be exactly what it was.
-- Asserting only "a deferred save happened" would pass on both of those mistakes,
-- so neither assertion is allowed to stand on its own here.
--
-- WHY IT DRIVES THE FORK DIRECTLY rather than going through Scribe. The subject is
-- twenty lines inside the vendored ProfileStore, and every layer between the bus
-- and those lines is a layer that can absorb the difference: Scribe's flush
-- pacing, its dirty tracking, its retry jitter. `Server.Module` is the real fork
-- loaded into a real simulated server's environment -- same disk, same bus, same
-- virtual clock as every other Sim spec -- so a session started on it exercises
-- the shipped code with nothing in between to explain a result away.
--
-- WHY THE BUS IS INSTANT HERE. The default Sim bus delivers after 1.5-2.5 seconds
-- of seeded jitter, on purpose, because delivery order is a real source of bugs.
-- It is the wrong instrument for this question: every assertion below is about
-- where a message lands INSIDE a six-second window, and a two-second smear of
-- arrival times would make "inside the window" a property of the seed rather than
-- of the code. So this universe gets a zero-latency, zero-jitter bus -- the one
-- variable being controlled -- and each nudge is placed at a stated offset on the
-- virtual clock. Nothing here depends on bus timing being realistic: the throttle
-- reads its own os.clock() and never sees the bus at all.
return function()
	local Root = script.Parent.Parent.Parent
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Bus = require(Root.Test.Sim.Bus)
	local Rng = require(Root.Test.Sim.Rng)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	local SEED = 5309
	local STORE_NAME = "NudgeStore"
	local PROFILE_KEY = "NUDGE_1"

	-- The window is six seconds and the whole point is to place messages inside it,
	-- so AUTO_SAVE_PERIOD is pushed far out of reach. Every run below is under two
	-- minutes of virtual time and a freshly loaded profile is not auto-saved for
	-- AUTO_SAVE_PERIOD/2 in any case, so an autosave landing in the middle of a
	-- measurement is not merely unlikely -- it cannot happen. That is what lets the
	-- save counts be asserted exactly rather than as a range, and an exact count is
	-- the only kind that can catch a coalescer that fires twice.
	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 3600,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	-- expect() has no ordering matcher, and "expected true, got false" says nothing
	-- about a timing failure. These report the number that was measured, which is
	-- what makes a red run here diagnosable instead of merely red.
	local function expectBetween(actual, low, high, what)
		if type(actual) ~= "number" or actual <= low or actual >= high then
			error(string.format("%s: expected a value in (%g, %g), got %s", what, low, high, tostring(actual)), 2)
		end
	end

	--- A two-server universe whose message bus delivers instantly.
	---
	--- The ordering here is forced: Bus.new wants a scheduler, Universe.new mints
	--- its own and offers no injection point, and Universe only forwards a bus
	--- LATENCY (jitter would stay at its one-second default, a sixth of the window
	--- being measured). So the bus is built first and bound to the universe's
	--- scheduler immediately after. Nothing subscribes or publishes during
	--- construction -- Env only captures the bus object and calls ServiceFor -- so
	--- there is no window in which the field is read unset.
	local function newUniverse()
		local bus = Bus.new({
			Sched = nil,
			Rng = Rng.Stream(SEED, "bus"),
			Latency = 0,
			Jitter = 0,
		})
		universe = Universe.new({
			Seed = SEED,
			Servers = 2,
			Constants = CONSTANTS,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Bus = bus,
		})
		bus._sched = universe.Sched
		Guard.Install(universe)
		return universe
	end

	--- Start a real session on server `index`'s ProfileStore and return everything
	--- needed to nudge it: the profile, the topic its subscription listens on, and
	--- a log of every save that starts on it.
	---
	--- The topic is `"PS_" .. unique_session_id`, and the module exposes that id
	--- nowhere -- but it writes it into the lock, at MetaData.ActiveSession[3],
	--- which is exactly where ProfileStore's own publishers read it from. Taking it
	--- off the disk is therefore not a back door into the module: it is the same
	--- address a real contending server would use.
	local function startSession(uni, index)
		local holder = uni:Server(index)
		local store = holder.Module.New(STORE_NAME, { Coins = 0 })

		local profile
		uni.Sched:Spawn(function()
			profile = store:StartSessionAsync(PROFILE_KEY, {
				Cancel = function()
					return false
				end,
			})
		end)
		uni:Run(40)
		if profile == nil then
			error("sim: the session never started -- nothing below would measure anything", 2)
		end

		local record = uni.Disk.Keyspace:Read(STORE_NAME, PROFILE_KEY)
		local session = record and record.Value and record.Value.MetaData.ActiveSession
		if type(session) ~= "table" or type(session[3]) ~= "string" then
			error("sim: the lock carries no session id, so there is no topic to nudge", 2)
		end

		-- Every SaveProfileAsync fires OnSave exactly once, before it yields, so
		-- this stamps the instant a save was DECIDED on -- which is the thing the
		-- throttle governs. Timing at completion instead would measure disk latency.
		local saves = {}
		profile.OnSave:Connect(function()
			table.insert(saves, uni.Sched.Now)
		end)

		-- StartSessionAsync spawns the subscription, and subscribing is a network
		-- round trip of its own. A nudge published before it lands is simply never
		-- delivered, which would look exactly like the bug under test.
		uni:Run(5)

		return {
			Profile = profile,
			Topic = "PS_" .. session[3],
			LoadCount = profile.SessionLoadCount,
			Saves = saves,
			-- Published from the OTHER server, as production would: PublishAsync is
			-- bound per server, and publishing from the holder's own service would
			-- model a server nudging itself.
			Publisher = uni:Server(3 - index).Env.Services.MessagingService,
		}
	end

	--- Publish one nudge `offset` virtual seconds from now. Returns immediately.
	local function nudgeAt(uni, session, offset, endSession)
		uni.Sched:Spawn(function()
			uni.Sched:Wait(offset)
			session.Publisher:PublishAsync(session.Topic, {
				LoadCount = session.LoadCount,
				EndSession = endSession,
			})
		end)
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	describe("MessagingService nudge throttle", function()
		it("coalesces every nudge inside a window into one save, and keeps the spacing", function()
			local uni = newUniverse()
			local session = startSession(uni, 1)

			-- The opening nudge. last_roblox_message is still 0 and os.clock() is the
			-- simulated epoch, so this one takes the immediate path and starts the
			-- window. Without it everything below would be measuring a FIRST nudge,
			-- which was never the broken case.
			nudgeAt(uni, session, 0, nil)
			uni:Run(1)
			expect(#session.Saves).to.equal(1)
			local immediateAt = session.Saves[1]

			-- Ten more, every half second, every one of them landing strictly inside
			-- the six seconds that opened at `immediateAt`. Upstream discards all ten.
			for i = 1, 10 do
				nudgeAt(uni, session, i * 0.5, nil)
			end

			-- Well past the window, and nowhere near AUTO_SAVE_PERIOD, so anything
			-- that lands in here was put there by the subscription and nothing else.
			uni:Run(30)

			-- COALESCING. Two saves: the immediate one, and ONE deferred one standing
			-- for all ten. Eleven would mean the nudges were queued rather than
			-- merged; one means they are still being dropped.
			expect(#session.Saves).to.equal(2)

			-- SPACING. Strictly more than six seconds, which is the same predicate
			-- the immediate path applies, so the maximum rate is unchanged. The upper
			-- bound is what proves the deferred save took the fast path at all: a
			-- save arriving on the autosave path would be 3600 seconds away here, and
			-- 300 at the shipped default.
			expectBetween(session.Saves[2] - immediateAt, 6, 7, "deferred save spacing")

			-- And the session is untouched by all of it: a deferred ordinary nudge is
			-- a save, never a release.
			expect(session.Profile:IsActive()).to.equal(true)
		end)

		it("lets EndSession win the merge instead of being downgraded", function()
			-- An ordinary nudge asks for a save; an EndSession nudge asks for a
			-- release, because another server is taking the session over. Merging an
			-- EndSession down into an ordinary save would leave the lock held and put
			-- the stealer back on the SESSION_STEAL deadline -- the same cliff moved
			-- somewhere else. So the flag is sticky, and it has to survive being
			-- surrounded by ordinary nudges on both sides rather than merely being
			-- the last one to arrive.
			local uni = newUniverse()
			local session = startSession(uni, 1)

			nudgeAt(uni, session, 0, nil)
			uni:Run(1)
			expect(#session.Saves).to.equal(1)
			local immediateAt = session.Saves[1]

			nudgeAt(uni, session, 0.5, nil)
			nudgeAt(uni, session, 1.5, true) -- the one that must not be lost
			nudgeAt(uni, session, 2.5, nil)
			nudgeAt(uni, session, 3.5, nil)

			uni:Run(60)

			-- Still exactly one deferred save: urgency wins the MERGE, not the
			-- WINDOW. A release is a DataStore write like any other and the budget
			-- does not care what asked for it.
			expect(#session.Saves).to.equal(2)
			expectBetween(session.Saves[2] - immediateAt, 6, 7, "deferred release spacing")

			-- And it WAS a release. This is the half a naive coalescer gets wrong: it
			-- would fold the EndSession into the ordinary nudges around it and leave
			-- the session running, which looks fine until the other server times out.
			expect(session.Profile:IsActive()).to.equal(false)

			local record = uni.Disk.Keyspace:Read(STORE_NAME, PROFILE_KEY)
			expect(record.Value.MetaData.ActiveSession).to.equal(nil)
		end)

		it("re-checks IsActive at fire time and never outlives the session", function()
			-- A deferred save is decided at ARRIVAL and performed up to six seconds
			-- later, and a lot can happen in between: the player leaves, another
			-- server steals the lock, this one starts closing. Firing the save anyway
			-- would be a write from a session that no longer owns the key -- the same
			-- class of bug as saving a profile that has already been released.
			--
			-- THE DEFERRED NUDGE HERE IS AN ENDSESSION ONE, and that is the whole
			-- reason this test can fail. Profile:Save() guards itself: called on an
			-- inactive profile it warns and returns, so an ordinary deferred nudge
			-- would be caught by that guard and a missing re-check would look
			-- harmless. SaveProfileAsync(profile, true, ...) has no such guard -- it
			-- would fire OnLastSave, tear the session down a second time and write
			-- from a session that no longer owns the key. So the dangerous path is
			-- the one the test drives.
			local uni = newUniverse()
			local session = startSession(uni, 1)

			nudgeAt(uni, session, 0, nil)
			uni:Run(1)
			expect(#session.Saves).to.equal(1)
			local immediateAt = session.Saves[1]

			-- Deferred: this one wants to fire about six seconds after `immediateAt`.
			nudgeAt(uni, session, 0.5, true)
			uni:Run(1.5)
			expect(#session.Saves).to.equal(1)

			-- The session ends first, roughly two seconds into the window. Its own
			-- release save is the second and LAST save that may ever appear.
			session.Profile:EndSession()
			uni:Run(3)
			expect(#session.Saves).to.equal(2)
			expect(session.Profile:IsActive()).to.equal(false)

			-- Counted at the disk as well as at the signal. A timer that woke up and
			-- wrote through some path OnSave does not cover would still be caught
			-- here, and "no write at all" is the property that actually matters.
			local writesAfterRelease = uni.Disk.Stats.Writes

			-- Past the moment the timer wanted to fire, and then far past it: the
			-- timer is one-shot and never re-arms, so it retires within one window of
			-- the session it belonged to rather than living on behind it.
			uni:Run(100)
			expect(#session.Saves).to.equal(2)
			expect(uni.Disk.Stats.Writes).to.equal(writesAfterRelease)
			expectBetween(uni.Sched.Now - immediateAt, 20, 200, "time advanced past the deferred fire")
			expect(uni.Sched.Deadlocked).to.equal(false)
		end)
	end)
end
