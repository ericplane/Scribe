--!nonstrict
-- The Init writer's initial capacity, and the per-session number that seeds it.
--
-- THIS IS THE SPEC FOR AN INVISIBLE CHANGE, which is why it exists at all. An
-- Init frame is byte-identical whether the writer was sized correctly, sized from
-- the op count, or sized wrongly -- the only difference is how many buffers were
-- allocated and copied on the way there. Nothing else in the suite can see that:
-- no round-trip differs, no length differs, no fuzz case behaves differently. So
-- the capacity DECISION is pinned directly, and the Replication wiring that
-- feeds it is pinned separately, because a break in either half would otherwise
-- leave every test in the repo green.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Wire = require(ScribeRoot.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Scribe = require(ScribeRoot) :: any

	local itRunning = if RunService:IsRunning() then it else itSKIP

	describe("the capacity decision", function()
		it("falls back to the op-count model with no hint", function()
			-- The shipped default, restated: 64 bytes of header room plus 16 per op.
			expect(Wire.OpsFrameCapacity(0)).to.equal(64)
			expect(Wire.OpsFrameCapacity(9)).to.equal(208)
			expect(Wire.OpsFrameCapacity(100)).to.equal(1664)
		end)

		it("seeds from the hint when the hint is larger", function()
			-- The whole point: an Init is one op per ROOT, so the op count says 208
			-- bytes for a frame that turns out to be 37,978. Ten buffer.create calls
			-- and 91,018 bytes memcpy'd become two and 37,978.
			expect(Wire.OpsFrameCapacity(9, 37978)).to.equal(37978)
		end)

		it("treats the op-count model as a FLOOR, not a default", function()
			-- A hint smaller than the ops already justify must not shrink the writer.
			-- A previous Init of 100 bytes followed by a 500-op Diff-sized frame would
			-- otherwise start smaller than the unseeded encoder did, making the
			-- "optimisation" a pessimisation.
			expect(Wire.OpsFrameCapacity(100, 10)).to.equal(1664)
			expect(Wire.OpsFrameCapacity(9, 208)).to.equal(208)
			expect(Wire.OpsFrameCapacity(9, 209)).to.equal(209)
		end)
	end)

	describe("the frame is unchanged by the hint", function()
		it("produces byte-identical frames at any capacity", function()
			-- The safety property behind the whole change. If a hint could alter a
			-- single byte, this would be a wire change wearing an allocation fix.
			local harness = TestCtx.make({ AutoPump = false })
			local ops = {
				{ Kind = "Set", Path = { "Coins" }, Value = 4242 },
				{ Kind = "Set", Path = { "Nick" }, Value = "somebody" },
			}
			local plain = Wire.EncodeOpsFrame(Wire.Frames.Init, harness.Compiled, ops)
			for _, hint in { 1, 208, 1000, 100000 } do
				local seeded = Wire.EncodeOpsFrame(Wire.Frames.Init, harness.Compiled, ops, nil, nil, hint)
				expect(buffer.len(seeded)).to.equal(buffer.len(plain))
				expect(buffer.tostring(seeded)).to.equal(buffer.tostring(plain))
			end
			harness.Cleanup()
		end)

		it("still fills the spans table when seeded", function()
			-- spans is measured from the writer's own offset, so a different starting
			-- capacity must not perturb it.
			local harness = TestCtx.make({ AutoPump = false })
			local ops = {
				{ Kind = "Set", Path = { "Coins" }, Value = 1 },
				{ Kind = "Set", Path = { "Nick" }, Value = "xyz" },
			}
			local a, b = {}, {}
			local plain = Wire.EncodeOpsFrame(Wire.Frames.Init, harness.Compiled, ops, nil, a)
			Wire.EncodeOpsFrame(Wire.Frames.Init, harness.Compiled, ops, nil, b, 65536)
			expect(#a).to.equal(2)
			expect(`{a[1]},{a[2]}`).to.equal(`{b[1]},{b[2]}`)
			-- The spans plus the header still sum to the frame, seeded or not.
			expect(a[1] + a[2] + 3).to.equal(buffer.len(plain))
			harness.Cleanup()
		end)
	end)

	describe("the session remembers its last Init", function()
		itRunning("records the Init size on the entry after the handshake", function()
			-- The "remember" half. Without it the hint is always nil and the seeding
			-- above is dead code that every other spec would still pass.
			local harness = TestCtx.make({ AutoPump = false })
			local player, entry, serverData = harness.Join()
			for i = 1, 50 do
				serverData.Coins.Set(i)
			end
			harness.Transport.LocalPlayer = player
			harness.SendHello(player)

			local initLen = nil
			for _, f in harness.Transport.SentToClientLog do
				if buffer.readu8(f.Bytes, 0) == Wire.Frames.Init then
					initLen = buffer.len(f.Bytes)
				end
			end
			expect(initLen).to.be.ok()
			expect(entry.InitSizeHint).to.equal(initLen)
			harness.Cleanup()
		end)

		itRunning("carries a large profile's size into the hint", function()
			-- Sized so the hint is unmistakably the frame and not the op-count model:
			-- a few roots, a lot of bytes. This is the shape the change exists for.
			local harness = TestCtx.make({
				AutoPump = false,
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Inventory = Scribe.DictOf({ Qty = Scribe.Int(0, { Min = 0 }) }),
				},
				Options = { MaxOutboundBytes = 1048576 },
			})
			local player, entry, serverData = harness.Join()
			for i = 1, 500 do
				serverData.Inventory[`item_{i}_abcdefghijkl`].Set({ Qty = i })
			end
			harness.Transport.LocalPlayer = player
			harness.SendHello(player)

			expect(entry.InitSizeHint).to.be.ok()
			-- Far above the op-count model, which is what makes the seeding worth
			-- anything at all.
			expect(entry.InitSizeHint > Wire.OpsFrameCapacity(2)).to.equal(true)
			expect(entry.InitSizeHint > 10000).to.equal(true)
			harness.Cleanup()
		end)
	end)
end
