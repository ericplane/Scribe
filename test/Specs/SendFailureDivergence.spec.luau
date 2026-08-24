--!nonstrict
-- What happens to a client mirror when a frame does not reach the transport.
--
-- The answer used to be "it diverges, permanently, and nothing notices". Four call
-- sites called `sendBuffer` as a bare statement and discarded the boolean it is
-- declared to return, while `FlushEntry` had already replaced `entry.Queue` before
-- the encode -- so the ops in a refused frame were gone from the server and had
-- never arrived at the client. `sendInit` was the one caller that checked, which is
-- the only reason a refused INIT recovered.
--
-- The client cannot repair this itself. All three `sendHello` sites gate on
-- `not loaded`, and `loaded` is written true exactly once in `applyInit` and never
-- reset -- so a LOADED client never asks again. The server has to notice.
--
-- WHAT A RAISING TRANSPORT MODELS. Roblox does not refuse payloads: a `FireClient`
-- of 32 MiB of incompressible data was measured delivering in full. The reachable
-- triggers are a CUSTOM transport adapter (a base64 wrapper, a capped channel, a
-- bridge that validates) and a player leaving mid-flush. The hole is a correctness
-- hole either way, and these specs drive it through the adapter seam.
--
-- `StubTransport:DropToClient` is deliberately NOT used here: it models SILENT loss
-- (the transport accepted the frame and the wire ate it), so `sendBuffer` returns
-- TRUE and no server-side change can help. Only a RAISING transport produces the
-- `false` these specs are about. See the last test, which pins that boundary.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Client = require(ScribeRoot.Client)
	local Metrics = require(ScribeRoot.Internal.Metrics)
	local Clock = require(ScribeRoot.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	--- A joined player with a live client mirror attached.
	local function mirrored(userId: number, template: { [string]: any }?)
		local harness = TestCtx.make({
			AutoPump = true,
			Template = template or {
				Coins = Scribe.Int(0),
				Nick = Scribe.String(""),
				Log = Scribe.ArrayOf(Scribe.String("")),
			},
		})
		local player, entry, data = harness.Join(userId)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()
		return harness, player, entry, data, client
	end

	--- Run `fn` against a frozen clock it can advance, then restore the real one.
	--- Repair is throttled at REINIT_COOLDOWN (5 s), so anything past the FIRST
	--- resync attempt is unreachable in a test that runs in milliseconds.
	local function withClock(fn)
		local now = 1_700_000_000
		Clock.Install({
			Now = function()
				return now
			end,
			Monotonic = function()
				return now
			end,
		})
		local ok, err = pcall(fn, function(seconds: number)
			now += seconds
		end)
		Clock.Reset()
		if not ok then
			error(err, 0)
		end
	end

	--- Make the transport raise for the next `n` sends to `player`, then behave.
	--- Returns a `heal` that restores it unconditionally.
	local function refuseNext(harness: any, player: any, n: number)
		local real = harness.Transport.SendToClient
		local left = n
		harness.Transport.SendToClient = function(self: any, target: any, bytes: buffer)
			if left > 0 and target == player then
				left -= 1
				error("transport adapter: refused", 0)
			end
			return real(self, target, bytes)
		end
		return function()
			harness.Transport.SendToClient = real
		end
	end

	describe("a refused owner frame", function()
		itRunning("still reaches the mirror once the link heals", function()
			-- The whole item in one assertion. Before: `server=7 client=0`, with
			-- `client.IsReady()` true the entire time and 300 virtual seconds of
			-- healthy link afterwards changing nothing.
			local harness, player, _entry, data, client = mirrored(74901)
			expect(client.IsReady()).to.equal(true)

			local heal = refuseNext(harness, player, 1)
			data.Coins.Set(7)
			data.Nick.Set("ada")
			harness.Step()
			heal()

			-- Several frames, because repair is allowed to take one: what must not
			-- happen is that it never arrives.
			for _ = 1, 4 do
				harness.Step()
			end

			expect(`server={data.Coins.Get()}/{data.Nick.Get()} client={client.Coins.Get()}/{client.Nick.Get()}`).to.equal(
				"server=7/ada client=7/ada"
			)
			harness.Cleanup()
		end)

		itRunning("does not double-apply an op that DID land", function()
			-- The overcorrection guard, and the reason a naive "requeue the whole
			-- compacted queue" is not a fix: Insert, Remove and Clear are NOT
			-- idempotent, so replaying a frame whose first chunk landed appends the
			-- same entry twice. A fix that yields "a,b,b" here is a new defect
			-- wearing the old one's clothes.
			local harness, player, _entry, data, client = mirrored(74902)

			data.Log.Insert("a")
			harness.Step()
			expect(table.concat(client.Log.Get(), ",")).to.equal("a")

			local heal = refuseNext(harness, player, 1)
			data.Log.Insert("b")
			harness.Step()
			heal()
			for _ = 1, 4 do
				harness.Step()
			end

			expect(table.concat(client.Log.Get(), ",")).to.equal("a,b")
			harness.Cleanup()
		end)

		itRunning("converges after a burst of refusals, not just one", function()
			-- Repair is throttled at REINIT_COOLDOWN, so this one has to advance a
			-- clock rather than spin frames: without it only the FIRST resync attempt
			-- is reachable and the test would be asserting the throttle, not the fix.
			withClock(function(advance)
				local harness, player, _entry, data, client = mirrored(74903)

				local heal = refuseNext(harness, player, 8)
				for i = 1, 3 do
					data.Coins.Set(i)
					data.Log.Insert(`e{i}`)
					harness.Step()
					advance(6)
				end
				heal()
				for _ = 1, 4 do
					harness.Step()
					advance(6)
				end

				expect(`coins={client.Coins.Get()} log={table.concat(client.Log.Get(), ",")}`).to.equal(
					"coins=3 log=e1,e2,e3"
				)
				harness.Cleanup()
			end)
		end)

		itRunning("throttles repeated repairs, so a broken transport costs one snapshot per cooldown", function()
			-- The bound that makes a server-driven repair safe at all. Without it a
			-- permanently refusing transport drives a whole-profile encode every
			-- frame, for every affected player, forever.
			withClock(function(advance)
				local harness, _player, entry, data = mirrored(74908)
				local real = harness.Transport.SendToClient
				harness.Transport.SendToClient = function()
					error("transport adapter: refused", 0)
				end

				data.Coins.Set(1)
				harness.Step() -- Diff refused -> resync requested
				Metrics.Reset()
				-- Twenty frames inside one cooldown. The FIRST repair is deliberately
				-- immediate -- a client that lost a frame a second after joining must
				-- not stay stale for five seconds -- so the number to see here is 1,
				-- not 0, and emphatically not 20.
				for _ = 1, 20 do
					harness.Step()
				end
				local inCooldown = Metrics.Get().InitSendFailed or 0

				advance(6)
				harness.Step()
				local afterCooldown = Metrics.Get().InitSendFailed or 0

				harness.Transport.SendToClient = real
				expect(`attemptsIn20Frames={inCooldown} afterCooldown={afterCooldown}`).to.equal(
					"attemptsIn20Frames=1 afterCooldown=2"
				)
				expect(`pending={entry.ResyncPending}`).to.equal("pending=true")
				harness.Cleanup()
			end)
		end)
	end)

	describe("a re-Init whose send fails", function()
		itRunning("does not strand the entry in a state that discards every op", function()
			-- The trap state the brief names: (HandshakeReady = true, QueueOpen =
			-- false). sendInit's failure branch cleared QueueOpen but left
			-- HandshakeReady true from the FIRST, successful Init -- and in that state
			-- PushOp silently discards every owner op (it is gated on QueueOpen, with
			-- no else, no log and no metric) while FlushEntry matches neither of its
			-- two branches. Total, permanent, silent loss of the owner mirror.
			local harness, player, entry, data, client = mirrored(74904)

			-- Drive a second Init the way a re-Hello does, past the cooldown.
			entry.LastInitAt = 0
			local heal = refuseNext(harness, player, 1)
			harness.SendHello(player)

			expect(`ready={entry.HandshakeReady} open={entry.QueueOpen}`).to.equal("ready=false open=false")

			heal()
			for _ = 1, 4 do
				harness.Step()
			end
			data.Coins.Set(42)
			for _ = 1, 4 do
				harness.Step()
			end

			expect(`client={client.Coins.Get()}`).to.equal("client=42")
			harness.Cleanup()
		end)
	end)

	describe("the accounting", function()
		itRunning("does not count ops that never left", function()
			-- docgen/guides/diagnostics.md says of FlushQueuedPerFrame: "OpsSent is
			-- what actually reached clients". Both OpsSent and DiffFlushes fired for a
			-- frame that was refused, while FramesSent -- correctly -- did not.
			local harness, player, _entry, data = mirrored(74905)
			local heal = refuseNext(harness, player, 1)
			Metrics.Reset()
			data.Coins.Set(3)
			harness.Step()
			heal()

			local m = Metrics.Get()
			expect(`flushes={m.DiffFlushes} ops={m.OpsSent} frames={m.FramesSent}`).to.equal(
				"flushes=nil ops=nil frames=nil"
			)
			harness.Cleanup()
		end)

		itRunning("counts them once the same ops are actually delivered", function()
			-- The other half: the counters must not become permanently silent.
			local harness, player, _entry, data = mirrored(74906)
			local heal = refuseNext(harness, player, 1)
			data.Coins.Set(3)
			harness.Step()
			heal()
			Metrics.Reset()
			for _ = 1, 4 do
				harness.Step()
			end

			expect(`frames={(Metrics.Get().FramesSent or 0) > 0}`).to.equal("frames=true")
			harness.Cleanup()
		end)
	end)

	describe("the boundary of what this can fix", function()
		itRunning("cannot see loss the transport reported as success", function()
			-- Deliberate, and worth stating so nobody reads the specs above as a
			-- delivery guarantee. This transport ACCEPTS the frame and drops it on the
			-- floor; sendBuffer returns true, the server has no signal at all, and the
			-- mirror stays stale. Repairing that needs an acknowledgement protocol,
			-- which is a different item entirely.
			local harness, player, _entry, data, client = mirrored(74907)
			local real = harness.Transport.SendToClient
			local swallow = 1
			harness.Transport.SendToClient = function(self: any, target: any, bytes: buffer)
				if swallow > 0 and target == player then
					swallow -= 1
					return -- accepted, and dropped on the floor
				end
				return real(self, target, bytes)
			end
			data.Coins.Set(9)
			for _ = 1, 4 do
				harness.Step()
			end
			harness.Transport.SendToClient = real
			expect(`server={data.Coins.Get()} client={client.Coins.Get()}`).to.equal("server=9 client=0")
			harness.Cleanup()
		end)
	end)
end
