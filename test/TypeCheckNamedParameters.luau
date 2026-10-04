--!strict
-- LSP probes also check callback inference without explicit annotations.
local Scribe = require(script.Parent.Parent.Scribe)

local template = {
	Coins = Scribe.Int(0),
	Names = Scribe.ArrayOf(Scribe.String("")),
	Scores = Scribe.MapOf("integer", Scribe.String("")),
	Nested = { Label = "" },
}

local products: { [string]: Scribe.ProductConfig<typeof(template)> } = {
	Coins = {
		Id = 1,
		Grant = function(data)
			-- named: grant-changed
			data.Coins.Changed(function(newValue, oldValue)
				print(newValue + oldValue)
			end)
		end,
	},
}

local bundle = Scribe({
	Template = template,
	ServerStore = { Wave = 0 },
	Products = products,
	ProfileStoreIndex = "NamedParameterTypes",
	ProfileKeyPrefix = "PLAYER_",
})

return function(player: Player)
	local data = bundle.Server[player]
	-- named: server-changed
	data.Coins.Changed(function(newValue, oldValue)
		print(newValue + oldValue)
	end)
	-- named: client-observe
	bundle.Client.Coins.Observe(function(value)
		print(value + 1)
	end)
	-- named: update
	data.Coins.Update(function(value)
		return value + 1
	end)
	-- named: child-changed
	data.Scores.OnChildChanged(function(key, newValue, oldValue)
		print(key + 1, if newValue then #newValue else 0, if oldValue then #oldValue else 0)
	end)
	-- named: insert-event
	data.Names.OnInsert(function(value, index)
		print(#value, index + 1)
	end)
	-- named: remove-event
	data.Names.OnRemove(function(value, index)
		print(#value, index + 1)
	end)
	-- named: key-added
	data.Scores.OnKeyAdded(function(key, value)
		print(key + 1, #value)
	end)
	-- named: key-removed
	data.Scores.OnKeyRemoved(function(key, value)
		print(key + 1, #value)
	end)
	-- named: nested-changed
	data.Nested.Label.Changed(function(newValue, oldValue)
		print(#newValue + #oldValue)
	end)
	local firstName = data.Names.Child(1)
	-- named: array-child-changed
	firstName.Changed(function(newValue, oldValue)
		print(#newValue + #oldValue)
	end)
	-- named: store-changed
	bundle.Server.ServerStore.Wave.Changed(function(newValue, oldValue)
		print(newValue + oldValue)
	end)
	-- named: set
	data.Coins.Set(1, true)
	-- named: increment
	data.Coins.Increment(1, true)
	-- named: insert
	data.Names.Insert("Alice", 1, true)
end
