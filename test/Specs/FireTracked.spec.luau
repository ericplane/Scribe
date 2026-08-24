--!nonstrict
-- Signal.FireTracked's SETTLEMENT CONTRACT, pinned directly rather than through
-- the one caller that happens to use it.
--
-- WHY A DIRECT SPEC EXISTS. FireTracked is a new primitive and it sits on the money
-- path: the cross-server message drain decides whether to ACKNOWLEDGE a message --
-- retiring it from the recipient's key forever -- purely from what onSettled says.
-- It was reachable only through MessageAckDurability.spec and
-- CrossPlayerTxnAtomicity.spec, both of which drive it through a whole profile
-- lifecycle and assert on mailbox depth, and neither of which pins the settlement
-- condition itself. MEASURED: rewriting `if dispatched and settled == ran` to
-- `if dispatched and settled == 1` -- settle on the FIRST handler instead of the
-- last, which acks a message while other handlers are still parked mid-write --
-- left the FULL SUITE GREEN at 1716 tests. Re-measured with this file in place: that
-- same mutation now fails four tests, and those four are the ONLY failures in the
-- whole suite. This file is the net under that line, and nothing else is.
--
-- THE CONTRACT, in one place:
--   * onSettled is called EXACTLY ONCE per FireTracked, or not at all.
--   * It is called only once EVERY live handler has returned or raised -- never
--     after the first, never mid-walk of the connection list.
--   * It is called SYNCHRONOUSLY (before FireTracked returns) when nothing yielded,
--     including when nothing is connected; otherwise on the last handler's thread.
--   * `ran` is how many connections were live when the walk reached them.
--   * `ok` is false if ANY handler raised; `err` is the FIRST error seen.
--   * A handler that yields and never returns never settles -- the caller is never
--     told to acknowledge. That is the safe direction, and it is the premise the
--     MESSAGE_HANDLER_STALLED diagnostic is built on, so it is pinned here too.
--
-- Handlers park on a bare `coroutine.yield()` rather than `task.wait()` so the
-- spec, not the scheduler, decides when (and whether) each one finishes. Every
-- assertion is a single formatted string containing the state at EVERY step, so a
-- settle that lands one step early is a diff rather than a missing assertion.

