--!nonstrict
-- Headless test runner: executes the TestEZ-compatible suite under Lune with a
-- minimal Roblox shim (fake DataModel + services, Instance-based require, and
-- a small describe/it/expect implementation matching the TestEZ subset the
-- specs use). CI-friendly: exits nonzero on failure.
--
--   lune run lune/run-tests
--
-- The same spec files run unmodified under real TestEZ in Studio (see
-- test/RunTests.server.luau).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")
local process = require("@lune/process")
local serde = require("@lune/serde")

-- Seconds per `it` block. The default is unchanged; the override exists so a
-- simulation soak can run deep without loosening the cap for the ordinary suite,
-- where a 10-second test is a hang worth failing on.
local TEST_TIMEOUT = tonumber(process.env.SCRIBE_TEST_TIMEOUT) or 10

--------------------------------------------------------------------------------
-- Fake signals
--------------------------------------------------------------------------------

local FakeSignal = {}
FakeSignal.__index = FakeSignal

function FakeSignal.new()
	return setmetatable({ _handlers = {} }, FakeSignal)
end

function FakeSignal:Connect(fn)
	local connection
	connection = {
		Connected = true,
		Disconnect = function()
			connection.Connected = false
			self._handlers[connection] = nil
		end,
	}
	self._handlers[connection] = fn
	return connection
end

FakeSignal.connect = FakeSignal.Connect

function FakeSignal:Fire(...)
	for _, fn in self._handlers do
		task.spawn(fn, ...)
	end
end

function FakeSignal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

--------------------------------------------------------------------------------
-- Fake Instances (virtual file system tree)
--------------------------------------------------------------------------------

local INSTANCE_MARKER = {}

local InstanceMethods = {}

function InstanceMethods.FindFirstChild(self, name)
	return rawget(self, "_children")[name]
end

function InstanceMethods.WaitForChild(self, name, _timeout)
	local child = rawget(self, "_children")[name]
	if not child then
		error(`shim: WaitForChild("{name}") would yield forever under {self:GetFullName()}`)
	end
	return child
end

function InstanceMethods.GetChildren(self)
	local out = {}
	for _, child in rawget(self, "_children") do
		table.insert(out, child)
	end
	return out
end

function InstanceMethods.IsA(self, className)
	return className == rawget(self, "ClassName") or className == "Instance" or className == "LuaSourceContainer"
end

function InstanceMethods.GetFullName(self)
	local parts = {}
	local node = self
	while node do
		table.insert(parts, 1, rawget(node, "Name"))
		node = rawget(node, "Parent")
	end
	return table.concat(parts, ".")
end

local InstanceMeta = {
	__index = function(self, key)
		local child = rawget(self, "_children")[key]
		if child ~= nil then
			return child
		end
		local method = InstanceMethods[key]
		if method ~= nil then
			return method
		end
		return nil
	end,
	__tostring = function(self)
		return rawget(self, "Name")
	end,
}

local function newInstance(name, className)
	local instance = setmetatable({
		[INSTANCE_MARKER] = true,
		Name = name,
		ClassName = className,
		Parent = nil,
		_children = {},
		_source = nil,
	}, InstanceMeta)
	return instance
end

local function addChild(parent, child)
	rawset(child, "Parent", parent)
	rawget(parent, "_children")[rawget(child, "Name")] = child
end

local function isFakeInstance(value)
	return type(value) == "table" and rawget(value, INSTANCE_MARKER) == true
end

--- Roblox's Instance:Clone(), as far as the module tree needs it: a deep copy with
--- no parent, carrying `_source` so shimRequire loads the module AGAIN rather than
--- handing back the original's cached value.
---
--- Defined here rather than beside the other InstanceMethods because it needs
--- `newInstance`, which is a local declared above only by accident of ordering --
--- a method written earlier in the file would resolve the name as a global and get
--- nil. Left as a method so specs reach it exactly as they would in Studio.
---
--- What it is FOR: a Scribe module whose state is a once-per-process latch cannot
--- be re-armed, so a spec that must not spend the shared one takes a private copy
--- instead. test/Specs/DebugHookIntegration.spec is the case, and the reason it is
--- worth supporting here is that it is not a headless problem at all -- headless
--- the latch is never even reached -- it is what made the Studio run's ordering
--- decide which of two specs got to measure the hook.
function InstanceMethods.Clone(self)
	local copy = newInstance(rawget(self, "Name"), rawget(self, "ClassName"))
	rawset(copy, "_source", rawget(self, "_source"))
	for name, child in rawget(self, "_children") do
		local childCopy = InstanceMethods.Clone(child)
		rawset(childCopy, "Parent", copy)
		rawget(copy, "_children")[name] = childCopy
	end
	return copy
