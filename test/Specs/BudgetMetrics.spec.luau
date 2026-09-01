--!nonstrict
-- What the budget pacer reports. Before this an operator saw one player's phase and
-- nothing of the queue.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Budget = require(ScribeRoot.Internal.Budget)
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local Sched = require(ScribeRoot.Internal.Sched)

	local function fakeBudget(initial: number)
		local value = initial
		Budget.SetProbe(function()
			return value
		end)
		return function(new: number)
			value = new
		end
	end

	local function park(count: number, timeout: number)
		Sched.Spawn(function()
			Budget.Await("GetAsync", count, timeout)
		end)
	end

	beforeEach(function()
		Budget.Reset()
		Metrics.Reset()
	end)

	afterEach(function()
		Budget.Reset()
		Metrics.Reset()
	end)

	it("counts a fast-path grant", function()
		fakeBudget(10)
		Budget.Await("GetAsync", 1)
		local m = Metrics.Get()
		expect(`granted={m.BudgetGranted} queued={tostring(m.BudgetQueued)}`).to.equal("granted=1 queued=nil")
	end)

	it("reports the queue depth while waiters are parked, and zero once they drain", function()
		local set = fakeBudget(0)
		park(1, 30)
		park(1, 30)
		park(1, 30)
		local parked = Metrics.Get().BudgetWaiters
		set(50)
		for _ = 1, 12 do
			task.wait(0.2)
			if Metrics.Get().BudgetWaiters == 0 then
				break
			end
		end
		local m = Metrics.Get()
		expect(`parked={parked} after={m.BudgetWaiters} queued={m.BudgetQueued} granted={m.BudgetGranted}`).to.equal(
			"parked=3 after=0 queued=3 granted=3"
		)
	end)

	it("counts a timeout as timed out, not granted", function()
		fakeBudget(0)
		park(1, 0)
		local m = Metrics.Get()
		expect(`timedOut={m.BudgetTimedOut} granted={tostring(m.BudgetGranted)}`).to.equal("timedOut=1 granted=nil")
	end)

	it("observes how long a queued grant waited", function()
		-- Queued grants only; an instant grant would drag the distribution to zero.
		local set = fakeBudget(0)
		park(1, 30)
		set(50)
		for _ = 1, 12 do
			task.wait(0.2)
			if Metrics.Get().BudgetWaiters == 0 then
				break
			end
		end
		local obs = Metrics.Get().BudgetWaitSeconds
		expect(`observed={obs ~= nil} count={obs and obs.Count} positive={obs and obs.Max > 0}`).to.equal(
			"observed=true count=1 positive=true"
		)
	end)
end
