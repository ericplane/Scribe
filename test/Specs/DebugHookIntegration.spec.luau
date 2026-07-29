--!nonstrict
-- DebugHook + replication integration: attaching the Studio hook at boot (as
-- Server.new does since protocol v6) must not disturb the client handshake,
-- diff replication, or shared broadcasts — the hook wraps PushOp and the
-- transport, and a regression here breaks the real game, not just the plugin.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("boot-attached hook leaves handshake, diffs, and broadcasts intact", function()
		-- Attach exactly like Server.new does after Server.build. DebugHook.Attach is
		-- called directly here, so no RunService gate needs faking; patching the real
		-- service Instance is illegal and made this spec unrunnable in Studio.
		local harness = TestCtx.make({ Options = { DevMode = true } })
		local attachOk, attachErr = pcall(function()
			(require(ScribeRoot.Server.DebugHook) :: any).Attach(harness.Data, harness.Ctx)
		end)
		if not attachOk then
			error(`DebugHook.Attach failed at boot: {tostring(attachErr)}`)
		end

		-- Client handshake flows through the wrapped transport.
		local player, entry, data = harness.Join()
		harness.SendHello(player)
		local inits = harness.FramesFor(player, Wire.Frames.Init)
		expect(#inits).to.equal(1)

		-- A server-side write flows through the wrapped PushOp into a diff.
		data.Coins.Set(123)
		harness.Ctx.Replication.FlushEntry(entry)
		local diffs = harness.FramesFor(player, Wire.Frames.Diff)
		expect(#diffs).to.equal(1)
		local coinsValue = nil
		for _, op in diffs[1].Ops do
			if op.Path[1] == "Coins" then
				coinsValue = op.Value
			end
		end
		expect(coinsValue).to.equal(123)

		-- Shared visibility still broadcasts to other handshaken clients.
		local other, otherEntry = harness.Join(2222)
		harness.SendHello(other)
		data.Pub.Title.Set("hello")
		harness.Ctx.Replication.FlushEntry(entry)
		local sharedDiffs = harness.FramesFor(other, Wire.Frames.SharedDiff)
		expect(#sharedDiffs > 0).to.equal(true)

		-- Ops before Hello are still superseded by the snapshot, not queued.
		local late = harness.Join(3333)
		local lateEntry = harness.Ctx.Persistence.EntryFor(late)
		local lateData = harness.Data.Get(late)
		lateData.Coins.Set(7)
		harness.Ctx.Replication.FlushEntry(lateEntry)
		expect(#harness.FramesFor(late, Wire.Frames.Diff)).to.equal(0)
		harness.SendHello(late)
		local lateInits = harness.FramesFor(late, Wire.Frames.Init)
		expect(#lateInits).to.equal(1)

		local _ = otherEntry
		harness.Cleanup()
	end)

	it("client hook's ApplyOp wrap leaves the client mirror intact", function()
		-- The client hook attaches when IsStudio + IsClient; it wraps
		-- tree.ApplyOp to record received ops. Diff application must be
		-- byte-identical with the wrap installed.
		local harness = TestCtx.make({ AutoPump = true, Options = { RequestTimeout = 0.25 } })
		local player, entry, serverData = harness.Join()
		harness.Transport.LocalPlayer = player
		-- Force the Studio client-hook branch via the option seams rather than
		-- patching RunService, which a real service Instance rejects.
		local clientOptions = table.clone(harness.Options)
		clientOptions.DevMode = true
		clientOptions.IsClient = true
		local clientOk, clientDataOrErr = pcall(Client.new, clientOptions, harness.Compiled)
		if not clientOk then
			error(`Client.new failed with the client hook attached: {tostring(clientDataOrErr)}`)
		end
		local clientData = clientDataOrErr

		-- Init snapshot applied through the wrapped ApplyOp.
		expect(clientData.Coins.Get()).to.equal(0)

		-- Live diffs still apply through the wrap.
		serverData.Coins.Set(77)
		harness.Ctx.Replication.FlushEntry(entry)
		expect(clientData.Coins.Get()).to.equal(77)

		-- Buffers survive the wrap's record cloning untouched.
		serverData.Inventory.Chunk.Set(buffer.fromstring("AB\0C"))
		harness.Ctx.Replication.FlushEntry(entry)
		expect(buffer.tostring(clientData.Inventory.Chunk.Get())).to.equal("AB\0C")

		harness.Cleanup()
	end)
end
