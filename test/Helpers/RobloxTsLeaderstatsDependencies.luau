--!nonstrict
-- Minimal instance tree for the compiled roblox-ts consumer in the headless runner.
local Signal = require(script.Parent.Parent.Parent.Scribe.Internal.Signal)

local function newInstance(className)
	local properties = { Name = className, ClassName = className, Children = {}, Destroyed = false }
	local instance
	local methods = {}
	function methods:IsA(name)
		return name == className or name == "Instance"
	end
	function methods:FindFirstChild(name)
		for _, child in properties.Children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function methods:GetChildren()
		return table.clone(properties.Children)
	end
	function methods:Destroy()
		for _, child in self:GetChildren() do
			child:Destroy()
		end
		self.Parent = nil
		properties.Destroyed = true
	end
	instance = setmetatable({}, {
		__index = function(_, key)
			return methods[key] or properties[key]
		end,
		__newindex = function(_, key, value)
			if key == "Parent" then
				local previous = properties.Parent
				if previous then
					table.remove(previous.Children, table.find(previous.Children, instance))
				end
				if value then
					table.insert(value.Children, instance)
				end
			elseif key == "Value" then
				assert(not properties.Destroyed, "writing a destroyed value")
			end
			properties[key] = value
		end,
	})
	return instance
end

return function(player)
	player.Children = {}
	function player:FindFirstChild(name)
		for _, child in self.Children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	return {
		Players = {
			PlayerAdded = Signal.new(),
			PlayerRemoving = Signal.new(),
			GetPlayers = function()
				return { player }
			end,
		},
		NewInstance = newInstance,
		IsServer = function()
			return true
		end,
		Warn = function(message)
			error(message)
		end,
	}
end
