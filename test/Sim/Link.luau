--!nonstrict
-- One simulated server's client link: a loopback ScribeTransport that can host
-- MANY clients at once.
--
-- test/Helpers/StubTransport exists for the non-sim harness and cannot be reused
-- here, for a reason worth stating rather than rediscovering: it holds ONE
-- `_clientListener` and ONE `LocalPlayer`, so it models a server with exactly one
-- player watching. A simulated server has tens, and the whole point of covering
-- replication is the fan-out -- who receives a frame and, far more importantly,
-- who does not.
--
-- DELIVERY IS FRAME-DRIVEN, not scheduler-driven, and that is deliberate.
-- Queueing each frame behind a `Sched:Delay` would work, but it would add a
-- thread per frame to a seeded scheduler whose step order IS the replay -- so
-- every existing digest would shift the moment a link existed, even in a spec
-- that never attached a client. Draining inside the server's frame instead adds
-- nothing to the scheduler at all, and models the real thing more honestly: a
-- RemoteEvent fires between frames, not at an arbitrary instant inside one.
--
-- The order inside a frame is the order Roblox uses, and specs depend on it:
--
--   1. inbound (client -> server) frames arrive
--   2. PostSimulation runs, so Scribe's flush loop enqueues outbound work
--   3. outbound (server -> client) frames leave
--
-- which is why one frame is enough to carry a whole Hello -> Init handshake, and
-- why a diff written during frame N is observed by the client during frame N.

local Reassemble = require(script.Parent.Parent.Helpers.Reassemble)

local Link = {}
Link.__index = Link

export type Frame = { Player: any?, Bytes: buffer }

--- `MaxFrameBytes` models a transport that REFUSES an oversize payload, which is
--- the one thing neither this link nor test/Helpers/StubTransport could express
--- before. Without it nothing in the repo can construct the failure Scribe's
--- fragmentation exists to fix, so a spec asserting the fix passes whether or not
--- the mechanism is there. It also doubles as the ceiling Scribe reads off the
--- transport, so a spec can set one number and have both halves agree.
---
--- WHAT IT IS NOT: this is not a model of Roblox. A `FireClient` of 32 MiB of
--- incompressible data was delivered in full on a live server with a real client --
--- no raise, no drop, no disconnect, at roughly 30 MiB/s. Platform remotes do not
--- refuse. Set `MaxFrameBytes` because you want a hostile transport, not because
--- you are reproducing something the platform does; the specs that use it are
--- defence in depth against an adapter that raises, which is a contract the repo
--- already keeps a spec for (test/Specs/InitWindow.spec.luau). See
--- test/Sim/Uncertain.luau, entry U14, for the measurement and its boundaries.
function Link.new(config: { Name: string?, MaxFrameBytes: number?, MaxFramesPerPump: number? }?)
	local cfg = config or {}
	return setmetatable({
		Name = cfg.Name or "SimLink",
		MaxFrameBytes = cfg.MaxFrameBytes,
		-- Frames delivered per pump. Default unlimited, which is what every existing
		-- spec assumes. Setting it models a link that drains slower than the server
		-- fills it -- the only way to express "a snapshot that takes many frames to
		-- arrive", which is a state a fragmented Init can be in and an unfragmented
		-- one never could.
		MaxFramesPerPump = cfg.MaxFramesPerPump,
		RefusedOversize = 0,
		LargestRefused = 0,

		-- Undelivered, in order.
		ToClient = {} :: { Frame },
		ToServer = {} :: { Frame },
		-- Everything ever sent, for assertions.
		SentToClientLog = {} :: { Frame },
		SentToServerLog = {} :: { Frame },

		_clients = {} :: { { Player: any, Listener: ((bytes: buffer) -> ())? } },
		_serverListener = nil :: ((player: any, bytes: buffer) -> ())?,
	}, Link)
end

--------------------------------------------------------------------------------
-- Adapters
--------------------------------------------------------------------------------

--- The adapter the SERVER half is built with (passed to Bundle as `Transport`).
function Link.ServerAdapter(self)
	if self._serverAdapter then
		return self._serverAdapter
	end
	local adapter = {}
	adapter.Name = self.Name

	adapter.MaxFrameBytes = self.MaxFrameBytes

	function adapter.SendToClient(_self: any, player: any, bytes: buffer)
		local cap = self.MaxFrameBytes
		if cap and buffer.len(bytes) > cap then
			-- Raise, the way a hostile or adapter-wrapped transport can. NOT the way a
			-- Roblox remote does -- measured, a 32 MiB FireClient is delivered in full
			-- (Uncertain.luau, U14). Scribe pcalls the send, so this becomes SEND_FAIL
			-- rather than unwinding the flush -- which is the behaviour the fix has to
			-- survive, whoever raises.
			self.RefusedOversize += 1
			self.LargestRefused = math.max(self.LargestRefused, buffer.len(bytes))
			error(`sim link: payload of {buffer.len(bytes)} exceeds {cap}`, 0)
		end
		local frame = { Player = player, Bytes = bytes }
		table.insert(self.SentToClientLog, frame)
		table.insert(self.ToClient, frame)
	end

	function adapter.SendToAllClients(_self: any, bytes: buffer)
		adapter:SendToClient(nil, bytes)
	end

	function adapter.ListenServer(_self: any, callback: (player: any, bytes: buffer) -> ())
		self._serverListener = callback
	end

	-- Present so Transport.Resolve's validation passes whichever side it thinks it
	-- is on; the server half never calls them.
	function adapter.SendToServer() end
	function adapter.ListenClient() end

	self._serverAdapter = adapter
	return adapter
