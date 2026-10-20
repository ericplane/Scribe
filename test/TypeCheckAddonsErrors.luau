--!strict
-- EXPECTED_ERRORS: 8
-- Each adapter misuse must report one type error.
local Scribe = require(script.Parent.Parent.Scribe)
local ScribeVide = require(script.Parent.Parent.Addons.UI.ScribeVide)
local ScribeReact = require(script.Parent.Parent.Addons.UI.ScribeReact)
local ScribeFusion = require(script.Parent.Parent.Addons.UI.ScribeFusion)

local bundle = Scribe({
	Template = { Coins = Scribe.Int(0) },
	ProfileStoreIndex = "TypeCheckAddonsErrors",
	ProfileKeyPrefix = "PLAYER_",
})
local Data = bundle.Client

local useVide = ScribeVide({ source = (nil :: any) :: (value: any) -> any })
local coins = useVide(Data.Coins)
local _wrongRead: string = coins() -- 1: a Source<number> reads a number
coins("five") -- 2: and sets a number
useVide(5) -- 3: not an accessor

local hooks = ScribeReact({
	useState = (nil :: any) :: (any) -> (any, any),
	useEffect = (nil :: any) :: (any, any) -> (),
	useBinding = (nil :: any) :: (any) -> (any, any),
})
local _wrongState: boolean = hooks.useScribe(Data.Coins) -- 4: the state is a number
local _wrongBinding: string = hooks.useScribeBinding(Data.Coins):getValue() -- 5: so is the binding's value

local useFusion = ScribeFusion({ Value = (nil :: any) :: (...any) -> any })
useFusion("Coins") -- 6: not an accessor

ScribeVide({}) -- 7: no source
ScribeReact({ useState = (nil :: any) :: (any) -> (any, any) }) -- 8: missing useEffect and useBinding
