--!strict
-- Template compiler + runtime schema derivation. Walks the user template with
-- sorted keys (deterministic on server and client), strips declarator markers,
-- assigns a u16 field ID to every static path node, and records declared
-- type/bounds/visibility metadata for validation and wire packing.

local Util = require(script.Parent.Util)
local Marker = require(script.Parent.Marker)
local Big = require(script.Parent.Big)
local Datatypes = require(script.Parent.Datatypes)
local DerivedModule = require(script.Parent.Derived)

--- A declared bound that is NaN or infinite cannot bound anything: nothing exceeds
--- math.huge, and every comparison against NaN is false.
local function isFiniteBound(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- The wire width a Scribe.Number takes, opt-in via Precision. FLOAT_F64 is the default
-- and is what an undeclared Number stays; Min/Max alone select nothing. FLOAT_F32 is
-- Precision = "f32", IEEE binary32 in 4 bytes. FLOAT_Q8/16/32 is Precision = <step>, a
-- fixed-point grid over [Min, Max] whose nearest-point index travels in the narrowest
-- of 1, 2 or 4 bytes that holds the step count.
-- Lives here rather than in Wire (where its sibling intWidth does) because the compiler
-- has to agree with the encoder and the decoder: "the declared bounds cannot be
-- represented in the chosen width" is a startup refusal.
local FLOAT_F64, FLOAT_F32, FLOAT_Q8, FLOAT_Q16, FLOAT_Q32 = 0, 1, 2, 3, 4

-- The extremes of IEEE binary32: the largest finite value and the smallest normal
-- magnitude. Wire.canSchemaEncode tests values against both, because a value outside
-- them must degrade to exact f64 rather than round to infinity or flush to zero.
local F32_MAX = 3.4028234663852886e38
local F32_MIN_NORMAL = 1.1754943508222875e-38
-- Largest grid index a fixed-point field can carry, i.e. the u32 the widest form
-- writes. A range needing more steps than this is refused at compile time.
local Q_MAX_STEPS = 4294967295

--- How many grid steps `[Min, Max]` needs at a step of `Precision`. The grid
--- index runs 0..steps INCLUSIVE, so a width holding `steps` holds every index.
local function quantSteps(min: number, max: number, precision: number): number
	return math.ceil((max - min) / precision)
end

export type Visibility = "Replicated" | "ServerOnly" | "Shared"

export type SchemaNode = {
	Id: number?, -- nil for dynamic (any) pseudo-nodes
	Name: string?,
	Path: { string },
	Kind: "leaf" | "table" | "any",
	ValueType: "number"
		| "int"
		| "boolean"
		| "string"
		| "enum"
		| "flags"
		| "big"
		| "buffer"
		| "datatype"
		| "table"
		| "any",
	Datatype: string?, -- typeof() name when ValueType == "datatype"
	Visibility: Visibility, -- who receives diffs
	Persist: boolean, -- false for a Scribe.Session subtree; orthogonal to Visibility
	Timed: boolean,
	Min: number?,
	Max: number?,
	-- Scribe.Number only, opt-in: nil is f64, "f32" is IEEE binary32, a positive
	-- number is the step of a fixed-point grid over [Min, Max]. Wire.floatPlan is the
	-- one place that turns this into a width.
	Precision: (number | string)?,
	MaxLength: number?,
	Members: { string }?,
	MemberIndex: { [string]: number }?, -- 0-based, for u8 packing
	Default: any,
	Factory: (() -> any)?, -- Scribe.Dynamic: seeds this field on a brand-new profile
	-- Scribe.Derived: computed from other declared fields, never written. Resolved in
	-- a post-pass (see Compile), because an input may name a root that has not been
	-- built yet when this node is created.
	Derived: {
		Inputs: { SchemaNode },
		InputPaths: { { string } },
		Compute: (...any) -> any,
		Transmit: boolean, -- server computes and REPLICATES (an input the audience cannot see)
		OfflineComputable: boolean, -- root-level, and every input persists
		Label: string,
	}?,
	Children: { [string]: SchemaNode }?,
	ChildOrder: { string }?, -- sorted; ordinal i encodes child ChildOrder[i]
	ChildOrdinal: { [string]: number }?,
	Parent: SchemaNode?,
	AnyChild: SchemaNode?, -- dynamic-key child: the compiled element schema on an
	-- ArrayOf/DictOf node (set at compile time), otherwise a generic pseudo-node
	-- synthesized lazily on first access
	HasPacked: boolean?, -- true if a declared descendant stores a different shape than
	-- it reads (a packed datatype buffer, a Scribe.Big pair); lets container reads
	-- skip the deep-unpack walk when there is nothing to convert
	-- Scribe.ArrayOf / Scribe.DictOf. `Container` is the discriminator (nil on every
	-- other node, untyped dynamic containers included); `IsElement` marks the compiled
	-- element root under AnyChild; `Closed` marks an element record whose field set is
	-- fixed, so an undeclared key is a write error rather than a synthesized `any` child.
	Container: ("Array" | "Dict")?,
	IsElement: boolean?,
	Closed: boolean?,
	-- Scribe.Optional: the field may legitimately be absent. Its Default is nil, so
	-- it is not seeded into a new profile and not filled into a partial element.
	Nullable: boolean?,
	-- Element default with ServerOnly subtrees removed, used when a client mirror
	-- materializes a fresh entry (see Node.resolveContainer).
	ClientDefault: any,
	MaxItems: number?,
	Evict: string?,
	Unique: boolean?,
	KeyType: string?,
	MaxKeys: number?,
	MaxKeyLength: number?,
}

export type Compiled = {
	Root: SchemaNode,
	ById: { [number]: SchemaNode },
	NodeCount: number,
	Hash: number,
	RootOrder: { string },
	-- Whether the template declares a Scribe.Shared root. Replication uses it to skip
	-- the per-player work only Shared data justifies: an O(N) broadcast on every leave
	-- and an O(N) entry scan on every join.
	HasShared: boolean,
	DynamicNodes: { SchemaNode }, -- fields with a Scribe.Dynamic factory, in id order
	DerivedNodes: { SchemaNode }, -- Scribe.Derived fields in topological order
	-- pathKey of an input (or any ancestor of one) -> the fields to recompute. A
	-- write looks up its own pathKey and finds every dependent in one hop.
	DerivedByWrite: { [string]: { SchemaNode } },
	-- Root views. Player is the compiled itself when no store is declared; views share
	-- everything but Root, RootOrder and HasShared by reference.
	Views: { Player: Compiled, Store: Compiled? },
	Config: CompileConfig,
}

export type CompileConfig = {
	ReplicateRobuxLog: boolean?,
	ReplicateInGameLog: boolean?,
	-- Roots owned by the server, not a player. Same compile state as the player roots,
	-- so one id space and one hash.
	ServerStore: { [string]: any }?,
}

local RESERVED_ROOT = "_Scribe"
local SESSION_ROOT = "_ScribeSession"
-- Cooldown slots share the flat _Scribe.Timed dict with timed-field pathKeys and
-- are namespaced by this prefix. Owned here (not in Server/Timed) so Compile can
-- reject a root field that would alias a cooldown slot.
local COOLDOWN_PREFIX = "@cd|"
-- Online-only cooldowns share that dict but hold remaining seconds rather than a
-- deadline. The prefixes differ at byte 4 ("|" vs "o"), so no wall-clock key text can
-- ever spell an online slot.
local ONLINE_COOLDOWN_PREFIX = "@cdo|"

local Template = {}

Template.FLOAT_F64 = FLOAT_F64
Template.FLOAT_F32 = FLOAT_F32
Template.FLOAT_Q8 = FLOAT_Q8
Template.FLOAT_Q16 = FLOAT_Q16
Template.FLOAT_Q32 = FLOAT_Q32
Template.F32_MAX = F32_MAX
Template.F32_MIN_NORMAL = F32_MIN_NORMAL
Template.Q_MAX_STEPS = Q_MAX_STEPS
Template.QuantSteps = quantSteps

--- The wire width `node` takes. Total by construction: every shape the validator
--- refuses answers FLOAT_F64 here, so a node that somehow reached the encoder
--- unvalidated gets the lossless encoding rather than a corrupt one.
function Template.FloatPlan(node: SchemaNode): number
	local p = node.Precision
	if p == nil then
		return FLOAT_F64
	end
	if p == "f32" then
		return FLOAT_F32
	end
	local min, max = node.Min, node.Max
	if type(p) ~= "number" or p ~= p or p <= 0 or p == math.huge or min == nil or max == nil or max < min then
		return FLOAT_F64
	end
	local steps = quantSteps(min, max, p)
	if steps < 256 then
		return FLOAT_Q8
	elseif steps < 65536 then
		return FLOAT_Q16
	elseif steps <= Q_MAX_STEPS then
		return FLOAT_Q32
	end
	return FLOAT_F64
end
Template.RESERVED_ROOT = RESERVED_ROOT
Template.SESSION_ROOT = SESSION_ROOT
Template.COOLDOWN_PREFIX = COOLDOWN_PREFIX
Template.ONLINE_COOLDOWN_PREFIX = ONLINE_COOLDOWN_PREFIX

local function compileError(path: { string }, message: string): never
	error(`Scribe: template error at "{table.concat(path, ".")}": {message}`, 0)
end

-- A Scribe declarator anywhere inside an array-like container would be silently
-- stored as its raw marker table instead of compiled into a schema field, so reject
-- the shape outright. A valid data blob contains no markers, so scanning it is safe.
local function rejectNestedMarkers(path: { string }, value: any)
	local function walk(v: any, where: string)
		if Marker.inspect(v) ~= nil then
			compileError(
				path,
				`"{where}" is a Scribe declarator inside an array-like container, which stores its `
					.. `entries as opaque data and so has no schema for the declarator to compile into. `
					.. `Declare the element shape instead: Scribe.ArrayOf(\{ ... }) for a list, or `
					.. `Scribe.DictOf(\{ ... }) for a string-keyed table. That is also the only way to `
					.. `store a Roblox datatype inside a container`
			)
		elseif type(v) == "table" then
			for k, child in v do
				walk(child, if where == "" then tostring(k) else where .. "." .. tostring(k))
			end
		end
	end
	for k, v in value do
		walk(v, tostring(k))
	end
end

-- Declarators that cannot appear inside an ArrayOf/DictOf element shape, each with
-- the reason it is unsound there. Scanned over the RAW shape at compile time so a
-- bad template fails at startup rather than behaving subtly wrong per element.
local FORBIDDEN_IN_ELEMENT: { [string]: string } = {
	Timed = "timed state is keyed by path and element paths are positional (an array index shifts on every"
		.. " insert or remove), so a running timer would resolve to the wrong element; store an expiry field"
		.. " on the element instead",
	Dynamic = "a Scribe.Dynamic factory seeds a field once per brand-new profile, and elements do not exist"
		.. " then; generate per-element values at Insert time",
	Derived = "a derived field reads a fixed set of declared paths, and element paths are positional (an array"
		.. " index shifts on every insert or remove), so its inputs would name a different entry after every"
		.. " structural write; derive at the root from a field the element writes instead",
	Shared = "Scribe.Shared is only supported on root fields",
	Session = "Scribe.Session is only supported on root fields",
}

local function rejectInElementShape(path: { string }, shape: any)
	local function walk(v: any)
		if type(v) ~= "table" then
			return
		end
		local kind, default, meta = Marker.inspect(v)
		if kind ~= nil then
			local reason = FORBIDDEN_IN_ELEMENT[kind :: string]
			if reason then
				compileError(path, `Scribe.{kind} is not supported inside an element shape: {reason}`)
			end
			if kind == "ArrayOf" or kind == "DictOf" or kind == "SetOf" or kind == "MapOf" then
				-- A nested container hides its shape in Meta.Element, not in Default.
				walk(if meta then meta.Element else nil)
			else
				walk(default)
			end
			return
		end
		for _, child in v do
			walk(child)
		end
	end
	walk(shape)
end

-- Whether reading this node (or anything below it) has to convert a stored shape back
-- to its read shape: a datatype packs to a buffer, a Scribe.Big stores a
-- { mantissa, exponent } pair. One predicate, so a third such type cannot reach some
-- read paths and miss the others.
local function isPacked(node: SchemaNode): boolean
	return node.ValueType == "datatype" or node.ValueType == "big" or node.HasPacked == true
end

local function checkContainerCap(path: { string }, label: string, value: any)
	if value == nil then
		return
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
		compileError(path, `{label} must be a positive integer`)
	end
end

-- Element subtrees are addressed only through AnyChild, never by field id, so they
-- carry none. See the id-less rationale at the ArrayOf/DictOf branch in buildNode.
local function clearIds(node: SchemaNode)
	node.Id = nil
	if node.Children then
		for _, child in node.Children do
			clearIds(child)
		end
	end
	if node.AnyChild then
		clearIds(node.AnyChild)
	end
end

-- Deepest declared level below and including `node`, counting a nested container's
-- element as one further level (an element is reached through a key of its own).
local function declaredDepth(node: SchemaNode): number
	local deepest = 0
	if node.Children then
		for _, child in node.Children do
			local d = declaredDepth(child)
			if d > deepest then
				deepest = d
			end
		end
	end
	if node.AnyChild then
		local d = declaredDepth(node.AnyChild)
		if d > deepest then
			deepest = d
		end
	end
	return deepest + 1
end

-- Element default with ServerOnly subtrees dropped, mirroring BuildDefaults'
-- buildClient. A client mirror seeds fresh entries from this, so that writing one
-- field of a new element cannot conjure a ServerOnly sibling's declared value.
local function buildClientDefault(node: SchemaNode): any
	if node.Visibility == "ServerOnly" then
		return nil
	end
	if node.Kind ~= "table" or not node.Children then
		return Util.deepClone(node.Default)
	end
	local out = {}
	for key, child in node.Children do
		local value = buildClientDefault(child)
		if value ~= nil then
			out[key] = value
		end
	end
	return out
end

local function checkDefaultValue(path: { string }, value: any)
	local t = typeof(value)
	if t == "table" then
		local hasNum, hasStr = false, false
		for k, v in value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				compileError(path, `unsupported key type "{kt}"`)
			end
			hasNum = hasNum or kt == "number"
			hasStr = hasStr or kt == "string"
			if hasNum and hasStr then
				-- A mixed table cannot be JSON-encoded, so the very first save of a
				-- new profile seeded with this default would fail outright.
				compileError(path, "a default cannot mix array indices and string keys (it would fail the save)")
			end
			-- A string default key becomes a persisted JSON object key, so it must
			-- be valid UTF-8 or the very first save of a new profile fails.
			if kt == "string" and not Util.isUtf8(k :: string) then
				compileError(path, `default key "{k}" contains invalid UTF-8 bytes`)
			end
			local childPath = table.clone(path)
			table.insert(childPath, tostring(k))
			checkDefaultValue(childPath, v)
		end
	elseif t ~= "boolean" and t ~= "number" and t ~= "string" and t ~= "buffer" then
		compileError(path, `unsupported value type "{t}" (only booleans, numbers, strings, buffers and tables persist)`)
	elseif t == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		compileError(path, "NaN/inf default")
	elseif t == "string" and not Util.isUtf8(value :: string) then
		-- A string default is seeded verbatim into every new profile and saved.
		compileError(path, "string default contains invalid UTF-8 bytes")
	end
end

-- Builds one schema node from a (possibly marker-wrapped) template value.
type PendingDerived = { Node: SchemaNode, InputPaths: { string }, Compute: (...any) -> any }
-- `Derived` is absent on the throwaway state an element shape compiles against; a
-- derived field is refused inside an element shape before it could be reached.
type CompileState = { NextId: number, ById: { [number]: SchemaNode }, Derived: { PendingDerived }? }

local function buildNode(
	state: CompileState,
	name: string?,
	rawValue: any,
	path: { string },
	inheritedVisibility: Visibility,
	inheritedPersist: boolean,
	parent: SchemaNode?
): SchemaNode
	-- A field name is a persisted JSON object key, so reject invalid UTF-8 at compile
	-- time rather than at the first save.
	if name ~= nil and not Util.isUtf8(name) then
		compileError(path, `field name contains invalid UTF-8 bytes`)
	end

	local visibility: Visibility = inheritedVisibility
	local persist: boolean = inheritedPersist
	-- Markers seen on THIS node, tracked separately from the inherited values so a
	-- nested ServerOnly under a ServerOnly parent is still allowed. Replication and
	-- persistence are independent axes: one of each combines, two of the same do not.
	local replicationSeen: string? = nil
	local sessionSeen = false
	local timed = false
	local derivedInputs: { string }? = nil
	local derivedCompute: ((...any) -> any)? = nil
	local dynamicSeen = false
	local meta: Marker.Meta? = nil
	local valueType: string? = nil
	local containerKind: ("Array" | "Dict")? = nil
	local containerDeclarator: string? = nil
	local nullable = false
	local value = rawValue

	-- Unwrap (possibly nested) markers, e.g. Scribe.Session wrapping a table
	-- whose fields use Scribe.Int.
	while true do
		local kind, default, markerMeta = Marker.inspect(value)
		if kind == nil then
			break
		end
		if kind == "Session" then
			if sessionSeen then
				compileError(path, "Scribe.Session is already applied to this field")
			end
			sessionSeen = true
			if #path > 1 then
				compileError(path, "Scribe.Session is only supported on root fields")
			end
			persist = false
		elseif kind == "ServerOnly" or kind == "Shared" then
			-- A field has ONE replication target, so these two cannot both apply:
			-- letting the inner win makes Scribe.Shared(Scribe.ServerOnly(x)) broadcast
			-- a field the outer wrapper says nobody should receive.
			if replicationSeen ~= nil then
				compileError(
					path,
					`Scribe.{replicationSeen} cannot wrap Scribe.{kind}: a field has one replication target, `
						.. `not two. Combine either one with Scribe.Session instead, which sets whether it saves.`
				)
			end
			replicationSeen = kind
			if kind == "Shared" and #path > 1 then
				compileError(path, "Scribe.Shared is only supported on root fields")
			end
			visibility = kind :: Visibility
		elseif kind == "Timed" then
			timed = true
		elseif kind == "Int" then
			valueType = "int"
			meta = markerMeta
		elseif kind == "Number" then
			valueType = "number"
			meta = markerMeta
		elseif kind == "Big" then
			valueType = "big"
			meta = markerMeta
		elseif kind == "String" then
			valueType = "string"
			meta = markerMeta
		elseif kind == "Enum" then
			valueType = "enum"
			meta = markerMeta
		elseif kind == "Flags" then
			valueType = "flags"
			meta = markerMeta
		elseif kind == "Datatype" then
			valueType = "datatype"
			meta = markerMeta
		elseif kind == "Optional" then
			-- Wraps another declarator: keep unwrapping so the inner type and bounds
			-- still compile, and drop the default to nil at the end of buildNode.
			nullable = true
		elseif kind == "ArrayOf" or kind == "DictOf" or kind == "SetOf" or kind == "MapOf" then
			-- The element shape lives in Meta.Element and the marker's Default is nil,
			-- so the `value = default` below ends the unwrap loop here. A SetOf is an
			-- Array container with a uniqueness invariant on top, so it reuses the
			-- whole element schema, wire and validation path.
			containerKind = if kind == "DictOf" or kind == "MapOf" then "Dict" else "Array"
			-- Keep the declarator the USER wrote: containerKind collapses SetOf into
			-- Array and MapOf into Dict, so error text built from it names a declarator
			-- the author never used.
			containerDeclarator = `Scribe.{kind}`
			meta = markerMeta
		elseif kind == "Derived" then
			-- A derived field is computed, never written, never persisted. Its Default is
			-- the output declarator, so the loop keeps unwrapping into it and the
			-- type/bounds machinery below is reached unchanged.
			if derivedInputs ~= nil then
				compileError(path, "Scribe.Derived is already applied to this field")
			end
			local inputs = if markerMeta then markerMeta.Inputs else nil
			local compute = if markerMeta then markerMeta.Compute else nil
			if type(inputs) ~= "table" then
				compileError(path, "Scribe.Derived requires a table of input paths")
			end
			if type(compute) ~= "function" then
				compileError(path, "Scribe.Derived requires a compute function")
			end
			-- Persistence is per ROOT (see Node.storeFor), so a derived field under a
			-- persisted root would be written into profile.Data and saved. A root field
			-- becomes non-persisted here, exactly as Scribe.Session would; anything
			-- deeper has to already be.
			if #path == 1 then
				persist = false
			elseif persist then
				compileError(
					path,
					`a derived field is never persisted, so it must be a root field or live inside a `
						.. `Scribe.Session root ("{path[1]}" is persisted)`
				)
			end
			derivedInputs = inputs :: { string }
			derivedCompute = compute :: (...any) -> any
		elseif kind == "Dynamic" then
			dynamicSeen = true
			-- `default` is the sample (the factory ran once at declaration). Infer the
			-- field type from it and carry the factory forward.
			if default == nil then
				compileError(path, "Scribe.Dynamic factory must return a non-nil value")
			end
			-- Dynamic seeds into the persistent store on a brand-new profile, but
			-- Session data lives in a separate store rebuilt from its default every
			-- session, so a Session+Dynamic seed would land in the wrong store.
			if not persist then
				compileError(
					path,
					"Scribe.Dynamic is not supported on a Session field; generate per-session values in OnPlayerInit instead"
				)
			end
			local factory = if markerMeta then markerMeta.Factory else nil
			local sampleType = typeof(default)
			if Datatypes.IsSupported(sampleType) then
				valueType = "datatype"
				meta = { Datatype = sampleType, Factory = factory } :: Marker.Meta
			elseif type(default) == "table" then
				compileError(path, "Scribe.Dynamic only wraps leaf values (numbers, strings, datatypes, ...)")
			else
				meta = { Factory = factory } :: Marker.Meta
			end
		end
		value = default
	end

	-- Wrapper combinations that contradict what a derived field IS. Checked after the
	-- unwrap loop so the order the user wrote them in does not matter.
	if derivedInputs ~= nil then
		if sessionSeen then
			compileError(path, "Scribe.Session is redundant on a derived field: a derived field never persists")
		end
		if timed then
			compileError(path, "Scribe.Timed cannot wrap a derived field: a derived value has no expiry, only inputs")
		end
		if dynamicSeen then
			compileError(
				path,
				"Scribe.Dynamic cannot wrap a derived field: a factory seeds a stored value, and a derived field "
					.. "stores nothing"
			)
		end
		if nullable then
			compileError(
				path,
				"Scribe.Optional cannot wrap a derived field: its value is whatever the compute function returns"
			)
		end
		if containerKind ~= nil then
			compileError(
				path,
				`Scribe.Derived cannot wrap {containerDeclarator or "a container"}: a derived field produces one `
					.. "scalar value"
			)
		end
	end

	-- Scribe.ArrayOf / Scribe.DictOf: a dynamic container carrying a compiled element
	-- schema. Returns early, before the leaf and default machinery below: the container
	-- declares no data of its own, and its element shape hangs off AnyChild, the node
	-- every dynamic key resolves through (Template.ChildSchema).
	if containerKind ~= nil then
		local declarator = containerDeclarator or `Scribe.{containerKind}Of`
		local elementShape = if meta then meta.Element else nil
		if elementShape == nil then
			compileError(path, `{declarator} requires an element shape`)
		end
		if timed then
			compileError(path, `Scribe.Timed cannot wrap {declarator}`)
		end
		if nullable then
			compileError(
				path,
				`Scribe.Optional cannot wrap {declarator}; an empty container is already the absent case`
			)
		end
		rejectInElementShape(path, elementShape)
		checkContainerCap(path, "MaxItems", meta and meta.MaxItems)
		checkContainerCap(path, "MaxKeys", meta and meta.MaxKeys)
		checkContainerCap(path, "MaxKeyLength", meta and meta.MaxKeyLength)
		local evict = meta and meta.Evict
		if evict ~= nil then
			if evict ~= "Front" and evict ~= "Back" then
				compileError(path, `Scribe.ArrayOf Evict must be "Front" or "Back", got {tostring(evict)}`)
			end
			-- Evict has nothing to drop from without a cap, so a bare Evict is a
			-- config mistake rather than a no-op.
			if not (meta and meta.MaxItems) then
				compileError(path, "Scribe.ArrayOf Evict requires MaxItems")
			end
		end

		local node: SchemaNode = {
			Id = state.NextId,
			Name = name,
			Path = table.clone(path),
			Kind = "table",
			ValueType = "table",
			Visibility = visibility,
			Persist = persist,
			Timed = false,
			Container = containerKind :: "Array" | "Dict",
			MaxItems = meta and meta.MaxItems,
			Evict = meta and meta.Evict,
			Unique = meta and meta.Unique,
			KeyType = meta and meta.KeyType,
			MaxKeys = meta and meta.MaxKeys,
			MaxKeyLength = meta and meta.MaxKeyLength,
			Default = {},
			Parent = parent,
		}
		state.ById[state.NextId :: number] = node
		state.NextId += 1
		if state.NextId > 65535 then
			error("Scribe: template exceeds 65535 static fields", 0)
		end

		-- Compile the element against a throwaway id counter, then strip the ids. Element
		-- fields are reachable only through AnyChild, while Template.Resolve follows
		-- Children and Wire.EncodePath sources ids from it, so an id here would be
		-- unaddressable at best and a decoder collision at worst.
		local elementPath = table.clone(path)
		table.insert(elementPath, "[]")
		local element = buildNode({ NextId = 0, ById = {} }, nil, elementShape, elementPath, visibility, persist, node)
		clearIds(element)
		element.IsElement = true
		if element.Children and next(element.Children) == nil then
			compileError(path, `{declarator} element shape declares no fields`)
		end
		-- A declared record has a fixed field set at EVERY depth: an undeclared key on
		-- the element or on any nested sub-record is a write error. Nested containers
		-- ran this same post-processing in their own buildNode call, so the walk stops
		-- at container boundaries.
		local function closeRecords(n: SchemaNode)
			if n.Container == nil and n.Children then
				if next(n.Children) ~= nil then
					n.Closed = true
				end
				for _, child in n.Children do
					closeRecords(child)
				end
			end
		end
		closeRecords(element)
		-- A set stores its members deduplicated and sorted, so the element has to be
		-- orderable. Anything else compiles clean, accepts the first Add, then throws a
		-- bare "attempt to compare table < table" on the second.
		if node.Unique then
			local vt = element.ValueType
			if not (vt == "int" or vt == "number" or vt == "string" or vt == "enum") then
				-- A Flags element carries Children = {}, so "has children" alone would
				-- call it a record. Name the declarator's own value type first.
				local kind
				if vt == "table" and element.Container ~= nil then
					kind = "nested container"
				elseif vt == "table" then
					kind = "record"
				else
					kind = vt
				end
				compileError(
					path,
					`Scribe.SetOf element must be an Int, Number, String or Enum, got a {kind}: members are `
						.. "compared by value and stored in a sorted canonical order. Use Scribe.ArrayOf, or "
						.. "hold a scalar identity field"
				)
			end
		end
		element.ClientDefault = buildClientDefault(element)
		node.AnyChild = element
		node.HasPacked = isPacked(element)

		local deepest = #path + declaredDepth(element)
		if deepest > Util.MAX_VALUE_DEPTH then
			compileError(
				path,
				`element shape nests {deepest} levels deep, past the {Util.MAX_VALUE_DEPTH}-level write limit`
			)
		end

		return node
	end

	local datatypeName: string? = nil
	local datatypePrecision: string? = nil
	if valueType == "datatype" then
		datatypeName = meta and meta.Datatype
		if not datatypeName or not Datatypes.IsSupported(datatypeName) then
			compileError(path, `unsupported datatype declarator`)
		end
		if typeof(value) ~= datatypeName then
			compileError(path, `default must be a {datatypeName}, got {typeof(value)}`)
		end
		-- Refused HERE, before the default is packed, rather than in the
		-- declarator-sanity block below: Datatypes.Pack validates the argument itself
		-- and would throw a raw, path-less error on the very next line.
		local declared = meta and meta.Precision
		if declared ~= nil then
			local accepted = Datatypes.PrecisionValues(datatypeName :: string)
			if not accepted then
				compileError(
					path,
					`Scribe.{datatypeName} has no Precision option`
						.. ` (only Scribe.Number and Scribe.CFrame take one)`
				)
			elseif type(declared) ~= "string" or not table.find(accepted, declared :: string) then
				local offered = table.concat(accepted, '" or "')
				compileError(path, `Scribe.{datatypeName} Precision must be "{offered}", got {tostring(declared)}`)
			end
			datatypePrecision = declared :: string
		end
		-- Profile data only ever holds the packed form.
		value = Datatypes.Pack(datatypeName :: string, value, datatypePrecision)
	end

	-- checkDefaultValue validates raw persistable leaf data. Run it for leaves and for
	-- array-like default blobs, whose elements are stored as data rather than recursed
	-- as schema. A named container's children are validated when buildNode recurses into
	-- them; here `value` still holds their un-stripped markers, so walking the whole
	-- container would wrongly reject valid nested declarators.
	if type(value) ~= "table" or Util.hasNumericKeys(value) then
		-- Marker scan FIRST: a declarator holding a non-persistable default would
		-- otherwise trip checkDefaultValue's generic "unsupported value type" on the
		-- marker's raw .Default and bury the real problem, which is the declarator
		-- being inside an array at all.
		if type(value) == "table" then
			rejectNestedMarkers(path, value)
		end
		checkDefaultValue(path, value)
	end

	local node: SchemaNode = {
		Id = state.NextId,
		Name = name,
		Path = table.clone(path),
		Kind = if type(value) == "table" then "table" else "leaf",
		ValueType = (valueType or (if type(value) == "table" then "table" else type(value))) :: any,
		Visibility = visibility,
		Persist = persist,
		Timed = timed,
		Datatype = datatypeName,
		Default = nil,
		Parent = parent,
	}
	state.ById[state.NextId :: number] = node
	state.NextId += 1
	if state.NextId > 65535 then
		error("Scribe: template exceeds 65535 static fields", 0)
	end

	if meta then
		node.Min = meta.Min
		node.Max = meta.Max
		node.Precision = meta.Precision
		node.MaxLength = meta.MaxLength
		if meta.Members then
			local members = table.clone(meta.Members)
			local index: { [string]: number } = {}
			for i, member in members do
				if type(member) ~= "string" then
					compileError(path, "enum members must be strings")
				end
				index[member] = i - 1
			end
			if #members > 255 then
				compileError(path, "enums support at most 255 members")
			end
			node.Members = members
			node.MemberIndex = index
		end
	end

	-- Scribe.Dynamic: record the factory. Datatype results are packed (profile.Data
	-- holds the packed form); other leaves pass through unchanged.
	if meta and meta.Factory then
		local rawFactory = meta.Factory
		if datatypeName then
			local dtName = datatypeName :: string
			-- Always nil today: a Scribe.Dynamic datatype field is inferred from the
			-- factory's sample, so there is no way to declare a Precision on one. Threaded
			-- anyway, so a seeded value always lands in the form a Set would have written.
			local dtPrecision = datatypePrecision
			node.Factory = function()
				return Datatypes.Pack(dtName, rawFactory(), dtPrecision)
			end
		else
			node.Factory = rawFactory
		end
	end

	-- Precision names what a field is stored and sent at, not a direction: on
	-- Scribe.Number it narrows from f64, on Scribe.CFrame it widens from a lossy
	-- quaternion. Anywhere else it would sit in the meta table doing nothing, so refuse
	-- it. Datatype fields are exempt, having been validated above against the set their
	-- codec publishes.
	if node.Precision ~= nil and node.ValueType ~= "number" and node.ValueType ~= "datatype" then
		compileError(
			path,
			`Precision is a Scribe.Number option and has no meaning on a {node.ValueType} field`
				.. ` (Scribe.Int already packs from its Min/Max alone)`
		)
	end
	if node.ValueType == "int" then
		if type(value) ~= "number" or value % 1 ~= 0 then
			compileError(path, "Scribe.Int default must be an integer")
		end
		-- Fractional bounds skew fixed-width int packing (value - Min is
		-- truncated), so require integer Min/Max on Int fields.
		if (node.Min ~= nil and node.Min % 1 ~= 0) or (node.Max ~= nil and node.Max % 1 ~= 0) then
			compileError(path, "Scribe.Int Min/Max must be integers")
		end
	elseif node.ValueType == "number" then
		if type(value) ~= "number" then
			compileError(path, "Scribe.Number default must be a number")
		end
		-- A bound that cannot bound anything. A numeric literal above ~1.8e308 IS
		-- math.huge, so `Max = 1e400` declares a ceiling no value can reach; NaN is worse,
		-- since `value < nan` and `value > nan` are both false, disabling the very check
		-- it was written to add.
		if (node.Min ~= nil and not isFiniteBound(node.Min)) or (node.Max ~= nil and not isFiniteBound(node.Max)) then
			compileError(path, "Scribe.Number Min/Max must be finite")
		end
		-- Narrowing is refused at configure time, not at runtime: the runtime answer
		-- would be the encoder quietly taking the generic path, with correct bytes,
		-- none of the saving, and no way to tell the narrowing never took effect.
		local precision = node.Precision
		if precision == "f32" then
			-- Not a packing constraint (the bounds do not enter the f32 encoding) but a
			-- contradiction: a bound past the binary32 range describes values the encoder
			-- must refuse one by one, so the field would silently spend nine bytes at the
			-- end of the range it was widened to reach.
			if
				(node.Min ~= nil and math.abs(node.Min) > F32_MAX)
				or (node.Max ~= nil and math.abs(node.Max) > F32_MAX)
			then
				compileError(
					path,
					`Scribe.Number Precision = "f32" cannot represent a bound past {F32_MAX}`
						.. ` (Min = {node.Min or "nil"}, Max = {node.Max or "nil"}); drop Precision to keep f64`
				)
			end
		elseif precision ~= nil then
			if type(precision) ~= "number" then
				compileError(
					path,
					`Scribe.Number Precision must be "f32" or a positive number, got a {type(precision)}`
				)
			end
			local p = precision :: number
			if not isFiniteBound(p) or p <= 0 then
				compileError(path, `Scribe.Number Precision must be finite and greater than zero, got {p}`)
			end
			-- A fixed-point grid is measured FROM Min and bounded BY Max: without both
			-- there is no origin to index from and no step count to pick a width from.
			if node.Min == nil or node.Max == nil then
				compileError(path, `Scribe.Number Precision = {p} requires both Min and Max`)
			end
			local min, max = node.Min :: number, node.Max :: number
			-- Min > Max is reported by the shared check below, in its own words; do
			-- not pre-empt it with arithmetic on a negative range.
			if max >= min then
				local steps = quantSteps(min, max, p)
				if steps > Q_MAX_STEPS then
					compileError(
						path,
						`Scribe.Number range {min}..{max} needs {steps} steps of {p}, past the {Q_MAX_STEPS}`
							.. ` a fixed-point field can index; widen Precision, or use Precision = "f32"`
					)
				end
				-- The grid must be coarser than the double under it: at a large
				-- magnitude a double's own spacing can exceed Precision, breaking the
				-- promised error bound before the codec does anything. The step count
				-- above stays small in that case, so test the bounds directly.
				local extreme = math.max(math.abs(min), math.abs(max))
				if extreme + p == extreme or extreme - p == extreme then
					compileError(
						path,
						`Scribe.Number Precision = {p} is finer than a double's own spacing at {extreme},`
							.. ` so the bound cannot step by it; widen Precision or narrow the range`
					)
				end
			end
		end
	elseif node.ValueType == "enum" then
		if not node.MemberIndex or node.MemberIndex[value] == nil then
			compileError(path, "enum default must be one of its members")
		end
	elseif node.ValueType == "big" then
		local parsed = Big.from(value)
		if parsed == nil then
			compileError(path, `Scribe.Big default must be a number or a numeric string, got {tostring(value)}`)
		end
		if node.Min ~= nil and Big.from(node.Min) == nil then
			compileError(path, "Scribe.Big Min must be a number or a numeric string")
		end
		if node.Max ~= nil and Big.from(node.Max) == nil then
			compileError(path, "Scribe.Big Max must be a number or a numeric string")
		end
	elseif node.ValueType == "flags" then
		-- bit32 is 32 bits wide, so a 33rd member would silently fall off the wire
		-- packing rather than round-tripping.
		if #(node.Members :: { string }) > 32 then
			compileError(path, `Scribe.Flags takes at most 32 members, got {#(node.Members :: { string })}`)
		end
		-- A member name is persisted verbatim and is the one persisted string with no
		-- write-path guard, since it comes from the template rather than from a Set:
		-- invalid UTF-8 fails the whole profile save the first time that flag is enabled.
		-- A duplicate is refused because MemberIndex keeps only the last, leaving the
		-- earlier bit unreachable.
		local seenMember: { [string]: boolean } = {}
		for _, member in node.Members :: { string } do
			if type(member) ~= "string" then
				compileError(path, `Scribe.Flags member names must be strings, got a {typeof(member)}`)
			end
			if not Util.isUtf8(member) then
				compileError(
					path,
					`Scribe.Flags member "{member}" contains invalid UTF-8, which would fail the profile save`
				)
			end
			if seenMember[member] then
				compileError(path, `Scribe.Flags declares "{member}" twice; member names must be unique`)
			end
			seenMember[member] = true
		end
		if type(value) ~= "table" then
			compileError(path, "Scribe.Flags default must be a table of member names")
		end
		for _, member in value :: { any } do
			if not node.MemberIndex or node.MemberIndex[member] == nil then
				compileError(path, `Scribe.Flags default contains "{tostring(member)}", which is not a member`)
			end
		end
	elseif node.ValueType == "string" then
		if type(value) ~= "string" then
			compileError(path, "Scribe.String default must be a string")
		end
		-- MaxLength is a byte budget, not a comparison bound: inf or NaN leaves the field
		-- silently unbounded, and a negative value is worse than a no-op, since
		-- truncateUtf8 ends in string.sub(s, 1, cut) and a negative index counts from the
		-- end, quietly deleting the tail of every value.
		if node.MaxLength ~= nil then
			local n = node.MaxLength
			if not isFiniteBound(n) or n % 1 ~= 0 or n < 0 then
				compileError(path, "Scribe.String MaxLength must be a non-negative integer")
			end
		end
	end
	if node.ValueType == "big" then
		-- A big bound past 1.8e308 can only be written as a numeric string, so the pair
		-- has to be ordered by Big.compare: a raw `>` either throws on a mixed pair or
		-- orders two strings lexically, which rejects "2" < "1e50" and accepts the
		-- inverted "1e50" > "2" this guard exists to catch.
		if node.Min ~= nil and node.Max ~= nil then
			local minBig = Big.from(node.Min) :: any
			local maxBig = Big.from(node.Max) :: any
			if Big.compare(minBig, maxBig) > 0 then
				compileError(path, "Min > Max")
			end
		end
	elseif node.Min and node.Max and node.Min > node.Max then
		compileError(path, "Min > Max")
	end
	if timed and type(value) == "table" then
		compileError(path, "Scribe.Timed only wraps leaf values")
	end

	if node.Kind == "table" then
		if Util.hasNumericKeys(value) then
			-- Array-like default: entries are DATA (deep-cloned, generically encoded),
			-- not schema. rejectNestedMarkers already ran above and refused any
			-- declarator nested in here.
			node.Default = Util.deepClone(value)
		else
			for k in value do
				-- sortedKeys would silently drop a non-string key, compiling a schema
				-- missing the field with no diagnostic at all.
				if type(k) ~= "string" then
					compileError(path, `record fields must have string names, got a {typeof(k)} key`)
				end
			end
			local children: { [string]: SchemaNode } = {}
			local order = Util.sortedKeys(value)
			local ordinal: { [string]: number } = {}
			local default = {}
			local hasPacked = false
			for i, key in order do
				local childPath = table.clone(path)
				table.insert(childPath, key)
				local child = buildNode(state, key, value[key], childPath, visibility, persist, node)
				children[key] = child
				ordinal[key] = i
				default[key] = child.Default
				-- Bubble the packed marker up (post-order: child is fully built).
				if isPacked(child) then
					hasPacked = true
				end
			end
			node.Children = children
			node.ChildOrder = order
			node.ChildOrdinal = ordinal
			node.Default = default
			node.HasPacked = hasPacked
		end
	elseif node.ValueType == "big" then
		-- The canonical { mantissa, exponent } form, so the schema default matches
		-- what every write produces rather than the raw declarator argument.
		node.Default = Big.toStored(Big.from(value) :: any)
	else
		node.Default = value
	end

	-- Collected, not resolved: an input may name a root this walk has not reached
	-- yet, so Compile finishes the job once every node exists.
	if derivedInputs ~= nil then
		local collected = state.Derived
		if collected == nil then
			compileError(path, "Scribe.Derived is not supported here")
		end
		table.insert(collected :: any, {
			Node = node,
			InputPaths = derivedInputs :: { string },
			Compute = derivedCompute :: (...any) -> any,
		})
	end

	-- Scribe.Optional: the inner declarator supplied the type and bounds; the default is
	-- dropped so the field is neither seeded into a new profile nor filled into a
	-- partial element write.
	if nullable then
		if timed then
			compileError(path, "Scribe.Optional cannot wrap Scribe.Timed: a lapsed timer restores the default")
		end
		if node.Factory then
			compileError(path, "Scribe.Optional cannot wrap Scribe.Dynamic: a factory exists to seed a value")
		end
		if node.Kind == "table" then
			compileError(path, "Scribe.Optional only wraps leaf values")
		end
		node.Nullable = true
		node.Default = nil
	end

	return node
end

-- Reserved internal roots: built server-only by default, then per-subkey
-- visibility applied explicitly so the rules are exact.
local function buildInternalRoots(state: any, root: SchemaNode, config: CompileConfig)
	local scribeTemplate = {
		-- GiftAims is not a second PendingGifts: a pending gift is a live intent counted
		-- against GiftMaxPending, an aim is the recipient identity that survives a stale
		-- prompt so a late receipt can still be routed. They expire on separate clocks;
		-- see the GIFT AIM block in Server/Monetization.
		GiftAims = {},
		GiftCredits = {},
		PendingGifts = {},
		Perks = {},
		ProcessedPurchaseIds = {},
		PurchaseLogs = {
			InGame = {},
			Robux = {},
		},
		-- Exchange holds the in-flight record per exchange id; ExchangeInbox holds value
		-- settled to this player but not yet delivered onto a game path. Untyped, like
		-- PendingGifts, because a settle must not be refusable by a declared shape.
		Exchange = {},
		ExchangeInbox = {},
		Timed = {},
		Version = Marker.make("Int", 1, { Min = 0 }),
	}

	local scribeNode = buildNode(state, RESERVED_ROOT, scribeTemplate, { RESERVED_ROOT }, "ServerOnly", true, root)
	local children = scribeNode.Children :: { [string]: SchemaNode }
	local function setVisibility(node: SchemaNode, visibility: Visibility)
		node.Visibility = visibility
		if node.Children then
			for _, child in node.Children do
				setVisibility(child, visibility)
			end
		end
	end
	setVisibility(children.Perks, "Replicated")
	setVisibility(children.GiftCredits, "Replicated")
	-- Purchase logs are opt-in per kind (PurchaseLog.ReplicateRobux/InGame);
	-- the container itself only replicates when at least one kind does, so the
	-- default sends nothing at all.
	local logs = children.PurchaseLogs
	local replicateRobux = config.ReplicateRobuxLog == true
	local replicateInGame = config.ReplicateInGameLog == true
	logs.Visibility = if replicateRobux or replicateInGame then "Replicated" else "ServerOnly"
	local logChildren = logs.Children :: { [string]: SchemaNode }
	setVisibility(logChildren.Robux, (if replicateRobux then "Replicated" else "ServerOnly") :: Visibility)
	setVisibility(logChildren.InGame, (if replicateInGame then "Replicated" else "ServerOnly") :: Visibility)

	-- _ScribeSession: never persisted, replicated to the owner. Holds the pass/Plus
	-- ownership cache, the player's own save info, and a sync flag the server flips
	-- true once the async gamepass refresh completes, so the client can await it
	-- before trusting OwnsCache (see Client/Server OwnsAsync).
	local sessionTemplate = {
		OwnsCache = {},
		SaveInfo = {},
		OwnsSynced = false,
	}
	local sessionNode = buildNode(state, SESSION_ROOT, sessionTemplate, { SESSION_ROOT }, "Replicated", false, root)

	return scribeNode, sessionNode
end

-- A DataStore serializes every object key to a JSON string, so a Scribe.MapOf with
-- integer keys comes back holding "123" where it stored 123. The declared key type is
-- what makes converting them back unambiguous. Runs on raw stored data before
-- Reconcile, so every later read sees the keys the template promised.
function Template.CoerceMapKeys(compiled: Compiled, data: any)
	local function walk(node: SchemaNode, value: any, depth: number)
		if type(value) ~= "table" or depth > 32 then
			return
		end
		if node.Container == "Dict" and node.KeyType == "integer" then
			local rename: { [string]: number }? = nil
			local blocked = false
			for key in value do
				if type(key) == "string" then
					local asNumber = tonumber(key)
					-- Only a canonical integer spelling converts. A key like "07" or
					-- "1.5" was never written by this map, so leaving it alone keeps
					-- foreign data intact rather than silently relocating it.
					if asNumber ~= nil and asNumber % 1 == 0 and tostring(asNumber) == key then
						rename = rename or {}
						(rename :: { [string]: number })[key] = asNumber
					else
						blocked = true
					end
				end
			end
			-- ALL of them or none. Converting only the canonical ones leaves the
			-- container holding a number key and a string key at once, a mixed table
			-- no DataStore will store, so every save for that profile would fail.
			if rename and not blocked then
				for from, to in rename do
					value[to] = value[from]
					value[from] = nil
				end
			end
		end
		local children = node.Children
		if children then
			for name, child in children do
				walk(child, value[name], depth + 1)
			end
		elseif node.Container ~= nil then
			for key in value do
				local element = Template.ChildSchema(node, key)
				if element then
					walk(element, value[key], depth + 1)
				end
			end
		end
	end
	walk(compiled.Root, data, 0)
end

function Template.Compile(userTemplate: any, config: CompileConfig?): Compiled
	local cfg: CompileConfig = config or {}
	if type(userTemplate) ~= "table" then
		error("Scribe: Template must be a table", 0)
	end
	for key in userTemplate do
		if type(key) ~= "string" then
			error("Scribe: template root keys must be strings", 0)
		end
		-- A top-level field's pathKey is just its name, so a root named "@cd|Daily"
		-- would collide with the cooldown slot of the same name. Nested fields are
		-- safe: their pathKeys always contain the \31 separator, which a cooldown key
		-- never has.
		if string.sub(key, 1, 3) == "@cd" then
			error(
				`Scribe: template may not declare a "{key}" key: the "{COOLDOWN_PREFIX}" prefix is reserved for cooldown slots`,
				0
			)
		end
		if string.sub(key, 1, #RESERVED_ROOT) == RESERVED_ROOT then
			error(`Scribe: template may not declare a "{key}" key: the {RESERVED_ROOT} root is library-owned`, 0)
		end
	end

	-- Held separately as well as on `state`, so the post-pass below reads it without
	-- the optionality buildNode's signature needs for the element-shape case.
	local pendingDerived: { PendingDerived } = {}
	local state: CompileState = { NextId = 1, ById = {} :: { [number]: SchemaNode }, Derived = pendingDerived }
	local root: SchemaNode = {
		Id = 0,
		Name = nil,
		Path = {},
		Kind = "table",
		ValueType = "table",
		Visibility = "Replicated",
		Persist = true,
		Timed = false,
		Default = nil,
		Parent = nil,
	}
	state.ById[0] = root

	local children: { [string]: SchemaNode } = {}
	local userOrder = Util.sortedKeys(userTemplate)
	for _, key in userOrder do
		children[key] = buildNode(state, key, userTemplate[key], { key }, "Replicated", true, root)
	end

	-- persist = false is what keeps these out of every save.
	local storeTemplate = cfg.ServerStore
	local storeOrder: { string } = {}
	if storeTemplate ~= nil then
		if type(storeTemplate) ~= "table" then
			error("Scribe: ServerStore must be a table", 0)
		end
		storeOrder = Util.sortedKeys(storeTemplate)
		for _, key in storeOrder do
			if type(key) ~= "string" then
				error("Scribe: ServerStore root keys must be strings", 0)
			end
			if string.sub(key, 1, 3) == "@cd" or string.sub(key, 1, #RESERVED_ROOT) == RESERVED_ROOT then
				error(`Scribe: ServerStore may not declare a "{key}" key: that prefix is library-owned`, 0)
			end
			if children[key] ~= nil then
				error(
					`Scribe: ServerStore declares "{key}", which the Template already declares. The two share `
						.. "one field-id space and one schema, so one would silently shadow the other. Rename one.",
					0
				)
			end
			-- Caught on the declarator: it cannot be told apart after building.
			local markerKind = Marker.inspect(storeTemplate[key])
			if markerKind == "Session" then
				error(
					`Scribe: ServerStore root "{key}" is Scribe.Session. A server store is never saved, so the `
						.. "marker sets nothing that is not already true. Drop the wrapper.",
					0
				)
			end
			local node = buildNode(state, key, storeTemplate[key], { key }, "Replicated", false, root)
			children[key] = node

			-- Load-bearing, not tidiness: hasShared scans every child of the root, so one
			-- Shared store root switches on the whole per-player fanout.
			if node.Visibility == "Shared" then
				error(
					`Scribe: ServerStore root "{key}" is Scribe.Shared. Every store root already reaches every `
						.. "client, and a store has no owning player for Shared to name. Drop the wrapper, or use "
						.. "Scribe.ServerOnly to keep it off the wire.",
					0
				)
			end

			-- A deadline is swept per profile entry and a Dynamic factory is sampled per profile
			-- load. A store has neither, and both would fail silently.
			local function refuseSubtree(n: SchemaNode)
				local where = if n.Name then `"{Util.pathString(n.Path :: any)}"` else `root "{key}"`
				if n.Timed then
					error(
						`Scribe: ServerStore field {where} is Scribe.Timed. A deadline lives in a player's `
							.. "_Scribe.Timed dict and is swept per profile, so a server store has nowhere to "
							.. "hold one and nothing to expire it.",
						0
					)
				end
				if n.Factory ~= nil then
					error(
						`Scribe: ServerStore field {where} is Scribe.Dynamic. The factory is sampled once when `
							.. "a brand-new profile is created, and a store has no profile. Set the value from "
							.. "your own code after the bundle is built.",
						0
					)
				end
				if n.Children then
					for _, child in n.Children do
						refuseSubtree(child)
					end
				end
				if n.AnyChild then
					refuseSubtree(n.AnyChild)
				end
			end
			refuseSubtree(node)
		end
	end

	local scribeNode, sessionNode = buildInternalRoots(state, root, cfg)
	children[RESERVED_ROOT] = scribeNode
	children[SESSION_ROOT] = sessionNode

	local order = table.clone(userOrder)
	for _, key in storeOrder do
		table.insert(order, key)
	end
	table.insert(order, RESERVED_ROOT)
	table.insert(order, SESSION_ROOT)
	table.sort(order)

	local ordinal: { [string]: number } = {}
	for i, key in order do
		ordinal[key] = i
	end
	root.Children = children
	root.ChildOrder = order
	root.ChildOrdinal = ordinal
	-- The root node is hand-built here rather than by buildNode, so bubble its
	-- HasPacked flag the same way (else a whole-data Get()/Clone() on the root
	-- accessor would leak packed buffers for a ROOT-level datatype field).
	local rootHasPacked = false
	for _, child in children do
		if isPacked(child) then
			rootHasPacked = true
			break
		end
	end
	root.HasPacked = rootHasPacked

	-- Scribe.Shared cannot appear below a root field, so this scan is exhaustive.
	local hasShared = false
	for _, child in children do
		if child.Visibility == "Shared" then
			hasShared = true
			break
		end
	end

	-- Derived fields, once every node they could name exists: resolve the input
	-- paths, order the graph, decide who computes each field, and seed the defaults.
	-- Before the hash fold, which folds the result.
	local derivedNodes: { SchemaNode } = {}
	local derivedByWrite: { [string]: { SchemaNode } } = {}
	if #pendingDerived > 0 then
		local reservedRoots = { [RESERVED_ROOT] = true, [SESSION_ROOT] = true }
		derivedNodes, derivedByWrite =
			DerivedModule.Resolve(root, pendingDerived :: any, reservedRoots, compileError :: any)
		DerivedModule.SeedDefaults(derivedNodes :: any, compileError :: any)

		-- A derived field recomputes on whichever tree took the write, so an input on the
		-- far side would settle into the wrong one.
		if storeTemplate ~= nil then
			local function isStoreRoot(path: { any }): boolean
				return #path > 0 and storeTemplate[path[1]] ~= nil
			end
			for _, node in derivedNodes do
				local spec = (node :: any).Derived
				if spec ~= nil and spec.Inputs ~= nil then
					local outputInStore = isStoreRoot(node.Path)
					for _, input in spec.Inputs do
						if isStoreRoot(input.Path) ~= outputInStore then
							error(
								`Scribe: derived field "{Util.pathString(node.Path)}" reads `
									.. `"{Util.pathString(input.Path)}", which is on the other side of the `
									.. "ServerStore boundary. A derived field recomputes on whichever tree took "
									.. "the write, and the two trees hold different data.",
								0
							)
						end
					end
				end
			end
		end
		-- A record's Default table was composed from its children while they were
		-- built, so a nested derived field's freshly seeded default has to be written
		-- back up: anything reading a record's Default directly would otherwise see
		-- the output declarator's default rather than the computed one.
		for _, node in derivedNodes do
			local child = node
			local parent = node.Parent
			while parent ~= nil and type(parent.Default) == "table" and child.Name ~= nil do
				(parent.Default :: { [string]: any })[child.Name :: string] = child.Default
				child = parent
				parent = parent.Parent
			end
		end
	end

	-- Folded into the schema hash below: Transmit decides whether the field crosses
	-- the wire at all, and the input set decides what a locally computing client
	-- reads, so a drift in either has to fail the handshake rather than diverge.
	local function derivedSig(node: SchemaNode): string
		local spec = node.Derived
		if spec == nil then
			return "nil"
		end
		local ids = table.create(#spec.Inputs)
		for i, input in spec.Inputs do
			ids[i] = tostring(input.Id)
		end
		return `d{if spec.Transmit then "1" else "0"}:{table.concat(ids, ",")}`
	end

	--- Precision drives a float's wire width, so it belongs in the hash for the same
	--- reason Min/Max do. %.17g rather than tostring: 17 significant digits round-trip
	--- every double, so the fold does not depend on tostring's shortest-round-trip
	--- behaviour, which nothing here pins.
	local function precisionSig(n: SchemaNode): string
		local p = n.Precision
		if p == nil then
			return "nil"
		elseif type(p) == "number" then
			return string.format("%.17g", p)
		end
		return tostring(p)
	end

	-- The hash must fold every field that affects the wire byte layout, or a
	-- server/client schema drift decodes silently wrong. Min/Max drive int
	-- width; Precision drives float width; Members drive enum indexing;
	-- Datatype/MaxLength are semantic.
	local hash = 2166136261
	for id = 0, state.NextId - 1 do
		local node = state.ById[id]
		if node then
			local members = ""
			if node.Members then
				local parts = table.create(#node.Members)
				for i, m in node.Members do
					parts[i] = `{#m}:{m}`
				end
				members = table.concat(parts, ",")
			end
			hash = Util.fnv32(
				-- Persist is folded too: without it a stale copy that moved a field
				-- on or off Session would hash identically to the current one.
				`{id}:{node.Name or ""}:{node.ValueType}:{node.Visibility}:{node.Persist}`
					.. `:{node.Min or "nil"}:{node.Max or "nil"}:{precisionSig(node)}:{node.MaxLength or "nil"}`
					.. `:{node.Datatype or "nil"}:{members}:{node.Container or "nil"}`
					.. `:{node.MaxItems or "nil"}:{node.Evict or "nil"}:{if node.Unique then "u" else "nil"}:{node.KeyType or "nil"}:{node.MaxKeys or "nil"}:{node.MaxKeyLength or "nil"}`
					.. `:{node.Nullable == true}:{if node.ChildOrder then #node.ChildOrder else -1}`
					.. `:{derivedSig(node)}`,
				hash
			)
		end
	end

	-- Element subtrees carry no ids, so the ById fold above cannot see them, but their
	-- Min/Max/Precision drive scalar width and their Members drive enum indexing: an
	-- element-only drift would pass the Hello schema guard and then decode every
	-- following op in the frame as garbage. ChildOrder is sorted at compile time, so the
	-- walk order is identical on both realms.
	local elementOrdinal = 0
	local function foldElementNode(n: SchemaNode)
		local members = ""
		if n.Members then
			local parts = table.create(#n.Members)
			for i, m in n.Members do
				parts[i] = `{#m}:{m}`
			end
			members = table.concat(parts, ",")
		end
		-- Leaf defaults matter here, unlike static nodes whose defaults only seed new
		-- profiles server-side: mirrors materialize fresh element entries from these,
		-- so a drift would seed different content on each realm.
		local dflt = ""
		local d = n.Default
		local dt = type(d)
		if dt == "boolean" or dt == "string" then
			dflt = tostring(d)
		elseif dt == "number" then
			dflt = string.format("%.17g", d)
		elseif dt == "buffer" then
			dflt = buffer.tostring(d)
		elseif n.ValueType == "big" and dt == "table" then
			-- A big's default is the stored { mantissa, exponent } pair, not a scalar,
			-- so the branches above skip it and a drift in one would otherwise hash
			-- identically on both realms.
			dflt = string.format("%.17g:%.17g", (d :: any)[1], (d :: any)[2])
		end
		hash = Util.fnv32(
			`@{elementOrdinal}:{n.Name or ""}:{n.ValueType}:{n.Visibility}`
				.. `:{n.Min or "nil"}:{n.Max or "nil"}:{precisionSig(n)}:{n.MaxLength or "nil"}`
				.. `:{n.Datatype or "nil"}:{members}:{n.Container or "nil"}`
				.. `:{n.MaxItems or "nil"}:{n.Evict or "nil"}:{if n.Unique then "u" else "nil"}:{n.KeyType or "nil"}:{n.MaxKeys or "nil"}:{n.MaxKeyLength or "nil"}`
				.. `:{n.Nullable == true}:{if n.ChildOrder then #n.ChildOrder else -1}`
				.. `:{#dflt}:{dflt}`,
			hash
		)
		elementOrdinal += 1
		local nodeChildren = n.Children
		if n.ChildOrder and nodeChildren then
			for _, key in n.ChildOrder do
				foldElementNode(nodeChildren[key])
			end
		end
		if n.AnyChild then
			foldElementNode(n.AnyChild)
		end
		-- Subtree terminator: without it a field moved from a sub-record up to the
		-- element root folds to the same preorder byte stream as before the move.
		hash = Util.fnv32("/", hash)
	end
	local function foldElements(n: SchemaNode)
		local anyChild = n.AnyChild
		if anyChild and anyChild.IsElement then
			foldElementNode(anyChild)
		end
		local nodeChildren = n.Children
		if n.ChildOrder and nodeChildren then
			for _, key in n.ChildOrder do
				foldElements(nodeChildren[key])
			end
		end
	end
	foldElements(root)

	-- Flatten the fields carrying a Scribe.Dynamic factory (in id order), so the
	-- load path can seed them on a new profile without walking the whole tree.
	local dynamicNodes: { SchemaNode } = {}
	for id = 0, state.NextId - 1 do
		local node = state.ById[id]
		if node and node.Factory then
			table.insert(dynamicNodes, node)
		end
	end

	local compiled: Compiled = {
		Root = root,
		ById = state.ById,
		NodeCount = state.NextId,
		Hash = hash,
		RootOrder = order,
		HasShared = hasShared,
		DynamicNodes = dynamicNodes,
		DerivedNodes = derivedNodes,
		DerivedByWrite = derivedByWrite,
		Views = nil :: any,
		Config = cfg,
	}

	-- A view is the compiled with its root scoped to a subset of the children. Node reads
	-- only Root, DerivedByWrite, DerivedNodes and Template.Resolve, so this costs nothing
	-- in Node itself.
	local function makeView(keys: { string }): Compiled
		local viewChildren: { [string]: SchemaNode } = {}
		local viewOrdinal: { [string]: number } = {}
		local viewShared = false
		for index, key in keys do
			local child = children[key]
			viewChildren[key] = child
			viewOrdinal[key] = index
			if child.Visibility == "Shared" then
				viewShared = true
			end
		end
		local viewRoot: SchemaNode = table.clone(root)
		-- No Id: a view must never reach an encoder. EncodePath would write id 0 and decode
		-- to a valid but schemaless path instead of raising.
		viewRoot.Id = nil
		viewRoot.Children = viewChildren
		viewRoot.ChildOrder = keys
		viewRoot.ChildOrdinal = viewOrdinal
		local view: Compiled = table.clone(compiled)
		view.Root = viewRoot
		view.RootOrder = keys
		view.HasShared = viewShared
		return view
	end

	if #storeOrder == 0 then
		-- No store, so the player view IS the compiled and nothing else changes shape.
		compiled.Views = { Player = compiled, Store = nil }
	else
		local declared = storeTemplate :: { [string]: any }
		local playerKeys: { string } = {}
		for _, key in order do
			if declared[key] == nil then
				table.insert(playerKeys, key)
			end
		end
		compiled.Views = { Player = makeView(playerKeys), Store = makeView(table.clone(storeOrder)) }
	end
	return compiled
end

-- Shared with Node, whose read paths all have to agree on which nodes need an unpack.
function Template.IsPacked(node: SchemaNode?): boolean
	return node ~= nil and isPacked(node)
end

-- Schema node for a child key: the static child when one exists, otherwise a cached
-- dynamic pseudo-node inheriting the parent's visibility. Returns nil for children of
-- leaves.
function Template.ChildSchema(node: SchemaNode, key: string | number): SchemaNode?
	if node.Kind == "leaf" then
		return nil
	end
	if type(key) == "string" and node.Children then
		local child = node.Children[key]
		if child then
			return child
		end
	end
	-- A compiled element record has a fixed field set, so an undeclared key resolves
	-- to nothing and the caller rejects the write. Without this, ChildSchema would
	-- synthesize a generic `any` node and CACHE it on the shared element schema,
	-- which both accepts the typo forever and mutates the compiled tree at runtime.
	if node.Closed then
		return nil
	end
	local anyChild = node.AnyChild
	if not anyChild then
		local created: SchemaNode = {
			Id = nil,
			Name = nil,
			Path = node.Path,
			Kind = "any",
			ValueType = "any",
			Persist = node.Persist,
			Visibility = node.Visibility,
			Timed = false,
			Default = nil,
			Parent = node,
		}
		node.AnyChild = created
		anyChild = created
	end
	return anyChild
end

-- Resolve a path to (deepest static schema node, index of the first dynamic
-- segment). If the whole path is static, the index is #path + 1.
function Template.Resolve(compiled: Compiled, path: { string | number }): (SchemaNode, number)
	local node = compiled.Root
	for i, seg in path do
		if type(seg) == "string" and node.Children and node.Children[seg] then
			node = node.Children[seg]
		else
			return node, i
		end
	end
	return node, #path + 1
end

-- Effective visibility of a path (deepest static node's visibility; dynamic
-- segments inherit).
function Template.VisibilityOf(compiled: Compiled, path: { string | number }): Visibility
	local node = Template.Resolve(compiled, path)
	return node.Visibility
end

-- The persistence axis, for callers that only have a path. Separate from
-- VisibilityOf because a field can be Session (never saves) AND ServerOnly or
-- Shared (who receives it) at the same time.
function Template.PersistOf(compiled: Compiled, path: { string | number }): boolean
	local node = Template.Resolve(compiled, path)
	return node.Persist
end

-- Deep-cloned default data. `which`:
--  "Persistent": everything saved (Persist); the ProfileStore template
--  "Session":    non-persisted roots only
--  "Client":     everything except ServerOnly subtrees (the owner's mirror)
function Template.BuildDefaults(compiled: Compiled, which: "Persistent" | "Session" | "Client"): { [string]: any }
	local function include(node: SchemaNode): boolean
		if which == "Persistent" then
			return node.Persist
		elseif which == "Session" then
			return not node.Persist
		else
			return node.Visibility ~= "ServerOnly"
		end
	end

	-- Client defaults strip ServerOnly subtrees but keep mixed-visibility
	-- containers whose children are visible (the _Scribe reserved root).
	local function buildClient(node: SchemaNode): any
		if node.Kind ~= "table" or not node.Children then
			return if node.Visibility == "ServerOnly" then nil else Util.deepClone(node.Default)
		end
		local out = {}
		local anyVisible = false
		for key, child in node.Children do
			local value = buildClient(child)
			if value ~= nil then
				out[key] = value
				anyVisible = true
			end
		end
		if node.Visibility == "ServerOnly" and not anyVisible then
			return nil
		end
		return out
	end

	local function build(node: SchemaNode): any
		if node.Kind ~= "table" or not node.Children then
			return Util.deepClone(node.Default)
		end
		local out = {}
		for key, child in node.Children do
			out[key] = build(child)
		end
		return out
	end

	local out = {}
	for key, child in compiled.Root.Children :: { [string]: SchemaNode } do
		if which == "Client" then
			out[key] = buildClient(child)
		elseif include(child) then
			out[key] = build(child)
		end
	end
	return out
end

-- Clone `value` at `node`, stripping ServerOnly subtrees (Init snapshots, offline
-- perk reads). Mixed-visibility containers such as the _Scribe root keep their
-- visible children; returns nil only when nothing is visible AND the node itself is
-- ServerOnly.
function Template.CloneVisible(node: SchemaNode, value: any): any
	-- A locally computed derived field is never sent: every realm that receives it can
	-- also see all of its inputs, so the client recomputes it from its own mirror.
	local derived = node.Derived
	if derived ~= nil and not derived.Transmit then
		return nil
	end
	if type(value) ~= "table" then
		if node.Visibility == "ServerOnly" then
			return nil
		end
		-- Packed datatypes are buffers, which are mutable and whose only reference here
		-- is live profile state. Callers mutate the returned tree in place, so hand
		-- back a copy.
		if type(value) == "buffer" then
			return Util.cloneBuffer(value)
		end
		return value
	end
	local out = {}
	local anyVisible = false
	for k, v in value do
		local childNode = if type(k) == "string" and node.Children then node.Children[k] else nil
		-- An ArrayOf/DictOf element schema describes EVERY entry, numeric keys
		-- included, so a ServerOnly field inside an element shape is stripped like a
		-- static one. Gated on IsElement so untyped dynamic containers keep the
		-- wholesale deepClone below, which otherwise starts aliasing live buffers.
		if childNode == nil and node.AnyChild ~= nil and node.AnyChild.IsElement then
			childNode = node.AnyChild
		end
		if childNode then
			local cloned = Template.CloneVisible(childNode, v)
			if cloned ~= nil then
				out[k] = cloned
				anyVisible = true
			end
		elseif node.Visibility ~= "ServerOnly" then
			-- Dynamic entries inherit this node's visibility.
			out[k] = Util.deepClone(v)
			anyVisible = true
		end
	end
	if node.Visibility == "ServerOnly" and not anyVisible then
		return nil
	end
	return out
end

-- Backfills element fields added to an ArrayOf/DictOf shape after profiles exist.
-- ProfileStore's Reconcile walks the static template only, and an element shape is
-- reachable solely through AnyChild, so without this a field added in v2 stays missing
-- on every stored entry forever. Fills a missing key, never touches an existing one;
-- a Nullable field has a nil default and is skipped. Returns true when anything changed.
function Template.ReconcileElements(compiled: Compiled, data: { [string]: any }): boolean
	-- `inElement` flips true under a container's AnyChild and stays true beneath it, so
	-- fills happen at every depth of an element subtree. Static template fields are
	-- never filled here; profile:Reconcile owns those.
	local function walk(node: SchemaNode, value: any, inElement: boolean): boolean
		if type(value) ~= "table" then
			return false
		end
		local changed = false
		if node.Container ~= nil then
			local element = node.AnyChild
			if element then
				for _, entry in value do
					if walk(element, entry, true) then
						changed = true
					end
				end
			end
			return changed
		end
		if node.Children then
			for name, child in node.Children do
				if inElement and value[name] == nil and child.Default ~= nil then
					value[name] = Util.deepClone(child.Default)
					changed = true
				end
				if walk(child, value[name], inElement) then
					changed = true
				end
			end
		end
		return changed
	end

	local changed = false
	for key, child in compiled.Root.Children :: { [string]: SchemaNode } do
		if walk(child, data[key], false) then
			changed = true
		end
	end
	return changed
end

-- Top-level keys present in `data` but absent from the schema (dev-mode warning;
-- `nil :: T?` template fields are invisible at runtime).
function Template.UnknownRootKeys(compiled: Compiled, data: { [string]: any }): { string }
	local unknown = {}
	local children = compiled.Root.Children :: { [string]: SchemaNode }
	for key in data do
		if type(key) ~= "string" or not children[key] then
			table.insert(unknown, tostring(key))
		end
	end
	table.sort(unknown)
	return unknown
end

return Template
