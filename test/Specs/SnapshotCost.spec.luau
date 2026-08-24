--!nonstrict
-- What a handshake costs, and what the oversize warning can say about it.
--
-- The gap this covers, measured: a Scribe.Session root rides in the Init snapshot
-- and never reaches the DataStore, so a template of { Coins, Cache = Session({}) }
-- with 8,000 keys produced a 286,946-byte Init while approxSize(LiveData) -- the
-- number PROFILE_SIZE reports -- was 158 bytes. Nothing was wrong with delivery;
-- fragmentation carries it. What nothing could say was WHICH ROOT.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Scribe = require(ScribeRoot) :: any
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- TestCtx sets LogLevel = "Fatal" to keep the suite's output clean, and that is
	-- fine here: Log fills the ring BEFORE consulting the level (Log.luau:137-142),
	-- so GetRecentLogs sees a Warn the console never printed.

	-- The log ring is a process singleton shared by every spec in the run, and the
	-- warning is latched per SERVER -- so each harness contributes at most one line
	-- and the newest is this test's. Scanning forward would return the previous
	-- test's line and assert against the wrong template, which is how the first
	-- draft of this file passed one test using another's data.
	local function oversizeLine()
		local logs = Scribe.GetRecentLogs()
		for i = #logs, 1, -1 do
			if logs[i].Code == "OUTBOUND_OVERSIZE" then
				return logs[i]
			end
		end
		return nil
	end

	itRunning("names the frame kind and the roots that made it large", function()
		-- A budget small enough that an ordinary fixture crosses the fragment
		-- threshold, so the spec exercises the real warning rather than needing a
		-- megabyte of data to reach it.
		local harness = TestCtx.make({
			AutoPump = false,
			Options = { MaxOutboundBytes = 1024 },
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Bag = {},
				Cache = Scribe.Session({}),
			},
		})
		local player, _entry, serverData = harness.Join()
		for i = 1, 900 do
			serverData.Cache[`sess_{i}_paddingpadding`].Set(i)
		end
		for i = 1, 20 do
			serverData.Bag[`bag_{i}`].Set(i)
		end
		harness.Transport.LocalPlayer = player
		harness.SendHello(player)

		local line = oversizeLine()
		expect(line).to.be.ok()
		-- The frame KIND: before this, the line said neither which frame nor which root.
		expect(`frame={line.Context.Frame}`).to.equal("frame=Init")
		-- The dominant root, named, and flagged as absent from ProfileSize.
		expect(string.find(line.Context.Roots, "Cache=", 1, true) ~= nil).to.equal(true)
		expect(string.find(line.Context.Roots, "not persisted", 1, true) ~= nil).to.equal(true)
		-- Ranked by bytes: Cache dwarfs Bag, so Cache is first.
		local cacheAt = string.find(line.Context.Roots, "Cache=", 1, true)
		local bagAt = string.find(line.Context.Roots, "Bag=", 1, true)
		expect(`cacheBeforeBag={bagAt == nil or cacheAt < bagAt}`).to.equal("cacheBeforeBag=true")
		-- Scribe's own roots are 16 and 29 bytes and are never the answer.
		expect(string.find(line.Context.Roots, "_Scribe", 1, true)).to.equal(nil)
		harness.Cleanup()
	end)

	itRunning("does not call a persisted root unpersisted", function()
		local harness = TestCtx.make({
			AutoPump = false,
			Options = { MaxOutboundBytes = 1024 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Bag = {} },
		})
		local player, _entry, serverData = harness.Join()
		for i = 1, 900 do
			serverData.Bag[`bag_{i}_paddingpadding`].Set(i)
		end
		harness.Transport.LocalPlayer = player
		harness.SendHello(player)

		local line = oversizeLine()
		expect(line).to.be.ok()
		expect(string.find(line.Context.Roots, "Bag=", 1, true) ~= nil).to.equal(true)
		-- The annotation is a claim about PERSISTENCE, and Bag persists.
		expect(string.find(line.Context.Roots, "not persisted", 1, true)).to.equal(nil)
		harness.Cleanup()
	end)

	itRunning("the span attribution is exact, not an estimate", function()
		-- Spans come from the writer's own offsets, so they must account for every
		-- byte of the frame except its 3-byte header (type + u16 op count). A
		-- re-encoding implementation would over-count by one header per root.
		local harness = TestCtx.make({
			AutoPump = false,
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Bag = {}, Cache = Scribe.Session({}) },
		})
		local _p, _e, serverData = harness.Join()
		for i = 1, 400 do
			serverData.Cache[`k_{i}_paddingpadding`].Set(i)
			serverData.Bag[`b_{i}`].Set(i)
		end
		local compiled = harness.Compiled
		local ops = {
			{ Kind = "Set", Path = { "Coins" }, Value = 7 },
			{ Kind = "Set", Path = { "Bag" }, Value = serverData.Bag.Get() },
			{ Kind = "Set", Path = { "Cache" }, Value = serverData.Cache.Get() },
		}
		local spans = {}
		local frame = Wire.EncodeOpsFrame(Wire.Frames.Init, compiled, ops, nil, spans)
		local sum = 0
		for _, n in spans do
			sum += n
		end
		expect(`spans={#spans} sum+header={sum + 3} frame={buffer.len(frame)}`).to.equal(
			`spans=3 sum+header={buffer.len(frame)} frame={buffer.len(frame)}`
		)
		-- And the frame is byte-identical to one encoded without spans.
		local plain = Wire.EncodeOpsFrame(Wire.Frames.Init, compiled, ops)
		expect(buffer.tostring(plain) == buffer.tostring(frame)).to.equal(true)
		harness.Cleanup()
	end)

	itRunning("JoinBytes counts the whole handshake, not just the Init", function()
		-- The owner Init is the smaller half on a Shared template: the SharedInit
		-- fan-out that follows it is one frame per already-ready player.
		Metrics.Reset()
		local harness = TestCtx.make({
			AutoPump = false,
			Template = { Pub = Scribe.Shared(Scribe.Session({})) },
		})
		local players, datas = {}, {}
		for i = 1, 4 do
			local p, _e, d = harness.Join(94100 + i)
			table.insert(players, p)
			table.insert(datas, d)
		end
		for _, d in datas do
			for i = 1, 300 do
				d.Pub[`s_{i}_paddingpad`].Set(i)
			end
		end
		harness.Transport.LocalPlayer = players[1]
		for _, p in players do
			harness.SendHello(p)
		end

		local m = Scribe.GetMetrics()
		local join, handshakes = m.JoinBytes, m.Handshakes
		expect(join).to.be.ok()
		expect(`count={join.Count} handshakes={handshakes}`).to.equal(`count={handshakes} handshakes={handshakes}`)
		-- The LAST player to join snapshots three other players, so its handshake
		-- must be strictly larger than its own Init alone.
		local ownInit = 0
		for _, sent in harness.Transport.SentToClientLog do
			if buffer.readu8(sent.Bytes, 0) == Wire.Frames.Init then
				ownInit = math.max(ownInit, buffer.len(sent.Bytes))
			end
		end
		expect(`joinMaxExceedsInit={join.Max > ownInit}`).to.equal("joinMaxExceedsInit=true")
		harness.Cleanup()
	end)

	itRunning("attributes the frame that shipped, not the one that failed", function()
		-- sendInit's fallback: when the whole-snapshot encode throws, it probes each
		-- root, drops the offenders and re-encodes the remainder. The attribution
		-- must describe THAT frame -- naming a root the client never received would
		-- send someone to trim data that is not on the wire.
		--
		-- Nothing else in the suite reaches this branch; it was uncovered until now.
		local harness = TestCtx.make({
			AutoPump = false,
			Options = { MaxOutboundBytes = 1024 },
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Bag = {},
				Deep = {},
			},
		})
		local player, entry, serverData = harness.Join()
		for i = 1, 900 do
			serverData.Bag[`bag_{i}_paddingpadding`].Set(i)
		end
		-- Past the generic codec's depth cap of 24, written straight into the store
		-- so it is the SNAPSHOT that refuses rather than the write.
		local deep = {}
		local cursor = deep
		for _ = 1, 30 do
			cursor.n = {}
			cursor = cursor.n
		end
		cursor.leaf = 1
		entry.LiveData.Deep = deep

		harness.Transport.LocalPlayer = player
		harness.SendHello(player)

		local dropped = 0
		for _, e in Scribe.GetRecentLogs() do
			if e.Code == "SNAPSHOT_ROOT_DROPPED" then
				dropped += 1
			end
		end
		expect(`dropped={dropped}`).to.equal("dropped=1")

		local line = oversizeLine()
		expect(line).to.be.ok()
		-- Bag shipped and is named; Deep was dropped and must not be.
		expect(string.find(line.Context.Roots, "Bag=", 1, true) ~= nil).to.equal(true)
		expect(string.find(line.Context.Roots, "Deep", 1, true)).to.equal(nil)
		-- The client still loaded, which is what the fallback exists for.
		expect(entry.HandshakeReady).to.equal(true)
		harness.Cleanup()
	end)
end
