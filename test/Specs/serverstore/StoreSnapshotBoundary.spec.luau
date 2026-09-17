--!nonstrict
-- The server store's snapshot boundary: an op queued when a joiner's Init is taken is
-- already in the snapshot, so it must not be broadcast to that joiner as well. Insert
-- would duplicate the element and Remove, by index, would drop a different one.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function makeHarness()
		return TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = { Items = {} }, Banner = false },
		})
	end

	--- Every Diff `player` received, as a flat string of ops.
	local function diffsFor(harness, player): string
		local parts = {}
		for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
			for _, op in frame.Ops do
				table.insert(parts, `{op.Kind}:{table.concat(op.Path, ".")}`)
			end
		end
		return table.concat(parts, ",")
	end

	it("lands a store write a synchronous transport makes while the joiner's Init is sent past the boundary", function()
		local harness = makeHarness()
		local a = harness.Join(80003)
		harness.SendHello(a)
		local b = harness.Join(80004)
		harness.Transport.LocalPlayer = b
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.Data.ServerStore.Items.Insert("a")
		-- A transport whose Send runs game code: every Diff to A inserts another element.
		local realSend = harness.Transport.SendToClient
		local writes = 0
		harness.Transport.SendToClient = function(self, player, bytes)
			if (player == a or player == nil) and buffer.readu8(bytes, 0) == Wire.Frames.Diff and writes < 6 then
				writes += 1
				harness.Data.ServerStore.Items.Insert(`w{writes}`)
			end
			return realSend(self, player, bytes)
		end
		harness.Transport:PumpToServer()
		harness.Step()
		harness.Transport:PumpToClient()
		for _ = 1, 8 do
			harness.Step()
			harness.Transport:PumpToClient()
		end
		local mirror = table.concat(clientB.ServerStore.Items.Get(), ",")
		local server = table.concat(harness.Data.ServerStore.Items.Get(), ",")
		clientB.Stop()
		harness.Cleanup()
		expect(`writes={writes} mirror={mirror}`).to.equal(`writes=6 mirror={server}`)
	end)

	it("delivers a store op queued before a joiner's Init to that client exactly once", function()
		local harness = makeHarness()
		local a = harness.Join(80001)
		harness.SendHello(a)
		local b = harness.Join(80002)
		harness.Transport.LocalPlayer = b
		-- Client.new queues B's Hello; the store write lands before the server reads it.
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.Data.ServerStore.Items.Insert("a")
		harness.Transport:PumpToServer()
		harness.Step()
		harness.Transport:PumpToClient()
		local mirror = #clientB.ServerStore.Items.Get()
		local aDiffs = diffsFor(harness, a)
		local bDiffs = diffsFor(harness, b)
		-- A write after the snapshot travels as a Diff.
		harness.Data.ServerStore.Items.Insert("b")
		harness.Step()
		harness.Transport:PumpToClient()
		local after = #clientB.ServerStore.Items.Get()
		local aFinal = diffsFor(harness, a)
		local bFinal = diffsFor(harness, b)
		clientB.Stop()
		harness.Cleanup()
		-- At the Init A got the drained op and B nothing; the later write adds one each.
		expect(`mirror={mirror} after={after} a=[{aDiffs}] b=[{bDiffs}] | a=[{aFinal}] b=[{bFinal}]`).to.equal(
			"mirror=1 after=2 a=[Insert:Items] b=[] | a=[Insert:Items,Insert:Items] b=[Insert:Items]"
		)
	end)
end