end

--- The adapter ONE client is built with (passed to Client.new as
--- `options.Transport`).
---
--- All four members are present on purpose. `Transport.Resolve` picks which two
--- it validates from `RunService:IsServer()` (src/Internal/Transport.luau:111),
--- and the harness pins that TRUE -- so a client adapter carrying only the client
--- members is rejected at construction with a message about the server ones.
function Link.ClientAdapter(self, player: any)
	local record = { Player = player, Listener = nil :: ((bytes: buffer) -> ())? }
	table.insert(self._clients, record)

	local adapter = {}
	adapter.Name = self.Name

	function adapter.SendToServer(_self: any, bytes: buffer)
		local frame = { Player = player, Bytes = bytes }
		table.insert(self.SentToServerLog, frame)
		table.insert(self.ToServer, frame)
	end

	function adapter.ListenClient(_self: any, callback: (bytes: buffer) -> ())
		record.Listener = callback
	end

	-- Inert, and inert deliberately rather than pointed at the shared link: a
	-- client that reached ListenServer would silently steal the SERVER's inbound
	-- callback, and the failure would look like "the server stopped receiving".
	function adapter.SendToClient() end
	function adapter.ListenServer() end

	self._clientAdapters = self._clientAdapters or {}
	self._clientAdapters[player] = adapter
	return adapter
end

--- Forget a client's listener (models the player's client going away).
function Link.DetachClient(self, player: any)
	for index, record in self._clients do
		if record.Player == player then
			table.remove(self._clients, index)
			break
		end
	end
	if self._clientAdapters then
		self._clientAdapters[player] = nil
	end
end

--------------------------------------------------------------------------------
-- Delivery
--------------------------------------------------------------------------------

--- Deliver every queued client -> server frame.
function Link.PumpToServer(self, count: number?)
	local remaining = count or math.huge
	while remaining > 0 do
		local frame = table.remove(self.ToServer, 1)
		if frame == nil then
			break
		end
		remaining -= 1
		if self._serverListener then
			self._serverListener(frame.Player, frame.Bytes)
		end
	end
end

--- Deliver every queued server -> client frame.
---
--- A frame addressed to a player reaches only that player's listener; a
--- nil-addressed frame is a broadcast and reaches every attached client. That
--- asymmetry IS the visibility test: a spec asserting that ServerOnly data never
--- reaches player B is only meaningful if a frame addressed to A cannot arrive at
--- B by accident of the harness.
function Link.PumpToClient(self, count: number?)
	local remaining = count or self.MaxFramesPerPump or math.huge
	while remaining > 0 do
		local frame = table.remove(self.ToClient, 1)
		if frame == nil then
			break
		end
		remaining -= 1
		for _, record in self._clients do
			if record.Listener and (frame.Player == nil or frame.Player == record.Player) then
				record.Listener(frame.Bytes)
			end
		end
	end
end

--- Drain both directions until nothing is left, bounded.
---
--- Bounded because delivery can create more work: an inbound Hello makes the
--- server send an Init synchronously, and a client applying an Init can send
--- something back. An unbounded loop would be a hang rather than a failure, and a
--- hang that only shows up as the runner's 10-second timeout proves nothing.
function Link.Pump(self, rounds: number?)
	for _ = 1, rounds or 8 do
		if #self.ToServer == 0 and #self.ToClient == 0 then
			return
		end
		self:PumpToServer()
		self:PumpToClient()
	end
end

--- Drop queued frames without delivering them (packet loss).
function Link.DropToClient(self, count: number?)
	for _ = 1, count or #self.ToClient do
		table.remove(self.ToClient, 1)
	end
end

function Link.DropToServer(self, count: number?)
	for _ = 1, count or #self.ToServer do
		table.remove(self.ToServer, 1)
	end
end

--- Inject a raw frame as if a (possibly hostile) client sent it.
function Link.InjectToServer(self, player: any, bytes: buffer)
	if self._serverListener then
		self._serverListener(player, bytes)
	end
end

--- Inject a raw frame straight into one client's listener, bypassing the server.
function Link.InjectToClient(self, player: any, bytes: buffer)
	for _, record in self._clients do
		if record.Player == player and record.Listener then
			record.Listener(bytes)
		end
	end
end

--- Every frame ever sent to `player`, broadcasts included.
function Link.FramesFor(self, player: any?): { Frame }
	local out = {}
	for _, frame in self.SentToClientLog do
		if player == nil or frame.Player == player or frame.Player == nil then
			table.insert(out, frame)
		end
	end
	return Reassemble.Logical(out)
end

--- Every frame ever sent to `player` and addressed to them SPECIFICALLY.
---
--- Separate from FramesFor because the two answer different questions and mixing
--- them is how a visibility assertion quietly stops meaning anything: "did B
--- receive this" includes broadcasts, "was this sent to B" does not.
function Link.AddressedTo(self, player: any): { Frame }
	local out = {}
	for _, frame in self.SentToClientLog do
		if frame.Player == player then
			table.insert(out, frame)
		end
	end
	return Reassemble.Logical(out)
end

return Link
