--!nonstrict
-- The client's apply timers: one sample per Init, Diff and Shared frame applied.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local Clock = require(ScribeRoot.Internal.Clock)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local realMonotonic = Clock.Monotonic
	afterEach(function()
		Clock.Install({ Monotonic = realMonotonic })
	end)

	--- The sum of every sample so far, from the Count and Average GetMetrics reports.
	local function sumOf(name: string): number
		local record = Metrics.Get()[name]
		return if type(record) == "table" then record.Average * record.Count else 0
	end

	local function counts(): { [string]: number }
		local out = {}
		for _, name in { "InitApplyDuration", "DiffApplyDuration", "SharedApplyDuration" } do
			local record = Metrics.Get()[name]
			out[name] = if type(record) == "table" then record.Count else 0
		end
		return out
	end

	it("samples once per Init, Diff and Shared frame applied", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0), Public = Scribe.Shared({ Title = Scribe.String("") }) },
			Options = { Banner = false },
		})
		local a, _, dataA = harness.Join(91001)
		harness.SendHello(a)
		local b, _, dataB = harness.Join(91002)
		harness.Transport.LocalPlayer = b
		local before = counts()
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.Transport:PumpToServer()
		harness.Step()
		harness.Transport:PumpToClient()
		-- B's Init and A's SharedInit have landed.
		local mid = counts()
		dataB.Coins.Set(5)
		dataA.Public.Title.Set("x")
		harness.Step()
		harness.Transport:PumpToClient()
		local after = counts()
		clientB.Stop()
		harness.Cleanup()
		local joined =
			`init={mid.InitApplyDuration - before.InitApplyDuration} sharedInit={mid.SharedApplyDuration - before.SharedApplyDuration}`
		local later =
			`diff={after.DiffApplyDuration - mid.DiffApplyDuration} sharedDiff={after.SharedApplyDuration - mid.SharedApplyDuration}`
		expect(`{joined} {later}`).to.equal("init=1 sharedInit=1 diff=1 sharedDiff=1")
	end)

	--- A clock the spec moves by hand, and a client on it.
	local function drivenClient(template)
		local offset = 0
		Clock.Install({
			Monotonic = function()
				return realMonotonic() + offset
			end,
		})
		local harness = TestCtx.make({ Template = template, Options = { Banner = false } })
		local a, _, dataA = harness.Join(91003)
		harness.SendHello(a)
		local b, _, dataB = harness.Join(91004)
		harness.Transport.LocalPlayer = b
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.Transport:PumpToServer()
		harness.Step()
		harness.Transport:PumpToClient()
		return harness, clientB, dataA, dataB, function(seconds: number)
			offset += seconds
		end
	end

	--- Applies one frame; the sample it added to `name`.
	local function sampleOf(harness, name: string, write: () -> ()): number
		local before = sumOf(name)
		write()
		harness.Step()
		harness.Transport:PumpToClient()
		return sumOf(name) - before
	end

	it("counts a Changed listener in full, its waits included, since it runs inline", function()
		local harness, clientB, _, dataB, advance = drivenClient({ Coins = Scribe.Int(0) })
		local resumed = false
		clientB.Coins.Changed(function()
			advance(1000)
		end)
		clientB.Coins.Changed(function()
			task.wait()
			advance(7000)
			resumed = true
		end)
		local sample = sampleOf(harness, "DiffApplyDuration", function()
			dataB.Coins.Set(1)
		end)
		clientB.Stop()
		harness.Cleanup()
		expect(`resumed={resumed} sample={math.round(sample)}`).to.equal("resumed=true sample=8000")
	end)

	it("counts an OnSharedChanged handler up to its first yield, since it runs on its own thread", function()
		local harness, clientB, dataA, _, advance =
			drivenClient({ Coins = Scribe.Int(0), Public = Scribe.Shared({ Title = Scribe.String("") }) })
		local resumed = false
		clientB.OnSharedChanged:Connect(function()
			advance(1000)
		end)
		clientB.OnSharedChanged:Connect(function()
			task.wait()
			advance(7000)
			resumed = true
		end)
		local sample = sampleOf(harness, "SharedApplyDuration", function()
			dataA.Public.Title.Set("x")
		end)
		for _ = 1, 4 do
			task.wait()
		end
		clientB.Stop()
		harness.Cleanup()
		expect(`resumed={resumed} sample={math.round(sample)}`).to.equal("resumed=true sample=1000")
	end)
end
