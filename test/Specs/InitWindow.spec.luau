--!nonstrict
-- The gap between the Init snapshot and the handshake, and what falls into it.
--
-- sendInit clones every root, encodes it, and only then marks the entry ready to
-- receive frames. Until that mark, PushOp discards: "before the handshake the
-- snapshot supersedes diffs". That reasoning is airtight only while nothing can
-- happen in between -- and something can. The Shared drain inside sendInit reaches
-- transport:SendToClient before the mark, and a transport adapter is free to yield
-- there. A write landing in that gap is in neither the clone nor the queue.
--
-- It is not lost data: the write reached the profile and persists. What is lost is
-- its REPLICATION, permanently, with no error and no anomaly -- the client mirror
-- simply disagrees with the server for the rest of the session.
--
-- These drive the gap through the transport seam, which is where it is actually
-- reachable, and they insist on a frame boundary inside it: a queue that survives
-- the gap but not the flush loop is no better than one that was never filled.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	--- A transport that behaves exactly like the stub, except that one chosen frame
	--- runs `during` before it is delivered. Nothing here is exotic: Transport.Resolve
	--- asks only that the keys are functions, and the guides never say a transport may
	--- not yield.
	local function hookedTransport()
		local inner = StubTransport.new({ AutoPump = false })
		local hook = { Inner = inner, During = nil :: any, When = nil :: any, Armed = false, Fired = 0 }

		local transport = {}
		transport.Name = "Hooked"

		function transport.SendToClient(_self: any, player: any, bytes: buffer)
			if hook.Armed and hook.During and (hook.When == nil or hook.When == player) then
				hook.Armed = false
				hook.Fired += 1
				hook.During()
			end
			inner:SendToClient(player, bytes)
		end

		function transport.SendToAllClients(_self: any, bytes: buffer)
			transport.SendToClient(_self, nil, bytes)
		end

		function transport.ListenServer(_self: any, callback: (player: any, bytes: buffer) -> ())
			inner:ListenServer(callback)
		end

		hook.Transport = transport
		return hook
	end

	local function sendHello(hook, compiled, player)
		local w = Wire.NewWriter(8)
		Wire.U8(w, Wire.Frames.Hello)
		Wire.U32(w, compiled.Hash % 4294967296)
		Wire.U8(w, Wire.PROTOCOL_VERSION)
		hook.Inner:InjectToServer(player, Wire.Finish(w))
	end

	--- Every value this player was ever sent, across Init and Diff frames, flattened
	--- so the assertion does not care which frame carried it.
	local function valuesSentFor(harness, hook, player, root: string): { any }
		local seen = {}
		for _, sent in hook.Inner.SentToClientLog do
			if sent.Player ~= nil and sent.Player ~= player then
				continue
			end
			local ok, frame = pcall(harness.DecodeFrame, sent.Bytes)
			if not ok or frame.Ops == nil then
				continue
			end
			for _, op in frame.Ops do
				if op.Path and op.Path[1] == root then
					table.insert(seen, if type(op.Value) == "table" then op.Value[root] else op.Value)
				end
			end
		end
		return seen
	end

	it("replicates a write that lands before the joiner is marked ready", function()
		-- The pre-mark gap, driven the way it is actually reachable on shipped code.
		-- sendInit drains every OTHER ready player's Shared queue before marking this
		-- one ready, and that drain reaches the transport. A transport that yields
		-- there leaves the joiner in the gap: its snapshot is already cloned, and
		-- PushOp still discards everything on the grounds that the snapshot will
		-- carry it.
		local hook = hookedTransport()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Pub = Scribe.Shared({ Log = {} }) },
			Options = { Transport = hook.Transport },
		})
		local playerA = harness.Join(97801)
		local playerB = harness.Join(97811)
		sendHello(hook, harness.Compiled, playerA)
		sendHello(hook, harness.Compiled, playerB)
		harness.Step()

		-- A queued Shared op, deliberately not yet flushed: this is what makes
		-- sendInit reach the transport before it marks the joiner ready.
		harness.Data.Get(playerA).Pub.Log.Insert("x")

		local playerC = FakePlayer.new(97821)
		harness.Ctx.Persistence.OnPlayerAdded(playerC)
		local dataC = harness.Ctx.Persistence.WaitForData(playerC)
		dataC.Coins.Set(11)

		-- Fire on the drain's delivery to B, which happens while C is still unmarked.
		hook.When = playerB
		hook.During = function()
			dataC.Coins.Set(42)
			-- ...and a frame passes while the transport is away. This is the half a
			-- same-frame yield would hide: the flush loop runs over an entry whose
			-- queue is filling but which is not ready to send yet.
			harness.Step()
		end
		hook.Armed = true
		sendHello(hook, harness.Compiled, playerC)
		harness.Step()

		expect(`fired={hook.Fired}`).to.equal("fired=1")
		local sent = valuesSentFor(harness, hook, playerC, "Coins")
		expect(`server={dataC.Coins.Get()} sent={table.concat(sent, ",")}`).to.equal("server=42 sent=11,42")

		harness.Cleanup()
	end)

	it("never lets a diff reach the client before the snapshot it diffs against", function()
		-- The other half of the same fix, and the reason the ready mark moves AFTER
		-- the Init is actually on the wire rather than before it. A client that
		-- applies a diff to a mirror it has not been given yet has nowhere to put it.
		local hook = hookedTransport()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { Transport = hook.Transport },
		})
		local player, _entry, data = harness.Join(97802)

		hook.During = function()
			data.Coins.Set(7)
			harness.Step()
		end
		hook.Armed = true
		sendHello(hook, harness.Compiled, player)
		harness.Step()

		local order = {}
		for _, sent in hook.Inner.SentToClientLog do
			if sent.Player ~= nil and sent.Player ~= player then
				continue
			end
			local ok, frame = pcall(harness.DecodeFrame, sent.Bytes)
			if ok and (frame.Type == Wire.Frames.Init or frame.Type == Wire.Frames.Diff) then
				table.insert(order, if frame.Type == Wire.Frames.Init then "init" else "diff")
			end
		end
		expect(table.concat(order, ",")).to.equal("init,diff")

		harness.Cleanup()
	end)

	it("does not start a second snapshot for a Hello that arrives during the first", function()
		-- The re-Init throttle and the "already handshaking" guard both mean "an Init
		-- has already begun for this entry". If they instead read "this entry can
		-- receive frames", they are both false for the whole send phase -- and Hello
		-- is a client-controlled frame, so a client could drive a fresh whole-profile
		-- clone and encode per Hello, nested inside the one already running.
		local hook = hookedTransport()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Options = { Transport = hook.Transport },
		})
		local player = harness.Join(97803)

		hook.During = function()
			for _ = 1, 5 do
				sendHello(hook, harness.Compiled, player)
			end
		end
		hook.Armed = true
		sendHello(hook, harness.Compiled, player)
		harness.Step()

		local inits = 0
		for _, sent in hook.Inner.SentToClientLog do
			if sent.Player ~= nil and sent.Player ~= player then
				continue
			end
			local ok, frame = pcall(harness.DecodeFrame, sent.Bytes)
			if ok and frame.Type == Wire.Frames.Init then
				inits += 1
			end
		end
		expect(`inits={inits}`).to.equal("inits=1")

		harness.Cleanup()
	end)

	it("does not replay pre-snapshot ops on top of a resnapshot", function()
		-- A repeated Hello re-snapshots, and the new snapshot already carries
		-- everything written so far -- so whatever is still sitting in the queue at
		-- that moment is a duplicate of it, not an addition to it. Harmless for a
		-- scalar, which is idempotent; an Insert applied twice leaves the client with
		-- two of something the server has one of, permanently.
		local hook = hookedTransport()
		local harness = TestCtx.make({
			Template = { Log = {} },
			Options = { Transport = hook.Transport },
		})
		local player, _entry, data = harness.Join(97831)
		sendHello(hook, harness.Compiled, player)
		harness.Step()

		-- Queued, not yet flushed, at the moment the second Hello arrives.
		data.Log.Insert("only-once")

		local entry = harness.Ctx.Persistence.EntryFor(player)
		entry.LastInitAt = 0 -- past the re-Init throttle, as a real resync would be
		sendHello(hook, harness.Compiled, player)
		harness.Step()
		harness.Step()

		-- Count the op as the client would apply it: one Init carrying the array, plus
		-- any Insert diffs after it.
		local inserts = 0
		local lastInitLen = nil
		for _, sent in hook.Inner.SentToClientLog do
			if sent.Player ~= nil and sent.Player ~= player then
				continue
			end
			local ok, frame = pcall(harness.DecodeFrame, sent.Bytes)
			if not ok or frame.Ops == nil then
				continue
			end
			for _, op in frame.Ops do
				if op.Path and op.Path[1] == "Log" then
					if frame.Type == Wire.Frames.Init then
						lastInitLen = if type(op.Value) == "table" then #op.Value else nil
					elseif op.Kind == "Insert" then
						inserts += 1
					end
				end
			end
		end
		expect(`initLen={lastInitLen} insertsAfter={inserts}`).to.equal("initLen=1 insertsAfter=0")

		harness.Cleanup()
	end)

	it("still refuses to re-broadcast another player's queued shared op to a joiner", function()
		-- The invariant the obvious version of this fix breaks. sendInit drains every
		-- other ready player's Shared queue BEFORE the joiner can receive broadcasts,
		-- so the joiner's snapshot is the single source for those ops; flipping the
		-- receive mark early would hand them to it twice, and Insert is not
		-- idempotent. Hardening.spec pins it from the other side; this pins that the
		-- window fix did not buy its correctness by breaking it.
		local hook = hookedTransport()
		local harness = TestCtx.make({
			Template = { Pub = Scribe.Shared({ Log = {} }) },
			Options = { Transport = hook.Transport },
		})
		local playerA = harness.Join(97804)
		harness.Join(97805)
		sendHello(hook, harness.Compiled, playerA)
		harness.Step()

		-- A queued Shared op on A, undrained, at the moment C handshakes.
		harness.Data.Get(playerA).Pub.Log.Insert("x")

		local playerC = FakePlayer.new(97806)
		harness.Ctx.Persistence.OnPlayerAdded(playerC)
		harness.Ctx.Persistence.WaitForData(playerC)
		sendHello(hook, harness.Compiled, playerC)
		harness.Step()
		harness.Step()

		local sharedDiffs = 0
		for _, sent in hook.Inner.SentToClientLog do
			if sent.Player ~= nil and sent.Player ~= playerC then
				continue
			end
			local ok, frame = pcall(harness.DecodeFrame, sent.Bytes)
			if ok and frame.Type == Wire.Frames.SharedDiff then
				sharedDiffs += 1
			end
		end
		expect(`sharedDiffsToJoiner={sharedDiffs}`).to.equal("sharedDiffsToJoiner=0")

		harness.Cleanup()
	end)
end
