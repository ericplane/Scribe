--!strict
-- Checks a stored profile against the compiled template. Read-only and free of
-- policy: it reports violations, and Persistence alone decides what one costs.
--
-- The walk is data-driven, not schema-driven. Walking the schema would flag every
-- field a profile predates, which Reconcile backfills moments later; walking the
-- data finds values that are the wrong shape, which is what corruption looks like.
--
-- Stored form is not read form for three value types, and checking the read form
-- would reject every healthy profile:
--   datatype  a packed buffer, not a CFrame/Vector3/...
--   big       a {mantissa, exponent} pair, not a number. Its Min/Max are ordered
--             with Big.compare, not `<`, because a bound past the double range can
--             only be written as a numeric string.
--   flags     a sorted array of member-name strings, not a set

local Big = require(script.Parent.Big)
local Template = require(script.Parent.Template)
local Util = require(script.Parent.Util)

local Conform = {}

-- Matches Util.findUnpersistable's cap. Stored data arrives from a datastore, not
-- from the accessor tree, so it can be cyclic or absurdly deep.
local MAX_DEPTH = 64

-- A corrupt profile can have a million bad leaves, so the walk stops at the cap
-- rather than traversing on and merely declining to record.
local DEFAULT_LIMIT = 32

export type Kind =
	"WrongType" -- the value is not the type the schema declares
	| "OutOfBounds" -- numeric, outside Min/Max
	| "OverMaxLength" -- past a declared size cap: MaxLength, MaxItems, MaxKeys, MaxKeyLength
	| "NotAMember" -- enum/flags value is not in Members
	| "BadEncoding" -- a string that is not valid UTF-8; would fail the save
	| "UnknownKey" -- a key a closed record does not declare

--- Advisory: report it, but never end a session over it, not even under
--- SchemaPolicy = "Reject". Set on the six container findings and nothing else.
---
--- A flag rather than a `Kind`, because `Kind` says what is wrong and this says
--- what policy applies: "OverMaxLength" covers both a string past `MaxLength`,
--- which rejects, and a container past `MaxItems`, which advises.
---
--- The mixed array/hash table is the one container finding that is not advisory:
--- it fails the DataStore save of the whole profile, so ending the session
--- preserves data that would otherwise be lost silently. The rest save fine (JSON
--- stores a sparse array as an object) and ordinary gameplay code can produce
--- them, so kicking over one strands the player on every rejoin.
export type Violation = {
	Path: { string | number },
	Kind: Kind,
	Detail: string,
	Advisory: boolean?,
}

type Walk = {
	Violations: { Violation },
	Limit: number,
	Full: boolean,
}

local function record(walk: Walk, path: { string | number }, kind: Kind, detail: string, advisory: boolean?)
	if #walk.Violations >= walk.Limit then
		walk.Full = true
		return
	end
	table.insert(walk.Violations, { Path = table.clone(path), Kind = kind, Detail = detail, Advisory = advisory })
end

