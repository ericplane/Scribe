--!strict
-- The total-apply primitive for ClaimExchange: moves value off a declared path into the
-- owner's reserved root and later back onto a declared path, proving every step from a
-- return value AND a post-mutation re-read. Never Increment, Decrement or a bare Insert:
-- those can no-op or clamp and still report success.
--
-- Three invariants close the ways both proofs pass on a write that did nothing:
--   I1 NO-OP INTERLOCK. An intended post-state equal to the current state is refused.
--   I2 VACANCY. A credit lands only on a destination proved absent.
--   I3 SOLVENCY. A quantity leg never drives a balance below its declared floor, and a
--      path with no floor is not exchangeable.
--
-- Escrow and Deliver return RunTransaction's (ok, err). pcall false is INDETERMINATE:
-- reconcile, never retry blind. pcall true with ok false is reverted; ok true committed.
--
-- PRECONDITION: no listener on this tree may write or yield from a change handler.
-- OnChildChanged is not deferred, so it fires inside the settle transaction, where a
-- yield becomes a rollback and a write during the drain lands and stays.

local Clock = require(script.Parent.Clock)
local Template = require(script.Parent.Template)
local Util = require(script.Parent.Util)
local Big = require(script.Parent.Big)

local ExchangeLeg = {}

local RESERVED = Template.RESERVED_ROOT
local MAX_SAFE = 9007199254740992

export type Leg = {
	Path: { string | number },
	Kind: string, -- "Key", "Qty" or "Stack"
	Key: any?, -- Key and Stack legs: dict key, set member, or array value
	Amount: number?, -- Qty and Stack legs
	Value: any?, -- filled by Escrow with the PACKED payload
}

--- The declared rules for one exchangeable path, resolved once at startup.
---
--- Held on `ctx.Plans` rather than on the leg: a parked delivery can outlive the server
--- that staked it, and config in the record is config a later fix cannot reach.
export type Plan = {
	Count: string?, -- Stack: the counting element field. nil when the element IS the count.
	Ignore: { [string]: true }, -- fields that do not travel with the item
}

--- Raise with the module's prefix. Level 0 because a leg failure is about the exchange,
--- not about the line inside this module that noticed it.
local function fail(message: string): never
	error(`ExchangeLeg: {message}`, 0)
end

--- Prove a value is present, and return it, so the guard narrows. Luau does not treat a
--- call to `fail` as terminating a branch even though it is declared `never`, so after a
--- plain `if x == nil then fail(...) end` the value is still optional to the checker.
local function present<T>(value: T?, message: string): T
	if value == nil then
		fail(message)
	end
	return value :: T
end

--- Walk to a schema node without Template.Resolve, which returns the deepest static
--- ANCESTOR rather than nil and so lets a typo resolve to a parent.
local function resolveStrict(compiled: any, path: { string | number }): any
	local node = compiled.Root
	for index, segment in path do
		if node == nil or node.Kind == "leaf" then
			fail(`path "{Util.pathString(path)}" descends through a leaf at "{segment}"`)
		end
		node = present(
			Template.ChildSchema(node, segment),
			`path "{Util.pathString(path)}" has no declared field "{segment}"`
		)
		-- A synthesized AnyChild is what an undeclared key resolves to. Accepting it
		-- would make every misspelling a valid path.
		if node.Kind == "any" and node.IsElement ~= true then
			fail(`path "{Util.pathString(path)}" segment {index} ("{segment}") is not a declared field`)
		end
	end
	return node
end

