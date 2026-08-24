--!nonstrict
-- The three named accessors on the vendored store, driven against the REAL fork.
--
-- Scribe used to read these three things straight off the profile table, each on a
-- property of ProfileStore that ProfileStore does not document:
--
--   * UserIds is written to the key only by a COMPLETED save, and no key-minting
--     path seeds it -- so a non-empty list proves a save landed.
--   * A view skips the session-start increment, because GetAsync passes
--     EditProfile = nil -- so its SessionLoadCount sits one below a live join's.
--   * The save transform reads profile.Data AFTER OnSave has fired -- so swapping
--     the pointer inside an OnSave handler changes what that save writes.
--
-- SetRetainLastSaved is here for the same reason rather than for that one: its
-- effect is on the store's own state, so the non-sim harness exercises only
-- FakeProfileStore's mirror of it. Mutating the fork's release left every one of
-- those specs green.
--
-- Each of those lived as a comment beside the read. Now the store states them, and
-- this is where they are checked against the implementation that actually ships.
-- The equivalent assertions in Conformance.spec hold FakeProfileStore to the same
-- contract, which is what stops the two drifting; these hold the fork.
--
-- Driven inside a simulated universe rather than by requiring the module directly:
-- the fork reaches for MessagingService, which the headless shim does not provide,
-- while every simulated server already loads the fork into an environment that has
-- one (test/Sim/Bundle.luau builds it; test/Sim/Bus.luau is the channel).

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

	--- A universe built only for the store module one of its servers loaded.
	local function forkStore(constants, latencyProfile)
		local base = { AUTO_SAVE_PERIOD = 300, SESSION_STEAL = 40, FIRST_LOAD_REPEAT = 5, ASSUME_DEAD = 630 }
		for name, value in constants or {} do
			base[name] = value
		end
		universe = Universe.new({
			Seed = 4242,
			Servers = 1,
			Constants = base,
			Transport = StubTransport.new({ AutoPump = false }),
			-- "Instant" everywhere except where a test needs a save to still be ON THE
			-- WIRE at a chosen moment; a zero-latency disk makes every write land
			-- before the next line and there is nothing left to wait for.
			LatencyProfile = latencyProfile or "Instant",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 3, RecoverStreak = 5 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = {},
		})
		Guard.Install(universe)
		local Module = universe:Server(1).Bundle.Options.ProfileStore
		return universe, Module.New("Default", { Coins = 0 })
	end

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	--- Run `fn` on a scheduler thread and pump the universe until it has finished.
	--- Everything here yields on the modelled disk, so nothing can be called inline.
	local function drive(uni, fn)
		local out = {}
		uni.Sched:Spawn(function()
			fn(out)
			out.Done = true
		end)
		uni:Run(60)
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

	describe("HasCompletedSave", function()
		it("is false until a save actually commits, and true after", function()
			-- The discriminator Scribe needs to tell a returning player who never
			-- earned anything from one whose FIRST session died before its save landed.
			-- Judged wrong, the second gets their legacy import and every migration
			-- skipped, and the empty profile Scribe then saves becomes canonical.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_1")
				out.Before = profile:HasCompletedSave()
				profile:AddUserId(4242)
				profile.Data.Coins = 9
				out.Outcome = profile:SaveAwait()
				out.After = profile:HasCompletedSave()
				profile:EndSession()
			end)

			expect(r.Before).to.equal(false)
			expect(r.Outcome).to.equal("Saved")
			expect(r.After).to.equal(true)
		end)

		it("survives the round trip, so a later session sees the same answer", function()
			-- The property is about STORED state, not about this Profile object: it has
			-- to answer for a session that has not saved anything itself yet.
			local uni, store = forkStore()
			local r = drive(uni, function()
				local first = session(store, "ACC_2")
				first:AddUserId(4242)
				first.Data.Coins = 3
				first:SaveAwait()
				first:EndSession()
			end)
			expect(r.Done).to.equal(true)

			local second = drive(uni, function(out)
				local profile = session(store, "ACC_2")
				out.HadSave = profile:HasCompletedSave()
				out.Coins = profile.Data.Coins
				profile:EndSession()
			end)
			expect(second.HadSave).to.equal(true)
			expect(second.Coins).to.equal(3)
		end)
	end)

	describe("MessageAsync at the queue cap", function()
		it("refuses instead of silently dropping the oldest message", function()
			-- MAX_MESSAGE_QUEUE is 1000 in production and the queue used to enforce it
			-- by `table.remove(update_list, 1)` -- dropping the OLDEST entry -- while
			-- still returning true. Driven here with the cap lowered to 8 through the
			-- store's own SetConstant seam, which the simulation already forwards.
			--
			-- deliverGift treats that `true` as durable and clears the buyer's escrow,
			-- so a PURCHASED gift could be destroyed with nothing anywhere recording
			-- it. Gifts and Data.SendMessage share this one channel.
			--
			-- Note what is NOT the argument for refusing: a full queue of gift-shaped
			-- messages is about 136 KB at 1,000 entries, 3.4% of the 4 MB key. The key
			-- is nowhere near full. Refusing is right because the eviction is SILENT.
			local uni, store = forkStore({ MAX_MESSAGE_QUEUE = 8 })
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_MSG")
				profile:EndSession()

				local results = {}
				for i = 1, 12 do
					local ok, reason = store:MessageAsync("ACC_MSG", { Seq = i })
					table.insert(results, if ok then "y" else `n:{tostring(reason)}`)
				end
				out.Results = table.concat(results, ",")

				-- What actually survived, read back through a fresh session.
				local seen = {}
				local reader = session(store, "ACC_MSG")
				reader:MessageHandler(function(message, processed)
					table.insert(seen, tostring(message.Seq))
					processed()
				end)
				reader:SaveAwait()
				out.Seen = table.concat(seen, ",")
				reader:EndSession()
			end)

			-- Eight accepted, four refused with a reason -- not twelve accepted and
			-- four silently gone.
			expect(r.Results).to.equal("y,y,y,y,y,y,y,y,n:QueueFull,n:QueueFull,n:QueueFull,n:QueueFull")
			-- ...and the survivors are the FIRST eight, not the last eight.
			expect(r.Seen).to.equal("1,2,3,4,5,6,7,8")
		end)
	end)

	-- THE THIRD RETURN, against the store that actually ships. `MessageAsync` answers
	-- `provably_clean` -- true only where NOTHING can have been written -- and Scribe
	-- spends real money on it: `deliverGift` hands a paid gift credit back on that
	-- value alone. It exists because the first two returns collapse three outcomes
	-- with three different correct treatments, and Scribe got two of them wrong in
	-- opposite directions before the store could say which was which.
	--
	-- Every exit that can answer `false` is here, one row each. Conformance.spec holds
	-- FakeProfileStore to the first-attempt row, which is what stops the fake and the
	-- fork drifting; the other two rows need a retry loop and a shutdown flag, so they
	-- are fork-only and live here.
	describe("MessageAsync: could anything have been written", function()
		it("does not call a QueueFull clean when an EARLIER attempt of the same call committed", function()
			-- THE ANSWER THE REFUND GATE READS, against the store that actually ships.
			--
			-- `MessageAsync` retries `UpdateAsync` inside itself, so `(false, "QueueFull")`
			-- describes the attempt that ANSWERED and not the call. An earlier attempt can
			-- have queued the message and lost only its reply, after which the refusal is
			-- being reported for a gift already in the inbox. Scribe refunded a paid gift
			-- credit there and the retry granted a second time: 2000 coins from one credit,
			-- no Robux. The store now answers a third value, `provably_clean`, and this is
			-- where the value is checked against the implementation rather than the fake.
			--
			-- The lost reply is the sim's `Indeterminate` fault, which is the one outcome
			-- built for exactly this: the write COMMITS and then the call raises. With the
			-- cap at one, the committed insert is itself what fills the queue, so the
			-- second attempt of the SAME call finds it full -- no coincidence and no second
			-- writer required.
			--
			-- BOTH ROWS, because the two mistakes are opposite and a fix in one direction
			-- is what opened the other. Answer every QueueFull `true` and the double grant
			-- is back; answer it `false` and an ordinary full inbox quietly eats the
			-- buyer's credit. The store settles it by classifying each failed attempt off
			-- its error -- a 504 may have landed, a 1xx or 3xx provably did not -- rather
			-- than by counting attempts, which is what got the second row wrong.
			local uni, store = forkStore({ MAX_MESSAGE_QUEUE = 1 })
			local r = drive(uni, function(out)
				uni.Disk:Arm({ Kind = "Indeterminate", Op = "UpdateAsync", Key = "ACC_INDET", Count = 1 })
				local ok, reason, clean = store:MessageAsync("ACC_INDET", { Seq = 1 })
				out.AfterCommit = `{tostring(ok)}/{tostring(reason)}/{tostring(clean)}`
				out.Commits = uni.Disk.Faults.Stats.IndeterminateCommits

				-- The adjacent arm, on a key nothing was ever armed against: refused on the
				-- FIRST attempt, with nothing before it, so nothing can have been written and
				-- the caller may refund.
				store:MessageAsync("ACC_FIRST", { Seq = 1 })
				local plainOk, plainReason, plainClean = store:MessageAsync("ACC_FIRST", { Seq = 2 })
				out.FirstAttempt = `{tostring(plainOk)}/{tostring(plainReason)}/{tostring(plainClean)}`

				-- The premise, asserted rather than assumed: the message the raising
				-- attempt committed really is in the key, waiting to be delivered.
				local seen = {}
				local reader = session(store, "ACC_INDET")
				reader:MessageHandler(function(message, processed)
					table.insert(seen, tostring(message.Seq))
					processed()
				end)
				reader:SaveAwait()
				out.Seen = table.concat(seen, ",")
				reader:EndSession()
			end)

			expect(r.Commits).to.equal(1)
			expect(r.Seen).to.equal("1")
			expect(r.AfterCommit).to.equal("false/QueueFull/false")
			expect(r.FirstAttempt).to.equal("false/QueueFull/true")
		end)

		it("separates the entry guard, which attempted nothing, from the give-up after attempts", function()
			-- THE TWO EXITS THAT USED TO BE THE SAME BARE `false`, and they are
			-- opposites. The IsClosing guard sits above WaitForStoreReady and above the
			-- retry loop -- zero attempts, zero UpdateAsync calls -- while the loop's
			-- give-up ends after attempts that could each have committed before erroring.
			-- Scribe read every bare `false` as the second and ate a buyer's paid gift
			-- credit for a send that was never made.
			--
			-- The flag is driven directly rather than through BeginClose, which would
			-- also run the drain: this is about one branch, and the sim gives every
			-- server its own ProfileStore module, so the field is private to this
			-- universe (test/Sim/Loader). The guard cannot yield, so it is set for zero
			-- scheduler steps.
			local uni, store = forkStore()
			local module = uni:Server(1).Bundle.Options.ProfileStore
			local r = drive(uni, function(out)
				module.IsClosing = true
				local guardOk, guardWhy, guardClean = store:MessageAsync("ACC_CLOSED", { Seq = 1 })
				module.IsClosing = false
				out.Guard = `{tostring(guardOk)}/{tostring(guardWhy)}/{tostring(guardClean)}`
				-- Provably, not as a matter of timing: the key was never even minted.
				out.KeyExists = store:GetAsync("ACC_CLOSED") ~= nil

				-- The give-up, and it has to be reached the long way round: every
				-- UpdateAsync on this key fails, and the flag flips while the loop is
				-- backing off, so it ends with attempts behind it rather than none.
				uni.Disk:Arm({ Kind = "ServiceError", Op = "UpdateAsync", Key = "ACC_GIVEUP", Count = 1000000 })
				uni.Sched:Spawn(function()
					uni.Sched:Wait(4)
					module.IsClosing = true
				end)
				local gaveUpOk, gaveUpWhy, gaveUpClean = store:MessageAsync("ACC_GIVEUP", { Seq = 1 })
				module.IsClosing = false
				out.GaveUp = `{tostring(gaveUpOk)}/{tostring(gaveUpWhy)}/{tostring(gaveUpClean)}`
			end)

			-- Identical to every caller that reads two values, and told apart for the
			-- one that asks the third question. That is the whole shape of the fix.
			expect(r.Guard).to.equal("false/nil/true")
			expect(r.KeyExists).to.equal(false)
			expect(r.GaveUp).to.equal("false/nil/false")
		end)
	end)

	describe("WriteIndex", function()
		it("moves on every committing write, including the one LastUpdate cannot see", function()
			-- The fourth accessor, and it exists because the other fingerprint fields
			-- could not do the job. LastUpdate has one-second granularity, so two
			-- writers off one snapshot committing inside the same second were
			-- indistinguishable; and SaveProfileAsync's OVERWRITE arm -- the view-mode
			-- SetAsync that RestoreVersion commits through -- stamps no LastUpdate at
			-- all, so it was invisible to the comparison at any timing.
			--
			-- Driven against the real fork, because that overwrite arm is fork code.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_WI")
				out.AtStart = profile.WriteIndex
				profile.Data.Coins = 1
				profile:SaveAwait()
				profile:EndSession()

				local afterSession = store:GetAsync("ACC_WI")
				out.AfterSaves = afterSession.WriteIndex

				-- A view write: no LastUpdate, but the index still moves.
				out.LastUpdateBefore = afterSession.LastUpdate
				afterSession.Data.Coins = 2
				afterSession:SetAsync()

				local afterView = store:GetAsync("ACC_WI")
				out.AfterView = afterView.WriteIndex
				out.LastUpdateAfter = afterView.LastUpdate
			end)

			-- 1, not 0: minting the key seeds WriteIndex = 0 and the session-start
			-- transform is itself a committing write, so it is already at 1 by the time
			-- Profile.New reads it.
			expect(`start={r.AtStart} grew={r.AfterSaves > r.AtStart} viewMoved={r.AfterView > r.AfterSaves}`).to.equal(
				"start=1 grew=true viewMoved=true"
			)
			-- ...and the view write really did leave LastUpdate alone, which is the
			-- whole reason a second field was needed.
			expect(`lastUpdateUnchanged={r.LastUpdateBefore == r.LastUpdateAfter}`).to.equal("lastUpdateUnchanged=true")
		end)

		it("reads as 0 on a profile saved before the field existed", function()
			-- The migration case. An existing key in the wild carries no WriteIndex,
			-- and `or 0` on read plus `or 0` on BOTH sides of the comparison is what
			-- makes its absence exactly as permissive as it was before -- neither
			-- failing every compare-and-set nor passing every one. Simulated by
			-- deleting the field from the stored record, which is what a key written by
			-- an older build looks like.
			local uni, store = forkStore()
			drive(uni, function()
				local profile = session(store, "ACC_WI_LEGACY")
				profile.Data.Coins = 5
				profile:SaveAwait()
				profile:EndSession()
			end)

			for _, entry in uni.Disk.Keyspace:Each() do
				if entry.Key == "ACC_WI_LEGACY" then
					entry.Record.Value.MetaData.WriteIndex = nil
				end
			end

			local r = drive(uni, function(out)
				local view = store:GetAsync("ACC_WI_LEGACY")
				out.Index = view.WriteIndex
				out.Outcome = store:UpdateOfflineAsync("ACC_WI_LEGACY", {
					SessionLoadCount = view.SessionLoadCount,
					LastUpdate = view.LastUpdate,
					WriteIndex = view.WriteIndex,
				}, { Coins = 6 })
				-- ...and the write that just landed seals the key: the SAME snapshot
				-- is now stale.
				out.Second = store:UpdateOfflineAsync("ACC_WI_LEGACY", {
					SessionLoadCount = view.SessionLoadCount,
					LastUpdate = view.LastUpdate,
					WriteIndex = view.WriteIndex,
				}, { Coins = 7 })
				out.Coins = store:GetAsync("ACC_WI_LEGACY").Data.Coins
			end)

			expect(`index={r.Index} first={r.Outcome} second={r.Second} coins={r.Coins}`).to.equal(
				"index=0 first=Written second=Changed coins=6"
			)
		end)
	end)

	describe("SessionsStarted", function()
		it("normalizes a view up to what a live join of the same profile reports", function()
			-- The sharp one. A view's RAW count is one below a live session's, so a
			-- reader comparing the raw field against 1 judges every view brand new --
			-- which for a dry run means stamping the current version and skipping every
			-- migration, i.e. the dry run silently not exercising what it exists for.
			local uni, store = forkStore()
			drive(uni, function()
				local first = session(store, "ACC_3")
				first:AddUserId(4242)
				first.Data.Coins = 7
				first:SaveAwait()
				first:EndSession()
			end)

			local r = drive(uni, function(out)
				local view = store:GetAsync("ACC_3")
				out.ViewRaw = view.SessionLoadCount
				out.ViewStarted = view:SessionsStarted()
			end)
			local live = drive(uni, function(out)
				local profile = session(store, "ACC_3")
				out.LiveRaw = profile.SessionLoadCount
				out.LiveStarted = profile:SessionsStarted()
				profile:EndSession()
			end)

			-- Raw, the two DISAGREE about a profile that has been loaded exactly once...
			expect(r.ViewRaw).to.equal(1)
			expect(live.LiveRaw).to.equal(2)
			-- ...and normalized they agree, which is the whole point.
			expect(r.ViewStarted).to.equal(2)
			expect(live.LiveStarted).to.equal(2)
		end)

		it("leaves a live session's count alone", function()
			-- The normalization must be view-only. Adding one unconditionally would
			-- make a genuinely brand-new profile report 2 and never be treated as new.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_4")
				out.Raw = profile.SessionLoadCount
				out.Started = profile:SessionsStarted()
				profile:EndSession()
			end)
			expect(r.Raw).to.equal(1)
			expect(r.Started).to.equal(1)
		end)
	end)

	describe("SetRetainLastSaved", function()
		it("hands the handler the real data, then releases it", function()
			-- Both halves matter and they are one line apart in the store. Releasing
			-- BEFORE OnAfterSave would hand the handler an empty table, and the summary
			-- Scribe builds there -- the wipe guard's entire baseline -- would be built
			-- from nothing while every existing spec stayed green.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "RET_1")
				profile:AddUserId(4242)
				profile:SetRetainLastSaved(false)
				profile.Data.Coins = 77
				local connection = profile.OnAfterSave:Connect(function(lastSaved)
					out.HandlerSawCoins = lastSaved and lastSaved.Coins
					out.HandlerSawTable = type(lastSaved) == "table" and next(lastSaved) ~= nil
				end)
				out.Outcome = profile:SaveAwait()
				connection:Disconnect()
				out.AfterEmpty = next(profile.LastSavedData) == nil
				-- Released, not repointed: it must not be the live table wearing a new
				-- name, or a later reader would diff live data against itself and the
				-- wipe guard would never trip again.
				out.NotLiveTable = profile.LastSavedData ~= profile.Data
				profile:EndSession()
			end)

			expect(r.Outcome).to.equal("Saved")
			expect(r.HandlerSawTable).to.equal(true)
			expect(r.HandlerSawCoins).to.equal(77)
			expect(r.AfterEmpty).to.equal(true)
			expect(r.NotLiveTable).to.equal(true)
		end)

		it("keeps retaining when nothing asks it not to", function()
			-- Opt-in: an owner that never calls this is unaffected.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "RET_2")
				profile:AddUserId(4242)
				profile.Data.Coins = 88
				out.Outcome = profile:SaveAwait()
				out.Retained = next(profile.LastSavedData) ~= nil
				out.Coins = profile.LastSavedData.Coins
				profile:EndSession()
			end)
			expect(r.Outcome).to.equal("Saved")
			expect(r.Retained).to.equal(true)
			expect(r.Coins).to.equal(88)
		end)

		it("goes on releasing every later save, not only the first", function()
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "RET_3")
				profile:AddUserId(4242)
				profile:SetRetainLastSaved(false)
				profile.Data.Coins = 1
				profile:SaveAwait()
				profile.Data.Coins = 2
				profile:SaveAwait()
				out.StillEmpty = next(profile.LastSavedData) == nil
				profile:EndSession()
			end)
			expect(r.StillEmpty).to.equal(true)
		end)
	end)

	describe("SetSaveSource", function()
		it("changes what the save that is already running writes", function()
			-- The ordering contract, stated: OnSave fires, and only then does the
			-- UpdateAsync transform read profile.Data. Scribe's wipe guard is built
			-- entirely on it -- it substitutes the last known-good snapshot for live
			-- data that looks like a wipe, from inside OnSave.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_5")
				profile:AddUserId(4242)
				profile.Data.Coins = 111
				local connection = profile.OnSave:Connect(function()
					profile:SetSaveSource({ Coins = 222 })
				end)
				out.Outcome = profile:SaveAwait()
				connection:Disconnect()
				profile:EndSession()
			end)
			expect(r.Outcome).to.equal("Saved")

			local stored = drive(uni, function(out)
				local view = store:GetAsync("ACC_5")
				out.Coins = view.Data.Coins
			end)
			-- The swapped table is what landed, not the one that was live when the
			-- save was requested.
			expect(stored.Coins).to.equal(222)
		end)

		it("refuses a non-table, at the assignment rather than at the next save", function()
			-- Left as a raw field write, a bad value surfaced deep inside
			-- SaveProfileAsync with nothing to say who wrote it.
			local uni, store = forkStore()
			local r = drive(uni, function(out)
				local profile = session(store, "ACC_6")
				out.Ok = pcall(function()
					profile:SetSaveSource("not a table")
				end)
				-- ...and the profile is untouched, so the session is still usable.
				out.StillTable = type(profile.Data) == "table"
				profile:EndSession()
			end)
			expect(r.Ok).to.equal(false)
			expect(r.StillTable).to.equal(true)
		end)
	end)
	describe("AwaitClose", function()
		it("releases a session it minted, when the load is cancelled after claiming it", function()
			-- Why AwaitClose can safely clone its active list ONCE, up front.
			--
			-- The obvious reading of AwaitClose is that the clone is a bug: a load
			-- already in flight when the drain begins completes during the job-drain
			-- wait, mints a session the clone never saw, and is left behind. I wrote
			-- that down in a progress note as a defect in the fork. It is not one, and
			-- the reason lives here rather than in AwaitClose: a load that claims a
			-- session and THEN finds the server closing releases what it just minted
			-- and returns nil (ProfileStore.luau:2353), before decrementing
			-- ActiveProfileLoadJobs -- so AwaitClose's wait cannot return until that
			-- release has finished.
			--
			-- WHICH ARM THIS PINS, precisely, because the two are not equally
			-- reachable. That check is `IsClosing == true or cancel_condition() == true`
			-- and this drives the SECOND arm. The IsClosing arm cannot be reached in
			-- this simulation at all: the modelled disk has no yield between the
			-- transform's commit and this check, so a concurrent BeginClose always
			-- lands earlier, where the retry loop's own condition catches it and the
			-- load returns nil having minted nothing. Measured across the whole 50 ms
			-- window at seven offsets -- every one returned nil with nothing left
			-- active, and never reached this block. Same `if`, same body, so holding
			-- one holds the code; it does not hold the interleaving.
			--
			-- The call sequence, measured: Cancel is consulted at the retry-loop
			-- condition (t=0), inside the UpdateAsync transform (t=0.05, after the
			-- Fixed profile's 50 ms), and again here. False for the first two, so the
			-- session really is claimed; true for the third.
			local uni, store = forkStore(nil, "Fixed")
			local key = "ACC_CANCEL_AFTER_CLAIM"

			local cancels = 0
			local r = drive(uni, function(out)
				out.Profile = store:StartSessionAsync(key, {
					Cancel = function()
						cancels += 1
						return cancels >= 3
					end,
				})
				-- Synchronously off the modelled keyspace: a read through the store
				-- would yield, and anything still in flight would land during it.
				local record = uni.Disk.Keyspace:Read("Default", key)
				local meta = record and record.Value and record.Value.MetaData
				out.Locked = meta ~= nil and meta.ActiveSession ~= nil
			end)

			-- cancels=3 is the anti-vacuity guard: it proves the load got past the
			-- transform and reached the post-load check, rather than being turned away
			-- at the loop condition, which would pass this test for no reason.
			expect(`cancels={cancels} returned={r.Profile ~= nil} locked={tostring(r.Locked)}`).to.equal(
				"cancels=3 returned=false locked=false"
			)
		end)

		it("does not return until the saves it started have landed", function()
			-- Pins AwaitClose's job-drain wait, which was a surviving mutation:
			-- replacing the loop with `while false do` left 1345/0.
			--
			-- Scribe's shutdown ends with `pcall(ProfileStore.AwaitClose)` and its
			-- comment calls it "the job-drain wait: it keeps the process alive until the
			-- saves those releases started have actually landed". Nothing held it,
			-- because CI drives FakeProfileStore, which has no AwaitClose at all -- so
			-- the guard `type(AwaitClose) == "function"` simply skips it on every CI
			-- run. See TIER-B-PROGRESS.md for that finding.
			--
			-- The latency profile is load-bearing rather than incidental. AwaitClose
			-- spawns SaveProfileAsync per active profile and then waits; on an
			-- instant disk the spawned save runs to completion before the wait is even
			-- reached, so the loop has nothing to do and the mutation is invisible. A
			-- Fixed profile leaves the save parked on the modelled disk at the moment
			-- the wait begins, which is the only state that can tell the two apart.
			local uni, store = forkStore(nil, "Fixed")
			local Module = uni:Server(1).Bundle.Options.ProfileStore

			local r = drive(uni, function(out)
				local profile = session(store, "ACC_AWAITCLOSE")
				profile:AddUserId(4242)
				profile.Data.Coins = 77
				-- Not saved here on purpose: AwaitClose is what saves and releases it.
				Module.AwaitClose()
				-- Read the modelled keyspace DIRECTLY, and synchronously, at the instant
				-- AwaitClose returns. Going through store:GetAsync would yield, and the
				-- parked save would land during that yield -- so the read would answer 77
				-- either way and the test would pass against a drain that does nothing.
				--
				-- profile:IsActive() is no good for the same reason in reverse: it is
				-- already false, because SaveProfileAsync drops the session before it
				-- ever touches the disk. Measured -- that was this test's first draft and
				-- the mutation survived it.
				local record = uni.Disk.Keyspace:Read("Default", "ACC_AWAITCLOSE")
				out.Stored = record and record.Value and record.Value.Data and record.Value.Data.Coins
				out.ActiveAfterClose = profile:IsActive()
			end)

			expect(`active={tostring(r.ActiveAfterClose)} stored={tostring(r.Stored)}`).to.equal(
				"active=false stored=77"
			)
		end)
	end)
end
