--!strict
-- React adapter. Copy into your game; not part of the Scribe package.
--   local Scribe = require(path.to.ScribeReact)(React)
--   local coins = Scribe.useScribe(Data.Coins)          -- number; re-renders
--   local coins = Scribe.useScribeBinding(Data.Coins)   -- Binding<number>; property only
-- Uses jsdotlua React 17.2.1 hooks.

export type Disconnect = () -> ()

export type Readable<T> = {
	--[[
	Returns the current value.
	]]
	read Get: () -> T,
	--[[
	Runs on future changes and returns a disconnect function.
	]]
	read Changed: (callback: (new: T, old: T) -> ()) -> Disconnect,
}

-- Matches react-lua's binding type.
type CoreBinding<T> = {
	--[[
	Returns the current binding value.
	]]
	getValue: (self: CoreBinding<T>) -> T,
	_source: string?,
}
type BindingMap = {
	--[[
	Creates a binding that transforms this binding's value.
	]]
	map: <T, U>(self: CoreBinding<T> & BindingMap, (T) -> U) -> BindingMap & CoreBinding<U>,
}
export type Binding<T> = CoreBinding<T> & BindingMap

export type React = {
	read useState: (initialState: any) -> (any, any),
	read useEffect: (create: any, deps: any) -> (),
	read useBinding: (initialValue: any) -> (any, any),
}

export type Adapter = {
	--[[
	Tracks an accessor and re-renders when it changes.
	]]
	useScribe: <T>(accessor: Readable<T>) -> T,
	--[[
	Updates a bound property without re-rendering.
	]]
	useScribeBinding: <T>(accessor: Readable<T>) -> Binding<T>,
}

--[[
Creates React hooks for Scribe accessors.
]]
return function(React: React): Adapter
	local function useScribe<T>(accessor: Readable<T>): T
		local state: T, setValue: (T) -> () = React.useState(accessor.Get)
		React.useEffect(function()
			-- Catch writes between render and the effect.
			setValue(accessor.Get())
			return accessor.Changed(function(new)
				setValue(new)
			end)
		end, { accessor })
		return state
	end

	local function useScribeBinding<T>(accessor: Readable<T>): Binding<T>
		local binding: Binding<T>, setBinding: (T) -> () = React.useBinding(accessor.Get())
		React.useEffect(function()
			setBinding(accessor.Get())
			return accessor.Changed(function(new)
				setBinding(new)
			end)
		end, { accessor })
		return binding
	end

	return {
		useScribe = useScribe,
		useScribeBinding = useScribeBinding,
	}
end
