--!strict
-- Loopback ScribeTransport for tests: captures every frame in both directions
-- and lets tests pump delivery manually (deterministic handshake tests) or
-- automatically (integration tests).

local StubTransport = {}

export type SentFrame = { Player: any?, Bytes: buffer }

function StubTransport.new(options: { AutoPump: boolean?, LocalPlayer: any? }?)
	local opts = options or {}
	local self = {} :: any

	self.Name = "Stub"
	self.AutoPump = opts.AutoPump == true
	self.LocalPlayer = opts.LocalPlayer

	self.ToClient = {} :: { SentFrame } -- undelivered, in order
	self.ToServer = {} :: { SentFrame }
	self.SentToClientLog = {} :: { SentFrame } -- everything ever sent
	self.SentToServerLog = {} :: { SentFrame }

	self._serverListener = nil :: ((player: any, bytes: buffer) -> ())?
	self._clientListener = nil :: ((bytes: buffer) -> ())?

	function self.SendToClient(_self: any, player: any, bytes: buffer)
		local frame = { Player = player, Bytes = bytes }
		table.insert(self.SentToClientLog, frame)
		table.insert(self.ToClient, frame)
		if self.AutoPump then
			self:PumpToClient()
		end
	end

	function self.SendToAllClients(_self: any, bytes: buffer)
		self:SendToClient(nil, bytes)
	end

	function self.ListenServer(_self: any, callback: (player: any, bytes: buffer) -> ())
		self._serverListener = callback
	end

	function self.SendToServer(_self: any, bytes: buffer)
		local frame = { Player = self.LocalPlayer, Bytes = bytes }
		table.insert(self.SentToServerLog, frame)
		table.insert(self.ToServer, frame)
		if self.AutoPump then
			self:PumpToServer()
		end
	end

	function self.ListenClient(_self: any, callback: (bytes: buffer) -> ())
		self._clientListener = callback
	end

	--- Deliver up to `count` (default all) queued server->client frames. Frames
	--- addressed to other players than LocalPlayer are skipped-but-consumed when
	--- a LocalPlayer is set (nil-addressed = broadcast, always delivered).
	function self.PumpToClient(_self: any?, count: number?)
		local remaining = count or math.huge
		while remaining > 0 do
			local frame = table.remove(self.ToClient, 1)
			if not frame then
				break
			end
			remaining -= 1
			local addressed = frame.Player == nil or self.LocalPlayer == nil or frame.Player == self.LocalPlayer
			if addressed and self._clientListener then
				self._clientListener(frame.Bytes)
			end
		end
	end

	function self.PumpToServer(_self: any?, count: number?)
		local remaining = count or math.huge
		while remaining > 0 do
			local frame = table.remove(self.ToServer, 1)
			if not frame then
				break
			end
			remaining -= 1
			if self._serverListener then
				self._serverListener(frame.Player, frame.Bytes)
			end
		end
	end

	--- Drop queued frames without delivering (packet-loss simulation).
	function self.DropToServer(_self: any?, count: number?)
		for _ = 1, count or #self.ToServer do
			table.remove(self.ToServer, 1)
		end
	end

	function self.DropToClient(_self: any?, count: number?)
		for _ = 1, count or #self.ToClient do
			table.remove(self.ToClient, 1)
		end
	end

	--- Inject a raw inbound frame as if a (possibly hostile) client sent it.
	function self.InjectToServer(_self: any?, player: any, bytes: buffer)
		if self._serverListener then
			self._serverListener(player, bytes)
		end
	end

	--- Inject a raw frame directly into the client listener (protocol-error
	--- simulations, bypassing the server).
	function self.InjectToClient(_self: any?, bytes: buffer)
		if self._clientListener then
			self._clientListener(bytes)
		end
	end

	--- All frames ever sent to `player` (nil = broadcasts included for any).
	function self.FramesFor(_self: any?, player: any?): { SentFrame }
		local out = {}
		for _, frame in self.SentToClientLog do
			if player == nil or frame.Player == player or frame.Player == nil then
				table.insert(out, frame)
			end
		end
		return out
	end

	return self
end

return StubTransport
