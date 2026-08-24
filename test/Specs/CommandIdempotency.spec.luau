--!nonstrict
-- Idempotency keys on Data.Command.
--
-- Data.Purchase got the same protection for soft-currency spends, but this key is
-- CLIENT-supplied, and that changes both halves of the design. The record is held in
-- memory on the entry rather than claimed in the persisted Timed store: a player at
-- the full CommandRateLimit would otherwise fill their own profile with junk table
-- keys until it stopped saving, and a handler's return values are not all things a
-- DataStore can hold, so there is nowhere durable to keep the reply a repeat has to
-- be answered with anyway.
--
-- The property that matters most here is the CONCURRENT one. A handler may yield, so
-- two identical requests can be in flight at the same instant; a check that only
-- caught sequential retries would read as protection without being any.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- Frames are hand-built and handed straight to HandleFrame. The mechanism under
	-- test is the server's, and driving it directly is what makes the concurrent case
	-- expressible at all: two overlapping requests need two threads, and a real
	-- client's send is deferred to the next resumption point.
	local function commandFrame(correlation: number, name: string, key: string?, args: any): buffer
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, correlation)
		Wire.Str(w, name)
		Wire.U8(w, args.n)
		Wire.Str(w, key or "")
		for i = 1, args.n do
			Wire.EncodeGeneric(w, args[i])
		end
		return Wire.Finish(w)
	end

	local function sendFrame(harness, entry, bytes: buffer)
		local reader = Wire.NewReader(bytes)
		Wire.RU8(reader) -- frame type, consumed by the real dispatcher
		harness.Ctx.Commands.HandleFrame(entry, reader)
	end

	local function send(harness, entry, correlation: number, name: string, key: string?, ...)
		sendFrame(harness, entry, commandFrame(correlation, name, key, table.pack(...)))
	end

	local function replies(harness, player)
		return harness.FramesFor(player, Wire.Frames.CommandReply)
	end

	local function makeHarness(options)
		local harness = TestCtx.make({ Options = options })
		local player, entry = harness.Join(97001)
		return harness, player, entry
	end

	describe("at most once per key", function()
		it("runs the handler once and answers every repeat with the ORIGINAL reply", function()
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
				return true, runs
			end)

			for correlation = 1, 3 do
				send(harness, entry, correlation, "Claim", "k1")
			end

			expect(runs).to.equal(1)
			local got = replies(harness, player)
			expect(#got).to.equal(3)
			for i, frame in got do
				-- Every repeat is answered, and answered on its OWN correlation --
				-- a duplicate that went unanswered would strand its caller until
				-- RequestTimeout, which is exactly the failure it was retrying.
				expect(frame.Correlation).to.equal(i)
				expect(frame.Ok).to.equal(true)
				expect(frame.Results[1]).to.equal(true)
				-- The FIRST call's value on all three. If the handler re-ran, the
				-- repeats would carry 2 and 3 and this whole feature would be a
				-- counter that happens to look right in aggregate.
				expect(frame.Results[2]).to.equal(1)
			end
			harness.Cleanup()
		end)

		it("still runs separately for a different key", function()
			local harness, _player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			send(harness, entry, 1, "Claim", "a")
			send(harness, entry, 2, "Claim", "b")

			expect(runs).to.equal(2)
			harness.Cleanup()
		end)

		it("keeps the same key on two commands apart", function()
			-- Records are namespaced by command name. Two commands sharing a key are
			-- two operations, and replaying one's reply for the other is not a
			-- near-miss -- it is a straightforwardly wrong answer to a different
			-- question.
			local harness, player, entry = makeHarness()
			harness.Data.Command("First", { Idempotent = true }, function()
				return "first"
			end)
			harness.Data.Command("Second", { Idempotent = true }, function()
				return "second"
			end)

			send(harness, entry, 1, "First", "shared")
			send(harness, entry, 2, "Second", "shared")

			local got = replies(harness, player)
			expect(got[1].Results[1]).to.equal("first")
			expect(got[2].Results[1]).to.equal("second")
			harness.Cleanup()
		end)
	end)

	describe("duplicates that overlap", function()
		it("coalesces a repeat that arrives while the first call is still running", function()
			-- The defect the whole design turns on. The handler yields, so the two
			-- requests are genuinely simultaneous. Claiming AFTER the handler returned
			-- would let both execute while still passing every sequential spec above.
			local harness, player, entry = makeHarness()
			local runs = 0
			local release
			harness.Data.Command("Slow", { Idempotent = true }, function()
				runs += 1
				local handlerThread = coroutine.running()
				release = function()
					task.spawn(handlerThread)
				end
				coroutine.yield()
				return "once", runs
			end)

			task.spawn(send, harness, entry, 1, "Slow", "k")
			expect(runs).to.equal(1)
			expect(#replies(harness, player)).to.equal(0) -- still inside the handler

			send(harness, entry, 2, "Slow", "k")
			expect(runs).to.equal(1) -- did not start a second run...
			expect(#replies(harness, player)).to.equal(0) -- ...and was parked, not refused

			release()

			local got = replies(harness, player)
			expect(#got).to.equal(2)
			expect(got[1].Correlation).to.equal(1)
			expect(got[2].Correlation).to.equal(2)
			for _, frame in got do
				expect(frame.Ok).to.equal(true)
				expect(frame.Results[1]).to.equal("once")
				expect(frame.Results[2]).to.equal(1)
			end
			harness.Cleanup()
		end)

		it("answers a parked duplicate with the first call's FAILURE, then stays retryable", function()
			local harness, player, entry = makeHarness()
			local attempts = 0
			local release
			harness.Data.Command("Slow", { Idempotent = true }, function()
				attempts += 1
				if attempts == 1 then
					local handlerThread = coroutine.running()
					release = function()
						task.spawn(handlerThread)
					end
					coroutine.yield()
					error("boom", 0)
				end
				return "recovered"
			end)

			task.spawn(send, harness, entry, 1, "Slow", "k")
			send(harness, entry, 2, "Slow", "k") -- parks on the in-flight call
			release()

			local got = replies(harness, player)
			expect(#got).to.equal(2)
			expect(got[1].Ok).to.equal(false)
			expect(got[2].Ok).to.equal(false)
			expect(got[2].Results[1]).to.equal("error")

			-- ...and the key was released with the failure, so a LATER retry runs.
			send(harness, entry, 3, "Slow", "k")
			expect(attempts).to.equal(2)
			expect(replies(harness, player)[3].Results[1]).to.equal("recovered")
			harness.Cleanup()
		end)
	end)

	describe("the replayed reply is the original", function()
		it("preserves arity across an embedded nil", function()
			-- table.pack's `.n` is the only record of the arity; `#` stops at the
			-- first hole. A cache that stored a plain array would turn (1, nil, 3)
			-- into (1) on every repeat -- so the retry a caller made BECAUSE it lost
			-- the first answer would be handed a different one.
			local harness, player, entry = makeHarness()
			harness.Data.Command("Holes", { Idempotent = true }, function()
				return 1, nil, 3
			end)

			send(harness, entry, 1, "Holes", "k")
			send(harness, entry, 2, "Holes", "k")

			local got = replies(harness, player)
			expect(got[1].Results[3]).to.equal(3) -- control: the original carries it
			expect(got[2].Results[3]).to.equal(3) -- and so does the replay
			harness.Cleanup()
		end)
	end)

	describe("a failed call claims nothing", function()
		it("stays retryable after the handler throws", function()
			-- The same property that makes the purchase claim safe to take at all: a
			-- handler that threw did not happen, so caching its failure would turn one
			-- transient error into a permanent one for that key.
			local harness, player, entry = makeHarness()
			local attempts = 0
			harness.Data.Command("Flaky", { Idempotent = true }, function()
				attempts += 1
				if attempts == 1 then
					error("boom", 0)
				end
				return "ok"
			end)

			send(harness, entry, 1, "Flaky", "k")
			send(harness, entry, 2, "Flaky", "k")

			expect(attempts).to.equal(2)
			local got = replies(harness, player)
			expect(got[1].Ok).to.equal(false)
			expect(got[1].Results[1]).to.equal("error")
			expect(got[2].Ok).to.equal(true)
			expect(got[2].Results[1]).to.equal("ok")
			harness.Cleanup()
		end)
	end)

	describe("the requirement is symmetric", function()
		it("refuses a keyless call to an Idempotent command, without running it", function()
			-- Silently running it would hand the caller a command they believe is
			-- protected and is not, which is worse than no protection: the retry that
			-- double-spends looks correct right up until it lands.
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			send(harness, entry, 1, "Claim", nil)

			expect(runs).to.equal(0)
			local got = replies(harness, player)
			expect(got[1].Ok).to.equal(false)
			expect(got[1].Results[1]).to.equal(Scribe.RequestReason.BadIdempotencyKey)
			harness.Cleanup()
		end)

		it("refuses a keyed call to a command that is not Idempotent, without running it", function()
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Plain", function()
				runs += 1
			end)

			send(harness, entry, 1, "Plain", "k")

			expect(runs).to.equal(0)
			local got = replies(harness, player)
			expect(got[1].Ok).to.equal(false)
			expect(got[1].Results[1]).to.equal(Scribe.RequestReason.BadIdempotencyKey)
			harness.Cleanup()
		end)

		it("leaves an ordinary keyless command untouched", function()
			-- The wire gained a field; every existing command has to behave exactly as
			-- it did, including the no-spec registration form.
			local harness, player, entry = makeHarness()
			harness.Data.Command("Ping", function(_player, value)
				return "pong", value
			end)

			send(harness, entry, 1, "Ping", nil, 42)
			send(harness, entry, 2, "Ping", nil, 43)

			local got = replies(harness, player)
			expect(got[1].Results[2]).to.equal(42)
			expect(got[2].Results[2]).to.equal(43)
			harness.Cleanup()
		end)

		it("rejects a non-boolean Idempotent at registration", function()
			local harness = makeHarness()
			expect(function()
				harness.Data.Command("Bad", { Idempotent = "yes" }, function() end)
			end).to.throw()
			harness.Cleanup()
		end)
	end)

	describe("the key is adversarial input", function()
		-- Data.Purchase validates its key defensively; this one arrives from the
		-- client, so the checks are the boundary rather than a courtesy. The client
		-- helper refuses these before they are sent, so they are driven at the wire.
		it("refuses a key past the byte cap", function()
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			send(harness, entry, 1, "Claim", string.rep("k", Wire.MAX_IDEMPOTENCY_KEY_BYTES + 1))

			expect(runs).to.equal(0)
			expect(replies(harness, player)[1].Results[1]).to.equal(Scribe.RequestReason.BadIdempotencyKey)
			harness.Cleanup()
		end)

		it("accepts a key at exactly the cap", function()
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			send(harness, entry, 1, "Claim", string.rep("k", Wire.MAX_IDEMPOTENCY_KEY_BYTES))

			expect(runs).to.equal(1)
			expect(replies(harness, player)[1].Ok).to.equal(true)
			harness.Cleanup()
		end)

		it("refuses a key that is not valid UTF-8", function()
			local harness, player, entry = makeHarness()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			send(harness, entry, 1, "Claim", "bad" .. string.char(0xFF, 0xFE) .. "key")

			expect(runs).to.equal(0)
			expect(replies(harness, player)[1].Results[1]).to.equal(Scribe.RequestReason.BadIdempotencyKey)
			harness.Cleanup()
		end)

		it("bounds how many records one player can hold, and says so when it drops one", function()
			-- The cap is the whole reason this cache is safe to expose to client-named
			-- keys. Evicting an unexpired record means a retry under it runs the
			-- handler again, so the eviction is counted rather than silent -- the same
			-- rule the purchase ring follows.
			-- The rate limit is lifted so the RECORD cap is what this measures: at the
			-- default 20/s the token bucket empties first and every assertion below
			-- would be about the wrong ceiling.
			local harness, _player, entry = makeHarness({ CommandRateLimit = 1000 })
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			local cap = 64 -- MAX_IDEMPOTENT_RECORDS
			local evictedBefore = Metrics.Get().CommandIdemEvicted or 0
			for i = 1, cap do
				send(harness, entry, i, "Claim", `key-{i}`)
			end
			expect(runs).to.equal(cap)

			-- Still cached, so nothing has been dropped yet.
			send(harness, entry, cap + 1, "Claim", `key-{cap}`)
			expect(runs).to.equal(cap)
			expect((Metrics.Get().CommandIdemEvicted or 0) - evictedBefore).to.equal(0)

			-- One past the cap: a record is dropped to make room, and it is reported.
			send(harness, entry, cap + 2, "Claim", "one-too-many")
			expect(runs).to.equal(cap + 1)
			expect((Metrics.Get().CommandIdemEvicted or 0) - evictedBefore).to.equal(1)

			local live = 0
			for _ in entry.CommandIdem do
				live += 1
			end
			expect(live <= cap).to.equal(true)
			harness.Cleanup()
		end)

		it("never evicts a record that is still in flight", function()
			-- The cap has to make room from the SETTLED records only. An in-flight
			-- record is the sole route back to the duplicates parked on it, and to the
			-- key's own retry protection while the handler is still running: dropping
			-- one lets the very next repeat start a second concurrent run of a handler
			-- that has not finished its first. When every record is in flight there is
			-- nothing safe to drop, so the new call is refused instead.
			local harness, player, entry = makeHarness({ CommandRateLimit = 1000 })
			local runs = 0
			local parked = {}
			harness.Data.Command("Slow", { Idempotent = true }, function()
				runs += 1
				table.insert(parked, coroutine.running())
				coroutine.yield()
				return "done", runs
			end)

			local cap = 64 -- MAX_IDEMPOTENT_RECORDS
			local evictedBefore = Metrics.Get().CommandIdemEvicted or 0
			for i = 1, cap do
				task.spawn(send, harness, entry, i, "Slow", `key-{i}`)
			end
			expect(runs).to.equal(cap)
			expect(#replies(harness, player)).to.equal(0) -- all still running

			-- One more distinct key with the store full of in-flight records.
			send(harness, entry, cap + 1, "Slow", "one-too-many")
			expect(runs).to.equal(cap) -- refused rather than making room
			expect((Metrics.Get().CommandIdemEvicted or 0) - evictedBefore).to.equal(0)
			local refusal = replies(harness, player)
			expect(#refusal).to.equal(1)
			expect(refusal[1].Correlation).to.equal(cap + 1)
			expect(refusal[1].Ok).to.equal(false)
			expect(refusal[1].Results[1]).to.equal(Scribe.RequestReason.RateLimited)

			-- ...and the first key's record survived, so its repeat still coalesces
			-- onto the call that is running rather than starting a second one.
			send(harness, entry, cap + 2, "Slow", "key-1")
			expect(runs).to.equal(cap)

			for _, thread in parked do
				task.spawn(thread)
			end
			-- Every original answered, plus the parked repeat, plus the refusal.
			expect(#replies(harness, player)).to.equal(cap + 2)
			harness.Cleanup()
		end)

		it("does not persist anything the client named", function()
			-- The reason this cache is not the Timed claim Data.Purchase takes. A
			-- persisted key would let a player at the full rate limit grow their own
			-- profile without bound, and it would still stop saving long before the
			-- keys expired.
			local harness, player, entry = makeHarness()
			harness.Data.Command("Claim", { Idempotent = true }, function()
				return true
			end)

			send(harness, entry, 1, "Claim", "some-client-key")
			expect(harness.Data.Flush(player)).to.equal(true)

			local stored = harness.Fake.Persisted["Default/PLAYER_97001"]
			expect(stored).never.to.equal(nil)
			local encoded = game:GetService("HttpService"):JSONEncode(stored)
			expect(string.find(encoded, "some-client-key", 1, true)).to.equal(nil)
			harness.Cleanup()
		end)
	end)

	describe("through the real client", function()
		local function makeLoopback()
			local harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
			local player, entry = harness.Join(97002)
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)
			return harness, player, entry, clientData
		end

		itRunning("RequestOnce runs the handler once across a retry", function()
			local harness, _player, _entry, clientData = makeLoopback()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
				return "granted", runs
			end)

			local firstOk, firstCount = clientData.RequestOnce("Claim", "click-1")
			local againOk, againCount = clientData.RequestOnce("Claim", "click-1")

			expect(runs).to.equal(1)
			expect(firstOk).to.equal("granted")
			expect(againOk).to.equal(firstOk)
			expect(againCount).to.equal(firstCount)
			harness.Cleanup()
		end)

		itRunning("a plain Request to an Idempotent command is refused", function()
			local harness, _player, _entry, clientData = makeLoopback()
			local runs = 0
			harness.Data.Command("Claim", { Idempotent = true }, function()
				runs += 1
			end)

			local ok, reason = clientData.Request("Claim")

			expect(runs).to.equal(0)
			expect(ok).to.equal(false)
			expect(reason).to.equal(Scribe.RequestReason.BadIdempotencyKey)
			harness.Cleanup()
		end)

		itRunning("pins the Command frame layout and the version that describes it", function()
			-- The version gate is the only thing standing between a mixed deploy and a
			-- silently mis-decoded command: a v1 client's frame has no key field, so a
			-- v2 server reading one consumes the bytes of its FIRST ARGUMENT instead,
			-- and what reaches the handler is garbage rather than a refusal. Layout and
			-- version therefore have to move together, so both are pinned -- change
			-- either and this fails until the other is changed with it.
			--
			-- The version ALSO moves for changes elsewhere in the protocol, and three
			-- have happened: v3 added Frames.Fragment, v4 folded the value-mode byte into
			-- a value header carrying the key tag and a dense-array flag, and v5 gave
			-- that header a third mode for the presence bitmask -- all three with the
			-- Command layout below untouched. Re-pinning is the right response rather
			-- than a weakening -- the coupling this test enforces is "you cannot change
			-- the Command layout without moving the version", and that still holds at
			-- 5. What would break it is relaxing this to a range; do not.
			--
			-- This equality is NOT what pins R3, and on its own it never was: a constant
			-- can be re-pinned by whoever changes it without the refusal ever running.
			-- Replication.spec's "refuses a Hello whose protocol version differs" drives
			-- a MISMATCHED version through the real onHello and asserts the handshake
			-- fails closed. Keep both; they fail for different reasons.
			expect(Wire.PROTOCOL_VERSION).to.equal(6)

			local harness, _player, _entry, clientData = makeLoopback()
			harness.Data.Command("Echo", { Args = { "string" }, Idempotent = true }, function(_player, value)
				return value
			end)
			clientData.RequestOnce("Echo", "the-key", "the-arg")

			-- Read the frame the REAL client encoded, field by field, in the order the
			-- server's HandleFrame reads them.
			local sent = harness.Transport.SentToServerLog
			local reader = Wire.NewReader(sent[#sent].Bytes)
			expect(Wire.RU8(reader)).to.equal(Wire.Frames.Command)
			Wire.RU32(reader) -- correlation
			expect(Wire.RStr(reader)).to.equal("Echo")
			expect(Wire.RU8(reader)).to.equal(1) -- argc
			-- The key sits HERE, ahead of the arguments, so the server can refuse an
			-- unusable one without decoding anything attacker-sized.
			expect(Wire.RStr(reader)).to.equal("the-key")
			expect(Wire.DecodeGeneric(reader)).to.equal("the-arg")
			expect(Wire.Remaining(reader)).to.equal(0)
			harness.Cleanup()
		end)

		itRunning("refuses an unusable key before it costs a round trip", function()
			local harness, _player, _entry, clientData = makeLoopback()
			harness.Data.Command("Claim", { Idempotent = true }, function() end)

			for _, bad in { "", string.rep("k", Wire.MAX_IDEMPOTENCY_KEY_BYTES + 1), 12345 } do
				expect(function()
					clientData.RequestOnce("Claim", bad :: any)
				end).to.throw()
			end
			harness.Cleanup()
		end)
	end)
end
