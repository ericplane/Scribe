--!nonstrict
-- Data.OnCooldown(player, key, seconds, { IncludeOfflineTime = false }).
--
-- A normal cooldown stores a DEADLINE, so wall-clock time keeps running while the
-- player is away. An online-only one stores REMAINING SECONDS on disk instead, and
-- Scribe turns that back into a deadline on load. In memory both are deadlines, so
-- every read, the 1 Hz sweep, and PeekCooldown behave identically for the two.
--
-- The conversion happens on every SAVE, not only on leave. That is what makes a
-- crash safe: whatever the DataStore caught is already a remaining, so the worst
-- case is a cooldown that resumes slightly long, never one that resumes as a
-- deadline in 1970.

return function()
	local Root = script.Parent.Parent.Parent
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local WALL = Template.COOLDOWN_PREFIX
	local ONLINE = Template.ONLINE_COOLDOWN_PREFIX

	it("persists remaining seconds, not a deadline", function()
		local harness = TestCtx.make()
		local player = harness.Join(97701)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.OnCooldown(player, "Wall", 3600)
		harness.Leave(player)

		local timed = harness.Fake.Persisted["Default/PLAYER_97701"]._Scribe.Timed
		-- The online slot is a small duration; the wall-clock one is a unix time.
		expect(timed[ONLINE .. "Daily"]).to.equal(3600)
		expect(timed[WALL .. "Wall"] > os.time()).to.equal(true)

		harness.Cleanup()
	end)

	it("ignores time spent offline, while a normal cooldown does not", function()
		local harness = TestCtx.make()
		local player = harness.Join(97702)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.OnCooldown(player, "Wall", 3600)
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97702"]

		-- Two hours pass with the player offline. The wall-clock deadline is now in
		-- the past; the online remaining is untouched.
		saved._Scribe.Timed[WALL .. "Wall"] = os.time() - 7200

		local rejoined = TestCtx.make()
		rejoined.Fake.Persisted["Default/PLAYER_97702"] = saved
		local player2 = rejoined.Join(97702)

		local onlineActive, onlineLeft = rejoined.Data.PeekCooldown(player2, "Daily")
		expect(onlineActive).to.equal(true)
		expect(onlineLeft > 3500).to.equal(true) -- the full hour survived the gap
		expect(rejoined.Data.PeekCooldown(player2, "Wall")).to.equal(false)
		rejoined.Cleanup()

		harness.Cleanup()
	end)

	it("counts time spent online", function()
		local harness = TestCtx.make()
		local player = harness.Join(97703)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })

		-- Simulate an hour of play by moving the live deadline back.
		local timed = harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Timed
		timed[ONLINE .. "Daily"] -= 1800

		local _active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(remaining <= 1801 and remaining >= 1799).to.equal(true)
		harness.Leave(player)

		-- Half an hour of countdown persisted, not the original full hour.
		local stored = harness.Fake.Persisted["Default/PLAYER_97703"]._Scribe.Timed[ONLINE .. "Daily"]
		expect(stored <= 1801 and stored >= 1799).to.equal(true)

		harness.Cleanup()
	end)

	it("keeps the live value a deadline across a save", function()
		-- The swap is only for the duration of the save. If it leaked, the next read
		-- would treat 3600 as a unix time and report the cooldown as long expired.
		local harness = TestCtx.make()
		local player = harness.Join(97704)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.Flush(player, { Force = true })

		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)

		harness.Cleanup()
	end)

	it("stays readable while a save is in flight", function()
		-- Between OnSave and OnAfterSave the profile carries remaining seconds so the
		-- store can read them. A real save is async, so that window is real: if the
		-- live deadlines went with it, every read in it would see a 1970 deadline.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97710)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })

		-- Enter the swap window by hand, exactly as profile.OnSave does.
		entry.TimedHeld = harness.Ctx.Timed.BeforeSave(entry)
		expect(entry.LiveData._Scribe.Timed[ONLINE .. "Daily"] < 4000).to.equal(true) -- persisted form

		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)
		-- Arming again inside the window must see it as running, not hand out a free one.
		expect(harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })).to.equal(true)
		-- And the sweep must not mistake it for lapsed.
		local ended = {}
		harness.Data.OnCooldownEnded:Connect(function(_p, key)
			table.insert(ended, key)
		end)
		harness.Ctx.Timed.Sweep(entry)
		expect(#ended).to.equal(0)

		harness.Ctx.Timed.AfterSave(entry, entry.TimedHeld)
		entry.TimedHeld = nil
		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(true)

		harness.Cleanup()
	end)

	it("keeps a write made during a save, rather than restoring over it", function()
		-- The restore points the profile back at the LIVE dict, so a clear or a fresh
		-- arm landing mid-save is still there afterwards. Copying held deadlines back
		-- over the store instead would resurrect the cleared one and clobber the new
		-- one, both silently and both with the API reporting success.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97711)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })

		entry.TimedHeld = harness.Ctx.Timed.BeforeSave(entry)
		harness.Data.ClearCooldown(player, "Daily")
		harness.Data.OnCooldown(player, "Weekly", 7200, { IncludeOfflineTime = false })
		harness.Ctx.Timed.AfterSave(entry, entry.TimedHeld)
		entry.TimedHeld = nil

		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(false)
		local active, remaining = harness.Data.PeekCooldown(player, "Weekly")
		expect(active).to.equal(true)
		expect(remaining > 7100).to.equal(true)

		-- And the one armed in the window persists as a remaining, not as the raw
		-- deadline, which a load would turn into a cooldown decades long.
		harness.Leave(player)
		local timed = harness.Fake.Persisted["Default/PLAYER_97711"]._Scribe.Timed
		expect(timed[ONLINE .. "Daily"]).to.equal(nil)
		expect(timed[ONLINE .. "Weekly"] <= 7200).to.equal(true)

		harness.Cleanup()
	end)

	it("is a deadline before the session reaches Ready, not after", function()
		-- The stored form is REMAINING seconds and only becomes a deadline in the
		-- Timed load hook. setState("Ready") resumes every parked Data.WaitForData
		-- synchronously, so running that hook afterwards hands the documented
		-- PlayerAdded -> WaitForData -> read path a remaining to read as a deadline:
		-- the gate reports expired and the reward is re-claimable on every rejoin.
		local harness = TestCtx.make()
		local player = harness.Join(97713)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97713"]
		expect(saved._Scribe.Timed[ONLINE .. "Daily"]).to.equal(3600)

		local rejoined = TestCtx.make()
		rejoined.Fake.Persisted["Default/PLAYER_97713"] = saved
		-- Make the load actually park the waiter, the way a real StartSessionAsync
		-- does. Without this the fake finishes the whole load inside OnPlayerAdded
		-- and the window this guards has zero width.
		rejoined.Fake.YieldOnSessionStart = true

		local player2 = FakePlayer.new(97713)
		rejoined.Ctx.Persistence.OnPlayerAdded(player2)
		local seen = nil
		task.spawn(function()
			-- The documented golden path: PlayerAdded -> WaitForData -> read.
			rejoined.Ctx.Persistence.WaitForData(player2)
			seen = select(1, rejoined.Data.PeekCooldown(player2, "Daily"))
		end)
		while seen == nil do
			task.wait()
		end

		expect(seen).to.equal(true)
		rejoined.Ctx.Persistence.OnPlayerRemoving(player2)
		rejoined.Cleanup()

		harness.Cleanup()
	end)

	it("has converted the cooldown by the instant the state says Ready", function()
		-- The same ordering as above, pinned where it actually lives rather than
		-- through a waiter. WaitForData used to resume from inside setState, so the
		-- spec above could observe the pre-Ready world by reading after it returned;
		-- the wake is deferred now, and by the time a waiter runs the conversion has
		-- happened either way. That makes the spec above pass whether the hook is
		-- above or below setState -- it stopped guarding anything.
		--
		-- StateChanged fires synchronously from inside setState, so a handler on it
		-- reads the world at exactly the moment the state flips. That is the moment
		-- the claim is about.
		local harness = TestCtx.make()
		local player = harness.Join(97717)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97717"]

		local rejoined = TestCtx.make()
		rejoined.Fake.Persisted["Default/PLAYER_97717"] = saved
		rejoined.Fake.YieldOnSessionStart = true

		local player2 = FakePlayer.new(97717)
		local atReady = nil
		rejoined.Ctx.Persistence.OnPlayerAdded(player2)
		local entry = rejoined.Ctx.Persistence.EntryFor(player2)
		entry.StateChanged:Connect(function(state)
			if state == "Ready" and atReady == nil then
				atReady = select(1, rejoined.Data.PeekCooldown(player2, "Daily"))
			end
		end)
		for _ = 1, 200 do
			if atReady ~= nil then
				break
			end
			task.wait()
		end

		expect(`onCooldownAtReady={atReady}`).to.equal("onCooldownAtReady=true")

		rejoined.Ctx.Persistence.OnPlayerRemoving(player2)
		rejoined.Cleanup()
		harness.Cleanup()
	end)

	it("survives two overlapping saves without persisting a deadline", function()
		-- ProfileStore task.spawns every save and takes no per-profile lock, so an
		-- autosave can start while a Flush is in flight. If the first save out closed
		-- the window, the profile would point back at the live DEADLINES and the
		-- second save would serialize those as remaining seconds, which a rejoin
		-- turns into a cooldown decades long.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97714)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })

		local heldA = harness.Ctx.Timed.BeforeSave(entry)
		local heldB = harness.Ctx.Timed.BeforeSave(entry) -- second save starts
		harness.Ctx.Timed.AfterSave(entry, heldA) -- first one finishes

		-- Still the persisted form while B is in flight, so B serializes correctly.
		local inFlight = entry.LiveData._Scribe.Timed[ONLINE .. "Daily"]
		expect(inFlight <= 3600).to.equal(true)

		harness.Ctx.Timed.AfterSave(entry, heldB)
		expect(entry.LiveData._Scribe.Timed[ONLINE .. "Daily"] > os.time()).to.equal(true)
		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)

		harness.Cleanup()
	end)

	it("keeps the save window open when an unrelated DataStore call errors", function()
		-- OnError is module-global. A Data.SendMessage, gift delivery or version read
		-- on the same key routes through the same RegisterError, and ProfileStore
		-- hands the handler nothing that says which call failed. Closing the window
		-- on one of those points the profile back at the live DEADLINES while the
		-- in-flight save is still going to serialize them, and a rejoin reads 1.78e9
		-- "remaining" as a cooldown decades out that never self-heals.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97715)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.OnCooldown(player, "Wall", 3600) -- control: never converted

		-- Fire the unrelated error from inside the save, where the real one lands,
		-- then read what the save is about to serialize. That is the exact value the
		-- bug corrupts, and reading it here is synchronous with the write.
		local aboutToPersist, wallAboutToPersist
		harness.Fake.MidSave = function()
			harness.Fake.OnError:Fire("Number of requests exceeded limit", "Default", "PLAYER_97715")
			local timed = entry.LiveData._Scribe.Timed
			aboutToPersist = timed[ONLINE .. "Daily"]
			wallAboutToPersist = timed[WALL .. "Wall"]
		end
		-- The error resumes this thread out of Flush before the save finishes, so
		-- wait for the write itself rather than trusting Flush's return.
		harness.Data.Flush(player, { Force = true })
		local saved
		for _ = 1, 50 do
			saved = harness.Fake.Persisted["Default/PLAYER_97715"]
			if saved then
				break
			end
			task.wait()
		end
		harness.Fake.MidSave = nil
		expect(saved).to.be.ok()

		-- The persisted form, not an absolute unix time.
		expect(aboutToPersist <= 3600).to.equal(true)
		expect(wallAboutToPersist > os.time()).to.equal(true) -- control: never converted
		expect(saved._Scribe.Timed[ONLINE .. "Daily"] <= 3600).to.equal(true)

		-- And the live session still reads a deadline.
		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)
		expect(entry.LiveData).to.be.ok()

		harness.Cleanup()
	end)

	it("opens the save window even with no online cooldown armed yet", function()
		-- BeforeSave opens the window unconditionally. Guarding it on "are there any
		-- online slots" looks like a cheap skip, but then a cooldown ARMED during the
		-- save writes an absolute deadline straight into the profile the store is
		-- about to serialize, and a rejoin reads it as remaining seconds: a cooldown
		-- decades long.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97716)
		harness.Data.OnCooldown(player, "Wall", 3600) -- wall-clock only, no @cdo| slot

		local held = harness.Ctx.Timed.BeforeSave(entry)
		expect(held).to.be.ok() -- the window opened regardless
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		-- The arm lands on the live table, so it is simply not in THIS save's
		-- payload, which is the right semantics for anything racing a save. What must
		-- never happen is an absolute DEADLINE sitting in the payload: that is what a
		-- skipped window produces, and a load reads it as remaining seconds.
		local inPayload = entry.LiveData._Scribe.Timed[ONLINE .. "Daily"]
		expect(inPayload == nil or inPayload <= 3600).to.equal(true)
		harness.Ctx.Timed.AfterSave(entry, held)

		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)
		harness.Leave(player)
		local stored = harness.Fake.Persisted["Default/PLAYER_97716"]._Scribe.Timed
		expect(stored[ONLINE .. "Daily"] <= 3600).to.equal(true)

		harness.Cleanup()
	end)

	it("still sweeps a lapsed cooldown while a save is in flight", function()
		-- The sweep used to bail entirely whenever a window was open. It no longer
		-- needs to, because the live table keeps real deadlines throughout, and
		-- bailing meant a lapsed cooldown sat un-swept for the whole round trip.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97717)
		local ended = {}
		harness.Data.OnCooldownEnded:Connect(function(_p, key)
			table.insert(ended, key)
		end)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.OnCooldown(player, "Lapsed", 3600, { IncludeOfflineTime = false })

		local held = harness.Ctx.Timed.BeforeSave(entry)
		-- Lapse one of them from inside the window, then sweep.
		local live = harness.Ctx.Persistence.EntryFor(player)
		live.TimedLive[ONLINE .. "Lapsed"] = os.time() - 1
		harness.Ctx.Timed.Sweep(entry)
		expect(table.concat(ended, ",")).to.equal("Lapsed")

		harness.Ctx.Timed.AfterSave(entry, held)
		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(true)
		expect(harness.Data.PeekCooldown(player, "Lapsed")).to.equal(false)

		harness.Cleanup()
	end)

	it("clears an online-only cooldown", function()
		-- ClearCooldown wipes both slots, and the online one is the half no other test
		-- reaches: everywhere else the online slot has already been swapped out for a
		-- wall-clock one by the time Clear runs.
		local harness = TestCtx.make()
		local player = harness.Join(97712)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(true)

		harness.Data.ClearCooldown(player, "Daily")

		local timed = harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Timed
		expect(timed[ONLINE .. "Daily"]).to.equal(nil)
		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(false)

		harness.Cleanup()
	end)

	it("treats the two modes as one cooldown per key", function()
		local harness = TestCtx.make()
		local player = harness.Join(97705)

		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		-- Flipping the mode while the first is STILL RUNNING must report on-cooldown,
		-- not silently clear it and arm a fresh one: that is a free claim.
		local active, remaining = harness.Data.OnCooldown(player, "Daily", 3600)
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)
		local timedNow = harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Timed
		expect(timedNow[ONLINE .. "Daily"]).to.be.ok() -- the original slot survived
		expect(timedNow[WALL .. "Daily"]).to.equal(nil)

		-- Once it has lapsed, re-arming the other way replaces it cleanly.
		harness.Data.ClearCooldown(player, "Daily")
		harness.Data.OnCooldown(player, "Daily", 3600)

		local timed = harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Timed
		expect(timed[ONLINE .. "Daily"]).to.equal(nil)
		expect(timed[WALL .. "Daily"]).to.be.ok()

		-- Clear covers the wall-clock slot armed just above; the online half has its
		-- own test, since nothing is armed there by the time this line runs.
		harness.Data.ClearCooldown(player, "Daily")
		expect(harness.Data.PeekCooldown(player, "Daily")).to.equal(false)

		harness.Cleanup()
	end)

	it("fires OnCooldownEnded with the plain key when an online cooldown lapses", function()
		local harness = TestCtx.make()
		local player = harness.Join(97706)
		local ended = {}
		harness.Data.OnCooldownEnded:Connect(function(_p, key)
			table.insert(ended, key)
		end)

		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		local timed = harness.Ctx.Persistence.EntryFor(player).LiveData._Scribe.Timed
		timed[ONLINE .. "Daily"] = os.time() - 1
		harness.Ctx.Timed.Sweep(harness.Ctx.Persistence.EntryFor(player))

		-- The prefix must be stripped, and it must take the cooldown branch rather
		-- than being mistaken for a template field path.
		expect(table.concat(ended, ",")).to.equal("Daily")

		harness.Cleanup()
	end)

	it("survives a failed save, which never swaps the deadline back on its own", function()
		-- ProfileStore fires OnSave before writing and OnAfterSave only on success, so
		-- a FAILED save leaves the live dict holding the persisted form. Every later
		-- reader treats those small remainings as absolute deadlines: the cooldown
		-- reads expired, the sweep deletes it and fires a bogus OnCooldownEnded, and
		-- the next save persists 0. ProfileStore autosaves every 300s with no retry,
		-- so one throttle is enough to reach this.
		local harness = TestCtx.make()
		local player, entry, _data = harness.Join(97709)
		harness.Data.OnCooldown(player, "Daily", 3600, { IncludeOfflineTime = false })
		harness.Data.OnCooldown(player, "Wall", 3600)

		local ended = {}
		harness.Data.OnCooldownEnded:Connect(function(_p, key)
			table.insert(ended, key)
		end)

		harness.Fake.FailSaves = true
		pcall(function()
			harness.Data.Flush(player, { Force = true })
		end)
		harness.Fake.FailSaves = false

		-- Still a deadline, so still on cooldown.
		local active, remaining = harness.Data.PeekCooldown(player, "Daily")
		expect(active).to.equal(true)
		expect(remaining > 3500).to.equal(true)
		-- The wall-clock one is the control: it never swaps, so it must be unaffected.
		expect(harness.Data.PeekCooldown(player, "Wall")).to.equal(true)

		-- The sweep must not mistake it for lapsed.
		harness.Ctx.Timed.Sweep(entry)
		expect(#ended).to.equal(0)

		-- And a later successful save persists the real remaining, not 0.
		harness.Leave(player)
		local stored = harness.Fake.Persisted["Default/PLAYER_97709"]._Scribe.Timed[ONLINE .. "Daily"]
		expect(stored > 3500).to.equal(true)

		harness.Cleanup()
	end)

	it("refuses a typo'd option rather than silently including offline time", function()
		local harness = TestCtx.make()
		local player = harness.Join(97707)
		expect(function()
			harness.Data.OnCooldown(player, "Daily", 60, { IncludeOfflineTimes = false })
		end).to.throw()
		expect(function()
			harness.Data.OnCooldown(player, "Daily", 60, { IncludeOfflineTime = false })
		end).never.to.throw()
		harness.Cleanup()
	end)

	it("refuses a template root that could alias either cooldown prefix", function()
		for _, name in { "@cd|X", "@cdo|X", "@cdX" } do
			expect(function()
				TestCtx.make({ Template = { [name] = 0 } }).Cleanup()
			end).to.throw()
		end
	end)
end
