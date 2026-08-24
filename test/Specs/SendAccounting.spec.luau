--!nonstrict
-- What the send path costs per recipient, and what it still guarantees.
--
-- The Shared fanout delivers one frame to every other ready client, so anything
-- done per recipient is done N^2 times a frame. Measured across a player-count
-- sweep, every-player-writes-every-frame, whole PostSimulation flush timed:
--
--     N      sends/frame   before    after
--     64        4,096      1.391 ms  0.873 ms
--     128      16,384      4.957 ms  2.749 ms
--     256      65,536     19.688 ms  9.589 ms
--
-- Three per-recipient costs came out, none of which was the send:
--
--   * `pcall(function() ... end)` allocated a closure per delivery. Replaced with
--     `pcall(f, ...)`, which protects identically and allocates nothing.
--   * `Metrics.Observe("BytesOutPerSend", ...)` ran per delivery. It is documented
--     as "bytes per outbound frame" and now runs once per frame, which is both
--     cheaper and what the docs already said.
--   * A per-delivery `Metrics.Add` replaced the second of those in a first draft
--     and cost almost exactly as much -- 5.2 ms of a 12.0 ms frame at N=256. The
--     count is now accumulated locally and added once.
--
-- THE POINT OF THIS FILE is the guarantee, not the speed. Unwrapping a pcall is
-- exactly the kind of change that quietly removes the protection it was written
-- for, so the first two tests drive a transport that raises and check the flush
-- loop survives it. The rest pin the metric semantics, because "cheaper" is only
-- true if the numbers still mean something.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Metrics = require(Root.Scribe.Internal.Metrics)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	--- `n` joined, handshaken players on one server, with the Init traffic settled.
	local function server(n: number, firstId: number)
		local harness = TestCtx.make({ AutoPump = false })
		local players, datas = {}, {}
		for i = 1, n do
			local player, _entry, data = harness.Join(firstId + i)
			players[i] = player
			datas[i] = data
			harness.SendHello(player)
		end
		for _ = 1, 3 do
			harness.Step()
		end
		return harness, players, datas
	end

	describe("a transport that raises", function()
		it("does not take down the flush loop, and the other clients still get theirs", function()
			-- The guarantee the pcall exists for. Unwrapping the closure must not
			-- unwrap the protection.
			local harness, players, datas = server(4, 74000)
			local victim = players[2]
			local real = harness.Transport.SendToClient
			harness.Transport.SendToClient = function(self: any, player: any, bytes: buffer)
				if player == victim then
					error("transport exploded")
				end
				return real(self, player, bytes)
			end

			for _, data in datas do
				data.Pub.Title.Set("x")
			end
			-- Must not raise out of PostSimulation.
			local ok = pcall(harness.Step)
			harness.Transport.SendToClient = real

			expect(ok).to.equal(true)
			expect(#Scribe.GetRecentLogs({ Code = "SEND_FAIL", Limit = 20 }) > 0).to.equal(true)
			-- ...and the healthy clients were served, so this is not passing because
			-- the whole flush was abandoned.
			expect(#harness.FramesFor(players[1]) > 0).to.equal(true)
			expect(#harness.FramesFor(players[3]) > 0).to.equal(true)
			harness.Cleanup()
		end)

		it("survives a broadcast-capable transport raising too", function()
			-- The other pcall, on the SendToAllClients fast path. Reached by a status
			-- broadcast, which passes no excluded entry.
			local harness = server(2, 74100)
			local real = harness.Transport.SendToAllClients
			harness.Transport.SendToAllClients = function()
				error("broadcast exploded")
			end

			local ok = pcall(function()
				harness.Ctx.Replication.BroadcastStatus()
			end)
			harness.Transport.SendToAllClients = real

			expect(ok).to.equal(true)
			expect(#Scribe.GetRecentLogs({ Code = "SEND_FAIL", Limit = 20 }) > 0).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("Replication.Broadcast", function()
		it("marks every recipient it could not reach for resync", function()
			-- Tier A recorded this line as the one it could not pin: deleting
			-- `self.Broadcast`'s markResync loop left the suite green, because it had no
			-- caller anywhere. THIS TEST is what changed that, so the "zero callers"
			-- claim that used to sit here was refuted by the file it was written in. It
			-- still has zero callers in src/; the line below is the only one in the repo.
			--
			-- Reachability, stated exactly, because the previous wording overshot in the
			-- other direction too. `Server.new` returns only `Data` and no member of the
			-- public bundle exposes `ctx` -- but `Server.build` returns `(Data, ctx)`,
			-- both harnesses publish that ctx (TestCtx.luau, test/Sim/Bundle.luau), and
			-- docgen/guides/testing.md teaches game developers the `_Index` path to
			-- `Server.build` and prints `local Data, ctx = Server.build(...)`. So a game
			-- CAN hold this, and the docs say how. What that page also says is that the
			-- entry point "carries no compatibility promise the public API does" -- so
			-- this is documented internal surface, not public API, and neither "nothing
			-- a game can reach" nor "public" is the right description of it.
			--
			-- Calling it from here is the same access every other subsystem assertion in
			-- this file uses, not a new seam invented to make a test possible.
			--
			-- Deleting the method instead would have been the other option and is
			-- worse: it is the only sibling of BroadcastStatus and SendTo that reports
			-- missed recipients at all, and a future caller that quietly loses that
			-- reporting is exactly the divergence class A4 was about.
			local harness, players = server(3, 74300)
			local entries = {}
			for i, player in players do
				entries[i] = harness.Ctx.Persistence.EntryFor(player)
			end
			expect(`readyBefore={entries[1].HandshakeReady and entries[2].HandshakeReady}`).to.equal("readyBefore=true")

			-- No SendToAllClients on this transport path: Broadcast passes no excluded
			-- entry, so it takes the fast path when one exists. Remove it so delivery
			-- goes per recipient, then refuse every send.
			local realAll = harness.Transport.SendToAllClients
			local realOne = harness.Transport.SendToClient
			harness.Transport.SendToAllClients = nil
			harness.Transport.SendToClient = function()
				error("refused")
			end
			local w = Wire.NewWriter(4)
			Wire.U8(w, Wire.Frames.Status)
			Wire.U8(w, 1)
			harness.Ctx.Replication.Broadcast(Wire.Finish(w))
			harness.Transport.SendToAllClients = realAll
			harness.Transport.SendToClient = realOne

			local marked = 0
			for _, entry in entries do
				if entry.ResyncPending == true and entry.HandshakeReady == false then
					marked += 1
				end
			end
			expect(`marked={marked}/{#entries}`).to.equal(`marked={#entries}/{#entries}`)
			harness.Cleanup()
		end)
	end)

	describe("what the counters mean", function()
		it("observes BytesOutPerSend once per FRAME, not once per recipient", function()
			-- Four ready clients, one Shared write each: four Shared frames, each
			-- delivered to three others, plus four owner frames. Twelve of the sixteen
			-- deliveries carry a buffer that was already observed.
			local harness, _players, datas = server(4, 74200)
			Metrics.Reset()
			for _, data in datas do
				data.Pub.Title.Set("shared")
			end
			harness.Step()

			local m = Metrics.Get()
			-- 4 SharedDiff frames + 4 owner Diff frames.
			expect(m.BytesOutPerSend.Count).to.equal(8)
			harness.Cleanup()
		end)

		it("counts every delivery in FramesSent, so the fanout is visible", function()
			-- The number the old per-delivery Observe was implicitly providing, kept
			-- explicitly and for far less: 4 owner sends + 4x3 Shared deliveries.
			local harness, _players, datas = server(4, 74300)
			Metrics.Reset()
			for _, data in datas do
				data.Pub.Title.Set("shared")
			end
			harness.Step()

			expect(Metrics.Get().FramesSent).to.equal(16)
			harness.Cleanup()
		end)

		it("scales as N squared, which is the property worth being able to see", function()
			-- The same measurement at two sizes. This is the shape that decides whether
			-- Shared needs interest management, so it is pinned rather than left to a
			-- comment: deliveries per frame are N^2, not N.
			for _, n in { 4, 8 } do
				local harness, _players, datas = server(n, 74400 + n * 100)
				Metrics.Reset()
				for _, data in datas do
					data.Pub.Title.Set("shared")
				end
				harness.Step()
				expect(`n={n} sent={Metrics.Get().FramesSent}`).to.equal(`n={n} sent={n * n}`)
				harness.Cleanup()
			end
		end)

		it("counts neither for a delivery that failed", function()
			local harness, _players, datas = server(2, 74600)
			local real = harness.Transport.SendToClient
			harness.Transport.SendToClient = function()
				error("no")
			end
			Metrics.Reset()
			for _, data in datas do
				data.Pub.Title.Set("x")
			end
			harness.Step()
			harness.Transport.SendToClient = real

			local m = Metrics.Get()
			expect(`sent={m.FramesSent} observed={m.BytesOutPerSend}`).to.equal("sent=nil observed=nil")
			harness.Cleanup()
		end)
	end)
end