--- Check one leaf against its schema, in the form it is stored in.
local function checkLeaf(walk: Walk, node: Template.SchemaNode, value: any, path: { string | number })
	local expected = node.ValueType

	if expected == "datatype" then
		-- Packed at write time; a stored CFrame table means someone wrote raw.
		if typeof(value) ~= "buffer" then
			record(
				walk,
				path,
				"WrongType",
				`expected a packed buffer for {tostring(node.Datatype)}, got {typeof(value)}`
			)
		end
		return
	end

	if expected == "big" then
		if type(value) ~= "table" or type((value :: any)[1]) ~= "number" or type((value :: any)[2]) ~= "number" then
			record(walk, path, "WrongType", `expected a {"{"}mantissa, exponent{"}"} pair, got {typeof(value)}`)
			return
		end
		-- Ordered through Big.compare, not `<`: a bound past 1.8e308 has to be
		-- declared as a numeric string, and comparing that against a number throws
		-- while comparing two strings orders them lexically.
		local stored = Big.from(value)
		if stored == nil then
			-- Both halves are numbers and at least one is not finite, so nothing can
			-- be ordered against it.
			record(walk, path, "WrongType", "mantissa/exponent pair is not finite")
			return
		end
		-- Guarded on the parse rather than assumed: this walk runs on the load path
		-- over untrusted stored data, so it must never throw.
		if node.Min ~= nil then
			local floor = Big.from(node.Min)
			if floor ~= nil and Big.compare(stored, floor) < 0 then
				record(walk, path, "OutOfBounds", `{Big.toString(stored)} is below Min {Big.toString(floor)}`)
				return
			end
		end
		if node.Max ~= nil then
			local ceiling = Big.from(node.Max)
			if ceiling ~= nil and Big.compare(stored, ceiling) > 0 then
				record(walk, path, "OutOfBounds", `{Big.toString(stored)} is above Max {Big.toString(ceiling)}`)
			end
		end
		return
	end

	if expected == "flags" then
		if type(value) ~= "table" then
			record(walk, path, "WrongType", `expected an array of flag names, got {typeof(value)}`)
			return
		end
		local index = node.MemberIndex
		if index ~= nil then
			for _, name in value :: { any } do
				if type(name) ~= "string" or index[name] == nil then
					record(walk, path, "NotAMember", `{tostring(name)} is not a declared flag`)
					return
				end
			end
		end
		return
	end

	if expected == "boolean" then
		if type(value) ~= "boolean" then
			record(walk, path, "WrongType", `expected boolean, got {typeof(value)}`)
		end
		return
	end

	if expected == "number" or expected == "int" then
		if type(value) ~= "number" then
			record(walk, path, "WrongType", `expected {expected}, got {typeof(value)}`)
			return
		end
		if value ~= value then
			-- NaN survives a JSON round trip in some encoders and poisons every
			-- comparison downstream, so it is called out separately.
			record(walk, path, "WrongType", "value is NaN")
			return
		end
		if expected == "int" and value % 1 ~= 0 then
			record(walk, path, "WrongType", `expected an integer, got {value}`)
			return
		end
		if node.Min ~= nil and value < node.Min then
			record(walk, path, "OutOfBounds", `{value} is below Min {node.Min}`)
		elseif node.Max ~= nil and value > node.Max then
			record(walk, path, "OutOfBounds", `{value} is above Max {node.Max}`)
		end
		return
	end

	if expected == "enum" then
		if type(value) ~= "string" then
			record(walk, path, "WrongType", `expected an enum member name, got {typeof(value)}`)
			return
		end
		if node.MemberIndex ~= nil and node.MemberIndex[value] == nil then
			record(walk, path, "NotAMember", `"{value}" is not a declared member`)
		end
		return
	end

	if expected == "string" then
		if type(value) ~= "string" then
			record(walk, path, "WrongType", `expected string, got {typeof(value)}`)
			return
		end
		if not Util.isUtf8(value) then
			-- An invalid-UTF-8 string fails the whole profile save with a DataStore
			-- 104, so one bad byte stops every future write.
			record(walk, path, "BadEncoding", "string is not valid UTF-8; this will fail the save")
			return
		end
		if node.MaxLength ~= nil and #value > node.MaxLength then
			record(walk, path, "OverMaxLength", `{#value} bytes exceeds MaxLength {node.MaxLength}`)
		end
		return
	end

	if expected == "buffer" then
		if typeof(value) ~= "buffer" then
			record(walk, path, "WrongType", `expected buffer, got {typeof(value)}`)
		end
		return
	end

	-- "any" and "table" accept whatever is there; a table recurses below.
end

--- Does this table mix array indices with string keys?
---
--- Runs on every table the walk reaches, not just declared containers: JSON has no
--- encoding for the shape, so one mixed table fails the save of the whole profile,
--- opaquely and far from whatever wrote it. The write path refuses it, but data
--- from the datastore, a migration, an UpdateOffline draft or an OnPlayerInit hook
--- never passed through there.
local function mixesKeyTypes(value: { [any]: any }): boolean
	local hasNum, hasStr = false, false
	for key in value do
		local kt = type(key)
		hasNum = hasNum or kt == "number"
		hasStr = hasStr or kt == "string"
		if hasNum and hasStr then
			return true
		end
	end
	return false
end

--- Container shape and caps, for a node that declares one.
---
--- The write path tolerates a container already over cap in storage and refuses
--- only growth past the stored size, since a rolling deploy can put a newer
--- server's larger container in front of an older server's lower cap. This check
--- has no stored size to compare against: it is the stored size. So it reports an
--- over-cap container even though a write to it would be allowed, and that is why
--- every finding here is advisory. See the note on Violation.Advisory.
---
--- `Container` is nil on untyped bags: an undeclared `{}` has no key shape and no
--- caps, and measuring it would report every bag that happens to hold an array.
local function checkContainer(walk: Walk, node: Template.SchemaNode, value: any, path: { string | number })
	local container = node.Container
	if container == nil then
		return
	end

	local count = 0
	local maxIndex = 0
	local badIndex = false
	-- A Scribe.MapOf("integer") is numerically keyed and its keys are back in numeric
	-- form by now (Template.CoerceMapKeys runs first), so MaxKeyLength, a byte cap on
	-- a string key, does not apply. Same test the write path makes.
	local maxKeyLength = if node.KeyType ~= "integer" then node.MaxKeyLength else nil

	for key in value :: { [any]: any } do
		count += 1
		if container == "Array" then
			if type(key) ~= "number" then
				-- What a hole looks like after a datastore round trip: JSON cannot
				-- express a sparse array, so the encoder writes an object and the decode
				-- hands back "1"/"3" instead of 1/3.
				record(
					walk,
					path,
					"WrongType",
					`Scribe.ArrayOf takes array entries, but "{tostring(key)}" is a string key`,
					true
				)
				badIndex = true
			elseif key % 1 ~= 0 or key < 1 then
				record(walk, path, "WrongType", `array index {key} is not a positive integer`, true)
				badIndex = true
			elseif key > maxIndex then
				maxIndex = key
			end
		elseif maxKeyLength ~= nil and type(key) == "string" and #key > maxKeyLength then
			record(walk, path, "OverMaxLength", `key "{key}" is {#key} bytes, over MaxKeyLength {maxKeyLength}`, true)
		end
	end

	if container == "Array" then
		-- `#value` stops at the first hole, so compare the entry count against the
		-- highest index instead: a ragged array always has maxIndex > count. Skipped
		-- once a bad index has been reported, since maxIndex is then meaningless.
		if not badIndex and count ~= maxIndex then
			record(
				walk,
				path,
				"WrongType",
				`array entries must run contiguously from 1 (no holes): {count} entries, highest index {maxIndex}`,
				true
			)
		end
		local maxItems = node.MaxItems
		if maxItems ~= nil then
			-- A set is stored deduplicated, so its cap is on membership. Counting raw
			-- entries would report a stored set whose membership fits.
			local effective = count
			if node.Unique then
				local seen: { [any]: boolean } = {}
				effective = 0
				for _, item in value :: { any } do
					if not seen[item] then
						seen[item] = true
						effective += 1
					end
				end
			end
			if effective > maxItems then
				record(walk, path, "OverMaxLength", `holds {effective} entries, over MaxItems {maxItems}`, true)
			end
		end
	else
		local maxKeys = node.MaxKeys
		if maxKeys ~= nil and count > maxKeys then
			record(walk, path, "OverMaxLength", `holds {count} keys, over MaxKeys {maxKeys}`, true)
		end
	end
