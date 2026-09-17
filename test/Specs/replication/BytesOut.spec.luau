--!nonstrict
-- BytesOut: bytes handed to the transport, summed over every recipient.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Wire = require(ScribeRoot.Internal.Wire)
	local Clock = require(ScribeRoot.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Reassemble = require(Root.Test.Helpers.Reassemble)

	local realMonotonic = Clock.Monotonic
	afterEach(function()
		Clock.Install({ Monotonic = realMonotonic })
	end)

	it("counts a unicast once, a broadcast per session, and a shared diff per other player", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0), Public = Scribe.Shared({ Title = Scribe.String("") }) },
			Options = { ServerStore = { Wave = Scribe.Int(0) } },
		})
		local a, _, dataA = harness.Join(92001)
		local b = harness.Join(92002)
		local c = harness.Join(92003)
		for _, player in { a, b, c } do
			harness.SendHello(player)
		end
		harness.Step()

		local function bytesOut(): number
			return Scribe.GetMetrics().BytesOut or 0
		end
		--- Length of the last frame of `frameType` sent to `player` (nil: any recipient).
		local function lastFrameLen(player, frameType: number): number
			local sent = harness.Transport:FramesFor(player)
			for i = #sent, 1, -1 do
				if buffer.readu8(sent[i].Bytes, 0) == frameType then
					return buffer.len(sent[i].Bytes)
				end
			end
			return -1
		end

		local base = bytesOut()
		dataA.Coins.Set(1)
		harness.Step()
		local unicast = bytesOut() - base
		local diffLen = lastFrameLen(a, Wire.Frames.Diff)

		base = bytesOut()
		harness.Data.ServerStore.Wave.Set(1)
		harness.Step()
		local broadcast = bytesOut() - base
		local storeLen = lastFrameLen(nil, Wire.Frames.Diff)

		base = bytesOut()
		dataA.Public.Title.Set("x")
		harness.Step()
		local shared = bytesOut() - base
		-- Two SharedDiffs plus the owner's own Diff.
		local sharedExpected = lastFrameLen(b, Wire.Frames.SharedDiff) * 2 + lastFrameLen(a, Wire.Frames.Diff)
		harness.Cleanup()
		expect(`unicast={unicast}/{diffLen} broadcast={broadcast}/{storeLen * 3} shared={shared}/{sharedExpected}`).to.equal(
			`unicast={diffLen}/{diffLen} broadcast={storeLen * 3}/{storeLen * 3} shared={sharedExpected}/{sharedExpected}`
		)
	end)

	--- One player under the smallest budget, so a 900-byte write splits.
	local function fragmentedHarness()
		local harness = TestCtx.make({
			Template = { Note = Scribe.String("", { MaxLength = 1000 }) },
			Options = { MaxOutboundBytes = 256 },
		})
		local a, _, data = harness.Join(92004)
		harness.SendHello(a)
		harness.Step()
		return harness, a, data
	end

	--- Bytes of every fragment sent to `player` after `from` entries of the transport log.
	local function fragmentBytes(harness, player, from: number): (number, number)
		local total, count = 0, 0
		local raw = harness.Transport:FramesFor(player)
		for i = from + 1, #raw do
			if buffer.readu8(raw[i].Bytes, 0) == Wire.Frames.Fragment then
				total += buffer.len(raw[i].Bytes)
				count += 1
			end
		end
		return total, count
	end

	it("counts a fragmented frame as the buffers the transport accepted, headers included", function()
		local harness, a, data = fragmentedHarness()
		local from = #harness.Transport:FramesFor(a)
		local base = Scribe.GetMetrics().BytesOut or 0
		data.Note.Set(string.rep("x", 900))
		harness.Step()
		local counted = (Scribe.GetMetrics().BytesOut or 0) - base
		local accepted, fragments = fragmentBytes(harness, a, from)
		local logical = Reassemble.Logical(harness.Transport:FramesFor(a))
		local payload = buffer.len(logical[#logical].Bytes)
		harness.Cleanup()
		expect(`fragments={fragments} headers={accepted > payload} counted={counted}/{accepted}`).to.equal(
			`fragments={fragments} headers=true counted={accepted}/{accepted}`
		)
	end)

	it("counts the fragments the transport accepted before it refused one", function()
		local harness, a, data = fragmentedHarness()
		local from = #harness.Transport:FramesFor(a)
		local transport = harness.Transport
		local realSend = transport.SendToClient
		local sends = 0
		transport.SendToClient = function(self, player, bytes)
			sends += 1
			if sends == 2 then
				error("refused")
			end
			return realSend(self, player, bytes)
		end
		local base = Scribe.GetMetrics().BytesOut or 0
		data.Note.Set(string.rep("x", 900))
		harness.Step()
		transport.SendToClient = realSend
		local counted = (Scribe.GetMetrics().BytesOut or 0) - base
		local accepted, fragments = fragmentBytes(harness, a, from)
		harness.Cleanup()
		expect(`fragments={fragments} counted={counted}/{accepted}`).to.equal(
			`fragments=1 counted={accepted}/{accepted}`
		)
	end)

	--- Three ready players, a store and a shared root, under the smallest budget.
	local function fragmentedFanout()
		local harness = TestCtx.make({
			Template = { Public = Scribe.Shared({ Title = Scribe.String("", { MaxLength = 1000 }) }) },
			Options = { ServerStore = { Note = Scribe.String("", { MaxLength = 1000 }) }, MaxOutboundBytes = 256 },
		})
		local a, _, dataA = harness.Join(92005)
		local b = harness.Join(92006)
		local c = harness.Join(92007)
		for _, player in { a, b, c } do
			harness.SendHello(player)
		end
		harness.Step()
		return harness, dataA, b
	end

	it("counts a fragmented broadcast per session, and only the parts accepted", function()
		local harness = fragmentedFanout()
		local from = #harness.Transport:FramesFor(nil)
		local base = Scribe.GetMetrics().BytesOut or 0
		harness.Data.ServerStore.Note.Set(string.rep("x", 900))
		harness.Step()
		local whole = (Scribe.GetMetrics().BytesOut or 0) - base
		local accepted, fragments = fragmentBytes(harness, nil, from)
		-- Then the transport refuses the second part of the next one.
		local transport = harness.Transport
		local realBroadcast = transport.SendToAllClients
		local sends = 0
		transport.SendToAllClients = function(self, bytes)
			sends += 1
			if sends == 2 then
				error("refused")
			end
			return realBroadcast(self, bytes)
		end
		from = #harness.Transport:FramesFor(nil)
		base = Scribe.GetMetrics().BytesOut or 0
		harness.Data.ServerStore.Note.Set(string.rep("y", 900))
		harness.Step()
		transport.SendToAllClients = realBroadcast
		local partial = (Scribe.GetMetrics().BytesOut or 0) - base
		local firstPart = fragmentBytes(harness, nil, from)
		harness.Cleanup()
		expect(`fragments={fragments} whole={whole}/{accepted * 3} partial={partial}/{firstPart * 3}`).to.equal(
			`fragments={fragments} whole={accepted * 3}/{accepted * 3} partial={firstPart * 3}/{firstPart * 3}`
		)
	end)

	it("counts a fragmented shared diff per other player", function()
		local harness, dataA, b = fragmentedFanout()
		local a = harness.Ctx.Persistence.EntryForUserId(92005).Player
		local fromB = #harness.Transport:FramesFor(b)
		local fromA = #harness.Transport:FramesFor(a)
		local base = Scribe.GetMetrics().BytesOut or 0
		dataA.Public.Title.Set(string.rep("x", 900))
		harness.Step()
		local counted = (Scribe.GetMetrics().BytesOut or 0) - base
		-- Two SharedDiffs and the owner's own Diff, all fragmented.
		local toB, fragments = fragmentBytes(harness, b, fromB)
		local toOwner = fragmentBytes(harness, a, fromA)
		harness.Cleanup()
		expect(`fragments={fragments} counted={counted}/{toB * 2 + toOwner}`).to.equal(
			`fragments={fragments} counted={toB * 2 + toOwner}/{toB * 2 + toOwner}`
		)
	end)

	it("attributes every byte to its frame kind, and a repair handshake to Resync as well", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0), Public = Scribe.Shared({ Title = Scribe.String("") }) },
		})
		local function counter(name: string): number
			return Scribe.GetMetrics()[name] or 0
		end
		local resyncAtStart = counter("BytesOutResync")
		local a, entryA, dataA = harness.Join(92008)
		local b = harness.Join(92009)
		harness.SendHello(a)
		harness.SendHello(b)
		harness.Step()
		-- A first handshake is not a repair.
		local firstJoin = counter("BytesOutResync") - resyncAtStart
		harness.Data.Command("Ping", {}, function()
			return true
		end)
		--- Bytes of every frame of `frameType` sent to `player` after `from` log entries.
		local function bytesOfKind(player, frameType: number, from: number): number
			local total = 0
			local raw = harness.Transport:FramesFor(player)
			for i = from + 1, #raw do
				if buffer.readu8(raw[i].Bytes, 0) == frameType then
					total += buffer.len(raw[i].Bytes)
				end
			end
			return total
		end

		local diffBefore, sharedBefore = counter("BytesOutDiff"), counter("BytesOutSharedDiff")
		local fromA, fromB = #harness.Transport:FramesFor(a), #harness.Transport:FramesFor(b)
		dataA.Coins.Set(1)
		dataA.Public.Title.Set("x")
		harness.Step()
		local diff = counter("BytesOutDiff") - diffBefore
		local shared = counter("BytesOutSharedDiff") - sharedBefore
		local diffSent = bytesOfKind(a, Wire.Frames.Diff, fromA)
		local sharedSent = bytesOfKind(b, Wire.Frames.SharedDiff, fromB)

		local replyBefore = counter("BytesOutCommandReply")
		fromA = #harness.Transport:FramesFor(a)
		local w = Wire.NewWriter(64)
		Wire.U8(w, Wire.Frames.Command)
		Wire.U32(w, 1)
		Wire.Str(w, "Ping")
		Wire.U8(w, 0)
		Wire.Str(w, "")
		local reader = Wire.NewReader(Wire.Finish(w))
		Wire.RU8(reader)
		harness.Ctx.Commands.HandleFrame(entryA, reader)
		local reply = counter("BytesOutCommandReply") - replyBefore
		local replySent = bytesOfKind(a, Wire.Frames.CommandReply, fromA)

		local initBefore, resyncBefore = counter("BytesOutInit"), counter("BytesOutResync")
		fromA = #harness.Transport:FramesFor(a)
		harness.Ctx.Replication.RequestResync(entryA, "Spec")
		harness.Step()
		local init = counter("BytesOutInit") - initBefore
		local resync = counter("BytesOutResync") - resyncBefore
		local initSent = bytesOfKind(a, Wire.Frames.Init, fromA)
		-- A repair handshake is the Init plus the other players' SharedInits.
		local handshake = initSent + bytesOfKind(a, Wire.Frames.SharedInit, fromA)
		harness.Cleanup()
		expect(
			`diff={diff}/{diffSent} shared={shared}/{sharedSent} reply={reply}/{replySent} init={init}/{initSent} resync={resync}/{handshake} firstJoin={firstJoin}`
		).to.equal(
			`diff={diffSent}/{diffSent} shared={sharedSent}/{sharedSent} reply={replySent}/{replySent} init={initSent}/{initSent} resync={handshake}/{handshake} firstJoin=0`
		)
	end)

	it("counts a repair by what the transport accepted, and never a retried first join", function()
		local offset = 0
		Clock.Install({
			Monotonic = function()
				return realMonotonic() + offset
			end,
		})
		local harness = TestCtx.make({
			Template = { Note = Scribe.String("", { MaxLength = 1000 }) },
			Options = { MaxOutboundBytes = 256 },
		})
		local p, entry, data = harness.Join(92010)
		data.Note.Set(string.rep("x", 900))
		local transport = harness.Transport
		local realSend = transport.SendToClient
		--- Refuses the n-th send from now, then steps aside.
		local function refuseAt(n: number)
			local sends = 0
			transport.SendToClient = function(self, player, bytes)
				sends += 1
				if sends == n then
					transport.SendToClient = realSend
					error("refused")
				end
				return realSend(self, player, bytes)
			end
		end
		local function resync(): number
			return Scribe.GetMetrics().BytesOutResync or 0
		end

		-- A refused first join retried by a Hello is no repair.
		local base = resync()
		refuseAt(1)
		harness.SendHello(p)
		local afterFailedJoin = resync() - base
		harness.SendHello(p)
		harness.Step()
		local afterRetry = resync() - base
		local inits = #harness.FramesFor(p, Wire.Frames.Init)

		-- A repair refused on its second fragment counts the first; the retry counts every fragment.
		local from = #transport:FramesFor(p)
		base = resync()
		harness.Ctx.Replication.RequestResync(entry, "Spec")
		refuseAt(2)
		harness.Step()
		local partial = resync() - base
		local firstPart = fragmentBytes(harness, p, from)
		offset += 6
		from = #transport:FramesFor(p)
		base = resync()
		harness.Step()
		local full = resync() - base
		local accepted = fragmentBytes(harness, p, from)
		local logical = Reassemble.Logical(transport:FramesFor(p))
		local payload = buffer.len(logical[#logical].Bytes)
		harness.Cleanup()
		expect(
			`failedJoin={afterFailedJoin} retry={afterRetry} inits={inits} partial={partial}/{firstPart} full={full}/{accepted} headers={accepted > payload}`
		).to.equal(
			`failedJoin=0 retry=0 inits=1 partial={firstPart}/{firstPart} full={accepted}/{accepted} headers=true`
		)
	end)

	it("attributes a repair even when a synchronous transport re-enters with another handshake", function()
		local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) } })
		local a, entryA = harness.Join(92011)
		local b = harness.Join(92012)
		harness.SendHello(a)
		harness.Step()
		local transport = harness.Transport
		local realSend = transport.SendToClient
		-- B's Hello arrives inside A's repair send.
		local reentered = false
		transport.SendToClient = function(self, player, bytes)
			if not reentered and player == a then
				reentered = true
				harness.SendHello(b)
			end
			return realSend(self, player, bytes)
		end
		local from = #transport:FramesFor(a)
		local base = Scribe.GetMetrics().BytesOutResync or 0
		harness.Ctx.Replication.RequestResync(entryA, "Spec")
		harness.Step()
		transport.SendToClient = realSend
		local resync = (Scribe.GetMetrics().BytesOutResync or 0) - base
		local raw = transport:FramesFor(a)
		local initLen = 0
		for i = from + 1, #raw do
			if buffer.readu8(raw[i].Bytes, 0) == Wire.Frames.Init then
				initLen += buffer.len(raw[i].Bytes)
			end
		end
		local bInits = #harness.FramesFor(b, Wire.Frames.Init)
		harness.Cleanup()
		expect(`reentered={reentered} bInits={bInits} resync={resync}/{initLen}`).to.equal(
			`reentered=true bInits=1 resync={initLen}/{initLen}`
		)
	end)
end
