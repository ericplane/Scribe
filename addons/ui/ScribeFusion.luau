--!strict
-- Fusion adapter. Copy into your game; not part of the Scribe package.
--   local useScribe = require(path.to.ScribeFusion)(Fusion, scope)  -- 0.3
--   local useScribe = require(path.to.ScribeFusion)(Fusion)         -- 0.2
--   local coins: Fusion.Value<number>, disconnect = useScribe(Data.Coins)
-- Annotate the value with your Fusion version's type.

export type Disconnect = () -> ()

export type Readable<T> = {
	--[[
	Returns the current value.
	]]
	read Get: () -> T,
	--[[
	Runs now and on each change; returns a disconnect function.
	]]
	read Observe: (callback: (value: T) -> ()) -> Disconnect,
}

export type Fusion = {
	read Value: (...any) -> any,
}

export type Adapter = <T>(accessor: Readable<T>) -> (any, Disconnect)

--[[
Creates a Fusion adapter; pass a scope for Fusion 0.3.
]]
return function(Fusion: Fusion, scope: { any }?): Adapter
	--[[
	Tracks an accessor and registers cleanup with the supplied scope.
	]]
	return function<T>(accessor: Readable<T>): (any, Disconnect)
		local value = if scope ~= nil then Fusion.Value(scope, accessor.Get()) else Fusion.Value(accessor.Get())
		-- Observe delivers the current value immediately.
		local disconnect = accessor.Observe(function(new)
			value:set(new)
		end)
		if scope ~= nil then
			table.insert(scope, disconnect)
		end
		return value, disconnect
	end
end