--- The stored parent table and key for a path, with no accessor and no unpack.
--- LiveData only: a non-persisted root is refused at registration, so routing to the
--- session store here would contradict that refusal.
local function rawStore(ctx: any, path: { string | number }): (any, any)
	local parent = ctx.Entry.LiveData
	for index = 1, #path - 1 do
		if type(parent) ~= "table" then
			return nil, nil
		end
		parent = parent[path[index]]
	end
	if type(parent) ~= "table" then
		return nil, nil
	end
	return parent, path[#path]
end

--- Deep equality that understands buffers, which is what a packed datatype is.
local function packedEquals(a: any, b: any): boolean
	if type(a) == "buffer" or type(b) == "buffer" then
		return type(a) == "buffer" and type(b) == "buffer" and Util.bufferEquals(a, b)
	end
	if type(a) == "table" and type(b) == "table" then
		for key, value in a do
			if not packedEquals(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	return a == b
end

--- The accessor at a declared path, indexed fresh. Never cached and never passed across
--- a transaction boundary: a handle taken before the transaction opened escapes the
--- cross-tree guard (Node.luau:4370-4374).
local function accessorAt(ctx: any, path: { string | number }): any
	local accessor = ctx.Tree.Accessor
	for _, segment in path do
		local ok, child = pcall(function()
			return accessor[segment]
		end)
		if not ok or child == nil then
			fail(`no accessor at "{Util.pathString(path)}"`)
		end
		accessor = child
	end
	return accessor
end

--- One numeric comparison path for every shape, so no relational operator is ever
--- applied to a value read through an accessor.
local function compareNumbers(a: any, b: any): number
	local message = `cannot compare "{tostring(a)}" and "{tostring(b)}" numerically`
	local left = present(Big.from(a), message)
	local right = present(Big.from(b), message)
	return Big.compare(left, right)
end

--- Which container declarator a node is. ArrayOf and SetOf share Container "Array"
--- and are told apart by Unique.
local function containerKindOf(node: any): string
	if node.Container == "Dict" then
		return if node.KeyType ~= nil then "Map" else "Dict"
	end
	if node.Container == "Array" then
		return if node.Unique == true then "Set" else "Array"
	end
	return "Leaf"
end

--- Reject a container key Scribe would reject deeper in, where the raise is harder to
--- attribute, and reject a nil key outright: Remove(nil) targets the CONTAINER.
local function assertUsableKey(key: any, node: any): ()
	if node.KeyType == "integer" then
		-- Scribe.MapOf("integer", ...) stores number keys and Node refuses any other
		-- shape for one, so the string rules below would reject every legal key.
		if type(key) ~= "number" or key ~= key or key % 1 ~= 0 then
			fail(`container takes an integer key, got {typeof(key)}`)
		end
		return
	end
	if type(key) ~= "string" or #key == 0 then
		fail(`container key must be a non-empty string, got {typeof(key)}`)
	end
	if string.find(key, "\31", 1, true) ~= nil or not Util.isUtf8(key) then
		fail(`container key "{key}" is not storable`)
	end
	if node.MaxKeyLength ~= nil and #key > node.MaxKeyLength then
		fail(`container key "{key}" is over MaxKeyLength {node.MaxKeyLength}`)
	end
end

--- The element schema of a container node, or nil for a leaf.
local function elementOf(node: any): any
	return node.AnyChild
end

--- True when the element is a record of declared fields rather than a bare scalar.
---
--- `DictOf(Scribe.Int(0))` has an element that IS the stored number, so it has no field
--- to count and no residual a split could duplicate, and needs no Count and no Identity.
local function isRecordElement(element: any): boolean
	return element ~= nil and element.Children ~= nil and element.ChildOrder ~= nil and #element.ChildOrder > 0
end

--- May this node hold a stack's count? The Qty leg rules applied to an element field,
--- same list and same reasons: a count is a quantity that lives inside an element.
local function assertCountable(field: any, name: any, label: string): ()
	if field == nil then
		fail(`exchangeable "{tostring(name)}" cannot resolve {label}`)
	end
	if field.Container ~= nil then
		fail(`exchangeable "{tostring(name)}" names {label} as its count, but a container cannot be a count`)
	end
	if field.ValueType == "big" then
		fail(`exchangeable "{tostring(name)}" counts with a Scribe.Big, whose arithmetic absorbs a small leg silently`)
	end
	if field.ValueType == "number" then
		fail(
			`exchangeable "{tostring(name)}" counts with a Scribe.Number, and a double debit is not exactly `
				.. "conserved by the matching credit; hold the count in Scribe.Int"
		)
	end
	if field.ValueType ~= "int" then
		fail(`exchangeable "{tostring(name)}" counts with a {tostring(field.ValueType)} field, which is not a count`)
	end
	if field.Nullable == true then
		fail(`exchangeable "{tostring(name)}" counts with a Scribe.Optional field, which has no count to credit`)
	end
	-- Without a floor a debit stores a negative and every assertion passes.
	if field.Min == nil then
		fail(`exchangeable "{tostring(name)}" counts with a field declaring no Min, so it has no floor`)
	end
end

--- The rules declared for this leg's path and Kind, or nil when none were indexed.
--- Absent is not an error: a Key leg works without a plan, and only a Stack leg needs
--- one, which it says itself.
local function planFor(ctx: any, leg: Leg): Plan?
	local plans = ctx.Plans
	if type(plans) ~= "table" then
		return nil
	end
	return plans[`{table.concat(leg.Path :: any, ".")}|{leg.Kind}`]
end

--- The stored element with the fields declared not to travel removed.
---
--- Removed rather than defaulted. A whole-element Set fills every omitted declared field
--- from its default and stores it (ElementPartialSet.spec), so dropping the field here is
--- what makes the receiver start fresh and an Optional one stay absent.
local function travelPayload(held: any, plan: Plan?): any
	local clone = Util.deepClone(held)
	if plan == nil or type(clone) ~= "table" then
		return clone
	end
	for field in plan.Ignore do
		clone[field] = nil
	end
	return clone
end

--- Prove no ignored field is riding in the payload.
---
--- Checked at both ends: escrow proves the drop happened, delivery proves the record has
--- not grown it back. Every other proof only asserts that what IS in the payload landed.
local function assertNotTravelling(leg: Leg, plan: Plan?, where: string): ()
	if plan == nil or type(leg.Value) ~= "table" then
		return
	end
	for field in plan.Ignore do
		if leg.Value[field] ~= nil then
			fail(`leg at "{Util.pathString(leg.Path)}" carries ignored field "{field}" {where}`)
		end
	end
end

--- How many the element at `key` holds, and the leaf accessor that counts it. One reader
--- for both element shapes, so no caller branches on `Count` being nil.
local function stackCount(ctx: any, leg: Leg, plan: Plan, stored: any): (number, any)
	local entryAccessor = accessorAt(ctx, leg.Path)[leg.Key]
	if entryAccessor == nil then
		fail(`stack leg at "{Util.pathString(leg.Path)}" has no accessor at "{tostring(leg.Key)}"`)
	end
	local countField = plan.Count
	local held = if countField == nil then stored else (if type(stored) == "table" then stored[countField] else nil)
	if type(held) ~= "number" or held ~= held or held % 1 ~= 0 then
		fail(`stack leg at "{Util.pathString(leg.Path)}" holds no integer count at "{tostring(leg.Key)}"`)
	end
	return held, if countField == nil then entryAccessor else entryAccessor[countField]
end

--- Reject a Stack amount before anything reads a balance against it.
local function assertStackAmount(leg: Leg): number
	local raw = leg.Amount
	if type(raw) ~= "number" or raw ~= raw or raw == math.huge or raw == -math.huge then
		fail(`stack leg at "{Util.pathString(leg.Path)}" has no finite Amount`)
	end
	-- Cast for the same reason `present` exists: the guard above does not narrow.
	local amount = raw :: number
	if amount <= 0 then
		fail(`stack leg at "{Util.pathString(leg.Path)}" must move a positive amount, got {amount}`)
	end
	if amount % 1 ~= 0 then
		fail(`stack leg at "{Util.pathString(leg.Path)}" must move a whole number, got {amount}`)
	end
	return amount
end

--- Both halves of a split must be legal stacks. Skipping the moved half is a liveness
--- bug, not a conservation one: moving 2 off a stack of 10 with Min 3 escrows fine,
--- debits the giver, then never delivers, because Clamp rounds the credit to 3 and
--- giveKey refuses the mismatch. Nothing is lost, but it parks for ever.
---
--- A full take is exempt: the element travels as it stands, so it is legal already.
local function assertSplitFits(leg: Leg, amount: number, have: number, low: any): ()
	if amount >= have or low == nil then
		return
	end
	if compareNumbers(amount, low) < 0 then
		fail(
			`stack leg at "{Util.pathString(leg.Path)}" would move {amount}, below the smallest legal stack `
				.. `{tostring(low)}; move the whole {have} instead`
		)
	end
	local remaining = have - amount
	if compareNumbers(remaining, low) < 0 then
		fail(
			`stack leg at "{Util.pathString(leg.Path)}" would leave {remaining}, below the smallest legal stack `
				.. `{tostring(low)}; move the whole {have} instead`
		)
	end
end

--- Every field of `expected` except the count must be byte-identical in `actual`. The
--- residual is what a split duplicates and what a merge would overwrite, so it is proved
--- on both. Ignored fields are already absent from the payload.
local function assertResidual(leg: Leg, plan: Plan, expected: any, actual: any, what: string): ()
	if type(expected) ~= "table" then
		return
	end
	if type(actual) ~= "table" then
		fail(`stack leg at "{Util.pathString(leg.Path)}" {what} is not a record`)
	end
	for field, value in expected do
		if field ~= plan.Count and not packedEquals(actual[field], value) then
			fail(`stack leg at "{Util.pathString(leg.Path)}" {what} differs at "{tostring(field)}"`)
		end
	end
end

--------------------------------------------------------------------------------
-- Qty legs
--------------------------------------------------------------------------------

--- Move a numeric leaf by `amount`, proving the stored result is exactly the intent.
--- `sign` is -1 to debit and 1 to credit. Set only: Increment and Decrement return
--- nothing that distinguishes a clamp from a write.
local function applyQty(ctx: any, leg: Leg, node: any, sign: number): ()
	local amount = leg.Amount :: number
	if type(amount) ~= "number" or amount ~= amount or amount == math.huge or amount == -math.huge then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" has no finite Amount`)
	end
	if amount <= 0 then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" must move a positive amount, got {amount}`)
	end

	local leaf = accessorAt(ctx, leg.Path)
	local before = leaf.Get()
	if before == nil then
		before = leaf.Default()
	end
	if type(before) ~= "number" then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" has no numeric balance`)
	end

	local target = before + sign * amount
	-- I1. Equal intent and current state means applySet returns early, and then the
	-- return check and the post-read both agree with an intent that never landed.
	if target == before then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" would not change the balance (absorbed)`)
	end
	if target ~= target or target == math.huge or target == -math.huge then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" produces a non-finite balance`)
	end
	if math.abs(target) > MAX_SAFE then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" passes 2^53, where Node has no guard`)
	end
	-- An "int" leaf is ROUNDED by the default Clamp policy (Node.luau:1100-1104), not
	-- refused. Refuse here so a fractional leg never becomes a rounded one.
	if node.ValueType == "int" and target % 1 ~= 0 then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" is fractional on an integer field`)
	end

	-- I3 and the bounds pre-check. Never let Clamp be the thing that tells you.
	local low, high = leaf.Min(), leaf.Max()
	-- I3. A debit needs a floor to be refusable at all: without one, Set stores the
	-- negative, returns it, and reads it back, so every proof below passes.
	if sign < 0 and low == nil then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" has no declared Min, so it has no floor`)
	end
	if low ~= nil and compareNumbers(target, low) < 0 then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" would store below Min {low}`)
	end
	if high ~= nil and compareNumbers(target, high) > 0 then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" would store above Max {high}`)
	end

	local returned = leaf.Set(target)
	if returned ~= target then
		fail(
			`quantity leg at "{Util.pathString(leg.Path)}" stored {tostring(returned)} but intended {tostring(target)}`
		)
	end
	-- Not redundant with the return: a Changed listener dispatches synchronously inside
	-- applySet (Node.luau:1863) and can overwrite the leaf before Set returns. No delta
	-- clause, because `after == target` already pins the post-state and a delta re-derives
	-- it through a second rounding that is red on correct Number legs.
	local after = leaf.Get()
	if after ~= target then
		fail(`quantity leg at "{Util.pathString(leg.Path)}" reads back {tostring(after)}, not {tostring(target)}`)
	end
end

--------------------------------------------------------------------------------
-- Key legs
--------------------------------------------------------------------------------

--- Take one keyed item off a declared container, proving it left.
local function takeKey(ctx: any, leg: Leg, node: any, kind: string): ()
	local accessor = accessorAt(ctx, leg.Path)
	local countBefore = accessor.Count()

	if kind == "Set" then
		if accessor.Has(leg.Key) ~= true then
			fail(`set leg at "{Util.pathString(leg.Path)}" does not hold its member`)
		end
		-- Identity against true. Remove returns literal false on a miss, and
		-- `~= nil` passes on false.
		if accessor.Remove(leg.Key) ~= true then
			fail(`set leg at "{Util.pathString(leg.Path)}" Remove reported a miss`)
		end
		if accessor.Has(leg.Key) ~= false then
			fail(`set leg at "{Util.pathString(leg.Path)}" member survived Remove`)
		end
	elseif kind == "Array" then
		-- The ragged detector: Count walks every key while the writers use `#`.
		local snapshot = accessor.Clone()
		if type(snapshot) ~= "table" or #snapshot ~= countBefore then
			fail(`array leg at "{Util.pathString(leg.Path)}" is ragged`)
		end
		-- Assert on the INDEX, never the removed value: it passes through unpackRead
		-- and may legitimately be false, a table, or a Big.
		local _removed, index = accessor.RemoveValue(leg.Key)
		if index == nil then
			fail(`array leg at "{Util.pathString(leg.Path)}" matched nothing`)
		end
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > countBefore then
			fail(`array leg at "{Util.pathString(leg.Path)}" returned a nonsense index {tostring(index)}`)
		end
	else
		assertUsableKey(leg.Key, node)
		if accessor[leg.Key].Get() == nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" does not hold "{tostring(leg.Key)}"`)
		end
		-- Remove, never Set(nil): Set(nil) returns nil on a hit AND on a miss, so it
		-- cannot prove its own effect.
		if accessor.Remove(leg.Key) == nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" Remove reported a miss`)
		end
		if accessor[leg.Key].Get() ~= nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" key survived Remove`)
		end
	end

	local countAfter = accessor.Count()
	if countAfter ~= countBefore - 1 then
		fail(`leg at "{Util.pathString(leg.Path)}" changed count {countBefore} to {countAfter}, not by one`)
	end
end

--- Put one keyed item onto a declared container, proving it landed.
local function giveKey(ctx: any, leg: Leg, node: any, kind: string): ()
	local accessor = accessorAt(ctx, leg.Path)
	local countBefore = accessor.Count()

	local cap = if kind == "Dict" or kind == "Map" then node.MaxKeys else node.MaxItems
	-- Checked here rather than left to the write: the cap fires only when the key is
	-- new, so without this the credit raises AFTER the debit already committed.
	if cap ~= nil and countBefore >= cap then
		fail(`leg at "{Util.pathString(leg.Path)}" destination is full ({countBefore}/{cap})`)
	end

	if kind == "Set" then
		if accessor.Has(leg.Key) ~= false then
			fail(`set leg at "{Util.pathString(leg.Path)}" destination already holds its member`)
		end
		if accessor.Add(leg.Key) ~= true then
			fail(`set leg at "{Util.pathString(leg.Path)}" Add reported the member already present`)
		end
		-- Load-bearing. Add can return true, write, emit an op and fire Changed while
		-- membership is unchanged, because validateWrite coerces the member into one
		-- already stored. Count alone passes that case.
		if accessor.Has(leg.Key) ~= true then
			fail(`set leg at "{Util.pathString(leg.Path)}" member absent after Add (coerced into an existing one)`)
		end
	elseif kind == "Array" then
		local snapshot = accessor.Clone()
		if type(snapshot) ~= "table" or #snapshot ~= countBefore then
			fail(`array leg at "{Util.pathString(leg.Path)}" destination is ragged`)
		end
		-- Set at an explicit index: Insert returns nothing and cannot self-prove.
		local index = countBefore + 1
		accessor[index].Set(leg.Value)
		local parent, key = rawStore(ctx, leg.Path)
		local landed = if parent ~= nil then parent[key] :: any else nil
		if type(landed) ~= "table" or not packedEquals(landed[index], leg.Value) then
			fail(`array leg at "{Util.pathString(leg.Path)}" did not store its payload at {index}`)
		end
	else
		assertUsableKey(leg.Key, node)
		-- I2. Vacancy is what makes both proofs bite: an occupied key either no-ops
		-- (scalar element) or silently clobbers (record element).
		if accessor[leg.Key].Get() ~= nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" destination key "{tostring(leg.Key)}" is occupied`)
		end
		-- The whole element at the key, never a leaf field: a leaf write materialises
		-- the element from its defaults first and then no-ops if it equals the default.
		local returned = accessor[leg.Key].Set(leg.Value)
		-- Non-nil only. Set returns the UNPACKED form, a fresh table of real datatypes
		-- for a packed element, so comparing it to a packed payload fails on exactly
		-- the elements the packed payload exists to carry.
		if returned == nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" Set returned nil`)
		end
		local parent, key = rawStore(ctx, leg.Path)
		local landed = if parent ~= nil then parent[key] :: any else nil
		if type(landed) ~= "table" or landed[leg.Key] == nil then
			fail(`key leg at "{Util.pathString(leg.Path)}" key absent after Set`)
		end
		-- Content proved against the RAW re-read, which is still packed. The walk is
		-- guarded on shape because a scalar element IS its payload: iterating a number
		-- raises, and Deliver is retried for ever, so that raise repeats on every load.
		local stored = landed[leg.Key]
		if type(leg.Value) == "table" then
			for field, value in leg.Value do
				if not packedEquals(stored[field], value) then
					fail(`key leg at "{Util.pathString(leg.Path)}" field "{tostring(field)}" did not store`)
				end
			end
		elseif not packedEquals(stored, leg.Value) then
			fail(`key leg at "{Util.pathString(leg.Path)}" did not store its payload`)
		end
	end

	local countAfter = accessor.Count()
	if countAfter ~= countBefore + 1 then
		fail(`leg at "{Util.pathString(leg.Path)}" changed count {countBefore} to {countAfter}, not by one`)
	end
end

--------------------------------------------------------------------------------
-- Stack legs
--------------------------------------------------------------------------------

--- Take `Amount` off one stacked entry, proving what left and what stayed. A full take
--- delegates to takeKey rather than decrementing to zero: a zero-count entry is an item
--- the player still appears to own and can name in a later basket.
local function takeStack(ctx: any, leg: Leg, node: any, plan: Plan, kind: string, expected: number): ()
	local amount = assertStackAmount(leg)
	local accessor = accessorAt(ctx, leg.Path)
	local countBefore = accessor.Count()

	assertUsableKey(leg.Key, node)
	local parent, key = rawStore(ctx, leg.Path)
	local container = if parent ~= nil then parent[key] else nil
	if type(container) ~= "table" then
		fail(`stack leg at "{Util.pathString(leg.Path)}" has no stored container`)
	end
	local stored = container[leg.Key]
	if stored == nil then
		fail(`stack leg at "{Util.pathString(leg.Path)}" does not hold "{tostring(leg.Key)}"`)
	end

	local have, counter = stackCount(ctx, leg, plan, stored)
	-- The payload was built before the escrow record was written, and writing it
	-- dispatches listeners. If one moved this balance the payload no longer describes
	-- what is here.
	if have ~= expected then
		fail(`stack leg at "{Util.pathString(leg.Path)}" moved from {expected} to {have} before it could be staked`)
	end
	if amount > have then
		fail(`stack leg at "{Util.pathString(leg.Path)}" moves {amount} of {have} held`)
	end
	if amount == have then
		takeKey(ctx, leg, node, kind)
		return
	end

	-- `stored` is the live table, so snapshot before the write or the residual check
	-- below compares it to itself.
	local before = Util.deepClone(stored)
	local remaining = have - amount
	-- Checked here as well as in Escrow: this primitive is callable on its own.
	assertSplitFits(leg, amount, have, counter.Min())
	local returned = counter.Set(remaining)
	if returned ~= remaining then
		fail(`stack leg at "{Util.pathString(leg.Path)}" stored {tostring(returned)} but intended {remaining}`)
	end
	local readBack = counter.Get()
	if readBack ~= remaining then
		fail(`stack leg at "{Util.pathString(leg.Path)}" reads back {tostring(readBack)}, not {remaining}`)
	end
	-- A split must not change the key set: the entry stays, holding less.
	local countAfter = accessor.Count()
	if countAfter ~= countBefore then
		fail(`stack leg at "{Util.pathString(leg.Path)}" changed count {countBefore} to {countAfter} on a split`)
	end
	local parentAfter, keyAfter = rawStore(ctx, leg.Path)
	local containerAfter = if parentAfter ~= nil then parentAfter[keyAfter] else nil
	local after = if type(containerAfter) == "table" then containerAfter[leg.Key] else nil
	assertResidual(leg, plan, before, after, "remainder")
end

--- Credit `Amount` onto the destination, whether or not it already holds the stack.
local function giveStack(ctx: any, leg: Leg, node: any, plan: Plan, kind: string): ()
	local amount = assertStackAmount(leg)
	assertNotTravelling(leg, plan, "into delivery")
	local accessor = accessorAt(ctx, leg.Path)
	assertUsableKey(leg.Key, node)

	local parent, key = rawStore(ctx, leg.Path)
	local container = if parent ~= nil then parent[key] else nil
	local stored = if type(container) == "table" then container[leg.Key] else nil
	if stored == nil then
		-- A vacant key is the ordinary whole-entry credit, and the payload already
		-- carries Count = Amount. giveKey proves vacancy, cap, content and count.
		giveKey(ctx, leg, node, kind)
		return
	end

	-- The residual is what says these two stacks are the same thing. A mismatch parks
	-- rather than picking a winner, so an operator can redirect it.
	assertResidual(leg, plan, leg.Value, stored, "destination")

	local countBefore = accessor.Count()
	local have, counter = stackCount(ctx, leg, plan, stored)
	local before = Util.deepClone(stored)
	local target = have + amount
	if target ~= target or target == math.huge or math.abs(target) > MAX_SAFE then
		fail(`stack leg at "{Util.pathString(leg.Path)}" produces an unstorable count {tostring(target)}`)
	end
	-- Checked before the write: Clamp would round the overflow away and report success.
	local high = counter.Max()
	if high ~= nil and compareNumbers(target, high) > 0 then
		fail(`stack leg at "{Util.pathString(leg.Path)}" would store {target}, above Max {tostring(high)}`)
	end
	local returned = counter.Set(target)
	if returned ~= target then
		fail(`stack leg at "{Util.pathString(leg.Path)}" stored {tostring(returned)} but intended {target}`)
	end
	local readBack = counter.Get()
	if readBack ~= target then
		fail(`stack leg at "{Util.pathString(leg.Path)}" reads back {tostring(readBack)}, not {target}`)
	end
	local countAfter = accessor.Count()
	if countAfter ~= countBefore then
		fail(`stack leg at "{Util.pathString(leg.Path)}" changed count {countBefore} to {countAfter} on a merge`)
	end
	local parentAfter, keyAfter = rawStore(ctx, leg.Path)
	local containerAfter = if parentAfter ~= nil then parentAfter[keyAfter] else nil
	local after = if type(containerAfter) == "table" then containerAfter[leg.Key] else nil
	assertResidual(leg, plan, before, after, "destination after merge")
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

--- Move every leg out of game data and into this player's own reserved escrow, in one
--- transaction.
---
--- The reserved record is written BEFORE the removals. That does not change what commits,
--- but it orders the failure modes: anything escaping a clean rollback strands value
--- under `_Scribe`, where the gate can see it and the resolver can return it.
function ExchangeLeg.Escrow(ctx: any, exchangeId: string, legs: { Leg }): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Escrow needs an exchange id")
	end
	if type(legs) ~= "table" or #legs == 0 then
		fail("Escrow needs at least one leg")
	end

	return ctx.Tree:RunTransaction(function()
		-- A claim with no value in it is the expected precursor; anything further
		-- along already holds value and must not be overwritten.
		local existing = ctx.Tree.Reserved.Exchange[exchangeId].Get()
		if existing ~= nil and existing.Phase ~= "Claimed" then
			fail(`exchange "{exchangeId}" is already staked on this profile`)
		end

		local recorded: { Leg } = {}
		-- What each Stack leg held when its payload was built, so the removal pass can
		-- refuse a balance that moved in between.
		local observed: { [number]: number } = {}
		for position, leg in legs do
			local node = resolveStrict(ctx.Compiled, leg.Path)
			local entry: Leg = { Path = leg.Path, Kind = leg.Kind, Key = leg.Key, Amount = leg.Amount }
			if leg.Kind == "Stack" then
				local plan = present(
					planFor(ctx, leg),
					`stack leg at "{Util.pathString(leg.Path)}" has no declared Stack rules on this bundle`
				)
				local kind = containerKindOf(node)
				if kind ~= "Dict" and kind ~= "Map" then
					fail(`stack leg at "{Util.pathString(leg.Path)}" is a {kind}, which has no keyed stack to split`)
				end
				assertUsableKey(leg.Key, node)
				local parent, key = rawStore(ctx, leg.Path)
				local container = if parent ~= nil then parent[key] else nil
				if type(container) ~= "table" then
					fail(`stack leg at "{Util.pathString(leg.Path)}" has no stored container`)
				end
				local held = container[leg.Key]
				if held == nil then
					fail(`stack leg at "{Util.pathString(leg.Path)}" holds nothing to stake`)
				end
				local amount = assertStackAmount(leg)
				local have, counter = stackCount(ctx, leg, plan, held)
				if amount > have then
					fail(`stack leg at "{Util.pathString(leg.Path)}" moves {amount} of {have} held`)
				end
				assertSplitFits(leg, amount, have, counter.Min())
				observed[position] = have
				if plan.Count == nil then
					-- A scalar element is its own count.
					entry.Value = amount
				else
					local payload = travelPayload(held, plan)
					if type(payload) ~= "table" then
						fail(`stack leg at "{Util.pathString(leg.Path)}" holds a scalar where a record was declared`)
					end
					payload[plan.Count] = amount
					entry.Value = payload
				end
				assertNotTravelling(entry, plan, "into escrow")
			elseif leg.Kind == "Key" then
				-- Read the STORED form before anything moves it. Remove's return is the
				-- live former table by reference for an unpacked element.
				local parent, key = rawStore(ctx, leg.Path)
				local container = if parent ~= nil then parent[key] else nil
				local kind = containerKindOf(node)
				if kind == "Set" then
					entry.Value = leg.Key
				elseif type(container) == "table" then
					local held
					if kind == "Array" then
						-- Resolve the needle to an INDEX and read what the STORE holds
						-- there, not the caller's own value: a packed element is live
						-- datatypes in the needle and a buffer in the store, and only the
						-- buffer can be recorded under the reserved root. It also proves
						-- the container holds the entry; a nil test on the needle did not.
						local index = accessorAt(ctx, leg.Path).Find(leg.Key)
						held = if index ~= nil then container[index] else nil
						-- The needle was an ADDRESS, spent once the entry is read. Keeping
						-- it would put the same unstorable live datatypes under `Key` that
						-- `Value` just avoided, and delivery appends by index anyway.
						-- takeKey below still gets the caller's own leg.
						entry.Key = nil
					else
						-- Checked here as well as inside takeKey: the lookup below misses
						-- on a wrong-typed key and would report "holds nothing to stake",
						-- which on an integer-keyed map reads as an empty container.
						assertUsableKey(leg.Key, node)
						held = container[leg.Key]
					end
					if held == nil then
						fail(`key leg at "{Util.pathString(leg.Path)}" holds nothing to stake`)
					end
					-- Dropped here, the one point where the giver's copy is still
					-- readable, so nothing downstream needs to know about them.
					local plan = planFor(ctx, leg)
					entry.Value = travelPayload(held, plan)
					assertNotTravelling(entry, plan, "into escrow")
				else
					fail(`key leg at "{Util.pathString(leg.Path)}" has no stored container`)
				end
			end
			table.insert(recorded, entry)
		end

		local written = ctx.Tree.Reserved.Exchange[exchangeId].Set({
			Id = exchangeId,
			Owner = ctx.UserId,
			Digest = if existing ~= nil then existing.Digest else nil,
			Role = if existing ~= nil then existing.Role else nil,
			Partner = if existing ~= nil then existing.Partner else nil,
			StakedAt = Clock.Now(),
			Phase = "Staked",
			Escrow = recorded,
		})
		-- An untyped Set hands back the live stored table, so identity is a true proof
		-- here and is available on no other shape.
		if type(written) ~= "table" or ctx.Tree.Reserved.Exchange[exchangeId].Get() ~= written then
			fail(`escrow record for "{exchangeId}" is not the live stored table`)
		end

		for index, leg in legs do
			local node = resolveStrict(ctx.Compiled, leg.Path)
			if leg.Kind == "Qty" then
				applyQty(ctx, leg, node, -1)
			elseif leg.Kind == "Stack" then
				takeStack(
					ctx,
					leg,
					node,
					present(planFor(ctx, leg), `stack leg at "{Util.pathString(leg.Path)}" lost its declared rules`),
					containerKindOf(node),
					present(observed[index], `stack leg at "{Util.pathString(leg.Path)}" was never measured`)
				)
			else
				takeKey(ctx, leg, node, containerKindOf(node))
			end
		end
	end)
end

--- Apply every leg of this player's inbox entry onto game data and clear the entry, in
--- one transaction, so delivery and removal are atomic.
function ExchangeLeg.Deliver(ctx: any, exchangeId: string): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Deliver needs an exchange id")
	end

	return ctx.Tree:RunTransaction(function()
		local record = ctx.Tree.Reserved.ExchangeInbox[exchangeId].Get()
		if type(record) ~= "table" then
			fail(`no inbox entry for "{exchangeId}"`)
		end
		local legs = record.Legs
		if type(legs) ~= "table" or #legs == 0 then
			fail(`inbox entry "{exchangeId}" carries no legs`)
		end

		for _, leg in legs do
			local node = resolveStrict(ctx.Compiled, leg.Path)
			if leg.Kind == "Qty" then
				applyQty(ctx, leg, node, 1)
			elseif leg.Kind == "Stack" then
				giveStack(
					ctx,
					leg,
					node,
					present(planFor(ctx, leg), `stack leg at "{Util.pathString(leg.Path)}" lost its declared rules`),
					containerKindOf(node)
				)
			else
				assertNotTravelling(leg, planFor(ctx, leg), "into delivery")
				giveKey(ctx, leg, node, containerKindOf(node))
			end
		end

		if ctx.Tree.Reserved.ExchangeInbox.Remove(exchangeId) == nil then
			fail(`inbox entry "{exchangeId}" vanished before it could be cleared`)
		end
		if ctx.Tree.Reserved.ExchangeInbox[exchangeId].Get() ~= nil then
			fail(`inbox entry "{exchangeId}" survived its removal`)
		end
	end)
end

--------------------------------------------------------------------------------
-- Reserved-root record lifecycle
--
-- Everything below writes ONLY under the reserved root. After the verdict no
-- operation may remain that a declared shape, a cap, a bound, a Closed record or a
-- seed path can refuse: a write outside `_Scribe` in Settle would put a
-- data-dependent refusal after the point of no return. ExchangeLegSettle.spec
-- records every emitted op and asserts it.
--------------------------------------------------------------------------------

--- How many exchanges this profile has in flight.
local function openExchangeCount(ctx: any): number
	local exchange = ctx.Tree.Reserved.Exchange.Get()
	if type(exchange) ~= "table" then
		return 0
	end
	local count = 0
	for _ in exchange do
		count += 1
	end
	return count
end

--- Take this profile's single exchange slot, holding no value yet. The emptiness test
--- runs INSIDE the transaction, so there is no instant at which a participant of an
--- in-flight exchange advertises a free slot.
function ExchangeLeg.Claim(ctx: any, exchangeId: string, spec: any): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Claim needs an exchange id")
	end
	if type(spec) ~= "table" or type(spec.Digest) ~= "string" then
		fail("Claim needs a spec carrying a Digest")
	end

	return ctx.Tree:RunTransaction(function()
		local open = openExchangeCount(ctx)
		if open ~= 0 then
			fail(`profile already has {open} exchange(s) in flight`)
		end
		ctx.Tree.Reserved.Exchange[exchangeId].Set({
			Id = exchangeId,
			Owner = ctx.UserId,
			Digest = spec.Digest,
			Role = spec.Role,
			Partner = spec.Partner,
			Phase = "Claimed",
			StakedAt = Clock.Now(),
		})
		if ctx.Tree.Reserved.Exchange[exchangeId].Get() == nil then
			fail(`claim for "{exchangeId}" did not land`)
		end
	end)
end

--- Release a slot that never took value. Restricted to Phase "Claimed" on purpose: once
--- any escrow has committed the only exit is the verdict-gated abort, and dropping a
--- staked record here would destroy the value it holds with nothing left to say where it
--- went.
function ExchangeLeg.Unclaim(ctx: any, exchangeId: string): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Unclaim needs an exchange id")
	end

	return ctx.Tree:RunTransaction(function()
		local record = ctx.Tree.Reserved.Exchange[exchangeId].Get()
		if record == nil then
			return
		end
		if record.Phase ~= "Claimed" then
			fail(`exchange "{exchangeId}" is {tostring(record.Phase)}, not Claimed; only the verdict may release it`)
		end
		if type(record.Escrow) == "table" and next(record.Escrow) ~= nil then
			fail(`exchange "{exchangeId}" holds escrowed value and cannot be unclaimed`)
		end
		if ctx.Tree.Reserved.Exchange.Remove(exchangeId) == nil then
			fail(`claim for "{exchangeId}" vanished before it could be released`)
		end
	end)
end

--- Record what this profile is OWED, copied from the counterparty's escrow.
---
--- The payload comes from the counterparty's escrow rather than their live game data, so
--- what a taker is promised is provably what the giver gave up. Game code cannot write
--- the reserved root, so that copy cannot have drifted.
function ExchangeLeg.FillTake(ctx: any, exchangeId: string, legs: { Leg }): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("FillTake needs an exchange id")
	end
	if type(legs) ~= "table" then
		fail("FillTake needs a leg list")
	end

	return ctx.Tree:RunTransaction(function()
		local record = ctx.Tree.Reserved.Exchange[exchangeId].Get()
		if record == nil then
			fail(`exchange "{exchangeId}" has no record to fill`)
		end
		-- Filling twice would replace what the profile is owed with a second copy of
		-- it, which reads as success and moves the wrong basket.
		if record.Take ~= nil then
			fail(`exchange "{exchangeId}" already has a take recorded`)
		end
		ctx.Tree.Reserved.Exchange[exchangeId].Take.Set(Util.deepClone(legs))
		local after = ctx.Tree.Reserved.Exchange[exchangeId].Get()
		if after == nil or type(after.Take) ~= "table" then
			fail(`take for "{exchangeId}" did not land`)
		end
	end)
end

--- Apply a verdict to this profile's record, in one transaction, touching nothing
--- outside the reserved root.
---
--- Commit moves this profile's Take into its inbox and DROPS its escrow: the
--- counterparty's copy was made durable before any verdict could exist, so the drop
--- cannot destroy the only copy. Abort moves the escrow back into this profile's own
--- inbox and drops the Take. The record's removal is fused with the move, so a replay
--- from the same verdict is a no-op rather than a second move.
function ExchangeLeg.Settle(ctx: any, exchangeId: string, verdict: any): (boolean, string?)
	if type(exchangeId) ~= "string" or #exchangeId == 0 then
		fail("Settle needs an exchange id")
	end
	if type(verdict) ~= "table" or (verdict.V ~= "Commit" and verdict.V ~= "Abort") then
		fail("Settle needs a verdict of Commit or Abort")
	end

	return ctx.Tree:RunTransaction(function()
		local record = ctx.Tree.Reserved.Exchange[exchangeId].Get()
		-- Absence IS the already-settled bit, and it is atomic with the settle because
		-- the removal below happens in this same transaction.
		if record == nil then
			return
		end
		-- A corruption check, not an expected branch. Refusing here leaves both records
		-- in place for an operator rather than settling against the wrong basket.
		if verdict.D ~= nil and record.Digest ~= nil and verdict.D ~= record.Digest then
			fail(`exchange "{exchangeId}" digest does not match the verdict`)
		end

		-- The ordering premise, asserted rather than assumed. With no Take the drop has
		-- no counterpart: nothing is written to the inbox, control falls through to the
		-- removal below, and the escrow and the record of what it held are deleted
		-- together while the call reports success. Attempt writes exactly this state
		-- between Escrow and FillTake and leaves it there whenever no verdict can be
		-- established, so it is reachable with no crash at all.
		local escrow = record.Escrow
		if
			verdict.V == "Commit"
			and type(record.Take) ~= "table"
			and type(escrow) == "table"
			and next(escrow) ~= nil
		then
			fail(`exchange "{exchangeId}" holds escrow with no take recorded; a Commit here would destroy it`)
		end

		local moved = if verdict.V == "Commit" then record.Take else record.Escrow
		if type(moved) == "table" and next(moved) ~= nil then
			ctx.Tree.Reserved.ExchangeInbox[exchangeId].Set({
				Id = exchangeId,
				Verdict = verdict.V,
				Legs = moved,
				SettledAt = Clock.Now(),
			})
			if ctx.Tree.Reserved.ExchangeInbox[exchangeId].Get() == nil then
				fail(`inbox entry for "{exchangeId}" did not land`)
			end
		end

		-- Fused with the move. If the removal were a separate transaction, a revert
		-- between them would replay the move and the inbox would hold it twice.
		if ctx.Tree.Reserved.Exchange.Remove(exchangeId) == nil then
			fail(`record for "{exchangeId}" vanished before it could be removed`)
		end
	end)
end

--- May a parked key leg at this path be re-pointed at a different key?
---
--- Only where the key is a slot and the payload is separate from it. In a Set the key IS
--- the member, so re-keying substitutes a different item rather than relocating the
--- delivery, and the delivery reports success. An Array has no key to move at all.
function ExchangeLeg.Rekeyable(compiled: any, path: any): (boolean, string?)
	if type(path) ~= "table" or #path == 0 then
		return false, "a leg with no Path cannot be redirected"
	end
	local ok, node = pcall(resolveStrict, compiled, path)
	if not ok or node == nil then
		return false, `"{Util.pathString(path)}" is not a declared container`
	end
	local kind = containerKindOf(node)
	if kind == "Dict" or kind == "Map" then
		if node.KeyType == "integer" then
			return false, `"{Util.pathString(path)}" is keyed by integer, and a redirect names its key as a string`
		end
		return true, nil
	end
	if kind == "Set" then
		return false,
			`"{Util.pathString(path)}" is a set, where the key is the value; re-keying it would deliver a different item`
	end
	return false, `"{Util.pathString(path)}" is a {kind} and has no destination key to move`
end

--- The runtime allowlist, indexed once from the declared specs.
---
--- Refuse, below, proves the DECLARATIONS are safe to move; this proves a basket only
--- names them. Keyed on the path AND the Kind, because the same path moved as a Key and
--- moved as a Qty reaches two different primitives and registration vetted one of them.
function ExchangeLeg.Approve(exchangeable: any): { [string]: Plan }
	local approved: { [string]: Plan } = {}
	if type(exchangeable) ~= "table" then
		return approved
	end
	for _, spec in exchangeable do
		if
			type(spec) == "table"
			and type(spec.Path) == "table"
			and (spec.Kind == "Key" or spec.Kind == "Qty" or spec.Kind == "Stack")
		then
			-- A set, not the list: every read is a membership test.
			local ignore: { [string]: true } = {}
			if type(spec.Ignore) == "table" then
				for _, field in spec.Ignore do
					if type(field) == "string" then
						ignore[field] = true
					end
				end
			end
			approved[`{table.concat(spec.Path, ".")}|{spec.Kind}`] = {
				Count = if type(spec.Count) == "string" then spec.Count else nil,
				Ignore = ignore,
			}
		end
	end
	return approved
end

--- Is this leg one the game declared exchangeable? Returns the reason when it is not.
---
--- Every malformed shape is answered with a refusal rather than a raise: this runs on a
--- basket that may have been built from client-influenced input, where a raise reaches
--- game code as a stack trace from inside Scribe. The shape checks come first because the
--- lookup has to read Path to build its key.
function ExchangeLeg.ApprovedLeg(approved: any, leg: any): (boolean, string?)
	if type(leg) ~= "table" or type(leg.Path) ~= "table" or #leg.Path == 0 then
		return false, "a leg with no Path is not exchangeable"
	end
	for _, segment in leg.Path do
		if type(segment) ~= "string" then
			return false, "a leg whose Path is not a list of names is not exchangeable"
		end
	end
	if leg.Kind ~= "Key" and leg.Kind ~= "Qty" and leg.Kind ~= "Stack" then
		return false, `the leg at "{Util.pathString(leg.Path)}" declares no Kind, so it is not exchangeable`
	end
	if type(approved) ~= "table" or not approved[`{table.concat(leg.Path, ".")}|{leg.Kind}`] then
		return false,
			`"{Util.pathString(leg.Path)}" is not exchangeable as a {leg.Kind} leg; declare it in the Exchangeable option`
	end
	return true, nil
end

--- Refuse every unsafe exchangeable path at startup, by name, so a misconfigured game
--- fails to boot instead of discovering it mid-exchange.
function ExchangeLeg.Refuse(compiled: any, exchangeable: any): ()
	if exchangeable == nil then
		return
	end
	if type(exchangeable) ~= "table" then
		fail("Exchangeable must be a table of leg specs")
	end

	for name, spec in exchangeable do
		if type(spec) ~= "table" or type(spec.Path) ~= "table" or #spec.Path == 0 then
			fail(`exchangeable "{tostring(name)}" must declare a Path`)
		end
		local kind = spec.Kind
		if kind ~= "Key" and kind ~= "Qty" and kind ~= "Stack" then
			fail(`exchangeable "{tostring(name)}" must declare Kind "Key", "Qty" or "Stack"`)
		end

		local root = spec.Path[1]
		if string.sub(root, 1, #RESERVED) == RESERVED then
			fail(`exchangeable "{tostring(name)}" names the reserved "{RESERVED}" root, which is Scribe's own ledger`)
		end
		local node = resolveStrict(compiled, spec.Path)
		local container = containerKindOf(node)

		-- A leg may name a top-level field or a container, but may NOT reach through
		-- one: a write under a key the receiver does not hold materialises that whole
		-- element from its declared defaults, so the credit mints everything the element
		-- declares and every per-leg proof still passes, the moved term being exact.
		local ancestor = node.Parent
		while ancestor ~= nil do
			if ancestor.Container ~= nil then
				fail(
					`exchangeable "{tostring(name)}" reaches through a container; name the container itself, `
						.. "because crediting a key the receiver does not hold would seed the whole element"
				)
			end
			ancestor = ancestor.Parent
		end

		-- Derived and Flags are named BEFORE the persistence test. A derived field is
		-- legitimately non-persisted, so testing persistence first blames the wrong
		-- rule and sends the reader hunting for a Session marker that is not there.
		if node.Derived ~= nil then
			fail(`exchangeable "{tostring(name)}" is a Scribe.Derived field; it is computed, never written`)
		end
		if node.ValueType == "flags" then
			fail(`exchangeable "{tostring(name)}" is a Scribe.Flags; membership is not movable`)
		end
		-- A session root is rebuilt from declared defaults on every load, so a credit
		-- is wiped on the next join and a debit is undone while the escrow persists.
		if not Template.PersistOf(compiled, { root }) then
			fail(
				`exchangeable "{tostring(name)}" names the non-persisted root "{root}"; session state cannot be exchanged`
			)
		end

		if kind == "Qty" then
			if container ~= "Leaf" then
				fail(`exchangeable "{tostring(name)}" is a quantity leg on a container`)
			end
			if node.ValueType == "big" then
				fail(`exchangeable "{tostring(name)}" is a Scribe.Big, whose arithmetic absorbs a small leg silently`)
			end
			if node.ValueType == "number" then
				fail(
					`exchangeable "{tostring(name)}" is a Scribe.Number, and a double debit is not exactly `
						.. "conserved by the matching credit; hold the quantity in Scribe.Int minor units"
				)
			end
			if node.ValueType ~= "int" and node.ValueType ~= "number" then
				fail(`exchangeable "{tostring(name)}" is a quantity leg on a {tostring(node.ValueType)} field`)
			end
			if node.Nullable == true then
				fail(
					`exchangeable "{tostring(name)}" is a Scribe.Optional field, which has no balance to `
						.. "credit until something writes it, so the receiving half would park for ever"
				)
			end
			-- Without a floor a debit stores a negative and every assertion passes.
			if node.Min == nil then
				fail(`exchangeable "{tostring(name)}" declares no Min, so it has no floor and cannot be a quantity`)
			end
		elseif container == "Leaf" then
			fail(`exchangeable "{tostring(name)}" is a {kind} leg on a field that is not a container`)
		end

		-- Ignore and the Stack rules are about the element, not the container.
		local element = elementOf(node)
		local isRecord = isRecordElement(element)

		--- One resolver for every option naming an element field. A typo in Ignore that
		--- silently ignored nothing would look stripped and travel anyway.
		local function declaredField(field: any, option: string): any
			if type(field) ~= "string" then
				fail(`exchangeable "{tostring(name)}" lists a non-string name in {option}`)
			end
			if string.find(field, ".", 1, true) ~= nil then
				fail(
					`exchangeable "{tostring(name)}" names "{field}" in {option}; only top-level element fields are `
						.. "supported, not a path into one"
				)
			end
			local child = if isRecord then element.Children[field] else nil
			if child == nil then
				fail(`exchangeable "{tostring(name)}" names "{field}" in {option}, which the element does not declare`)
			end
			return child
		end

		local ignored: { [string]: true } = {}
		if spec.Ignore ~= nil then
			if kind == "Qty" then
				fail(`exchangeable "{tostring(name)}" declares Ignore on a quantity leg, which has no fields`)
			end
			if type(spec.Ignore) ~= "table" then
				fail(`exchangeable "{tostring(name)}" declares Ignore that is not a list of field names`)
			end
			if not isRecord then
				fail(
					`exchangeable "{tostring(name)}" declares Ignore, but its element is a single value with no `
						.. "fields to ignore"
				)
			end
			for _, field in spec.Ignore do
				declaredField(field, "Ignore")
				ignored[field] = true
			end
		end

		if spec.Count ~= nil and kind ~= "Stack" then
			fail(`exchangeable "{tostring(name)}" declares Count on a {kind} leg; it is only meaningful for a Stack`)
		end
		if spec.Identity ~= nil and kind ~= "Stack" then
			fail(`exchangeable "{tostring(name)}" declares Identity on a {kind} leg; it is only meaningful for a Stack`)
		end

		if kind == "Stack" then
			if container ~= "Dict" and container ~= "Map" then
				fail(
					`exchangeable "{tostring(name)}" is a stack leg on a {container}; only a DictOf or MapOf has a `
						.. "keyed stack to split"
				)
			end
			if not isRecord then
				-- The element IS the count, so nothing rides alongside it to declare.
				if spec.Count ~= nil then
					fail(
						`exchangeable "{tostring(name)}" declares Count, but its element is a single value which IS `
							.. "the count"
					)
				end
				if spec.Identity ~= nil then
					fail(
						`exchangeable "{tostring(name)}" declares Identity, but its element is a single value with no `
							.. "other fields"
					)
				end
				assertCountable(element, name, "its element")
			else
				if type(spec.Count) ~= "string" then
					fail(
						`exchangeable "{tostring(name)}" must declare Count, naming the element field that holds how many`
					)
				end
				assertCountable(declaredField(spec.Count, "Count"), name, `"{spec.Count}"`)
				if ignored[spec.Count] then
					fail(`exchangeable "{tostring(name)}" ignores "{spec.Count}", which is the field being moved`)
				end

				local identified: { [string]: true } = {}
				if spec.Identity ~= nil then
					if type(spec.Identity) ~= "table" then
						fail(`exchangeable "{tostring(name)}" declares Identity that is not a list of field names`)
					end
					for _, field in spec.Identity do
						declaredField(field, "Identity")
						if ignored[field] then
							fail(`exchangeable "{tostring(name)}" lists "{field}" in BOTH Identity and Ignore`)
						end
						identified[field] = true
					end
				end

				-- A split duplicates whatever it does not drop, and no per-leg proof can
				-- see it because the count is exact either way. Boot is the only place
				-- an unclassified field is visible, so every one must be accounted for.
				for _, field in element.ChildOrder do
					if field == spec.Count then
						continue
					end
					if not identified[field] and not ignored[field] then
						fail(
							`exchangeable "{tostring(name)}" does not account for element field "{field}"; list it in `
								.. "Identity to travel with the split, or in Ignore to reset on the receiver"
						)
					end
					if identified[field] and element.Children[field].Container ~= nil then
						fail(
							`exchangeable "{tostring(name)}" lists container field "{field}" in Identity; a split would `
								.. "duplicate the whole collection"
						)
					end
				end
			end
		end

		local seen = {}
		local function walk(current: any)
			if current == nil or seen[current] then
				return
			end
			seen[current] = true
			if current.Timed == true then
				fail(
					`exchangeable "{tostring(name)}" has a Scribe.Timed field in its subtree; timed state is keyed by path`
				)
			end
			if current.Evict ~= nil then
				fail(`exchangeable "{tostring(name)}" has an Evict container in its subtree, which destroys silently`)
			end
			if current.Derived ~= nil then
				fail(`exchangeable "{tostring(name)}" has a derived field in its subtree`)
			end
			if current.ValueType == "flags" then
				fail(`exchangeable "{tostring(name)}" has a Scribe.Flags in its subtree`)
			end
			if current.ChildOrder and current.Children then
				for _, key in current.ChildOrder do
					walk(current.Children[key])
				end
			end
			if current.AnyChild and current.AnyChild.IsElement then
				walk(current.AnyChild)
			end
		end
		walk(node)
	end
end

return ExchangeLeg
