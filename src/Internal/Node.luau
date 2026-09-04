--!strict
-- The Value tree runtime: a metatable-backed accessor tree that lazily materializes
-- child nodes, records paths for replication, validates every write, and holds
-- per-node callback lists. Used for the server tree and the client mirror alike.

local Util = require(script.Parent.Util)
local Big = require(script.Parent.Big)
local Template = require(script.Parent.Template)
local Datatypes = require(script.Parent.Datatypes)
local DerivedModule = require(script.Parent.Derived)
local Metrics = require(script.Parent.Metrics)

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
	-- Scribe.Derived diagnostics, so each realm logs with its own context and this
	-- module stays free of the logger.
	OnDerivedIssue: ((code: string, field: string, detail: string) -> ())?,
	-- The server store: no player, no key. Read only by the cross-tree refusal.
	IsServerStore: boolean?,
}

-- Cast once: Big.from is optional because parsing can fail, which a literal cannot,
-- and the economy path below would otherwise compare through `any`.
local BIG_ZERO = Big.from(0) :: Big.Big

local Node = {}

-- The message RunTransaction returns when `fn` yielded. Exported so a caller can tell
-- a yield apart from a throw without string-matching a literal.
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
		-- The library's handle on the reserved `_Scribe` root: the only accessor
		-- permitted to write there, and never returned by any public API.
		Reserved: any,
		Dead: boolean,
		_listeners: { [string]: { [string]: { [any]: (...any) -> () } } },
		-- Path array per listened pathKey; the pathKey string is lossy and cannot be
		-- reversed to read a node's value.
		_paths: { [string]: { string | number } },
		-- Ancestor pathKey -> listened pathKeys strictly below it, so a container write
		-- finds its descendant listeners by lookup instead of sweeping every path.
		_descendants: { [string]: { [string]: boolean } },
		-- True only while replaying the initial snapshot: suppresses per-op fires so
		-- descendants can be fired once, together, afterwards.
		_replaying: boolean,
		_batchDepth: number,
		-- Ancestor Changed fires deferred to the end of a batch, keyed by pathKey so N
		-- writes under one container collapse to one fire. Insertion-ordered via
		-- _pendingAncestorOrder, which reproduces the unbatched order.
		_pendingAncestors: { [string]: { string | number } }?,
		_pendingAncestorOrder: { string }?,
		-- Set only while a failed transaction rolls back: dispatch is queued here and
		-- drained once the tree is whole again. See `fire` and `rollbackTransaction`.
		_fireQueue: { { any } }?,
		_txn: {
			Snapshots: { [string]: { Path: { string | number }, Value: any } },
			Below: { [string]: { [string]: boolean } },
			Ops: { { Op: Op, Schema: SchemaNode? } },
			Created: { { string | number } },
			Seeded: { { string | number } },
			Economy: { { Path: { string | number }, Delta: number, New: number, Tags: { [string]: any } } },
			RawRestores: { [string]: { Store: { [string]: any }, Value: any } },
		}?,
		-- Scribe.Derived: fields whose inputs changed and have not been recomputed
		-- yet, and the reentrancy guard for the settle pass that drains them.
		_derivedDirty: { [SchemaNode]: true }?,
		_derivedAudit: { { Path: { string | number }, Label: string, Server: any } }?,
		_derivedSettling: boolean,
		-- Fields whose compute function has already reported a throw this session.
		_derivedLogged: { [SchemaNode]: true }?,
	},
	Tree
))

-- Per-accessor state, stored under keys a caller cannot type. Table identities, not
-- strings: a rawset string key like "_tree" is found before __index runs, so
-- `Data.Get(p)._tree` would hand game code the live Tree and its raw stores.
local F_TREE = {} :: any
local F_PATH = {} :: any
local F_KEY = {} :: any
local F_SCHEMA = {} :: any
local F_CHILDREN = {} :: any

-- The accessors permitted to write under Template.RESERVED_ROOT. A module upvalue
-- rather than a field, so no object a caller can reach can rawset the capability onto
-- a public accessor. Weak-keyed: a collected child accessor is rebuilt from its
-- parent, which re-grants it.
local PRIVILEGED: { [any]: true } = setmetatable({}, { __mode = "k" }) :: any

-- The ONE tree whose transaction is open right now, or nil. `Tree._txn` is per-tree,
-- right for the journal but wrong as the admission test: a transaction can only undo
-- writes to its own tree, and another player is another tree behind another DataStore
-- key. A module upvalue is sound because a transaction is synchronous by construction:
-- `fn` runs on its own coroutine and a yield is refused. Cleared BEFORE the rollback
-- restores and before the queued fires drain, so a listener writing after a rollback is
-- an ordinary write.
local OPEN_TXN_TREE: Tree? = nil

-- The shared half of both cross-tree refusals: why, and the durable outbox to use
-- instead. One player handing value to another is a real need, so the refusal has to
-- name the route that works.
local CROSS_TREE_TXN_WHY = "a transaction can only roll back its OWN player, because another player is "
	.. "another tree behind another DataStore key -- the same reason a yield inside a transaction is "
	.. "refused. For one-sided value (a gift, mail, a reward, a bounty payout) use the durable outbox that "
	.. "gift delivery already uses: record the debit on the giver's own key INSIDE this transaction, "
	.. "Data.Flush it, then deliver with Data.SendMessage and apply it idempotently at the far end. See the "
	.. "Transactions guide."

-- The cross-tree refusal, in one place: accessorIndex is not the only writer, since
-- Server/Timed writes the flat `_Scribe.Timed` store raw. `subject` names what was
-- written, `level` is the caller's own blame depth. Callers gate on OPEN_TXN_TREE
-- before building `subject`, which is not worth allocating on every write.
local function assertSameTreeWrite(tree: Tree?, subject: string, level: number)
	if OPEN_TXN_TREE == nil or tree == OPEN_TXN_TREE then
		return
	end
	-- Not another player, so the outbox route is wrong advice: it has no key at all.
	if tree ~= nil and tree.Params.IsServerStore then
		error(
			`Scribe: "{subject}" is on the ServerStore, not on the player whose transaction is `
				.. `open, so it cannot be written from inside that transaction: a rollback restores one `
				.. `player's own tree, and the store is not saved to any key, so a store write would `
				.. `outlive an aborted transaction. Write the store before Data.Transaction, or after it `
				.. `returns true.`,
			level
		)
	end
	error(
		`Scribe: "{subject}" belongs to a different player than the one `
			.. `whose transaction is open, so it cannot be written from inside that transaction: `
			.. CROSS_TREE_TXN_WHY,
		level
	)
end

local function newAccessor(tree: Tree, path: { string | number }, schema: SchemaNode?, privileged: boolean?): any
	local accessor: any = setmetatable({}, ACCESSOR_MT)
	rawset(accessor, F_TREE, tree)
	rawset(accessor, F_PATH, path)
	rawset(accessor, F_KEY, Util.pathKey(path))
	rawset(accessor, F_SCHEMA, schema)
	-- Weak VALUES: child accessors carry no state (listeners live on the tree, keyed by
	-- pathKey), so a collected one is simply rebuilt on the next index. Without this,
	-- indexing a dictionary by transient keys (GUIDs, trade ids) leaks for the session.
	rawset(accessor, F_CHILDREN, setmetatable({}, { __mode = "v" }))
	if privileged then
		PRIVILEGED[accessor] = true
	end
	return accessor
end

function Node.NewTree(params: TreeParams): Tree
	local self = setmetatable({
		Params = params,
		Compiled = params.Compiled,
		Accessor = nil :: any,
		Reserved = nil :: any,
		Dead = false,
		_listeners = {},
		_paths = {},
		_descendants = {},
		_replaying = false,
		_batchDepth = 0,
		_pendingAncestors = nil,
		_pendingAncestorOrder = nil,
		_fireQueue = nil,
		_txn = nil,
		_derivedDirty = nil,
		_derivedSettling = false,
		_derivedLogged = nil,
	}, Tree) :: Tree
	self.Accessor = newAccessor(self, {}, params.Compiled.Root)
	-- The schema is read straight off Root.Children, not through ChildSchema: a template
	-- lacking the reserved root must not get an AnyChild node synthesized and cached onto
	-- the compiled root as a side effect of building a tree.
	local rootChildren = params.Compiled.Root.Children
	self.Reserved = newAccessor(
		self,
		{ Template.RESERVED_ROOT },
		if rootChildren then rootChildren[Template.RESERVED_ROOT] else nil,
		true
	)
	return self
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
		if rootSchema and not rootSchema.Persist then
			return tree.Params.Stores.Session
		end
	end
	return tree.Params.Stores.Persist
end

-- The other-typed form of a key that produces the SAME Util.pathKey (7 <-> "7"), or
-- nil when there is none. Used to reject a numeric key coexisting with its string
-- form, whose colliding pathKeys would alias listeners, coalescing and rollback.
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

-- Container memos -------------------------------------------------------------
--
-- Key count and "holds a string key", memoised by container identity so building a
-- capped or integer-keyed dictionary key by key is not O(n^2). Weak-keyed, and safe
-- because a whole-table Set installs a different table with no entry yet. Maintained
-- where a container is ASSIGNED INTO, not where a write is validated: NoValidate and
-- FromRemote writes skip validation entirely.
local containerCounts: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
-- The offending string key of an integer-keyed container, or `false` for
-- "walked it, there is none".
local stringKeyed: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local function countKeysExact(container: any): number
	local n = 0
	for _ in container do
		n += 1
	end
	containerCounts[container] = n
	return n
end

local function countKeys(container: any): number
	local cached = containerCounts[container]
	if cached ~= nil then
		return cached
	end
	return countKeysExact(container)
end

-- One key of `container` went from absent to present or back. A container with no
-- memo yet is left alone: the next countKeys walks it once and starts from truth.
local function noteKeyDelta(container: any, key: any, had: boolean, has: boolean)
	if had == has then
		return
	end
	-- A cached "holds no string key" stops being true the moment one is added. Upgraded
	-- here rather than in the guard because NoValidate and FromRemote writes assign
	-- without reaching validation, and this hook still sees them. A string key going AWAY
	-- is deliberately not tracked: that only leaves a stale "yes", which
	-- blockingStringKey re-derives before acting on.
	if has and type(key) == "string" and stringKeyed[container] == false then
		stringKeyed[container] = key
	end
	local cached = containerCounts[container]
	if cached ~= nil then
		containerCounts[container] = if has then cached + 1 else cached - 1
	end
end

-- Drop both memos for a container mutated in a way this module cannot account for
-- key by key. Cheaper and safer than trying to reconstruct the delta.
local function forgetContainer(container: any)
	containerCounts[container] = nil
	stringKeyed[container] = nil
end

-- A container emptied in place (table.clear keeps the identity) has no keys at all, so
-- neither memo needs re-deriving. Not load-bearing; it just keeps them truthful.
local function noteContainerCleared(container: any)
	containerCounts[container] = 0
	stringKeyed[container] = false
end

local function scanStringKey(container: any): string?
	for existing in container do
		if type(existing) == "string" then
			stringKeyed[container] = existing
			return existing
		end
	end
	stringKeyed[container] = false
	return nil
end

-- Does this container still hold a string key? Only a Scribe.MapOf("integer") asks, and
-- only when adding a key, so "no" is the case worth memoising. A cached "yes" is NOT
-- trusted: such a key goes away by a raw fix-up of the stored table (a migration, an
-- operator edit) this module never sees, so re-deriving lets the repair take effect
-- instead of locking the container forever.
local function blockingStringKey(container: any): string?
	local cached = stringKeyed[container]
	if cached == false then
		return nil
	end
	return scanStringKey(container)
end

-- Would creating `key` in this UNDECLARED container leave it holding an array part and
-- string keys at once? The DataStore drops half of such a table on encode. Returns a
-- description of the blocker, or nil.
--
-- Deliberately asymmetric: a numeric key is refused whenever a string key is present,
-- but a string key only when index 1 is occupied, since `{ [7] = ... }` is a legitimate
-- sparse bag that encodes cleanly.
local function mixedKeyBlocker(container: any, key: any): string?
	if type(key) == "number" then
		if container[1] ~= nil then
			-- Already array-shaped, so a further index adds nothing the string side did
			-- not already have to permit. Short-circuiting here is also what keeps
			-- building an array key-by-key linear rather than quadratic.
			return nil
		end
		local blocking = blockingStringKey(container)
		if blocking ~= nil then
			return `the string key "{blocking}"`
		end
		return nil
	end
	if container[1] ~= nil then
		return "an array starting at index 1"
	end
	return nil
end