return function()
	local Root = script.Parent.Parent.Parent
	local Signal = require(Root.Scribe.Internal.Signal)

	--- Records every onSettled call. Reading back a joined string rather than a
	--- count is what makes "exactly once" measurable: two settles render as two
	--- segments instead of quietly overwriting one another.
	local function recorder()
		local calls = {}
		local function onSettled(ran: number, ok: boolean, err: any)
			table.insert(calls, ("ran=%d ok=%s err=%s"):format(ran, tostring(ok), tostring(err)))
		end
		local function state(): string
			if #calls == 0 then
				return "none"
			end
			return table.concat(calls, " ++ ")
		end
		return onSettled, state
	end

	--- A handler that parks at its first yield and stores its thread under `name`,
	--- so the spec resumes it explicitly. `after` runs on resume with the ORIGINAL
	--- fire arguments, which is how a late error is produced.
	local function parking(threads: { [string]: thread }, name: string, after: ((...any) -> ())?)
		return function(...)
			local args = table.pack(...)
			threads[name] = coroutine.running()
			coroutine.yield()
			if after then
				after(table.unpack(args, 1, args.n))
			end
		end
	end

	local function resume(threads: { [string]: thread }, name: string)
		local thread = threads[name]
		if thread == nil then
			error(`the handler named "{name}" never parked`, 2)
		end
		task.spawn(thread)
	end

	--------------------------------------------------------------------------------
	-- The synchronous cases: settled before FireTracked returns
	--------------------------------------------------------------------------------

	it("settles synchronously with ran=0 when nothing is connected", function()
		-- The drain's MESSAGE_NO_LISTENER arm is entirely this call. Nothing yields,
		-- so a settle observed on the very next line was necessarily synchronous.
		local signal = Signal.new()
		local onSettled, state = recorder()

		signal:FireTracked(onSettled, "player", { Amount = 50 })

		expect(state()).to.equal("ran=0 ok=true err=nil")
	end)

	it("settles synchronously, once, when every handler returns without yielding", function()
		local signal = Signal.new()
		local onSettled, state = recorder()

		local seen = {}
		signal:Connect(function(who, payload)
			table.insert(seen, ("A:%s:%d"):format(who, payload.Amount))
		end)
		signal:Connect(function(who, payload)
			table.insert(seen, ("B:%s:%d"):format(who, payload.Amount))
		end)

		signal:FireTracked(onSettled, "player", { Amount = 50 })
		table.sort(seen) -- Connect prepends, so dispatch order is B then A

		expect(("%s | %s"):format(table.concat(seen, ","), state())).to.equal(
			"A:player:50,B:player:50 | ran=2 ok=true err=nil"
		)
	end)

	it("does not count a connection that was disconnected before the fire", function()
		local signal = Signal.new()
		local onSettled, state = recorder()

		local ran = 0
		local live = signal:Connect(function()
			ran += 1
		end)
		local dead = signal:Connect(function()
			ran += 100
		end)
		dead:Disconnect()

		signal:FireTracked(onSettled)
		expect(("ran=%d %s"):format(ran, state())).to.equal("ran=1 ran=1 ok=true err=nil")

		live:Disconnect()
		local onSettled2, state2 = recorder()
		signal:FireTracked(onSettled2)
		expect(state2()).to.equal("ran=0 ok=true err=nil")
	end)

	--------------------------------------------------------------------------------
	-- The asynchronous cases: settled on the LAST handler, never the first
	--------------------------------------------------------------------------------

	it("does not settle until a lone parked handler returns", function()
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "A"))

		signal:FireTracked(onSettled)
		local atFire = state()
		resume(threads, "A")

		expect(("fire=[%s] resumed=[%s]"):format(atFire, state())).to.equal(
			"fire=[none] resumed=[ran=1 ok=true err=nil]"
		)
	end)

	it("waits for the LAST parked handler, not the first", function()
		-- THE `settled == 1` MUTANT'S EXECUTION. Two handlers park; resuming only the
		-- first must change nothing observable. Settling here is precisely the bug
		-- that acks a cross-server message while a second handler is still parked
		-- before its write.
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "A"))
		signal:Connect(parking(threads, "B"))

		signal:FireTracked(onSettled)
		local atFire = state()
		resume(threads, "A")
		local afterA = state()
		resume(threads, "B")

		expect(("fire=[%s] A=[%s] B=[%s]"):format(atFire, afterA, state())).to.equal(
			"fire=[none] A=[none] B=[ran=2 ok=true err=nil]"
		)
	end)

	it("waits for the parked handler even when a sibling already finished synchronously", function()
		-- The mixed shape, and the reason `dispatched` exists: the synchronous handler
		-- completes DURING the walk, when `ran` still counts only the handlers reached
		-- so far. Settling on that moment reports a smaller `ran` than actually ran and
		-- does it before the parked sibling has done anything.
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		local syncRan = 0
		signal:Connect(parking(threads, "slow"))
		signal:Connect(function()
			syncRan += 1
		end)

		signal:FireTracked(onSettled)
		local atFire = ("sync=%d %s"):format(syncRan, state())
		resume(threads, "slow")

		expect(("fire=[%s] resumed=[%s]"):format(atFire, state())).to.equal(
			"fire=[sync=1 none] resumed=[ran=2 ok=true err=nil]"
		)
	end)

	it("settles once, after the last, when parked handlers finish out of order", function()
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "A"))
		signal:Connect(parking(threads, "B"))
		signal:Connect(parking(threads, "C"))

		signal:FireTracked(onSettled)
		local steps = { state() }
		for _, name in { "C", "A", "B" } do
			resume(threads, name)
			table.insert(steps, state())
		end

		expect(table.concat(steps, " / ")).to.equal("none / none / none / ran=3 ok=true err=nil")
	end)

	it("never settles while a handler stays parked, however long the scheduler runs", function()
		-- THE INVISIBLE CASE, and the premise MESSAGE_HANDLER_STALLED is built on: a
		-- handler that never returns means the caller is never told to acknowledge.
		-- Withholding is correct; the drain is responsible for saying so out loud.
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		local good = 0
		signal:Connect(parking(threads, "stuck"))
		signal:Connect(function()
			good += 1
		end)

		signal:FireTracked(onSettled)
		for _ = 1, 5 do
			task.wait()
		end

		expect(("good=%d %s"):format(good, state())).to.equal("good=1 none")
	end)

	--------------------------------------------------------------------------------
	-- Errors: ok, and which error is reported
	--------------------------------------------------------------------------------

	it("reports a synchronous handler's error instead of letting it reach the scheduler", function()
		local signal = Signal.new()
		local onSettled, state = recorder()

		signal:Connect(function()
			error("sync boom", 0)
		end)

		signal:FireTracked(onSettled)

		expect(state()).to.equal("ran=1 ok=false err=sync boom")
	end)

	it("reports a parked handler's error, raised long after FireTracked returned", function()
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "A", function()
			error("late boom", 0)
		end))

		signal:FireTracked(onSettled)
		local atFire = state()
		resume(threads, "A")

		expect(("fire=[%s] resumed=[%s]"):format(atFire, state())).to.equal(
			"fire=[none] resumed=[ran=1 ok=false err=late boom]"
		)
	end)

	it("answers ok=false when a LATER handler raises after an earlier one succeeded", function()
		-- Settling early would answer ok=true here and the caller would acknowledge a
		-- message one of its handlers blew up on. The success is resumed FIRST on
		-- purpose: that is the ordering in which an early settle looks healthy.
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "good"))
		signal:Connect(parking(threads, "bad", function()
			error("second handler blew up", 0)
		end))

		signal:FireTracked(onSettled)
		resume(threads, "good")
		local afterGood = state()
		resume(threads, "bad")

		expect(("good=[%s] bad=[%s]"):format(afterGood, state())).to.equal(
			"good=[none] bad=[ran=2 ok=false err=second handler blew up]"
		)
	end)

	it("keeps the FIRST error when several handlers raise", function()
		local signal = Signal.new()
		local onSettled, state = recorder()
		local threads = {}

		signal:Connect(parking(threads, "first", function()
			error("first error", 0)
		end))
		signal:Connect(parking(threads, "second", function()
			error("second error", 0)
		end))

		signal:FireTracked(onSettled)
		resume(threads, "first")
		resume(threads, "second")

		expect(state()).to.equal("ran=2 ok=false err=first error")
	end)

	it("still settles ok=false when every handler raised synchronously", function()
		local signal = Signal.new()
		local onSettled, state = recorder()

		signal:Connect(function()
			error("alpha", 0)
		end)
		signal:Connect(function()
			error("beta", 0)
		end)

		signal:FireTracked(onSettled)

		-- Connect prepends, so beta is dispatched first and is therefore the first
		-- error seen. Asserting the exact one keeps "first error wins" honest.
		expect(state()).to.equal("ran=2 ok=false err=beta")
	end)

	--------------------------------------------------------------------------------
	-- Independence from Fire
	--------------------------------------------------------------------------------

	it("leaves the ordinary Fire path untouched, including its cached runner thread", function()
		-- FireTracked spawns a FRESH thread per handler; Fire reuses one cached runner.
		-- A change that made FireTracked borrow the runner would break Fire's reuse
		-- invariant silently, so both are exercised against the same signal.
		local signal = Signal.new()
		local onSettled, state = recorder()

		local hits = {}
		signal:Connect(function(tag)
			table.insert(hits, tag)
		end)

		signal:Fire("fire-1")
		signal:FireTracked(onSettled, "tracked")
		signal:Fire("fire-2")
		task.wait()

		expect(("%s | %s"):format(table.concat(hits, ","), state())).to.equal(
			"fire-1,tracked,fire-2 | ran=1 ok=true err=nil"
		)
	end)
end