end

local function walkNode(walk: Walk, node: Template.SchemaNode, value: any, path: { string | number }, depth: number)
	if walk.Full then
		return
	end
	if depth > MAX_DEPTH then
		record(walk, path, "WrongType", `nesting exceeds {MAX_DEPTH} levels`)
		return
	end

	-- A nil is a field the profile does not carry yet. Reconcile backfills those, so
	-- absence is never a violation.
	if value == nil then
		return
	end

	-- Dispatch on what the field is, not on what its default happened to be. `Kind`
	-- records only whether the declared default was a table, and it disagrees with
	-- `ValueType` in two places, both of which reported healthy profiles as corrupt:
	--
	--   flags  defaults to `{}`, so Kind is "table", but the stored form is an array
	--          of member names.
	--   any    the child ChildSchema synthesises for an undeclared key carries no
	--          schema, which is what makes untyped bags work.
	if node.Kind == "leaf" or node.ValueType == "flags" or node.ValueType == "any" then
		checkLeaf(walk, node, value, path)
		return
	end

	if type(value) ~= "table" then
		record(walk, path, "WrongType", `expected a table, got {typeof(value)}`)
		return
	end

	-- Reported and then abandoned, not descended into: nothing under a table the
	-- datastore cannot encode can be acted on until the table itself is repaired,
	-- and a finding per leaf would crowd out the rest of the report at the cap.
	if mixesKeyTypes(value) then
		record(walk, path, "WrongType", "table mixes array indices and string keys; this will fail the DataStore save")
		return
	end
	checkContainer(walk, node, value, path)

	for key, child in value :: { [any]: any } do
		if walk.Full then
			return
		end
		if type(key) ~= "string" and type(key) ~= "number" then
			record(walk, path, "UnknownKey", `key of type {typeof(key)} cannot be stored`)
			continue
		end

		local childSchema = Template.ChildSchema(node, key)
		table.insert(path, key)
		if childSchema == nil then
			-- Only reachable on a Closed record. Everywhere else ChildSchema
			-- synthesises an `any` child, which is what makes untyped bags work, so
			-- an unknown key is undetectable outside a closed shape.
			record(walk, path, "UnknownKey", `"{tostring(key)}" is not declared on this record`)
		else
			walkNode(walk, childSchema, child, path, depth + 1)
		end
		table.remove(path)
	end
end

--- Every way `data` fails to match `compiled`, up to `limit` findings.
---
--- An empty result means the stored shape is consistent with the template, not
--- that the data is correct.
function Conform.Check(compiled: Template.Compiled, data: { [string]: any }, opts: { Limit: number? }?): { Violation }
	local walk: Walk = {
		Violations = {},
		Limit = if opts and opts.Limit then opts.Limit else DEFAULT_LIMIT,
		Full = false,
	}
	if type(data) ~= "table" then
		return { { Path = {}, Kind = "WrongType" :: Kind, Detail = `profile is {typeof(data)}, not a table` } }
	end

	local root = compiled.Root
	if root.Children == nil then
		return walk.Violations
	end

	for name, child in root.Children do
		-- Session subtrees are never stored, so a stored copy of one is stale rather
		-- than corrupt.
		if child.Persist then
			local path: { string | number } = { name }
			walkNode(walk, child, data[name], path, 1)
		end
	end
	return walk.Violations
end

Conform.MAX_DEPTH = MAX_DEPTH
Conform.DEFAULT_LIMIT = DEFAULT_LIMIT

return Conform