local function checkContainerKey(
	containerSchema: SchemaNode?,
	container: any,
	key: any,
	path: { any },
	upto: number,
	removing: boolean?
)
	-- Rendered only when refusing; this runs on every container write.
	local function where(): string
		return Util.pathString(table.move(path, 1, upto, 1, {}))
	end
	local kind = if containerSchema then containerSchema.Container else nil
	if kind == nil then
		-- No declared key type, but an undeclared container still may not become a mixed
		-- array/hash table. Only key CREATION is judged: a removal, or a write to a key
		-- already there, must stay possible or a profile that loaded already mixed has no
		-- way to repair itself.
		if not removing and container[key] == nil then
			local blocker = mixedKeyBlocker(container, key)
			if blocker ~= nil then
				-- A write on the profile root has an empty path prefix, and `"" already
				-- holds ...` reads like a bug in the message. Name the root instead.
				local label = if where() == "" then "the profile root" else `"{where()}"`
				error(
					`Scribe: {label} already holds {blocker}, so adding the key {tostring(key)} would make it `
						.. "a mixed array/hash table -- the DataStore drops half of one on save, and Set on the "
						.. "parent refuses the same shape. Use one key type for this container",
					0
				)
			end
		end
		return
	end
	local schema = containerSchema :: SchemaNode
	if kind == "Array" then
		if type(key) ~= "number" then
			error(
				`Scribe: "{where()}" is a Scribe.ArrayOf and takes array indices, but the key "{tostring(key)}" `
					.. `is a {type(key)}`,
				0
			)
		end
		local len = #container
		if removing then
			-- Only the tail can go away by a nil write without leaving a hole. Removing
			-- a key that is not there stays a no-op.
			if container[key] ~= nil and key ~= len then
				error(
					`Scribe: "{where()}" is a Scribe.ArrayOf and must stay contiguous; use Remove({key}) `
						.. `instead of setting index {key} to nil`,
					0
				)
			end
			return
		end
		if key % 1 ~= 0 or key < 1 or key > len + 1 then
			error(
				`Scribe: index {key} is out of range for "{where()}" (length {len}); `
					.. "array elements are created with Insert",
				0
			)
		end
		-- Growth only: an entry past the cap that already exists stays writable,
		-- because a newer-template server may have stored it before this server's
		-- lower cap deployed, and stranding it turns a rolling deploy into lost writes.
		if schema.MaxItems and key > schema.MaxItems and container[key] == nil then
			error(`Scribe: "{where()}" is capped at MaxItems {schema.MaxItems}`, 0)
		end
	else
		-- Scribe.MapOf declares its key type; a plain Scribe.DictOf is string-keyed.
		local keyType = schema.KeyType or "string"
		if keyType == "integer" then
			if type(key) ~= "number" then
				error(
					`Scribe: "{where()}" is a Scribe.MapOf("integer") and takes integer keys, but the key `
						.. `{tostring(key)} is a {type(key)}`,
					0
				)
			end
			-- A DataStore serializes object keys to JSON strings, and only a finite
			-- integer survives that round trip unambiguously.
			if key ~= key or key == math.huge or key == -math.huge or key % 1 ~= 0 then
				error(`Scribe: "{where()}" takes finite integer keys, got {tostring(key)}`, 0)
			end
		elseif type(key) ~= "string" then
			local declarator = if schema.KeyType then `Scribe.MapOf("string")` else "Scribe.DictOf"
			error(
				`Scribe: "{where()}" is a {declarator} and takes string keys, but the key {tostring(key)} `
					.. `is a {type(key)}`,
				0
			)
		end
		if removing then
			return
		end
		-- A new integer key in a container that still holds a string one gives a
		-- table with both key types, which fails the WHOLE profile save, not just
		-- this field. Reachable when load-time coercion was blocked by a
		-- non-canonical spelling ("07", "1.5"). Refuse and name the blocker.
		if keyType == "integer" and container[key] == nil then
			local blocking = blockingStringKey(container)
			if blocking ~= nil then
				error(
					`Scribe: "{where()}" is a Scribe.MapOf("integer") but still holds the string key `
						.. `"{blocking}", which load-time coercion could not convert. Writing an integer `
						.. "key now would leave both key types in one table, which fails the whole "
						.. "profile save. Remove or migrate that key first",
					0
				)
			end
		end
		local maxKeyLength = if keyType == "string" then schema.MaxKeyLength else nil
		if maxKeyLength and #(key :: string) > maxKeyLength then
			-- Reject rather than truncate: a truncated key writes to the wrong slot.
			error(`Scribe: key "{key}" at "{where()}" is {#(key :: string)} bytes, over MaxKeyLength {maxKeyLength}`, 0)
		end
		local maxKeys = schema.MaxKeys
		if maxKeys and container[key] == nil then
			local count = countKeys(container)
			if count >= maxKeys then
				-- At the cap according to the memo. Re-derive before refusing, so a
				-- memo drifted by a caller mutating the live table from a container
				-- Get() costs a walk rather than rejecting a legitimate write.
				count = countKeysExact(container)
			end
			if count >= maxKeys then
				error(`Scribe: "{where()}" already holds {count} keys, at its MaxKeys {maxKeys}`, 0)
			end
		end
	end
end

