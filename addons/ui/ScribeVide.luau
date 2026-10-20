--!strict
-- Vide adapter. Copy into your game; not part of the Scribe package.
--   local useScribe = require(path.to.ScribeVide)(vide)
--   local coins, disconnect = useScribe(Data.Coins) -- coins: Source<number>
-- Nullable or any-typed reads need a getter cast: (score :: () -> number?)().

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

-- Matches Vide's getter/setter overloads.
export type Source<T> = (() -> T) & ((value: T) -> T)

export type Vide = {
	read source: (value: any) -> any,
}

--[[
Creates a Vide adapter for Scribe accessors.
]]
return function(vide: Vide)
	--[[
	Tracks an accessor; pass the returned disconnect to vide.cleanup.
	]]
	return function<T>(accessor: Readable<T>): (Source<T>, Disconnect)
		local source: Source<T> = vide.source(accessor.Get())
		local disconnect = accessor.Observe(function(value)
			source(value)
		end)
		return source, disconnect
	end
end
