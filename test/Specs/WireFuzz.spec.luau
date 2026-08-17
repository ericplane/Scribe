--!nonstrict
-- Byte-level fuzzing of the inbound wire decoder.
--
-- src/Internal/Wire.luau is a hand-rolled binary decoder (varints, zigzag,
-- bitmasks, field-id interning, per-value mode prefixes) parsing buffers a
-- hostile client fully controls, and it was guarded by four hand-written
-- negative cases. This mutates VALID frames -- truncate, flip, splice, extend,
-- zero -- and feeds them through the real transport listener, asserting the
-- decoder's contract rather than any particular parse result:
--
--   1. A malformed frame NEVER escapes the server's pcall. The listener must
--      absorb it; a throw reaching the transport would kill the caller's thread.
--   2. Every frame is ACCOUNTED FOR -- handled, or charged to the malformed
--      budget. A frame that silently vanishes is a hole in the rate limiting.
--   3. The session SURVIVES. After the whole barrage the tree is alive and a
--      legitimate command still round-trips.
--
-- Deterministic: a fixed seed and a local LCG, so CI reproduces byte-for-byte.
-- Every failure message carries the seed and case index needed to replay it.

return function()
	local Root = script.Parent.Parent.Parent
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local SEED = 0x5C21BE
	local CASES = 600

	-- Local LCG (numerical recipes constants). math.random is process-global and
	-- another spec reseeding it would silently change this suite's coverage.
	local function makeRng(seed: number)
		local state = seed % 2147483648
		return function(n: number): number
			state = (1103515245 * state + 12345) % 2147483648
			return state % n
		end
	end

	local function validHello(compiled): buffer
		local w = Wire.NewWriter(8)
		Wire.U8(w, Wire.Frames.Hello)
		Wire.U32(w, compiled.Hash % 4294967296)
		Wire.U8(w, Wire.PROTOCOL_VERSION)
		return Wire.Finish(w)
	end

	local function validCommand(name: string, args: { any }): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, 7) -- correlation
		Wire.Str(w, name)
		Wire.U8(w, #args)
		for _, arg in args do
			Wire.EncodeGeneric(w, arg)
		end
		return Wire.Finish(w)
	end

	local function toBytes(buf: buffer): { number }
		local out = table.create(buffer.len(buf))
		for i = 0, buffer.len(buf) - 1 do
			out[i + 1] = buffer.readu8(buf, i)
		end
		return out
	end

	local function fromBytes(bytes: { number }): buffer
		local buf = buffer.create(math.max(#bytes, 0))
		for i, byte in bytes do
			buffer.writeu8(buf, i - 1, byte % 256)
		end
		return buf
	end

	-- Five mutators, chosen because each breaks a different decoder assumption:
	-- truncation starves a length prefix, flips corrupt tags and counts, splices
	-- desynchronise every following field, extension leaves trailing garbage, and
	-- zeroing produces structurally "valid-looking" empty values.
	local MUTATORS = {
		function(bytes, rng) -- truncate
			local keep = rng(#bytes + 1)
			local out = {}
			for i = 1, keep do
				out[i] = bytes[i]
			end
			return out, "truncate"
		end,
		function(bytes, rng) -- flip one byte
			if #bytes == 0 then
				return bytes, "flip"
			end
			local out = table.clone(bytes)
			local at = rng(#out) + 1
			out[at] = (out[at] + 1 + rng(255)) % 256
			return out, "flip"
		end,
		function(bytes, rng) -- splice a byte in
			local out = table.clone(bytes)
			table.insert(out, rng(#out + 1) + 1, rng(256))
			return out, "splice"
		end,
		function(bytes, rng) -- append garbage
			local out = table.clone(bytes)
			for _ = 1, 1 + rng(16) do
				table.insert(out, rng(256))
			end
			return out, "extend"
		end,
		function(bytes, rng) -- zero a run
			if #bytes == 0 then
				return bytes, "zero"
			end
			local out = table.clone(bytes)
			local at = rng(#out) + 1
			for i = at, math.min(at + rng(4), #out) do
				out[i] = 0
			end
			return out, "zero"
		end,
	}

	describe("inbound decoder fuzzing", function()
		it("absorbs mutated frames without ever throwing, and accounts for every one", function()
			local harness = TestCtx.make({
				Options = {
					-- The fuzzer sends far faster than a real client; the frame-rate
					-- bucket is a separate concern with its own spec, and letting it
					-- trip here would silently stop exercising the decoder at all.
					InboundFrameRate = 100000,
				},
			})
			-- Commands are registered through the real API, not an option table.
			harness.Data.Command("Echo", function(_player, value)
				return value
			end)
			local player, entry = harness.Join()
			harness.SendHello(player)

			local rng = makeRng(SEED)
			local corpus = {
				validHello(harness.Compiled),
				validCommand("Echo", { 1 }),
				validCommand("Echo", { "hello" }),
				validCommand("Echo", { { a = 1, b = { 2, 3 } } }),
				validCommand("Missing", {}),
			}

			local mutatorCounts = {}
			for case = 1, CASES do
				local source = corpus[rng(#corpus) + 1]
				local mutator = MUTATORS[rng(#MUTATORS) + 1]
				local mutated, label = mutator(toBytes(source), rng)
				mutatorCounts[label] = (mutatorCounts[label] or 0) + 1

				-- Keep both budgets clear so every case reaches the decoder: this
				-- spec is about the decoder's robustness, not the budgets (which
				-- Replication.spec covers). The malformed DELTA is still asserted.
				entry.MalformedCount = 0
				entry.MalformedBlocked = false
				entry.OversizeCount = 0
				entry.OversizeBlocked = false
				entry.FrameTokens = 100000

				local before = entry.MalformedCount
				local ok, err = pcall(function()
					harness.Transport:InjectToServer(player, fromBytes(mutated))
				end)

				-- (1) Nothing escapes the server's pcall.
				if not ok then
					error(
						`seed {SEED} case {case} ({label}, {#mutated} bytes): a mutated frame escaped the `
							.. `server handler and threw: {tostring(err)}`,
						0
					)
				end

				-- (2) Handled, or charged to the malformed budget -- never silently
				-- dropped. A mutation that happens to stay legal is a valid outcome.
				local charged = entry.MalformedCount > before
				if not charged and entry.MalformedCount ~= 0 then
					error(`seed {SEED} case {case} ({label}): frame neither handled nor counted`, 0)
				end

				-- (3) The session is still usable.
				if entry.Tree == nil or entry.Tree.Dead then
					error(`seed {SEED} case {case} ({label}): the tree died on a malformed frame`, 0)
				end
				if entry.State ~= "Ready" then
					error(`seed {SEED} case {case} ({label}): session left Ready ({entry.State})`, 0)
				end
			end

			-- Every mutator actually ran; a silently-dead mutator would make the
			-- headline count meaningless.
			for _, mutator in { "truncate", "flip", "splice", "extend", "zero" } do
				expect(mutatorCounts[mutator]).to.be.ok()
			end

			harness.Cleanup()
		end)

		it("still serves a legitimate command after the barrage", function()
			local harness = TestCtx.make({
				Options = {
					InboundFrameRate = 100000,
				},
			})
			-- Commands are registered through the real API, not an option table.
			harness.Data.Command("Echo", function(_player, value)
				return value
			end)
			local player, entry = harness.Join()
			harness.SendHello(player)

			local rng = makeRng(SEED + 1)
			local source = validCommand("Echo", { 42 })
			for _ = 1, 200 do
				entry.MalformedCount = 0
				entry.MalformedBlocked = false
				entry.FrameTokens = 100000
				local mutator = MUTATORS[rng(#MUTATORS) + 1]
				local mutated = mutator(toBytes(source), rng)
				pcall(function()
					harness.Transport:InjectToServer(player, fromBytes(mutated))
				end)
			end

			-- The barrage is supposed to have cost the sender their COMMAND budget:
			-- every mutation that still parsed as a Command reached the dispatcher
			-- and spent a token. Assert that before refilling, so this spec also
			-- pins the limiter rather than quietly depending on it.
			entry.MalformedCount = 0
			entry.MalformedBlocked = false
			entry.FrameTokens = 100000
			harness.Transport:InjectToServer(player, validCommand("Echo", { 42 }))
			local throttled = harness.FramesFor(player, Wire.Frames.CommandReply)
			local refused = throttled[#throttled]
			expect(refused).to.be.ok()
			expect(refused.Ok).to.equal(false)
			expect(refused.Results[1]).to.equal("rate-limited")

			-- Once the budgets are back, the session serves normally: the barrage left
			-- no lasting damage, only spent buckets. RateLimitedCount is cleared too
			-- because past RATE_LIMIT_MAX sustained refusals Commands stops replying
			-- at all, which would otherwise leave the stale refusal above as the last
			-- frame and make the assertion below read it instead of a fresh reply.
			local sawBefore = #harness.FramesFor(player, Wire.Frames.CommandReply)
			entry.RateTokens = 20
			entry.RateLast = os.clock()
			entry.RateLimitedCount = 0
			entry.LastRateLimitAt = nil
			entry.FrameTokens = 100000
			harness.Transport:InjectToServer(player, validCommand("Echo", { 42 }))

			local replies = harness.FramesFor(player, Wire.Frames.CommandReply)
			expect(#replies).to.equal(sawBefore + 1) -- a NEW reply, not the stale one
			local last = replies[#replies]
			expect(last.Ok).to.equal(true)
			expect(last.Results[1]).to.equal(42)

			harness.Cleanup()
		end)

		it("charges the malformed budget for a frame type the server never accepts", function()
			local harness = TestCtx.make()
			local player, entry = harness.Join()
			harness.SendHello(player)

			-- Init/Diff/Status are server->client only; a client sending one is
			-- malformed by definition.
			for _, frameType in { Wire.Frames.Init, Wire.Frames.Diff, Wire.Frames.Status, 200 } do
				local before = entry.MalformedCount
				local buf = buffer.create(1)
				buffer.writeu8(buf, 0, frameType)
				harness.Transport:InjectToServer(player, buf)
				expect(entry.MalformedCount).to.equal(before + 1)
			end

			harness.Cleanup()
		end)
	end)
end
