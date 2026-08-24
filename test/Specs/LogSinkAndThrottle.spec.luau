--!nonstrict
-- Two small things that were asymmetric with their own siblings.
--
-- Log.AddSink could only ever ADD, with no way to detach a sink. The missing
-- remover matters more here than it sounds: every entry Sched.Spawns once PER SINK,
-- and Log.Warn is the most expensive call in the observability stack, so a sink
-- registered again on each of several bundles multiplies thread spawns on the
-- hottest failure path with no way to undo it.
--
-- COMMAND_ERROR was the one client-drivable log in Commands.luau that was not
-- throttled. A handler that throws on a given input is a bug a player can replay at
-- their full command rate, and each entry costs a JSONEncode, a console write, and a
-- spawn per sink.
--
-- The `throttled warnings` block below is the second half of that, and it was added
-- because this file's NAME was the only thing in the repo asserting any of it. Two
-- guarantees are published --
--
--   log-codes.md:149  "The clock is per code, so COMMAND_UNKNOWN and
--                      COMMAND_BAD_ARGS do not throttle each other."
--   security.md:34    "throttled to once per second per player, on its own clock"
--
-- -- and until these specs existed, NEITHER was held by anything. Both were measured
-- breakable with a fully green suite: collapsing the per-code map to one per-entry
-- timestamp silently dropped 2 of 18 warnings the suite drives, and collapsing the
-- per-player key to one process-wide clock dropped 9 of 18. A documented promise
-- with nothing behind it is the shape this project keeps rediscovering.
return function()
	local Root = script.Parent.Parent.Parent
	local Log = require(Root.Scribe.Internal.Log)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	describe("Log.AddSink", function()
		it("returns a remover that actually stops delivery", function()
			local seen = 0
			local remove = Log.AddSink(function()
				seen += 1
			end)
			expect(type(remove)).to.equal("function")

			Log.Warn("Persistence", "PROFILE_SAVE_FAIL", "one")
			task.wait() -- sinks are spawned, not called inline
			local afterFirst = seen
			expect(afterFirst > 0).to.equal(true)

			remove()
			Log.Warn("Persistence", "PROFILE_SAVE_FAIL", "two")
			task.wait()
			expect(seen).to.equal(afterFirst)
		end)

		it("is idempotent, so a double remove cannot evict somebody else's sink", function()
			-- The failure this guards is specific: a remover that stored an INDEX
			-- rather than searching would, on a second call, remove whatever had since
			-- taken that slot -- silently unsubscribing an unrelated sink.
			local mineSeen, otherSeen = 0, 0
			local removeMine = Log.AddSink(function()
				mineSeen += 1
			end)
			removeMine()
			removeMine() -- second call must do nothing at all

			local removeOther = Log.AddSink(function()
				otherSeen += 1
			end)
			Log.Warn("Persistence", "PROFILE_SAVE_FAIL", "three")
			task.wait()

			expect(mineSeen).to.equal(0)
			expect(otherSeen > 0).to.equal(true)
			removeOther()
		end)
	end)

	describe("Scribe.AddLogSink", function()
		-- Log.AddSink's remover is only worth having if a GAME can reach it, and
		-- Scribe.AddLogSink is the only public door to the sink list: there is no
		-- Log.ClearSinks and nothing else removes one. The wrapper used to call
		-- through and drop the closure on the floor, which is a leak with teeth --
		-- `sinks` is a process singleton and every entry Sched.Spawns once per sink,
		-- so a bundle that re-registers on each hot reload pays forever.
		--
		-- The two tests above hold the mechanism; this one holds the wiring, and the
		-- wiring is the half that was missing.
		local Scribe = require(Root.Scribe)

		it("hands the remover back to the caller, so a game can actually detach", function()
			local seen = 0
			local remove = Scribe.AddLogSink(function()
				seen += 1
			end)
			expect(type(remove)).to.equal("function")

			Log.Warn("Persistence", "PROFILE_SAVE_FAIL", "public-one")
			task.wait()
			local afterFirst = seen
			expect(afterFirst > 0).to.equal(true)

			remove()
			Log.Warn("Persistence", "PROFILE_SAVE_FAIL", "public-two")
			task.wait()
			expect(seen).to.equal(afterFirst)
		end)
	end)
	describe("throttled warnings", function()
		-- Frames are hand-built and handed to HandleFrame directly, the same idiom
		-- CommandIdempotency.spec uses: the mechanism under test is the server's, and
		-- the throttle clock is keyed on the ENTRY, which is what a real client send
		-- would only reach indirectly.
		local function send(harness, entry, correlation: number, name: string, ...)
			local args = table.pack(...)
			local w = Wire.NewWriter(64)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, correlation)
			Wire.Str(w, name)
			Wire.U8(w, args.n)
			Wire.Str(w, "")
			for i = 1, args.n do
				Wire.EncodeGeneric(w, args[i])
			end
			local reader = Wire.NewReader(Wire.Finish(w))
			Wire.RU8(reader) -- frame type, consumed by the real dispatcher
			harness.Ctx.Commands.HandleFrame(entry, reader)
		end

		-- The log ring is a PROCESS singleton, so absolute counts carry whatever
		-- earlier specs left in it. Count the delta across the window instead.
		local function counter(code: string)
			local before = #Log.GetRecent({ Code = code })
			return function()
				return #Log.GetRecent({ Code = code }) - before
			end
		end

		it("does not let one code throttle a DIFFERENT code on the same player", function()
			-- log-codes.md:149 states this in as many words. The throttle is keyed on
			-- (entry, code) -- a per-entry MAP from code to timestamp, not one timestamp
			-- per entry. Collapse it to the latter and the second code here is swallowed
			-- because the first one fired, inside the same one-second window.
			local harness = TestCtx.make({})
			local _player, entry = harness.Join(97301)
			harness.Data.Command("Known", { Args = { "string" } }, function()
				return true
			end)

			local unknown = counter("COMMAND_UNKNOWN")
			local badArgs = counter("COMMAND_BAD_ARGS")

			send(harness, entry, 1, "NoSuchCommand")
			send(harness, entry, 2, "Known", 12345) -- declared "string"

			expect(`unknown={unknown()} badArgs={badArgs()}`).to.equal("unknown=1 badArgs=1")
			harness.Cleanup()
		end)

		it("does not let one PLAYER throttle another, on the same code", function()
			-- security.md:34 promises "once per second per player". The subject is the
			-- entry, so two players hold two clocks; a single process-wide clock would
			-- let one player's flood silence the diagnostics of everyone else on the
			-- server -- which is the opposite of what a per-player throttle is for.
			local harness = TestCtx.make({})
			local _a, entryA = harness.Join(97302)
			local _b, entryB = harness.Join(97303)

			local unknown = counter("COMMAND_UNKNOWN")
			send(harness, entryA, 1, "NoSuchCommand")
			send(harness, entryB, 1, "NoSuchCommand")

			expect(`emitted={unknown()}`).to.equal("emitted=2")
			harness.Cleanup()
		end)

		it("suppresses a repeat of the SAME code on the same player within the window", function()
			-- The positive half, and the reason the throttle exists at all: these fire on
			-- client-controlled input that sits UNDER the rate limit, so an exploiter can
			-- drive them at the full allowance and evict the whole diagnostic ring,
			-- erasing the evidence of everything else. Nothing asserted that any log was
			-- ever throttled before this.
			local harness = TestCtx.make({})
			local _player, entry = harness.Join(97304)

			local unknown = counter("COMMAND_UNKNOWN")
			for correlation = 1, 5 do
				send(harness, entry, correlation, "NoSuchCommand")
			end

			expect(`emitted={unknown()}`).to.equal("emitted=1")
			harness.Cleanup()
		end)
	end)
end
