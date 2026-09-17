--!nonstrict
-- Joins during Erase's board sweep wait, are refused after EraseJoinTimeout, and are
-- refused by the marker on other servers; a foreign session refuses the erase instead.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Sched = require(Root.Scribe.Internal.Sched)
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	local function keyFor(userId: number): string
		return `Default/PLAYER_{userId}`
	end

	--- Erase on its own thread, with a sweep that yields for `sweep` seconds.
	local function eraseInBackground(harness, userId: number, sweep: number?)
		local out = {}
		harness.Ctx.Leaderboards.EraseUser = function()
			task.wait(sweep or 0.1)
			return true
		end
		Sched.Spawn(function()
			local ok, reason = harness.Data.Erase(userId)
			local entry = harness.Ctx.Persistence.EntryForUserId(userId)
			table.insert(out, { Ok = ok, Reason = reason, State = if entry then entry.State else "none" })
		end)
		return function()
			while #out == 0 do
				task.wait(0.02)
			end
			return out[1]
		end
	end

	--- Erase on its own thread, parked in its sweep until called back; it then checkpoints once.
	local function parkedErase(harness, userId: number)
		local out = {}
		local released = false
		local checkpoint = nil
		harness.Ctx.Leaderboards.EraseUser = function(_, _, progress)
			while not released do
				task.wait(0.02)
			end
			checkpoint = progress.Save()
			return checkpoint, if checkpoint then nil else "stopped"
		end
		Sched.Spawn(function()
			local ok, reason = harness.Data.Erase(userId)
			table.insert(out, { Ok = ok, Reason = reason })
		end)
		return function()
			released = true
			while #out == 0 do
				task.wait(0.02)
			end
			return out[1], checkpoint
		end
	end

	it("holds a join on this server until the erase has finished, and the join then starts fresh", function()
		local harness = TestCtx.make()
		local first, _, data = harness.Join(70001)
		data.Coins.Set(555)
		harness.Data.Flush(first)
		harness.Leave(first)

		local result = eraseInBackground(harness, 70001)
		-- The erase is inside its sweep.
		task.wait(0.02)
		local rejoined, _, fresh = harness.Join(70001)
		local erased = result()
		local coins = fresh.Coins.Get()
		harness.Data.Flush(rejoined)
		local persisted = harness.Fake.Persisted[keyFor(70001)]
		harness.Cleanup()
		expect(`erase={erased.Ok} stateAtErase={erased.State} coins={coins} saved={persisted and persisted.Coins}`).to.equal(
			"erase=true stateAtErase=Loading coins=0 saved=0"
		)
	end)

	it("refuses a second erase while the first is still sweeping", function()
		local harness = TestCtx.make()
		local first, _, data = harness.Join(70003)
		data.Coins.Set(555)
		harness.Data.Flush(first)
		harness.Leave(first)

		local one = eraseInBackground(harness, 70003)
		task.wait(0.03)
		local secondOk, secondReason = harness.Data.Erase(70003)
		local erased = one()
		local _, _, fresh = harness.Join(70003)
		local coins = fresh.Coins.Get()
		harness.Cleanup()
		expect(`second={secondOk} reason={secondReason} first={erased.Ok} coins={coins}`).to.equal(
			"second=false reason=another erase of this profile is still running first=true coins=0"
		)
	end)

	it("refuses a join that has waited EraseJoinTimeout, and the erase still finishes", function()
		local harness = TestCtx.make({ Options = { EraseJoinTimeout = 0.1 } })
		local first, _, data = harness.Join(70004)
		data.Coins.Set(555)
		harness.Data.Flush(first)
		harness.Leave(first)

		local result = eraseInBackground(harness, 70004, 0.4)
		task.wait(0.02)
		local player, _, accessor, reason = harness.TryJoin(70004, 1)
		local kicked = player.Kicked
		local erased = result()
		local gone = harness.Fake.Persisted[keyFor(70004)] == nil
		harness.Cleanup()
		expect(`refused={accessor == nil} reason={reason} kicked={kicked} erase={erased.Ok} gone={gone}`).to.equal(
			"refused=true reason=erasing kicked=Your data is being reset. Please rejoin in a few minutes! erase=true gone=true"
		)
	end)

	it("marks the profile so another server refuses the join without saving anything back", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70005)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local result = eraseInBackground(b, 70005, 0.3)
		task.wait(0.05)
		local stored = fake.Persisted[keyFor(70005)]
		local marked = stored ~= nil and type(stored._Scribe.Erase) == "table"
		local player, _, accessor, reason = a.TryJoin(70005, 1)
		local erased = result()
		local gone = fake.Persisted[keyFor(70005)] == nil
		b.Cleanup()
		a.Cleanup()
		expect(
			`marked={marked} refused={accessor == nil} reason={reason} kicked={player.Kicked ~= nil} erase={erased.Ok} gone={gone}`
		).to.equal("marked=true refused=true reason=erasing kicked=true erase=true gone=true")
	end)

	it("refuses when a session opened outside Scribe during the sweep", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70002)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local result = eraseInBackground(a, 70002, 0.3)
		task.wait(0.05)
		-- A session opened outside Scribe ignores the marker.
		local foreign = fake.New("Default"):StartSessionAsync("PLAYER_70002", {})
		local erased = result()
		local persisted = fake.Persisted[keyFor(70002)]
		local marked = persisted ~= nil and type(persisted._Scribe.Erase) == "table"
		foreign:EndSession()
		a.Cleanup()
		expect(`erase={erased.Ok} reason={erased.Reason} keyGone={persisted == nil} marked={marked}`).to.equal(
			"erase=false reason=profile has an active session on another server keyGone=false marked=true"
		)
	end)

	it("stops when another server finished the erase and a rejoin recreated the profile", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70006)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local resume = parkedErase(a, 70006)
		task.wait(0.05)
		-- A has stalled past its lease, so B may take the erase over.
		fake.Persisted[keyFor(70006)]._Scribe.Erase.Lease.Until = Clock.Now() - 1
		local elsewhere = b.Data.Erase(70006)
		local again, _, fresh = b.Join(70006)
		fresh.Coins.Set(7)
		b.Data.Flush(again)
		b.Leave(again)

		local result, checkpoint = resume()
		local persisted = fake.Persisted[keyFor(70006)]
		local coins = tostring(if persisted then persisted.Coins else nil)
		local marked = persisted ~= nil and type(persisted._Scribe.Erase) == "table"
		b.Cleanup()
		a.Cleanup()
		local outcome = `checkpoint={tostring(checkpoint)} ok={result.Ok} reason={tostring(result.Reason)}`
		expect(`elsewhere={elsewhere} {outcome} coins={coins} marked={marked}`).to.equal(
			"elsewhere=true checkpoint=false ok=false reason=the profile was recreated since this erase began coins=7 marked=false"
		)
	end)

	it("reports success when another server finished the erase first", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70007)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local resume = parkedErase(a, 70007)
		task.wait(0.05)
		fake.Persisted[keyFor(70007)]._Scribe.Erase.Lease.Until = Clock.Now() - 1
		local elsewhere = b.Data.Erase(70007)
		local result, checkpoint = resume()
		local gone = fake.Persisted[keyFor(70007)] == nil
		b.Cleanup()
		a.Cleanup()
		expect(
			`elsewhere={elsewhere} checkpoint={tostring(checkpoint)} ok={result.Ok} reason={tostring(result.Reason)} gone={gone}`
		).to.equal("elsewhere=true checkpoint=false ok=true reason=nil gone=true")
	end)

	it("stops at a checkpoint while the recreated profile is live on another server", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70009)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local resume = parkedErase(a, 70009)
		task.wait(0.05)
		fake.Persisted[keyFor(70009)]._Scribe.Erase.Lease.Until = Clock.Now() - 1
		local elsewhere = b.Data.Erase(70009)
		local again, _, fresh = b.Join(70009)
		fresh.Coins.Set(7)
		b.Data.Flush(again)

		local result, checkpoint = resume()
		local persisted = fake.Persisted[keyFor(70009)]
		local marked = persisted ~= nil and type(persisted._Scribe.Erase) == "table"
		b.Leave(again)
		local coins = tostring(fake.Persisted[keyFor(70009)] and fake.Persisted[keyFor(70009)].Coins)
		b.Cleanup()
		a.Cleanup()
		local outcome = `checkpoint={tostring(checkpoint)} ok={result.Ok} reason={tostring(result.Reason)}`
		expect(`elsewhere={elsewhere} {outcome} marked={marked} coins={coins}`).to.equal(
			"elsewhere=true checkpoint=false ok=false reason=profile has an active session on another server marked=false coins=7"
		)
	end)

	it("stops when another erase has replaced its marker", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70008)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local resume = parkedErase(a, 70008)
		task.wait(0.05)
		fake.Persisted[keyFor(70008)]._Scribe.Erase = {
			StartedAt = 0,
			Done = {},
			Cursors = {},
			Lease = { Id = "other", Until = Clock.Now() + 300 },
		}
		local result, checkpoint = resume()
		local persisted = fake.Persisted[keyFor(70008)]
		local intact = persisted ~= nil and persisted.Coins == 555 and persisted._Scribe.Erase.Lease.Id == "other"
		a.Cleanup()
		expect(`checkpoint={tostring(checkpoint)} ok={result.Ok} reason={tostring(result.Reason)} intact={intact}`).to.equal(
			"checkpoint=false ok=false reason=another erase replaced this one intact=true"
		)
	end)

	it("does not mark a profile recreated between its read and its claim", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70010)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)
		local oldMeta = table.clone(fake.Meta[keyFor(70010)])

		-- Parks A's claim between its read and its write.
		local parked = true
		local armed = true
		fake.MidOfflineCommit = function()
			if armed then
				armed = false
				while parked do
					task.wait(0.02)
				end
			end
		end
		local out = {}
		Sched.Spawn(function()
			local ok, reason = a.Data.Erase(70010)
			table.insert(out, { Ok = ok, Reason = tostring(reason) })
		end)
		task.wait(0.05)
		local elsewhere = b.Data.Erase(70010)
		local again, _, fresh = b.Join(70010)
		fresh.Coins.Set(7)
		b.Data.Flush(again)
		b.Leave(again)
		-- The recreated key repeats every counter of the old one; only its generation differs.
		local meta = fake.Meta[keyFor(70010)]
		meta.LastUpdate, meta.WriteIndex, meta.SessionLoadCount =
			oldMeta.LastUpdate, oldMeta.WriteIndex, oldMeta.SessionLoadCount
		parked = false
		while #out == 0 do
			task.wait(0.02)
		end
		fake.MidOfflineCommit = nil
		local persisted = fake.Persisted[keyFor(70010)]
		local coins = tostring(persisted and persisted.Coins)
		local marked = persisted ~= nil and type(persisted._Scribe.Erase) == "table"
		local refused = string.find(out[1].Reason, "could not mark the profile for erasure", 1, true) ~= nil
		b.Cleanup()
		a.Cleanup()
		expect(`elsewhere={elsewhere} ok={out[1].Ok} refused={refused} coins={coins} marked={marked}`).to.equal(
			"elsewhere=true ok=false refused=true coins=7 marked=false"
		)
	end)

	it("does not resurrect a profile erased between its read and its claim", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })
		local first, _, data = a.Join(70014)
		data.Coins.Set(555)
		a.Data.Flush(first)
		a.Leave(first)

		local parked = true
		local armed = true
		fake.MidOfflineCommit = function()
			if armed then
				armed = false
				while parked do
					task.wait(0.02)
				end
			end
		end
		-- A's sweep fails, which is when a resurrected profile would be left behind.
		a.Ctx.Leaderboards.EraseUser = function()
			return false, "boom"
		end
		local out = {}
		Sched.Spawn(function()
			local ok, reason = a.Data.Erase(70014)
			table.insert(out, { Ok = ok, Reason = tostring(reason) })
		end)
		task.wait(0.05)
		local elsewhere = b.Data.Erase(70014)
		parked = false
		while #out == 0 do
			task.wait(0.02)
		end
		fake.MidOfflineCommit = nil
		local gone = fake.Persisted[keyFor(70014)] == nil
		b.Cleanup()
		a.Cleanup()
		expect(`elsewhere={elsewhere} ok={out[1].Ok} gone={gone}`).to.equal("elsewhere=true ok=false gone=true")
	end)

	it("marks a placeholder when no profile exists, so a join during the sweep is refused", function()
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake })
		local b = TestCtx.make({ Fake = fake })

		local resume = parkedErase(a, 70011)
		task.wait(0.05)
		local placeholder = fake.Persisted[keyFor(70011)]
		local marked = placeholder ~= nil and type(placeholder._Scribe.Erase) == "table"
		local player, _, accessor, reason = b.TryJoin(70011, 1)
		local result, checkpoint = resume()
		local gone = fake.Persisted[keyFor(70011)] == nil
		b.Cleanup()
		a.Cleanup()
		local outcome = `checkpoint={tostring(checkpoint)} ok={result.Ok} gone={gone}`
		expect(`marked={marked} refused={accessor == nil} reason={reason} kicked={player.Kicked ~= nil} {outcome}`).to.equal(
			"marked=true refused=true reason=erasing kicked=true checkpoint=true ok=true gone=true"
		)
	end)

	it("takes over a lapsed lease", function()
		local harness = TestCtx.make()
		local first, _, data = harness.Join(70012)
		data.Coins.Set(555)
		harness.Data.Flush(first)
		harness.Leave(first)
		harness.Fake.Persisted[keyFor(70012)]._Scribe.Erase = {
			StartedAt = 1,
			Done = {},
			Cursors = {},
			Lease = { Id = "dead", Until = Clock.Now() - 1 },
		}

		local ok, reason = harness.Data.Erase(70012)
		local gone = harness.Fake.Persisted[keyFor(70012)] == nil
		harness.Cleanup()
		expect(`ok={ok} reason={tostring(reason)} gone={gone}`).to.equal("ok=true reason=nil gone=true")
	end)

	it("refuses while another server's lease is live", function()
		local harness = TestCtx.make()
		local first, _, data = harness.Join(70013)
		data.Coins.Set(555)
		harness.Data.Flush(first)
		harness.Leave(first)
		harness.Fake.Persisted[keyFor(70013)]._Scribe.Erase = {
			StartedAt = 1,
			Done = {},
			Cursors = {},
			Lease = { Id = "other", Until = Clock.Now() + 300 },
		}

		local ok, reason = harness.Data.Erase(70013)
		local persisted = harness.Fake.Persisted[keyFor(70013)]
		local intact = persisted ~= nil and persisted.Coins == 555 and persisted._Scribe.Erase.Lease.Id == "other"
		harness.Cleanup()
		expect(`ok={ok} reason={tostring(reason)} intact={intact}`).to.equal(
			"ok=false reason=another erase of this profile is still running intact=true"
		)
	end)
end
