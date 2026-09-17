--!nonstrict
-- The window behind a percentile: samples held, age of the newest, span of the ring.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local Clock = require(Root.Scribe.Internal.Clock)

	local realMonotonic = Clock.Monotonic
	afterEach(function()
		Clock.Install({ Monotonic = realMonotonic })
	end)

	local function drivenClock()
		local now = 0
		Clock.Install({
			Monotonic = function()
				return now
			end,
		})
		return function(t: number)
			now = t
		end
	end

	it("reports the samples held, the age of the newest and the span of the ring", function()
		local set = drivenClock()
		Metrics.Reset()
		set(100)
		Metrics.Observe("PW", 1)
		set(130)
		Metrics.Observe("PW", 2)
		set(160)
		Metrics.Observe("PW", 3)
		set(175)
		local p = Metrics.Percentiles("PW")
		expect(`samples={p.Samples} age={p.Age} window={p.Window}`).to.equal("samples=3 age=15 window=60")
	end)

	it("spans from the oldest sample still in the ring once it has wrapped", function()
		local set = drivenClock()
		Metrics.Reset()
		-- The ring keeps the last 256 of 300, t=44 to t=299.
		for i = 0, 299 do
			set(i)
			Metrics.Observe("PW", i)
		end
		set(299)
		local p = Metrics.Percentiles("PW")
		local total = Metrics.Get().PW.Count
		expect(`samples={p.Samples} total={total} window={p.Window} age={p.Age}`).to.equal(
			"samples=256 total=300 window=255 age=0"
		)
	end)

	it("is absent for a name never observed, as before", function()
		Metrics.Reset()
		expect(Metrics.Percentiles("Never")).to.equal(nil)
	end)
end
