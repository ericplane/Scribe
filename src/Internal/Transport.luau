--!strict
-- Transport. The transport moves opaque buffers; Scribe owns
-- serialization, batching, and RPC correlation. "Default" is two RemoteEvents
-- carrying buffers under a Scribe folder in ReplicatedStorage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type ScribeTransport = {
	Name: string,
	SendToClient: (self: any, player: Player, bytes: buffer) -> (),
	SendToAllClients: ((self: any, bytes: buffer) -> ())?,
	ListenServer: (self: any, callback: (player: Player, bytes: buffer) -> ()) -> (),
	SendToServer: (self: any, bytes: buffer) -> (),
	ListenClient: (self: any, callback: (bytes: buffer) -> ()) -> (),
}

local FOLDER_PREFIX = "ScribeTransport"

local Transport = {}

-- Two Scribe instances listening on the same RemoteEvents would receive each
-- other's frames and fail schema decoding; fail loudly at startup instead.
local boundServerChannels: { [string]: boolean } = {}

local function folderName(channel: string?): string
	if channel and channel ~= "" and channel ~= "Default" then
		return `{FOLDER_PREFIX}_{channel}`
	end
	return FOLDER_PREFIX
end

local function buildDefault(channel: string?): ScribeTransport
	local name = folderName(channel)
	local down: RemoteEvent
	local up: RemoteEvent

	if RunService:IsServer() then
		if boundServerChannels[name] then
			error(
				`Scribe: another Scribe instance is already using the "{channel or "Default"}" transport channel — `
					.. "give each instance a distinct TransportChannel option",
				0
			)
		end
		boundServerChannels[name] = true
		local folder = ReplicatedStorage:FindFirstChild(name)
		if not folder then
			local newFolder = Instance.new("Folder")
			newFolder.Name = name
			newFolder.Parent = ReplicatedStorage
			folder = newFolder
		end
		local function ensureRemote(remoteName: string): RemoteEvent
			local remote = (folder :: Instance):FindFirstChild(remoteName)
			if not remote then
				local newRemote = Instance.new("RemoteEvent")
				newRemote.Name = remoteName
				newRemote.Parent = folder
				remote = newRemote
			end
			return remote :: RemoteEvent
		end
		down = ensureRemote("Down")
		up = ensureRemote("Up")
	else
		local folder = ReplicatedStorage:WaitForChild(name)
		down = folder:WaitForChild("Down") :: RemoteEvent
		up = folder:WaitForChild("Up") :: RemoteEvent
	end

	return {
		Name = "Default",
		SendToClient = function(_, player: Player, bytes: buffer)
			down:FireClient(player, bytes)
		end,
		SendToAllClients = function(_, bytes: buffer)
			down:FireAllClients(bytes)
		end,
		ListenServer = function(_, callback: (player: Player, bytes: buffer) -> ())
			up.OnServerEvent:Connect(function(player: Player, bytes: any)
				-- Payload type is validated here so adapters and Scribe's
				-- decoder can assume buffers.
				if typeof(bytes) == "buffer" then
					callback(player, bytes)
				end
			end)
		end,
		SendToServer = function(_, bytes: buffer)
			up:FireServer(bytes)
		end,
		ListenClient = function(_, callback: (bytes: buffer) -> ())
			down.OnClientEvent:Connect(function(bytes: any)
				if typeof(bytes) == "buffer" then
					callback(bytes)
				end
			end)
		end,
	}
end

-- Resolve the Transport option: "Default", an adapter table, or nil.
function Transport.Resolve(spec: any, channel: string?): ScribeTransport
	if spec == nil or spec == "Default" then
		return buildDefault(channel)
	end
	if type(spec) == "table" then
		local required: { string } = if RunService:IsServer()
			then { "SendToClient", "ListenServer" }
			else { "SendToServer", "ListenClient" }
		for _, key in required do
			if type((spec :: any)[key]) ~= "function" then
				error(`Scribe: custom transport is missing "{key}" (see the ScribeTransport type)`, 0)
			end
		end
		return spec :: ScribeTransport
	end
	error(`Scribe: invalid Transport option ({typeof(spec)})`, 0)
end

return Transport
