--!strict
-- Declarator markers. Declarators return marker tables at
-- runtime (cast to their base Luau type at the type level); the template
-- compiler strips them into (defaultValue, schemaMeta) and deep-freezes the rest.

local MARKER_KEY = "__scribeMarker"

export type MarkerKind =
	"Int"
	| "Number"
	| "Big"
	| "String"
	| "Enum"
	| "Flags"
	| "Timed"
	| "Datatype"
	| "Dynamic"
	| "Derived"
	| "Optional"
	| "ArrayOf"
	| "SetOf"
	| "DictOf"
	| "MapOf"
	| "ServerOnly"
	| "Shared"
	| "Session"

export type Meta = {
	Min: number?,
	Max: number?,
	-- Scribe.Number only: opts the field out of f64 on the wire. "f32" selects
	-- IEEE binary32; a positive number selects a fixed-point grid of that step
	-- over [Min, Max]. Absent means f64, which is the default and stays it.
	Precision: (number | string)?,
	MaxLength: number?,
	Members: { string }?,
	Datatype: string?, -- typeof() name for Datatype markers (e.g. "Vector3")
	Factory: (() -> any)?, -- Dynamic markers: produces the per-new-profile default
	Inputs: { string }?, -- Derived markers: dotted paths of the fields it reads
	Compute: ((...any) -> any)?, -- Derived markers: pure function of those inputs
	Element: any?, -- ArrayOf/DictOf markers: the raw element shape, compiled into AnyChild
	MaxItems: number?, -- ArrayOf: cardinality cap
	Evict: string?, -- ArrayOf: "Front" or "Back", which end an Insert at the cap drops
	Unique: boolean?, -- SetOf: entries are deduplicated and kept in sorted order
	KeyType: string?, -- MapOf: "integer" or "string"
	MaxKeys: number?, -- DictOf/MapOf: cardinality cap
	MaxKeyLength: number?, -- DictOf: per-key byte cap
}

local Marker = {}

function Marker.make(kind: MarkerKind, default: any, meta: Meta?): any
	local marker = {
		[MARKER_KEY] = kind,
		Default = default,
		Meta = meta,
	}
	-- For Timed fields the static type is { __scribeTimed: T }; the type
	-- function keys off that property name, the runtime keys off MARKER_KEY.
	if kind == "Timed" then
		(marker :: any).__scribeTimed = default
	end
	return marker
end

-- Returns (kind, default, meta) when the value is a marker, otherwise nil.
function Marker.inspect(value: any): (MarkerKind?, any, Meta?)
	if type(value) == "table" and rawget(value, MARKER_KEY) ~= nil then
		return rawget(value, MARKER_KEY) :: MarkerKind, rawget(value, "Default"), rawget(value, "Meta")
	end
	return nil, nil, nil
end

Marker.KEY = MARKER_KEY

return Marker