end

local function buildTree(name, path)
	if fs.isDir(path) then
		local node = newInstance(name, "Folder")
		local initPath = `{path}/init.luau`
		if fs.isFile(initPath) then
			rawset(node, "ClassName", "ModuleScript")
			rawset(node, "_source", initPath)
		end
		for _, childName in fs.readDir(path) do
			if childName == "init.luau" then
				continue
			end
			local childPath = `{path}/{childName}`
			if fs.isDir(childPath) then
				addChild(node, buildTree(childName, childPath))
			elseif string.sub(childName, -5) == ".luau" then
				local moduleName = string.sub(childName, 1, -6)
				local leaf = newInstance(moduleName, "ModuleScript")
				rawset(leaf, "_source", childPath)
				addChild(node, leaf)
			end
		end
		return node
	end
	error(`shim: not a directory: {path}`)
end

--------------------------------------------------------------------------------
-- Enum proxy (lazily creates unknown enums/items)
--------------------------------------------------------------------------------

-- Marks a table as a fake EnumItem. A private key rather than a field, so it
-- cannot collide with a real member name and does not show up in iteration.
--
-- It exists because ProfileStore guards VersionQuery with
--   typeof(sort_direction) ~= "EnumItem" or sort_direction.EnumType ~= Enum.SortDirection
-- and Scribe reaches that guard (src/Server/Persistence.luau:1889). Passing the
-- guard needs BOTH halves: a typeof that answers "EnumItem" and an EnumType that
-- is identity-equal to the enum object -- a string EnumType fails, and so does the
-- object with the shim's ordinary typeof. Only a simulation env supplies the
-- typeof half (test/Sim/Env.luau); this marker is how it recognises what to lie
-- about, and its scope is exactly the one chunk that needs the lie.
local ENUM_ITEM_MARKER = {}

local Enum = setmetatable({}, {
	__index = function(self, enumName)
		local created = {}
		local nextValue = 0
		local enumType
		enumType = setmetatable({
			FromValue = function(_self, value)
				for _, item in created do
					if item.Value == value then
						return item
					end
				end
				error(`no {enumName} item with value {value}`)
			end,
			GetEnumItems = function(_self)
				return table.clone(created)
			end,
		}, {
			__index = function(itemsSelf, itemName)
				local item = setmetatable({
					Name = itemName,
					Value = nextValue,
					-- The enum OBJECT, not its name. Real EnumItem.EnumType is the
					-- Enum, and ProfileStore compares it by identity. The only
					-- reader in this tree is src/Internal/Datatypes.luau:483, which
					-- does tostring(value.EnumType) -- and the object's __tostring
					-- returns enumName, so that string is unchanged.
					EnumType = enumType,
					[ENUM_ITEM_MARKER] = true,
				}, {
					__tostring = function()
						return `Enum.{enumName}.{itemName}`
					end,
				})
				nextValue += 1
				table.insert(created, item)
				rawset(itemsSelf, itemName, item)
				return item
			end,
			__tostring = function()
				return enumName
			end,
		})
		rawset(self, enumName, enumType)
		return enumType
	end,
})

--------------------------------------------------------------------------------
-- Fake Roblox datatypes: only the surface Scribe's datatype codecs touch.
--------------------------------------------------------------------------------

local DT_MARKER = {}

local function dt(typeName, fields)
	fields[DT_MARKER] = typeName
	return fields
end

local function isFakeDatatype(value)
	return type(value) == "table" and rawget(value, DT_MARKER) ~= nil
end

local FakeVector3 = {
	new = function(x, y, z)
		return dt("Vector3", { X = x or 0, Y = y or 0, Z = z or 0 })
	end,
}
FakeVector3.zero = FakeVector3.new(0, 0, 0)

local FakeVector2 = {
	new = function(x, y)
		return dt("Vector2", { X = x or 0, Y = y or 0 })
	end,
}

local FakeVector3int16 = {
	new = function(x, y, z)
		return dt("Vector3int16", { X = x or 0, Y = y or 0, Z = z or 0 })
	end,
}

