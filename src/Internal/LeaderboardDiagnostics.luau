--!strict
-- Passive registry; each running bundle owns its provider.

local Types = require(script.Parent.Parent.Types)

type Provider = () -> { [string]: Types.LeaderboardStatusInfo }

local Diagnostics = {}
local nextId = 0
local providers: { [number]: Provider } = setmetatable({}, { __mode = "v" }) :: any

function Diagnostics.Register(provider: Provider): () -> ()
	nextId += 1
	local id = nextId
	providers[id] = provider
	return function()
		providers[id] = nil
	end
end

function Diagnostics.Snapshot(): { Types.LeaderboardSnapshotEntry }
	local out: { Types.LeaderboardSnapshotEntry } = {}
	for id, provider in providers do
		for name, status in provider() do
			local entry = table.clone(status) :: any
			entry.BundleId, entry.Name = id, name
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a: Types.LeaderboardSnapshotEntry, b: Types.LeaderboardSnapshotEntry)
		return if a.BundleId == b.BundleId then a.Name < b.Name else a.BundleId < b.BundleId
	end)
	return out
end

return Diagnostics
