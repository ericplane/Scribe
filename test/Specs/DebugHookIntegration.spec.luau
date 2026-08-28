--!nonstrict
-- DebugHook + replication integration: attaching the Studio hook at boot (as
-- Server.new does since protocol v6) must not disturb the client handshake,
-- diff replication, or shared broadcasts: the hook wraps PushOp and the
-- transport, and a regression here breaks the real game, not just the plugin.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	it("boot-attached hook leaves handshake, diffs, and broadcasts intact", function()
		-- Attach exactly like Server.new does after Server.build. DebugHook.Attach is
		-- called directly here, so no RunService gate needs faking; patching the real
		-- service Instance is illegal and made this spec unrunnable in Studio.
		--
		-- A PRIVATE COPY OF THE MODULE, and this is the load-bearing part in Studio.
		-- `Attach` closes a once-per-process latch that `detach` deliberately never
		-- reopens, so exactly one spec in a run can exercise the real attach path. This
		-- node does not measure the attach -- it measures that everything AROUND a
		-- boot-attached hook still works -- while DebugHookTeardown measures nothing
		-- else. Headless the difference is invisible, because IsStudio is pinned false
		-- and Attach returns before the latch; in Studio it is genuinely true for every
		-- spec, so whichever file sorted first silently took the latch and the one that
		-- needed it reported a hook that never attached. A copy costs one module load
		-- and removes the ordering dependency entirely.
		-- RENAMED BEFORE IT IS PARENTED, and that is not cosmetic. `Server.new` reaches
		-- its own hook as `script.DebugHook`, and a name lookup with two children of
		-- that name returns whichever the engine feels like -- so a copy left under the
		-- original name would silently become the module the LIBRARY loads. It has to
		-- live under Scribe.Server all the same: DebugHook resolves everything it needs
		-- through `script.Parent.Parent`, so the copy only works where the original did.
		local hookModule = ScribeRoot.Server.DebugHook:Clone()
		hookModule.Name = "DebugHookIntegrationCopy"
		hookModule.Parent = ScribeRoot.Server
		local harness = TestCtx.make({ Options = { DevMode = true } })
		local detach = nil
		local attachOk, attachErr = pcall(function()
			detach = (require(hookModule) :: any).Attach(harness.Data, harness.Ctx)
		end)
		if not attachOk then
			error(`DebugHook.Attach failed at boot: {tostring(attachErr)}`)
		end
		-- THE CALIBRATION, and it is new. Everything below asserts that the wrapped
		-- paths still behave; none of it can tell a correctly-wrapped bundle from an
		-- unwrapped one. Headless the hook cannot attach at all -- IsStudio is pinned
		-- false and this spec deliberately does not fake it, because patching the real
		-- service Instance is illegal in Studio -- so the check is on the gate rather
		-- than on the host, and it is what proves the copy above is doing its job.
		if RunService:IsStudio() then
			expect(type(detach)).to.equal("function")
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
		-- Give back what the hook took. `detach` releases the Log sink, the Health
		-- listener and the ServerStorage container -- all process singletons, all of
		-- which used to outlive this node, and the container is itself half of Attach's
		-- duplicate guard. Unparenting the copy afterwards leaves the module tree as it
		-- was found; `Parent = nil` rather than `Destroy` because it means the same
		-- thing on both runners.
		if type(detach) == "function" then
			detach()
		end
		hookModule.Parent = nil
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
