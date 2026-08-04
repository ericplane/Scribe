--!nonstrict
-- Scribe.ArrayOf(shape, { MaxItems = N, Evict = "Front" | "Back" }): a bounded
-- history that trims itself instead of erroring at the cap. The eviction goes
-- through the real remove path, so it emits a Remove op and fires OnRemove rather
-- than quietly shrinking the server's array out from under every mirror.
--
-- Evict names the END to drop from, not an age, because which end holds the oldest
-- entry depends on whether you append or prepend.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function evicting(maxItems: number)
		return TestCtx.make({
			AutoPump = true,
			Template = { Log = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = maxItems, Evict = "Front" }) },
		})
	end

	it("drops the oldest entry instead of erroring at the cap", function()
		local harness = evicting(3)
		local _player, _entry, data = harness.Join(96001)

		for i = 1, 6 do
			data.Log.Insert(i)
		end

		expect(data.Log.Count()).to.equal(3)
		expect(table.concat(data.Log.Get(), ",")).to.equal("4,5,6")

		harness.Cleanup()
	end)

	it("fires OnRemove for each evicted entry, so a listener sees what was dropped", function()
		local harness = evicting(3)
		local _player, _entry, data = harness.Join(96002)

		local dropped = {}
		data.Log.OnRemove(function(value)
			table.insert(dropped, tostring(value))
		end)

		for i = 1, 6 do
			data.Log.Insert(i)
		end

		expect(table.concat(dropped, ",")).to.equal("1,2,3")

		harness.Cleanup()
	end)

	it("still errors at the cap without Evict, which stays the default", function()
		local harness = TestCtx.make({
			Template = { Log = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 2 }) },
		})
		local _player, _entry, data = harness.Join(96003)
		data.Log.Insert(1)
		data.Log.Insert(2)

		expect(function()
			data.Log.Insert(3)
		end).to.throw()
		expect(data.Log.Count()).to.equal(2)

		harness.Cleanup()
	end)

	it("trims an array that is already over a lowered cap, not one entry per Insert", function()
		-- Reaching the cap from above happens when MaxItems is lowered in a later
		-- release, or when the data predates the cap. One eviction per Insert would
		-- leave it permanently over.
		local harness = evicting(2)
		local _player, entry, data = harness.Join(96004)
		-- Seed past the cap directly, the way a stored profile would arrive.
		entry.LiveData.Log = { 1, 2, 3, 4, 5 }

		data.Log.Insert(6)

		expect(data.Log.Count()).to.equal(2)
		expect(table.concat(data.Log.Get(), ",")).to.equal("5,6")

		harness.Cleanup()
	end)

	it("rolls the whole eviction back with a failed transaction", function()
		local harness = evicting(3)
		local player, _entry, data = harness.Join(96005)
		data.Log.Insert(1)
		data.Log.Insert(2)
		data.Log.Insert(3)

		local ok = harness.Data.Transaction(player, function()
			data.Log.Insert(4) -- evicts 1
			error("boom")
		end)

		expect(ok).to.equal(false)
		-- The evicted entry has to come back too, not just the inserted one.
		expect(table.concat(data.Log.Get(), ",")).to.equal("1,2,3")

		harness.Cleanup()
	end)

	it("rejects a misconfigured Evict at compile time", function()
		local function compile(opts)
			return function()
				TestCtx.make({ Template = { L = Scribe.ArrayOf(Scribe.Int(0), opts) } }).Cleanup()
			end
		end
		-- Only "Front" and "Back" exist; anything else would silently fall through to
		-- the cap error and read as if it were configured.
		expect(compile({ MaxItems = 3, Evict = "Sideways" })).to.throw()
		-- Evict has nothing to drop from without a cap.
		expect(compile({ Evict = "Front" })).to.throw()
		-- A typo must not leave the array quietly unbounded.
		expect(compile({ MaxItems = 3, Evicct = "Front" })).to.throw()
		expect(compile({ MaxItems = 3, Evict = "Front" })).never.to.throw()
	end)

	it("drops from the back for a prepend-style array", function()
		-- The reason the policy names an end rather than an age. Prepending with
		-- Insert(item, 1) puts the OLDEST entry at the back, so Evict = "Front" would
		-- evict the entry inserted a moment ago and churn the front forever while the
		-- tail froze. Concretely, MaxItems 3 prepending 1..5 under "Front" yields
		-- 5,2,1: it drops 3 and 4, from the middle.
		local harness = TestCtx.make({
			Template = { Log = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 3, Evict = "Back" }) },
		})
		local _player, _entry, data = harness.Join(96007)

		for i = 1, 5 do
			data.Log.Insert(i, 1)
		end

		-- Newest first, oldest dropped off the end.
		expect(table.concat(data.Log.Get(), ",")).to.equal("5,4,3")

		harness.Cleanup()
	end)

	it("trims multiple entries off the back when already over cap", function()
		-- Evicting more than one in a single Insert is the case that catches a stale
		-- tail index: the array shrinks under the loop, so the index of the last
		-- entry has to be recomputed each pass rather than reused.
		local harness = TestCtx.make({
			Template = { Log = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 2, Evict = "Back" }) },
		})
		local _player, entry, data = harness.Join(96008)
		entry.LiveData.Log = { 1, 2, 3, 4, 5 }

		data.Log.Insert(6, 1)

		-- Four evictions off the back leave { 1 }, then 6 prepends.
		expect(data.Log.Count()).to.equal(2)
		expect(table.concat(data.Log.Get(), ",")).to.equal("6,1")

		harness.Cleanup()
	end)

	itRunning("keeps the client mirror in step with the eviction", function()
		local harness = evicting(3)
		local player, entry, data = harness.Join(96006)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		for i = 1, 6 do
			data.Log.Insert(i)
		end
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()

		-- A silent table.remove on the server would leave the mirror holding all six
		-- and drifting further apart on every insert from here on.
		expect(table.concat(client.Log.Get(), ",")).to.equal("4,5,6")

		harness.Cleanup()
	end)
end
