--!strict
-- The Value tree runtime: a metatable-backed accessor tree that
-- lazily materializes child nodes, records paths for replication, validates
-- every write, and holds per-node callback lists. Used for the
-- server's authoritative tree and the client's mirror alike.

local Util = require(script.Parent.Util)
local Big = require(script.Parent.Big)
local Template = require(script.Parent.Template)
local Datatypes = require(script.Parent.Datatypes)

type SchemaNode = Template.SchemaNode
type Compiled = Template.Compiled

export type Op = {
	Kind: string,
	Path: { string | number },
	Value: any?,
	Index: number?,
}

export type TimedHooks = {
	SetTimed: (accessor: any, value: any, seconds: number, replicate: boolean?) -> (),
	ExtendTimed: (accessor: any, seconds: number, replicate: boolean?) -> (),
	Active: (accessor: any) -> (boolean, number?),
}

export type TreeParams = {
	Compiled: Compiled,
	Stores: { Persist: { [string]: any }, Session: { [string]: any } },
	IsServer: boolean,
	Label: string,
	OnOp: ((op: Op, schema: SchemaNode?) -> ())?,
	OnAnomaly: ((path: { string | number }, value: any, reason: string) -> ())?,
	BoundsPolicy: ("Clamp" | "Reject")?,
	DevMode: boolean?,
	TimedHooks: TimedHooks?,
	OnEconomy: ((path: { string | number }, delta: number, newValue: number, tags: { [string]: any }) -> ())?,
	LogError: (message: string) -> (),
	LogWarn: ((message: string) -> ())?,
	OnBatchEnd: (() -> ())?,
}

local Node = {}

-- The exact message RunTransaction returns when `fn` yielded. Exported so a caller
-- can tell "your callback yielded" apart from "your callback threw" without
-- string-matching a literal; Monetization needs that distinction to keep a legacy
-- yielding product Grant working instead of turning it into a receipt retry loop.
local YIELD_ERROR =
	"Scribe: a transaction function must not yield (no task.wait, DataStore, or MarketplaceService calls inside Data.Transaction; do async work before or after it)"
Node.YIELD_ERROR = YIELD_ERROR

local ACCESSOR_MT: any -- forward declaration

-- Tree ------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

export type Tree = typeof(setmetatable(
	{} :: {
		Params: TreeParams,
		Compiled: Compiled,
		Accessor: any,
		Dead: boolean,
		_listeners: { [string]: { [string]: { [any]: (...any) -> () } } },
		-- path array for each listener'd pathKey, so the Init replay can read a
		-- node's value without reversing the (lossy) pathKey string.
		_paths: { [string]: { string | number } },
		-- true only while replaying the initial snapshot: suppresses per-op fires
		-- so descendants can be fired once, together, afterwards.
		_replaying: boolean,
		_accessors: { [string]: any },
		_batchDepth: number,
		-- Ancestor Changed fires deferred to the end of a batch, keyed by pathKey
		-- so N writes under one container collapse to one fire. Insertion-ordered
		-- (deepest first, matching the unbatched order) via _pendingAncestorOrder.
		-- Only the prefix is kept: Changed carries state, and WHICH child moved is
		-- OnChildChanged's job.
		_pendingAncestors: { [string]: { string | number } }?,
		_pendingAncestorOrder: { string }?,
		_txn: {
			Snapshots: { [string]: { Path: { string | number }, Value: any } },
			Ops: { { Op: Op, Schema: SchemaNode? } },
			Created: { { string | number } },
			RawRestores: { [string]: { Store: { [string]: any }, Value: any } },
		}?,
	},
	Tree
))

local function newAccessor(tree: Tree, path: { string | number }, schema: SchemaNode?): any
	local accessor: any = setmetatable({}, ACCESSOR_MT)
	rawset(accessor, "_tree", tree)
	rawset(accessor, "_path", path)
	rawset(accessor, "_key", Util.pathKey(path))
	rawset(accessor, "_schema", schema)
	-- Weak VALUES: child accessors are lazily materialized on index and cached
	-- here, but they carry no state (listeners live on the tree, keyed by pathKey,
	-- not by accessor identity), so once nothing else holds a child it may be
	-- collected and its entry drops. This prevents an unbounded, session-long leak
	-- when a dictionary is indexed by high-cardinality transient keys (GUIDs,
	-- per-trade ids); a re-index simply rebuilds an equivalent accessor.
	rawset(accessor, "_children", setmetatable({}, { __mode = "v" }))
	return accessor
end

function Node.NewTree(params: TreeParams): Tree
	local self = setmetatable({
		Params = params,
		Compiled = params.Compiled,
		Accessor = nil :: any,
		Dead = false,
		_listeners = {},
		_paths = {},
		_replaying = false,
		_accessors = {},
		_batchDepth = 0,
		_pendingAncestors = nil,
		_pendingAncestorOrder = nil,
		_txn = nil,
	}, Tree)
	self.Accessor = newAccessor(self, {}, params.Compiled.Root)
	return self :: any
end

local function assertAlive(tree: Tree)
	if tree.Dead then
		error(`Scribe: data for {tree.Params.Label} has been unloaded`, 3)
	end
end

local function storeFor(tree: Tree, rootKey: string | number): { [string]: any }
	local children = tree.Compiled.Root.Children
	if type(rootKey) == "string" and children then
		local rootSchema = children[rootKey]
		if rootSchema and rootSchema.Visibility == "Session" then
			return tree.Params.Stores.Session
		end
	end
	return tree.Params.Stores.Persist
end

-- The OTHER-typed form of a key that would produce the SAME Util.pathKey: a
-- number and its canonical string (7 <-> "7"). Returns nil when there is no such
-- alias (a non-integer string, "07", a named field, etc.). Used to reject a
-- numeric key and its string form coexisting in one container, whose colliding
-- pathKeys would alias listeners, coalescing, and transaction rollback.
local function aliasForm(seg: any): any
	if type(seg) == "number" then
		return tostring(seg)
	elseif type(seg) == "string" then
		local n = tonumber(seg)
		if n ~= nil and n % 1 == 0 and tostring(n) == seg then
			return n
		end
	end
	return nil
end

-- Key rules for a DECLARED container (Scribe.ArrayOf / Scribe.DictOf) at the moment
-- a key is created in it. Arrays stay contiguous 1..n, because a hole makes `#arr`
-- disagree with Count() and shifts every wire index below it; dicts are string-keyed,
-- which is also what makes Remove()'s string/number dispatch correct by construction.
-- Untyped containers (a plain `{}` template field) have no Container and are
-- unaffected, keeping exactly the behavior they have today.
local function checkContainerKey(
	containerSchema: SchemaNode?,
	container: any,
	key: any,
	where: string,
	removing: boolean?
)
	local kind = if containerSchema then containerSchema.Container else nil
	if kind == nil then
		return
	end
	local schema = containerSchema :: SchemaNode
	if kind == "Array" then
		if type(key) ~= "number" then
			error(
				`Scribe: "{where}" is a Scribe.ArrayOf and takes array indices, but the key "{tostring(key)}" `
					.. `is a {type(key)}`,
				0
			)
		end
		local len = #container
		if removing then
			-- Only the tail can go away by a nil write without leaving a hole. Removing
			-- a key that is not there is left as the no-op it has always been.
			if container[key] ~= nil and key ~= len then
				error(
					`Scribe: "{where}" is a Scribe.ArrayOf and must stay contiguous; use Remove({key}) `
						.. `instead of setting index {key} to nil`,
					0
				)
			end
			return
		end
		if key % 1 ~= 0 or key < 1 or key > len + 1 then
			error(
				`Scribe: index {key} is out of range for "{where}" (length {len}); `
					.. "array elements are created with Insert",
				0
			)
		end
		-- Growth only: an entry beyond the cap that already EXISTS stays writable,
		-- because a newer-template server may have stored it before this server's
		-- (lower) cap deployed; stranding it would turn a rolling deploy into
		-- lost writes.
		if schema.MaxItems and key > schema.MaxItems and container[key] == nil then
			error(`Scribe: "{where}" is capped at MaxItems {schema.MaxItems}`, 0)
		end
	else
		-- Scribe.MapOf declares its key type; a plain Scribe.DictOf is string-keyed.
		local keyType = schema.KeyType or "string"
		if keyType == "integer" then
			if type(key) ~= "number" then
				error(
					`Scribe: "{where}" is a Scribe.MapOf("integer") and takes integer keys, but the key `
						.. `{tostring(key)} is a {type(key)}`,
					0
				)
			end
			-- A DataStore serializes object keys to JSON strings, and only a finite
			-- integer survives that round trip unambiguously.
			if key ~= key or key == math.huge or key == -math.huge or key % 1 ~= 0 then
				error(`Scribe: "{where}" takes finite integer keys, got {tostring(key)}`, 0)
			end
		elseif type(key) ~= "string" then
			local declarator = if schema.KeyType then `Scribe.MapOf("string")` else "Scribe.DictOf"
			error(
				`Scribe: "{where}" is a {declarator} and takes string keys, but the key {tostring(key)} `
					.. `is a {type(key)}`,
				0
			)
		end
		if removing then
			return
		end
		-- Creating a NEW integer key in a container that still holds a string one
		-- would produce a table with both key types, which no DataStore will store:
		-- the whole profile save then fails, not just this field. That state is
		-- reachable when load-time coercion was blocked, which happens when a key is
		-- not a canonical integer spelling ("07", "1.5") and the all-or-nothing rule
		-- left the container alone rather than half-converting it. Refuse the write
		-- and name the blocker instead of letting the profile become unsaveable.
		if keyType == "integer" and container[key] == nil then
			for existing in container do
				if type(existing) == "string" then
					error(
						`Scribe: "{where}" is a Scribe.MapOf("integer") but still holds the string key `
							.. `"{existing}", which load-time coercion could not convert. Writing an integer `
							.. "key now would leave both key types in one table, which fails the whole "
							.. "profile save. Remove or migrate that key first",
						0
					)
				end
			end
		end
		local maxKeyLength = if keyType == "string" then schema.MaxKeyLength else nil
		if maxKeyLength and #(key :: string) > maxKeyLength then
			-- Reject rather than truncate: a truncated key writes to the wrong slot.
			error(`Scribe: key "{key}" at "{where}" is {#(key :: string)} bytes, over MaxKeyLength {maxKeyLength}`, 0)
		end
		local maxKeys = schema.MaxKeys
		if maxKeys and container[key] == nil then
			local count = 0
			for _ in container do
				count += 1
			end
			if count >= maxKeys then
				error(`Scribe: "{where}" already holds {count} keys, at its MaxKeys {maxKeys}`, 0)
			end
		end
	end
end

