--!nonstrict
-- Capping the WORK an inbound frame may do, not just the bytes it may occupy.
--
-- The byte cap is a poor proxy for cost because cost-per-byte varies by three
-- orders of magnitude. `06 00` is a two-byte empty buffer and one GC object; the
-- same eight kilobytes spent on a single string is one GC object too. So an
-- 8 KB frame is worth either ~4,000 allocations or one, and MaxInboundBytes
-- cannot tell the difference. Depth does not help either: a flat table of four
-- thousand siblings is depth 1, nowhere near the cap of 24.
--
-- Since the frame's SIZE is already bounded, the missing dimension is exactly
-- allocations-per-byte, so that is what is counted.
--
-- The most important spec in this file is the LAST one. The same decoder runs on
-- the client over server-sent Init and Diff frames, which are not size-limited,
-- so a budget applied globally rather than per-reader would refuse legitimate
-- snapshots and present as "replication randomly stops".

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local Client = require(Root.Scribe.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local RunService = game:GetService("RunService")
	local itRunning = if RunService:IsRunning() then it else itSKIP

	--- A generic table of `n` empty buffers: the densest shape the decoder accepts,
	--- at two bytes per allocated object.
	local function denseBuffers(n: number)
		local out = table.create(n)
		for i = 1, n do
			out[i] = buffer.create(0)
		end
		return out
	end

	--- The same idea with empty tables, at three bytes each.
	local function denseTables(n: number)
		local out = table.create(n)
		for i = 1, n do
			out[i] = {}
		end
		return out
	end

	local function encoded(value): buffer
		local w = Wire.NewWriter(16384)
		Wire.EncodeGeneric(w, value)
		return Wire.Finish(w)
	end

	describe("the decoder's retention budget", function()
		-- The budget is denominated in RETAINED BYTES, not in objects, and every
		-- number below is the exact modelled cost of the shape it decodes. They are
		-- written as BOUNDARIES -- one byte under refuses, exactly on accepts --
		-- because that is what makes each charge site individually killable: an
		-- assertion with slack passes with the charge deleted.
		--
		-- The model: table 64, array slot 32, hash node 64, string 24 + payload,
		-- buffer 24 + payload.

		it("refuses a frame that would retain past its budget", function()
			-- 1 table (64) + 40 x (slot 32 + buffer 24) = 2,304 against a budget of 500.
			local bytes = encoded(denseBuffers(40))
			local reader = Wire.NewReader(bytes, 500)
			expect(function()
				Wire.DecodeGeneric(reader)
			end).to.throw()
			-- Flagged on the READER, so the caller can tell "too expensive" from
			-- "malformed" without matching on error text a crafted frame could
			-- otherwise contain.
			expect(reader.overBudget).to.equal(true)
		end)

		it("accepts a payload that fits exactly, so the cap is not merely a refusal", function()
			-- 64 + 8 x (32 + 24) = 512, to the byte.
			local bytes = encoded(denseBuffers(8))
			local reader = Wire.NewReader(bytes, 512)
			local out = Wire.DecodeGeneric(reader)
			expect(#out).to.equal(8)
			expect(`left={reader.budget} over={tostring(reader.overBudget)}`).to.equal("left=0 over=nil")

			local tight = Wire.NewReader(encoded(denseBuffers(8)), 511)
			expect(function()
				Wire.DecodeGeneric(tight)
			end).to.throw()
		end)

		it("charges the TABLE", function()
			-- An empty table is 64 and nothing else.
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded({}), 64))).to.be.ok()
			local tight = Wire.NewReader(encoded({}), 63)
			expect(function()
				Wire.DecodeGeneric(tight)
			end).to.throw()
			expect(tight.overBudget).to.equal(true)
		end)

		it("charges the SLOT a primitive sits in, but not the primitive itself", function()
			-- The model: a primitive VALUE allocates nothing and is not charged; the
			-- SLOT holding it is memory and is. 64 + 32 = 96 for one boolean.
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded({ true }), 96))).to.be.ok()
			local tight = Wire.NewReader(encoded({ true }), 95)
			expect(function()
				Wire.DecodeGeneric(tight)
			end).to.throw()

			-- A bare primitive, not in a table, still costs nothing at all.
			local bare = Wire.NewReader(encoded(12.5), 0)
			expect(Wire.DecodeGeneric(bare)).to.equal(12.5)
			expect(bare.overBudget).to.equal(nil)
		end)

		it("charges the STRING, including its payload", function()
			-- 64 + slot 32 + (24 + 5) = 125. Charging a flat header instead of the
			-- payload would let one 8 KB string through for the price of a short one.
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded({ "abcde" }), 125))).to.be.ok()
			expect(function()
				Wire.DecodeGeneric(Wire.NewReader(encoded({ "abcde" }), 124))
			end).to.throw()

			-- The payload half, stated on its own: 64 + 32 + 24 + 1000.
			local long = { string.rep("a", 1000) }
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded(long), 1120))).to.be.ok()
			expect(function()
				Wire.DecodeGeneric(Wire.NewReader(encoded(long), 1119))
			end).to.throw()
		end)

		it("charges the BUFFER, including its payload", function()
			local one = { buffer.create(5) }
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded(one), 125))).to.be.ok()
			expect(function()
				Wire.DecodeGeneric(Wire.NewReader(encoded(one), 124))
			end).to.throw()

			local long = { buffer.create(1000) }
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded(long), 1120))).to.be.ok()
			expect(function()
				Wire.DecodeGeneric(Wire.NewReader(encoded(long), 1119))
			end).to.throw()
		end)

		it("charges the HASH PAIR", function()
			-- 64 (table) + 64 (node) + 25 (the key string "x") = 153. The VALUE here
			-- is a primitive in a hash node, so it adds nothing beyond the node.
			expect(Wire.DecodeGeneric(Wire.NewReader(encoded({ x = 1 }), 153))).to.be.ok()
			local tight = Wire.NewReader(encoded({ x = 1 }), 152)
			expect(function()
				Wire.DecodeGeneric(tight)
			end).to.throw()
			expect(tight.overBudget).to.equal(true)
		end)

		it("refuses a long array of one-byte primitives, which used to slip the cap", function()
			-- `TAG_TRUE` is a single byte, so at the shipped MaxInboundBytes of 8192 an
			-- attacker declares roughly eight thousand slots -- and under the ORIGINAL
			-- accounting the whole frame cost ONE charge, because only the table was a
			-- GC object. Eight kilobytes in, tens of kilobytes of array storage out,
			-- with the cap reporting nothing.
			local flags = table.create(4000)
			for i = 1, 4000 do
				flags[i] = true
			end
			local reader = Wire.NewReader(encoded(flags), 4096)
			expect(function()
				Wire.DecodeGeneric(reader)
			end).to.throw()
			expect(reader.overBudget).to.equal(true)
		end)

		it("is unlimited when no budget is given", function()
			-- The default, and what the client's Init/Diff path relies on.
			local reader = Wire.NewReader(encoded(denseBuffers(5000)))
			local out = Wire.DecodeGeneric(reader)
			expect(#out).to.equal(5000)
		end)
	end)

	describe("on the server's untrusted inbound path", function()
		local function armed()
			local harness = TestCtx.make()
			local player = harness.Join()
			harness.SendHello(player)
			harness.Data.Command("Sink", { Args = { "table" } }, function()
				return true
			end)
			return harness, player
		end

		local function commandFrame(name: string, arg): buffer
			local w = Wire.NewWriter(16384)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, 7)
			Wire.Str(w, name)
			Wire.U8(w, 1)
			Wire.Str(w, "") -- no idempotency key
			Wire.EncodeGeneric(w, arg)
			return Wire.Finish(w)
		end

		it("refuses a dense frame, and charges it to its OWN budget", function()
			local harness, player = armed()
			local entry = harness.Ctx.Persistence.Entries[player]

			-- ~4,000 empty buffers in one argument: about 8 KB, so it clears the
			-- size cap that is supposed to be protecting the decoder.
			local frame = commandFrame("Sink", denseBuffers(3990))
			expect(buffer.len(frame) < 8192).to.equal(true)

			local malformedBefore = entry.MalformedCount
			local repliesBefore = #harness.FramesFor(player, Wire.Frames.CommandReply)
			local limitedBefore = Scribe.GetMetrics().InboundWorkLimited or 0

			harness.Transport:InjectToServer(player, frame)

			expect(`limited={(Scribe.GetMetrics().InboundWorkLimited or 0) - limitedBefore}`).to.equal("limited=1")
			-- NOT the malformed budget. That one is 32 strikes and blocking for the
			-- session, so routing a large-but-legal payload there would drop a
			-- player for sending too much of their own game's data.
			expect(`malformed={entry.MalformedCount - malformedBefore}`).to.equal("malformed=0")
			expect(entry.MalformedBlocked).never.to.equal(true)
			-- No reply, because answering is the amplification the limiter exists
			-- to avoid -- the same reason the frame-rate limiter is silent.
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply)).to.equal(repliesBefore)
			-- The session survives.
			expect(entry.State).to.equal("Ready")
			expect(entry.Tree).to.be.ok()

			harness.Cleanup()
		end)

		it("still serves an ordinary command afterwards", function()
			-- A refusal must not wedge the session: the budget is per frame.
			local harness, player = armed()
			harness.Transport:InjectToServer(player, commandFrame("Sink", denseBuffers(3990)))
			harness.Transport:InjectToServer(player, commandFrame("Sink", { 1, 2, 3 }))
			local replies = harness.FramesFor(player, Wire.Frames.CommandReply)
			expect(#replies > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("lets an ordinary payload of the same SIZE straight through", function()
			-- The discriminating case, and the reason this is a work cap rather
			-- than a smaller byte cap: the same ~8 KB spent on numbers allocates
			-- almost nothing and must not be refused.
			local harness, player = armed()
			local entry = harness.Ctx.Persistence.Entries[player]
			local numbers = table.create(880)
			for i = 1, 880 do
				numbers[i] = i + 0.5
			end
			local frame = commandFrame("Sink", numbers)
			expect(buffer.len(frame) > 7000).to.equal(true)

			local limitedBefore = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, frame)

			expect(`limited={(Scribe.GetMetrics().InboundWorkLimited or 0) - limitedBefore}`).to.equal("limited=0")
			expect(entry.MalformedCount).to.equal(0)
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply) > 0).to.equal(true)
			harness.Cleanup()
		end)

		--- `n` strings of `k` bytes each -- the shape that decides where the cap sits.
		--- Short strings are the densest LEGITIMATE payload a game sends in bulk:
		--- item codes, tags, ids.
		local function shortStrings(n: number, k: number)
			local out = table.create(n)
			local s = string.rep("a", k)
			for i = 1, n do
				out[i] = s
			end
			return out
		end

		it("accepts an ordinary array of short strings at a third of the byte cap", function()
			-- The regression. An array of 550 three-byte strings encodes to 2,754
			-- bytes -- 33.6% of the shipped 8,192-byte ceiling -- and was REFUSED,
			-- because the charging unit changed when array slots and hash pairs were
			-- added as charge sites and the divisor was never re-derived. Under object
			-- counting this frame costs 1 + 550 + 550 = 1,101 against a budget of
			-- 1,024, so it dies at element 512 of 550.
			local harness, player = armed()
			local entry = harness.Ctx.Persistence.Entries[player]
			local frame = commandFrame("Sink", shortStrings(550, 3))
			expect(`bytes={buffer.len(frame)}`).to.equal("bytes=2766")

			local limitedBefore = Scribe.GetMetrics().InboundWorkLimited or 0
			local repliesBefore = #harness.FramesFor(player, Wire.Frames.CommandReply)
			harness.Transport:InjectToServer(player, frame)

			expect(`limited={(Scribe.GetMetrics().InboundWorkLimited or 0) - limitedBefore}`).to.equal("limited=0")
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply) > repliesBefore).to.equal(true)
			-- And it was not merely re-routed into the OTHER budget on the way past.
			expect(`malformed={entry.MalformedCount}`).to.equal("malformed=0")
			harness.Cleanup()
		end)

		it("accepts a FULL frame of two-byte strings, the densest legitimate shape", function()
			-- The binding case for wherever the ceiling is set. If a payload that fits
			-- inside MaxInboundBytes can still be refused for being the wrong SHAPE,
			-- then MaxInboundBytes is not the contract it is documented to be.
			local harness, player = armed()
			local frame = commandFrame("Sink", shortStrings(2000, 2))
			expect(`under={buffer.len(frame) < 8192} over7k={buffer.len(frame) > 7000}`).to.equal(
				"under=true over7k=true"
			)

			local limitedBefore = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, frame)

			expect(`limited={(Scribe.GetMetrics().InboundWorkLimited or 0) - limitedBefore}`).to.equal("limited=0")
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply) > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("still refuses the amplification frames, in both of their shapes", function()
			-- The other direction, and it must not move. A 4,104-byte all-boolean
			-- frame retains ~131 KB of array part (32x), and an array of EMPTY TABLES
			-- is worse still at 96 bytes of retention per 3 input bytes. Loosening the
			-- cap for the two specs above must not re-open either.
			local harness, player = armed()

			local flags = table.create(4100)
			for i = 1, 4100 do
				flags[i] = true
			end
			local boolFrame = commandFrame("Sink", flags)
			expect(`under={buffer.len(boolFrame) < 8192}`).to.equal("under=true")

			local before = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, boolFrame)
			expect(`bools={(Scribe.GetMetrics().InboundWorkLimited or 0) - before}`).to.equal("bools=1")

			before = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, commandFrame("Sink", denseTables(2600)))
			expect(`tables={(Scribe.GetMetrics().InboundWorkLimited or 0) - before}`).to.equal("tables=1")

			before = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, commandFrame("Sink", denseBuffers(3990)))
			expect(`buffers={(Scribe.GetMetrics().InboundWorkLimited or 0) - before}`).to.equal("buffers=1")

			harness.Cleanup()
		end)

		it("honours MaxInboundRetainedBytes when the game raises it", function()
			local harness = TestCtx.make({ Options = { MaxInboundRetainedBytes = 400000 } })
			local player = harness.Join()
			harness.SendHello(player)
			harness.Data.Command("Sink", { Args = { "table" } }, function()
				return true
			end)
			local limitedBefore = Scribe.GetMetrics().InboundWorkLimited or 0
			harness.Transport:InjectToServer(player, commandFrame("Sink", denseBuffers(3990)))
			expect(`limited={(Scribe.GetMetrics().InboundWorkLimited or 0) - limitedBefore}`).to.equal("limited=0")
			harness.Cleanup()
		end)
	end)

	describe("the command name read", function()
		-- The one attacker-sized read the command rate limiter does not cover: the
		-- name is read ABOVE takeToken, so it runs at the raw frame rate rather than
		-- at CommandRateLimit -- four times more often by default.
		--
		-- The idempotency key deliberately keeps its read-then-check shape: that one
		-- sits BELOW the token, and its cap is about what may be retained as a table
		-- key rather than about the read. Its own comment says so.

		it("refuses from the length prefix, without reading the payload", function()
			-- The assertion that distinguishes a real fix from a cosmetic one. A cap
			-- applied to the RETURNED string has already paid for the allocation; the
			-- proof that this one did not is that the cursor never moved past the
			-- prefix.
			local w = Wire.NewWriter(8192)
			Wire.Str(w, string.rep("x", 5000))
			local reader = Wire.NewReader(Wire.Finish(w))

			expect(function()
				Wire.RStrBounded(reader, 64)
			end).to.throw()
			expect(`walked={reader.pos < 8}`).to.equal("walked=true")
		end)

		it("accepts a string exactly at its limit", function()
			local w = Wire.NewWriter(128)
			Wire.Str(w, string.rep("y", 64))
			local reader = Wire.NewReader(Wire.Finish(w))
			expect(#Wire.RStrBounded(reader, 64)).to.equal(64)
		end)

		it("refuses an over-long command name as malformed", function()
			local harness = TestCtx.make()
			local player = harness.Join()
			harness.SendHello(player)
			harness.Data.Command("Sink", { Args = { "table" } }, function()
				return true
			end)
			local entry = harness.Ctx.Persistence.Entries[player]

			local w = Wire.NewWriter(16384)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, 7)
			Wire.Str(w, string.rep("n", 8000)) -- longer than any registered command
			Wire.U8(w, 0)
			Wire.Str(w, "")
			local frame = Wire.Finish(w)
			expect(buffer.len(frame) < 8192).to.equal(true)

			local malformedBefore = entry.MalformedCount
			local repliesBefore = #harness.FramesFor(player, Wire.Frames.CommandReply)
			harness.Transport:InjectToServer(player, frame)

			-- Malformed rather than its own budget, and that is the right home: a
			-- name longer than every registered command cannot match one, and
			-- Scribe's own client only ever sends names the game registered.
			expect(`malformed={entry.MalformedCount - malformedBefore}`).to.equal("malformed=1")
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply)).to.equal(repliesBefore)
			expect(entry.State).to.equal("Ready")
			harness.Cleanup()
		end)

		it("derives the limit from the registry, so a long registered name still works", function()
			-- The reason the cap is derived rather than a constant. A game is free to
			-- register a 100-character command name, and it must keep working.
			local longName = string.rep("L", 100)
			local harness = TestCtx.make()
			local player = harness.Join()
			harness.SendHello(player)
			harness.Data.Command(longName, function()
				return 7
			end)

			local w = Wire.NewWriter(256)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, 11)
			Wire.Str(w, longName)
			Wire.U8(w, 0)
			Wire.Str(w, "")
			harness.Transport:InjectToServer(player, Wire.Finish(w))

			local replies = harness.FramesFor(player, Wire.Frames.CommandReply)
			expect(#replies > 0).to.equal(true)
			local entry = harness.Ctx.Persistence.Entries[player]
			expect(entry.MalformedCount).to.equal(0)
			harness.Cleanup()
		end)

		it("still answers an ordinary unknown name with unknown-command", function()
			-- The floor exists for this: a typo must reach the registry and get a
			-- reply, not be charged as a malformed frame.
			local harness = TestCtx.make()
			local player = harness.Join()
			harness.SendHello(player)
			harness.Data.Command("Sink", function()
				return true
			end)
			local entry = harness.Ctx.Persistence.Entries[player]

			local w = Wire.NewWriter(128)
			Wire.U8(w, Wire.Frames.Command)
			Wire.U32(w, 5)
			Wire.Str(w, "SinkTypoThatIsNotRegisteredAnywhere")
			Wire.U8(w, 0)
			Wire.Str(w, "")
			harness.Transport:InjectToServer(player, Wire.Finish(w))

			expect(entry.MalformedCount).to.equal(0)
			expect(#harness.FramesFor(player, Wire.Frames.CommandReply) > 0).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("the client's trusted inbound path", function()
		itRunning("still applies a snapshot far larger than the server's object budget", function()
			-- THE anti-landmine spec. Server-sent Init and Diff frames run through
			-- the same decoder and are not size-limited outbound, so a budget made
			-- global to Wire rather than supplied per reader would refuse a large
			-- but perfectly legitimate snapshot. That failure would surface as
			-- "replication randomly stops", nowhere near its cause.
			local template = TestCtx.defaultTemplate()
			template.Bag = Scribe.DictOf(Scribe.String(""))
			local harness = TestCtx.make({ AutoPump = true, Template = template })
			local player, _, data = harness.Join()
			harness.Transport.LocalPlayer = player

			-- Written BEFORE the client exists, so it arrives in the Init snapshot
			-- rather than as diffs. 3,000 entries is comfortably past the 1,024
			-- objects the server allows on ITS inbound path.
			local bag = {}
			for i = 1, 3000 do
				bag[`k{i}`] = `v{i}`
			end
			data.Bag.Set(bag)

			-- Client.new sends Hello synchronously over the loopback and applies the
			-- snapshot before it returns.
			local client = Client.new(harness.Options, harness.Compiled)

			local mirrored = client.Bag.Get()
			expect(mirrored).to.be.ok()
			local count = 0
			for _ in mirrored do
				count += 1
			end
			expect(`mirrored={count}`).to.equal("mirrored=3000")

			harness.Cleanup()
		end)
	end)
end
