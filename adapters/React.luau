--!strict
-- React adapter. Copy into your game; not part of the Scribe package.
--   local Scribe = require(path.to.React)(React)
--   local coins = Scribe.useScribe(Data.Coins)          -- re-renders
--   local coins = Scribe.useScribeBinding(Data.Coins)   -- property only
--
-- useState + useEffect, not useSyncExternalStore: that is React 18 and jsdotlua
-- React 17.2.1 does not export it.

return function(React: any)
	local Adapter = {}

	--- State tracking one accessor. Re-renders on every change.
	function Adapter.useScribe(accessor: any): any
		local value, setValue = React.useState(accessor.Get)
		React.useEffect(function()
			-- Re-read before subscribing: a write landing between render and effect is
			-- otherwise missed, and the UI sits on the stale first value forever.
			setValue(accessor.Get())
			return accessor.Changed(function(new)
				setValue(new)
			end)
		end, { accessor })
		return value
	end

	--- A binding instead of state: updates the property without re-rendering. Prefer it
	--- for a value that only feeds Text or Size.
	function Adapter.useScribeBinding(accessor: any): any
		local binding, setBinding = React.useBinding(accessor.Get())
		React.useEffect(function()
			setBinding(accessor.Get())
			return accessor.Changed(function(new)
				setBinding(new)
			end)
		end, { accessor })
		return binding
	end

	return Adapter
end