-- Resolves the container holding path's last segment. When `create` is true,
-- missing intermediate tables are materialized. `schema` is the schema of the
-- LAST segment (what every caller already holds); the per-segment schemas are
-- recovered by walking its Parent chain, which mirrors the path exactly because
-- accessors resolve children through Template.ChildSchema.
local function resolveContainer(
	tree: Tree,
	path: { string | number },
	create: boolean,
	schema: SchemaNode?,
	validating: boolean?
): (any, any)
	local n = #path
	if n == 0 then
		return nil, nil
	end
	local chain: { SchemaNode }? = nil
	if create and schema ~= nil and n > 1 then
		local c: { SchemaNode } = table.create(n)
		local cursor: SchemaNode? = schema
		for i = n, 1, -1 do
			if cursor == nil then
				break
			end
			c[i] = cursor
			cursor = cursor.Parent
		end
		chain = c
	end
	local container: any = storeFor(tree, path[1])
	for i = 1, n - 1 do
		local seg = path[i]
		local nextContainer = container[seg]
		if nextContainer == nil then
			if not create then
				return nil, nil
			end
			-- The container being written into is path[1..i-1], so its schema is the
			-- chain entry one level up. i == 1 is the store root, which is never a
			-- declared container. VALIDATED writes only: a remote apply must never
			-- throw here, because Tree.ApplyOp is fed whole frames and one throw
			-- drops every remaining op of the frame, permanently desyncing the
			-- mirror (compaction can legitimately replay a create the mirror's
			-- current state appears to have no room for).
			if validating and chain and i > 1 then
				checkContainerKey(chain[i - 1], container, seg, Util.pathString(table.move(path, 1, i - 1, 1, {})))
			end
			-- Materializing an INTERMEDIATE segment whose other-typed form already
			-- occupies this container is the same alias hazard applySet guards for the
			-- leaf key; reject it here so a nested write like Dict[7].Sub cannot create
			-- a numeric 7 alongside an existing string "7" (server data never carries
			-- such a pair, so remote/restore writes never trip this).
			local alias = aliasForm(seg)
			if alias ~= nil and container[alias] ~= nil then
				error(
					`Scribe: key "{tostring(seg)}" at "{Util.pathString(path)}" collides with the existing `
						.. `"{tostring(alias)}" key form (a numeric key and its string form cannot coexist)`,
					0
				)
			end
			-- A declared element materializes from its compiled defaults, so writing
			-- one field of a fresh key does not leave the rest nil against a type
			-- that says they are always present.
			local createdSchema = if chain then chain[i] else nil
			local seed: any = nil
			if createdSchema and createdSchema.IsElement then
				-- The mirror gets the ServerOnly-stripped copy: materializing the full
				-- default there would surface a ServerOnly sibling's declared value on
				-- the client, which no replicated op would ever have sent.
				seed = if tree.Params.IsServer then createdSchema.Default else createdSchema.ClientDefault
			end
			nextContainer = if type(seed) == "table" then Util.deepClone(seed) else {}
			container[seg] = nextContainer
			-- Record containers materialized mid-transaction so a rollback can
			-- prune them (they never existed pre-transaction).
			local txn = tree._txn
			if txn then
				txn.Created[#txn.Created + 1] = table.move(path, 1, i, 1, table.create(i))
			end
		elseif type(nextContainer) ~= "table" then
			error(`Scribe: cannot index "{Util.pathString(path)}" — "{tostring(seg)}" is not a table`, 0)
		end
		container = nextContainer
	end
	return container, path[n]
end

local function readValue(tree: Tree, path: { string | number }): any
	if #path == 0 then
		return tree.Params.Stores.Persist
	end
	local container, key = resolveContainer(tree, path, false)
	if container == nil then
		return nil
	end
	return container[key]
end

-- Listeners ---------------------------------------------------------------------

local function listenersFor(tree: Tree, pathKey: string, event: string, create: boolean): { [any]: (...any) -> () }?
	local byEvent = tree._listeners[pathKey]
	if byEvent == nil then
		if not create then
			return nil
		end
		byEvent = {}
		tree._listeners[pathKey] = byEvent
	end
	local list = byEvent[event]
	if list == nil then
		if not create then
			return nil
		end
		list = {}
		byEvent[event] = list
	end
	return list
end

local function connect(tree: Tree, path: { string | number }, event: string, fn: (...any) -> ()): () -> ()
	assertAlive(tree)
	local pathKey = Util.pathKey(path)
	local list = listenersFor(tree, pathKey, event, true) :: { [any]: (...any) -> () }
	tree._paths[pathKey] = path
	local token = {}
	list[token] = fn
	return function()
		local byEvent = tree._listeners[pathKey]
		local current = byEvent and byEvent[event]
		if current then
			current[token] = nil
			-- Reclaim now-empty listener tables so they don't accumulate and
			-- permanently defeat the fireAncestors no-listener fast path.
			if next(current) == nil then
				byEvent[event] = nil
				if next(byEvent) == nil then
					tree._listeners[pathKey] = nil
					tree._paths[pathKey] = nil
				end
			end
		end
	end
end

local function fire(tree: Tree, pathKey: string, event: string, ...: any)
	if tree._replaying then
		return -- suppressed during the Init replay; fired together afterwards
	end
	local list = listenersFor(tree, pathKey, event, false)
	if list == nil then
		return
	end
	local args = table.pack(...)
	-- Snapshot the listeners before dispatch: a callback may connect() into (or
	-- disconnect from) this same live table, and inserting during generalized
	-- iteration is undefined in Luau (empirically double-fires or skips entries).
	-- Semantics match GoodSignal: a listener connected during the fire does NOT
	-- receive the in-flight event; one disconnected mid-fire is not called after.
	local tokens = {}
	local fns = {}
	for token, fn in list do
		tokens[#tokens + 1] = token
		fns[#fns + 1] = fn
	end
	for i = 1, #fns do
		if list[tokens[i]] == nil then
			continue -- disconnected by an earlier listener during this fire
		end
		local fn = fns[i]
		local ok, err = xpcall(function()
			fn(table.unpack(args, 1, args.n))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			tree.Params.LogError(`listener error at "{pathKey}" ({event}): {err}`)
		end
	end
end

-- Walks up from `path` firing two different KINDS of event on each ancestor.
--
-- OnChildChanged is a TRANSITION: "this direct child moved, here it is". It fires
-- immediately, once per write, never deferred and never deduplicated, exactly like
-- leaf Changed and like OnInsert / OnRemove / OnKeyAdded / OnKeyRemoved. Coalescing
-- a transition would destroy it, which is the whole reason this event exists.
--
-- Changed is STATE: "this container is different, here is its current value". Its
-- `old` is the same reference as `new` because Scribe never snapshots a container,
-- so there is nothing in it that a batch can lose. That is what makes it safe to
-- defer and collapse to one fire per batch or per received frame.
-- `childOld` is the prior value of the DEEPEST ancestor's immediate child, passed
-- only by applySet, where that child is the leaf that actually changed. It needs
-- its own `known` flag because nil is a legitimate prior value (a key being
-- added). Every shallower ancestor's child is a container mutated in place, so
-- its old and new are one reference, exactly as a container's own Changed reports.
local function fireAncestors(tree: Tree, path: { string | number }, childOld: any, childOldKnown: boolean?)
	if next(tree._listeners) == nil then
		return
	end
	local deferring = tree._batchDepth > 0
	-- The child of the ancestor at `depth` is the prefix of length depth + 1, which
	-- is the previous iteration's already-allocated prefix. Starts as `path` itself,
	-- whose last segment is the leaf that actually changed.
	local childPrefix: { string | number } = path
	for depth = #path - 1, 0, -1 do
		local prefix = table.move(path, 1, depth, 1, table.create(depth)) :: { string | number }
		local pathKey = Util.pathKey(prefix)
		local byEvent = tree._listeners[pathKey]
		if byEvent ~= nil then
			local childList = byEvent.OnChildChanged
			if childList and next(childList) ~= nil then
				-- Read the child on its OWN path rather than indexing the parent's
				-- table: at the root, readValue short-circuits to Stores.Persist while
				-- resolveContainer routes the first segment through storeFor, so
				-- `parentValue[key]` would read nil for a Session root's child.
				local childNew = readValue(tree, childPrefix)
				local previous = if depth == #path - 1 and childOldKnown then childOld else childNew
				fire(tree, pathKey, "OnChildChanged", path[depth + 1], childNew, previous)
			end
			local list = byEvent.Changed
			if list and next(list) ~= nil then
				if not deferring then
					local value = readValue(tree, prefix)
					fire(tree, pathKey, "Changed", value, value)
				else
					local pending = tree._pendingAncestors
					if pending == nil then
						pending = {}
						tree._pendingAncestors = pending
						tree._pendingAncestorOrder = {}
					end
					if (pending :: any)[pathKey] == nil then
						(pending :: any)[pathKey] = prefix
						local order = tree._pendingAncestorOrder :: { string }
						order[#order + 1] = pathKey
					end
				end
			end
		end
		childPrefix = prefix
	end
end

-- A container's own STATE fire, routed through the same defer queue fireAncestors
-- uses. Insert/Remove/Clear mutate at the container's OWN path rather than a child's,
-- so they never reach fireAncestors for that node and fired N times inside a batch
-- where every other container fires once. Deferring is safe for exactly the same
-- reason it is there: the fire is (value, value), so there is no prior state a
-- collapse can lose, and the per-entry transitions are already carried separately by
-- OnInsert and OnRemove.
local function deferSelfState(tree: Tree, pathKey: string, path: { string | number }): boolean
	if tree._replaying then
		-- Same suppression `fire` applies: ReplayFire fires every observed path
		-- itself once the apply is done, so queuing here would double it.
		return true
	end
	if tree._batchDepth == 0 then
		return false
	end
	local list = listenersFor(tree, pathKey, "Changed", false)
	if list == nil or next(list) == nil then
		return true -- nothing listening: skip the fire either way
	end
	local pending = tree._pendingAncestors
	if pending == nil then
		pending = {}
		tree._pendingAncestors = pending
		tree._pendingAncestorOrder = {}
	end
	if (pending :: any)[pathKey] == nil then
		(pending :: any)[pathKey] = table.clone(path)
		local order = tree._pendingAncestorOrder :: { string }
		order[#order + 1] = pathKey
	end
	return true
end

-- Fire the ancestor Changed events a batch deferred, one per container. Values are
-- read NOW, so every listener sees the batch's end state.
--
-- Order is first-touch: each write queues its own ancestors deepest-first, and a
-- container already queued keeps its original position. That reproduces the order
-- the same writes would have fired unbatched, minus the duplicates, which is the
-- property that matters. It is NOT globally deepest-first across writes, and
-- sorting it that way would move fires relative to the unbatched order.
local function flushPendingAncestors(tree: Tree)
	local pending = tree._pendingAncestors
	if pending == nil then
		return
	end
	local order = tree._pendingAncestorOrder :: { string }
	tree._pendingAncestors = nil
	tree._pendingAncestorOrder = nil
	for _, pathKey in order do
		local list = listenersFor(tree, pathKey, "Changed", false)
		if list and next(list) ~= nil then
			local value = readValue(tree, pending[pathKey])
			fire(tree, pathKey, "Changed", value, value)
		end
	end
end

-- Drop a rolled-back transaction's deferred fires. The writes that queued them no
-- longer happened, and the restores below fire their own Changed with the
-- pre-transaction values.
--
-- Scoped to what the TRANSACTION queued, via a mark taken when it opened. The queue
-- is tree-wide, so a transaction nested in a Data.Batch shares it with the batch's
-- own surviving writes: clearing it wholesale swallowed those too, and the batch
-- ended with the data written but no container Changed on the server, while the
-- client mirror fired one from the same frame. Anything the batch queued sits below
-- the mark and survives; the dedupe in fireAncestors means a container both touched
-- stays queued once, at its earlier position, which is correct because the batch's
-- write to it still happened.
local function discardPendingAncestors(tree: Tree, mark: number)
	local order = tree._pendingAncestorOrder
	if order == nil then
		return
	end
	local pending = tree._pendingAncestors :: any
	for i = #order, mark + 1, -1 do
		pending[order[i]] = nil
		order[i] = nil
	end
	if mark == 0 then
		tree._pendingAncestors = nil
		tree._pendingAncestorOrder = nil
	end
end

-- A whole-table write at one path silently changes every leaf beneath it, but
-- `fire` only touches that exact pathKey and `fireAncestors` only walks upward,
-- so a listener bound to a descendant would never hear about it: `Get()` returns
-- the new value while a bound `Observe` renders the old one forever. These two
-- helpers snapshot the observed descendants before the write and fire whichever
-- actually changed after it, matching what `Tree.ReplayFire` already does for
-- the Init path. Scoped to STRICT descendants: the written path itself is fired
-- by the caller, and `leafEquals` is false for tables, so including it would
-- double-fire the container's own observer.
local function snapshotDescendants(tree: Tree, pathKey: string): { [string]: any }?
	if next(tree._listeners) == nil then
		return nil
	end
	-- Root writes are rejected upstream, so pathKey is never "" here; a non-empty
	-- prefix plus the separator cannot match the written path itself.
	local prefix = pathKey .. "\31"
	local olds: { [string]: any }? = nil
	for key, path in tree._paths do
		if #key > #prefix and string.sub(key, 1, #prefix) == prefix then
			local byEvent = tree._listeners[key]
			if byEvent and byEvent.Changed then
				olds = olds or {}
				(olds :: { [string]: any })[key] = readValue(tree, path)
			end
		end
	end
	return olds
end

local function fireDescendants(tree: Tree, olds: { [string]: any }?)
	if not olds then
		return
	end
	-- Collect before firing: a fired listener may add or remove listeners.
	local pending: { { Key: string, New: any, Old: any } } = {}
	for key, old in olds do
		local path = tree._paths[key]
		if path then
			local current = readValue(tree, path)
			if not Util.leafEquals(current, old) then
				table.insert(pending, { Key = key, New = current, Old = old })
			end
		end
	end
	for _, item in pending do
		fire(tree, item.Key, "Changed", item.New, item.Old)
	end
end

-- Tier-1 validation ----------------------------------------------------------

local function anomaly(tree: Tree, path: { string | number }, value: any, reason: string)
	if tree.Params.OnAnomaly then
		tree.Params.OnAnomaly(path, value, reason)
	end
end

local function validationError(path: { string | number }, message: string): never
	error(`Scribe: invalid write to "{Util.pathString(path)}": {message}`, 0)
end

-- Matches the wire codec's recursion cap (Wire.luau); a value that passes
-- validation must always be encodable, so over-deep tables are rejected here.
local MAX_VALUE_DEPTH = Util.MAX_VALUE_DEPTH

-- Truncate `s` to at most `maxBytes` bytes WITHOUT splitting a multi-byte UTF-8
-- character. Callers pass a string already validated as UTF-8, so any byte in
-- 0x80..0xBF is a continuation byte: if the character straddling the cut point
-- extends past the limit, walk the cut back off it. A plain string.sub would
-- leave a half-encoded trailing character that fails the DataStore save (the
-- library must never manufacture invalid UTF-8 while clamping MaxLength). Valid
-- UTF-8 characters are at most 4 bytes, so the loop runs at most 3 times.
local function truncateUtf8(s: string, maxBytes: number): string
	if #s <= maxBytes then
		return s
	end
	local cut = maxBytes
	while cut > 0 do
		local nextByte = string.byte(s, cut + 1)
		if nextByte == nil or nextByte < 0x80 or nextByte >= 0xC0 then
			break -- byte after the cut starts a fresh character (or end of string)
		end
		cut -= 1
	end
	return string.sub(s, 1, cut)
end

-- Returns the (possibly clamped) value to write. Throws on type violations.
local function validateWrite(
	tree: Tree,
	schema: SchemaNode?,
	path: { string | number },
	value: any,
	depth: number?
): any
	if value == nil then
		return nil
	end
	-- Depth is budgeted from the ROOT (seeded with the path length), because
	-- Init snapshots re-encode the whole root from depth 0. A value accepted
	-- here must always be encodable from the root, or it silently drops the
	-- entire root from every snapshot.
	local d = depth or math.max(0, #path - 1)
	if d > MAX_VALUE_DEPTH then
		validationError(path, `nested deeper than {MAX_VALUE_DEPTH} levels from the root`)
	end

	-- Declared datatype fields accept their Roblox datatype (packed at the
	-- boundary) or an already-packed buffer (timed sweeps restoring defaults,
	-- migrations writing packed values). Checked before the generic type gate,
	-- which would otherwise reject the userdata.
	if schema and schema.ValueType == "datatype" then
		local name = schema.Datatype :: string
		if typeof(value) == name then
			local ok, packed = pcall(Datatypes.Pack, name, value)
			if not ok then
				if type(packed) == "string" and string.find(packed, Datatypes.NONFINITE, 1, true) then
					anomaly(tree, path, value, "NonFiniteComponent")
					validationError(path, `{name} has a NaN/inf component`)
				end
				validationError(path, `could not pack {name}: {tostring(packed)}`)
			end
			return packed
		end
		if type(value) == "buffer" then
			return Util.cloneBuffer(value)
		end
		validationError(path, `expected {name}, got {typeof(value)}`)
	end

	local t = type(value)
	if t == "function" or t == "thread" or t == "userdata" or typeof(value) ~= t then
		validationError(path, `unsupported type "{typeof(value)}"`)
	end
	if t == "number" and (value ~= value or value == math.huge or value == -math.huge) then
		validationError(path, "NaN/inf")
	end
	-- A string with invalid UTF-8 bytes cannot be JSON-encoded for the DataStore:
	-- the ENTIRE profile save fails (error 104), silently, long after this write.
	-- Reject it here -- for every string leaf, whatever its declared type (string,
	-- enum, or an untyped `any` field) -- so the failure names the exact path at
	-- the write site instead of surfacing as an opaque save error later.
	if t == "string" and not Util.isUtf8(value :: string) then
		anomaly(tree, path, value, "InvalidUtf8")
		validationError(path, "string contains invalid UTF-8 bytes")
	end

	local vt = if schema then schema.ValueType else "any"
	local policy = tree.Params.BoundsPolicy or "Clamp"

	if vt == "boolean" then
		if t ~= "boolean" then
			validationError(path, `expected boolean, got {t}`)
		end
	elseif vt == "number" or vt == "int" then
		if t ~= "number" then
			validationError(path, `expected number, got {t}`)
		end
		local v = value :: number
		if vt == "int" and v % 1 ~= 0 then
			if policy == "Reject" then
				validationError(path, "expected integer")
			end
			v = math.floor(v + 0.5)
		end
		local min = schema and schema.Min
		local max = schema and schema.Max
		if (min and v < min) or (max and v > max) then
			anomaly(tree, path, value, "OutOfBounds")
			if policy == "Reject" then
				validationError(path, `out of bounds [{min or "-inf"}, {max or "inf"}]`)
			end
			v = math.clamp(v, min or -math.huge, max or math.huge)
		end
		return v
	elseif vt == "big" then
		local parsed = Big.from(value)
		if parsed == nil then
			validationError(path, `expected a number or a numeric string, got {t}`)
		end
		local big = parsed :: any
		local min = schema and schema.Min
		local max = schema and schema.Max
		if min ~= nil then
			local floor = Big.from(min) :: any
			if Big.compare(big, floor) < 0 then
				anomaly(tree, path, Big.toString(big), "OutOfBounds")
				if policy == "Reject" then
					validationError(path, `below Min {Big.toString(floor)}`)
				end
				big = floor
			end
		end
		if max ~= nil then
			local ceiling = Big.from(max) :: any
			if Big.compare(big, ceiling) > 0 then
				anomaly(tree, path, Big.toString(big), "OutOfBounds")
				if policy == "Reject" then
					validationError(path, `above Max {Big.toString(ceiling)}`)
				end
				big = ceiling
			end
		end
		return Big.toStored(big)
	elseif vt == "flags" then
		if t ~= "table" then
			validationError(path, `expected a table of member names, got {t}`)
		end
		-- Normalize to declaration order with duplicates dropped, so the stored value
		-- is canonical. Without that, { "B", "A" } and { "A", "B" } would be
		-- different tables meaning the same thing, and every diff and equality check
		-- downstream would have to care about write order.
		local index = (schema and schema.MemberIndex) :: { [string]: number }?
		local enabled: { [string]: boolean } = {}
		for _, name in value :: { any } do
			if type(name) ~= "string" then
				validationError(path, `flag names must be strings, got {type(name)}`)
			end
			if index == nil or index[name] == nil then
				anomaly(tree, path, name, "NotAMember")
				validationError(path, `"{tostring(name)}" is not a member of the flags`)
			end
			enabled[name] = true
		end
		local out = {}
		for _, name in (schema and schema.Members) :: { string } do
			if enabled[name] then
				table.insert(out, name)
			end
		end
		return out
	elseif vt == "string" or vt == "enum" then
		if t ~= "string" then
			validationError(path, `expected string, got {t}`)
		end
		if vt == "enum" then
			local index = schema and schema.MemberIndex
			if index and index[value] == nil then
				anomaly(tree, path, value, "NotAMember")
				validationError(path, `"{value}" is not a member of the enum`)
			end
		end
		local maxLength = schema and schema.MaxLength
		if maxLength and #(value :: string) > maxLength then
			anomaly(tree, path, value, "OverMaxLength")
			if policy == "Reject" then
				validationError(path, `exceeds MaxLength {maxLength}`)
			end
			-- Truncate on a character boundary: MaxLength is a byte budget, and a
			-- raw string.sub could split the multi-byte character straddling it,
			-- producing invalid UTF-8 that then fails the save (the value above is
			-- already validated as UTF-8, so this only ever shortens it).
			return truncateUtf8(value :: string, maxLength)
		end
	elseif vt == "buffer" then
		if t ~= "buffer" then
			validationError(path, `expected buffer, got {t}`)
		end
	elseif vt == "table" then
		if t ~= "table" then
			validationError(path, `expected table, got {t}`)
		end
	end

	if t == "buffer" then
		-- Buffers are mutable: store a private copy so a caller-held reference
		-- can't bypass replication later.
		return Util.cloneBuffer(value)
	end

	if t == "table" then
		-- Recursive Tier-1 over the written table; cost is proportional to the
		-- table being written. The root-relative depth guard at the top rejects
		-- any level the wire codec could not encode.
		-- A numeric key N and the string key tostring(N) produce the SAME pathKey
		-- (Util.pathKey tostring's every segment), so they would alias distinct slots
		-- in listeners, coalescing, and transaction rollback. Reject that ambiguity,
		-- mirroring the \31 guard below. Only scanned when numeric keys are present.
		if Util.hasNumericKeys(value :: any) then
			for k in value :: any do
				-- A mixed table cannot be JSON-encoded for the DataStore: the whole
				-- profile save fails later, silently, far from this write. Reject at
				-- the write site (this also subsumes the numeric/string alias pair).
				if type(k) == "string" then
					validationError(
						path,
						"a table cannot mix array indices and string keys (it would fail the DataStore save)"
					)
				end
			end
		end
		-- A whole-container write to a Scribe.ArrayOf / Scribe.DictOf must match the
		-- declared key shape. Without this, a pure-dictionary payload passes the plain
		-- table gate above and lands under a field typed `{ Record }`.
		local container = if schema then schema.Container else nil
		if container ~= nil then
			local declared = schema :: SchemaNode
			local count = 0
			local maxIndex = 0
			for k in value do
				count += 1
				if container == "Array" then
					if type(k) ~= "number" then
						validationError(path, `Scribe.ArrayOf takes array entries, but "{tostring(k)}" is a string key`)
					end
					if (k :: number) > maxIndex then
						maxIndex = k :: number
					end
				elseif declared.KeyType == "integer" then
					-- A Scribe.MapOf("integer") declares its key type, so a whole-table
					-- write has to be judged against THAT, not against DictOf's string
					-- assumption. Judging it wrongly refuses the map's own keys and
					-- accepts the ones it cannot store.
					if type(k) ~= "number" then
						validationError(
							path,
							`Scribe.MapOf("integer") takes integer keys, but "{tostring(k)}" is a string key`
						)
					end
					local n = k :: number
					if n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 then
						validationError(path, `key {tostring(k)} is not a finite integer`)
					end
				else
					if type(k) ~= "string" then
						validationError(path, `Scribe.DictOf takes string keys, but {tostring(k)} is a number key`)
					end
					local maxKeyLength = declared.MaxKeyLength
					if maxKeyLength and #(k :: string) > maxKeyLength then
						validationError(path, `key "{k}" is {#(k :: string)} bytes, over MaxKeyLength {maxKeyLength}`)
					end
				end
			end
			-- Cap checks tolerate a container that is ALREADY over cap in storage
			-- (written by a newer-template server before this server's lower cap
			-- deployed): only growth past the stored size is refused.
			local function storedCount(): number
				local stored = readValue(tree, path)
				return if type(stored) == "table" then Util.count(stored) else 0
			end
			if container == "Array" then
				-- `#value` stops at the first hole (any border is legal for a table
				-- with a hash part), so compare against the HIGHEST key instead: a
				-- ragged payload always has maxIndex > count.
				if count ~= maxIndex then
					validationError(path, "array entries must run contiguously from 1 (no holes)")
				end
				local maxItems = declared.MaxItems
				if maxItems then
					-- A set is stored deduplicated, so its cap is on MEMBERSHIP. Counting
					-- the caller's raw array refused writes whose resulting set fits,
					-- e.g. Set({1,1,1}) against MaxItems 2.
					local effective = count
					if declared.Unique then
						local seen: { [any]: boolean } = {}
						effective = 0
						for _, item in value do
							if not seen[item] then
								seen[item] = true
								effective += 1
							end
						end
					end
					if effective > maxItems and effective > storedCount() then
						validationError(path, `holds {effective} entries, over MaxItems {maxItems}`)
					end
				end
			else
				local maxKeys = declared.MaxKeys
				if maxKeys and count > maxKeys and count > storedCount() then
					validationError(path, `holds {count} keys, over MaxKeys {maxKeys}`)
				end
			end
		end

		local out = {}
		for k, v in value do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then
				validationError(path, `unsupported key type "{kt}"`)
			end
			if kt == "number" then
				-- Non-integer / non-finite numeric keys do not survive the
				-- DataStore JSON round-trip; reject them at the write boundary.
				if k ~= k or k == math.huge or k == -math.huge or k % 1 ~= 0 then
					validationError(path, "invalid numeric key (must be a finite integer)")
				end
			else
				local ks = k :: string
				if string.find(ks, "\31", 1, true) then
					-- char 31 is the pathKey separator; a key containing it would
					-- alias a distinct path in coalescing/listeners/rollback.
					validationError(path, "string key may not contain control character \\31")
				end
				-- A JSON object key must be valid UTF-8 too; an invalid-byte key
				-- fails the whole profile save exactly like an invalid string value.
				if not Util.isUtf8(ks) then
					validationError(path, "string key contains invalid UTF-8 bytes")
				end
			end
			local childSchema = if schema then Template.ChildSchema(schema, k) else nil
			-- A declared element record has a fixed field set, so an undeclared key is
			-- a typo, not an untyped extra field. ChildSchema returns nil rather than
			-- synthesizing (and caching) an `any` node for exactly this case. The one
			-- exception: a key this profile ALREADY stores at this path was written by
			-- a newer template during a rolling deploy; rejecting it would turn every
			-- read-modify-write on an old server into a lost write, so it is carried
			-- through (generically validated) instead.
			if childSchema == nil and schema and schema.Closed then
				local stored = readValue(tree, path)
				if not (type(stored) == "table" and stored[k] ~= nil) then
					validationError(path, `"{tostring(k)}" is not a declared field of this element shape`)
				end
			end
			local childPath = table.clone(path)
			table.insert(childPath, k)
			out[k] = validateWrite(tree, childSchema, childPath, v, d + 1)
		end
		-- Fill declared element fields the caller omitted. The element type says they
		-- are always present, so storing a partial element would nil-crash every
		-- consumer written against it. Nullable (Scribe.Optional) fields have a nil
		-- default and stay absent, which is what makes them optional.
		if schema and schema.Closed and schema.Children then
			for name, child in schema.Children do
				if out[name] == nil and child.Default ~= nil then
					-- A mirror never fills a ServerOnly field: no replicated op would
					-- ever have sent it, so filling it would make an optimistic local
					-- write visibly diverge from the server-replicated element.
					if tree.Params.IsServer or child.Visibility ~= "ServerOnly" then
						out[name] = Util.deepClone(child.Default)
					end
				end
			end
		end
		if schema and schema.Unique then
			-- Deduplicate and sort, so the stored form of a set is canonical: two
			-- profiles holding the same members hold the same table, and Add is
			-- idempotent no matter what order things were written in. Sorting is
			-- safe because Template refuses any set element that is not an
			-- orderable scalar.
			local seen: { [any]: boolean } = {}
			local unique = {}
			for _, item in out do
				if not seen[item] then
					seen[item] = true
					table.insert(unique, item)
				end
			end
			table.sort(unique)
			return unique
		end
		return out
	end

	return value
end

-- Mutation core ----------------------------------------------------------------

type WriteOpts = {
	Replicate: boolean?,
	FromRemote: boolean?,
	NoOp: boolean?, -- rollback writes: fire listeners but never emit ops
	NoValidate: boolean?,
}

local function emitOp(tree: Tree, op: Op, schema: SchemaNode?, opts: WriteOpts)
	if opts.NoOp or opts.FromRemote or opts.Replicate == false then
		return
	end
	local onOp = tree.Params.OnOp
	if onOp == nil then
		return
	end
	if tree._txn then
		table.insert(tree._txn.Ops, { Op = op, Schema = schema })
	else
		onOp(op, schema)
	end
end

-- Whether `a` is a strict ancestor path of `b` (a shorter, matching prefix).
local function pathIsStrictAncestor(a: { string | number }, b: { string | number }): boolean
	if #a >= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- Restore `value` at a relative path inside `root`, creating tables as needed.
local function setNested(root: { [any]: any }, relPath: { string | number }, value: any)
	local container = root
	for i = 1, #relPath - 1 do
		local seg = relPath[i]
		local nextContainer = container[seg]
		if type(nextContainer) ~= "table" then
			nextContainer = {}
			container[seg] = nextContainer
		end
		container = nextContainer
	end
	container[relPath[#relPath]] = value
end

-- Remove `relPath` from `root` WITHOUT creating any intermediate tables (unlike
-- setNested): if an ancestor along the way is already absent, there is nothing to
-- remove. Used to strip txn-materialized descendant containers out of a rollback
-- reconstruction so no phantom empty sub-table survives.
local function removeNested(root: { [any]: any }, relPath: { string | number })
	local container = root
	for i = 1, #relPath - 1 do
		local nextContainer = container[relPath[i]]
		if type(nextContainer) ~= "table" then
			return
		end
		container = nextContainer
	end
	container[relPath[#relPath]] = nil
end

-- Records the pre-transaction value of `path`, keeping snapshots DISJOINT so
-- rollback order is irrelevant. If an ancestor is already snapshotted, this
-- subtree is covered. If descendants were snapshotted earlier, this path's true
-- pre-transaction value is reconstructed by overlaying their pre-txn values
-- onto the current (possibly already-mutated) value, and those now-subsumed
-- descendant snapshots are dropped.
local function snapshotForTxn(tree: Tree, path: { string | number }, pathKey: string, oldValue: any)
	local txn = tree._txn
	if not txn or txn.Snapshots[pathKey] ~= nil then
		return
	end
	for _, snap in txn.Snapshots do
		if pathIsStrictAncestor(snap.Path, path) then
			return
		end
	end
	local value = Util.deepClone(oldValue)
	-- Track which descendant snapshots get overlaid: each one is the AUTHORITATIVE
	-- pre-txn state at its path (first-write-wins), which the Created-strip below
	-- must not undo.
	local overlaid: { { string | number } }? = nil
	for descKey, snap in txn.Snapshots do
		if pathIsStrictAncestor(path, snap.Path) then
			if type(value) ~= "table" then
				value = {}
			end
			local relPath = table.move(snap.Path, #path + 1, #snap.Path, 1, table.create(#snap.Path - #path))
			setNested(value, relPath, snap.Value)
			overlaid = overlaid or {}
			table.insert(overlaid :: { { string | number } }, snap.Path)
			txn.Snapshots[descKey] = nil
		end
	end
	-- Reconcile the reconstruction with containers materialized during this txn
	-- (txn.Created), so a rollback cannot resurrect them as phantom empty tables
	-- (which coveredBySnapshot would then shield from the Created-prune). Two cases:
	-- the snapshotted container ITSELF was created (its pre-txn value is nil), or a
	-- STRICT DESCENDANT container was created (strip it out of the reconstruction).
	-- CAVEAT on the strip: txn.Created records containers materialized MID-txn, which
	-- includes a PRE-EXISTING container deleted then recreated within this txn. Its
	-- deletion recorded a snapshot whose overlay above just re-established the genuine
	-- pre-txn subtree -- stripping that would destroy committed data on rollback. So
	-- only strip a created path when NO overlaid snapshot sits at or above it (an
	-- overlay strictly BELOW it only materialized intermediates, not the container).
	local function establishedByOverlay(createdPath: { string | number }): boolean
		if not overlaid then
			return false
		end
		for _, snapPath in overlaid :: { { string | number } } do
			if #snapPath <= #createdPath then
				local isPrefix = true
				for i = 1, #snapPath do
					if snapPath[i] ~= createdPath[i] then
						isPrefix = false
						break
					end
				end
				if isPrefix then
					return true
				end
			end
		end
		return false
	end
	if value ~= nil then
		local pathCreated = false
		for _, createdPath in txn.Created do
			if #createdPath == #path then
				local same = true
				for i = 1, #path do
					if createdPath[i] ~= path[i] then
						same = false
						break
					end
				end
				if same then
					pathCreated = true
					break
				end
			end
		end
		if pathCreated then
			value = nil
		elseif type(value) == "table" then
			for _, createdPath in txn.Created do
				if pathIsStrictAncestor(path, createdPath) and not establishedByOverlay(createdPath) then
					local relPath: { string | number } = {}
					for i = #path + 1, #createdPath do
						relPath[#relPath + 1] = createdPath[i]
					end
					removeNested(value, relPath)
				end
			end
		end
	end
	txn.Snapshots[pathKey] = { Path = table.clone(path), Value = value }
end

local applySet: (Tree, { string | number }, SchemaNode?, any, WriteOpts) -> any

-- Materializes every missing DECLARED-ELEMENT intermediate along `path` as a real
-- applySet write of the element's seeded defaults, BEFORE the caller's own write
-- resolves the chain. This is what makes materialization visible everywhere a
-- write is visible: the element Set op replicates (so plain Shared mirrors, which
-- apply ops with no schema, reconstruct the full element instead of a bare {}),
-- OnKeyAdded fires for the new key, hooks record the true old value, and a
-- transaction snapshots the creation for rollback. It also means a later leaf
-- write that happens to EQUAL the element default can safely no-op: the entry's
-- existence already replicated. Untyped intermediates keep their silent plain-{}
-- materialization in resolveContainer.
local function seedMissingElements(tree: Tree, path: { string | number }, schema: SchemaNode?, opts: WriteOpts)
	local n = #path
	if n < 2 or schema == nil then
		return
	end
	local chain: { SchemaNode } = table.create(n)
	local cursor: SchemaNode? = schema
	for i = n, 1, -1 do
		if cursor == nil then
			break
		end
		chain[i] = cursor
		cursor = cursor.Parent
	end
	local validating = not opts.NoValidate and not opts.FromRemote
	local container: any = storeFor(tree, path[1])
	for i = 1, n - 1 do
		if type(container) ~= "table" then
			return -- the caller's own resolve reports the real error
		end
		local seg = path[i]
		local nextContainer = container[seg]
		if nextContainer == nil then
			local createdSchema = chain[i]
			if createdSchema and createdSchema.IsElement then
				local seed = if tree.Params.IsServer then createdSchema.Default else createdSchema.ClientDefault
				if type(seed) == "table" then
					-- The element's own key must satisfy its container's rules before
					-- the seed write lands (the seed applySet runs NoValidate, since
					-- the compiled default is already storage-form).
					if validating and i > 1 then
						checkContainerKey(
							chain[i - 1],
							container,
							seg,
							Util.pathString(table.move(path, 1, i - 1, 1, {}))
						)
						-- And the same alias guard resolveContainer applies. Seeding
						-- here reaches the container FIRST, so a numeric key
						-- materializing next to its existing string form would leave
						-- resolveContainer's own check looking at a key that already
						-- exists, and it would never run. Both forms would persist, and
						-- the load-time key coercion resolves such a pair by
						-- overwriting one with the other, losing a saved write.
						--
						-- Defence in depth: checkContainerKey above rejects the
						-- mismatched form for every DECLARED container, so no public
						-- call reaches this today and no test can pin it. It is kept
						-- because it is the cheap half of a pair whose other half is
						-- load-bearing, and because "unreachable" here depends on a
						-- guard in a different function.
						local alias = aliasForm(seg)
						if alias ~= nil and container[alias] ~= nil then
							error(
								`Scribe: key "{tostring(seg)}" at "{Util.pathString(path)}" collides with the `
									.. `existing "{tostring(alias)}" key form (a numeric key and its string form `
									.. "cannot coexist)",
								0
							)
						end
					end
					local prefix = table.move(path, 1, i, 1, table.create(i))
					applySet(tree, prefix, createdSchema, Util.deepClone(seed), {
						NoValidate = true,
						FromRemote = opts.FromRemote,
						Replicate = opts.Replicate,
					})
					nextContainer = container[seg]
				end
			end
			if nextContainer == nil then
				return -- untyped intermediate: created silently by resolveContainer
			end
		end
		container = nextContainer
	end
end

function applySet(tree: Tree, path: { string | number }, schema: SchemaNode?, value: any, opts: WriteOpts): any
	-- validateWrite rebuilds tables entry-by-entry (no aliasing); unvalidated
	-- table writes are cloned explicitly instead.
	local newValue = if opts.NoValidate then value else validateWrite(tree, schema, path, value)
	if type(newValue) == "table" and opts.NoValidate then
		newValue = Util.deepClone(newValue)
	end

	-- A REMOTE nil-Set must materialize missing parents: the server only emits a
	-- removal when the parent chain existed at emission (a local nil-Set under a
	-- missing parent never emits), so if this mirror lacks the parents, the op that
	-- created them was coalesced away in the same flush and the server still holds
	-- them as (possibly empty) containers. Creating them here keeps existence and
	-- Count() parity. Local writes keep the no-op semantics.
	-- Seeding runs AFTER validateWrite so a rejected value never leaves a
	-- phantom element behind.
	if newValue ~= nil or opts.FromRemote == true then
		seedMissingElements(tree, path, schema, opts)
	end
	local container, key = resolveContainer(
		tree,
		path,
		newValue ~= nil or opts.FromRemote == true,
		schema,
		not opts.NoValidate and not opts.FromRemote
	)
	if container == nil then
		if newValue == nil then
			return nil -- removing under a missing parent is a no-op
		end
		error(`Scribe: cannot write to "{Util.pathString(path)}"`, 0)
	end

	-- Reject a keyed write whose OTHER-typed form already occupies the container
	-- (number 7 vs string "7"): their pathKeys alias (see validateWrite's whole-table
	-- guard, and resolveContainer for intermediate segments). Local validated writes
	-- only; remote/restore writes are trusted.
	if not opts.NoValidate and not opts.FromRemote then
		-- The last segment is a key of its parent, so a declared container's key rules
		-- apply to it too (resolveContainer only saw the INTERMEDIATE ones). Removals
		-- are checked as well, because a nil write to a middle array index would
		-- otherwise punch a hole and split #arr from Count().
		if schema and schema.Parent then
			checkContainerKey(
				schema.Parent,
				container,
				key,
				Util.pathString(table.move(path, 1, #path - 1, 1, {})),
				newValue == nil
			)
		end
		-- Deleting a declared, non-Optional field of a closed element record stores
		-- the partial element the closed shape exists to prevent (and that every
		-- consumer typed against the element would nil-crash on). Removing the
		-- WHOLE element stays legal: its parent is the container, not a record.
		if
			newValue == nil
			and schema
			and schema.Nullable ~= true
			and schema.Default ~= nil
			and schema.Parent
			and schema.Parent.Closed
			and container[key] ~= nil
		then
			error(
				`Scribe: "{Util.pathString(path)}" is a declared element field; Set a value instead of removing it `
					.. "(wrap the field in Scribe.Optional if absence is legitimate)",
				0
			)
		end
		if newValue ~= nil then
			local aliasKey = aliasForm(key)
			if aliasKey ~= nil and container[aliasKey] ~= nil then
				error(
					`Scribe: key at "{Util.pathString(path)}" collides with the existing "{tostring(aliasKey)}" key `
						.. "form (a numeric key and its string form cannot coexist)",
					0
				)
			end
		end
	end

	local old = container[key]
	if Util.leafEquals(old, newValue) then
		return old
	end

	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, old)
	-- Snapshot observed descendants BEFORE the write; a whole-table Set changes
	-- every leaf beneath this path and only this pass can report it.
	local descendantOlds = if type(newValue) == "table" or type(old) == "table"
		then snapshotDescendants(tree, pathKey)
		else nil
	container[key] = newValue

	emitOp(tree, { Kind = "Set", Path = table.clone(path), Value = newValue }, schema, opts)

	fire(tree, pathKey, "Changed", newValue, old)
	fireDescendants(tree, descendantOlds)
	-- Dictionary key events on the parent (dynamic keys only).
	if #path >= 1 then
		local parentPath = table.move(path, 1, #path - 1, 1, table.create(#path - 1)) :: { string | number }
		local parentSchema = if schema then schema.Parent else nil
		local isDynamic = parentSchema == nil
			or parentSchema.Children == nil
			or type(key) ~= "string"
			or parentSchema.Children[key :: string] == nil
		if isDynamic then
			local parentKey = Util.pathKey(parentPath)
			if old == nil and newValue ~= nil then
				fire(tree, parentKey, "OnKeyAdded", key, newValue)
			elseif old ~= nil and newValue == nil then
				fire(tree, parentKey, "OnKeyRemoved", key, old)
			end
		end
	end
	fireAncestors(tree, path, old, true)
	return newValue
end

local function ensureContainerValue(tree: Tree, path: { string | number }, schema: SchemaNode?): { [any]: any }
	local container, key = resolveContainer(tree, path, true, schema)
	if container == nil then
		error(`Scribe: cannot access "{Util.pathString(path)}"`, 0)
	end
	local value = container[key]
	if value == nil then
		value = {}
		container[key] = value
	elseif type(value) ~= "table" then
		error(`Scribe: "{Util.pathString(path)}" is not a container`, 0)
	end
	return value
end

-- Forward declaration: applyInsert evicts through the real remove path so the
-- client mirror receives a Remove op, rather than quietly shrinking the table.
local applyArrayRemove: (Tree, { string | number }, SchemaNode?, number?, WriteOpts) -> any

-- Scribe.Big and Scribe.Flags are LEAVES whose stored form happens to be a table (a
-- { mantissa, exponent } pair, and the list of enabled member names). Every container
-- mutation gates on the stored VALUE being a table, so they sailed through: Insert on
-- a big rewrote the pair, turning a 1e100 balance into 50, and Clear left a
-- non-Optional field reading nil. Both persisted and survived a rejoin.
--
-- A Scribe.SetOf is a real container, but its stored form is deduplicated and sorted
-- by the whole-value write path, which Insert and a positional write bypass, so it is
-- refused here too and callers are pointed at Add/Remove.
local function refuseStructuralWrite(schema: SchemaNode?, path: { string | number }, method: string)
	if schema == nil then
		return
	end
	local vt = schema.ValueType
	if vt == "big" then
		error(
			`Scribe: "{Util.pathString(path)}" is a Scribe.Big, not a container; {method} would rewrite its `
				.. "stored mantissa/exponent pair. Use Set, Increment, Decrement, Multiply or Divide",
			0
		)
	elseif vt == "flags" then
		error(
			`Scribe: "{Util.pathString(path)}" is a Scribe.Flags, not a container; {method} would corrupt its `
				.. "member list. Use Enable, Disable, Toggle or Clear",
			0
		)
	elseif schema.Unique then
		error(
			`Scribe: "{Util.pathString(path)}" is a Scribe.SetOf; {method} bypasses the dedupe and ordering `
				.. "its stored form depends on. Use Add or Remove",
			0
		)
	end
end

local function applyInsert(
	tree: Tree,
	path: { string | number },
	schema: SchemaNode?,
	item: any,
	pos: number?,
	opts: WriteOpts
)
	-- Validation only: Tree.ApplyOp replays replicated Inserts with FromRemote +
	-- NoValidate, and a mirror whose length is momentarily ahead of the server must
	-- not throw mid-frame (that drops the frame and desyncs permanently).
	local validating = not opts.NoValidate and not opts.FromRemote
	if validating then
		refuseStructuralWrite(schema, path, "Insert")
		if schema and schema.Container == "Dict" then
			error(`Scribe: "{Util.pathString(path)}" is a Scribe.DictOf; write a key instead of calling Insert`, 0)
		end
	end

	local pathKey = Util.pathKey(path)
	-- Read the existing array first (create = false, so nothing is materialized).
	-- The prospective index is needed up front so validation errors name the real
	-- element path, and MaxItems has to be refused before anything is written. The
	-- pre-creation value (nil if the array does not exist yet) is also what a
	-- rolled-back transaction must restore, rather than an empty table.
	local existingContainer, existingKey = resolveContainer(tree, path, false)
	local preValue = if existingContainer then existingContainer[existingKey] else nil
	local existingLength = if type(preValue) == "table" then #(preValue :: any) else 0
	local index = math.clamp(pos or existingLength + 1, 1, existingLength + 1)

	if validating and schema and schema.MaxItems and existingLength >= schema.MaxItems then
		if schema.Evict ~= "Front" and schema.Evict ~= "Back" then
			error(
				`Scribe: "{Util.pathString(path)}" already holds {existingLength} entries, `
					.. `at its MaxItems {schema.MaxItems}`,
				0
			)
		end
		-- Make room at the named end. This goes through the real remove path on
		-- purpose: a bare table.remove would shrink the server's array without
		-- emitting a Remove op, leaving every client mirror one entry longer
		-- forever. It also fires OnRemove, so a listener sees what was dropped.
		-- The loop handles an array already over cap (a lowered MaxItems, or data
		-- from before the cap existed) rather than trimming one entry per Insert.
		local dropFront = schema.Evict == "Front"
		for _ = 1, existingLength - schema.MaxItems + 1 do
			-- Recompute the tail index each pass: the array shrinks under us.
			local current = if type(preValue) == "table" then #(preValue :: any) else 0
			applyArrayRemove(tree, path, schema, if dropFront then 1 else current, opts)
		end
		-- Everything shifted down, so re-read rather than trusting the stale index.
		-- Rollback stays correct because applyArrayRemove already snapshotted the
		-- pre-eviction array, and snapshotForTxn keeps the FIRST value per pathKey.
		existingContainer, existingKey = resolveContainer(tree, path, false)
		preValue = if existingContainer then existingContainer[existingKey] else nil
		existingLength = if type(preValue) == "table" then #(preValue :: any) else 0
		index = math.clamp(pos or existingLength + 1, 1, existingLength + 1)
	end

	if validating then
		if item == nil then
			error(`Scribe: cannot Insert nil into "{Util.pathString(path)}"`, 0)
		end
		if pos ~= nil and (type(pos) ~= "number" or pos ~= pos or pos % 1 ~= 0) then
			-- A NaN/fractional position would silently write a hash-part index.
			error(`Scribe: Insert position must be an integer, got {tostring(pos)}`, 0)
		end
	end

	-- Validate the item BEFORE creating any container, so a rejected item can
	-- never leave a phantom container behind.
	local elementSchema = if schema then Template.ChildSchema(schema, index) else nil
	local elementPath = table.clone(path)
	table.insert(elementPath, index)
	-- Pass depth = #path: an inserted element sits one level BELOW the array's own
	-- path, so the default (#path - 1) under-budgets its nesting by one and would
	-- admit an element the Init-snapshot re-encode (wire depth cap == MAX_VALUE_DEPTH)
	-- cannot serialize, dropping the whole root from that client's snapshot.
	local value = if opts.NoValidate
		then Util.deepClone(item)
		else validateWrite(tree, elementSchema, elementPath, item, #path)

	-- Seed AFTER validation (a rejected item must not leave a phantom element),
	-- BEFORE the snapshot so intermediate declared elements replicate as real ops.
	seedMissingElements(tree, path, schema, opts)
	snapshotForTxn(tree, path, pathKey, preValue)

	local arr = ensureContainerValue(tree, path, schema)
	table.insert(arr, index, value)

	emitOp(tree, { Kind = "Insert", Path = table.clone(path), Value = value, Index = index }, schema, opts)
	fire(tree, pathKey, "OnInsert", value, index)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", arr, arr)
	end
	fireAncestors(tree, path)
end

function applyArrayRemove(
	tree: Tree,
	path: { string | number },
	schema: SchemaNode?,
	pos: number?,
	opts: WriteOpts
): any
	if not opts.NoValidate and not opts.FromRemote then
		refuseStructuralWrite(schema, path, "Remove by index")
	end
	local container, key = resolveContainer(tree, path, false)
	local arr = if container then container[key] else nil
	if type(arr) ~= "table" or #arr == 0 then
		return nil
	end
	-- No argument means "the last element". An EXPLICIT index outside the array is
	-- a no-op, not a clamp: clamping made Remove(99) on a 3-element array delete
	-- element 3, and Remove(0) delete element 1, silently destroying real data on
	-- what is almost always an off-by-one or a stale index.
	local index: number
	if pos == nil then
		index = #arr
	else
		if pos ~= math.floor(pos) or pos < 1 or pos > #arr then
			return nil
		end
		index = pos
	end

	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, arr)
	local item = table.remove(arr, index)

	emitOp(tree, { Kind = "Remove", Path = table.clone(path), Index = index }, schema, opts)
	fire(tree, pathKey, "OnRemove", item, index)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", arr, arr)
	end
	fireAncestors(tree, path)
	return item
end

local function applyClear(tree: Tree, path: { string | number }, schema: SchemaNode?, opts: WriteOpts)
	-- A Scribe.Flags legitimately clears to {} ("nothing enabled"), and so does a
	-- Scribe.SetOf, so only the big is refused here.
	if not opts.NoValidate and not opts.FromRemote and schema and schema.ValueType == "big" then
		refuseStructuralWrite(schema, path, "Clear")
	end
	local container, key = resolveContainer(tree, path, opts.FromRemote == true, schema)
	local value = if container then container[key] else nil
	if type(value) ~= "table" then
		if not (opts.FromRemote and container) then
			return
		end
		-- A remote Clear implies the container existed (as a table) server-side at
		-- emission -- a local Clear on a missing container never emits. If the op
		-- that created it was coalesced away in this flush, materialize it as {} so
		-- existence/Count() parity with the server holds.
		value = {}
		container[key] = value
	end
	local pathKey = Util.pathKey(path)
	snapshotForTxn(tree, path, pathKey, value)
	local descendantOlds = snapshotDescendants(tree, pathKey)
	table.clear(value)

	emitOp(tree, { Kind = "Clear", Path = table.clone(path) }, schema, opts)
	-- Bulk semantics: parent Changed fires once; per-entry key events don't. A
	-- descendant leaf listener is NOT a per-entry event though: its value really
	-- did change, and it has no other way to learn that.
	--
	-- Descendants BEFORE the container's own state, which is the only order both
	-- paths can share: inside a batch (and the client mirror is always batched) the
	-- self fire is deferred to the flush and necessarily lands last, so firing it
	-- first when unbatched made the same Clear deliver two different orders.
	fireDescendants(tree, descendantOlds)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", value, value)
	end
	fireAncestors(tree, path)
end

-- Applies a whole frame's ops as ONE batch, so N ops landing under the same
-- container produce a single container Changed rather than one per op. This is
-- the receiving half of Server.Batch: the server already coalesces a batch into
-- one frame, and without this the client would unpack that frame back into N
-- separate fires, which is exactly what a listener on the container is trying to
-- avoid. A frame is the unit of change as far as the client is concerned.
--
-- Leaf fires are untouched, so each field still reports its own transition.
function Tree.ApplyOps(self: Tree, ops: { Op })
	if self.Dead then
		return
	end
	self._batchDepth += 1
	local ok, err = pcall(function()
		for _, op in ops do
			self:ApplyOp(op)
		end
	end)
	self._batchDepth -= 1
	if self._batchDepth == 0 then
		-- Flush even when an op threw: the ops before it did land, and a listener
		-- that never hears about them is worse than one that hears late.
		flushPendingAncestors(self)
	end
	if not ok then
		error(err, 0)
	end
end

-- Applies an op received over the wire (client mirror / gift delivery replays).
function Tree.ApplyOp(self: Tree, op: Op)
	if self.Dead then
		return
	end
	-- Resolve the exact schema node (dynamic tail resolves to any-nodes).
	local baseSchema, dynStart = Template.Resolve(self.Compiled, op.Path)
	local exactSchema: SchemaNode? = baseSchema
	for i = dynStart, #op.Path do
		exactSchema = if exactSchema then Template.ChildSchema(exactSchema, op.Path[i]) else nil
	end
	local opts: WriteOpts = { FromRemote = true, NoValidate = true }
	if op.Kind == "Set" or op.Kind == "Init" then
		applySet(self, op.Path, exactSchema, op.Value, opts)
	elseif op.Kind == "Insert" then
		applyInsert(self, op.Path, exactSchema, op.Value, op.Index, opts)
	elseif op.Kind == "Remove" then
		applyArrayRemove(self, op.Path, exactSchema, op.Index, opts)
	elseif op.Kind == "Clear" then
		applyClear(self, op.Path, exactSchema, opts)
	end
end

-- Runs `apply` with per-op fires suppressed, then fires Changed once per
-- observed path the mutation actually changed. A whole-container Set fires
-- Changed only on the container and its ancestors, never its descendants, so a
-- nested Observe/Changed registered BEFORE the mutation would miss its value.
-- Used by the initial snapshot (ReplayInit) and edit-mode Mock, both of which
-- write whole roots. Cost is O(listeners) -- independent of player-data size.
function Tree.ReplayFire(self: Tree, apply: () -> ())
	if self.Dead then
		apply()
		return
	end
	-- Snapshot the pre-apply value of every observed path.
	local olds: { [string]: any } = {}
	for pathKey, path in self._paths do
		local byEvent = self._listeners[pathKey]
		if byEvent and byEvent.Changed then
			olds[pathKey] = readValue(self, path)
		end
	end
	self._replaying = true
	local ok, err = pcall(apply)
	self._replaying = false -- always cleared, even if `apply` threw
	if not ok then
		error(err, 0)
	end
	-- Collect the changed observed paths first (a fired listener may add or
	-- remove listeners), then fire. leafEquals is false for tables/buffers, so
	-- container observers always fire (matching a live whole-container Set);
	-- scalar leaves fire only on a real change.
	local pending: { { Key: string, New: any, Old: any } } = {}
	for pathKey, path in self._paths do
		local byEvent = self._listeners[pathKey]
		if byEvent and byEvent.Changed then
			local current = readValue(self, path)
			if not Util.leafEquals(current, olds[pathKey]) then
				table.insert(pending, { Key = pathKey, New = current, Old = olds[pathKey] })
			end
		end
	end
	for _, entry in pending do
		fire(self, entry.Key, "Changed", entry.New, entry.Old)
	end
end

-- Applies the initial snapshot (the caller has already reset the mirror to
-- defaults), firing nested observers registered before Init.
function Tree.ReplayInit(self: Tree, ops: { Op })
	self:ReplayFire(function()
		for _, op in ops do
			self:ApplyOp(op)
		end
	end)
end

-- Batch / Transaction ------------------------------------------------

function Tree.RunBatch(self: Tree, fn: () -> ())
	assertAlive(self)
	self._batchDepth += 1
	local ok, err = pcall(fn :: any)
	self._batchDepth -= 1
	if self._batchDepth == 0 then
		-- Listeners before replication, matching the unbatched ordering.
		flushPendingAncestors(self)
		if self.Params.OnBatchEnd then
			self.Params.OnBatchEnd()
		end
	end
	if not ok then
		error(err, 0)
	end
end

-- Register a pre-transaction value for a RAW store mutation (a direct write into
-- a plain dict that does not go through applySet -- e.g. the _Scribe.Timed store,
-- whose keys are full pathKeys containing \31 that the accessor tree rejects). If
-- a transaction is active, the first write to a given key records its pre-txn
-- value so a rollback can restore it; commits keep the write. No-op outside a
-- transaction. `key` is unique per store in practice (one raw store per tree).
function Tree.RecordRawWrite(self: Tree, store: { [string]: any }, key: string)
	local txn = self._txn
	if not txn or txn.RawRestores[key] ~= nil then
		return
	end
	txn.RawRestores[key] = { Store = store, Value = store[key] }
end

function Tree.RunTransaction(self: Tree, fn: () -> ()): (boolean, string?)
	assertAlive(self)
	if self._txn then
		error("Scribe: transactions do not nest", 2)
	end
	self._txn = { Snapshots = {}, Ops = {}, Created = {}, RawRestores = {}, Economy = {} }
	-- Everything already queued belongs to an enclosing batch, not to this
	-- transaction, so a rollback must leave it alone.
	local outerOrder = self._pendingAncestorOrder
	local pendingMark = if outerOrder then #outerOrder else 0
	-- RESTORED, not decremented, at the end. A Data.Batch opened inside `fn` raises
	-- the depth on `fn`'s own coroutine, and the yield path below closes that
	-- coroutine, which in Luau does NOT unwind pending frames: RunBatch's matching
	-- decrement dies with the stack. Decrementing only our own would leave the tree
	-- permanently above zero, and flushPendingAncestors is only ever reached at
	-- zero, so every container Changed and Observe on this player would go silently
	-- dead for the rest of the session.
	local depthBefore = self._batchDepth
	self._batchDepth += 1
	-- Run fn in its OWN coroutine so a yield can be detected. self._txn is set for
	-- the whole of fn, and every write path absorbs into it while it is set; if fn
	-- yielded (task.wait, a DataStore/Marketplace call), a concurrent write landing
	-- during the yield would be silently pulled into this transaction and rolled back
	-- with it (e.g. reverting a receipt grant, losing paid currency). Transactions
	-- must be synchronous, so refuse a yield loudly and roll back fn's writes so far.
	-- The inner xpcall preserves the original error traceback for the non-yield case.
	local co = coroutine.create(function()
		return xpcall(fn :: any, function(e)
			return debug.traceback(tostring(e), 2)
		end)
	end)
	local resumed, innerOk, innerErr = coroutine.resume(co)
	local ok, err
	if coroutine.status(co) ~= "dead" then
		coroutine.close(co) -- cancel it so the scheduler never resumes it after rollback
		ok, err = false, YIELD_ERROR
	elseif not resumed then
		ok, err = false, tostring(innerOk) -- coroutine itself errored (should not happen)
	else
		ok, err = innerOk, innerErr
	end
	local txn = self._txn :: any
	self._txn = nil
	self._batchDepth = depthBefore
	if not ok then
		discardPendingAncestors(self, pendingMark)
	end

	if ok then
		local onOp = self.Params.OnOp
		if onOp then
			for _, entry in txn.Ops :: { { Op: Op, Schema: SchemaNode? } } do
				onOp(entry.Op, entry.Schema)
			end
		end
		local onEconomy = self.Params.OnEconomy
		if onEconomy then
			for _, event in txn.Economy :: { { Path: { string | number }, Delta: number, New: number, Tags: any } } do
				onEconomy(event.Path, event.Delta, event.New, event.Tags)
			end
		end
		if self._batchDepth == 0 then
			flushPendingAncestors(self)
			if self.Params.OnBatchEnd then
				self.Params.OnBatchEnd()
			end
		end
		return true, nil
	end

	-- Roll back every touched field to its pre-transaction value (listeners fire
	-- with the restored values). Restores EMIT replication ops: the client never
	-- saw the txn's deferred ops, so a restore op is normally a no-op Set of the
	-- value the client already holds (and compactOps coalesces the batch) -- but if
	-- a listener fired by an EARLIER restore wrote a field this txn also touched,
	-- that listener write replicated, and only an emitted restore corrects the
	-- client back to the server's final (pre-txn) value. Suppressing them (the old
	-- NoOp) left the client holding the listener's value while the server kept the
	-- restore: a silent mirror divergence. Snapshots are disjoint, so restore order
	-- does not matter.
	for _, snapshot in txn.Snapshots :: { [string]: { Path: { string | number }, Value: any } } do
		local baseSchema, dynStart = Template.Resolve(self.Compiled, snapshot.Path)
		local exactSchema: SchemaNode? = baseSchema
		for i = dynStart, #snapshot.Path do
			exactSchema = if exactSchema then Template.ChildSchema(exactSchema, snapshot.Path[i]) else nil
		end
		applySet(self, snapshot.Path, exactSchema, snapshot.Value, {
			NoValidate = true,
		})
	end
	-- Restore raw store writes (e.g. _Scribe.Timed expiries) that bypassed applySet;
	-- a nil pre-txn value restores by removing the key.
	for key, restore in txn.RawRestores :: { [string]: { Store: { [string]: any }, Value: any } } do
		restore.Store[key] = restore.Value
	end
	-- Prune containers materialized during the transaction (deepest first) so no
	-- phantom empty tables survive a rollback. A created path covered by a
	-- snapshot (exact or ancestor) is authoritative pre-txn state that the
	-- restore just recreated — never prune those; only prune true phantoms.
	local created = txn.Created :: { { string | number } }
	local snapshots = txn.Snapshots :: { [string]: { Path: { string | number }, Value: any } }
	local function coveredBySnapshot(createdPath: { string | number }): boolean
		for _, snap in snapshots do
			if #snap.Path == #createdPath then
				local same = true
				for i = 1, #snap.Path do
					if snap.Path[i] ~= createdPath[i] then
						same = false
						break
					end
				end
				if same then
					return true
				end
			elseif pathIsStrictAncestor(snap.Path, createdPath) then
				return true
			end
		end
		return false
	end
	for i = #created, 1, -1 do
		if not coveredBySnapshot(created[i]) then
			local container, key = resolveContainer(self, created[i], false)
			-- No emptiness requirement: a path in Created provably did not exist before
			-- the transaction, so removing it wholesale is correct. It is also necessary,
			-- because a declared element materializes from its defaults rather than {}
			-- and so is never empty to begin with.
			if container ~= nil and type(container[key]) == "table" then
				-- Prune through applySet so the removal EMITS: the restore ops above
				-- replicate, and a restore op beneath this created container has just
				-- materialized it on the client (remote removals create intermediates
				-- for parity). A silent raw removal here would strand that client-side
				-- phantom {} forever. Deepest-first order ships child removals first.
				local baseSchema, dynStart = Template.Resolve(self.Compiled, created[i])
				local exactSchema: SchemaNode? = baseSchema
				for j = dynStart, #created[i] do
					exactSchema = if exactSchema then Template.ChildSchema(exactSchema, created[i][j]) else nil
				end
				applySet(self, created[i], exactSchema, nil, { NoValidate = true })
			end
		end
	end
	return false, tostring(err)
end

function Tree.Destroy(self: Tree)
	self.Dead = true
	table.clear(self._listeners)
	table.clear(self._accessors)
end

-- Accessor methods -----------------------------------------------------------------

--[=[
	@class Value

	A node in the accessor tree: what you get from indexing your data, e.g.
	`Data[player].Coins` or `data.Inventory.Sword`. Every field is a `Value`;
	container fields also expose their children as `Value`s.

	The method set is contextual: **all** fields have `Get`/`Set`/`Update`/
	`Observe`/`Changed`; number fields add `Increment`/`Decrement`; boolean fields
	add `Toggle`; array fields add `Insert`/`Remove`/…; dictionary fields add
	`Remove`/`Count`/…; `Scribe.Timed` fields add `SetTimed`/`ExtendTimed`/`Active`.
	On the client, `Set` writes are local-only (optimistic UI).

	:::caution Reserved names
	Because method names live on the node, a template field named `Get`, `Set`,
	`Count`, `Remove`, etc. is unreachable through the typed accessor. Scribe
	warns about this in Studio.
	:::
]=]

--[=[
	@function Get
	@within Value
	@tag Core
	@return T
	Returns the field's current value. A datatype field comes back as the real
	datatype, unpacked from its stored buffer.

	A **table** field returns the stored table, not a copy: only subtrees that
	actually contain datatypes are rebuilt on the way out, and everything else is
	shared by reference. Mutating what `Get` hands you edits authoritative state with
	no validation and no replication, so treat it as read-only and use [Value.Clone]
	when you intend to mutate.

	:::note The root is a special case
	`Data[player].Get()` is the one read that does not hand back the store. It
	returns a **frozen** table holding exactly the roots your template declares, so
	`Get().Coins = 1` raises at that line instead of quietly editing authoritative
	state. Scribe's own `_Scribe` and `_ScribeSession` roots are left out, which is
	what the accessor type has always said, and `Scribe.Session` roots are included,
	which it also said but the runtime used to omit. The freeze is shallow: nested
	containers are still the live tables described above. Use [Value.Clone] for a
	copy you can edit, and [Server.Export] when you want the profile including
	Scribe's internals.
	:::

	That applies to entries you reach through it too, which is the usual way this
	bites: an entry from `Get` is a plain table with no [Value.Set] of its own, so
	write through the accessor at that index instead.

	```lua
	local daily = data.Gifts.Daily
	for i, entry in daily.Get() do          -- read from the snapshot
	    if entry.GiftId == day then
	        daily[i].Claimed.Set(true)      -- write through the accessor
	        break
	    end
	end
	```

	A value that has not materialized yet reads `nil`: a field of a `Scribe.DictOf`
	key nothing has written, or a [Scribe.Optional] field. On a fresh key that `nil`
	is not the whole story, since [Value.Increment] and [Value.Toggle] start from the
	element's declared default there.
]=]

--[=[
	@function Set
	@within Value
	@tag Core
	@param value T
	@param replicate boolean?
	@return T
	Writes a new value (validated and clamped per the declarator). Fires
	`Changed`, replicates, and returns the stored value. Pass `replicate = false`
	to keep the write server-only.

	`Set(nil)` removes the field, except where that would store a shape nothing can
	read back:

	- a middle index of a [Scribe.ArrayOf], which punches a hole: `#arr` stops at the
	  gap and every replicated index below it shifts, so use [Value.Remove] (clearing
	  the tail is fine)
	- a declared, non-optional field of an element record, whose field set is closed:
	  wrap it in [Scribe.Optional] if absence is legitimate

	A whole-container `Set` on a [Scribe.ArrayOf] or [Scribe.DictOf] must match the
	declared key shape: contiguous integer keys from 1 for an array, string keys
	within `MaxKeyLength` for a dictionary, and no growth past `MaxItems` or
	`MaxKeys`. Omitted declared element fields fill from their defaults.
]=]

--[=[
	@function Update
	@within Value
	@tag Core
	@param transform (current: T) -> T
	@param replicate boolean?
	@return T
	Reads the current value, passes it to `transform`, and writes the result:
	a convenient read-modify-write.
]=]

--[=[
	@function Clone
	@within Value
	@tag Core
	@return T
	A deep copy of the value (for tables/buffers you intend to mutate locally).

	On the root accessor the copy holds exactly your declared template roots, the
	same shape [Value.Get] returns, and unlike `Get` it is not frozen. Scribe's
	`_Scribe` root is left out on purpose, because it is the copy that tends to
	leave the profile it came from. Carrying it into another profile grants that
	player every perk and gift credit the first one owned, and stamps them with a
	migration `Version` they never ran, which makes Scribe skip those migrations
	permanently.
]=]

--[=[
	@function Default
	@within Value
	@tag Core
	@return T
	The field's declared default (a deep copy for tables/buffers, the real
	datatype for datatype fields). Read-only schema metadata, so it works on the
	client and server and before data loads. Handy for "reset to default" flows
	and diffing against the current value.
]=]

--[=[
	@function Observe
	@within Value
	@tag Core
	@param callback (value: T) -> ()
	@return () -> ()
	Calls `callback` immediately with the current value, then again on every
	change. Returns a disconnect function. The go-to for driving UI.
]=]

--[=[
	@function Changed
	@within Value
	@tag Core
	@param callback (new: T, old: T) -> ()
	@return () -> ()
	Like `Observe` but fires only on change (no initial call). Returns a disconnect
	function.

	On a **leaf** the callback gets the new and old values, and fires once per write.

	On a **container** it reports state rather than a transition: "something beneath
	this changed, here is the current value". `old` is the same reference as `new`,
	because the fire happens after the write and Scribe does not snapshot a
	container's prior contents. Such a fire is **coalesced**: one per
	[Server.Batch], and on the client one per replication frame, however many
	children moved.

	:::caution The container `key` argument was removed
	A container `Changed` listener used to receive a third `key` argument. It cannot
	any more, because a single fire now covers every child a batch or a frame
	touched. Passing one of them would imply the others did not change. Scribe
	**errors at connect time** on a container listener declaring a third parameter,
	rather than handing it `nil` forever. Use [Value.OnChildChanged] instead.

	A node beneath an untyped `{}` subtree has no schema to judge, so it is
	classified by what is stored there right now. Connect after the container
	exists and the check covers it too.
	:::

	```lua
	-- before
	data.Inventory.Changed(function(new, old, key) refresh(key) end)

	-- after
	data.Inventory.Changed(function(new, old) redrawTotals(new) end)
	data.Inventory.OnChildChanged(function(key, new) refreshSlot(key, new) end)
	```
]=]

--[=[
	@function OnChildChanged
	@within Value
	@tag Containers
	@param callback (key: K, new: V?, old: V?) -> ()
	@return () -> ()
	Fires once for every write to a **direct child** of this container, with that
	child's key and both sides of the change. `new` is `nil` when the child was
	removed, `old` is `nil` when it was just added.

	`old` is a real prior value when the child is a **leaf**. When the child is
	itself a **container**, `old` is the same reference as `new`, because Scribe
	mutates containers in place and never snapshots them. That is the same caveat
	[Value.Changed] carries on a container.

	Unlike [Value.Changed], this is never coalesced: a batch that writes three
	children fires it three times, and a child written twice fires it twice, because
	each is a real transition and collapsing them would lose what happened. Every
	ancestor of a write receives its **own** immediate child, so a write to
	`State.Inner.A` reports `A` to `State.Inner` and `Inner` to `State`.

	All of a container's `OnChildChanged` fires arrive **before** that container's
	coalesced `Changed`, batched or not, so you can accumulate keys and act on them
	once.

	This is the only way to learn that an existing [Scribe.DictOf] key's **value**
	moved. [Value.OnKeyAdded] and [Value.OnKeyRemoved] report a key appearing or
	disappearing, never one changing.
]=]

--[=[
	@function Increment
	@within Value
	@tag Numbers
	@param amount number
	@param meta EconomyMeta?
	@return number
	Number fields only. Adds `amount` and returns the new value. Pass `false`
	instead of `meta` to keep the write server-only.

	Pass an [EconomyMeta](../economy.md) table to auto-emit an economy event
	(`AnalyticsService:LogEconomyEvent`): the currency is this field's name, the
	ending balance is the post-change value, and `TransactionType`, `ItemSku`,
	and per-currency custom `Fields` come from the table. Increment defaults the
	flow to `Source`.

	```lua
	Data[player].Coins.Increment(50, {
	    TransactionType = Enum.AnalyticsEconomyTransactionType.Gameplay,
	    ItemSku = "quest_daily_01",
	    Fields = { Location = "Lobby" },
	})
	```
]=]

--[=[
	@function Decrement
	@within Value
	@tag Numbers
	@param amount number
	@param meta EconomyMeta?
	@return number
	Number fields only. Subtracts `amount` and returns the new value. Like
	[Value.Increment] but the economy flow defaults to `Sink`. See the
	[Economy Analytics](../economy.md) guide.
]=]

--[=[
	@function Min
	@within Value
	@tag Numbers
	@return number?
	Number fields only. The declared minimum (`Scribe.Int(0, { Min = 0 })`), or
	`nil` if unbounded. Read-only metadata from the shared schema, so it works on
	both the client and the server, and even before data has loaded. Handy for
	driving slider ranges or validation off the single source of truth.
]=]

--[=[
	@function Max
	@within Value
	@tag Numbers
	@return number?
	Number fields only. The declared maximum, or `nil` if unbounded. See
	[Value.Min].
]=]

--[=[
	@function Toggle
	@within Value
	@tag Booleans
	@param replicate boolean?
	@return boolean
	Boolean fields only. Flips the value and returns the new one.
]=]

--[=[
	@function Insert
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@param index number?
	@param replicate boolean?
	Array fields only. Inserts `value` at `index`, or appends it. `index` is clamped
	to the array's contiguous length plus one, and must be an integer: a fractional
	or NaN position is refused rather than silently writing a hash-part key. `value`
	may not be `nil`.

	On a [Scribe.ArrayOf] the entry is validated against the element shape, and
	exceeding `MaxItems` is refused before anything is written, so a rejected
	`Insert` never leaves a phantom container behind. For a record element shape an
	undeclared field is an error, and a declared field the caller omitted fills from
	its default ([Scribe.Optional] fields have none and stay absent).

	Calling `Insert` on a [Scribe.DictOf] is an error: write the key instead.
]=]

--[=[
	@function Remove
	@within Value
	@tag Arrays & Dictionaries
	@param indexOrKey (number | string)?
	@param replicate boolean?
	@return T?
	Two operations, chosen by the argument's type. Given a **number** (or nothing),
	removes and returns the array element at that index, or the last one, or `nil`
	if the array is empty. Given a **string**, deletes that dictionary key and
	returns its former value.

	The returned value is unpacked, so a datatype element comes back as the real
	datatype rather than its stored buffer.
]=]

--[=[
	@function RemoveValue
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@param replicate boolean?
	@return (T?, number?)
	Array fields only. Removes the first element matching `value`, returning it
	unpacked along with its former index. Matching follows [Value.Find]. Errors on a
	[Scribe.DictOf]: use `Remove(key)`.
]=]

--[=[
	@function Find
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@return number?
	Array fields only. The index of the first matching element, or `nil`.

	A [Scribe.ArrayOf] element is compared **structurally, by value**, since entries
	reach you unpacked and copied and an identity search would never match what
	`Get()` just handed you. An untyped `{}` container keeps `table.find`'s identity
	comparison. Errors on a [Scribe.DictOf], which is keyed: read the key directly.]=]

--[=[
	@function Has
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@return boolean
	Array fields only. Whether `value` is present. Matching follows [Value.Find],
	including its error on a [Scribe.DictOf].
]=]

--[=[
	@function OnInsert
	@within Value
	@tag Arrays & Dictionaries
	@param callback (value: T, index: number) -> ()
	@return () -> ()
	Array fields only. Fires when an element is inserted, with the value and the
	index it landed at. Returns a disconnect function.
]=]

--[=[
	@function OnRemove
	@within Value
	@tag Arrays & Dictionaries
	@param callback (value: T, index: number) -> ()
	@return () -> ()
	Array fields only. Fires when an element is removed, with the removed value
	and its former index. Returns a disconnect function.
]=]

--[=[
	@function OnKeyAdded
	@within Value
	@tag Arrays & Dictionaries
	@param callback (key: K, value: T) -> ()
	@return () -> ()
	Fires when a key is added, with the key and its new value. Returns a disconnect
	function. Mainly for dictionaries, but an array fires it too, with the numeric
	index as the key, when an index is written directly with `Set` rather than
	`Insert`.
]=]

--[=[
	@function OnKeyRemoved
	@within Value
	@tag Arrays & Dictionaries
	@param callback (key: K, value: T) -> ()
	@return () -> ()
	Fires when a key is removed, with the key and its former value. Returns a
	disconnect function. As with `OnKeyAdded`, an array fires it for a direct
	`Set(nil)` on an index, with the numeric index as the key.
]=]

--[=[
	@function Count
	@within Value
	@tag Arrays & Dictionaries
	@return number
	Array/dictionary fields. The number of elements/keys.
]=]

--[=[
	@function Clear
	@within Value
	@tag Arrays & Dictionaries
	@param replicate boolean?
	Array/dictionary fields. Removes all entries.
]=]

--[=[
	@function SetTimed
	@within Value
	@tag Timed
	@param value T
	@param seconds number
	@param replicate boolean?
	`Scribe.Timed` fields only. Sets `value` for `seconds`, after which it
	auto-clears back to the declared default (firing `Changed`). Durations floor
	to 1 second (a once-per-second sweep checks expiries) and cap at a finite
	~126 years, so `SetTimed(value, math.huge)` means "effectively permanent".
	Note that a later plain `Set` does NOT cancel the running timer: the field
	still resets to its default when the timer lapses. To make a timed value
	permanent, re-issue `SetTimed(value, math.huge)`.
]=]

--[=[
	@function ExtendTimed
	@within Value
	@tag Timed
	@param seconds number
	`Scribe.Timed` fields only. Adds time to a running timer.

	With no timer running it **arms a fresh one** from now, so a field that was
	never `SetTimed` starts counting down and will revert to its declared default.
	Check `Active()` first if that is not what you want. The value itself is never
	written, so unlike `SetTimed` there is nothing here to replicate.
]=]

--[=[
	@function Active
	@within Value
	@tag Timed
	@return (boolean, number?)
	`Scribe.Timed` fields only. Whether the timer is active, and the seconds
	remaining.
]=]

type Accessor = any

local function accessorSchema(accessor: Accessor): SchemaNode?
	return rawget(accessor, "_schema") :: any
end

local function accessorTree(accessor: Accessor): Tree
	return rawget(accessor, "_tree") :: any
end

local function accessorPath(accessor: Accessor): { string | number }
	return rawget(accessor, "_path") :: any
end

local function accessorKey(accessor: Accessor): string
	return rawget(accessor, "_key") :: any
end

local function parseIncrementArgs(tagsOrReplicate: any): ({ [string]: any }?, boolean?)
	if type(tagsOrReplicate) == "boolean" then
		return nil, tagsOrReplicate
	elseif type(tagsOrReplicate) == "table" then
		return tagsOrReplicate, nil
	end
	return nil, nil
end

-- Declared datatype fields store a packed buffer; the accessor converts at
-- the boundary so callers only ever see the real datatype.
local function unpackIfDatatype(schema: SchemaNode?, value: any): any
	if schema and schema.ValueType == "datatype" and type(value) == "buffer" then
		return Datatypes.Unpack(schema.Datatype :: string, value)
	end
	return value
end

-- Read-boundary unpack that also handles CONTAINERS: a container whose schema has
-- packed descendants (compile-time HasPacked flag) is returned as a fresh table with
-- every packed buffer converted back to its datatype and every stored mantissa pair
-- back to a Big, so a container-level read never leaks a stored shape. Unpacked
-- subtrees are shared by reference (same as a plain container read today) and
-- containers with nothing packed below return unchanged: no walk, no allocation for
-- the overwhelming common case.
local function unpackRead(schema: SchemaNode?, value: any): any
	-- A big value is STORED as { mantissa, exponent } and READ as the object with
	-- arithmetic on it, the same split datatype fields use.
	if schema and schema.ValueType == "big" then
		return if value == nil then nil else Big.from(value)
	end
	if type(value) == "table" then
		if Template.IsPacked(schema) then
			local out: { [any]: any } = {}
			for k, v in value do
				out[k] = unpackRead(Template.ChildSchema(schema, k), v)
			end
			return out
		end
		return value
	end
	return unpackIfDatatype(schema, value)
end

-- Schema of a container's entries: the compiled element for a Scribe.ArrayOf /
-- Scribe.DictOf, otherwise the generic dynamic pseudo-node (or nil for a leaf).
local function elementSchemaOf(schema: SchemaNode?): SchemaNode?
	return if schema then Template.ChildSchema(schema, 1) else nil
end

-- Whether `schema` sits anywhere inside an ArrayOf/DictOf element subtree. Fields
-- there may legitimately not exist yet (the entry materializes on first write),
-- unlike static template fields, which Reconcile guarantees present.
local function inElementSubtree(schema: SchemaNode?): boolean
	local cursor = schema
	while cursor do
		if cursor.IsElement then
			return true
		end
		cursor = cursor.Parent
	end
	return false
end

-- Canonical packed form of a datatype, for comparison only. Packing is NOT
-- byte-canonical for every codec (an arbitrary CFrame rotation goes through a lossy
-- quaternion path), so a value handed to a caller by Get() would not re-pack to the
-- bytes it came from. Routing BOTH sides through the same unpack+repack lands them
-- on one representative, which is what makes `Has(Get()[i])` work.
local function canonicalDatatype(name: string, value: any): buffer?
	local packed: buffer
	if type(value) == "buffer" then
		packed = value
	elseif typeof(value) == name then
		local ok, result = pcall(Datatypes.Pack, name, value)
		if not ok then
			return nil
		end
		packed = result
	else
		return nil
	end
	local unpackOk, unpacked = pcall(Datatypes.Unpack, name, packed)
	if not unpackOk then
		return packed
	end
	local repackOk, repacked = pcall(Datatypes.Pack, name, unpacked)
	return if repackOk then repacked else packed
end

-- Structural equality between a STORED entry and a caller-supplied needle, resolved
-- through the element schema so packed datatype and big leaves compare by value.
local function entryEquals(schema: SchemaNode?, stored: any, needle: any): boolean
	if schema and schema.ValueType == "big" then
		-- The stored side is a { mantissa, exponent } pair and the needle is whatever
		-- a read handed back, so both go through Big.from before comparing. Without
		-- this the pair-vs-object table walk never matches and Has/Find/RemoveValue
		-- silently no-op against the value Get() just returned.
		local a, b = Big.from(stored), Big.from(needle)
		return a ~= nil and b ~= nil and Big.compare(a, b) == 0
	end
	if schema and schema.ValueType == "datatype" then
		local name = schema.Datatype :: string
		local a = canonicalDatatype(name, stored)
		local b = canonicalDatatype(name, needle)
		return a ~= nil and b ~= nil and Util.bufferEquals(a, b)
	end
	if type(stored) == "buffer" or type(needle) == "buffer" then
		return type(stored) == "buffer" and type(needle) == "buffer" and Util.bufferEquals(stored, needle)
	end
	if type(stored) ~= "table" or type(needle) ~= "table" then
		return stored == needle
	end
	local seen = 0
	for k, v in stored do
		if not entryEquals(if schema then Template.ChildSchema(schema, k) else nil, v, (needle :: any)[k]) then
			return false
		end
		seen += 1
	end
	for _ in needle do
		seen -= 1
	end
	return seen == 0
end

-- Element-aware `table.find`. A declared element is compared STRUCTURALLY: entries
-- reach callers unpacked and copied, so identity never holds and Find/Has/
-- RemoveValue would be permanently dead against the value Get() just returned.
-- Untyped containers keep identity semantics, which existing code relies on.
local function findElement(schema: SchemaNode?, arr: { any }, item: any): number?
	if schema and schema.Container == "Dict" then
		error(
			"Scribe: Find/Has/RemoveValue search array entries; a Scribe.DictOf is keyed, "
				.. "so read the key directly (or Remove(key))",
			0
		)
	end
	local element = elementSchemaOf(schema)
	if element == nil or not (element.IsElement or element.ValueType == "datatype") then
		return table.find(arr, item)
	end
	for i, v in arr do
		if entryEquals(element, v, item) then
			return i
		end
	end
	return nil
end

-- Clone counterpart: a full deep copy with packed descendants unpacked, so Clone()
-- of a datatype- or big-bearing container yields an independent value in its read
-- shape rather than the stored one.
local function cloneUnpack(schema: SchemaNode?, value: any): any
	if schema and schema.ValueType == "big" then
		-- A Big object is immutable and built fresh here, so it needs no extra copy.
		return if value == nil then nil else Big.from(value)
	end
	if type(value) ~= "table" then
		local unpacked = unpackIfDatatype(schema, value)
		-- A raw (non-datatype) buffer leaf must be COPIED, not aliased: buffers are
		-- mutable and Clone()/the Shared-mirror clone promise an independent value.
		-- A datatype leaf already became an immutable Roblox datatype above, so this
		-- only ever catches a ValueType=="buffer" field (matching Util.deepClone).
		if type(unpacked) == "buffer" then
			return Util.cloneBuffer(unpacked)
		end
		return unpacked
	end
	local out: { [any]: any } = {}
	for k, v in value do
		out[k] = cloneUnpack(if schema then Template.ChildSchema(schema, k) else nil, v)
	end
	return out
end

-- The whole-data value the ROOT accessor reads. Reading the store directly is
-- wrong in both directions: the store carries Scribe's library-owned roots, which
-- the declared type has never had, and it is only ONE of the two stores, so the
-- Session roots the declared type DOES have go missing on the server (readValue
-- short-circuits the empty path to Stores.Persist, while every deeper read routes
-- through storeFor). Building the shell from the DECLARED roots instead means the
-- snapshot carries exactly the keys the template promises, and nothing else.
--
-- Scribe's own internals stay reachable by indexing the accessor
-- (`data._Scribe.Perks`), which is how the server layers read them; this only
-- changes what a whole-data read hands back.
local function rootShell(tree: Tree, clone: boolean): { [string]: any }
	local out: { [string]: any } = {}
	local children = tree.Compiled.Root.Children
	if children == nil then
		return out
	end
	for key, childSchema in children do
		if key == Template.RESERVED_ROOT or key == Template.SESSION_ROOT then
			continue
		end
		local value = storeFor(tree, key)[key]
		if value == nil then
			continue
		end
		if not clone then
			out[key] = unpackRead(childSchema, value)
		elseif Template.IsPacked(childSchema) then
			out[key] = cloneUnpack(childSchema, value)
		else
			out[key] = Util.deepClone(value)
		end
	end
	return out
end

-- Every root read hands back the same frozen shell shape, so Get, Observe, and
-- Changed cannot disagree about what "all of the data" means.
local function frozenRootShell(tree: Tree): { [string]: any }
	return table.freeze(rootShell(tree, false))
end

-- Whether this node holds children, and so receives coalesced ancestor fires
-- rather than leaf transitions. The root always does. A schema-less (dynamic) node
-- is judged by what is actually stored there right now, which is the best answer
-- available at connect time.
local function isContainerNode(tree: Tree, schema: SchemaNode?, path: { string | number }): boolean
	if #path == 0 then
		return true
	end
	-- Kind == "any" is the pseudo-node Template synthesizes for an undeclared key
	-- under an untyped `{}` subtree. It is never nil, so testing `schema ~= nil`
	-- alone classified every such node as a leaf and made the runtime check below
	-- dead for the exact case it was written for.
	if schema ~= nil and schema.Kind ~= "any" then
		return schema.Kind == "table" or schema.Children ~= nil
	end
	return type(readValue(tree, path)) == "table"
end

local METHOD_FACTORIES: { [string]: (Accessor) -> any } = {}

METHOD_FACTORIES.Get = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local path = accessorPath(accessor)
		if #path == 0 then
			-- Frozen so `Get().Coins = 1` raises at the offending line. Unfrozen it
			-- either edited authoritative state with no validation and no
			-- replication, or was silently discarded, depending only on whether the
			-- template happened to declare a datatype field somewhere.
			return frozenRootShell(tree)
		end
		return unpackRead(accessorSchema(accessor), readValue(tree, path))
	end
end

METHOD_FACTORIES.Set = function(accessor)
	return function(value: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local stored = applySet(tree, accessorPath(accessor), schema, value, { Replicate = replicate })
		return unpackRead(schema, stored)
	end
end

METHOD_FACTORIES.Update = function(accessor)
	return function(fn: (any) -> any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local current = unpackRead(schema, readValue(tree, accessorPath(accessor)))
		local stored = applySet(tree, accessorPath(accessor), schema, fn(current), { Replicate = replicate })
		return unpackRead(schema, stored)
	end
end

METHOD_FACTORIES.Clone = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local path = accessorPath(accessor)
		if #path == 0 then
			-- Deliberately NOT frozen: a copy you can edit is the whole point of
			-- Clone, and it is already detached from the store.
			return rootShell(tree, true)
		end
		local schema = accessorSchema(accessor)
		if Template.IsPacked(schema) then
			-- Leaf datatype or big, or a container holding either: deep-clone and
			-- unpack together so the copy is independent AND in its read shape.
			return cloneUnpack(schema, readValue(tree, path))
		end
		return Util.deepClone(readValue(tree, path))
	end
end

-- Flags helpers. Each one reads the current set, edits it, and writes the whole
-- field back, so a flag change is a single validated, replicated write that fires
-- one Changed rather than N.
local function flagsSchema(accessor: Accessor, method: string): SchemaNode
	local schema = accessorSchema(accessor)
	if not schema or schema.ValueType ~= "flags" then
		error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is not a Scribe.Flags field ({method})`, 3)
	end
	return schema
end

local function flagsSet(
	tree: Tree,
	accessor: Accessor,
	schema: SchemaNode,
	name: string,
	on: boolean,
	replicate: boolean?
)
	local index = schema.MemberIndex :: { [string]: number }
	if index[name] == nil then
		error(`Scribe: "{tostring(name)}" is not a member of "{Util.pathString(accessorPath(accessor))}"`, 3)
	end
	local current = readValue(tree, accessorPath(accessor))
	local enabled: { [string]: boolean } = {}
	if type(current) == "table" then
		for _, member in current :: { string } do
			enabled[member] = true
		end
	end
	-- `or false` matters: an unset flag reads nil, and nil == false is false, so a
	-- Disable on an already-off flag would otherwise write and fire Changed.
	if (enabled[name] or false) == on then
		return -- no transition, so no write, no Changed, no replication op
	end
	enabled[name] = on or nil
	local out = {}
	for _, member in schema.Members :: { string } do
		if enabled[member] then
			table.insert(out, member)
		end
	end
	applySet(tree, accessorPath(accessor), schema, out, { Replicate = replicate })
end

METHOD_FACTORIES.Enable = function(accessor)
	return function(name: string, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		flagsSet(tree, accessor, flagsSchema(accessor, "Enable"), name, true, replicate)
	end
end

METHOD_FACTORIES.Disable = function(accessor)
	return function(name: string, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		flagsSet(tree, accessor, flagsSchema(accessor, "Disable"), name, false, replicate)
	end
end

-- Scribe.SetOf membership. Both go through the whole-value write path, so the
-- dedupe-and-sort normalization in validateWrite is what actually maintains the
-- invariant; these just decide whether a write is needed at all.
local function setSchema(accessor: Accessor, method: string): SchemaNode
	local schema = accessorSchema(accessor)
	if not schema or not schema.Unique then
		error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is not a Scribe.SetOf field ({method})`, 3)
	end
	return schema
end

METHOD_FACTORIES.Add = function(accessor)
	return function(item: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = setSchema(accessor, "Add")
		local path = accessorPath(accessor)
		if item == nil then
			error(`Scribe: cannot Add nil to "{Util.pathString(path)}"`, 3)
		end
		local current = readValue(tree, path)
		local arr = if type(current) == "table" then current :: { any } else {}
		if findElement(schema, arr, item) ~= nil then
			return false -- already a member: no write, no op, no Changed
		end
		local next_ = table.clone(arr)
		table.insert(next_, item)
		applySet(tree, path, schema, next_, { Replicate = replicate })
		return true
	end
end

-- Scribe.Big arithmetic. Each reads the current value, applies the operation, and
-- writes the whole field, so bounds, replication, and the economy event all run on
-- the normal write path rather than a parallel one.
local function bigSchema(accessor: Accessor, method: string): SchemaNode
	local schema = accessorSchema(accessor)
	if not schema or schema.ValueType ~= "big" then
		error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is not a Scribe.Big field ({method})`, 3)
	end
	return schema
end

local function bigOperand(accessor: Accessor, method: string, value: any): any
	local parsed = Big.from(value)
	if parsed == nil then
		error(`Scribe: {method} on "{Util.pathString(accessorPath(accessor))}" needs a number or numeric string`, 3)
	end
	return parsed
end

local function bigApply(accessor: Accessor, method: string, value: any, replicate: boolean?, op: (any, any) -> any): any
	local tree = accessorTree(accessor)
	assertAlive(tree)
	local schema = bigSchema(accessor, method)
	local path = accessorPath(accessor)
	local operand = bigOperand(accessor, method, value)
	-- A Nullable leaf has no default and is legitimately absent, so there is nothing
	-- to arithmetic against. Materializing it from 0 contradicted the contract every
	-- other Scribe.Optional leaf keeps, where Increment on an absent value errors.
	local current = Big.from(readValue(tree, path)) or Big.from(schema.Default)
	if current == nil then
		if schema.Nullable then
			validationError(path, `{method} on an absent Scribe.Optional value`)
		end
		current = Big.from(0)
	end
	local result = op(current, operand)
	if result == nil then
		error(`Scribe: {method} on "{Util.pathString(path)}" divided by zero`, 3)
	end
	return unpackRead(schema, applySet(tree, path, schema, result, { Replicate = replicate }))
end

METHOD_FACTORIES.Multiply = function(accessor)
	return function(factor: any, replicate: boolean?)
		return bigApply(accessor, "Multiply", factor, replicate, Big.mul)
	end
end

METHOD_FACTORIES.Divide = function(accessor)
	return function(factor: any, replicate: boolean?)
		return bigApply(accessor, "Divide", factor, replicate, Big.div)
	end
end

local function incrementImpl(accessor: Accessor, delta: any, tagsOrReplicate: any, defaultFlow: string): any
	local tree = accessorTree(accessor)
	assertAlive(tree)
	local path = accessorPath(accessor)
	local bigNode = accessorSchema(accessor)
	if not (bigNode and bigNode.ValueType == "big") and defaultFlow == "Sink" and type(delta) == "number" then
		delta = -delta
	end
	if bigNode and bigNode.ValueType == "big" then
		-- Same economy plumbing as a plain number, just with arithmetic that does not
		-- lose the value at 2^53.
		local method = if defaultFlow == "Source" then "Increment" else "Decrement"
		local signed = bigOperand(accessor, method, delta)
		if defaultFlow == "Sink" then
			signed = Big.negate(signed)
		end
		local tags, replicate = parseIncrementArgs(tagsOrReplicate)
		local before = Big.from(readValue(tree, path)) or Big.from(bigNode.Default)
		if before == nil then
			if bigNode.Nullable then
				validationError(path, `{method} on an absent Scribe.Optional value`)
			end
			before = Big.from(0)
		end
		local result = bigApply(accessor, method, signed, replicate, Big.add)
		if tags and tree.Params.OnEconomy then
			local after = Big.from(result) or Big.from(0)
			-- Report the EFFECTIVE change, as the plain path does, so a Min/Max clamp
			-- does not over-report. The economy contract is (delta, newValue) as
			-- numbers, and Roblox's LogEconomyEvent takes a double, so the conversion
			-- has to happen at this boundary; Big.toNumber saturates past the double
			-- range, which is lossy but reaches the log, unlike a table that would
			-- throw inside Analytics' pcall and be swallowed.
			local effective = Big.sub(after, before)
			if Big.compare(effective, Big.from(0) :: any) ~= 0 then
				local applied = table.clone(tags)
				if applied.Flow == nil then
					applied.Flow = defaultFlow
				end
				local effectiveDelta = Big.toNumber(effective)
				local newValue = Big.toNumber(after)
				local txn = tree._txn
				if txn then
					table.insert(
						(txn :: any).Economy,
						{ Path = path, Delta = effectiveDelta, New = newValue, Tags = applied }
					)
				else
					tree.Params.OnEconomy(path, effectiveDelta, newValue, applied)
				end
			end
		end
		return result
	end
	if type(delta) ~= "number" or delta ~= delta then
		validationError(path, "Increment delta must be a number")
	end
	local schema = accessorSchema(accessor)
	local current = readValue(tree, path)
	if current == nil then
		-- A declared element leaf that has not been written yet: start from its
		-- compiled default rather than erroring, so `Resources.Wood.Increment(5)`
		-- on a fresh key yields 5. That is the whole point of DictOf(Scribe.Int(0)).
		-- Nullable (Scribe.Optional) leaves have no default and keep erroring.
		if schema and type(schema.Default) == "number" and inElementSubtree(schema) then
			current = schema.Default
		end
	end
	if type(current) ~= "number" then
		validationError(path, `Increment on non-number value ({typeof(current)})`)
	end
	local tags, replicate = parseIncrementArgs(tagsOrReplicate)
	local newValue = applySet(tree, path, schema, current + delta, { Replicate = replicate }) :: number
	-- Report the EFFECTIVE change, not the requested delta: a bounded field may
	-- clamp (or reject) so the balance moves less than asked, or not at all.
	-- Logging the raw delta over-reports economy amounts, and firing on a no-op
	-- logs a phantom transaction the balance never made.
	local effectiveDelta = newValue - current
	if tags and tree.Params.OnEconomy and effectiveDelta ~= 0 then
		local applied = table.clone(tags)
		if applied.Flow == nil then
			applied.Flow = defaultFlow
		end
		local txn = tree._txn
		if txn then
			-- Deferred exactly like replication ops: fired on commit, dropped on
			-- rollback, so a rolled-back Increment never logs a phantom transaction.
			table.insert((txn :: any).Economy, { Path = path, Delta = effectiveDelta, New = newValue, Tags = applied })
		else
			tree.Params.OnEconomy(path, effectiveDelta, newValue, applied)
		end
	end
	return newValue
end

METHOD_FACTORIES.Increment = function(accessor)
	return function(delta: number, tagsOrReplicate: any?)
		return incrementImpl(accessor, delta, tagsOrReplicate, "Source")
	end
end

METHOD_FACTORIES.Decrement = function(accessor)
	return function(delta: number, tagsOrReplicate: any?)
		local tree = accessorTree(accessor)
		if tree.Params.DevMode and type(delta) == "number" and delta < 0 then
			local warnFn = tree.Params.LogWarn
			if warnFn then
				warnFn(
					`Decrement called with a negative delta at "{Util.pathString(accessorPath(accessor))}" — likely a sign error`
				)
			end
		end
		return incrementImpl(accessor, delta, tagsOrReplicate, "Sink")
	end
end

-- Min/Max read the declarator's bounds off the (static) schema, so they work on
-- the server and client alike, and even before data has loaded.
METHOD_FACTORIES.Min = function(accessor)
	return function(): number?
		local schema = accessorSchema(accessor)
		return if schema then schema.Min else nil
	end
end

METHOD_FACTORIES.Max = function(accessor)
	return function(): number?
		local schema = accessorSchema(accessor)
		return if schema then schema.Max else nil
	end
end

-- The declarator's default, straight off the (static) schema: a fresh datatype for
-- packed datatype fields, a Big for big ones, a deep copy for tables/buffers, the
-- value itself for scalars. Works on server and client and before data has loaded.
METHOD_FACTORIES.Default = function(accessor)
	return function(): any
		local schema = accessorSchema(accessor)
		if schema == nil then
			return nil
		end
		if Template.IsPacked(schema) then
			-- The stored Default holds the PACKED form (a leaf datatype default is
			-- packed at compile time, a big one is a mantissa pair), so deep-clone AND
			-- unpack, matching Clone(). A plain deepClone would hand back the stored
			-- shape for anything packed or holding something packed.
			return cloneUnpack(schema, schema.Default)
		end
		return Util.deepClone(schema.Default)
	end
end

METHOD_FACTORIES.Toggle = function(accessor)
	return function(nameOrReplicate: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local path = accessorPath(accessor)
		local schema = accessorSchema(accessor)
		if schema and schema.ValueType == "flags" then
			-- On a Scribe.Flags field Toggle names the flag to flip, since the field
			-- holds a set rather than one boolean.
			if type(nameOrReplicate) ~= "string" then
				error(`Scribe: Toggle on a Scribe.Flags field takes a member name`, 3)
			end
			local index = schema.MemberIndex :: { [string]: number }
			if index[nameOrReplicate] == nil then
				error(`Scribe: "{nameOrReplicate}" is not a member of "{Util.pathString(path)}"`, 3)
			end
			local current = readValue(tree, path)
			local on = false
			if type(current) == "table" then
				for _, member in current :: { string } do
					if member == nameOrReplicate then
						on = true
						break
					end
				end
			end
			flagsSet(tree, accessor, schema, nameOrReplicate, not on, replicate)
			return not on
		end
		local replicateFlag = nameOrReplicate :: boolean?
		local current = readValue(tree, path)
		if current == nil and schema and type(schema.Default) == "boolean" and inElementSubtree(schema) then
			-- Same fresh-element fallback as Increment: the entry materializes on
			-- first write, so Toggle starts from the declared default.
			current = schema.Default
		end
		if type(current) ~= "boolean" then
			validationError(path, `Toggle on non-boolean value ({typeof(current)})`)
		end
		return applySet(tree, path, schema, not current, { Replicate = replicateFlag })
	end
end

METHOD_FACTORIES.Changed = function(accessor)
	return function(fn: (any, any) -> ())
		local tree = accessorTree(accessor)
		local schema = accessorSchema(accessor)
		local path = accessorPath(accessor)

		-- A container Changed used to receive a third `key` argument. It cannot any
		-- more: one fire now covers every child a batch or a replication frame
		-- touched, so no single key describes it. Refuse the old shape at connect
		-- time rather than handing it a nil forever, which would make
		-- `if key == "Coins"` quietly stop matching in a shipped game. Arity is read
		-- once per connect, never per fire.
		if isContainerNode(tree, schema, path) then
			local params, isVararg = debug.info(fn, "a")
			if not isVararg and params > 2 then
				error(
					`Scribe: a container Changed listener takes (new, old). "{Util.pathString(path)}" declares `
						.. `{params} parameters. The third key argument was removed because one fire can now cover `
						.. `several children. Use OnChildChanged(key, value) to learn which child moved.`,
					3
				)
			end
		end

		if #path == 0 then
			-- Match what Get hands back. The root has no Set or Update, so its only
			-- fires are ancestor fires, where old and new are one reference; a single
			-- shell serves both and a listener's `if new == old then return` holds.
			local inner = fn
			fn = function()
				local shell = frozenRootShell(tree)
				inner(shell, shell)
			end
			return connect(tree, path, "Changed", fn)
		end
		if Template.IsPacked(schema) then
			local inner = fn
			fn = function(newValue, oldValue)
				local newUnpacked = unpackRead(schema, newValue)
				-- An ancestor container fire passes the SAME reference for new and old;
				-- reuse the unpacked value to skip a second walk and to preserve
				-- reference-equality for a listener's `if new == old then return` guard.
				local oldUnpacked = if oldValue == newValue then newUnpacked else unpackRead(schema, oldValue)
				inner(newUnpacked, oldUnpacked)
			end
		end
		return connect(tree, path, "Changed", fn)
	end
end

METHOD_FACTORIES.Observe = function(accessor)
	return function(fn: (any) -> ())
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local path = accessorPath(accessor)
		local isRoot = #path == 0
		local disconnect = connect(tree, path, "Changed", function(newValue)
			fn(if isRoot then frozenRootShell(tree) else unpackRead(schema, newValue))
		end)
		local ok, err = xpcall(function()
			fn(if isRoot then frozenRootShell(tree) else unpackRead(schema, readValue(tree, path)))
		end, function(e)
			return debug.traceback(tostring(e), 2)
		end)
		if not ok then
			tree.Params.LogError(`listener error at "{accessorKey(accessor)}" (Observe): {err}`)
		end
		return disconnect
	end
end

METHOD_FACTORIES.Insert = function(accessor)
	return function(item: any, pos: number?, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		applyInsert(tree, accessorPath(accessor), accessorSchema(accessor), item, pos, { Replicate = replicate })
	end
end

METHOD_FACTORIES.Remove = function(accessor)
	return function(posOrKey: any, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local setNode = accessorSchema(accessor)
		if setNode and setNode.Unique then
			-- A set has no indices, so Remove names the member to drop.
			local path = accessorPath(accessor)
			local current = readValue(tree, path)
			local arr = if type(current) == "table" then current :: { any } else {}
			local at = findElement(setNode, arr, posOrKey)
			if at == nil then
				return false -- not a member: nothing to do
			end
			local next_ = table.clone(arr)
			table.remove(next_, at)
			applySet(tree, path, setNode, next_, { Replicate = replicate })
			return true
		end
		-- Branch on the SCHEMA, not on the Lua type of the argument: a
		-- Scribe.MapOf("integer") takes number keys, and reading those as array
		-- indices would silently remove the wrong entry. The type fallback keeps
		-- untyped and dynamic nodes behaving as before.
		if (setNode and setNode.Container == "Dict") or type(posOrKey) == "string" then
			-- Dictionary removal: sugar for Set(nil) with a useful return.
			local path = table.clone(accessorPath(accessor))
			table.insert(path, posOrKey)
			local schema = accessorSchema(accessor)
			local childSchema = if schema then Template.ChildSchema(schema, posOrKey) else nil
			local container, key = resolveContainer(tree, path, false)
			local old = if container then container[key] else nil
			if old ~= nil then
				applySet(tree, path, childSchema, nil, { Replicate = replicate })
			end
			-- Convert at the datatype boundary like every other read accessor: a
			-- removed static datatype leaf is stored packed, so return the real value.
			return unpackRead(childSchema, old)
		end
		-- Convert at the datatype boundary like the dictionary branch above: an
		-- element of a Scribe.ArrayOf(Scribe.CFrame(...)) is stored packed, so
		-- returning it raw would hand the caller a buffer.
		local schema = accessorSchema(accessor)
		local removed =
			applyArrayRemove(tree, accessorPath(accessor), schema, posOrKey :: number?, { Replicate = replicate })
		return unpackRead(elementSchemaOf(schema), removed)
	end
end

METHOD_FACTORIES.RemoveValue = function(accessor)
	return function(item: any, replicate: boolean?): (any, number?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local arr = readValue(tree, accessorPath(accessor))
		if type(arr) ~= "table" then
			return nil, nil
		end
		local index = findElement(schema, arr, item)
		if index == nil then
			return nil, nil
		end
		local removed = applyArrayRemove(tree, accessorPath(accessor), schema, index, { Replicate = replicate })
		return unpackRead(elementSchemaOf(schema), removed), index
	end
end

METHOD_FACTORIES.Find = function(accessor)
	return function(item: any): number?
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local arr = readValue(tree, accessorPath(accessor))
		if type(arr) ~= "table" then
			return nil
		end
		return findElement(accessorSchema(accessor), arr, item)
	end
end

METHOD_FACTORIES.Has = function(accessor)
	return function(item: any)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local arr = readValue(tree, accessorPath(accessor))
		return type(arr) == "table" and findElement(accessorSchema(accessor), arr, item) ~= nil
	end
end

METHOD_FACTORIES.Clear = function(accessor)
	return function(replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		applyClear(tree, accessorPath(accessor), accessorSchema(accessor), { Replicate = replicate })
	end
end

METHOD_FACTORIES.Count = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local value = readValue(tree, accessorPath(accessor))
		if type(value) ~= "table" then
			return 0
		end
		return Util.count(value)
	end
end

-- Value handed to an entry-level listener. Packed values are converted back, and a
-- table is copied: the fired value IS the stored one, so a listener mutating it
-- would edit authoritative state with no validation and no replication.
local function entryValueForListener(schema: SchemaNode?, value: any): any
	if Template.IsPacked(schema) then
		return cloneUnpack(schema, value)
	end
	-- Only a DECLARED element is copied. An untyped container must keep handing out
	-- the stored reference: Has/Find/RemoveValue fall back to table.find, which
	-- compares by identity, so a copy would make a listener's own entry unfindable.
	if schema and schema.IsElement and type(value) == "table" then
		return Util.deepClone(value)
	end
	return value
end

-- The four listener kinds that receive a container ENTRY rather than the container
-- itself. Unlike Changed/Observe they had no datatype conversion, which an
-- ArrayOf/DictOf element makes the primary case rather than an unreachable one.
for _, event in { "OnInsert", "OnRemove", "OnKeyAdded", "OnKeyRemoved", "OnChildChanged" } do
	METHOD_FACTORIES[event] = function(accessor)
		return function(fn: (...any) -> ())
			local tree = accessorTree(accessor)
			local schema = accessorSchema(accessor)
			local inner = fn
			local wrapped: (...any) -> ()
			if event == "OnInsert" or event == "OnRemove" then
				local element = elementSchemaOf(schema)
				wrapped = function(value: any, index: any)
					inner(entryValueForListener(element, value), index)
				end
			elseif event == "OnChildChanged" then
				-- Carries a transition, so BOTH sides need unpacking. OnKeyAdded and
				-- OnKeyRemoved below take a single value because an appearance has no
				-- prior and a disappearance has no successor.
				wrapped = function(key: any, newValue: any, oldValue: any)
					local childSchema = if schema then Template.ChildSchema(schema, key) else nil
					inner(
						key,
						entryValueForListener(childSchema, newValue),
						entryValueForListener(childSchema, oldValue)
					)
				end
			else
				wrapped = function(key: any, value: any)
					local childSchema = if schema then Template.ChildSchema(schema, key) else nil
					inner(key, entryValueForListener(childSchema, value))
				end
			end
			return connect(tree, accessorPath(accessor), event, wrapped)
		end
	end
end

local function timedHooks(accessor: Accessor): TimedHooks
	local tree = accessorTree(accessor)
	local schema = accessorSchema(accessor)
	if not schema or not schema.Timed then
		error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is not a Scribe.Timed field`, 3)
	end
	local hooks = tree.Params.TimedHooks
	if not hooks then
		error("Scribe: timed fields are managed on the server", 3)
	end
	return hooks
end

METHOD_FACTORIES.SetTimed = function(accessor)
	return function(value: any, seconds: number, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		timedHooks(accessor).SetTimed(accessor, value, seconds, replicate)
	end
end

METHOD_FACTORIES.ExtendTimed = function(accessor)
	return function(seconds: number, replicate: boolean?)
		local tree = accessorTree(accessor)
		assertAlive(tree)
		timedHooks(accessor).ExtendTimed(accessor, seconds, replicate)
	end
end

METHOD_FACTORIES.Active = function(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		return timedHooks(accessor).Active(accessor)
	end
end

-- Accessor metatable -----------------------------------------------------------------

local function accessorIndex(accessor: Accessor, key: any): any
	local factory = METHOD_FACTORIES[key]
	if factory then
		local method = factory(accessor)
		rawset(accessor, key, method)
		return method
	end

	local tree = accessorTree(accessor)
	assertAlive(tree)
	if type(key) ~= "string" and type(key) ~= "number" then
		error(`Scribe: invalid child key of type {typeof(key)}`, 2)
	end
	-- The pathKey separator (char 31) would let a crafted dynamic key alias a
	-- distinct path — corrupting coalescing, listeners, and txn rollback.
	if type(key) == "string" and string.find(key, "\31", 1, true) then
		error("Scribe: dictionary keys may not contain control character \\31", 2)
	end
	-- Invalid UTF-8 bytes in a dynamic key would fail the DataStore save for the
	-- entire profile (JSON object keys must be valid UTF-8). Reject at the accessor
	-- boundary so the error points at the offending index, not a later opaque save.
	if type(key) == "string" and not Util.isUtf8(key) then
		error("Scribe: dictionary keys must be valid UTF-8", 2)
	end
	-- Fractional / non-finite numeric keys do not survive the DataStore JSON round
	-- trip (coerced to strings, or breaking JSON outright), which would silently
	-- diverge the stored key from its pathKey/listeners. Reject at the accessor
	-- boundary, mirroring validateWrite's guard for whole-table writes.
	if type(key) == "number" and (key ~= key or key == math.huge or key == -math.huge or key % 1 ~= 0) then
		error(`Scribe: numeric dictionary keys must be finite integers, got {tostring(key)}`, 2)
	end

	local children = rawget(accessor, "_children") :: { [any]: any }
	local child = children[key]
	if child == nil then
		local schema = accessorSchema(accessor)
		-- Kind alone is not enough: Scribe.Big and Scribe.Flags compile as Kind
		-- "table" because their stored form IS a table, so indexing them was allowed
		-- and `Tutorial[1].Set(...)` overwrote an enabled flag in place. They are
		-- leaves as far as a caller is concerned.
		if schema and (schema.Kind == "leaf" or schema.ValueType == "big" or schema.ValueType == "flags") then
			error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is a leaf value and has no children`, 2)
		end
		local path = table.clone(accessorPath(accessor))
		table.insert(path, key)
		local childSchema = if schema then Template.ChildSchema(schema, key) else nil
		-- A declared element record has a fixed field set, so an undeclared key is a
		-- typo. Refusing it HERE is load-bearing, not just friendly: a nil child
		-- schema reads as "untyped" everywhere downstream, which would skip the
		-- container's own key rules and caps (resolveContainer builds no Parent chain
		-- without a schema), letting a write under a misspelled field bypass
		-- MaxKeys/MaxItems/MaxKeyLength and the array contiguity rule entirely.
		if childSchema == nil and schema and schema.Closed then
			error(
				`Scribe: "{tostring(key)}" is not a declared field of the element shape at `
					.. `"{Util.pathString(accessorPath(accessor))}"`,
				2
			)
		end
		child = newAccessor(tree, path, childSchema)
		children[key] = child
	end
	return child
end

-- Callable shorthand: node() gets, node(value) sets, node(fn) updates.
local function accessorCall(accessor: Accessor, ...: any): any
	local n = select("#", ...)
	if n == 0 then
		return accessor.Get()
	end
	local first = ...
	if type(first) == "function" then
		return accessor.Update(first, select(2, ...))
	end
	return accessor.Set(...)
end

ACCESSOR_MT = {
	__index = accessorIndex,
	__call = accessorCall,
}

Node.METHOD_NAMES = {} :: { [string]: boolean }
for name in METHOD_FACTORIES do
	Node.METHOD_NAMES[name] = true
end

-- Deep-clone a value while unpacking every declared datatype descendant back to
-- its Roblox datatype. Exposed for the client's Shared mirror, which stores the
-- packed buffer wire form but has no accessor tree to convert it on read.
Node.CloneUnpack = cloneUnpack

return Node
