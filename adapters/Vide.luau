--!strict
-- Vide adapter. Copy into your game; not part of the Scribe package.
--   local useScribe = require(path.to.Vide)(vide)
--   local coins, disconnect = useScribe(Data.Coins)

export type Disconnect = () -> ()

return function(vide: any)
	--- A source tracking one accessor. Hand the disconnect to `vide.cleanup`.
	return function(accessor: any): (any, Disconnect)
		local source = vide.source(accessor.Get())
		local disconnect = accessor.Observe(source)
		return source, disconnect
	end
end