local FakeVector2int16 = {
	new = function(x, y)
		return dt("Vector2int16", { X = x or 0, Y = y or 0 })
	end,
}

local function cframeFromComponents(...)
	local components = { ... }
	return dt("CFrame", {
		GetComponents = function(_self)
			return table.unpack(components)
		end,
	})
end

local FakeCFrame = {}

-- Mirrors the real CFrame.new overload set: 3 arguments (position, identity
-- rotation), 7 (position + quaternion), and 12 (position + the nine rotation
-- components VERBATIM -- Roblox does not re-orthonormalize them, which is why
-- GetComponents is its exact inverse and why the codec's exact form round-trips).
function FakeCFrame.new(...)
	local argc = select("#", ...)
	if argc >= 12 then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = ...
		return cframeFromComponents(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	end
	local x, y, z, qx, qy, qz, qw = ...
	if qx == nil then
		return cframeFromComponents(x or 0, y or 0, z or 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
	return cframeFromComponents(
		x,
		y,
		z,
		1 - 2 * (qy * qy + qz * qz),
		2 * (qx * qy - qz * qw),
		2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw),
		1 - 2 * (qx * qx + qz * qz),
		2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw),
		2 * (qy * qz + qx * qw),
		1 - 2 * (qx * qx + qy * qy)
	)
end

function FakeCFrame.fromMatrix(pos, vX, vY, vZ)
	vZ = vZ or FakeVector3.new(vX.Y * vY.Z - vX.Z * vY.Y, vX.Z * vY.X - vX.X * vY.Z, vX.X * vY.Y - vX.Y * vY.X)
	return cframeFromComponents(pos.X, pos.Y, pos.Z, vX.X, vY.X, vZ.X, vX.Y, vY.Y, vZ.Y, vX.Z, vY.Z, vZ.Z)
end

FakeCFrame.identity = FakeCFrame.new(0, 0, 0)

local FakeColor3 = {
	new = function(r, g, b)
		return dt("Color3", { R = r or 0, G = g or 0, B = b or 0 })
	end,
}
FakeColor3.fromRGB = function(r, g, b)
	return FakeColor3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end

local FakeBrickColor = {
	new = function(number)
		return dt("BrickColor", { Number = number, Name = `Mock{number}` })
	end,
}

local FakeUDim = {
	new = function(scale, offset)
		return dt("UDim", { Scale = scale or 0, Offset = offset or 0 })
	end,
}

local FakeUDim2 = {
	new = function(sx, ox, sy, oy)
		return dt("UDim2", { X = FakeUDim.new(sx, ox), Y = FakeUDim.new(sy, oy) })
	end,
}

local FakeRect = {
	new = function(minV, maxV)
		return dt("Rect", { Min = minV, Max = maxV })
	end,
}

local FakeNumberRange = {
	new = function(minValue, maxValue)
		return dt("NumberRange", { Min = minValue, Max = maxValue or minValue })
	end,
}

local FakeNumberSequenceKeypoint = {
	new = function(time, value, envelope)
		return dt("NumberSequenceKeypoint", { Time = time, Value = value, Envelope = envelope or 0 })
	end,
}

local FakeNumberSequence = {
	new = function(keypoints)
		if type(keypoints) == "number" then
			keypoints = {
				FakeNumberSequenceKeypoint.new(0, keypoints),
				FakeNumberSequenceKeypoint.new(1, keypoints),
			}
		end
		return dt("NumberSequence", { Keypoints = keypoints })
	end,
}

local FakeColorSequenceKeypoint = {
	new = function(time, color)
		return dt("ColorSequenceKeypoint", { Time = time, Value = color })
	end,
}

local FakeColorSequence = {
	new = function(keypoints)
		if isFakeDatatype(keypoints) then
			keypoints = {
				FakeColorSequenceKeypoint.new(0, keypoints),
				FakeColorSequenceKeypoint.new(1, keypoints),
			}
		end
		return dt("ColorSequence", { Keypoints = keypoints })
	end,
}

local FakeDateTime = {
	fromUnixTimestampMillis = function(ms)
		return dt("DateTime", { UnixTimestampMillis = ms })
	end,
}
FakeDateTime.now = function()
	return FakeDateTime.fromUnixTimestampMillis(os.time() * 1000)
end

local FakeFont = {
	new = function(family, weight, style)
		return dt("Font", {
			Family = family,
			Weight = weight or Enum.FontWeight.Regular,
			Style = style or Enum.FontStyle.Normal,
		})
	end,
}

local FakePhysicalProperties = {
	new = function(density, friction, elasticity, frictionWeight, elasticityWeight)
		return dt("PhysicalProperties", {
			Density = density,
			Friction = friction or 0.3,
			Elasticity = elasticity or 0.5,
			FrictionWeight = frictionWeight or 1,
			ElasticityWeight = elasticityWeight or 1,
		})
	end,
}

--------------------------------------------------------------------------------
-- Services and game
--------------------------------------------------------------------------------

local services = {}

-- Fixed start for the GUID sequence, so a full run produces the same ids every
-- time. Arbitrary but nonzero: xorshift32 has zero as a fixed point.
local GUID_SEED = 0x5C21BE01
local guidState = GUID_SEED

services.HttpService = {
	JSONEncode = function(_self, value)
		return serde.encode("json", value)
	end,
	JSONDecode = function(_self, text)
		return serde.decode("json", text)
	end,
	-- Deterministic, NOT math.random. Util.guid() feeds gift ids and (via
	-- FakeProfileStore) version ids, and both end up inside persisted data -- so an
	-- unseeded generator here means the stored state differs on every run and any
	-- digest taken over it is worthless for replay. Uniqueness is what a GUID is
	-- for; unpredictability is not, and the harness needs reproducibility more.
	--
	-- Same xorshift32 as test/Sim/Rng.luau, and for the same reason: an LCG with a
	-- ~2^30 multiplier overflows the double mantissa and drops its low bits.
	GenerateGUID = function(_self, _wrapped)
		local hex = "0123456789abcdef"
		local out = {}
		for i = 1, 36 do
			if i == 9 or i == 14 or i == 19 or i == 24 then
				out[i] = "-"
			else
				guidState = bit32.bxor(guidState, bit32.lshift(guidState, 13))
				guidState = bit32.bxor(guidState, bit32.rshift(guidState, 17))
				guidState = bit32.bxor(guidState, bit32.lshift(guidState, 5))
				local index = (guidState % 16) + 1
				out[i] = string.sub(hex, index, index)
			end
		end
		return table.concat(out)
	end,
	--- Re-pin the GUID sequence. A simulation that replays a seed calls this first,
	--- or the ids it stores depend on how many guids every earlier spec happened to
	--- consume.
	ResetGuidSequence = function(_self, seed: number?)
		guidState = seed or GUID_SEED
	end,
}

services.LogService = {} -- no structured methods -> Scribe falls back to print/warn

services.RunService = {
	IsStudio = function()
		return false
	end,
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
	IsRunning = function()
		return true
	end,
	PostSimulation = FakeSignal.new(),
	Heartbeat = FakeSignal.new(),
}

services.Players = {
	PlayerAdded = FakeSignal.new(),
	PlayerRemoving = FakeSignal.new(),
	PlayerMembershipChanged = FakeSignal.new(),
	GetPlayers = function()
		return {}
	end,
	GetPlayerByUserId = function()
		return nil
	end,
	GetNameFromUserIdAsync = function(_self, userId)
		return `User{userId}`
	end,
}

services.MarketplaceService = {
	ProcessReceipt = nil,
	PromptGamePassPurchaseFinished = FakeSignal.new(),
	-- Test-controllable gamepass ownership. OwnedGamePasses[passId] = true marks a
	-- pass owned; OwnsYield makes the check yield once (to exercise the async
	-- cold-cache path). Both default to "nobody owns anything, resolve synchronously".
	OwnedGamePasses = {},
	OwnsYield = false,
	UserOwnsGamePassAsync = function(self, _userId, passId)
		if self.OwnsYield then
			task.wait()
		end
		return self.OwnedGamePasses[passId] == true
	end,
	PromptProductPurchase = function()
		error("shim: PromptProductPurchase is not available headless (inject options.PromptProductPurchase)")
	end,
}

services.AnalyticsService = {
	_events = 0,
	LogEconomyEvent = function(self)
		self._events += 1
	end,
}

-- A simulation installs a modelled backend here; with nothing installed this
-- behaves exactly as it always has, and the two error strings below are
-- byte-identical to the originals on purpose. test/Specs/LeaderboardMode.spec
-- names that GetOrderedDataStore error as its discriminator, so changing a word
-- of it silently rewrites what that spec asserts.
--
-- The TABLE is mutated in place and never replaced: src/Server/Leaderboards.luau:6
-- captures it into a module upvalue at load time, and modules load once, so a
-- replacement object would be invisible to the one caller that matters.
local installedDataStore = nil

services.DataStoreService = {
	Install = function(_self, impl)
		installedDataStore = impl
	end,
	Reset = function(_self)
		installedDataStore = nil
	end,
	GetOrderedDataStore = function(_self, name, scope)
		if installedDataStore then
			return installedDataStore:GetOrderedDataStore(name, scope)
		end
		error("shim: OrderedDataStores are not available headless (run with UseMock)")
	end,
	GetDataStore = function(_self, name, scope, options)
		if installedDataStore then
			return installedDataStore:GetDataStore(name, scope, options)
		end
		error("shim: DataStores are not available headless (run with UseMock)")
	end,
	GetRequestBudgetForRequestType = function(_self, kind)
		if installedDataStore then
			return installedDataStore:GetRequestBudgetForRequestType(kind)
		end
		return 0
	end,
}

services.ReplicatedStorage = newInstance("ReplicatedStorage", "ReplicatedStorage")
services.ServerScriptService = newInstance("ServerScriptService", "ServerScriptService")
services.ServerStorage = newInstance("ServerStorage", "ServerStorage")

local game = {
	PlaceId = 0,
	JobId = "shim-job",
	GetService = function(_self, name)
		local service = services[name]
		if not service then
			error(`shim: unknown service "{name}"`)
		end
		return service
	end,
	-- Headless: the shutdown drain is exercised directly via ctx.Persistence.Shutdown
	-- in Shutdown.spec, so registered close callbacks are intentionally not invoked.
	BindToClose = function() end,
}

local InstanceLib = {
	new = function(className)
		return newInstance(className, className)
	end,
}

--------------------------------------------------------------------------------
-- Mini TestEZ (describe/it/expect subset; same API surface as real TestEZ)
--------------------------------------------------------------------------------

local Expectation = {}
Expectation.__index = function(self, key)
	if key == "_value" or key == "_negate" then
		return nil -- expect(nil) stores a nil value; don't treat as a matcher
	end
	if key == "to" or key == "be" or key == "been" or key == "have" or key == "was" or key == "at" then
		return self
	elseif key == "never" then
		return setmetatable({ _value = self._value, _negate = not self._negate }, Expectation)
	elseif key == "equal" then
		return function(expected)
			local pass = self._value == expected
			if self._negate then
				pass = not pass
			end
			if not pass then
				error(
					`expected {if self._negate then "anything but " else ""}{tostring(expected)}, got {tostring(
						self._value
					)}`,
					2
				)
			end
			return self
		end
	elseif key == "ok" then
		return function()
			local pass = self._value ~= nil
			if self._negate then
				pass = not pass
			end
			if not pass then
				error(`expected value {if self._negate then "" else "not "}to be nil, got {tostring(self._value)}`, 2)
			end
			return self
		end
	elseif key == "near" then
		return function(expected, limit)
			local pass = math.abs(self._value - expected) <= (limit or 1e-7)
			if self._negate then
				pass = not pass
			end
			if not pass then
				error(`expected {tostring(self._value)} to be near {tostring(expected)}`, 2)
			end
			return self
		end
	elseif key == "throw" then
		return function(message)
			local ok, err = pcall(self._value)
			local pass = not ok and (message == nil or string.find(tostring(err), message, 1, true) ~= nil)
			if self._negate then
				pass = ok
			end
			if not pass then
				error(
					`expected function {if self._negate then "not " else ""}to throw{if message
						then ` "{message}"`
						else ""}, got {tostring(err)}`,
					2
				)
			end
			return self
		end
	end
	error(`unknown expectation "{tostring(key)}"`, 2)
end

local function expect(value)
	return setmetatable({ _value = value, _negate = false }, Expectation)
end

local runnerState = nil -- current describe node during collection

local function newNode(name)
	return { Name = name, Children = {}, Tests = {}, BeforeEach = {}, AfterEach = {} }
end

local function describe(name, fn)
	local parent = runnerState
	local node = newNode(name)
	table.insert(parent.Children, node)
	runnerState = node
	local ok, err = pcall(fn)
	runnerState = parent
	if not ok then
		table.insert(node.Tests, {
			Name = "(describe body)",
			Fn = function()
				error(err)
			end,
		})
	end
end

local function it(name, fn)
	table.insert(runnerState.Tests, { Name = name, Fn = fn })
end

local function itSKIP(name, _fn)
	table.insert(runnerState.Tests, { Name = name, Skip = true })
end

local function beforeEach(fn)
	table.insert(runnerState.BeforeEach, fn)
end

local function afterEach(fn)
	table.insert(runnerState.AfterEach, fn)
end

--------------------------------------------------------------------------------
-- Module loader
--------------------------------------------------------------------------------

local baseGlobals = {}

local moduleCache = {}

-- Which shim globals a module has to be handed as PARAMETERS rather than read as
-- globals. Filled in below, once baseGlobals is complete.
--
-- Handing `luau.load` an `environment` table is what made this harness slow, and
-- the flag everyone reaches for is not the cause: a chunk whose globals are a
-- caller-supplied table is not a SAFE environment, so Luau declines the FASTCALL
-- path and every `math.max` becomes a real global lookup plus a real call.
-- Measured at 4.2x on a builtin-saturated body, and 1.0x on plain arithmetic --
-- which is exactly why a single blanket correction factor was never right.
--
-- So modules load against the process's real globals, and the names the shim has
-- to override are passed in as parameters instead. A parameter shadows a global
-- lexically, while `math`/`table`/`string` stay true globals -- which is the
-- condition Luau needs to emit FASTCALL.
local passName = { script = true }

local function shimRequire(target)
	if not isFakeInstance(target) then
		error(`shim: require expects a ModuleScript instance, got {type(target)}`)
	end
	local cached = moduleCache[target]
	if cached ~= nil then
		return cached.value
	end
	local source = rawget(target, "_source")
	if not source then
		error(`shim: {target:GetFullName()} is not a ModuleScript`)
	end

	local text = fs.readFile(source)

	-- Only the names this module actually writes down. Every parameter costs a
	-- register for the life of the chunk and Luau allows 200 locals per function,
	-- so handing all of them to every module would spend that budget on files that
	-- use none. Scanning for identifier tokens OVER-approximates -- a name inside a
	-- comment counts, and so does the `unpack` in `table.unpack` -- and that is the
	-- safe direction: a spare parameter costs one register, a missing one is a
	-- silent wrong answer. Never tighten this into an exact-use analysis.
	local mentioned = {}
	for word in string.gmatch(text, "[%a_][%w_]*") do
		if passName[word] then
			mentioned[word] = true
		end
	end
	local params = {}
	for name in mentioned do
		table.insert(params, name)
	end
	table.sort(params)

	-- The whole prefix sits on line 1 and the closing `end` goes on its own line
	-- AFTER the source, so every line of the module keeps its real number in error
	-- messages and tracebacks.
	local wrapped = `return function({table.concat(params, ", ")}) ` .. text .. "\n" .. "end"
	local chunk = luau.load(wrapped, {
		debugName = target:GetFullName(),
		injectGlobals = true,
	})

	local args = table.create(#params)
	for index, name in params do
		args[index] = if name == "script" then target else baseGlobals[name]
	end

	local value = chunk()(table.unpack(args, 1, #params))
	moduleCache[target] = { value = value }
	return value
end

local shimDebug = {
	traceback = function(message, _level)
		local native = debug and debug.traceback
		if native then
			return native(tostring(message or ""), 2)
		end
		return tostring(message or "")
	end,
	info = debug and debug.info,
}

local function shimTypeof(value)
	if isFakeInstance(value) then
		return "Instance"
	end
	if isFakeDatatype(value) then
		return rawget(value, DT_MARKER)
	end
	return typeof(value)
end

for key, value in
	{
		assert = assert,
		error = error,
		ipairs = ipairs,
		next = next,
		pairs = pairs,
		pcall = pcall,
		print = print,
		rawequal = rawequal,
		rawget = rawget,
		rawlen = rawlen,
		rawset = rawset,
		getmetatable = getmetatable,
		setmetatable = setmetatable,
		select = select,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		unpack = table.unpack,
		xpcall = xpcall,
		warn = warn or print,

		bit32 = bit32,
		buffer = buffer,
		coroutine = coroutine,
		math = math,
		os = os,
		string = string,
		table = table,
		utf8 = utf8,
		debug = shimDebug,

		task = task,
		game = game,
		Enum = Enum,
		Instance = InstanceLib,
		typeof = shimTypeof,
		require = shimRequire,

		Vector3 = FakeVector3,
		Vector2 = FakeVector2,
		Vector3int16 = FakeVector3int16,
		Vector2int16 = FakeVector2int16,
		CFrame = FakeCFrame,
		Color3 = FakeColor3,
		BrickColor = FakeBrickColor,
		UDim = FakeUDim,
		UDim2 = FakeUDim2,
		Rect = FakeRect,
		NumberRange = FakeNumberRange,
		NumberSequence = FakeNumberSequence,
		NumberSequenceKeypoint = FakeNumberSequenceKeypoint,
		ColorSequence = FakeColorSequence,
		ColorSequenceKeypoint = FakeColorSequenceKeypoint,
		DateTime = FakeDateTime,
		Font = FakeFont,
		PhysicalProperties = FakePhysicalProperties,

		-- Test framework globals (only spec modules call these).
		describe = describe,
		it = it,
		itSKIP = itSKIP,
		itFOCUS = it,
		xit = itSKIP,
		beforeEach = beforeEach,
		afterEach = afterEach,
		expect = expect,
	}
do
	baseGlobals[key] = value
end

--------------------------------------------------------------------------------
-- Build the DataModel mirror of test.project.json and collect specs
--------------------------------------------------------------------------------

local root = newInstance("ScribeDev", "Folder")
addChild(root, buildTree("Scribe", "src"))
addChild(root, buildTree("Test", "test"))

-- The escape hatch a simulation needs, and the ONLY one.
--
-- test/Sim builds each simulated server its own environment: its own clock, its
-- own scheduler, its own JobId, its own copy of every module. That needs raw
-- chunk loading -- but `@lune/luau` and `@lune/fs` are unreachable from a module
-- the shim loaded, because shimRequire only resolves fake Instances. So the
-- capability is handed down explicitly here rather than left to be smuggled.
--
-- Inert with respect to the LIBRARY: nothing in src/ reads it, and reading it does
-- nothing until something calls LoadChunk. It is NOT unread by tests, which this
-- comment used to claim: test/Sim/ loads fork source through it (Loader, Bundle, Env,
-- Server), and four places under test/ read `__SimHost.Env` as the only way to see a
-- process environment variable at all -- SimSoak.spec:47 (SCRIBE_SOAK),
-- SimStudy.spec:20 (SCRIBE_STUDY), TestCtx.luau:114 (SCRIBE_FRAGMENT_ALL) and
-- RngSeam.spec:105. Every mode gate in the suite runs through this table.
baseGlobals.__SimHost = {
	ReadSource = function(path: string): string
		return fs.readFile(path)
	end,
	LoadChunk = function(source: string, env, name: string)
		return luau.load(source, { debugName = name, environment = env, injectGlobals = false })
	end,
	-- Copy this; never mutate it. Every simulated server derives its globals from
	-- these, so a mutation would leak across servers and out into the suite.
	BaseGlobals = baseGlobals,
	Root = root,
	-- THE Enum object. ProfileStore compares EnumType by identity, so a simulation
	-- must hand out items from this one, not a rebuilt copy.
	Enum = Enum,
	IsEnumItem = function(value): boolean
		return type(value) == "table" and rawget(value, ENUM_ITEM_MARKER) == true
	end,
	Typeof = shimTypeof,
	-- Process environment, for specs that gate a deep run behind a variable.
	-- Handed down rather than reachable: @lune/process cannot be required from a
	-- shim-loaded module, and a spec that tried would silently get a false answer
	-- instead of an error -- which is exactly how a soak stops running without
	-- anyone noticing.
	Env = process.env,
}

-- baseGlobals is complete, so the override set can be worked out.
--
-- COMPUTED, never written down, because both ways of getting the list wrong are
-- silent. Most of these names do not resolve natively at all, so omitting one
-- raises. But `typeof`, `require`, `debug` and `unpack` all DO resolve under Lune
-- -- to something other than the shim's version -- so a module handed the native
-- one would quietly do the wrong thing instead of failing. (`unpack` is the one
-- that gets missed: Lune's global `unpack` is not `table.unpack`.) A name added
-- to baseGlobals later would land in the same trap. Probing each key against its
-- native value and passing it whenever the two differ makes both cases
-- impossible rather than merely documented.
do
	local function nativeGlobal(name: string)
		local ok, chunk = pcall(luau.load, "return " .. name, {
			debugName = "probe:" .. name,
			injectGlobals = true,
		})
		if not ok then
			return nil
		end
		local ranOk, value = pcall(chunk)
		if not ranOk then
			return nil
		end
		return value
	end

	for key, value in baseGlobals do
		if not rawequal(nativeGlobal(key), value) then
			passName[key] = true
		end
	end
end

local specsFolder = root._children.Test._children.Specs
if not specsFolder then
	print("No test/Specs folder found")
	process.exit(1)
end

local plan = newNode("root")
local collectErrors = {}

local specNames = {}
for name in rawget(specsFolder, "_children") do
	table.insert(specNames, name)
end
table.sort(specNames)

for _, name in specNames do
	local child = rawget(specsFolder, "_children")[name]
	if string.sub(name, -5) == ".spec" then
		local ok, result = pcall(shimRequire, child)
		if not ok then
			table.insert(collectErrors, `{name}: failed to load: {result}`)
			continue
		end
		if type(result) ~= "function" then
			table.insert(collectErrors, `{name}: spec module must return a function`)
			continue
		end
		runnerState = plan
		describe(string.sub(name, 1, -6), result)
	end
end
runnerState = nil

--------------------------------------------------------------------------------
-- Execute
--------------------------------------------------------------------------------

local passed, failed, skipped = 0, 0, 0
local failures = {}

local function runStep(fn)
	local done = false
	local ok, err = true, nil
	task.spawn(function()
		ok, err = xpcall(fn, function(e)
			local traceback = shimDebug.traceback(e, 2)
			return traceback
		end)
		done = true
	end)
	local deadline = os.clock() + TEST_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait(0.02)
	end
	if not done then
		return false, `timed out after {TEST_TIMEOUT}s`
	end
	return ok, err
end

local function runNode(node, ancestors, path)
	local chain = table.clone(ancestors)
	table.insert(chain, node)

	for _, test in node.Tests do
		local label = `{path}{test.Name}`
		if test.Skip then
			skipped += 1
			print(`  SKIP  {label}`)
			continue
		end
		local ok, err = true, nil
		for _, level in chain do
			for _, hook in level.BeforeEach do
				ok, err = runStep(hook)
				if not ok then
					break
				end
			end
			if not ok then
				break
			end
		end
		if ok then
			ok, err = runStep(test.Fn)
		end
		for i = #chain, 1, -1 do
			for _, hook in chain[i].AfterEach do
				local hookOk, hookErr = runStep(hook)
				if ok and not hookOk then
					ok, err = hookOk, hookErr
				end
			end
		end
		if ok then
			passed += 1
			print(`  PASS  {label}`)
		else
			failed += 1
			table.insert(failures, { Label = label, Error = err })
			print(`  FAIL  {label}`)
			print(`        {tostring(err)}`)
		end
	end

	for _, child in node.Children do
		runNode(child, chain, `{path}{child.Name} > `)
	end
end

print("Running Scribe test suite (headless shim)...")
local startedAt = os.clock()
runNode(plan, {}, "")
local duration = os.clock() - startedAt

print("")
for _, message in collectErrors do
	failed += 1
	print(`  LOAD FAIL  {message}`)
end

-- Modules now share the process's real global table, so a `local` left off a
-- top-level name would leak into every other module instead of dying inside that
-- module's private env copy -- which is the one property the old loader had and
-- this one does not. Lune keeps its own builtins behind a metatable, so anything
-- ENUMERABLE here was written by this run.
--
-- After the last test, never before: `getfenv` permanently deoptimizes the
-- environment it is asked about, and calling it early costs the whole suite the
-- speedup this loader exists for. Nothing else in lune/, src/ or test/ calls it.
for key in getfenv(0) do
	if key ~= "_G" then
		failed += 1
		print(`  GLOBAL LEAK  a module assigned the global \`{tostring(key)}\`; add the missing \`local\``)
	end
end
print(string.format("%d passed, %d failed, %d skipped in %.2fs", passed, failed, skipped, duration))

if #failures > 0 then
	print("\nFailures:")
	for _, failure in failures do
		print(`  - {failure.Label}`)
	end
end

process.exit(if failed > 0 then 1 else 0)
