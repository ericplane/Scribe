--!nonstrict
-- Per-command metrics: duration, open calls, throws, and client timeouts by name.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local Clock = require(ScribeRoot.Internal.Clock)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local realMonotonic = Clock.Monotonic
	afterEach(function()
		Clock.Install({ Monotonic = realMonotonic })
	end)

	--- A command frame to the dispatcher, on its own thread as the transport would.
	local function send(harness, entry, correlation: number, name: string)
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, correlation)
		Wire.Str(w, name)
		Wire.U8(w, 0)
		Wire.Str(w, "")
		local reader = Wire.NewReader(Wire.Finish(w))
		Wire.RU8(reader)
		task.spawn(harness.Ctx.Commands.HandleFrame, entry, reader)
	end

	local function metric(name: string): any
		return Metrics.Get()[name]
	end

	it("gauges the calls a command has open and samples its duration when they return", function()
		local offset = 0
		Clock.Install({
			Monotonic = function()
				return realMonotonic() + offset
			end,
		})
		local harness = TestCtx.make({})
		local _, entry = harness.Join(93001)
		local parked = {}
		harness.Data.Command("MetricsSlow", {}, function()
			table.insert(parked, coroutine.running())
			coroutine.yield()
		end)
		for correlation = 1, 3 do
			send(harness, entry, correlation, "MetricsSlow")
		end
		local open = metric("CommandActive:MetricsSlow")
		local before = metric("CommandDuration:MetricsSlow")
		local countBefore = if before then before.Count else 0
		local sumBefore = if before then before.Average * before.Count else 0
		offset += 5
		for _, thread in parked do
			task.spawn(thread)
		end
		local closed = metric("CommandActive:MetricsSlow")
		local duration = metric("CommandDuration:MetricsSlow")
		local samples = duration.Count - countBefore
		local each = (duration.Average * duration.Count - sumBefore) / samples
		harness.Cleanup()
		expect(`open={open} closed={closed} samples={samples} each={math.round(each)}`).to.equal(
			"open=3 closed=0 samples=3 each=5"
		)
	end)

	it("counts a throwing handler against its own name, and still closes its call", function()
		local harness = TestCtx.make({})
		local _, entry = harness.Join(93002)
		harness.Data.Command("MetricsBoom", {}, function()
			error("no")
		end)
		harness.Data.Command("MetricsFine", {}, function()
			return true
		end)
		send(harness, entry, 1, "MetricsBoom")
		send(harness, entry, 2, "MetricsFine")
		local boom = metric("CommandErrors:MetricsBoom") or 0
		local fine = metric("CommandErrors:MetricsFine") or 0
		local open = metric("CommandActive:MetricsBoom")
		harness.Cleanup()
		expect(`boom={boom} fine={fine} open={open}`).to.equal("boom=1 fine=0 open=0")
	end)

	it("gauges open calls across bundles that registered the same command", function()
		local bundleA = TestCtx.make({})
		local bundleB = TestCtx.make({})
		local _, entryA = bundleA.Join(93004)
		local _, entryB = bundleB.Join(93005)
		local parkedA, parkedB = {}, {}
		bundleA.Data.Command("MetricsShared", {}, function()
			table.insert(parkedA, coroutine.running())
			coroutine.yield()
		end)
		bundleB.Data.Command("MetricsShared", {}, function()
			table.insert(parkedB, coroutine.running())
			coroutine.yield()
		end)
		send(bundleA, entryA, 1, "MetricsShared")
		send(bundleA, entryA, 2, "MetricsShared")
		send(bundleB, entryB, 3, "MetricsShared")
		local open = metric("CommandActive:MetricsShared")
		task.spawn(parkedB[1])
		local afterB = metric("CommandActive:MetricsShared")
		for _, thread in parkedA do
			task.spawn(thread)
		end
		local afterA = metric("CommandActive:MetricsShared")
		bundleA.Cleanup()
		bundleB.Cleanup()
		expect(`open={open} afterB={afterB} afterA={afterA}`).to.equal("open=3 afterB=2 afterA=0")
	end)

	itRunning("counts a request that timed out on the client, by command name", function()
		local harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
		local player = harness.Join(93003)
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		harness.Transport.AutoPump = false
		local before = metric("RequestTimeouts:Nothing") or 0
		local ok, reason = clientData.Request("Nothing")
		local after = metric("RequestTimeouts:Nothing") or 0
		harness.Transport.AutoPump = true
		clientData.Stop()
		harness.Cleanup()
		expect(`ok={ok} reason={reason} counted={after - before}`).to.equal("ok=false reason=timeout counted=1")
	end)

	itRunning("caps the timeout series a client can create and folds the rest under Other", function()
		local harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
		local player = harness.Join(93006)
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		harness.Transport.AutoPump = false
		local totalBefore = metric("RequestTimeouts") or 0
		local otherBefore = metric("RequestTimeouts:Other") or 0
		local settled = 0
		for i = 1, 40 do
			task.spawn(function()
				clientData.Request(`Gone{i}`)
				settled += 1
			end)
		end
		while settled < 40 do
			task.wait()
		end
		local named = 0
		for key in Metrics.Get() do
			if string.find(key, "RequestTimeouts:Gone", 1, true) == 1 then
				named += 1
			end
		end
		local total = (metric("RequestTimeouts") or 0) - totalBefore
		local other = (metric("RequestTimeouts:Other") or 0) - otherBefore
		harness.Transport.AutoPump = true
		clientData.Stop()
		harness.Cleanup()
		expect(`total={total} accounted={named + other == 40} capped={named <= 32} folded={other >= 8}`).to.equal(
			"total=40 accounted=true capped=true folded=true"
		)
	end)
end
