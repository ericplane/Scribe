--!nonstrict
-- The Client.Request return contract: ARITY, and the send-failure path.
--
-- CHARACTERISATION ONLY. Every assertion below is true of the tree as it stands
-- and must stay true of it. Nothing here is a red-before pin on a fix.
--
-- Two gaps this closes, both measured rather than assumed:
--
--   * `select("#"` appeared nowhere in any spec that calls Request. Four spec
--     files drive commands (ClientLoopback, CommandIdempotency, Entrypoint,
--     SimReplication) and all of them assert on the VALUES a request returned,
--     none on how many there were. Request is transparent RPC -- the guide's
--     words are "returns whatever its handler returned" -- so the width of the
--     tuple is half of the contract and it was the unwatched half.
--   * "send-failed" existed only as a string in the RequestReason union
--     (Reasons.spec.luau:42). No spec had ever made a send actually fail, so
--     nothing knew what a caller receives when it does.
--
-- Why the count needs its own assertion rather than a table length: `#` cannot
-- see a returned nil, and on a table with a hole it is not merely lossy but
-- undefined. `#{ nil }` is 0 and `#{ true, nil, nil }` is 1, so an implementation
-- that re-derived the arity from its results table would satisfy every value
-- assertion in the suite while handing the caller the wrong number of returns.
-- The server (Commands.encodeReply) and the client (handleFrame) each carry an
-- explicit count for exactly that reason; until now nothing checked that either
-- of them used it.
--
-- Deliberately NOT rebuilt here, because it already exists:
--   ClientLoopback.spec.luau:621 -- a request with no reply resolves "timeout"
--     and takes at least RequestTimeout to do it.
--   ClientLoopback.spec.luau:640 -- a framework refusal carries the frozen
--     Scribe.RequestFailed marker and a handler returning the same two leading
--     values does not.
--   ClientLoopback.spec.luau:675 -- the client-local timeout carries the marker.
--   CommandIdempotency.spec.luau:482 -- RequestOnce runs the handler once and
--     replays the same values.
-- What is added against those is the COUNT, which none of them assert.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- Same shape as ClientLoopback's helper: a server harness plus a real Client
	-- instance wired through one loopback transport.
	local function makeLoopback(extraOptions)
		local options = { RequestTimeout = 0.25, CommandRateLimit = 1000 }
		for key, value in extraOptions or {} do
			options[key] = value
		end
		local harness = TestCtx.make({ AutoPump = true, Options = options })
		local player, entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		return harness, player, entry, serverData, clientData
	end

	-- THE arity primitive. `select("#", ...)` is the only construct in Luau that
	-- reports a tuple's true width, so it is what every assertion below counts
	-- with. The values ride in a plain table that is read BY INDEX ONLY -- never
	-- with `#`, never by iteration -- so a hole in it stays observable as nil
	-- instead of silently shortening the record of what arrived.
	local function capture(...)
		return select("#", ...), { ... }
	end

	-- Tables render as the bare word "table" so a summary string can name the
	-- RequestFailed marker without embedding its address.
	local function show(value: any): string
		return if type(value) == "table" then "table" else tostring(value)
	end

	local function render(n: number, values: { any }): string
		local parts = {}
		for i = 1, n do
			table.insert(parts, show(values[i]))
		end
		return `n={n} [{table.concat(parts, ",")}]`
	end

	-- One table of cases, driven twice: once over an AutoPump loopback and once
	-- pumped by hand. Expectations are written once so the two exits cannot drift.
	--
	-- The shapes are chosen to defeat a length-derived count rather than to be
	-- representative. `RetNil` dies under `#` (0 instead of 1), `RetTrailingNil`
	-- dies under `#` (1 instead of 2), and `RetTrueNilNil` is the one an implicit
	-- count gets wrong in the least obvious way, since `#{ true, nil, nil }` is 1.
	-- `RetHole` happens to survive `#` on this build -- it is here for the value
	-- assertion (a nil BETWEEN two values must arrive as a nil, not close the
	-- tuple early), not as a mutation trap.
	local ARITY_CASES = {
		{
			Name = "RetNone",
			Handler = function() end,
			Expect = "n=0 []",
		},
		{
			Name = "RetNil",
			Handler = function()
				return nil
			end,
			Expect = "n=1 [nil]",
		},
		{
			Name = "RetTrailingNil",
			Handler = function()
				return 1, nil
			end,
			Expect = "n=2 [1,nil]",
		},
		{
			Name = "RetHole",
			Handler = function()
				return 1, nil, 3
			end,
			Expect = "n=3 [1,nil,3]",
		},
		{
			Name = "RetTrueNilNil",
			Handler = function()
				return true, nil, nil
			end,
			Expect = "n=3 [true,nil,nil]",
		},
		{
			Name = "RetMany",
			Handler = function()
				return "a", 2, true, false, "e"
			end,
			Expect = "n=5 [a,2,true,false,e]",
		},
	}

	local function registerCases(harness)
		for _, case in ARITY_CASES do
			harness.Data.Command(case.Name, case.Handler)
		end
	end

	local function expectedLines(prefix: (any) -> string): string
		local lines = {}
		for _, case in ARITY_CASES do
			table.insert(lines, `{prefix(case)}{case.Expect}`)
		end
		return table.concat(lines, "\n")
	end

	describe("Client.Request arity", function()
		itRunning("returns a handler's tuple at its exact width, nils included, over an AutoPump loopback", function()
			local harness, _, _, _, clientData = makeLoopback()
			registerCases(harness)

			local seen = {}
			for _, case in ARITY_CASES do
				local n, values = capture(clientData.Request(case.Name))
				table.insert(seen, `{case.Name} {render(n, values)}`)
			end

			-- Read, tear down, then assert: a failing assertion before Cleanup leaves
			-- a live entry and a live bundle for the rest of the run to trip over.
			local summary = table.concat(seen, "\n")
			harness.Cleanup()
			expect(summary).to.equal(expectedLines(function(case)
				return `{case.Name} `
			end))
		end)

		itRunning("returns the identical tuple when the requester parks and a pumped reply wakes it", function()
			-- The other exit. With AutoPump off the reply cannot arrive during the
			-- send, so the requester genuinely suspends and is resumed with the
			-- values -- a different code path from the one above, and it has to agree
			-- with it to the value and to the count.
			local harness, _, _, _, clientData = makeLoopback({ RequestTimeout = 5 })
			registerCases(harness)
			-- After the handshake, so `loaded` is already true and nothing below is
			-- waiting on an Init that will never be delivered.
			harness.Transport.AutoPump = false

			local seen = {}
			for _, case in ARITY_CASES do
				local line = nil
				local requester = coroutine.create(function()
					local n, values = capture(clientData.Request(case.Name))
					line = render(n, values)
				end)
				coroutine.resume(requester)
				-- One scheduler step: the send is queued with Sched.Defer today, so the
				-- Command frame is not on the wire until that deferred callback runs.
				-- Harmless if it ever becomes an inline send -- the frame is simply
				-- already there.
				task.wait()
				harness.Transport:PumpToServer()
				harness.Transport:PumpToClient()
				-- The status is part of the recorded line rather than a separate
				-- expect, so a reply that failed to wake the requester fails HERE, on
				-- "suspended", instead of hanging until RequestTimeout and then
				-- reporting a perfectly well-formed timeout tuple.
				table.insert(seen, `{case.Name} {coroutine.status(requester)} {tostring(line)}`)
			end
			harness.Transport.AutoPump = true

			local summary = table.concat(seen, "\n")
			harness.Cleanup()
			expect(summary).to.equal(expectedLines(function(case)
				return `{case.Name} dead `
			end))
		end)

		itRunning("replays an idempotent reply at its original width, trailing nil included", function()
			-- CommandIdempotency:482 pins that a replay carries the same VALUES. The
			-- cached record stores the handler's table.pack as it stands, specifically
			-- so `.n` survives (Commands.settleIdempotent says so in as many words),
			-- and a trailing nil is the only shape that can tell a preserved `.n` from
			-- a re-derived `#`.
			local harness, _, _, _, clientData = makeLoopback()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
				return "granted", nil
			end)

			local firstN, firstValues = capture(clientData.RequestOnce("Claim", "click-1"))
			local replayN, replayValues = capture(clientData.RequestOnce("Claim", "click-1"))

			local summary = table.concat({
				`runs={runs}`,
				`first {render(firstN, firstValues)}`,
				`replay {render(replayN, replayValues)}`,
			}, "\n")
			harness.Cleanup()
			expect(summary).to.equal(table.concat({
				"runs=1",
				"first n=2 [granted,nil]",
				"replay n=2 [granted,nil]",
			}, "\n"))
		end)
	end)

	describe("Client.Request failure tuples", function()
		itRunning("resolves send-failed, marked and three values wide, when the transport raises", function()
			-- RequestTimeout is long here on purpose. "send-failed arrived" is not the
			-- whole claim: it has to arrive BECAUSE the send failed, not because the
			-- request later timed out into a tuple of the same shape. A timeout rescue
			-- would take five seconds and fail the elapsed assertion rather than
			-- passing the value one.
			local harness, _, _, _, clientData = makeLoopback({ RequestTimeout = 5 })
			local ran = 0
			harness.Data.Command("Ping", function()
				ran += 1
				return true
			end)

			local realSend = harness.Transport.SendToServer
			harness.Transport.SendToServer = function()
				error("the transport is down")
			end
			local started = os.clock()
			local n, values = capture(clientData.Request("Ping"))
			local elapsed = os.clock() - started
			harness.Transport.SendToServer = realSend

			local summary = `{render(n, values)} marked={values[3] == Scribe.RequestFailed} `
				.. `fast={elapsed < 1} ran={ran}`
			harness.Cleanup()
			-- ran=0 is load-bearing: nothing reached the server, so this is the send
			-- failing and not a handler that refused.
			expect(summary).to.equal("n=3 [false,send-failed,table] marked=true fast=true ran=0")
		end)

		itRunning("resolves send-failed when there is no SendToServer to call at all", function()
			-- dispatchRequest justifies having no transport check of its own with "A
			-- nil transport would still be caught by the pcall around SendToServer
			-- below, surfacing as send-failed". That is a claim about the pcall's
			-- BREADTH -- it has to catch a call on a nil value, not only a send that
			-- raised -- and nothing exercised it.
			local harness, _, _, _, clientData = makeLoopback({ RequestTimeout = 5 })
			harness.Data.Command("Ping", function()
				return true
			end)

			local realSend = harness.Transport.SendToServer
			harness.Transport.SendToServer = nil
			local started = os.clock()
			local n, values = capture(clientData.Request("Ping"))
			local elapsed = os.clock() - started
			harness.Transport.SendToServer = realSend

			local summary = `{render(n, values)} marked={values[3] == Scribe.RequestFailed} fast={elapsed < 1}`
			harness.Cleanup()
			expect(summary).to.equal("n=3 [false,send-failed,table] marked=true fast=true")
		end)

		itRunning("gives a framework refusal three values and pads a handler's tuple never", function()
			-- ClientLoopback:640 and :675 pin WHICH values a refusal carries and that
			-- the third is the frozen Scribe.RequestFailed. Neither asserts how MANY,
			-- and the count is precisely what a caller writing
			-- `local ok, reason, marker = Data.Request(...)` depends on.
			--
			-- The contrast case is the point of the spec, not decoration: Scribe
			-- appends its marker to its OWN refusals only, so a handler that returns
			-- two values still returns two, and a caller cannot read the third slot as
			-- "always present".
			local harness, _, _, _, clientData = makeLoopback()
			harness.Data.Command("TwoValues", function()
				return false, "denied"
			end)

			local unknownN, unknownValues = capture(clientData.Request("NoSuchCommandHere"))
			local handlerN, handlerValues = capture(clientData.Request("TwoValues"))

			harness.Transport.AutoPump = false -- swallow the command frame
			local timeoutN, timeoutValues = capture(clientData.Request("TwoValues"))
			harness.Transport.AutoPump = true

			local summary = table.concat({
				`unknown {render(unknownN, unknownValues)} marked={unknownValues[3] == Scribe.RequestFailed}`,
				`handler {render(handlerN, handlerValues)} marked={handlerValues[3] == Scribe.RequestFailed}`,
				`timeout {render(timeoutN, timeoutValues)} marked={timeoutValues[3] == Scribe.RequestFailed}`,
			}, "\n")
			harness.Cleanup()
			expect(summary).to.equal(table.concat({
				"unknown n=3 [false,unknown-command,table] marked=true",
				"handler n=2 [false,denied] marked=false",
				"timeout n=3 [false,timeout,table] marked=true",
			}, "\n"))
		end)
	end)
end
