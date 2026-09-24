--!nonstrict
return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Client = require(Root.Scribe.Client)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Sched = require(Root.Scribe.Internal.Sched)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local harness, client, removeSink
	local deferred, delays, waits, logs

	local function resume(thread, ...)
		local ok, message = coroutine.resume(thread, ...)
		assert(ok, message)
	end

	local function defer(fn, ...)
		local args = table.pack(...)
		local thread = coroutine.create(function()
			fn(table.unpack(args, 1, args.n))
		end)
		table.insert(deferred, thread)
		return thread
	end

	local function spawn(fn, ...)
		local thread = coroutine.create(fn)
		resume(thread, ...)
		return thread
	end

	local function drain()
		while #deferred > 0 do
			resume(table.remove(deferred, 1))
		end
	end

	local function makeClient(fetch)
		harness = TestCtx.make({
			Template = { Coins = 0 },
			Options = {
				IsRunning = false,
				Products = { One = { Id = 111 }, Two = { Id = 222 } },
				GetProductInfoAsync = fetch,
			},
		})
		client = Client.new(harness.Options, harness.Compiled)
		Sched.Install({ Spawn = spawn, Defer = defer, Resume = resume })
		Clock.Install({
			Wait = function()
				table.insert(waits, coroutine.running())
				return coroutine.yield()
			end,
			Delay = function(_seconds, fn, ...)
				local args = table.pack(...)
				local thread = coroutine.create(function()
					fn(table.unpack(args, 1, args.n))
				end)
				table.insert(delays, thread)
				return thread
			end,
		})
		removeSink = Scribe.AddLogSink(function(entry)
			if entry.Code == "PRODUCT_INFO_FAIL" or entry.Code == "PRODUCT_INFO_THROTTLED" then
				table.insert(logs, entry.Code)
			end
		end, { Level = "Warn" })
		return client
	end

	beforeEach(function()
		deferred, delays, waits, logs = {}, {}, {}, {}
		harness, client, removeSink = nil, nil, nil
	end)

	afterEach(function()
		if client then
			client.Stop()
		end
		if removeSink then
			removeSink()
		end
		Sched.Reset()
		Clock.Reset()
		Client.SetLocalPlayerProbe(nil)
		if harness then
			harness.Cleanup()
		end
	end)

	it("discards queued requests and refuses new product work after Stop", function()
		local calls, observed = 0, 0
		local data = makeClient(function()
			calls += 1
			return { PriceInRobux = 25 }
		end)
		data.PrefetchProductInfo()
		expect(#deferred).to.equal(1)
		data.Stop()
		data.Stop()
		drain()
		data.PrefetchProductInfo()
		data.RefreshProductInfo()
		data.RefreshProductInfo("One")
		expect(data.GetProductInfo("One")).to.equal(nil)
		expect(data.GetPrice("One")).to.equal(nil)
		expect(data.GetProductInfoAsync("One")).to.equal(nil)
		expect(data.GetPriceAsync("One")).to.equal(nil)
		local disconnect = data.ObserveProductInfo("One", function()
			observed += 1
		end)
		disconnect()
		drain()
		expect(calls).to.equal(0)
		expect(observed).to.equal(0)
		expect(#delays).to.equal(0)
	end)

	for _, succeeds in { true, false } do
		it(`discards an in-flight {if succeeds then "success" else "failure"} after Stop`, function()
			local request, calls, observed = nil, 0, 0
			local data = makeClient(function()
				calls += 1
				request = coroutine.running()
				coroutine.yield()
				if not succeeds then
					error("request refused")
				end
				return { PriceInRobux = 25 }
			end)
			data.ObserveProductInfo("One", function()
				observed += 1
			end)
			drain()
			expect(calls).to.equal(1)
			expect(observed).to.equal(1)
			data.Stop()
			resume(request)
			drain()
			expect(coroutine.status(request)).to.equal("dead")
			expect(calls).to.equal(1)
			expect(observed).to.equal(1)
			expect(#waits).to.equal(0)
			expect(#logs).to.equal(0)
			expect(data.GetProductInfo("One")).to.equal(nil)
		end)
	end

	it("does not retry or log again when Stop interrupts backoff", function()
		local calls = 0
		local data = makeClient(function()
			calls += 1
			error("request refused")
		end)
		data.GetProductInfo("One")
		drain()
		expect(calls).to.equal(1)
		expect(#waits).to.equal(1)
		expect(table.concat(logs, ",")).to.equal("PRODUCT_INFO_THROTTLED")
		data.Stop()
		resume(waits[1], 2)
		drain()
		expect(coroutine.status(waits[1])).to.equal("dead")
		expect(calls).to.equal(1)
		expect(#logs).to.equal(1)
	end)

	it("settles pending info and price readers once without waking their next wait", function()
		local request
		local data = makeClient(function()
			request = coroutine.running()
			coroutine.yield()
			return { PriceInRobux = 25 }
		end)
		local returned, spuriouslyResumed = 0, 0
		for _, read in { data.GetProductInfoAsync, data.GetPriceAsync } do
			spawn(function()
				expect(read("One")).to.equal(nil)
				returned += 1
				coroutine.yield()
				spuriouslyResumed += 1
			end)
		end
		drain()
		expect(returned).to.equal(0)
		expect(#delays).to.equal(2)
		data.Stop()
		expect(returned).to.equal(2)
		resume(request)
		for _, timeout in delays do
			resume(timeout)
		end
		data.Stop()
		drain()
		expect(returned).to.equal(2)
		expect(spuriouslyResumed).to.equal(0)
	end)

	it("settles remaining readers with nil when a resumed reader calls Stop", function()
		local data = makeClient(function()
			return { PriceInRobux = 25 }
		end)
		local first, second, observed, returned = nil, "pending", 0, 0
		data.ObserveProductInfo("One", function()
			observed += 1
		end)
		spawn(function()
			first = data.GetProductInfoAsync("One")
			returned += 1
			data.Stop()
		end)
		spawn(function()
			second = data.GetProductInfoAsync("One")
			returned += 1
		end)
		drain()
		expect(first.PriceInRobux).to.equal(25)
		expect(second).to.equal(nil)
		expect(returned).to.equal(2)
		expect(observed).to.equal(1)
		for _, timeout in delays do
			resume(timeout)
		end
		expect(returned).to.equal(2)
	end)

	it("skips remaining observers and batch requests when an observer calls Stop", function()
		local calls, first, second = 0, 0, 0
		local data = makeClient(function()
			calls += 1
			return { PriceInRobux = 25 }
		end)
		data.ObserveProductInfo("One", function(info)
			first += 1
			if info then
				data.Stop()
			end
		end)
		data.ObserveProductInfo("One", function()
			second += 1
		end)
		data.GetProductInfo("Two")
		drain()
		expect(first).to.equal(2)
		expect(second).to.equal(1)
		expect(calls).to.equal(1)
	end)
end
