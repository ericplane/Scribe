--!nonstrict
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function tpl()
		return {
			Coins = Scribe.Int(0, { Min = 0 }),
			Inventory = Scribe.DictOf({ Qty = Scribe.Int(0, { Min = 0 }), Lvl = Scribe.Int(0, { Min = 0 }) }),
		}
	end

	-- A transport that REFUSES anything over `cap`, the way a platform remote does.
	-- Nothing in test/Helpers or test/Sim models this, so without it no spec in the
	-- repo can observe an oversize outbound frame at all.
	local function capped(transport, cap)
		local inner = transport.SendToClient
		local refused = { n = 0, max = 0 }
		transport.SendToClient = function(self, player, bytes)
			if buffer.len(bytes) > cap then
				refused.n += 1
				refused.max = math.max(refused.max, buffer.len(bytes))
				error(`transport: payload of {buffer.len(bytes)} exceeds {cap}`, 0)
			end
			return inner(self, player, bytes)
		end
		return refused
	end

	itRunning("delivers a snapshot far larger than the transport will carry", function()
		local harness = TestCtx.make({ AutoPump = true, Template = tpl(), Options = { MaxOutboundBytes = 4096 } })
		local player, _entry, serverData = harness.Join()
		for i = 1, 3000 do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		serverData.Coins.Set(4242)
		local refused = capped(harness.Transport, 4096)
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		expect(`refused={refused.n}`).to.equal("refused=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=4242")
		local n = 0
		for _ in clientData.Inventory.Get() do
			n += 1
		end
		expect(`keys={n}`).to.equal("keys=3000")
		expect(clientData.Inventory["item_2500_abcdefghijkl"].Qty.Get()).to.equal(2500)

		local frames = harness.Transport.SentToClientLog
		local frag, maxLen = 0, 0
		for _, f in frames do
			maxLen = math.max(maxLen, buffer.len(f.Bytes))
			if buffer.readu8(f.Bytes, 0) == Wire.Frames.Fragment then
				frag += 1
			end
		end
		expect(frag > 10).to.equal(true)
		expect(maxLen <= 4096).to.equal(true)
		harness.Cleanup()
	end)

	itRunning("BASELINE without the fix: the same profile leaves the client unloaded", function()
		-- MaxOutboundBytes raised above the transport cap reproduces today's shipped
		-- behaviour: one oversize frame, refused, client never loads.
		local harness =
			TestCtx.make({ AutoPump = true, Template = tpl(), Options = { MaxOutboundBytes = 64 * 1024 * 1024 } })
		local player, _entry, serverData = harness.Join()
		for i = 1, 3000 do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		local refused = capped(harness.Transport, 4096)
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		expect(refused.n > 0).to.equal(true)
		expect(clientData.IsReady()).to.equal(false)
		harness.Cleanup()
	end)

	itRunning("an Init whose fragments only partly land does not mark the client ready", function()
		-- The failure this exists for: a transport that accepts some fragments and
		-- then refuses. Before, sendInit marked the client ready regardless, counted
		-- a Handshake, logged INIT_SENT and disarmed the one alarm -- for a client
		-- that then re-Hello'd forever with no mirror.
		local Metrics = require(ScribeRoot.Internal.Metrics)
		local harness = TestCtx.make({ AutoPump = true, Template = tpl(), Options = { MaxOutboundBytes = 4096 } })
		local player, entry, serverData = harness.Join()
		for i = 1, 3000 do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		local inner = harness.Transport.SendToClient
		local seen = 0
		harness.Transport.SendToClient = function(self, p, bytes)
			seen += 1
			if seen > 5 then
				error("transport: refused", 0)
			end
			return inner(self, p, bytes)
		end
		harness.Transport.LocalPlayer = player
		local before = Metrics.Get().InitSendFailed or 0
		local clientData = Client.new(harness.Options, harness.Compiled)
		local after = Metrics.Get().InitSendFailed or 0
		expect(`ready={entry.HandshakeReady} failed={after - before} clientReady={clientData.IsReady()}`).to.equal(
			"ready=false failed=1 clientReady=false"
		)
		harness.Cleanup()
	end)

	itRunning("ordinary traffic is not fragmented at the default budget", function()
		local harness = TestCtx.make({ AutoPump = false, Template = tpl() })
		local player, _entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		harness.SendHello(player)
		serverData.Coins.Set(9)
		serverData.Inventory.Sword.Qty.Set(1)
		harness.Step()
		local frag = 0
		for _, f in harness.Transport.SentToClientLog do
			if buffer.readu8(f.Bytes, 0) == Wire.Frames.Fragment then
				frag += 1
			end
		end
		expect(`fragments={frag}`).to.equal("fragments=0")
		harness.Cleanup()
	end)

	itRunning("each fragmented frame carries its own sequence id", function()
		-- The client tells two logical frames apart by `seq`, so the server must not
		-- reuse one. Read off the frames the REAL server produced, not hand-built.
		local harness = TestCtx.make({ AutoPump = false, Template = tpl(), Options = { MaxOutboundBytes = 1024 } })
		local player, _entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		harness.SendHello(player)
		local seen = {}
		local function collect()
			local out = {}
			for _, f in harness.Transport.SentToClientLog do
				if buffer.readu8(f.Bytes, 0) == Wire.Frames.Fragment then
					out[buffer.readu16(f.Bytes, 1)] = true
				end
			end
			return out
		end
		for round = 1, 3 do
			for i = 1, 200 do
				serverData.Inventory[`r{round}_item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 1 })
			end
			harness.Step()
		end
		seen = collect()
		local distinct = 0
		for _ in seen do
			distinct += 1
		end
		expect(`distinctSeqs>=3 -> {distinct >= 3}`).to.equal("distinctSeqs>=3 -> true")
		harness.Cleanup()
	end)

	itRunning("a failed Init un-takes the snapshot instead of leaving the queue to grow", function()
		-- FlushEntry flushes when HandshakeReady and clears when NOT QueueOpen. An
		-- entry that is neither matches no branch, so its queue would grow for the
		-- whole session, uncompacted, for a client that receives none of it.
		local harness = TestCtx.make({ AutoPump = true, Template = tpl(), Options = { MaxOutboundBytes = 4096 } })
		local player, entry, serverData = harness.Join()
		for i = 1, 3000 do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		local inner = harness.Transport.SendToClient
		local seen = 0
		harness.Transport.SendToClient = function(self, p, bytes)
			seen += 1
			if seen > 5 then
				error("transport: refused", 0)
			end
			return inner(self, p, bytes)
		end
		harness.Transport.LocalPlayer = player
		Client.new(harness.Options, harness.Compiled)
		expect(`ready={entry.HandshakeReady} queueOpen={entry.QueueOpen}`).to.equal("ready=false queueOpen=false")
		for round = 1, 4 do
			for i = 1, 50 do
				serverData.Coins.Set(i)
				serverData.Inventory[`later_{round}_{i}`].Set({ Qty = i, Lvl = 1 })
			end
			harness.Step()
			expect(`round={round} queued={#entry.Queue}`).to.equal(`round={round} queued=0`)
		end
		harness.Cleanup()
	end)

	itRunning("the op cap and the byte cap compose rather than replace each other", function()
		-- MAX_OPS_PER_FRAME is a u16 guard, not a size guard: EncodeOpsFrame raises
		-- past 65535 ops, and an encode that raises inside FlushEntry loses the ops
		-- for good because the queue was drained before it. So the byte budget is a
		-- layer BENEATH the op cap, never a replacement -- and an ordinary write loop
		-- reaches both. 59,999 distinct keys is one logical Diff; 60,001 is two; at a
		-- 64 KB budget neither puts a frame over the budget on the wire.
		for _, n in { 59999, 60001 } do
			local harness = TestCtx.make({
				AutoPump = false,
				Template = { Bag = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 200000 }) },
			})
			local player, _entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			harness.SendHello(player)
			local before = #harness.Transport.SentToClientLog
			for i = 1, n do
				serverData.Bag[`k{i}`].Set(i)
			end
			harness.Step()
			local over, wire = 0, 0
			for i = before + 1, #harness.Transport.SentToClientLog do
				local bytes = harness.Transport.SentToClientLog[i].Bytes
				wire += 1
				if buffer.len(bytes) > 65536 then
					over += 1
				end
			end
			expect(`n={n} overBudget={over} wireFrames>0={wire > 0}`).to.equal(`n={n} overBudget=0 wireFrames>0=true`)
			harness.Cleanup()
		end
	end)
	-- The BROADCAST half of fragmentation, which had no assertion behind it in
	-- either run mode.
	--
	-- Measured while adding these: across a whole run the server splits 27 frames
	-- under `lune run lune/run-tests` (18 Diff, 9 Init) and 51 under
	-- SCRIBE_FRAGMENT_ALL=1 (18 Diff, 17 Init, 12 SharedInit, 4 SharedDiff). So the
	-- Shared fan-out was fragmented ZERO times by the plain suite and 16 times by
	-- the env-var run -- and neither number was checked, because the specs that
	-- reached it hold no client. Dropping the FIRST fragment of every broadcast
	-- (`if #parts > 1 then table.remove(parts, 1) end` after the split in
	-- `broadcastBuffer`) left 1324/0 in BOTH modes.
	--
	-- Both directions are covered because they are different call sites with
	-- different recipients: the snapshot goes out of OnEntryReady and the diff out
	-- of flushSharedQueue, and only the second one can be re-sent.
	local function twoPlayers(budget: number)
		local harness = TestCtx.make({
			AutoPump = false,
			Template = { Pub = Scribe.Shared(Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 5000 })) },
			Options = { MaxOutboundBytes = budget },
		})
		-- B is ready FIRST, so it is a recipient of whatever A broadcasts next.
		local playerB = harness.Join(98402)
		harness.Transport.LocalPlayer = playerB
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.SendHello(playerB)
		harness.Transport:PumpToClient()
		return harness, clientB, playerB
	end

	-- Counts the fragments actually addressed to B, so a budget that stopped
	-- mattering fails the test instead of passing it vacuously.
	local function fragmentsTo(harness, player, from: number): number
		local n = 0
		for i = from + 1, #harness.Transport.SentToClientLog do
			local frame = harness.Transport.SentToClientLog[i]
			if frame.Player == player and buffer.readu8(frame.Bytes, 0) == Wire.Frames.Fragment then
				n += 1
			end
		end
		return n
	end

	local function mirrorSummary(clientB, ownerId: number, n: number): string
		local view = clientB.GetShared(ownerId)
		if view == nil or view.Pub == nil then
			return "mirror=absent"
		end
		local seen, wrong = 0, 0
		for i = 1, n do
			local got = view.Pub[`key_{i}_padpadpadpad`]
			if got == nil then
				continue
			end
			seen += 1
			if got ~= i then
				wrong += 1
			end
		end
		return `keys={seen}/{n} wrong={wrong}`
	end

	itRunning("a Shared SNAPSHOT too large to carry whole still reaches another player's mirror", function()
		local harness, clientB, playerB = twoPlayers(1024)
		local N = 400
		-- The snapshot is taken in OnEntryReady, which runs at LOAD -- so the data has
		-- to be in the stored profile before the join that broadcasts it, not written
		-- after. A first session writes it and leaves (which broadcasts SharedGone and
		-- clears B's mirror of A); the rejoin is the one under test.
		local playerA0, _entryA0, dataA0 = harness.Join(98401)
		for i = 1, N do
			dataA0.Pub[`key_{i}_padpadpadpad`].Set(i)
		end
		harness.Leave(playerA0)
		harness.Transport:PumpToClient()
		local before = #harness.Transport.SentToClientLog
		local _playerA = harness.Join(98401)
		local parts = fragmentsTo(harness, playerB, before)
		harness.Transport:PumpToClient()
		expect(`parts>1={parts > 1} {mirrorSummary(clientB, 98401, N)}`).to.equal(`parts>1=true keys={N}/{N} wrong=0`)
		harness.Cleanup()
	end)

	-- A transport's OWN declared ceiling, which wins when it is smaller than the
	-- configured budget. Replication reads `transport.MaxFrameBytes` once, inside
	-- Replication.new, and takes math.min of the two.
	--
	-- Nothing held that min(). Both specs that set MaxFrameBytes -- SimFragmentation
	-- :73 and :100 -- set MaxOutboundBytes to the SAME number, so math.min is a no-op
	-- in each, and test/Sim/Link.luau enforces the cap itself, which is what makes
	-- them pass either way. Measured: replacing the min with `maxOutbound = maxOutbound`
	-- left the whole suite at 1358 passed / 0 failed.
	local function declaring(cap: number?)
		local stub = StubTransport.new({ AutoPump = true })
		if cap ~= nil then
			(stub :: any).MaxFrameBytes = cap
		end
		return stub
	end

	-- The largest single buffer that reached the transport.
	local function largestSent(harness): number
		local max = 0
		for _, f in harness.Transport.SentToClientLog do
			max = math.max(max, buffer.len(f.Bytes))
		end
		return max
	end

	local function joinWithInventory(harness, records: number)
		local player, _entry, serverData = harness.Join()
		for i = 1, records do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		harness.Transport.LocalPlayer = player
		return Client.new(harness.Options, harness.Compiled)
	end

	itRunning("MEASURES the Init snapshot of a 1,000-record inventory", function()
		-- The number MaxOutboundBytes's default is justified against, measured here
		-- rather than asserted in prose. Both docs said "about 80 KB" with no
		-- reproduction; this is the template they now name.
		--
		-- The template is `tpl()` at the top of this file -- the shape the shipped
		-- templates guide teaches -- filled with 1,000 keys of the form
		-- `item_<i>_abcdefghijkl`, each holding { Qty, Lvl }.
		--
		-- Budget raised past any plausible result so the Init reaches the transport
		-- WHOLE: over MaxOutboundBytes it arrives as Fragment frames and the logical
		-- size is no longer one buffer.len.
		local harness = TestCtx.make({
			AutoPump = false,
			Template = tpl(),
			Options = { MaxOutboundBytes = 1048576 },
		})
		local player, _entry, serverData = harness.Join()
		for i = 1, 1000 do
			serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i, Lvl = 2 })
		end
		harness.Transport.LocalPlayer = player
		harness.SendHello(player)

		local initBytes = 0
		for _, f in harness.Transport.SentToClientLog do
			if buffer.readu8(f.Bytes, 0) == Wire.Frames.Init then
				initBytes = math.max(initBytes, buffer.len(f.Bytes))
			end
		end
		-- Exact, not a band. A band would let the encoder drift while the docs that
		-- quote this number stayed still; an exact figure fails here first, and
		-- whoever changes the encoder updates configuration.md and Replication.luau
		-- in the same commit.
		expect(`init={initBytes}`).to.equal("init=29810")
		harness.Cleanup()
	end)

	itRunning("a transport's smaller declared MaxFrameBytes wins over MaxOutboundBytes", function()
		-- The budget is generous and the CHANNEL is narrow: only the transport knows
		-- its own framing overhead, which is the whole reason the field exists.
		local harness = TestCtx.make({
			AutoPump = true,
			Transport = declaring(1024),
			Template = tpl(),
			Options = { MaxOutboundBytes = 65536 },
		})
		local clientData = joinWithInventory(harness, 400)
		local largest = largestSent(harness)
		-- Delivered whole despite being split: the ceiling is transparent.
		local seen = 0
		for _ in clientData.Inventory.Get() do
			seen += 1
		end
		expect(`largest<=1024={largest <= 1024} keys={seen}`).to.equal("largest<=1024=true keys=400")
		harness.Cleanup()
	end)

	itRunning("...and the same profile with no declared ceiling exceeds it, so that is not vacuous", function()
		-- Without this the test above would pass against a build that ignored
		-- MaxFrameBytes but never produced a frame over 1024 in the first place.
		local harness = TestCtx.make({
			AutoPump = true,
			Transport = declaring(nil),
			Template = tpl(),
			Options = { MaxOutboundBytes = 65536 },
		})
		joinWithInventory(harness, 400)
		expect(`largest>1024={largestSent(harness) > 1024}`).to.equal("largest>1024=true")
		harness.Cleanup()
	end)

	itRunning("a LARGER declared ceiling does not raise the configured budget", function()
		-- The other half of the min(). A transport that can carry more does not get
		-- to overrule a game that asked for smaller frames -- `maxOutbound = declaredMax`
		-- would pass the first test in this group and fail this one.
		local harness = TestCtx.make({
			AutoPump = true,
			Transport = declaring(65536),
			Template = tpl(),
			Options = { MaxOutboundBytes = 1024 },
		})
		joinWithInventory(harness, 400)
		expect(`largest<=1024={largestSent(harness) <= 1024}`).to.equal("largest<=1024=true")
		harness.Cleanup()
	end)

	itRunning("a Shared DIFF too large to carry whole still reaches another player's mirror", function()
		local harness, clientB, playerB = twoPlayers(1024)
		local N = 400
		local playerA, _entryA, dataA = harness.Join(98401)
		harness.SendHello(playerA)
		harness.Transport:PumpToClient()
		-- Written AFTER both handshakes, so this leaves as a SharedDiff broadcast
		-- rather than riding in the snapshot above.
		local before = #harness.Transport.SentToClientLog
		for i = 1, N do
			dataA.Pub[`key_{i}_padpadpadpad`].Set(i)
		end
		harness.Step()
		local parts = fragmentsTo(harness, playerB, before)
		harness.Transport:PumpToClient()
		expect(`parts>1={parts > 1} {mirrorSummary(clientB, 98401, N)}`).to.equal(`parts>1=true keys={N}/{N} wrong=0`)
		harness.Cleanup()
	end)
end
