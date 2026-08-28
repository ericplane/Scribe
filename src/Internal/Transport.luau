--!strict
-- Transport. A transport moves opaque buffers; Scribe owns serialization, batching
-- and RPC correlation. "Default" is two RemoteEvents under a folder in
-- ReplicatedStorage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Parent.Types)

--- A replication channel. The send methods MUST NOT YIELD: Scribe calls them from
--- inside the handshake and from the per-frame flush, and one that parks there
--- stalls that frame's remaining work for every player. Buffer and return instead.
---
--- Re-exported from Types so what a game sees and what Resolve returns cannot drift.
export type ScribeTransport = Types.ScribeTransport

local FOLDER_PREFIX = "ScribeTransport"

local Transport = {}

-- Two Scribe instances listening on the same RemoteEvents would receive each
-- other's frames and fail schema decoding; fail loudly at startup instead.
local boundServerChannels: { [string]: boolean } = {}

-- How to hand a claimed channel back, keyed by folder name. The claim above is
-- module-global and outlives any one bundle: without a release, a stopped bundle
-- keeps its channel and its OnServerEvent listener for the rest of the process, so
-- client frames still reach a bundle whose save paths are dead.
local channelReleases: { [string]: () -> () } = {}

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
	-- Everything this channel connects, so ReleaseChannel can undo it. Declared out
	-- here because ListenServer closes over it; stays nil on the client, which has no
	-- claim to release.
	local serverConnections: { RBXScriptConnection }? = nil

	if RunService:IsServer() then
		if boundServerChannels[name] then
			error(
				`Scribe: another Scribe instance is already using the "{channel or "Default"}" transport channel; `
					.. "give each instance a distinct TransportChannel option",
				0
			)
		end
		boundServerChannels[name] = true
		-- Recorded on the channel rather than returned from ListenServer, which would
		-- widen the public ScribeTransport signature custom adapters are written to.
		local connections: { RBXScriptConnection } = {}
		serverConnections = connections
		channelReleases[name] = function()
			for _, connection in connections do
				pcall(function()
					connection:Disconnect()
				end)
			end
			table.clear(connections)
		end
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
			local connection = up.OnServerEvent:Connect(function(player: Player, bytes: any)
				-- Validated here so adapters and Scribe's decoder can assume buffers.
				if typeof(bytes) == "buffer" then
					callback(player, bytes)
				end
			end)
			-- Only on the server, where serverConnections exists.
			if serverConnections ~= nil then
				table.insert(serverConnections, connection)
			end
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

--- Hand a Default channel back, so a later bundle in this process can claim it.
--- Disconnects what the channel connected and clears the claim. Idempotent, and a
--- no-op for a name that was never bound. Call it only from the scope that built the
--- channel: a bundle on a custom transport releasing Default would take it from
--- whoever legitimately holds it.
function Transport.ReleaseChannel(channel: string?)
	local name = folderName(channel)
	local release = channelReleases[name]
	channelReleases[name] = nil
	boundServerChannels[name] = nil
	if release ~= nil then
		release()
	end
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
