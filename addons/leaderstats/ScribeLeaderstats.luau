--!strict
-- An opt-in, one-way bridge from Scribe accessors to Roblox's player list.
-- Every selected value becomes public, regardless of its template visibility.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

export type Stats = { [string]: string }
export type Handle = { Stop: (self: Handle) -> () }
export type DataAPI = {
	WaitForData: (player: Player, timeout: number?) -> (any?, string?),
	SessionEnded: { Connect: (self: any, callback: (player: Player, reason: string) -> ()) -> any },
}
--- Test dependencies; normal game code omits this argument.
export type Dependencies = {
	Players: any?,
	NewInstance: ((className: string) -> any)?,
	IsServer: (() -> boolean)?,
	Warn: ((message: string) -> ())?,
}

local ScribeLeaderstats = {}
type Definition = { Name: string, Path: string, Segments: { string } }
local active: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local classes = { number = "NumberValue", string = "StringValue", boolean = "BoolValue" }
local LOAD_WAIT = 10

local function validText(value: any): boolean
	return type(value) == "string" and #value > 0 and utf8.len(value) ~= nil and string.find(value, "%c") == nil
end

local function scalarClass(value: any): string?
	if type(value) == "number" and (value ~= value or math.abs(value) == math.huge) then
		return nil
	end
	return (classes :: any)[type(value)]
end

function ScribeLeaderstats.Start(data: DataAPI, stats: Stats, dependencies: Dependencies?): Handle
	local deps: Dependencies = dependencies or {}
	local isServer = deps.IsServer or function()
		return RunService:IsServer()
	end
	assert(isServer(), "ScribeLeaderstats: Start must run on the server")
	assert(
		type(data) == "table" and type(data.WaitForData) == "function" and data.SessionEnded ~= nil,
		"ScribeLeaderstats: expected Scribe's server Data API"
	)
	assert(not active[data], "ScribeLeaderstats: already started for this Data API; Stop() the running one first")
	assert(type(stats) == "table", "ScribeLeaderstats: stats must map display names to paths")
	local definitions: { Definition } = {}
	for name, path in stats do
		assert(
			validText(name),
			"ScribeLeaderstats: display names must be non-empty UTF-8 strings without control characters"
		)
		assert(validText(path), `ScribeLeaderstats: invalid path for "{name}"`)
		local segments = string.split(path, ".")
		for _, segment in segments do
			assert(#segment > 0, `ScribeLeaderstats: invalid path "{path}"`)
		end
		table.insert(definitions, { Name = name, Path = path, Segments = segments })
	end
	assert(#definitions > 0, "ScribeLeaderstats: configure at least one stat")
	table.sort(definitions, function(a: Definition, b: Definition)
		return a.Name < b.Name
	end)

	local players: any = deps.Players or Players
	local create = deps.NewInstance or function(className: string): any
		return Instance.new(className)
	end
	local report = deps.Warn or warn
	local stopped = false
	local states: { [any]: any } = {}
	local connections: { any } = {}
	local handle = {} :: Handle

	local function release(player: any)
		local state = states[player]
		if not state then
			return
		end
		states[player] = nil
		for _, disconnect in state.Disconnects do
			disconnect()
		end
		for _, instance in state.Values do
			instance:Destroy()
		end
		-- Another script may have added children to our folder after startup.
		-- Never destroy those children or a folder we did not create.
		if state.OwnFolder and state.Folder and #state.Folder:GetChildren() == 0 then
			state.Folder:Destroy()
		end
	end

	local function mount(player: any, state: any, accessor: any)
		local resolved = {}
		local folder = player:FindFirstChild("leaderstats")
		assert(folder == nil or folder:IsA("Folder"), "an existing leaderstats instance is not a Folder")
		-- Validate every selected value before adding any instances or observers.
		for _, definition in definitions do
			assert(
				folder == nil or folder:FindFirstChild(definition.Name) == nil,
				`stat "{definition.Name}" already exists`
			)
			local node = accessor
			for _, segment in definition.Segments do
				node = node.Child(segment)
			end
			local value = node.Get()
			local className = scalarClass(value)
			assert(className ~= nil, `path "{definition.Path}" must contain a finite number, string, or boolean`)
			table.insert(resolved, { Definition = definition, Node = node, Value = value, Class = className })
		end
		state.OwnFolder = folder == nil
		if folder == nil then
			folder = create("Folder")
			folder.Name = "leaderstats"
		end
		state.Folder = folder
		for _, item in resolved do
			local instance = create(item.Class)
			table.insert(state.Values, instance)
			instance.Name = item.Definition.Name
			instance.Value = item.Value
			instance.Parent = folder
			local disconnect = item.Node.Observe(function(value: any)
				if stopped or states[player] ~= state then
					return
				end
				if scalarClass(value) ~= item.Class then
					release(player)
					report(
						`ScribeLeaderstats: removed stats for {player.Name}: path "{item.Definition.Path}" changed type or became absent`
					)
					return
				end
				if instance.Value ~= value then
					instance.Value = value
				end
			end)
			if states[player] ~= state then
				disconnect()
				return
			end
			table.insert(state.Disconnects, disconnect)
		end
		if state.OwnFolder then
			folder.Parent = player
		end
	end

	local function join(player: any)
		if stopped or states[player] ~= nil then
			return
		end
		local state = { Disconnects = {}, Values = {} }
		states[player] = state
		task.spawn(function()
			-- WaitForData owns a signal connection while yielding. Let each bounded
			-- wait finish instead of cancelling its coroutine and stranding it.
			while not stopped and states[player] == state do
				local ok, accessor, reason = pcall(data.WaitForData, player, LOAD_WAIT)
				if stopped or states[player] ~= state then
					return
				end
				if ok and accessor ~= nil then
					local mounted, err = pcall(mount, player, state, accessor)
					if not mounted then
						release(player)
						report(`ScribeLeaderstats: could not attach stats for {player.Name}: {tostring(err)}`)
					end
					return
				elseif ok and reason == "still-loading" then
					continue
				else
					release(player)
					if not ok then
						report(`ScribeLeaderstats: could not load stats for {player.Name}: {tostring(accessor)}`)
					end
					return
				end
			end
		end)
	end

	function handle:Stop()
		if stopped then
			return
		end
		stopped = true
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		for player in states do
			release(player)
		end
		active[data] = nil
	end

	active[data] = true
	local ok, err = pcall(function()
		table.insert(connections, (players.PlayerAdded:Connect(join)))
		table.insert(connections, (players.PlayerRemoving:Connect(release)))
		table.insert(connections, data.SessionEnded:Connect(release))
		for _, player in players:GetPlayers() do
			join(player)
		end
	end)
	if not ok then
		handle:Stop()
		error(err, 2)
	end
	return handle
end

return table.freeze(ScribeLeaderstats)
