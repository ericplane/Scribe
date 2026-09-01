--!strict
-- Fusion adapter. Copy into your game; not part of the Scribe package.
--   local useScribe = require(path.to.Fusion)(Fusion, scope)  -- 0.3
--   local useScribe = require(path.to.Fusion)(Fusion)         -- 0.2
--   local coins, disconnect = useScribe(Data.Coins)

export type Disconnect = () -> ()

--- `scope` selects the calling convention: pass it on 0.3, omit it on 0.2.
return function(Fusion: any, scope: any?)
	--- A Value tracking one accessor. A 0.3 scope destroys the Value but never the
	--- Scribe listener, so still call the disconnect.
	return function(accessor: any): (any, Disconnect)
		local value = if scope ~= nil then Fusion.Value(scope, accessor.Get()) else Fusion.Value(accessor.Get())
		-- Observe, not Changed: it delivers the current value before returning.
		local disconnect = accessor.Observe(function(new)
			value:set(new)
		end)
		return value, disconnect
	end
end
