--!strict
-- UI adapter compatibility with copied MIT framework types. Not shipped.

local Scribe = require(script.Parent.Parent.Scribe)
local ScribeVide = require(script.Parent.Parent.Addons.UI.ScribeVide)
local ScribeReact = require(script.Parent.Parent.Addons.UI.ScribeReact)
local ScribeFusion = require(script.Parent.Parent.Addons.UI.ScribeFusion)

local bundle = Scribe({
	Template = {
		Coins = Scribe.Int(0, { Min = 0 }),
		Settings = { Music = true },
		Score = Scribe.Optional(Scribe.Int(0)),
		Stats = { Deaths = Scribe.Int(0), Playtime = Scribe.Int(0) },
	},
	ProfileStoreIndex = "TypeCheckAddons",
	ProfileKeyPrefix = "PLAYER_",
})
local Data = bundle.Client

-- Vide (src/source.luau) -------------------------------------------------------------
type VideSource<T> = (() -> T) & ((value: T) -> T)
local function videSource<T>(_initial_value: T): VideSource<T>
	return nil :: any
end
local vide = { source = videSource }

local useVide = ScribeVide(vide)
local coins, stopCoins = useVide(Data.Coins)
local read: number = coins()
local written: number = coins(5)
local asVide: VideSource<number> = coins
local asAdapter: ScribeVide.Source<number> = coins
local music = useVide(Data.Settings.Music)
local musicOn: boolean = music()
-- Nullable or any Vide sources need a cast to disambiguate reads.
local score = useVide(Data.Score)
local scoreNow: number? = (score :: () -> number?)()
local statName: string = "Deaths"
local stat = useVide(Data.Stats.Child(statName))
local statNow = (stat :: () -> any)()
stopCoins()

-- react-lua (shared/ReactTypes.luau, react/ReactHooks.luau) --------------------------
type CoreReactBinding<T> = {
	getValue: (self: CoreReactBinding<T>) -> T,
	_source: string?,
}
type ReactBindingMap = {
	map: <T, U>(self: CoreReactBinding<T> & ReactBindingMap, (T) -> U) -> ReactBindingMap & CoreReactBinding<U>,
}
type ReactBinding<T> = CoreReactBinding<T> & ReactBindingMap
type ReactBindingUpdater<T> = (T) -> ()
type BasicStateAction<S> = ((S) -> S) | S
-- Expanded Dispatch<BasicStateAction<S>>.
type SetState<S> = (BasicStateAction<S>) -> ()
-- selene: allow(unused_variable)
local function useState<S>(_initialState: (() -> S) | S, ...): (S, SetState<S>)
	return nil :: any, nil :: any
end
local function useBinding<T>(_initialValue: T): (ReactBinding<T>, ReactBindingUpdater<T>)
	return nil :: any, nil :: any
end
local function useEffect(_create: (() -> ()) | (() -> () -> ()), _deps: { any } | nil): () end
local React = { useState = useState, useBinding = useBinding, useEffect = useEffect }

local hooks = ScribeReact(React)
local count: number = hooks.useScribe(Data.Coins)
local binding = hooks.useScribeBinding(Data.Coins)
local current: number = binding:getValue()
local asReact: ReactBinding<number> = binding
local label = binding:map(function(c: number): string
	return tostring(c)
end)
local labelText: string = label:getValue()

-- Scoped Fusion (src/Types.luau) ---------------------------------------------------
type Task =
	Instance
	| RBXScriptConnection
	| () -> ()
	| { destroy: (unknown) -> () }
	| { Destroy: (unknown) -> () }
	| { disconnect: (unknown) -> () }
	| { Disconnect: (unknown) -> () }
	| { Task }
type Scope<Constructors = any> = { Task } & Constructors
type ScopedObject = {
	scope: Scope<unknown>?,
	oldestTask: unknown,
}
type GraphObject = ScopedObject & {
	createdAt: number,
	dependencySet: { [GraphObject]: unknown },
	dependentSet: { [GraphObject]: unknown },
	lastChange: number?,
	timeliness: "lazy" | "eager",
	validity: "valid" | "invalid" | "busy",
	_evaluate: (GraphObject) -> boolean,
}
type StateObject<T> = GraphObject & {
	type: "State",
	kind: string,
	_EXTREMELY_DANGEROUS_usedAsValue: T,
}
type Value<T, S = T> = StateObject<T> & {
	kind: "State",
	timeliness: "lazy",
	set: (Value<T, S>, newValue: S, force: boolean?) -> S,
	____phantom_setType: (never) -> S,
}
type ValueConstructor = <T>(scope: Scope<unknown>, initialValue: T) -> Value<T, any>
local Fusion = { Value = (nil :: any) :: ValueConstructor }
local scope: Scope<{}> = {}

-- Fusion callers supply their framework's Value type.
local useFusion = ScribeFusion(Fusion, scope)
local value: Value<number>, stopValue = useFusion(Data.Coins)
local setTo: number = value:set(5)
stopValue()

-- Fusion 0.2 (src/PubTypes.lua) --------------------------------------------------------
type Set<T> = { [T]: any }
type Dependency = {
	dependentSet: Set<Dependent>,
}
type Dependent = {
	update: (Dependent) -> boolean,
	dependencySet: Set<Dependency>,
}
type LegacyStateObject<T> = Dependency & {
	type: string,
	kind: string,
	get: (LegacyStateObject<T>, asDependency: boolean?) -> T,
}
type LegacyValue<T> = LegacyStateObject<T> & {
	set: (LegacyValue<T>, newValue: any, force: boolean?) -> (),
}
local function legacyValue<T>(_initialValue: T): LegacyValue<T>
	return nil :: any
end
local Fusion02 = { Value = legacyValue }

local useLegacy = ScribeFusion(Fusion02)
local legacy: LegacyValue<number>, stopLegacy = useLegacy(Data.Coins)
local legacyRead: number = legacy:get()
stopLegacy()

return {
	read,
	written,
	asVide,
	asAdapter,
	musicOn,
	scoreNow,
	statNow,
	count,
	current,
	asReact,
	labelText,
	setTo,
	legacyRead,
}
