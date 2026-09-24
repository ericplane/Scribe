--!nonstrict
-- Test admission rates with virtual time, independently of the disk simulator.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Budget = require(Root.Scribe.Internal.Budget)
	local Clock = require(Root.Scribe.Internal.Clock)
	local now, players, remaining
	local WRITE, READ = "SetIncrementSortedAsync", "GetSortedAsync"

	beforeEach(function()
		Budget.Reset()
		now, players, remaining = 0, 1, 1000
		Clock.Install({
			Monotonic = function()
				return now
			end,
		})
		Budget.SetProbe(function()
			return remaining
		end, function()
			return players
		end)
	end)

	afterEach(function()
		Budget.Reset()
		Clock.Reset()
	end)

	local function take(kind)
		local allowed, release = Budget.TryBackground(kind)
		release()
		return allowed
	end

	it("shares a bounded burst between independent callers and keeps pools separate", function()
		for _ = 1, 8 do
			expect(take(WRITE)).to.equal(true)
		end
		expect(take(WRITE)).to.equal(false)
		expect(take(READ)).to.equal(true)
		expect(take(READ)).to.equal(true)
		expect(take(READ)).to.equal(false)
	end)

	it("leaves one fifth of a minute of write allowance and at least two sorted reads", function()
		remaining = 7 -- one player's write allowance is 35/minute; reserve is seven
		expect(take(WRITE)).to.equal(false)
		remaining = 8
		expect(take(WRITE)).to.equal(true)
		remaining = 2
		expect(take(READ)).to.equal(false)
		remaining = 3
		expect(take(READ)).to.equal(true)
	end)

	it("keeps slow requests reserved until release even beyond the foreground grant TTL", function()
		remaining = 8
		local allowed, release = Budget.TryBackground(WRITE)
		expect(allowed).to.equal(true)
		now = 30
		expect(take(WRITE)).to.equal(false)
		release()
		release() -- idempotent, including after the outstanding list is compacted
		expect(take(WRITE)).to.equal(true)
	end)

	it("counts background reservations when granting a foreground Await", function()
		remaining = 8
		local allowed, release = Budget.TryBackground(WRITE)
		expect(allowed).to.equal(true)
		local blocked, releaseBlocked = Budget.Await(WRITE, 8, 0)
		expect(blocked).to.equal(false)
		releaseBlocked()
		release()
		local granted, releaseGranted = Budget.Await(WRITE, 8, 0)
		expect(granted).to.equal(true)
		releaseGranted()
	end)

	it("counts foreground grants and configured reserves against background admission", function()
		remaining = 8
		local allowed, release = Budget.Await(WRITE, 1)
		expect(allowed).to.equal(true)
		expect(take(WRITE)).to.equal(false)
		release()
		Budget.SetReserve(WRITE, 8)
		expect(take(WRITE)).to.equal(false)
		Budget.SetReserve(WRITE, 0)
		expect(take(WRITE)).to.equal(true)
	end)

	it("does not spend rate tokens on a budget refusal or refund tokens on release", function()
		remaining = 0
		for _ = 1, 20 do
			expect(take(WRITE)).to.equal(false)
		end
		remaining = 1000
		local count = 0
		for _ = 1, 20 do
			if take(WRITE) then
				count += 1
			end
		end
		expect(count).to.equal(8)
	end)

	it("bounds five minutes of sustained one-player requests even with an unknown engine budget", function()
		remaining = nil
		local writes, reads = 0, 0
		-- Four requests/second exceeds the 28 writes and 5.6 reads/minute limit.
		for tick = 0, 1200 do
			now = tick / 4
			if take(WRITE) then
				writes += 1
			end
			if take(READ) then
				reads += 1
			end
		end
		-- Initial burst plus five minutes of refill; allow one token for rounding.
		expect(writes >= 147 and writes <= 148).to.equal(true)
		expect(reads >= 29 and reads <= 30).to.equal(true)
	end)

	it("caps idle credit and updates the sustained rate as player count changes", function()
		players = 0
		for _ = 1, 8 do
			take(WRITE)
		end
		now = 3600
		players = 100
		local count = 0
		for _ = 1, 20 do
			if take(WRITE) then
				count += 1
			end
		end
		expect(count).to.equal(8)
		now += 1
		-- 80% of (30 + 100 * 5), or about seven tokens per second.
		count = 0
		for _ = 1, 20 do
			if take(WRITE) then
				count += 1
			end
		end
		expect(count).to.equal(7)
	end)
end
