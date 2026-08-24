--!nonstrict
-- Fragment reassembly, driven through a REAL Client instance. An earlier draft
-- of this file tested a hand-copied reassembler and four mutations to the shipped
-- one survived it; every case below injects crafted frames into the real client
-- listener instead.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Metrics = require(ScribeRoot.Internal.Metrics)

	-- Counter deltas, not absolutes: Metrics is a process singleton shared by every
	-- spec in the run.
	local function counters()
		local m = Metrics.Get()
		return (m.FragmentsRefused or 0), (m.FramesReassembled or 0)
	end

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- Wire.Fragment streams so the unicast send path never materialises a second
	-- copy of a large frame; a spec wants the list, so it collects one.
	local function fragmentsOf(bytes: buffer, budget: number, seq: number)
		local out = {}
		local split = Wire.Fragment(bytes, budget, seq, function(part)
			table.insert(out, part)
			return true
		end)
		return if split == nil then nil else out
	end

	local function tpl()
		return { Coins = Scribe.Int(0, { Min = 0 }), Bag = Scribe.DictOf(Scribe.Int(0, { Min = 0 })) }
	end

	-- A loaded client plus a big Diff frame, pre-fragmented, ready to inject
	-- piecemeal. The frame is built by the REAL encoder so its layout cannot drift
	-- from the shipped one.
	local function loaded(budget: number)
		local harness = TestCtx.make({ AutoPump = true, Template = tpl() })
		local player, entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)
		local ops = { { Kind = "Set", Path = { "Coins" }, Value = 777 } }
		for i = 1, 400 do
			table.insert(ops, { Kind = "Set", Path = { "Bag", `key_{i}_padpadpadpad` }, Value = i })
		end
		local frame = Wire.EncodeOpsFrame(Wire.Frames.Diff, harness.Compiled, ops)
		local parts = fragmentsOf(frame, budget, 1)
		return harness, clientData, frame, parts, entry, serverData
	end

	itRunning("reassembles a fragmented Diff into the same mirror as the whole frame", function()
		local harness, clientData, frame, parts = loaded(512)
		expect(#parts > 8).to.equal(true)
		local refused0, done0 = counters()
		for _, part in parts do
			expect(buffer.len(part) <= 512).to.equal(true)
			harness.Transport:InjectToClient(part)
		end
		local refused1, done1 = counters()
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=0 reassembled=1")
		expect(`coins={clientData.Coins.Get()} k7={clientData.Bag["key_7_padpadpadpad"].Get()}`).to.equal(
			"coins=777 k7=7"
		)
		-- and it matches applying the unfragmented frame to a second client
		harness.Cleanup()

		local h2 = TestCtx.make({ AutoPump = true, Template = tpl() })
		local p2 = h2.Join()
		h2.Transport.LocalPlayer = p2
		local c2 = Client.new(h2.Options, h2.Compiled)
		h2.Transport:InjectToClient(frame)
		expect(`coins={c2.Coins.Get()} k7={c2.Bag["key_7_padpadpadpad"].Get()}`).to.equal("coins=777 k7=7")
		h2.Cleanup()
	end)

	itRunning("a lost middle fragment is detected, and the next whole frame still lands", function()
		local harness, clientData, _frame, parts = loaded(512)
		-- Drop fragment 3. Without the index check the later pieces would be written
		-- at the wrong offset and still reach `total`, decoding as garbage.
		local refused0, done0 = counters()
		for i, part in parts do
			if i ~= 3 then
				harness.Transport:InjectToClient(part)
			end
		end
		local refused1, done1 = counters()
		-- The gap must be REFUSED, not merely left incomplete: an implementation
		-- that stops checking the index writes the surviving pieces at the wrong
		-- offsets and a replay can still drive it to `total` with scrambled bytes.
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		-- The client is not poisoned: a complete sequence afterwards applies.
		for _, part in parts do
			harness.Transport:InjectToClient(part)
		end
		expect(`coins={clientData.Coins.Get()} k7={clientData.Bag["key_7_padpadpadpad"].Get()}`).to.equal(
			"coins=777 k7=7"
		)
		harness.Cleanup()
	end)

	itRunning("a lost first fragment starts nothing", function()
		local harness, clientData, _frame, parts = loaded(512)
		for i = 2, #parts do
			harness.Transport:InjectToClient(parts[i])
		end
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("a duplicated fragment is refused rather than double-written", function()
		local harness, clientData, _frame, parts = loaded(512)
		local refused0, done0 = counters()
		harness.Transport:InjectToClient(parts[1])
		harness.Transport:InjectToClient(parts[2])
		harness.Transport:InjectToClient(parts[2]) -- replay
		for i = 3, #parts do
			harness.Transport:InjectToClient(parts[i])
		end
		local refused1, done1 = counters()
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("a frame declaring more than the reassembly cap allocates nothing", function()
		local harness, clientData, _frame, parts = loaded(512)
		-- Same first fragment, but claiming a gigabyte. Refused before the buffer is
		-- created; without the cap this allocates 1 GiB from one 512-byte frame.
		local head = parts[1]
		local forged = buffer.create(buffer.len(head))
		buffer.copy(forged, 0, head, 0, buffer.len(head))
		buffer.writeu32(forged, 3, 1024 * 1024 * 1024)
		local refused0, done0 = counters()
		harness.Transport:InjectToClient(forged)
		local refused1, done1 = counters()
		-- Refused at the header, before buffer.create. Without the cap this is a
		-- 1 GiB allocation driven by a 512-byte frame.
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		for i = 2, #parts do
			harness.Transport:InjectToClient(parts[i])
		end
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("a fragment that would write past the declared total is refused", function()
		local harness, clientData, _frame, parts = loaded(512)
		-- Deliver everything but the tail, then send a FULL-SIZE piece carrying the
		-- tail's index. The sequence check passes -- correct index, correct total --
		-- so only the length check stands between this and a buffer overrun.
		for i = 1, #parts - 1 do
			harness.Transport:InjectToClient(parts[i])
		end
		expect(buffer.len(parts[1]) > buffer.len(parts[#parts])).to.equal(true)
		local fat = buffer.create(buffer.len(parts[1]))
		buffer.copy(fat, 0, parts[1], 0, buffer.len(parts[1]))
		buffer.writeu16(fat, 7, #parts - 1) -- the tail's 0-based index
		local refused0, done0 = counters()
		harness.Transport:InjectToClient(fat)
		local refused1, done1 = counters()
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("an unfragmented frame arriving mid-sequence does not disturb reassembly", function()
		local harness, clientData, _frame, parts = loaded(512)
		harness.Transport:InjectToClient(parts[1])
		-- A Status frame between pieces: a real interleaving, since sendStatus(nil)
		-- broadcasts through the SendToAllClients path with no readiness gate.
		local w = Wire.NewWriter(4)
		Wire.U8(w, Wire.Frames.Status)
		Wire.U8(w, 0)
		harness.Transport:InjectToClient(Wire.Finish(w))
		for i = 2, #parts do
			harness.Transport:InjectToClient(parts[i])
		end
		expect(`coins={clientData.Coins.Get()} k7={clientData.Bag["key_7_padpadpadpad"].Get()}`).to.equal(
			"coins=777 k7=7"
		)
		harness.Cleanup()
	end)

	itRunning("a reassembled frame that is itself a Fragment is refused", function()
		local harness, clientData = loaded(512)
		-- Wrap a Fragment-typed payload in one complete fragment. Re-entering on it
		-- is what an unbounded implementation would do.
		local inner = buffer.create(16)
		buffer.writeu8(inner, 0, Wire.Frames.Fragment)
		local outer = buffer.create(Wire.FRAGMENT_HEADER + 16)
		buffer.writeu8(outer, 0, Wire.Frames.Fragment)
		buffer.writeu32(outer, 1, 16)
		buffer.writeu16(outer, 5, 0)
		buffer.copy(outer, Wire.FRAGMENT_HEADER, inner, 0, 16)
		local refused0, done0 = counters()
		harness.Transport:InjectToClient(outer)
		local refused1, done1 = counters()
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("two interleaved logical frames never splice into a mirror", function()
		-- The failure this whole field exists for. Without a sequence id, two frames
		-- of equal length interleave into a buffer whose indices ascend correctly and
		-- whose length matches -- and it DECODES, producing a mirror holding a
		-- combination of values present in neither frame, with no error and no log.
		-- Scribe never interleaves two fragmented sends, because sends are
		-- synchronous and ScribeTransport forbids a yielding adapter; this asserts
		-- what happens when an adapter breaks that contract anyway.
		local harness = TestCtx.make({ AutoPump = true, Template = tpl() })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		local function frameFor(coins: number, tag: string)
			local ops = { { Kind = "Set", Path = { "Coins" }, Value = coins } }
			for i = 1, 200 do
				table.insert(ops, { Kind = "Set", Path = { "Bag", `{tag}_{i}_padpadpad` }, Value = i })
			end
			return Wire.EncodeOpsFrame(Wire.Frames.Diff, harness.Compiled, ops)
		end
		-- Both coin values are under 128 so they varint to one byte and the two
		-- frames come out the same length: total and count then match, and `seq` is
		-- the only field left to tell them apart.
		local a, b = frameFor(111, "aaa"), frameFor(122, "bbb")
		expect(`aLen={buffer.len(a)} bLen={buffer.len(b)}`).to.equal(`aLen={buffer.len(a)} bLen={buffer.len(a)}`)
		local pa = fragmentsOf(a, 512, 7) :: { buffer }
		local pb = fragmentsOf(b, 512, 8) :: { buffer }
		expect(`counts={#pa}/{#pb}`).to.equal(`counts={#pa}/{#pa}`)

		local refused0, done0 = counters()
		-- A0 A1 B2 B3 ... : ascending indices, matching total, two different frames.
		harness.Transport:InjectToClient(pa[1])
		harness.Transport:InjectToClient(pa[2])
		for i = 3, #pb do
			harness.Transport:InjectToClient(pb[i])
		end
		local refused1, done1 = counters()
		expect(`refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal("refused=1 reassembled=0")
		expect(`coins={clientData.Coins.Get()}`).to.equal("coins=0")
		harness.Cleanup()
	end)

	itRunning("a tail loss followed by a head loss never splices", function()
		-- The second, independent splice path: A[0..k-1] then B[k..n-1]. Index 0 --
		-- the only reset trigger without a sequence id -- is exactly the fragment
		-- that was dropped, so every surviving index still ascends.
		local harness = TestCtx.make({ AutoPump = true, Template = tpl() })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		local function frameFor(coins: number, tag: string)
			local ops = { { Kind = "Set", Path = { "Coins" }, Value = coins } }
			for i = 1, 60 do
				table.insert(ops, { Kind = "Set", Path = { "Bag", `{tag}_{i}_padpadpad` }, Value = i })
			end
			return Wire.EncodeOpsFrame(Wire.Frames.Diff, harness.Compiled, ops)
		end
		local pa = fragmentsOf(frameFor(111, "aaa"), 400, 21) :: { buffer }
		local pb = fragmentsOf(frameFor(122, "bbb"), 400, 22) :: { buffer }
		for k = 2, #pa - 1 do
			local refused0, done0 = counters()
			for i = 1, k do
				harness.Transport:InjectToClient(pa[i])
			end
			for i = k + 1, #pb do
				harness.Transport:InjectToClient(pb[i])
			end
			local refused1, done1 = counters()
			expect(`k={k} refused={refused1 - refused0} reassembled={done1 - done0}`).to.equal(
				`k={k} refused=1 reassembled=0`
			)
			expect(`k={k} coins={clientData.Coins.Get()}`).to.equal(`k={k} coins=0`)
		end
		harness.Cleanup()
	end)

	itRunning("absorbs mutated fragment streams without throwing, and accounts for every one", function()
		-- The decode-side fuzz for the new header, built the way WireFuzz is: the
		-- frames come from the REAL fragmenter, so a layout change cannot quietly
		-- start mutating something else, and every case reaches acceptFragment by
		-- construction rather than by luck.
		--
		-- Unlike WireFuzz this is a CLIENT-side surface: only the server can raise
		-- OnClientEvent on the Down remote, so there is no attacker here and the
		-- contract being tested is "a corrupted stream costs the frame it corrupted
		-- and nothing else" -- never a throw, and never a mirror holding a value that
		-- was not sent.
		local SEED, CASES = 0x5C21BE, 600
		local state = bit32.bxor(SEED, 0x9E3779B9)
		local function rand(n: number): number
			state = bit32.bxor(state, bit32.lshift(state, 13))
			state = bit32.bxor(state, bit32.rshift(state, 17))
			state = bit32.bxor(state, bit32.lshift(state, 5))
			return state % n
		end

		local harness = TestCtx.make({ AutoPump = true, Template = tpl() })
		local player = harness.Join()
		harness.Transport.LocalPlayer = player
		local clientData = Client.new(harness.Options, harness.Compiled)

		local ops = { { Kind = "Set", Path = { "Coins" }, Value = 55 } }
		for i = 1, 120 do
			table.insert(ops, { Kind = "Set", Path = { "Bag", `fz_{i}_padpadpadpad` }, Value = i })
		end
		local clean = Wire.EncodeOpsFrame(Wire.Frames.Diff, harness.Compiled, ops)
		local parts = fragmentsOf(clean, 384, 3) :: { buffer }

		local applied, refusedTotal, seen = 0, 0, {}
		for case = 1, CASES do
			-- Mutate ONE fragment of a fresh copy of the stream, five ways.
			local mutated = {}
			for i, part in parts do
				local copy = buffer.create(buffer.len(part))
				buffer.copy(copy, 0, part, 0, buffer.len(part))
				mutated[i] = copy
			end
			local victim = rand(#mutated) + 1
			local kind = rand(5)
			seen[kind] = (seen[kind] or 0) + 1
			local target = mutated[victim]
			if kind == 0 then -- forge the declared length
				buffer.writeu32(target, 3, rand(0xFFFFFF))
			elseif kind == 1 then -- forge the index
				buffer.writeu16(target, 7, rand(0xFFFF))
			elseif kind == 2 then -- forge the sequence
				buffer.writeu16(target, 1, rand(0xFFFF))
			elseif kind == 3 then -- truncate
				local keep = rand(buffer.len(target))
				local short = buffer.create(keep)
				buffer.copy(short, 0, target, 0, keep)
				mutated[victim] = short
			else -- corrupt a payload byte
				if buffer.len(target) > Wire.FRAGMENT_HEADER then
					local at = Wire.FRAGMENT_HEADER + rand(buffer.len(target) - Wire.FRAGMENT_HEADER)
					buffer.writeu8(target, at, rand(256))
				end
			end

			local refusedBefore, rebuiltBefore = counters()
			clientData.Coins.Set(0)
			for _, part in mutated do
				local ok, err = pcall(function()
					harness.Transport:InjectToClient(part)
				end)
				-- Nothing may escape. The client's own listener pcalls handleFrame, so a
				-- throw reaching here means the reassembler unwound something the
				-- listener could not have caught.
				expect(`case={case} kind={kind} threw={not ok}: {tostring(err)}`).to.equal(
					`case={case} kind={kind} threw=false: nil`
				)
			end
			local refusedAfter, rebuiltAfter = counters()
			refusedTotal += refusedAfter - refusedBefore
			applied += rebuiltAfter - rebuiltBefore

			-- THE CONTRACT. A mutated stream may rebuild a frame or may not; what it
			-- may never do is put a value in the mirror that was never sent. Coins is
			-- either untouched (0, because a frame did not complete) or exactly the 55
			-- the real encoder wrote -- never anything in between, which is what a
			-- spliced or partly-overwritten buffer would produce.
			local coins = clientData.Coins.Get()
			expect(`case={case} kind={kind} coins={coins}`).to.equal(
				if coins == 0 then `case={case} kind={kind} coins=0` else `case={case} kind={kind} coins=55`
			)
			-- A clean stream still lands afterwards, so a mutated case cannot poison
			-- the next one.
			for _, part in parts do
				harness.Transport:InjectToClient(part)
			end
			expect(`case={case} recovered={clientData.Coins.Get()}`).to.equal(`case={case} recovered=55`)
		end

		-- Every mutator must have fired, or a dead one would inflate the headline.
		for kind = 0, 4 do
			expect(`kind={kind} fired={(seen[kind] or 0) > 0}`).to.equal(`kind={kind} fired=true`)
		end
		-- Both outcomes must be a real share of the run. Without this the test passes
		-- just as happily if every case were refused at the first byte, which would
		-- assert one branch 600 times and call it coverage.
		-- Measured at this seed: 353 refused, 120 rebuilt, the rest left incomplete.
		-- The rebuilt ones are mostly the payload-corruption mutator, which is the
		-- case that carries a damaged buffer all the way into Wire.DecodeOps.
		local floor = CASES // 10
		expect(`refused>{floor}={refusedTotal > floor}`).to.equal(`refused>{floor}=true`)
		expect(`rebuilt>{floor}={applied > floor}`).to.equal(`rebuilt>{floor}=true`)
		harness.Cleanup()
	end)
end