-- Resolves the container holding path's last segment, materializing missing
-- intermediates when `create`. `schema` is the LAST segment's schema; the
-- per-segment ones come from walking its Parent chain, which mirrors the path.
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
		local c = table.create(n) :: { SchemaNode }
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
			-- The container written into is path[1..i-1], so its schema is the chain
			-- entry one level up; i == 1 is the store root, never a declared
			-- container. Validated writes only: a remote apply must never throw here,
			-- because one throw drops the rest of the frame and desyncs the mirror.
			if validating and chain and i > 1 then
				checkContainerKey(chain[i - 1], container, seg, path, i - 1)
			end
			-- Same alias hazard applySet guards for the leaf key: a nested write like
			-- Dict[7].Sub must not create a numeric 7 next to an existing string "7".
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
				-- The mirror gets the ServerOnly-stripped copy; the full default would
				-- surface a value on the client that no replicated op ever sent.
				seed = if tree.Params.IsServer then createdSchema.Default else createdSchema.ClientDefault
			end
			nextContainer = if type(seed) == "table" then Util.deepClone(seed) else {}
			local segHad = container[seg] ~= nil
			container[seg] = nextContainer
			noteKeyDelta(container, seg, segHad, true)
			-- Recorded so a rollback can prune containers that never existed pre-txn.
			local txn = tree._txn
			if txn then
				txn.Created[#txn.Created + 1] = table.move(path, 1, i, 1, table.create(i) :: { string | number })
			end
		elseif type(nextContainer) ~= "table" then
			if not create then
				-- A READ through a segment that now holds a scalar answers nil, as a
				-- read through an absent segment does. readValue is on the apply path
				-- twice (snapshotDescendants and fireDescendants), so raising here would
				-- kill the frame and desync the mirror for good. Only a WRITE raises.
				return nil, nil
			end
			error(`Scribe: cannot index "{Util.pathString(path)}": "{tostring(seg)}" is not a table`, 0)
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

-- Calls `fn` with every strict ancestor pathKey of `pathKey`, outermost first. A
-- segment can never contain the \31 separator (control characters are refused at
-- write time), so a prefix ending at one is exactly an ancestor.
local function forEachAncestorKey(pathKey: string, fn: (string) -> ())
	local at = string.find(pathKey, "\31", 1, true)
	while at do
		fn(string.sub(pathKey, 1, at - 1))
		at = string.find(pathKey, "\31", at + 1, true)
	end
end

-- Register/unregister `pathKey` under each of its ancestors, so a write at an
-- ancestor can find everything listening below it without sweeping every path.
local function indexDescendant(tree: Tree, pathKey: string)
	forEachAncestorKey(pathKey, function(ancestor)
		local set = tree._descendants[ancestor]
		if set == nil then
			set = {}
			tree._descendants[ancestor] = set
		end
		set[pathKey] = true
	end)
end

local function unindexDescendant(tree: Tree, pathKey: string)
	forEachAncestorKey(pathKey, function(ancestor)
		local set = tree._descendants[ancestor]
		if set ~= nil then
			set[pathKey] = nil
			if next(set) == nil then
				tree._descendants[ancestor] = nil
			end
		end
	end)
end

local function connect(tree: Tree, path: { string | number }, event: string, fn: (...any) -> ()): () -> ()
	assertAlive(tree)
	local pathKey = Util.pathKey(path)
	local list = listenersFor(tree, pathKey, event, true) :: { [any]: (...any) -> () }
	if tree._paths[pathKey] == nil then
		indexDescendant(tree, pathKey)
	end
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
					unindexDescendant(tree, pathKey)
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
	-- A rollback restores many paths one at a time; dispatching as each lands would
	-- let a listener read and write from a half-restored tree that never existed.
	-- Queue instead, and RunTransaction drains once every restore has landed. Unlike
	-- the `_replaying` suppression above, nothing is dropped: only the dispatch moves.
	local queue = tree._fireQueue
	if queue ~= nil then
		queue[#queue + 1] = { pathKey, event, table.pack(...) }
		return
	end
	local args = table.pack(...)
	-- Snapshot the listeners before dispatch: a callback may connect or disconnect
	-- into this same live table, and mutating during generalized iteration is
	-- undefined in Luau. Semantics match GoodSignal: a listener connected during the
	-- fire does not receive it, and one disconnected mid-fire is not called.
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

-- Walks up from `path` firing two kinds of event on each ancestor. OnChildChanged is a
-- TRANSITION, so it fires immediately and is never coalesced, which would destroy what
-- it reports. Changed is STATE, and its `old` is the same reference as `new`, so a batch
-- can collapse it losing nothing.
--
-- `childOld` is the deepest ancestor's immediate child's prior value, passed only by
-- applySet. It needs its own `known` flag because nil is a legitimate prior value.
local function fireAncestors(tree: Tree, path: { string | number }, childOld: any, childOldKnown: boolean?)
	if next(tree._listeners) == nil then
		return
	end
	local deferring = tree._batchDepth > 0
	-- The child of the ancestor at `depth` is the prefix of length depth + 1, i.e.
	-- the previous iteration's already-allocated prefix. Starts as `path` itself.
	local childPrefix: { string | number } = path
	for depth = #path - 1, 0, -1 do
		local prefix = table.move(path, 1, depth, 1, table.create(depth) :: { string | number })
		local pathKey = Util.pathKey(prefix)
		local byEvent = tree._listeners[pathKey]
		if byEvent ~= nil then
			local childList = byEvent.OnChildChanged
			if childList and next(childList) ~= nil then
				-- Read the child on its OWN path, not by indexing the parent's table:
				-- at the root, readValue short-circuits to Stores.Persist, so
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

-- A container's own STATE fire, routed through the defer queue fireAncestors uses.
-- Insert/Remove/Clear mutate at the container's own path, so they never reach
-- fireAncestors for that node and would otherwise fire N times in a batch where every
-- other container fires once. Safe to collapse: the fire is (value, value), and OnInsert
-- and OnRemove carry the per-entry transitions separately.
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
-- Order is first-touch, which reproduces the unbatched order minus the duplicates. It
-- is NOT globally deepest-first, and sorting it that way would move fires.
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

-- Drop a rolled-back transaction's deferred fires; the restores below fire their own
-- Changed with the pre-transaction values. Scoped by a mark taken when the transaction
-- opened, because the queue is tree-wide: a transaction nested in a Data.Batch shares it
-- with the batch's surviving writes, and clearing it wholesale would swallow those too.
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

-- Stands in for "this path held nothing" in a descendant snapshot: `olds[key] = nil`
-- stores no entry, so an absent-to-present descendant would be invisible to the diff.
-- That is the ordinary case, not an edge one (every appended array element).
local ABSENT = table.freeze({})

-- A whole-table write changes every leaf beneath it, but `fire` touches only that
-- pathKey and `fireAncestors` walks upward, so a descendant listener would never hear
-- about it. These two snapshot the observed descendants before the write and fire
-- whichever changed after it. Scoped to STRICT descendants: the written path is fired
-- by the caller, and including it would double-fire the container's own observer.
local function snapshotDescendants(tree: Tree, pathKey: string): { [string]: any }?
	if next(tree._listeners) == nil then
		return nil
	end
	-- Indexed, not swept: _descendants answers this in one lookup, so a write does
	-- not cost a prefix match against every path the game is listening to.
	local below = tree._descendants[pathKey]
	if below == nil then
		return nil
	end
	local olds: { [string]: any }? = nil
	for key in below do
		local byEvent = tree._listeners[key]
		if byEvent and byEvent.Changed then
			local path = tree._paths[key]
			if path then
				olds = olds or {}
				local was = readValue(tree, path)
				local slot = olds :: { [string]: any }
				slot[key] = if was == nil then ABSENT else was
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
	for key, parked in olds do
		local path = tree._paths[key]
		if path then
			local old = if parked == ABSENT then nil else parked
			local current = readValue(tree, path)
			-- Identity, not leafEquals, which reports tables as never equal. Both sides
			-- are the same path read before and after one mutation, so a container still
			-- holding its original table held its contents too. Insert at the tail
			-- depends on this, or it wakes every bound row in the array.
			if current ~= old then
				table.insert(pending, { Key = key, New = current, Old = old })
			end
		end
	end
	for _, item in pending do
		fire(tree, item.Key, "Changed", item.New, item.Old)
	end
end

-- Key transitions for the containers a whole-table write REWRITES. applySet reports only
-- the one key it wrote, so a Set at an ancestor would add or drop keys further down with
-- nothing saying so. Scoped to STRICT descendants, like `snapshotDescendants`: the
-- written path's own contents are a bulk state change. The snapshot is a shallow
-- key -> value map per container bound to OnKeyAdded/OnKeyRemoved.
type KeyedSnapshot = {
	Key: string,
	Path: { string | number },
	Schema: SchemaNode?,
	Old: { [any]: any },
}

-- Resolve the schema at `path` starting from the node that sits at depth `from - 1`.
local function schemaBelow(base: SchemaNode?, path: { string | number }, from: number): SchemaNode?
	local node = base
	for i = from, #path do
		if node == nil then
			return nil
		end
		node = Template.ChildSchema(node, path[i])
	end
	return node
end

-- The same dynamic-key test applySet applies to a direct parent: a DECLARED child is
-- part of a record's fixed shape, so it never appears or disappears as a key.
local function isDynamicKey(node: SchemaNode?, key: any): boolean
	local declared = if node then node.Children else nil
	return declared == nil or type(key) ~= "string" or declared[key :: string] == nil
end

local function snapshotKeyed(tree: Tree, pathKey: string, depth: number, schema: SchemaNode?): { KeyedSnapshot }?
	local below = tree._descendants[pathKey]
	if below == nil then
		return nil
	end
	local out: { KeyedSnapshot }? = nil
	for key in below do
		local byEvent = tree._listeners[key]
		if byEvent ~= nil and (byEvent.OnKeyAdded ~= nil or byEvent.OnKeyRemoved ~= nil) then
			local p = tree._paths[key]
			if p ~= nil then
				local node = schemaBelow(schema, p, depth + 1)
				-- A Scribe.Big and a Scribe.Flags are leaves that merely store as
				-- tables: their keys are an encoding, not container entries.
				if node == nil or (node.ValueType ~= "big" and node.ValueType ~= "flags") then
					local current = readValue(tree, p)
					local olds: { [any]: any } = {}
					if type(current) == "table" then
						for k, v in current :: { [any]: any } do
							olds[k] = v
						end
					end
					local list = out or {}
					out = list
					list[#list + 1] = { Key = key, Path = p, Schema = node, Old = olds }
				end
			end
		end
	end
	return out
end

local function fireKeyDeltas(tree: Tree, snapshots: { KeyedSnapshot }?)
	if snapshots == nil then
		return
	end
	for _, entry in snapshots do
		local current = readValue(tree, entry.Path)
		local new: { [any]: any } = if type(current) == "table" then current :: any else {}
		local old = entry.Old
		for k, v in new do
			if old[k] == nil and isDynamicKey(entry.Schema, k) then
				fire(tree, entry.Key, "OnKeyAdded", k, v)
			end
		end
		for k, v in old do
			if new[k] == nil and isDynamicKey(entry.Schema, k) then
				fire(tree, entry.Key, "OnKeyRemoved", k, v)
			end
		end
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

-- Truncate `s` to at most `maxBytes` without splitting a multi-byte UTF-8 character; a
-- half-encoded trailing character fails the DataStore save. Callers pass an
-- already-validated string, so the loop runs at most 3 times.
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
	-- Depth is budgeted from the ROOT, because Init snapshots re-encode the whole
	-- root from depth 0: a value that is not encodable from there silently drops
	-- the entire root from every snapshot.
	local d = depth or math.max(0, #path - 1)
	if d > MAX_VALUE_DEPTH then
		validationError(path, `nested deeper than {MAX_VALUE_DEPTH} levels from the root`)
	end

	-- Declared datatype fields accept their Roblox datatype (packed here) or an
	-- already-packed buffer. Checked before the generic type gate, which would
	-- otherwise reject the userdata.
	if schema and schema.ValueType == "datatype" then
		local name = schema.Datatype :: string
		if typeof(value) == name then
			-- Precision is nil for a field that did not declare one. The template
			-- compiler has already refused any value a codec would reject, so this
			-- cannot fail on the Precision itself.
			local ok, packed = pcall(Datatypes.Pack, name, value, schema.Precision)
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
	-- Invalid UTF-8 cannot be JSON-encoded, so the ENTIRE profile save fails (error
	-- 104) silently, long after this write. Rejecting every string leaf here names the
	-- offending path at the write site instead.
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
		-- Normalize to declaration order with duplicates dropped, so one set of flags
		-- has one stored form and no diff downstream has to care about write order.
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
			-- Truncate on a character boundary: MaxLength is a byte budget, and a raw
			-- string.sub could split a multi-byte character and fail the save.
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
		-- Recursive Tier-1 over the written table. A numeric key N and the string key
		-- tostring(N) produce the SAME pathKey, so they would alias distinct slots in
		-- listeners, coalescing and rollback. Only scanned when numeric keys exist.
		if Util.hasNumericKeys(value :: any) then
			for k in value :: any do
				-- A mixed table cannot be JSON-encoded, so the whole profile save fails
				-- later, far from this write. This also subsumes the alias pair above.
				if type(k) == "string" then
					validationError(
						path,
						"a table cannot mix array indices and string keys (it would fail the DataStore save)"
					)
				end
			end
		end
		-- A whole-container write must match the declared key shape, or a pure-dictionary
		-- payload passes the plain table gate above and lands under a `{ Record }` field.
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
					-- A Scribe.MapOf("integer") declares its key type, so judge against that
					-- and not DictOf's string assumption, which would refuse the map's own
					-- keys and accept the ones it cannot store.
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
			-- A container already over cap in storage (a newer-template server wrote it
			-- before this server's lower cap deployed) stays writable; only growth is refused.
			local function storedCount(): number
				local stored = readValue(tree, path)
				return if type(stored) == "table" then Util.count(stored) else 0
			end
			if container == "Array" then
				-- `#value` stops at the first hole, so compare against the HIGHEST key
				-- instead: a ragged payload always has maxIndex > count.
				if count ~= maxIndex then
					validationError(path, "array entries must run contiguously from 1 (no holes)")
				end
				local maxItems = declared.MaxItems
				if maxItems then
					-- A set is stored deduplicated, so its cap is on MEMBERSHIP: counting the
					-- caller's raw array would refuse Set({1,1,1}) against MaxItems 2.
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
				-- Non-integer or non-finite numeric keys do not survive the DataStore
				-- JSON round trip.
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
			-- A declared element record has a fixed field set, so an undeclared key is a
			-- typo. The exception: a key this profile already stores was written by a newer
			-- template during a rolling deploy, and rejecting it would turn every
			-- read-modify-write on an old server into a lost write.
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
		-- Fill declared element fields the caller omitted: the element type says they are
		-- always present, so a partial element nil-crashes every consumer typed against
		-- it. Scribe.Optional fields have no default and stay absent.
		if schema and schema.Closed and schema.Children then
			for name, child in schema.Children do
				if out[name] == nil and child.Default ~= nil then
					-- A mirror never fills a ServerOnly field: no replicated op would have
					-- sent it, so an optimistic local write would visibly diverge.
					if tree.Params.IsServer or child.Visibility ~= "ServerOnly" then
						out[name] = Util.deepClone(child.Default)
					end
				end
			end
		end
		if schema and schema.Unique then
			-- Deduplicate and sort so a set has one stored form whatever the write
			-- order. Safe because Template refuses any set element that is not an
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

-- Derived fields ---------------------------------------------------------------
-- A recompute is an ordinary write through applySet, so bounds, coalescing,
-- listeners, transactions and replication all keep working. This layer only decides
-- WHEN to recompute.

-- A listener fired by a recompute may write an input, re-dirtying the field that
-- fired it. Bounded so a feedback loop is reported rather than hanging the writer.
local MAX_SETTLE_PASSES = 4

-- Assigned below applyClear: settling writes through applySet.
local settleDerived: (tree: Tree) -> ()

local function markDerivedDirty(tree: Tree, pathKey: string)
	local dependents = tree.Compiled.DerivedByWrite[pathKey]
	if dependents == nil then
		return
	end
	local dirty = tree._derivedDirty
	if dirty == nil then
		dirty = {}
		tree._derivedDirty = dirty
	end
	for _, node in dependents do
		(dirty :: any)[node] = true
	end
end

-- A write settles immediately unless something else is already going to settle for
-- it: inside a batch the flush does, inside a transaction the commit does, during a
-- replay ReplayFire does (once, after the whole snapshot has landed), and inside a
-- settle pass the pass itself does.
local function settleAfterWrite(tree: Tree)
	if
		tree._derivedDirty == nil
		or tree._derivedSettling
		or tree._batchDepth > 0
		or tree._txn ~= nil
		or tree._replaying
	then
		return
	end
	settleDerived(tree)
end

-- Per-transaction mirror of the tree's _descendants index: ancestor pathKey -> the
-- snapshot keys strictly below it, so a snapshot can absorb the ones underneath it
-- without scanning every snapshot in the transaction.
local function indexSnapshot(txn: any, pathKey: string)
	forEachAncestorKey(pathKey, function(ancestor)
		local set = txn.Below[ancestor]
		if set == nil then
			set = {}
			txn.Below[ancestor] = set
		end
		set[pathKey] = true
	end)
end

local function unindexSnapshot(txn: any, pathKey: string)
	forEachAncestorKey(pathKey, function(ancestor)
		local set = txn.Below[ancestor]
		if set ~= nil then
			set[pathKey] = nil
			if next(set) == nil then
				txn.Below[ancestor] = nil
			end
		end
	end)
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
			forgetContainer(container)
			container[seg] = nextContainer
		end
		container = nextContainer
	end
	forgetContainer(container)
	container[relPath[#relPath]] = value
end

-- Remove `relPath` from `root` WITHOUT creating any intermediate tables (unlike
-- setNested). Used to strip txn-materialized descendant containers out of a rollback
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

-- Records the pre-transaction value of `path`, keeping snapshots DISJOINT so rollback
-- order is irrelevant. An ancestor snapshot already covers this subtree; earlier
-- descendant snapshots are overlaid onto the current value and then dropped.
local function snapshotForTxn(tree: Tree, path: { string | number }, pathKey: string, oldValue: any)
	local txn = tree._txn
	if not txn or txn.Snapshots[pathKey] ~= nil then
		return
	end
	-- Already covered by an ancestor snapshot? Walk THIS path's ancestor keys rather than
	-- every snapshot taken so far, which made a transaction quadratic in the number of
	-- distinct paths it touched. The real path comparison still runs on a hit: it is
	-- O(depth) and it decides whether a rollback restores the correct subtree.
	local at = string.find(pathKey, "\31", 1, true)
	while at do
		local ancestorSnap = txn.Snapshots[string.sub(pathKey, 1, at - 1)]
		if ancestorSnap ~= nil and pathIsStrictAncestor(ancestorSnap.Path, path) then
			return
		end
		at = string.find(pathKey, "\31", at + 1, true)
	end
	local value = Util.deepClone(oldValue)
	-- Track which descendant snapshots get overlaid: each is the authoritative
	-- pre-txn state at its path, which the Created-strip below must not undo.
	local overlaid: { { string | number } }? = nil
	-- Snapshots strictly BELOW this path, by lookup. Collected first because
	-- absorbing one removes it from the same index being iterated.
	local belowSet = txn.Below[pathKey]
	if belowSet ~= nil then
		local descKeys: { string } = {}
		for descKey in belowSet do
			descKeys[#descKeys + 1] = descKey
		end
		for _, descKey in descKeys do
			local snap = txn.Snapshots[descKey]
			if snap ~= nil and pathIsStrictAncestor(path, snap.Path) then
				if type(value) ~= "table" then
					value = {}
				end
				local relPath = table.move(
					snap.Path,
					#path + 1,
					#snap.Path,
					1,
					table.create(#snap.Path - #path) :: { string | number }
				)
				setNested(value, relPath, snap.Value)
				overlaid = overlaid or {}
				table.insert(overlaid :: { { string | number } }, snap.Path)
				txn.Snapshots[descKey] = nil
				unindexSnapshot(txn, descKey)
			end
		end
	end
	-- Reconcile against containers materialized during this txn, so a rollback cannot
	-- resurrect them as phantom empty tables: either the snapshotted container itself was
	-- created (pre-txn value is nil), or a strict descendant was (strip it out). Only
	-- strip a created path when NO overlaid snapshot sits at or above it: Created also
	-- records a pre-existing container deleted and recreated inside this txn, whose
	-- overlay re-established genuine pre-txn state that stripping would destroy.
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
	indexSnapshot(txn, pathKey)
end

local applySet: (Tree, { string | number }, SchemaNode?, any, WriteOpts) -> any

-- Materializes every missing DECLARED-ELEMENT intermediate along `path` as a real
-- applySet write of the element's defaults, before the caller's own write resolves the
-- chain. That makes materialization visible everywhere a write is: the element Set
-- replicates (so a schema-less Shared mirror rebuilds the full element, not a bare {}),
-- OnKeyAdded fires, a transaction can roll the creation back, and a later leaf write
-- equal to the default no-ops safely. Untyped intermediates keep their silent plain-{}
-- materialization in resolveContainer.
local function seedMissingElements(tree: Tree, path: { string | number }, schema: SchemaNode?, opts: WriteOpts)
	local n = #path
	if n < 2 or schema == nil then
		return
	end
	local chain = table.create(n) :: { SchemaNode }
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
					-- The element's own key must satisfy its container's rules before the
					-- seed write lands, which runs NoValidate on an already-stored form.
					if validating and i > 1 then
						checkContainerKey(chain[i - 1], container, seg, path, i - 1)
						-- The same alias guard resolveContainer applies. Seeding reaches the
						-- container first, so resolveContainer's own check would see a key
						-- that already exists and never run. Unreachable today only because
						-- checkContainerKey above rejects the mismatched form, which is a
						-- guard in another function, so this stays.
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
					local prefix = table.move(path, 1, i, 1, table.create(i) :: { string | number })
					-- This element exists because a write descended THROUGH its key, not
					-- because anything asked for it. Recorded inside transactions only, for
					-- the receipt path. Deliberately NOT txn.Created, which rollback
					-- consumes: this list is observational.
					local seedTxn = tree._txn
					if seedTxn then
						seedTxn.Seeded[#seedTxn.Seeded + 1] = prefix
					end
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

-- Value equality for the three leaves whose canonical stored form is a table or a
-- buffer, which `Util.leafEquals` always reports as changed; without it a no-op Set on
-- one fires Changed and replicates. Safe because validateWrite has just rebuilt the
-- value into Scribe's own normal form, of bounded size and never handed out by
-- reference. Deliberately NOT extended to user tables, Scribe.SetOf or containers: a
-- deep compare there is unbounded, and a whole-table Set is how a caller replaces a
-- table.
local function canonicalStoredEquals(schema: SchemaNode?, old: any, new: any): boolean
	if schema == nil then
		return false
	end
	local vt = schema.ValueType
	if vt == "big" then
		-- Big.toStored is exactly two numbers, and normalize() snaps the mantissa
		-- through "%.15g" precisely so that one value has ONE stored pair.
		return type(old) == "table"
			and type(new) == "table"
			and #(old :: { any }) == 2
			and #(new :: { any }) == 2
			and (old :: { any })[1] == (new :: { any })[1]
			and (old :: { any })[2] == (new :: { any })[2]
	elseif vt == "datatype" then
		-- Byte-for-byte on the PACKED form. Packing is deterministic, so an equal
		-- value re-packs to equal bytes; a lossy round trip just fails this test and
		-- writes, which is the safe direction to be wrong in.
		return type(old) == "buffer" and type(new) == "buffer" and Util.bufferEquals(old :: buffer, new :: buffer)
	elseif vt == "flags" then
		if type(old) ~= "table" or type(new) ~= "table" then
			return false
		end
		local a, b = old :: { any }, new :: { any }
		if #a ~= #b then
			return false
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return false
			end
		end
		-- Both sides are member names in declaration order, so element-by-element
		-- equality IS set equality. An out-of-order stored value fails and writes,
		-- which canonicalizes it.
		return true
	end
	return false
end

function applySet(tree: Tree, path: { string | number }, schema: SchemaNode?, value: any, opts: WriteOpts): any
	-- validateWrite rebuilds tables entry-by-entry (no aliasing); unvalidated
	-- table writes are cloned explicitly instead.
	local newValue = if opts.NoValidate then value else validateWrite(tree, schema, path, value)
	if type(newValue) == "table" and opts.NoValidate then
		newValue = Util.deepClone(newValue)
	end

	-- A REMOTE nil-Set materializes missing parents: the server only emits a removal
	-- when the parent chain existed, so a mirror missing them lost the creating op to
	-- coalescing and the server still holds them. Creating them here keeps existence
	-- and Count() parity; local writes keep the no-op semantics. Seeding runs AFTER
	-- validateWrite so a rejected value leaves no phantom element behind.
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

	-- Reject a keyed write whose other-typed form already occupies the container
	-- (number 7 vs string "7"), because their pathKeys alias. Local validated writes
	-- only; remote and restore writes are trusted.
	if not opts.NoValidate and not opts.FromRemote then
		-- The last segment is a key of its parent, so the container's key rules apply
		-- to it too; resolveContainer only saw the intermediate ones. Removals are
		-- checked because a nil write to a middle array index punches a hole.
		if schema and schema.Parent then
			checkContainerKey(schema.Parent, container, key, path, #path - 1, newValue == nil)
		end
		-- Deleting a declared, non-Optional field of a closed element record stores the
		-- partial element that shape exists to prevent. Removing the WHOLE element stays
		-- legal: its parent is the container, not a record.
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
	-- `not opts.NoValidate` is what makes the second test sound: only then did
	-- validateWrite build `newValue`, and only then is it in canonical stored form.
	if Util.leafEquals(old, newValue) or (not opts.NoValidate and canonicalStoredEquals(schema, old, newValue)) then
		return old
	end

	local pathKey = Util.pathKey(path)
	-- After the no-op early-out, so an unchanged write never triggers a recompute,
	-- and before the fires, so a listener reading a derived field sees it settled.
	markDerivedDirty(tree, pathKey)
	snapshotForTxn(tree, path, pathKey, old)
	-- Snapshot observed descendants BEFORE the write; a whole-table Set changes
	-- every leaf beneath this path and only this pass can report it.
	local descendantOlds = if type(newValue) == "table" or type(old) == "table"
		then snapshotDescendants(tree, pathKey)
		else nil
	-- Only a table on one side or the other can add or drop keys BELOW this path.
	local keyedOlds = if type(newValue) == "table" or type(old) == "table"
		then snapshotKeyed(tree, pathKey, #path, schema)
		else nil
	local keyHad = old ~= nil
	container[key] = newValue
	noteKeyDelta(container, key, keyHad, newValue ~= nil)

	emitOp(tree, { Kind = "Set", Path = table.clone(path), Value = newValue }, schema, opts)

	fire(tree, pathKey, "Changed", newValue, old)
	-- Key transitions on a descendant container come BEFORE that container's own
	-- Changed, matching a single-key write and keeping the guarantee that a
	-- container's transitions arrive before the state fire summarizing them.
	fireKeyDeltas(tree, keyedOlds)
	fireDescendants(tree, descendantOlds)
	-- Dictionary key events on the parent (dynamic keys only).
	if #path >= 1 then
		local parentPath = table.move(path, 1, #path - 1, 1, table.create(#path - 1) :: { string | number })
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
	settleAfterWrite(tree)
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
		noteKeyDelta(container, key, false, true)
	elseif type(value) ~= "table" then
		error(`Scribe: "{Util.pathString(path)}" is not a container`, 0)
	end
	return value
end

-- Forward declaration: applyInsert evicts through the real remove path so the client
-- mirror receives a Remove op rather than the table quietly shrinking.
local applyArrayRemove: (Tree, { string | number }, SchemaNode?, number?, WriteOpts) -> any

-- Scribe.Big and Scribe.Flags are leaves whose stored form happens to be a table, and
-- every container mutation gates on the stored value being one: without this, Insert on
-- a big rewrites its mantissa pair and Clear leaves a non-Optional field nil. A
-- Scribe.SetOf is a real container, but Insert and positional writes bypass the dedupe
-- and ordering its stored form depends on, so it is refused too.
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
	-- Validation only: Tree.ApplyOp replays replicated Inserts with FromRemote and
	-- NoValidate, and a mirror momentarily ahead of the server must not throw
	-- mid-frame, which drops the frame and desyncs permanently.
	local validating = not opts.NoValidate and not opts.FromRemote
	if validating then
		refuseStructuralWrite(schema, path, "Insert")
		if schema and schema.Container == "Dict" then
			error(`Scribe: "{Util.pathString(path)}" is a Scribe.DictOf; write a key instead of calling Insert`, 0)
		end
		-- Ahead of the other refusals because the `math.clamp` below raises its own error
		-- on a non-number position, and a NaN or fractional position would silently write
		-- a hash-part index. The cost: `Insert(nil, "x")` names the position, not the nil.
		if pos ~= nil and (type(pos) ~= "number" or pos ~= pos or pos % 1 ~= 0) then
			error(`Scribe: Insert position must be an integer, got {tostring(pos)}`, 0)
		end
	end

	local pathKey = Util.pathKey(path)
	-- Read the existing array first (create = false, so nothing is materialized). The
	-- prospective index is needed up front so validation errors name the real element
	-- path, and the pre-creation value is what a rollback must restore, rather than an
	-- empty table. The MaxItems cap is applied further down, because with Evict it writes.
	local existingContainer, existingKey = resolveContainer(tree, path, false)
	local preValue = if existingContainer then existingContainer[existingKey] else nil
	local existingLength = if type(preValue) == "table" then #(preValue :: any) else 0
	local index = math.clamp(pos or existingLength + 1, 1, existingLength + 1)

	-- One decision read in two places, computed once so the two cannot drift. They sit
	-- on opposite sides of the other checks: the refusal (no Evict declared) belongs
	-- with the other refusals, the eviction belongs past all of them because it WRITES.
	local capped: SchemaNode? = if validating
			and schema ~= nil
			and schema.MaxItems ~= nil
			and existingLength >= schema.MaxItems
		then schema
		else nil

	if validating then
		if capped ~= nil and capped.Evict ~= "Front" and capped.Evict ~= "Back" then
			error(
				`Scribe: "{Util.pathString(path)}" already holds {existingLength} entries, `
					.. `at its MaxItems {capped.MaxItems}`,
				0
			)
		end
		if item == nil then
			error(`Scribe: cannot Insert nil into "{Util.pathString(path)}"`, 0)
		end
		-- Insert creates an array index, so it can mix an undeclared container just as a
		-- keyed write can, and it is the one path checkContainerKey never sees. Checked
		-- before validateWrite, seedMissingElements and ensureContainerValue, so a refusal
		-- leaves nothing materialized.
		if (schema == nil or schema.Container == nil) and type(preValue) == "table" then
			local blocker = mixedKeyBlocker(preValue, index)
			if blocker ~= nil then
				error(
					`Scribe: "{Util.pathString(path)}" already holds {blocker}, so Insert would make it a mixed `
						.. "array/hash table -- the DataStore drops half of one on save, and Set on the parent "
						.. "refuses the same shape. Use one key type for this container",
					0
				)
			end
		end
	end

	-- Validate the item BEFORE creating any container, so a rejected item can
	-- never leave a phantom container behind.
	local elementSchema = if schema then Template.ChildSchema(schema, index) else nil
	local elementPath = table.clone(path)
	table.insert(elementPath, index)
	-- Pass depth = #path: an inserted element sits one level below the array's own
	-- path, and the default under-budgets it by one, admitting an element the Init
	-- snapshot cannot re-encode and so dropping that client's whole root.
	local value = if opts.NoValidate
		then Util.deepClone(item)
		else validateWrite(tree, elementSchema, elementPath, item, #path)

	-- Only now, with the insert guaranteed to land, make room at the named end. Run any
	-- earlier and a REFUSED Insert on a full array would still drop the oldest entry,
	-- fire OnRemove and replicate a Remove, with no rollback outside a transaction.
	-- Nothing above here has written, so a refusal still materializes nothing.
	if capped ~= nil then
		-- Through the real remove path on purpose: a bare table.remove would shrink
		-- the server's array without emitting a Remove op, leaving every mirror one
		-- entry longer forever. The loop handles an array already over cap (a lowered
		-- MaxItems, or data predating it) rather than trimming one entry per Insert.
		local dropFront = capped.Evict == "Front"
		for _ = 1, existingLength - (capped.MaxItems :: number) + 1 do
			-- Recompute the tail index each pass: the array shrinks under us.
			local current = if type(preValue) == "table" then #(preValue :: any) else 0
			applyArrayRemove(tree, path, schema, if dropFront then 1 else current, opts)
		end
		-- Everything shifted down, so re-read rather than trusting the stale index.
		-- Rollback stays correct: applyArrayRemove snapshotted the pre-eviction array
		-- and snapshotForTxn keeps the first value per pathKey.
		existingContainer, existingKey = resolveContainer(tree, path, false)
		preValue = if existingContainer then existingContainer[existingKey] else nil
		existingLength = if type(preValue) == "table" then #(preValue :: any) else 0
		index = math.clamp(pos or existingLength + 1, 1, existingLength + 1)
	end

	-- Seed AFTER validation (a rejected item must not leave a phantom element),
	-- BEFORE the snapshot so intermediate declared elements replicate as real ops.
	seedMissingElements(tree, path, schema, opts)
	markDerivedDirty(tree, pathKey)
	snapshotForTxn(tree, path, pathKey, preValue)

	local arr = ensureContainerValue(tree, path, schema)
	-- Every element from `index` up shifts, so a listener bound to an element path is
	-- now looking at a different element. Snapshot before the shift and diff after.
	local descendantOlds = snapshotDescendants(tree, pathKey)
	table.insert(arr, index, value)

	emitOp(tree, { Kind = "Insert", Path = table.clone(path), Value = value, Index = index }, schema, opts)
	fire(tree, pathKey, "OnInsert", value, index)
	fireDescendants(tree, descendantOlds)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", arr, arr)
	end
	fireAncestors(tree, path)
	settleAfterWrite(tree)
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
	-- No argument means "the last element". An explicit index outside the array is a
	-- no-op, not a clamp: clamping turns an off-by-one or a stale index into a silent
	-- deletion of the wrong element.
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
	markDerivedDirty(tree, pathKey)
	snapshotForTxn(tree, path, pathKey, arr)
	-- The same shift as Insert, in the other direction.
	local descendantOlds = snapshotDescendants(tree, pathKey)
	local item = table.remove(arr, index)

	emitOp(tree, { Kind = "Remove", Path = table.clone(path), Index = index }, schema, opts)
	fire(tree, pathKey, "OnRemove", item, index)
	fireDescendants(tree, descendantOlds)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", arr, arr)
	end
	fireAncestors(tree, path)
	settleAfterWrite(tree)
	return item
end

local function applyClear(tree: Tree, path: { string | number }, schema: SchemaNode?, opts: WriteOpts)
	-- A Scribe.Flags and a Scribe.SetOf both clear legitimately to {}, so only the
	-- big is refused here.
	if not opts.NoValidate and not opts.FromRemote and schema and schema.ValueType == "big" then
		refuseStructuralWrite(schema, path, "Clear")
	end
	local container, key = resolveContainer(tree, path, opts.FromRemote == true, schema)
	local value = if container then container[key] else nil
	if type(value) ~= "table" then
		if not (opts.FromRemote and container) then
			return
		end
		-- A remote Clear implies the container existed server-side at emission, so if
		-- the op that created it was coalesced away, materialize it as {} to keep
		-- existence and Count() parity.
		value = {}
		container[key] = value
		noteKeyDelta(container, key, false, true)
	end
	local pathKey = Util.pathKey(path)
	-- Clear accepts any table node, a static record included, so this is the one
	-- non-Set path that can blank a derived input.
	markDerivedDirty(tree, pathKey)
	snapshotForTxn(tree, path, pathKey, value)
	local descendantOlds = snapshotDescendants(tree, pathKey)
	table.clear(value)
	noteContainerCleared(value)

	emitOp(tree, { Kind = "Clear", Path = table.clone(path) }, schema, opts)
	-- Bulk semantics: the parent Changed fires once and per-entry key events do not. A
	-- descendant leaf listener is not a per-entry event: its value really did change.
	-- Descendants come BEFORE the container's own state, the only order both paths can
	-- share: inside a batch the self fire is deferred to the flush and lands last anyway,
	-- so firing it first when unbatched gave one Clear two orders.
	fireDescendants(tree, descendantOlds)
	if not deferSelfState(tree, pathKey, path) then
		fire(tree, pathKey, "Changed", value, value)
	end
	fireAncestors(tree, path)
	settleAfterWrite(tree)
end

-- Recomputes every dirty derived field in the compiler's topological order, so a
-- field reading another derived field sees the settled value in the same sweep. Each
-- recompute writes through applySet, so an unchanged result costs nothing.
local function runSettle(tree: Tree)
	local ordered = tree.Compiled.DerivedNodes
	local devMode = tree.Params.DevMode == true
	local onIssue = tree.Params.OnDerivedIssue

	for _ = 1, MAX_SETTLE_PASSES do
		local dirty = tree._derivedDirty
		if dirty == nil then
			break
		end
		-- Sweeping `ordered` rather than the dirty set is what settles chains of any
		-- depth in ONE pass: a dependent sits after its inputs, so a mark laid down
		-- by the recompute above is still ahead of the cursor.
		for _, node in ordered do
			if dirty[node] then
				dirty[node] = nil
				local spec = node.Derived :: any
				local inputs = spec.Inputs
				local count = #inputs
				local values = table.create(count)
				for i, input in inputs do
					values[i] = DerivedModule.ReadForm(input, readValue(tree, input.Path :: any))
				end
				local ok, value = DerivedModule.Compute(node, values, count)
				Metrics.Add("DerivedRecomputes")
				if ok then
					if not spec.Transmit then
						-- The transmit rule, counted: a recompute that cost no bytes.
						Metrics.Add("DerivedOpsSuppressed")
					end
					applySet(tree, node.Path :: any, node, value, {
						-- Dev mode sends locally computed values too, so the client can
						-- compare and report an impure function. Production sends nothing.
						Replicate = spec.Transmit or devMode,
					})
				else
					Metrics.Add("DerivedErrors")
					-- Never rethrow: a Set on an input must not fail because a compute
					-- function has a typo. Logged once per field per tree, or the throw
					-- on every write evicts the ring holding the evidence.
					local logged = tree._derivedLogged
					if logged == nil then
						logged = {}
						tree._derivedLogged = logged
					end
					if onIssue and not (logged :: any)[node] then
						(logged :: any)[node] = true
						onIssue("DERIVED_ERROR", spec.Label, tostring(value))
					end
				end
			end
		end
		if next(dirty) == nil then
			tree._derivedDirty = nil
			break
		end
	end

	local leftover = tree._derivedDirty
	if leftover ~= nil then
		if onIssue then
			local names = {}
			for node in leftover do
				table.insert(names, (node.Derived :: any).Label)
			end
			table.sort(names)
			onIssue(
				"DERIVED_FEEDBACK",
				table.concat(names, ", "),
				`still dirty after {MAX_SETTLE_PASSES} passes: a listener keeps writing an input from inside the `
					.. "recompute it triggered"
			)
		end
		tree._derivedDirty = nil
	end
end

settleDerived = function(tree: Tree)
	if tree._derivedDirty == nil or tree._derivedSettling then
		return
	end
	-- The guard is cleared even when a recompute's write throws. Leaving it set would
	-- silently retire every derived field on this tree for the rest of the session.
	tree._derivedSettling = true
	local ok, err = pcall(runSettle, tree)
	tree._derivedSettling = false
	if not ok then
		error(err, 0)
	end
end

--- Compares each derived value the server sent this frame against the one this realm
--- computed, once the local recompute has run. A disagreement is an impure compute
--- function, which nothing else can detect.
local function runDerivedAudit(tree: Tree)
	local audit = tree._derivedAudit
	if audit == nil then
		return
	end
	tree._derivedAudit = nil
	local onIssue = tree.Params.OnDerivedIssue
	if onIssue == nil then
		return
	end
	for _, pending in audit do
		local mine = readValue(tree, pending.Path)
		if not Util.leafEquals(mine, pending.Server) then
			onIssue(
				"DERIVED_MISMATCH",
				pending.Label,
				`server computed {tostring(pending.Server)}, this realm computed {tostring(mine)}: the `
					.. "compute function is not pure (os.time / math.random / a realm-specific upvalue?)"
			)
		end
	end
end

-- Applies a whole frame's ops as ONE batch, so N ops under the same container give one
-- container Changed. The receiving half of Server.Batch: the server already coalesced
-- the batch into one frame. Leaf fires are untouched.
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
		-- One recompute per FRAME, not per op: the server already coalesced these
		-- ops into a single flush.
		settleDerived(self)
		runDerivedAudit(self)
		-- Flush even when an op threw: the ops before it landed, and a listener
		-- that never hears about them is worse than one that hears late.
		flushPendingAncestors(self)
	end
	if not ok then
		error(err, 0)
	end
end

--[=[
	Recomputes every derived field from current state, whatever the dirty set says.

	Used once per profile load, where the tree has just been pointed at real data
	that no write ever passed through: the session store still holds the compile-time
	defaults, which were computed from the template's defaults rather than from this
	player's values.
]=]
function Tree.SeedDerived(self: Tree)
	local ordered = self.Compiled.DerivedNodes
	if #ordered == 0 then
		return
	end
	local dirty = self._derivedDirty
	if dirty == nil then
		dirty = {}
		self._derivedDirty = dirty
	end
	for _, node in ordered do
		(dirty :: any)[node] = true
	end
	settleDerived(self)
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

	-- Purity audit. A locally computed derived field is not sent in production, so
	-- receiving one means the server is in dev mode and wants the two compared.
	--
	-- The comparison cannot happen HERE: this realm recomputes at the end of the frame,
	-- not per op, so reading the path now returns the pre-frame value, which differs on
	-- every derived op (one is emitted only when the value changed). Record the server's
	-- value and let runDerivedAudit compare once both realms have seen the same inputs.
	if exactSchema ~= nil and exactSchema.Derived ~= nil and not exactSchema.Derived.Transmit then
		if self.Params.OnDerivedIssue then
			local audit = self._derivedAudit
			if audit == nil then
				audit = {}
				self._derivedAudit = audit
			end
			(audit :: any)[#audit + 1] = {
				Path = table.clone(op.Path),
				Label = exactSchema.Derived.Label,
				Server = op.Value,
			}
		end
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
	-- Outside a frame the apply above settled derived itself, so the audit can run
	-- now. Inside one, ApplyOps runs it after the frame's single recompute.
	if self._batchDepth == 0 then
		runDerivedAudit(self)
	end
end

-- Runs `apply` with per-op fires suppressed, then fires Changed once per observed
-- path the mutation actually changed. A whole-container Set never fires descendants,
-- so a nested Observe registered before the mutation would miss its value. Used by
-- ReplayInit and edit-mode Mock. Cost is O(listeners), not O(data).
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
	-- Derived fields settle INSIDE the replay, with fires still suppressed, so their
	-- new values reach the single diff pass below instead of arriving as a second
	-- round of events. Only on success: a half-applied snapshot is not worth deriving.
	if ok then
		pcall(settleDerived, self)
		pcall(runDerivedAudit, self)
	end
	self._replaying = false -- always cleared, even if `apply` threw
	if not ok then
		error(err, 0)
	end
	-- Collect first (a fired listener may add or remove listeners), then fire.
	-- leafEquals is false for tables and buffers, so container observers always fire,
	-- matching a live whole-container Set; scalar leaves fire only on a real change.
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

-- Applies the initial snapshot, firing nested observers registered before Init. The
-- caller has already reset the mirror to defaults.
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
		-- Before the flush and before OnBatchEnd: one recompute for the whole batch,
		-- whose ops join the same replication frame as the writes that caused it.
		settleDerived(self)
		-- Listeners before replication, matching the unbatched ordering.
		flushPendingAncestors(self)
		local onBatchEnd: (() -> ())? = self.Params.OnBatchEnd
		if onBatchEnd then
			onBatchEnd()
		end
	end
	if not ok then
		error(err, 0)
	end
end

-- Register a pre-transaction value for a RAW store mutation, i.e. a write that does
-- not go through applySet (the _Scribe.Timed store, whose keys are full pathKeys
-- containing \31 that the accessor tree rejects). The first write to a key records
-- its pre-txn value for rollback; commits keep the write. No-op outside a transaction.
function Tree.RecordRawWrite(self: Tree, store: { [string]: any }, key: string)
	local txn = self._txn
	if not txn or txn.RawRestores[key] ~= nil then
		return
	end
	txn.RawRestores[key] = { Store = store, Value = store[key] }
end

-- The rollback half of RunTransaction. Its own function so the caller can pcall it
-- and still drain the queued fires when a restore or a recompute throws: a tree left
-- with `_fireQueue` set would go permanently silent.
local function rollbackTransaction(self: Tree, txn: any)
	-- Roll back every touched field to its pre-transaction value; listeners are told
	-- afterwards, in one drain.
	--
	-- Restores EMIT replication ops. A listener woken by the drain can write a field this
	-- txn also touched, and that write replicates, so only an emitted restore keeps the
	-- client's baseline equal to the server's. ORDERED, because those listener writes are
	-- neither snapshotted nor rolled back. Sorting does not stop the write; it makes the
	-- outcome the same every run, which Universe.Digest depends on outright.
	local ordered: { { Path: { string | number }, Value: any } } = {}
	local orderKeys: { [any]: string } = {}
	for pathKey, snapshot in txn.Snapshots :: { [string]: { Path: { string | number }, Value: any } } do
		ordered[#ordered + 1] = snapshot
		orderKeys[snapshot] = pathKey
	end
	-- Shallowest first, then by path key: if a snapshot pair is ever not disjoint, the
	-- ancestor must land before the descendant it contains, not be overwritten by it.
	table.sort(
		ordered,
		function(a: { Path: { string | number }, Value: any }, b: { Path: { string | number }, Value: any })
			if #a.Path ~= #b.Path then
				return #a.Path < #b.Path
			end
			return orderKeys[a] < orderKeys[b]
		end
	)
	for _, snapshot in ordered do
		local baseSchema, dynStart = Template.Resolve(self.Compiled, snapshot.Path)
		local exactSchema: SchemaNode? = baseSchema
		for i = dynStart, #snapshot.Path do
			exactSchema = if exactSchema then Template.ChildSchema(exactSchema, snapshot.Path[i]) else nil
		end
		applySet(self, snapshot.Path, exactSchema, snapshot.Value, {
			NoValidate = true,
		})
	end
	-- Restore raw store writes that bypassed applySet; a nil pre-txn value restores
	-- by removing the key.
	for key, restore in txn.RawRestores :: { [string]: { Store: { [string]: any }, Value: any } } do
		restore.Store[key] = restore.Value
	end
	-- Prune containers materialized during the transaction, deepest first, so no
	-- phantom empty tables survive. A created path covered by a snapshot is
	-- authoritative pre-txn state the restore just recreated: never prune those.
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
			-- No emptiness requirement: a path in Created did not exist before the
			-- transaction. Necessary too, since a declared element materializes from its
			-- defaults and so is never empty.
			if container ~= nil and type(container[key]) == "table" then
				-- Prune through applySet so the removal EMITS: a restore op beneath this
				-- created container has just materialized it on the client, and a silent
				-- raw removal would strand that phantom {} forever.
				local baseSchema, dynStart = Template.Resolve(self.Compiled, created[i])
				local exactSchema: SchemaNode? = baseSchema
				for j = dynStart, #created[i] do
					exactSchema = if exactSchema then Template.ChildSchema(exactSchema, created[i][j]) else nil
				end
				applySet(self, created[i], exactSchema, nil, { NoValidate = true })
			end
		end
	end
	-- The restores above settle as they go, since the transaction is closed by now.
	-- This is the backstop for a body that dirtied a field where every restore was a
	-- no-op, leaving marks unclaimed until the next unrelated write.
	settleDerived(self)
end

-- `onSeeded`, when given, is called on the COMMIT path with the path of every
-- declared container element this transaction materialized IMPLICITLY: a write
-- descended through a key that named no element. A deliberate whole-element Set is
-- not one of these. The receipt path uses it; see GRANT_SEEDED_ELEMENT.
function Tree.RunTransaction(
	self: Tree,
	fn: () -> (),
	onSeeded: ((seeded: { { string | number } }) -> ())?
): (boolean, string?)
	assertAlive(self)
	if self._txn then
		error("Scribe: transactions do not nest", 2)
	end
	-- Nor does a transaction on a DIFFERENT player nest inside this one, which is the
	-- shape a trade is written in. The guard above only sees one player's tree, and
	-- neither half of such a pair is atomic with the other: an outer throw after the
	-- inner commit mints value, an inner rollback under a committing outer destroys it.
	if OPEN_TXN_TREE ~= nil then
		error(
			`Scribe: a transaction is already open on another player, and transactions do not span players: `
				.. CROSS_TREE_TXN_WHY,
			2
		)
	end
	self._txn = { Snapshots = {}, Below = {}, Ops = {}, Created = {}, Seeded = {}, RawRestores = {}, Economy = {} }
	OPEN_TXN_TREE = self
	-- Everything already queued belongs to an enclosing batch, not to this
	-- transaction, so a rollback must leave it alone.
	local outerOrder = self._pendingAncestorOrder
	local pendingMark = if outerOrder then #outerOrder else 0
	-- RESTORED, not decremented, at the end. A Data.Batch opened inside `fn` raises the
	-- depth on `fn`'s coroutine, and closing that coroutine on the yield path does not
	-- unwind pending frames in Luau, so RunBatch's decrement dies with the stack.
	-- Decrementing only our own would strand the tree above zero, where
	-- flushPendingAncestors never runs and every container listener goes silent.
	local depthBefore = self._batchDepth
	self._batchDepth += 1
	-- Run fn in its OWN coroutine so a yield can be detected. Every write path absorbs
	-- into `self._txn` while it is set, so a concurrent write landing during a yield
	-- would be pulled into this transaction and rolled back with it, reverting a receipt
	-- grant and losing paid currency. Refuse the yield and roll back fn's writes so far.
	-- The inner xpcall preserves the original traceback for the non-yield case.
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
	-- Settle while the transaction is still open, so a recompute is journaled with the
	-- writes that caused it and commits or rolls back atomically with them.
	if ok then
		local settleOk, settleErr = pcall(settleDerived, self)
		if not settleOk then
			ok, err = false, tostring(settleErr)
		end
	end

	local txn = self._txn :: any
	self._txn = nil
	-- Cleared in lockstep with `_txn`, so the restores, the queued drain and the
	-- OnOp / OnEconomy / onSeeded callbacks all run outside the transaction.
	OPEN_TXN_TREE = nil
	self._batchDepth = depthBefore
	if not ok then
		discardPendingAncestors(self, pendingMark)
	end

	if ok then
		local onOp: ((op: Op, schema: SchemaNode?) -> ())? = self.Params.OnOp
		if onOp then
			for _, entry in txn.Ops :: { { Op: Op, Schema: SchemaNode? } } do
				onOp(entry.Op, entry.Schema)
			end
		end
		local onEconomy: ((path: { string | number }, delta: number, newValue: number, tags: { [string]: any }) -> ())? =
			self.Params.OnEconomy
		if onEconomy then
			for _, event in txn.Economy :: { { Path: { string | number }, Delta: number, New: number, Tags: any } } do
				onEconomy(event.Path, event.Delta, event.New, event.Tags)
			end
		end
		-- After the ops, so anything reported here describes journaled writes, and only on
		-- the committed path. pcall, unlike the two callbacks above, because this one is a
		-- DIAGNOSTIC and the transaction has already committed: a throw would skip
		-- flushPendingAncestors and surface as a failed grant, which Roblox retries into a
		-- double grant. OnOp and OnEconomy are load-bearing and stay unguarded.
		if onSeeded and #txn.Seeded > 0 then
			local reported = pcall(onSeeded, txn.Seeded :: { { string | number } })
			if not reported then
				warn("[Scribe] seeded-element reporter errored")
			end
		end
		if self._batchDepth == 0 then
			flushPendingAncestors(self)
			local onBatchEnd: (() -> ())? = self.Params.OnBatchEnd
			if onBatchEnd then
				onBatchEnd()
			end
		end
		return true, nil
	end

	-- Restores run with listener dispatch QUEUED rather than immediate (see `fire`), so
	-- the tree is whole before any listener sees it. A listener write made during the
	-- drain is an ordinary post-rollback write: it lands, emits, and is not rolled back.
	-- Rolling it back too would need an unbounded fixpoint, since undoing it re-fires
	-- the listener that wrote it.
	local queue: { { any } } = {}
	self._fireQueue = queue
	local rolledBack, rollbackErr = pcall(rollbackTransaction, self, txn)
	self._fireQueue = nil
	for _, entry in queue do
		local args = entry[3]
		fire(self, entry[1], entry[2], table.unpack(args, 1, args.n))
	end
	if not rolledBack then
		error(rollbackErr, 0)
	end
	return false, tostring(err)
end

function Tree.Destroy(self: Tree)
	self.Dead = true
	table.clear(self._listeners)
	-- _paths holds one entry per listened path, so leaving it behind would keep every
	-- path array alive on a tree destroyed with listeners still connected. Accessors
	-- need no equivalent sweep: the per-parent _children caches are weak-valued.
	table.clear(self._paths)
	table.clear(self._descendants)
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
	`Remove`/`Count`/…; `Scribe.Flags` fields add `Enable`/`Disable`; `Scribe.SetOf`
	fields add `Add`; `Scribe.Big` fields add `Multiply`/`Divide` and read back as
	[BigValue](bigvalue.md); `Scribe.Timed` fields add
	`SetTimed`/`ExtendTimed`/`Active`.
	On the client, `Set` writes are local-only (optimistic UI).

	!!! warning "Reserved names"
	    Because method names live on the node, a template field named `Get`, `Set`,
	    `Count`, `Remove`, etc. is unreachable through the typed accessor. Scribe
	    warns about this in Studio.

	!!! warning "Scribe's own `_Scribe` root is read-only to game code"
	    Every mutator is refused on a path inside the reserved `_Scribe` root, and a
	    read of it hands back a detached copy rather than the live table. That root is
	    Scribe's ledger, not your data. [Value.Set] says what it holds and which APIs
	    own it.

	!!! warning "The callable shorthand is not API"
	    A node is callable at runtime, so `data.Coins()` reads, `data.Coins(5)` writes
	    and `data.Coins(fn)` updates. The generated accessor type does not carry it, so
	    every such call site is a type error, and nothing tests it. Treat it as an
	    implementation detail and call `Get`, `Set` and `Update` by name.
]=]

--[=[
	@function Get
	@within Value
	@tag Core
	@return T
	Returns the field's current value. A datatype field comes back as the real
	datatype, unpacked from its stored buffer, and a [Scribe.Big] field comes back
	as a [BigValue](bigvalue.md) object rather than a number.

	A **table** field returns the stored table, not a copy, so mutating what `Get`
	hands you edits authoritative state with no validation, no replication and no
	`Changed`. Treat it as read-only, use [Value.Clone] for a copy you may edit, and
	write through the accessor at an index, not the plain entry a read handed back.

	Two reads are special. `Data[player].Get()`, with no field in front of it, returns
	a **frozen** table of exactly the roots your template declares. Scribe's own
	`_Scribe` root returns a detached deep copy, since that root refuses every write.

	An unmaterialized field reads `nil`: a [Scribe.DictOf] key nothing has written,
	or a [Scribe.Optional] field. [Value.Increment] and [Value.Toggle] start from the
	element's declared default on such a key, not from that `nil`.

	[Reading & Writing Values](../values.md) covers the live-table rule in full.
]=]

--[=[
	@function Set
	@within Value
	@tag Core
	@param value T
	@param replicate boolean?
	@return T
	Writes a new value (validated and clamped per the declarator). Fires `Changed`,
	replicates, and returns the stored value, which is not always the value you
	passed. Pass `replicate = false` to keep the write server-only.

	`Set(nil)` removes the field, except where that would store an unreadable shape:

	- a middle index of a [Scribe.ArrayOf], which punches a hole: `#arr` stops at the
	  gap and every replicated index below it shifts, so use [Value.Remove] (clearing
	  the tail is fine)
	- a declared, non-optional field of an element record, whose field set is closed:
	  wrap it in [Scribe.Optional] if absence is legitimate

	A whole-container `Set` on a [Scribe.ArrayOf] or [Scribe.DictOf] must match the
	declared key shape: contiguous integer keys from 1 for an array, string keys
	within `MaxKeyLength` for a dictionary, and no growth past `MaxItems` or
	`MaxKeys`. Omitted declared element fields fill from their defaults.

	Like every other mutator, `Set` is refused on any path inside Scribe's own
	`_Scribe` root, with an error naming the path; see the caution on this page.
]=]

--[=[
	@function Update
	@within Value
	@tag Core
	@param transform (current: T) -> T
	@param replicate boolean?
	@return T
	Reads the current value, passes it to `transform`, and writes the result: a
	convenient read-modify-write. Pass `replicate = false` to keep the write
	server-only.

	On a table field `transform` receives exactly what [Value.Get] returns, which is
	the **stored table, not a copy**. Mutating it in place edits authoritative state
	directly, and a transform that throws after mutating leaves that edit in the
	profile with no `Changed` fired and no replication op emitted, so it saves and
	every client mirror stays behind it. Build a new table and return that, or start
	from [Value.Clone]. A scalar field has none of this.

	[Reading & Writing Values](../values.md) has the WRONG and RIGHT pair.
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
	Like [Value.Observe] but fires only on change, with no initial call. Returns a
	disconnect function.

	On a **leaf** the callback gets the new and old values and fires once per write.
	On a **container** it reports state rather than a transition: `old` is the same
	reference as `new`, because the fire happens after the write and Scribe does not
	snapshot a container's prior contents. A container fire is also **coalesced**,
	one per [Server.Batch] and one per client replication frame, however many
	children moved. Use [Value.OnChildChanged] to learn which child moved.

	!!! warning "The container `key` argument was removed"
	    A container listener declaring a **third parameter errors at connect time**: one
	    fire now covers every child a batch or a frame touched, so naming one of them
	    would imply the others did not change. A node beneath an untyped `{}` subtree is
	    classified by what is stored there now, so connect after the container exists.

	[Reading & Writing Values](../values.md) puts the three container listeners side
	by side.
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

	`old` is a real prior value when the child is a **leaf**. When the child is itself
	a container, `old` is the same reference as `new`, the same caveat
	[Value.Changed] carries.

	Unlike `Changed` this is never coalesced: a batch writing three children fires it
	three times, and a child written twice fires it twice. Every ancestor of a write
	receives its **own** immediate child, so a write to `State.Inner.A` reports `A` to
	`State.Inner` and `Inner` to `State`. All of a container's `OnChildChanged` fires
	arrive before that container's `Changed`, batched or not.

	This is the only way to learn that an existing [Scribe.DictOf] key's **value**
	moved: [Value.OnKeyAdded] and [Value.OnKeyRemoved] report a key appearing or
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
	ending balance is the post-change value, and `TransactionType`, `ItemSku` and
	per-currency custom `Fields` come from the table. `Increment` defaults the flow
	to `Source`, and the amount logged is the effective change after clamping.

	**On a fresh container key the increment starts from the element's declared
	default, not from zero.** Emberfall declares its `Inventory` element as
	`Qty = Scribe.Int(1, { Min = 1, Max = 999 })`, so
	`data.Inventory.Emberblade.Qty.Increment(2)` materializes the entry and returns
	`3` rather than `2`. A [Scribe.Optional] leaf has no default to start from, so
	`Increment` on an absent one is an error, as it is on a non-number `amount` and
	on a field whose current value is not a number.
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
	@param nameOrReplicate (string | boolean)?
	@param replicate boolean?
	@return boolean
	Flips a boolean and returns its new value. Which argument it takes depends on
	the kind of field.

	On a plain **boolean** field it takes no name, and the optional first argument is
	`replicate`, so `Toggle(false)` flips the value and keeps the write server-only.

	On a **[Scribe.Flags]** field it takes the member name to flip, because the field
	holds a set of enabled names rather than one boolean:
	`data.Settings.Toggle("Sfx")`. Passing no name there is an error, since there is
	no single value to flip, and so is a name the template never declared.

	On a fresh container key the flip starts from the element's **declared default**,
	not from `false`, exactly as [Value.Increment] does for numbers. See
	[Reading & Writing Values](../values.md) for the whole flags surface.
]=]

--[=[
	@function Enable
	@within Value
	@tag Booleans
	@param name string
	@param replicate boolean?
	[Scribe.Flags] fields only. Turns the member called `name` on. Returns nothing.
	Pass `replicate = false` to keep the write server-only.

	A flags field is **one leaf** holding the set of enabled member names, not a
	container of booleans, so you address it by name and `Settings.Music.Set(true)`
	reaches for a child that does not exist. The stored value lists the enabled names
	in **declaration order**, not the order you enabled them, so two profiles holding
	the same flags hold the same table and diff cleanly.

	Enabling a member that is already on writes nothing at all: no `Changed`, no
	replication op, nothing to save. Enabling a name the template never declared is
	an error naming the field, and so is calling `Enable` on a field that is not a
	`Scribe.Flags`.

	See [Reading & Writing Values](../values.md) for the whole flags surface.
]=]

--[=[
	@function Disable
	@within Value
	@tag Booleans
	@param name string
	@param replicate boolean?
	[Scribe.Flags] fields only. Turns the member called `name` off. Returns
	nothing. The mirror of [Value.Enable], and it refuses the same two things: a
	name the template never declared, and a field that is not a `Scribe.Flags`.

	```lua
	data.Settings.Disable("Music")
	data.Settings.Has("Music")     --> false
	```

	Disabling a member that is already off writes nothing: no `Changed`, no
	replication op, nothing to save. That comes up more often than it looks,
	because every member of a flags field starts off, so a `Disable` on a brand
	new profile is always a no-op. [Value.Clear] turns every member off at once.
]=]

--[=[
	@function Add
	@within Value
	@tag Sets
	@param item T
	@param replicate boolean?
	@return boolean
	[Scribe.SetOf] fields only. Adds `item` to the set and returns `true`. If the set
	already holds it, nothing happens at all and you get `false` back: no write, no
	`Changed`, no replication op. That return value is the cheap way to answer "was
	this the first time", which is what a discovery reward needs.

	The stored form is kept deduplicated and sorted into a canonical order, so the
	value does not depend on the order members were added in.

	`Add(nil)` is an error, and so is `Add` on a field that is not a `Scribe.SetOf`.
	Growing past `MaxItems` is refused with an error before anything is written; a
	duplicate at the cap is still the ordinary no-op returning `false`. There is no
	[Value.Insert] on a set, and [Value.Remove] takes the member rather than an index.
]=]

--[=[
	@function Multiply
	@within Value
	@tag Big Numbers
	@param factor number | string | BigValue
	@param replicate boolean?
	@return BigValue
	[Scribe.Big] fields only. Multiplies the field by `factor` and returns the new
	stored value. `factor` may be a plain number, a numeric string like `"1.5e100"`,
	or another big value. Pass `replicate = false` to keep the write server-only.

	It reads, multiplies and writes the whole value back on the **ordinary write
	path**, so a declared `Min` or `Max` clamps the result, `Changed` fires, and the
	write replicates like any other. There is no economy-meta slot: the second
	argument is `replicate`, so a meta table passed there is read as that and ignored.

	Errors on a field that is not a `Scribe.Big`, on a `factor` that is not numeric,
	and on an absent [Scribe.Optional] big, which has no value to multiply.

	See [Big Numbers](../big-numbers.md) for the value object and
	[Reading & Writing Values](../values.md) for why this exists.
]=]

--[=[
	@function Divide
	@within Value
	@tag Big Numbers
	@param divisor number | string | BigValue
	@param replicate boolean?
	@return BigValue
	[Scribe.Big] fields only. Divides the field by `divisor` and returns the new
	stored value. The mirror of [Value.Multiply]: the same accepted operand types,
	the same write path, the same clamping and replication.

	```lua
	data.Essence.Divide(2)   --> 8.625e99, halved on a prestige reset
	```

	The quotient is not rounded, so a big field legitimately holds a fractional
	value. `Divide(3)` on a field holding 10 stores `3.33333333333333`, and that
	is what `Get()` and `tostring` give back.

	**Dividing by zero is an error naming the field, and nothing is written.**
	Storing the infinity a plain number would produce is worse than throwing,
	because an infinity does not survive the DataStore round trip and would come
	back as a corrupt profile. The other refusals match [Value.Multiply]: a field
	that is not a `Scribe.Big`, a non-numeric divisor, and an absent
	[Scribe.Optional] big.
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
	@return (T | boolean)?
	Three operations, chosen by the kind of field and then the argument's type.

	On an **array**, a **number** (or nothing) removes and returns the element at
	that index, or the last one, or `nil` if the array is empty. On a
	**[Scribe.DictOf]**, the argument is the key to delete, and its former value
	comes back. On a **[Scribe.SetOf]** the argument is the member itself, since a
	set has no positions, and the return is a **boolean**: `true` if it was a
	member, `false` if it was not, in which case nothing is written and no
	`Changed` fires.

	```lua
	data.Unlocked.Remove("AshfallRidge")   --> true, it was a member
	data.Unlocked.Remove("AshfallRidge")   --> false, nothing to do
	data.Unlocked.Remove(1)                --> false, an index is not a member
	```

	Outside the set case the returned value is unpacked, so a datatype element
	comes back as the real datatype rather than its stored buffer.
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
	[Scribe.DictOf]: use `Remove(key)`. On a [Scribe.SetOf], `Remove(member)` is
	already the by-value removal, so reach for that instead.
]=]

--[=[
	@function Find
	@within Value
	@tag Arrays & Dictionaries
	@param value T
	@return number?
	Array and [Scribe.SetOf] fields. The index of the first matching element, or
	`nil`.

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
	Whether `value` is present. Matching follows [Value.Find], including its error
	on a [Scribe.DictOf].

	This is the membership test for every list-shaped field, not just arrays:

	```lua
	data.Unlocked.Has("AshfallRidge")   --> true, a Scribe.SetOf member
	data.Settings.Has("Music")          --> true, a Scribe.Flags member
	```
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
	Array, dictionary and [Scribe.SetOf] fields. The number of elements, keys or
	members. A [Scribe.Flags] field answers with the number of members currently
	enabled. A field holding nothing yet counts `0` rather than erroring.
]=]

--[=[
	@function Clear
	@within Value
	@tag Arrays & Dictionaries
	@param replicate boolean?
	Removes every entry, leaving the container empty. Works on arrays,
	dictionaries and [Scribe.SetOf] fields, and on a [Scribe.Flags] field it turns
	every member off in one write.
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
	return rawget(accessor, F_SCHEMA) :: any
end

local function accessorTree(accessor: Accessor): Tree
	return rawget(accessor, F_TREE) :: any
end

local function accessorPath(accessor: Accessor): { string | number }
	return rawget(accessor, F_PATH) :: any
end

local function accessorKey(accessor: Accessor): string
	return rawget(accessor, F_KEY) :: any
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

-- Read-boundary unpack that also handles containers: one with packed descendants
-- comes back as a fresh table with every buffer and mantissa pair converted, so a
-- container read never leaks a stored shape. Unpacked subtrees are shared by
-- reference, and a container with nothing packed below returns unchanged.
local function unpackRead(schema: SchemaNode?, value: any): any
	-- A big is stored as { mantissa, exponent } and read as the object with
	-- arithmetic on it, the same split datatype fields use.
	if schema and schema.ValueType == "big" then
		return if value == nil then nil else Big.from(value)
	end
	if type(value) == "table" then
		if schema ~= nil and Template.IsPacked(schema) then
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
-- there may legitimately not exist yet, unlike static fields, which Reconcile
-- guarantees present.
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

-- Canonical packed form of a datatype, for comparison only. Packing is not
-- byte-canonical for every codec, so a value Get() handed out would not re-pack to the
-- bytes it came from; routing both sides through the same unpack+repack lands them on
-- one representative, which makes `Has(Get()[i])` work. `precision` must be the same on
-- both sides, hence threaded rather than defaulted.
local function canonicalDatatype(name: string, value: any, precision: (string | number)?): buffer?
	local packed: buffer
	if type(value) == "buffer" then
		packed = value
	elseif typeof(value) == name then
		local ok, result = pcall(Datatypes.Pack, name, value, precision)
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
	local repackOk, repacked = pcall(Datatypes.Pack, name, unpacked, precision)
	return if repackOk then repacked else packed
end

-- Structural equality between a STORED entry and a caller-supplied needle, resolved
-- through the element schema so packed datatype and big leaves compare by value.
local function entryEquals(schema: SchemaNode?, stored: any, needle: any): boolean
	if schema and schema.ValueType == "big" then
		-- The stored side is a { mantissa, exponent } pair and the needle is whatever a
		-- read handed back, so both go through Big.from; otherwise the pair-vs-object
		-- walk never matches and Has/Find/RemoveValue silently no-op.
		local a, b = Big.from(stored), Big.from(needle)
		return a ~= nil and b ~= nil and Big.compare(a, b) == 0
	end
	if schema and schema.ValueType == "datatype" then
		local name = schema.Datatype :: string
		local a = canonicalDatatype(name, stored, schema.Precision)
		local b = canonicalDatatype(name, needle, schema.Precision)
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

-- Element-aware `table.find`. A declared element is compared structurally, because
-- entries reach callers unpacked and copied, so identity never holds. Untyped
-- containers keep identity semantics, which existing code relies on.
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
		-- A raw buffer leaf must be copied, not aliased: buffers are mutable and Clone
		-- promises an independent value. A datatype leaf already became an immutable
		-- Roblox datatype above.
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

-- Is this accessor GAME CODE's handle on Scribe's own ledger? Shared by both
-- reserved-root guards: the write refusal in accessorIndex and the copy-on-read below.
-- Neither term can change for a given accessor, so callers evaluate this once when a
-- method is built.
local function isPublicReserved(accessor: Accessor): boolean
	return accessorPath(accessor)[1] == Template.RESERVED_ROOT and not PRIVILEGED[accessor]
end

-- The independent copy Clone() hands back: unpack-and-deep-clone when anything below
-- is packed, an ordinary deep clone otherwise. Shared with the reserved-root read
-- guard, which needs the identical value.
local function detachedCopy(schema: SchemaNode?, value: any): any
	if Template.IsPacked(schema) then
		return cloneUnpack(schema, value)
	end
	return Util.deepClone(value)
end

-- The read boundary. An ordinary read unpacks and hands back the live stored table by
-- reference, which is deliberate; a read of the reserved root BY GAME CODE hands back a
-- detached deep copy, or the write guard in accessorIndex is decorative and clearing the
-- ledger through a reader lets the next retried receipt grant twice. Deep, because the
-- ledger nests. Not table.freeze, which is permanent in Luau and would break the
-- library's own writes through Tree.Reserved.
local function readOut(guarded: boolean, schema: SchemaNode?, value: any): any
	if guarded and type(value) == "table" then
		return detachedCopy(schema, value)
	end
	return unpackRead(schema, value)
end

-- The whole-data value the ROOT accessor reads. Reading the store directly is wrong in
-- both directions: it carries Scribe's library-owned roots, which the declared type
-- never had, and it is only one of the two stores, so Session roots go missing. Building
-- from the DECLARED roots gives exactly the keys the template promises. Scribe's
-- internals stay reachable by indexing the accessor (`data._Scribe.Perks`).
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

-- Every root read hands back the same frozen shell, so Get, Observe and Changed
-- cannot disagree about what "all of the data" means.
local function frozenRootShell(tree: Tree): { [string]: any }
	return table.freeze(rootShell(tree, false))
end

-- A root Observe/Changed re-reads every root on every write, and a root holding a
-- datatype or a Scribe.Big must be rebuilt key by key to be read at all, so over a few
-- thousand packed elements one unrelated write costs milliseconds. The library cannot
-- make that cheap safely: skipping the rebuild means sharing one view, and that view
-- aliases live store tables. The fix belongs in the game, which should listen to the
-- container it cares about. Said once, in DevMode.
local ROOT_OBSERVE_WARN_NODES = 512
local warnedRootObserve: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function countNodes(value: any, budget: number): number
	if type(value) ~= "table" or budget <= 0 then
		return 1
	end
	local n = 1
	for _, child in value do
		n += countNodes(child, budget - n)
		if n >= budget then
			break
		end
	end
	return n
end

local function warnIfRootObserveIsExpensive(tree: Tree, what: string)
	if not tree.Params.DevMode or warnedRootObserve[tree] then
		return
	end
	local warnFn = tree.Params.LogWarn
	if warnFn == nil then
		return
	end
	local children = tree.Compiled.Root.Children
	if children == nil then
		return
	end
	for key, childSchema in children do
		if key ~= Template.RESERVED_ROOT and key ~= Template.SESSION_ROOT and Template.IsPacked(childSchema) then
			local nodes = countNodes(storeFor(tree, key)[key], ROOT_OBSERVE_WARN_NODES)
			if nodes >= ROOT_OBSERVE_WARN_NODES then
				warnedRootObserve[tree] = true
				warnFn(
					`a root {what} re-reads every root on every write, and "{key}" holds a datatype or `
						.. `Scribe.Big across {nodes}+ values, which must be unpacked each time. Listen to the `
						.. `container you care about instead (data.{key}.{what}) -- a container only fires for `
						.. "writes at or under it, so unrelated writes cost nothing. DevMode-only warning."
				)
				return
			end
		end
	end
end
-- Whether this node holds children, and so receives coalesced ancestor fires rather
-- than leaf transitions. The root always does; a dynamic node is judged by what is
-- stored there now, the best answer available at connect time.
local function isContainerNode(tree: Tree, schema: SchemaNode?, path: { string | number }): boolean
	if #path == 0 then
		return true
	end
	-- Kind == "any" is the pseudo-node Template synthesizes for an undeclared key
	-- under an untyped `{}` subtree. It is never nil, so testing `schema ~= nil`
	-- alone would classify every such node as a leaf and skip the check below.
	if schema ~= nil and schema.Kind ~= "any" then
		return schema.Kind == "table" or schema.Children ~= nil
	end
	return type(readValue(tree, path)) == "table"
end

local METHOD_FACTORIES: { [string]: (Accessor) -> any } = {}

-- Reads settle first, so a derived field never hands back a value its inputs have
-- moved past, inside a batch or mid-transaction alike. One nil compare when nothing
-- is dirty, which is the common case.
local function settleForRead(tree: Tree)
	if tree._derivedDirty ~= nil then
		settleDerived(tree)
	end
end

METHOD_FACTORIES.Get = function(accessor)
	local guarded = isPublicReserved(accessor)
	return function()
		local tree = accessorTree(accessor)
		assertAlive(tree)
		settleForRead(tree)
		local path = accessorPath(accessor)
		if #path == 0 then
			-- Frozen so `Get().Coins = 1` raises at the offending line. Unfrozen, it
			-- either edits authoritative state unvalidated or is silently discarded,
			-- depending only on whether the template declares a datatype anywhere.
			return frozenRootShell(tree)
		end
		return readOut(guarded, accessorSchema(accessor), readValue(tree, path))
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
		settleForRead(tree)
		local path = accessorPath(accessor)
		if #path == 0 then
			-- Deliberately NOT frozen: an editable copy is the point of Clone, and
			-- it is already detached from the store.
			return rootShell(tree, true)
		end
		-- detachedCopy deep-clones and unpacks together when anything below is packed,
		-- so the copy is independent and in its read shape.
		return detachedCopy(accessorSchema(accessor), readValue(tree, path))
	end
end

-- Flags helpers. Each reads the current set, edits it and writes the whole field
-- back, so a flag change is one validated, replicated write firing one Changed.
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

-- Scribe.SetOf membership. Both go through the whole-value write path, so
-- validateWrite's dedupe-and-sort maintains the invariant; these only decide
-- whether a write is needed at all.
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

-- Scribe.Big arithmetic. Each reads, applies the operation and writes the whole
-- field, so bounds, replication and the economy event run on the normal write path.
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
	-- A Nullable leaf has no default and is legitimately absent, so there is nothing to
	-- arithmetic against. Starting from 0 would contradict every other Scribe.Optional
	-- leaf, where Increment on an absent value errors.
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
		-- Same economy plumbing as a plain number, with arithmetic that does not
		-- lose the value at 2^53.
		local method = if defaultFlow == "Source" then "Increment" else "Decrement"
		local signed = bigOperand(accessor, method, delta)
		if defaultFlow == "Sink" then
			signed = Big.negate(signed)
		end
		local tags, replicate = parseIncrementArgs(tagsOrReplicate)
		local stored = Big.from(readValue(tree, path)) or Big.from(bigNode.Default)
		if stored == nil and bigNode.Nullable then
			validationError(path, `{method} on an absent Scribe.Optional value`)
		end
		local before: Big.Big = stored or BIG_ZERO
		local result = bigApply(accessor, method, signed, replicate, Big.add)
		if tags and tree.Params.OnEconomy then
			local after: Big.Big = Big.from(result) or BIG_ZERO
			-- Report the EFFECTIVE change so a Min/Max clamp does not over-report.
			-- LogEconomyEvent takes a double, so the conversion happens here;
			-- Big.toNumber saturates past the double range, which is lossy but
			-- reaches the log, unlike a table that Analytics' pcall would swallow.
			local effective = Big.sub(after, before)
			if Big.compare(effective, BIG_ZERO) ~= 0 then
				local applied = table.clone(tags)
				if applied.Flow == nil then
					applied.Flow = defaultFlow
				end
				local effectiveDelta = Big.toNumber(effective)
				local newValue = Big.toNumber(after)
				local txn = tree._txn
				if txn then
					table.insert(txn.Economy, { Path = path, Delta = effectiveDelta, New = newValue, Tags = applied })
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
		-- A declared element leaf not yet written starts from its compiled default
		-- rather than erroring, so `Resources.Wood.Increment(5)` on a fresh key
		-- yields 5. Scribe.Optional leaves have no default and keep erroring.
		if schema and type(schema.Default) == "number" and inElementSubtree(schema) then
			current = schema.Default
		end
	end
	if type(current) ~= "number" then
		validationError(path, `Increment on non-number value ({typeof(current)})`)
	end
	local tags, replicate = parseIncrementArgs(tagsOrReplicate)
	local newValue = applySet(tree, path, schema, current + delta, { Replicate = replicate }) :: number
	-- Report the EFFECTIVE change, not the requested delta: a bounded field may clamp
	-- or reject, so logging the raw delta over-reports and firing on a no-op logs a
	-- transaction the balance never made.
	local effectiveDelta = newValue - current
	if tags and tree.Params.OnEconomy and effectiveDelta ~= 0 then
		local applied = table.clone(tags)
		if applied.Flow == nil then
			applied.Flow = defaultFlow
		end
		local txn = tree._txn
		if txn then
			-- Deferred like replication ops: fired on commit, dropped on rollback,
			-- so a rolled-back Increment never logs a transaction.
			table.insert(txn.Economy, { Path = path, Delta = effectiveDelta, New = newValue, Tags = applied })
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
					`Decrement called with a negative delta at "{Util.pathString(accessorPath(accessor))}", likely a sign error`
				)
			end
		end
		return incrementImpl(accessor, delta, tagsOrReplicate, "Sink")
	end
end

-- Min/Max read the declarator's bounds off the static schema, so they work on both
-- realms and before data has loaded.
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

-- The declarator's default, straight off the static schema: a fresh datatype, a Big,
-- a deep copy for tables and buffers, or the scalar itself.
METHOD_FACTORIES.Default = function(accessor)
	return function(): any
		local schema = accessorSchema(accessor)
		if schema == nil then
			return nil
		end
		if Template.IsPacked(schema) then
			-- The stored Default holds the PACKED form, so deep-clone and unpack
			-- together, matching Clone(); a plain deepClone would hand back the
			-- stored shape.
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
	local guarded = isPublicReserved(accessor)
	return function(fn: (any, any) -> ())
		local tree = accessorTree(accessor)
		local schema = accessorSchema(accessor)
		local path = accessorPath(accessor)

		-- A container Changed takes no third `key` argument: one fire covers every
		-- child a batch or a frame touched, so no single key describes it. Refused at
		-- connect time rather than passing nil forever, which would make
		-- `if key == "Coins"` quietly stop matching. Arity is read once per connect.
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
			warnIfRootObserveIsExpensive(tree, "Changed")
			-- Match what Get hands back. The root's only fires are ancestor fires, where
			-- old and new are one reference, so a single shell serves both and a
			-- listener's `if new == old then return` holds.
			local inner = fn
			fn = function()
				local shell = frozenRootShell(tree)
				inner(shell, shell)
			end
			return connect(tree, path, "Changed", fn)
		end
		-- `guarded` joins IsPacked here because a listener is a reader: handed the live
		-- reserved table it could write through it, the same hole readOut closes on Get.
		if guarded or Template.IsPacked(schema) then
			local inner = fn
			fn = function(newValue, oldValue)
				local newUnpacked = readOut(guarded, schema, newValue)
				-- An ancestor container fire passes the SAME reference for new and old, so
				-- reuse the unpacked value: it skips a walk and keeps reference equality
				-- for a listener's `if new == old then return` guard.
				local oldUnpacked = if oldValue == newValue then newUnpacked else readOut(guarded, schema, oldValue)
				inner(newUnpacked, oldUnpacked)
			end
		end
		return connect(tree, path, "Changed", fn)
	end
end

METHOD_FACTORIES.Observe = function(accessor)
	local guarded = isPublicReserved(accessor)
	return function(fn: (any) -> ())
		local tree = accessorTree(accessor)
		assertAlive(tree)
		local schema = accessorSchema(accessor)
		local path = accessorPath(accessor)
		local isRoot = #path == 0
		if isRoot then
			warnIfRootObserveIsExpensive(tree, "Observe")
		end
		local disconnect = connect(tree, path, "Changed", function(newValue)
			fn(if isRoot then frozenRootShell(tree) else readOut(guarded, schema, newValue))
		end)
		local ok, err = xpcall(function()
			fn(if isRoot then frozenRootShell(tree) else readOut(guarded, schema, readValue(tree, path)))
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
		-- Branch on the SCHEMA, not the Lua type of the argument: a
		-- Scribe.MapOf("integer") takes number keys, and reading those as array indices
		-- would remove the wrong entry. The type fallback covers untyped nodes.
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
			-- Convert at the datatype boundary: a removed static datatype leaf is
			-- stored packed, so return the real value.
			return unpackRead(childSchema, old)
		end
		-- Same datatype boundary as the dictionary branch: an element of a
		-- Scribe.ArrayOf(Scribe.CFrame(...)) is stored packed, so returning it raw
		-- would hand the caller a buffer.
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

-- Value handed to an entry-level listener. Packed values are converted back and a
-- table is copied: the fired value IS the stored one, so a listener mutating it
-- would edit authoritative state with no validation and no replication.
local function entryValueForListener(guarded: boolean, schema: SchemaNode?, value: any): any
	-- Reserved root read by game code gets the same detached copy readOut hands back:
	-- the live `{ Id, At }` record would let a listener blank an Id and un-dedupe
	-- that purchase.
	if guarded and type(value) == "table" then
		return detachedCopy(schema, value)
	end
	if Template.IsPacked(schema) then
		return cloneUnpack(schema, value)
	end
	-- Only a DECLARED element is copied. An untyped container must keep handing out the
	-- stored reference, because Has/Find/RemoveValue fall back to table.find and a copy
	-- would make a listener's own entry unfindable.
	if schema and schema.IsElement and type(value) == "table" then
		return Util.deepClone(value)
	end
	return value
end

-- The listener kinds that receive a container ENTRY rather than the container itself,
-- and so need the same datatype conversion Changed and Observe do.
for _, event in { "OnInsert", "OnRemove", "OnKeyAdded", "OnKeyRemoved", "OnChildChanged" } do
	METHOD_FACTORIES[event] = function(accessor)
		local guarded = isPublicReserved(accessor)
		-- The root accessor's own path is empty, so isPublicReserved answers false for it,
		-- but these events carry a CHILD and one of the root's children IS the reserved
		-- root: without this, binding data.OnChildChanged hands game code the live ledger
		-- by reference. The PRIVILEGED term is unreachable today and stays, so a
		-- privileged root added later does not silently start receiving copies.
		local rootGuard = #accessorPath(accessor) == 0 and not PRIVILEGED[accessor]
		return function(fn: (...any) -> ())
			local tree = accessorTree(accessor)
			local schema = accessorSchema(accessor)
			local inner = fn
			local wrapped: (...any) -> ()
			if event == "OnInsert" or event == "OnRemove" then
				local element = elementSchemaOf(schema)
				wrapped = function(value: any, index: any)
					inner(entryValueForListener(guarded, element, value), index)
				end
			elseif event == "OnChildChanged" then
				-- Carries a transition, so both sides need unpacking. OnKeyAdded and
				-- OnKeyRemoved take a single value: an appearance has no prior and a
				-- disappearance has no successor.
				wrapped = function(key: any, newValue: any, oldValue: any)
					local childSchema = if schema then Template.ChildSchema(schema, key) else nil
					local g = guarded or (rootGuard and key == Template.RESERVED_ROOT)
					inner(
						key,
						entryValueForListener(g, childSchema, newValue),
						entryValueForListener(g, childSchema, oldValue)
					)
				end
			else
				wrapped = function(key: any, value: any)
					local childSchema = if schema then Template.ChildSchema(schema, key) else nil
					-- Same key-derived guard. Unreachable today, since the reserved root is
					-- created with the tree and never appears or disappears
					-- (RootChildLedgerGuard.spec pins that), but kept so the sibling wrappers
					-- do not differ for no reason.
					local g = guarded or (rootGuard and key == Template.RESERVED_ROOT)
					inner(key, entryValueForListener(g, childSchema, value))
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

-- Every method that mutates; all of them are refused on a derived field. Listed by
-- name rather than inferred, so a method added later has to make a deliberate choice
-- rather than silently becoming writable.
local MUTATOR_METHODS: { [string]: boolean } = {
	Set = true,
	Update = true,
	Increment = true,
	Decrement = true,
	Multiply = true,
	Divide = true,
	Toggle = true,
	Enable = true,
	Disable = true,
	Add = true,
	Insert = true,
	Remove = true,
	RemoveValue = true,
	Clear = true,
	SetTimed = true,
	ExtendTimed = true,
}

-- One module-private identity per mutator name, used as the rawset key its built
-- method is cached under. Private so nothing outside this file can name or plant a
-- cached mutator. See accessorIndex for why they are not cached under their own name.
local MUTATOR_CACHE_KEY: { [string]: any } = {}
for name in MUTATOR_METHODS do
	MUTATOR_CACHE_KEY[name] = {}
end

local function accessorIndex(accessor: Accessor, key: any): any
	local factory = METHOD_FACTORIES[key]
	if factory then
		if MUTATOR_METHODS[key] then
			-- A write to a DIFFERENT player's tree is refused while a transaction is open: it
			-- cannot be rolled back with the transaction, so one half of a trade could commit
			-- while the other is undone. Reads never enter this branch. The residual: a handle
			-- taken BEFORE the transaction opened (`local inc = other.Coins.Increment`) is not
			-- refused, since no index happens at the call. Gated on OPEN_TXN_TREE because
			-- pathString allocates; level 3 blames the game code that indexed the mutator.
			if OPEN_TXN_TREE ~= nil then
				assertSameTreeWrite(accessorTree(accessor), Util.pathString(accessorPath(accessor)), 3)
			end
			-- The reserved root is Scribe's own ledger, and ServerOnly only keeps it off the
			-- wire. Clearing ProcessedPurchaseIds makes the next retried receipt grant a
			-- second time; dropping Version re-runs every migration against migrated data.
			-- Refused by CALLER, not by object: the library writes these paths through
			-- Tree.Reserved, which holds the capability.
			local path = accessorPath(accessor)
			if path[1] == Template.RESERVED_ROOT and not PRIVILEGED[accessor] then
				error(
					`Scribe: "{Util.pathString(path)}" is inside the reserved "{Template.RESERVED_ROOT}" root `
						.. `and cannot be written; it is Scribe's own ledger -- processed receipt ids, perks, `
						.. `gift credits, pending gifts, purchase logs, timers and the schema version. Read it `
						.. `with the typed readers (Owns, GetGiftCredits, GetPurchases) and change it through `
						.. `the APIs that own it (GrantPerk, RevokePerk, Purchase, PromptGift)`,
					2
				)
			end
			local schema = accessorSchema(accessor)
			local derived = if schema then schema.Derived else nil
			if derived then
				local inputs = table.create(#derived.InputPaths)
				for i, segments in derived.InputPaths do
					inputs[i] = table.concat(segments, ".")
				end
				error(
					`Scribe: "{Util.pathString(accessorPath(accessor))}" is a derived field and cannot be written; `
						.. `it is computed from {table.concat(inputs, ", ")}`,
					2
				)
			end
			-- Cached under a module-private identity rather than under `key`, so every
			-- `x.Set` keeps going through __index and past the guards. A plain rawset under
			-- `key`, as the non-mutator branch below does, would be satisfied off the
			-- accessor table on the second read: harmless for the fixed refusals, wrong for
			-- the transaction one, which changes with the caller. Cache the method, not the
			-- decision.
			local cached = rawget(accessor, MUTATOR_CACHE_KEY[key])
			if cached ~= nil then
				return cached
			end
			local built = factory(accessor)
			rawset(accessor, MUTATOR_CACHE_KEY[key], built)
			return built
		end
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
	-- distinct path, corrupting coalescing, listeners and txn rollback.
	if type(key) == "string" and string.find(key, "\31", 1, true) then
		error("Scribe: dictionary keys may not contain control character \\31", 2)
	end
	-- Invalid UTF-8 in a dynamic key fails the DataStore save for the entire profile.
	-- Rejected here so the error points at the offending index, not a later save.
	if type(key) == "string" and not Util.isUtf8(key) then
		error("Scribe: dictionary keys must be valid UTF-8", 2)
	end
	-- Fractional or non-finite numeric keys do not survive the DataStore JSON round
	-- trip, which would diverge the stored key from its pathKey and listeners.
	if type(key) == "number" and (key ~= key or key == math.huge or key == -math.huge or key % 1 ~= 0) then
		error(`Scribe: numeric dictionary keys must be finite integers, got {tostring(key)}`, 2)
	end

	local children = rawget(accessor, F_CHILDREN) :: { [any]: any }
	local child = children[key]
	if child == nil then
		local schema = accessorSchema(accessor)
		-- Kind alone is not enough: Scribe.Big and Scribe.Flags compile as Kind
		-- "table" because their stored form is one, so indexing them would let
		-- `Tutorial[1].Set(...)` overwrite an enabled flag in place.
		if schema and (schema.Kind == "leaf" or schema.ValueType == "big" or schema.ValueType == "flags") then
			error(`Scribe: "{Util.pathString(accessorPath(accessor))}" is a leaf value and has no children`, 2)
		end
		local path = table.clone(accessorPath(accessor))
		table.insert(path, key)
		local childSchema = if schema then Template.ChildSchema(schema, key) else nil
		-- A declared element record has a fixed field set, so an undeclared key is a
		-- typo. Refusing it HERE is load-bearing: a nil child schema reads as untyped
		-- everywhere downstream, so a write under a misspelled field would bypass
		-- MaxKeys, MaxItems, MaxKeyLength and the array contiguity rule entirely.
		if childSchema == nil and schema and schema.Closed then
			error(
				`Scribe: "{tostring(key)}" is not a declared field of the element shape at `
					.. `"{Util.pathString(accessorPath(accessor))}"`,
				2
			)
		end
		-- The capability follows the HANDLE down, so Tree.Reserved.Perks.VIP may
		-- write and Accessor[RESERVED_ROOT].Perks.VIP may not.
		child = newAccessor(tree, path, childSchema, PRIVILEGED[accessor])
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
	-- `node(nil, nil)` is what a generalized `for` used to produce before __iter
	-- existed, and it reaches Set(nil) which deletes the node. A deliberate clear is
	-- `node.Set(nil)` with one argument; two nils is never intentional.
	if n == 2 and first == nil and select(2, ...) == nil then
		error("Scribe: accessor(nil, nil) would delete this node; use Set(nil) if that is what you mean", 2)
	end
	return accessor.Set(...)
end

-- Without __iter, a generalized `for` falls back to __call and invokes it as the
-- iterator with two nil arguments, which reaches `accessor.Set(nil, nil)` and DELETES
-- the node. The loop body never runs, so `for k, v in data.Inventory do` reads as a
-- no-op and silently destroys the container, then replicates and persists the deletion.
local function accessorIter(): ()
	error(
		"Scribe: an accessor is not iterable. Iterate the value instead: "
			.. "`for key, entry in data.Inventory.Get() do` (read-only) or `.Clone()` for a table you may edit",
		2
	)
end

ACCESSOR_MT = {
	__index = accessorIndex,
	__call = accessorCall,
	__iter = accessorIter,
}

Node.METHOD_NAMES = {} :: { [string]: boolean }
for name in METHOD_FACTORIES do
	Node.METHOD_NAMES[name] = true
end

-- The canonical write set, exported so a guard's spec can iterate it rather than
-- hand-list it, and a mutator added later is covered without editing the spec.
Node.MUTATOR_METHODS = table.freeze(MUTATOR_METHODS)

--- The cross-tree transaction refusal, for a writer that bypasses the accessor tree.
--- Server/Timed writes the flat `_Scribe.Timed` store directly, so this export is the
--- only way it can enforce the same rule with the same sentence.
Node.AssertSameTreeWrite = assertSameTreeWrite

--- The pathKey of an accessor. Exported because the accessor's fields are keyed by
--- module-private identities no other module can name.
function Node.PathKeyOf(accessor: any): string
	return rawget(accessor, F_KEY) :: any
end

-- Deep-clone a value while unpacking every declared datatype descendant. Exposed for
-- the client's Shared mirror, which stores the packed wire form but has no accessor
-- tree to convert it on read.
Node.CloneUnpack = cloneUnpack

return Node
