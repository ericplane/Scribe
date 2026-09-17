--!nonstrict
-- A transport that writes Shared data from inside its send: a joiner sees another
-- player's write once, and the others do not miss the new player's.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TEMPLATE = { Public = Scribe.Shared({ Title = "" }) }

	--- Runs `write` once, from inside the send of the first `kind` frame addressed to `target`.
	local function writeDuringSend(harness, target, kind: number, write: () -> ())
		local realSend = harness.Transport.SendToClient
		local fired = false
		harness.Transport.SendToClient = function(self, player, bytes)
			if not fired and player == target and buffer.readu8(bytes, 0) == kind then
				fired = true
				write()
			end
			return realSend(self, player, bytes)
		end
	end

	it("hands a joiner another player's write made during its handshake exactly once", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local a, _, dataA = harness.Join(70201)
		harness.SendHello(a)
		local b = harness.Join(70202)
		harness.SendHello(b)
		harness.Step()
		local diffsToBBefore = #harness.FramesFor(b, Wire.Frames.SharedDiff)
		local j = harness.Join(70203)
		writeDuringSend(harness, j, Wire.Frames.Init, function()
			dataA.Public.Title.Set("mid-send")
		end)
		harness.SendHello(j)
		harness.Step()
		harness.Step()
		local inits = #harness.FramesFor(j, Wire.Frames.SharedInit)
		local diffsToJoiner = #harness.FramesFor(j, Wire.Frames.SharedDiff)
		local diffsToB = #harness.FramesFor(b, Wire.Frames.SharedDiff) - diffsToBBefore
		harness.Cleanup()
		expect(`sharedInits={inits} diffsToJoiner={diffsToJoiner} diffsToB={diffsToB}`).to.equal(
			"sharedInits=2 diffsToJoiner=0 diffsToB=1"
		)
	end)

	it("keeps a write made during the drain to a third client out of the joiner's snapshot", function()
		local harness = TestCtx.make({ Template = { Public = Scribe.Shared({ List = {} }) } })
		local a, _, dataA = harness.Join(70208)
		harness.SendHello(a)
		local b = harness.Join(70209)
		harness.SendHello(b)
		harness.Step()
		local j = harness.Join(70210)
		writeDuringSend(harness, j, Wire.Frames.Init, function()
			dataA.Public.List.Insert("x")
		end)
		writeDuringSend(harness, b, Wire.Frames.SharedDiff, function()
			dataA.Public.List.Insert("y")
		end)
		harness.SendHello(j)
		harness.Step()
		harness.Step()
		local inSnapshot = 0
		for _, frame in harness.FramesFor(j, Wire.Frames.SharedInit) do
			if frame.UserId == 70208 then
				inSnapshot = #frame.Ops[1].Value.List
			end
		end
		local diffsToJoiner = #harness.FramesFor(j, Wire.Frames.SharedDiff)
		harness.Cleanup()
		expect(`inSnapshot={inSnapshot} diffsToJoiner={diffsToJoiner}`).to.equal("inSnapshot=1 diffsToJoiner=1")
	end)

	it("does not re-broadcast an op queued before the new player's snapshot", function()
		local harness = TestCtx.make({ Template = { Public = Scribe.Shared({ List = {} }) } })
		local a = harness.Join(70206)
		harness.SendHello(a)
		harness.Step()
		local before = #harness.FramesFor(a, Wire.Frames.SharedDiff)
		-- The load hooks run before the snapshot, so a write there is queued and in it.
		local realOnLoad = harness.Ctx.Leaderboards.OnLoad
		harness.Ctx.Leaderboards.OnLoad = function(entry)
			if entry.UserId == 70207 then
				harness.Data.Get(entry.Player).Public.List.Insert("x")
			end
			return realOnLoad(entry)
		end
		harness.Join(70207)
		harness.Step()
		local inits = #harness.FramesFor(a, Wire.Frames.SharedInit)
		local diffs = #harness.FramesFor(a, Wire.Frames.SharedDiff) - before
		harness.Cleanup()
		expect(`inits={inits} diffs={diffs}`).to.equal("inits=1 diffs=0")
	end)

	it("keeps a new player's write made during its own Shared broadcast", function()
		local harness = TestCtx.make({ Template = TEMPLATE })
		local a = harness.Join(70204)
		harness.SendHello(a)
		harness.Step()
		local before = #harness.FramesFor(a, Wire.Frames.SharedDiff)
		writeDuringSend(harness, a, Wire.Frames.SharedInit, function()
			local entry = harness.Ctx.Persistence.EntryForUserId(70205)
			harness.Data.Get(entry.Player).Public.Title.Set("late")
		end)
		harness.Join(70205)
		harness.Step()
		harness.Step()
		local diffs = #harness.FramesFor(a, Wire.Frames.SharedDiff) - before
		harness.Cleanup()
		expect(`diffs={diffs}`).to.equal("diffs=1")
	end)
end
