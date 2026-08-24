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
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- Every way the listener may legitimately refuse a frame, summed.
	---
	--- Enumerated rather than inferred: the contract is that nothing vanishes, so
	--- the check has to know the complete set of exits. Two of these (protocol and
	--- schema mismatch) had no counter until this spec went looking for one.
	local function refusals(): number
		local m = Scribe.GetMetrics()
		return (m.MalformedFrames or 0)
			+ (m.InboundOversize or 0)
			+ (m.InboundWorkLimited or 0)
			+ (m.InboundRateLimited or 0)
			+ (m.ProtocolMismatch or 0)
			+ (m.SchemaMismatch or 0)
			+ (m.ReInitThrottled or 0)
	end

	local SEED = 0x5C21BE
	local CASES = 600

	-- xorshift32 over bit32, not an LCG. math.random is process-global and another
	-- spec reseeding it would silently change this suite's coverage -- but the LCG
	-- that replaced it had its own problem: `1103515245 * state` exceeds the f64
	-- mantissa for most states, so the low bits it then takes modulo are rounding
	-- noise rather than the sequence. Measured, three of the five mutators were
	-- near-degenerate as a result. bit32 keeps every operation exact in 32 bits.
	local function makeRng(seed: number)
		local state = bit32.bxor(seed, 0x9E3779B9)
		if state == 0 then
			state = 1
		end
		return function(n: number): number
			state = bit32.bxor(state, bit32.lshift(state, 13))
			state = bit32.bxor(state, bit32.rshift(state, 17))
			state = bit32.bxor(state, bit32.lshift(state, 5))
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
		Wire.Str(w, "") -- no idempotency key
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
				-- The COMMAND bucket, which the first version of this spec left alone
				-- and which turned out to be what the fuzzer was really testing.
				-- src/Server/Commands.luau:521 takes a token BEFORE decoding arguments
				-- -- correctly, since arguments are attacker-sized -- so an unrefilled
				-- bucket rejects almost everything on the fixed-cost header and the
				-- decoder is never reached. Measured: 355 of 600 cases (59.2%) died
				-- here, and reach into the argument decoder was 2.8-3.3%. Refilling it
				-- takes reach to ~47% AND makes the run deterministic, because the
				-- surviving cases no longer depend on how many earlier ones happened to
				-- spend a token.
				entry.RateTokens = 100000
				entry.RateLimitedCount = 0

				local before = entry.MalformedCount
				local refusedBefore = refusals()
				local outBefore = #harness.FramesFor(player)
				local tokensBefore = entry.RateTokens
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

				-- (2) Handled, or refused and counted -- never silently dropped. A
				-- mutation that happens to stay legal is a valid outcome.
				--
				-- This assertion used to be unreachable, and the way it failed is
				-- worth keeping. `before` was read immediately after the line that
				-- zeroes MalformedCount, so it was always 0; the guard then read
				-- `not charged and MalformedCount ~= 0`, and `not charged` already
				-- meant MalformedCount == 0. The branch could never be taken, so the
				-- fuzzer's headline contract -- nothing is silently dropped -- was
				-- asserting nothing at all, and a decoder change that started
				-- dropping frames would have sailed through 600 cases.
				--
				-- Every way the listener may legitimately dispose of a frame is
				-- enumerated instead: one of the three refusal budgets moved, or the
				-- frame was actually served (an outbound frame, or a command token
				-- spent). Silence on all five is the failure.
				local accounted = entry.MalformedCount > before
					or refusals() > refusedBefore
					or #harness.FramesFor(player) > outBefore
					or entry.RateTokens ~= tokensBefore
				if not accounted then
					error(`seed {SEED} case {case} ({label}, {#mutated} bytes): frame neither handled nor counted`, 0)
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

		it("reaches the argument decoder on every case, and exercises all of its outcomes", function()
			-- THE test the file's headline claim needs, and the one it did not have.
			--
			-- The broad fuzzer above mutates a whole frame, so the mutation usually lands
			-- in the header and the frame dies at a check long before the argument
			-- decoder -- the untrusted-input boundary this file exists for. Measured on
			-- the version before this one: 17-20 of 600 cases (2.8-3.3%) reached the
			-- decode loop and 5-6 (under 1%) made it throw. It read as coverage of a
			-- surface it barely touched.
			--
			-- So this one is STRUCTURE-AWARE: the header is built by the real encoder and
			-- left intact, and only the argument region is mutated. Every case therefore
			-- reaches the decoder by construction -- which is what makes the coverage
			-- assertion at the bottom exact rather than a guess, and what makes it
			-- impossible for reach to fall back to 3% without this test going red.
			--
			-- The header length is READ from the encoder rather than written down as 12.
			-- A hardcoded offset would keep passing after a wire-format change while
			-- quietly mutating the header again.
			local harness = TestCtx.make({ Options = { InboundFrameRate = 100000 } })
			local handled = 0
			harness.Data.Command("Echo", function(_player, value)
				handled += 1
				return value
			end)
			local player, entry = harness.Join()
			harness.SendHello(player)

			local function commandHeader(name: string, argc: number): buffer
				local w = Wire.NewWriter(32)
				Wire.U8(w, Wire.Frames.Command)
				Wire.U32(w, 7) -- correlation
				Wire.Str(w, name)
				Wire.U8(w, argc)
				Wire.Str(w, "") -- no idempotency key
				return Wire.Finish(w)
			end

			local function argBytes(value: any): buffer
				local w = Wire.NewWriter(64)
				Wire.EncodeGeneric(w, value)
				return Wire.Finish(w)
			end

			local header = toBytes(commandHeader("Echo", 1))
			-- Seeds chosen to span the grammar the decoder actually walks: a scalar, a
			-- string with a length prefix, a nested table with array and hash counts, an
			-- array of mixed types, and a buffer. Those prefixes and counts are where the
			-- interesting failures live -- a corrupted count is what turns a small frame
			-- into a large allocation.
			local seeds = {
				argBytes(1.5),
				argBytes("a longer string with length prefix"),
				argBytes({ a = 1, b = { 2, 3, 4 }, c = "x" }),
				argBytes({ true, 2, "three", { 4 } }),
				argBytes(buffer.fromstring("bytes")),
			}

			local rng = makeRng(SEED + 2)
			local threw, decoded = 0, 0
			local mutatorCounts = {}

			for case = 1, CASES do
				local mutator = MUTATORS[rng(#MUTATORS) + 1]
				local mutatedArgs, label = mutator(toBytes(seeds[rng(#seeds) + 1]), rng)
				mutatorCounts[label] = (mutatorCounts[label] or 0) + 1

				local bytes = table.clone(header)
				for _, byte in mutatedArgs do
					table.insert(bytes, byte)
				end

				entry.MalformedCount = 0
				entry.MalformedBlocked = false
				entry.OversizeCount = 0
				entry.OversizeBlocked = false
				entry.FrameTokens = 100000
				entry.RateTokens = 100000
				entry.RateLimitedCount = 0

				local handledBefore = handled
				local ok, err = pcall(function()
					harness.Transport:InjectToServer(player, fromBytes(bytes))
				end)
				if not ok then
					error(
						`seed {SEED + 2} case {case} ({label}, {#mutatedArgs} arg bytes): escaped the server `
							.. `handler and threw: {tostring(err)}`,
						0
					)
				end

				-- The header is intact and the budgets are full, so the ONLY thing that can
				-- have consumed this frame is the argument decoder: either it completed and
				-- the handler ran, or it raised and the frame was charged as malformed.
				-- Anything else means a check moved in front of the decode and this test
				-- has silently stopped measuring what it claims.
				if handled > handledBefore then
					decoded += 1
				elseif entry.MalformedCount > 0 then
					threw += 1
				else
					error(
						`seed {SEED + 2} case {case} ({label}): a well-headed Command frame reached `
							.. `neither the decoder nor the malformed budget -- something now rejects it earlier`,
						0
					)
				end

				if entry.State ~= "Ready" then
					error(`seed {SEED + 2} case {case} ({label}): session left Ready ({entry.State})`, 0)
				end
			end

			-- THE COVERAGE ASSERTION. Every case reached the decoder, and both outcomes
			-- happened -- so neither a decoder that accepts everything nor one that
			-- rejects everything can pass, and reach cannot regress silently.
			expect(decoded + threw).to.equal(CASES)
			expect(threw > 0).to.equal(true)
			expect(decoded > 0).to.equal(true)
			-- Both outcomes are a real share of the run, not one stray case. Loose bounds
			-- on purpose: the exact split is a property of the seed, and pinning it would
			-- make this fail on an unrelated wire change rather than on a real one.
			expect(threw > CASES // 20).to.equal(true)
			expect(decoded > CASES // 20).to.equal(true)
			for _, mutator in { "truncate", "flip", "splice", "extend", "zero" } do
				expect(mutatorCounts[mutator]).to.be.ok()
			end

			harness.Cleanup()
		end)

		it("fuzzes the SCHEMA-TYPED decoder, including the dense and bitmask paths", function()
			-- THE PATH THE THREE TESTS ABOVE CANNOT REACH, and the reason this exists.
			--
			-- Everything above goes through the server's listener, and the server
			-- accepts exactly two frame types: Hello, and Command whose arguments take
			-- the GENERIC codec. The schema-typed value decoder -- field-id interning,
			-- bounds-packed ints, key tags, and as of protocol 4 the folded value
			-- header and the dense-array fast path -- runs on the CLIENT, over Init and
			-- Diff frames. Not one byte of it was fuzzed, and a codec that grows a new
			-- encoding while its fuzzer keeps hitting the old one silently narrows its
			-- own coverage. So this one drives Wire.DecodeOps directly, which is what
			-- the client's frame handler calls.
			--
			-- Structure-aware for the same reason the argument fuzzer is: the frame
			-- type and op header are left intact and only the op region is mutated, so
			-- every case reaches the value decoder by construction.
			--
			-- `Gear` and its seeds were added for protocol 5's presence bitmask. A
			-- fuzzer that only reaches the encodings it was written against narrows its
			-- own coverage every time the codec grows one, and the bitmask brought a
			-- new width field, a new mask region and a new set of refusals with it --
			-- none of which any seed above could produce, because every shape that
			-- existed here was an array or a dynamic-key dict.
			--
			-- `Speed`, `Ratio`, `Positions` and `Meters` were added for protocol 6's
			-- NARROWED FLOATS, for the same reason and with a sharper edge. Narrowing
			-- changes how many bytes a scalar occupies, so a mutation inside a narrowed
			-- value's payload is a mutation the decoder must absorb at a width no seed
			-- here could previously produce -- every float in this template was eight
			-- bytes, and four of the five widths the codec now reads had no seed at
			-- all. A one-byte grid index is the sharpest of them: at that width a
			-- single flipped byte moves the frame's whole remaining alignment if the
			-- decoder ever disagrees about the width, which is precisely the failure
			-- the coverage precondition below is there to keep reachable.
			local Template = require(Root.Scribe.Internal.Template)
			local template = {
				Ints = Scribe.ArrayOf(Scribe.Int(0, { Min = 0 })),
				Records = Scribe.ArrayOf({
					Id = Scribe.String("", { MaxLength = 32 }),
					Count = Scribe.Int(1, { Min = 0, Max = 1000 }),
				}),
				Bag = Scribe.DictOf(Scribe.Int(0, { Min = 0 })),
				Loose = {},
				Level = Scribe.Int(1, { Min = 1, Max = 200 }),
				-- Nine declared children: wide enough that the bitmask beats the
				-- ordinals, so a full or mostly-full Gear takes the static path, and
				-- narrow enough that a two-field one does not.
				-- Narrowed floats: one of every width the codec reads, standalone and
				-- as dense elements.
				Speed = Scribe.Number(0, { Precision = "f32" }),
				Ratio = Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 }),
				Positions = Scribe.ArrayOf(Scribe.Number(0, { Min = -1024, Max = 1024, Precision = "f32" })),
				Meters = Scribe.ArrayOf(Scribe.Number(0, { Min = 0, Max = 1, Precision = 0.01 })),
				Gear = {
					Amulet = Scribe.Int(0, { Min = 0, Max = 255 }),
					Belt = Scribe.Int(0, { Min = 0, Max = 255 }),
					Body = Scribe.Int(0, { Min = 0, Max = 255 }),
					Boots = Scribe.Int(0, { Min = 0, Max = 255 }),
					Cape = Scribe.Int(0, { Min = 0, Max = 255 }),
					Gloves = Scribe.Int(0, { Min = 0, Max = 255 }),
					Head = Scribe.Int(0, { Min = 0, Max = 255 }),
					Legs = Scribe.Int(0, { Min = 0, Max = 255 }),
					Ring = Scribe.Int(0, { Min = 0, Max = 255 }),
				},
			}
			local compiled = Template.Compile(template, {})

			local function encodedValue(path: { any }, value: any): buffer
				local node, dynStart = Template.Resolve(compiled, path)
				for i = dynStart, #path do
					node = Template.ChildSchema(node, path[i])
				end
				local w = Wire.NewWriter(32)
				Wire.EncodeValue(w, node, value)
				return Wire.Finish(w)
			end

			local function valueHeader(path: { any }, value: any): number
				return buffer.readu8(encodedValue(path, value), 0)
			end

			--- Total encoded bytes, which is how a NARROWED scalar is identified: the
			--- value header carries the mode, not the width, so the width is only
			--- visible in the length. 9 is f64, 5 is f32, 2 is a one-byte grid index,
			--- and 10 is the generic fallback.
			local function valueBytes(path: { any }, value: any): number
				return buffer.len(encodedValue(path, value))
			end

			local ints = {}
			for i = 1, 40 do
				ints[i] = i * 37
			end
			local records = {}
			for i = 1, 12 do
				records[i] = { Id = `item_{i}`, Count = i }
			end
			-- f32 elements: 5 bytes each, so a mutation lands mid-mantissa as often
			-- as it lands on a header.
			local positions = {}
			for i = 1, 16 do
				positions[i] = (i - 8) * 63.7
			end
			-- One-byte grid indices: the narrowest element the codec can produce, and
			-- the width where a mutated byte is most likely to still decode -- to a
			-- DIFFERENT number, which is the outcome worth exercising.
			local meters = {}
			for i = 1, 24 do
				meters[i] = (i % 101) / 100
			end

			local fullGear =
				{ Amulet = 1, Belt = 2, Body = 3, Boots = 4, Cape = 5, Gloves = 6, Head = 7, Legs = 8, Ring = 9 }
			local partGear = { Body = 3, Boots = 4, Head = 7, Legs = 8, Ring = 9 }
			local badValueGear = { Belt = 2, Cape = 5, Head = "not-an-int", Legs = 8, Ring = 9 }
			-- The undeclared key is bolted on afterwards rather than written into the
			-- literal so selene's mixed-key lints stay on for the rest of the repo.
			local strayGear = { Amulet = 1, Belt = 2, Body = 3, Boots = 4, Cape = 5, Gloves = 6, Head = 7, Legs = 8 }
			strayGear.Ring = 9
			strayGear.Trinket = "undeclared"

			local SEEDS = {
				-- Dense, schema-typed elements.
				{ Kind = "Set", Path = { "Ints" }, Value = ints },
				-- Dense outside, bitmask records inside (two declared children each, so
				-- the mask beats the ordinals by a byte).
				{ Kind = "Set", Path = { "Records" }, Value = records },
				-- Tagged, dynamic string keys.
				{ Kind = "Set", Path = { "Bag" }, Value = { alpha = 1, beta = 2, gamma = 3 } },
				-- Sparse: the fallback, so a mutation can flip a frame between paths.
				{ Kind = "Set", Path = { "Loose" }, Value = { [1] = 1, [4] = 4, tail = "x" } },
				-- A dense array holding an element the schema cannot describe, so the
				-- mode bit inside a dense parent is on the fuzzed surface too.
				{ Kind = "Set", Path = { "Ints" }, Value = { 1, "not-an-int", 3 } },
				-- Nested dense inside dense.
				{ Kind = "Set", Path = { "Loose" }, Value = { { 1, 2 }, { 3, 4, 5 } } },
				-- STATIC: a full mask, and a half-full one whose absent children leave
				-- gaps the decoder has to skip rather than read.
				{ Kind = "Set", Path = { "Gear" }, Value = fullGear },
				{ Kind = "Set", Path = { "Gear" }, Value = partGear },
				-- A declared child whose VALUE the schema cannot describe: still static,
				-- with that one field degraded to generic inside the mask.
				{ Kind = "Set", Path = { "Gear" }, Value = badValueGear },
				-- THE BITMASK'S FALLBACK: one undeclared KEY, so the whole table drops
				-- to the tagged path. Same node and nearly the same bytes as the seeds
				-- above it, which is what lets a mutation carry a frame across the
				-- boundary between the two encodings.
				{ Kind = "Set", Path = { "Gear" }, Value = strayGear },
				-- Non-table values, so the standalone header range is covered too.
				{ Kind = "Set", Path = { "Level" }, Value = 137 },
				{ Kind = "Insert", Path = { "Ints" }, Value = 9, Index = 2 },
				-- NARROWED FLOATS. A standalone f32 and a standalone one-byte grid
				-- index, then both widths as dense elements.
				{ Kind = "Set", Path = { "Speed" }, Value = 12.375 },
				{ Kind = "Set", Path = { "Ratio" }, Value = 0.42 },
				{ Kind = "Set", Path = { "Positions" }, Value = positions },
				{ Kind = "Set", Path = { "Meters" }, Value = meters },
				-- THE NARROWING'S OWN FALLBACK, seeded so a mutation can carry a frame
				-- across the boundary between the two: same node, same array, one
				-- element that the grid cannot hold and that therefore travels as a
				-- generic f64 in the middle of a run of one-byte indices.
				{ Kind = "Set", Path = { "Meters" }, Value = { 0.5, math.huge, 0.25 } },
				{ Kind = "Set", Path = { "Speed" }, Value = 1e39 },
				{ Kind = "Insert", Path = { "Meters" }, Value = 0.75, Index = 1 },
			}

			-- THE COVERAGE PRECONDITION. Without this the whole test could be fuzzing
			-- the tagged path only, and would keep passing while saying "dense" and
			-- "bitmask" in its name. Asserted on the seeds, before any mutation, and
			-- counted PER MODE rather than as one "not tagged" bucket -- the version of
			-- this check that read `% 4 >= 2` would have been satisfied by static seeds
			-- alone the moment static took the header's fourth value, and would have
			-- gone on claiming dense coverage it no longer had.
			local seedsByMode = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
			for _, op in SEEDS do
				if type(op.Value) == "table" then
					local mode = valueHeader(op.Path, op.Value) % 4
					seedsByMode[mode] += 1
				end
			end
			expect(seedsByMode[2] >= 4).to.equal(true) -- dense
			expect(seedsByMode[3] >= 3).to.equal(true) -- static, the bitmask
			expect(seedsByMode[0] >= 2).to.equal(true) -- tagged, its fallback

			-- THE SAME PRECONDITION FOR THE NARROWED WIDTHS, and it needs its own
			-- check because the value header does NOT record the width -- a float's
			-- width comes from the schema, so every seed below carries mode 0 and
			-- seedsByMode cannot tell an f32 from an f64. Without these lines the
			-- narrowed seeds could all have silently fallen back to f64 and this test
			-- would go on claiming coverage it did not have.
			expect(valueBytes({ "Speed" }, 12.375)).to.equal(5) -- 1 header + f32
			expect(valueBytes({ "Ratio" }, 0.42)).to.equal(2) -- 1 header + u8 index
			expect(valueBytes({ "Meters", 1 }, 0.75)).to.equal(2) -- narrowed ELEMENT
			expect(valueBytes({ "Positions", 1 }, 63.7)).to.equal(5)
			-- And the fallback really does fall back, so both sides of the boundary a
			-- mutation can cross are actually seeded.
			expect(valueBytes({ "Speed" }, 1e39)).to.equal(10) -- 1 header + tag + f64
			expect(valueBytes({ "Meters", 1 }, math.huge)).to.equal(10)
			-- The control: an undeclared float is still eight bytes wide, so a
			-- narrowing that leaked onto every Number would fail here.
			expect(valueBytes({ "Loose" }, 1.5)).to.equal(10)

			local KINDS = { Set = true, Insert = true, Remove = true, Clear = true }
			local rng = makeRng(SEED + 3)
			local threw, decoded, budgetRefused = 0, 0, 0
			local mutatorCounts = {}

			for case = 1, CASES do
				local op = SEEDS[rng(#SEEDS) + 1]
				local frame = Wire.EncodeOpsFrame(Wire.Frames.Diff, compiled, { op })
				local bytes = toBytes(frame)
				-- Leave the frame-type byte and the u16 op count alone; mutate the op.
				local head = { bytes[1], bytes[2], bytes[3] }
				local tail = {}
				for i = 4, #bytes do
					table.insert(tail, bytes[i])
				end
				local mutator = MUTATORS[rng(#MUTATORS) + 1]
				local mutatedTail, label = mutator(tail, rng)
				mutatorCounts[label] = (mutatorCounts[label] or 0) + 1
				for _, byte in mutatedTail do
					table.insert(head, byte)
				end

				-- A budget, so the retention charges on this path -- including the new
				-- per-slot charge the dense decoder levies -- are actually exercised.
				-- The client passes nil in production; that makes this the ONLY place
				-- those charges run against a real frame.
				local reader = Wire.NewReader(fromBytes(head), 8192)
				expect(Wire.RU8(reader)).to.equal(Wire.Frames.Diff)
				local ok, result = pcall(Wire.DecodeOps, reader, compiled)

				if ok then
					decoded += 1
					-- Decoding "succeeded", so the result must be a WHOLE op list, not a
					-- half-built one. A decoder that returned early on a mutated count
					-- would hand the client's applier a nil Kind or a nil Path and the
					-- corruption would surface far from here.
					if type(result) ~= "table" then
						error(`seed {SEED + 3} case {case} ({label}): DecodeOps returned a {type(result)}`, 0)
					end
					for i, decodedOp in result do
						if not KINDS[decodedOp.Kind] or type(decodedOp.Path) ~= "table" then
							error(
								`seed {SEED + 3} case {case} ({label}): op {i} decoded to `
									.. `Kind={tostring(decodedOp.Kind)} Path={type(decodedOp.Path)}`,
								0
							)
						end
					end
				else
					threw += 1
					if reader.overBudget then
						budgetRefused += 1
					end
					-- Every refusal is Scribe's own, raised deliberately, or a bounds
					-- error from the buffer library -- never a nil-index or arithmetic
					-- fault, which would mean the decoder walked off its own grammar
					-- rather than refusing at a check.
					local message = tostring(result)
					local expected = string.find(message, "Scribe:", 1, true)
						or string.find(message, "buffer access out of bounds", 1, true)
						or string.find(message, "out of bounds", 1, true)
					if not expected then
						error(`seed {SEED + 3} case {case} ({label}): unexpected failure: {message}`, 0)
					end
				end
			end

			-- Both outcomes, in real proportion: neither a decoder that accepts
			-- everything nor one that rejects everything can pass.
			expect(decoded + threw).to.equal(CASES)
			expect(decoded > CASES // 20).to.equal(true)
			expect(threw > CASES // 20).to.equal(true)
			for _, mutator in { "truncate", "flip", "splice", "extend", "zero" } do
				expect(mutatorCounts[mutator]).to.be.ok()
			end
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
