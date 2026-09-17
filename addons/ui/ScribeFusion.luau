--!strict
-- Fusion adapter. Copy into your game; not part of the Scribe package.
--   local useScribe = require(path.to.ScribeFusion)(Fusion, scope)  -- 0.3
--   local useScribe = require(path.to.ScribeFusion)(Fusion)         -- 0.2
--   local coins, disconnect = useScribe(Data.Coins)
-- With a scope the disconnect is also registered in it, so doCleanup(scope) runs it.

export type Disconnect = () -> ()

--- `scope` selects the calling convention: pass it on 0.3, omit it on 0.2.
return function(Fusion: any, scope: any?)
	--- A Value tracking one accessor. The disconnect is returned either way; with a
	--- scope it is registered there too, and a second call is a no-op.
	return function(accessor: any): (any, Disconnect)
		local value = if scope ~= nil then Fusion.Value(scope, accessor.Get()) else Fusion.Value(accessor.Get())
		-- Observe, not Changed: it delivers the current value before returning.
		local disconnect = accessor.Observe(function(new)
			value:set(new)
		end)
		if scope ~= nil then
			table.insert(scope, disconnect)
		end
		return value, disconnect
	end
end
