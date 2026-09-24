--!nonstrict
return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Log = require(Root.Scribe.Internal.Log)
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local Sched = require(Root.Scribe.Internal.Sched)
	local Scribe = require(Root.Scribe)
	local removers = {}
	local release = false

	local function attach(fn, options)
		local remove = Scribe.AddLogSink(fn, options)
		table.insert(removers, remove)
		return remove
	end

	local function captureWorkers()
		local workers = {}
		Sched.Install({
			Defer = function(fn, ...)
				local args = table.pack(...)
				local worker = coroutine.create(function()
					fn(table.unpack(args, 1, args.n))
				end)
				table.insert(workers, worker)
				return worker
			end,
		})
		return workers
	end

	beforeEach(function()
		release = false
		Log.SetLevel("Fatal")
		Log.SetRingLevel("Warn")
	end)

	afterEach(function()
		release = true
		for _, remove in removers do
			remove()
		end
		table.clear(removers)
		Sched.Reset()
		task.wait()
		Log.SetLevel("Debug")
		Log.SetRingLevel(nil)
	end)

	it("filters debug entries before allocating sink work or retaining them", function()
		Log.SetLevel("Warn")
		local calls, deferred = 0, 0
		local originalDefer = Sched.Defer
		Sched.Install({
			Defer = function(fn, ...)
				deferred += 1
				return originalDefer(fn, ...)
			end,
		})
		attach(function(entry)
			if entry.Message == "filtered debug" then
				calls += 1
			end
		end)
		for _ = 1, 100 do
			Log.Debug("Persistence", "PROFILE_SIZE", "filtered debug")
		end
		expect(deferred).to.equal(0)
		Sched.Reset()
		task.wait()
		expect(calls).to.equal(0)
		for _, entry in Log.GetRecent({ Code = "PROFILE_SIZE" }) do
			expect(entry.Message == "filtered debug").to.equal(false)
		end
	end)

	it("allows explicit debug capture independently of the console level", function()
		Log.SetRingLevel("Debug")
		local seen = {}
		attach(function(entry)
			table.insert(seen, entry.Message)
		end, { Level = "Debug" })
		Log.Debug("Persistence", "PROFILE_SIZE", "explicit debug capture")
		task.wait()
		expect(seen[1]).to.equal("explicit debug capture")
		local recent = Log.GetRecent({ Code = "PROFILE_SIZE", Limit = 1 })
		expect(recent[1].Message).to.equal("explicit debug capture")
	end)

	it("bounds slow sinks independently and counts overflow", function()
		local calls, active, peak = 0, 0, 0
		local workers = captureWorkers()
		for _ = 1, 2 do
			attach(function()
				calls += 1
				active += 1
				peak = math.max(peak, active)
				while not release do
					coroutine.yield()
				end
				active -= 1
			end, { Level = "Debug", MaxQueued = 3 })
		end
		local dropped = Metrics.Get().LogSinkDropped or 0
		for _ = 1, 100 do
			Log.Debug("Persistence", "PROFILE_SIZE", "slow sink")
		end
		expect(#workers).to.equal(2)
		for _, worker in workers do
			assert(coroutine.resume(worker))
		end
		expect(calls).to.equal(2)
		expect(active).to.equal(2)
		expect((Metrics.Get().LogSinkDropped or 0) - dropped).to.equal(194)
		release = true
		for _, worker in workers do
			assert(coroutine.resume(worker))
			expect(coroutine.status(worker)).to.equal("dead")
		end
		expect(calls).to.equal(6)
		expect(peak).to.equal(2)
		expect(active).to.equal(0)
	end)

	it("preserves higher severity entries when the queue is full", function()
		local workers = captureWorkers()
		local dropped = Metrics.Get().LogSinkDropped or 0
		local seen = {}
		attach(function(entry)
			table.insert(seen, entry.Message)
		end, { Level = "Debug", MaxQueued = 3 })
		Log.Debug("Persistence", "PROFILE_SIZE", "debug")
		Log.Warn("Persistence", "PROFILE_SIZE", "warning")
		Log.Info("Persistence", "PROFILE_SIZE", "info")
		Log.Error("Persistence", "PROFILE_SAVE_FAIL", "error")
		Log.Debug("Persistence", "PROFILE_SIZE", "dropped")
		expect(#workers).to.equal(1)
		expect(#seen).to.equal(0)
		-- Drain this burst without yielding to unrelated log producers.
		assert(coroutine.resume(workers[1]))
		expect(coroutine.status(workers[1])).to.equal("dead")
		expect(table.concat(seen, ",")).to.equal("warning,info,error")
		expect((Metrics.Get().LogSinkDropped or 0) - dropped).to.equal(2)
	end)

	it("clears queued entries on detach and isolates duplicate registrations", function()
		local calls = 0
		local callback = function()
			calls += 1
		end
		local remove = attach(callback, { Level = "Debug" })
		attach(callback, { Level = "Debug" })
		Log.Debug("Persistence", "PROFILE_SIZE", "queued")
		remove()
		remove()
		task.wait()
		expect(calls).to.equal(1)
	end)

	it("keeps processing after a sink throws", function()
		local calls = 0
		local errors = Metrics.Get().LogSinkErrors or 0
		attach(function()
			calls += 1
			if calls == 1 then
				error("expected sink failure")
			end
		end, { Level = "Debug" })
		Log.Debug("Persistence", "PROFILE_SIZE", "one")
		Log.Debug("Persistence", "PROFILE_SIZE", "two")
		task.wait()
		expect(calls).to.equal(2)
		expect((Metrics.Get().LogSinkErrors or 0) - errors).to.equal(1)
	end)

	it("rejects invalid queue capacities and levels", function()
		for _, size in { 0, -1, 1.5, math.huge, 0 / 0, 4097, "10" } do
			expect(pcall(Log.AddSink, function() end, { MaxQueued = size })).to.equal(false)
		end
		expect(pcall(Log.AddSink, function() end, { Level = "verbose" })).to.equal(false)
	end)
end
