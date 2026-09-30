--!nonstrict
-- Roblox host for unmodified Jest Roblox under Lune. The host owns the fake
-- engine surface and simulation capabilities; Jest owns test execution.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")
local process = require("@lune/process")
local serde = require("@lune/serde")
local datetime = require("@lune/datetime")
local installSnapshots = require("./snapshot-host")

return function()
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
	local nextInstanceId = 0

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
		table.sort(out, function(a, b)
			return a.Name < b.Name
		end)
		return out
	end

	function InstanceMethods.IsA(self, className)
		local ownClass = rawget(self, "ClassName")
		return className == ownClass
			or className == "Instance"
			or (className == "LuaSourceContainer" and ownClass == "ModuleScript")
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
		nextInstanceId += 1
		local instance = setmetatable({
			[INSTANCE_MARKER] = true,
			Name = name,
			ClassName = className,
			Parent = nil,
			_children = {},
			_source = nil,
			_debugId = string.format("host-%08x", nextInstanceId),
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
	--- instead. test/Specs/diagnostics/DebugHookIntegration.spec is the case, and the reason it is
	--- worth supporting here is that it is not a headless problem at all -- headless
	--- the latch is never even reached -- it is what made the Studio run's ordering
	--- decide which of two specs got to measure the hook.
	function InstanceMethods.Clone(self)
		local copy = newInstance(rawget(self, "Name"), rawget(self, "ClassName"))
		rawset(copy, "_source", rawget(self, "_source"))
		rawset(copy, "Source", rawget(self, "Source"))
		for _, child in self:GetChildren() do
			local childCopy = InstanceMethods.Clone(child)
			addChild(copy, childCopy)
		end
		return copy
	end

	local function sourceModule(name, path)
		local node = newInstance(name, "ModuleScript")
		node._source = path
		node.Source = fs.readFile(path)
		return node
	end

	local function buildTree(name, path)
		if fs.isFile(path) then
			return sourceModule(name, path)
		end
		local projectPath = path .. "/default.project.json"
		if fs.isFile(projectPath) then
			local project = serde.decode("json", fs.readFile(projectPath))
			if project.tree["$path"] then
				return buildTree(name, path .. "/" .. project.tree["$path"])
			end
		end
		local node = newInstance(name, "Folder")
		for _, init in { "init.luau", "init.lua" } do
			if fs.isFile(path .. "/" .. init) then
				node = sourceModule(name, path .. "/" .. init)
				break
			end
		end
		local names = fs.readDir(path)
		table.sort(names)
		for _, file in names do
			if file == "init.lua" or file == "init.luau" then
				continue
			end
			local childPath = path .. "/" .. file
			-- Match test.project.json's ignored compiler fixture tree.
			if childPath == "test/roblox-ts" then
				continue
			end
			if fs.isDir(childPath) then
				addChild(node, buildTree(file, childPath))
			elseif string.match(file, "%.luau?$") then
				addChild(node, sourceModule(string.gsub(file, "%.luau?$", ""), childPath))
			end
		end
		return node
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

	-- Lune supplies calendar parsing and formatting; this adapter keeps Roblox's
	-- property names and the DateTime type marker used by Scribe and Jest.
	-- Locale-specific FormatUniversalTime/FormatLocalTime are outside this host:
	-- Lune's strftime patterns differ from Roblox's display-format tokens.
	local DATETIME_VALUE = {}
	local DateTimeMethods = {}
	local DateTimeMeta = {
		__index = DateTimeMethods,
		__eq = function(a, b)
			return a.UnixTimestampMillis == b.UnixTimestampMillis
		end,
	}
	local function wrapDateTime(value)
		return setmetatable(
			dt("DateTime", {
				[DATETIME_VALUE] = value,
				UnixTimestamp = value.unixTimestamp,
				UnixTimestampMillis = value.unixTimestampMillis,
			}),
			DateTimeMeta
		)
	end
	local function calendarFields(value)
		return {
			Year = value.year,
			Month = value.month,
			Day = value.day,
			Hour = value.hour,
			Minute = value.minute,
			Second = value.second,
			Millisecond = value.millisecond,
		}
	end
	function DateTimeMethods:ToIsoDate()
		-- Roblox omits milliseconds here; Jest obtains them from ToUniversalTime.
		return self[DATETIME_VALUE]:formatUniversalTime("%Y-%m-%dT%H:%M:%SZ", "en")
	end
	function DateTimeMethods:ToUniversalTime()
		return calendarFields(self[DATETIME_VALUE]:toUniversalTime())
	end
	function DateTimeMethods:ToLocalTime()
		return calendarFields(self[DATETIME_VALUE]:toLocalTime())
	end
	local function fromCalendar(constructor, year, month, day, hour, minute, second, millisecond)
		return wrapDateTime(constructor({
			year = year,
			month = month or 1,
			day = day or 1,
			hour = hour or 0,
			minute = minute or 0,
			second = second or 0,
			millisecond = millisecond or 0,
		}))
	end
	local function fromTimestampMillis(ms)
		local milliseconds = math.floor(ms)
		local seconds = math.floor(milliseconds / 1000)
		-- Native conversion from fractional seconds can lose a millisecond through
		-- floating-point rounding. Preserve integer codec values across round trips.
		local fields = table.clone(datetime.fromUnixTimestamp(seconds):toUniversalTime())
		fields.millisecond = milliseconds - seconds * 1000
		return wrapDateTime(datetime.fromUniversalTime(fields))
	end
	local FakeDateTime = {
		now = function()
			return wrapDateTime(datetime.now())
		end,
		fromUnixTimestamp = function(seconds)
			return fromTimestampMillis(seconds * 1000)
		end,
		fromUnixTimestampMillis = function(ms)
			return fromTimestampMillis(ms)
		end,
		fromUniversalTime = function(...)
			return fromCalendar(datetime.fromUniversalTime, ...)
		end,
		fromLocalTime = function(...)
			return fromCalendar(datetime.fromLocalTime, ...)
		end,
		fromIsoDate = function(value)
			local ok, result = pcall(datetime.fromIsoDate, value)
			return if ok then wrapDateTime(result) else nil
		end,
	}

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
		PromptProductPurchaseFinished = FakeSignal.new(),
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
	-- byte-identical to the originals on purpose. test/Specs/leaderboards/LeaderboardMode.spec
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

	local baseGlobals = {}
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
		}
	do
		baseGlobals[key] = value
	end

	--------------------------------------------------------------------------------
	-- Build the DataModel mirror of test.project.json for Jest and the simulation
	--------------------------------------------------------------------------------

	local root = newInstance("ScribeDev", "Folder")
	addChild(root, buildTree("Scribe", "src"))
	addChild(root, buildTree("Test", "test"))
	-- Mirrors test.project.json: the add-ons are not part of the package (wally publishes
	-- src only), but their specs drive them, so they have to be reachable.
	local addons = newInstance("Addons", "Folder")
	addChild(addons, buildTree("UI", "addons/ui"))
	addChild(addons, buildTree("Telemetry", "addons/telemetry"))
	addChild(addons, buildTree("Leaderstats", "addons/leaderstats"))
	addChild(root, addons)

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

	local host = {
		globals = baseGlobals,
		root = root,
		services = services,
		methods = InstanceMethods,
		newInstance = newInstance,
		addChild = addChild,
		isInstance = isFakeInstance,
		-- Doc examples use FakePlayer's lifecycle methods with native typeof guards.
		markPlayer = function(player)
			rawset(player, INSTANCE_MARKER, true)
			return player
		end,
	}
	local globals = baseGlobals
	globals.tick = function()
		return FakeDateTime.now().UnixTimestampMillis / 1000
	end
	globals.time = os.clock
	globals.wait = globals.task.wait
	globals.spawn = globals.task.spawn
	globals.delay = globals.task.delay
	globals._G = {}
	globals.shared = {}
	local flags = {}
	function globals.game:DefineFastFlag(name, default)
		if flags[name] == nil then
			flags[name] = default
		end
		return flags[name]
	end
	function globals.game:GetFastFlag(name)
		assert(flags[name] ~= nil, "Unknown fast flag: " .. name)
		return flags[name]
	end
	globals.game.DefineFastInt = globals.game.DefineFastFlag
	globals.game.GetFastInt = globals.game.GetFastFlag
	globals.game.DefineFastString = globals.game.DefineFastFlag
	globals.game.GetFastString = globals.game.GetFastFlag
	host.methods.isA = host.methods.IsA
	host.services.HttpService.UrlEncode = function(_self, value)
		return (
			string.gsub(value, "([^%w%-_%.~])", function(char)
				return string.format("%%%02X", string.byte(char))
			end)
		)
	end

	function host.methods:GetDescendants()
		local result = {}
		local function visit(node)
			for _, child in node:GetChildren() do
				table.insert(result, child)
				visit(child)
			end
		end
		visit(self)
		return result
	end

	function host.methods:IsDescendantOf(ancestor)
		local parent = self.Parent
		while parent do
			if parent == ancestor then
				return true
			end
			parent = parent.Parent
		end
		return false
	end

	function host.methods:FindFirstAncestor(name)
		local parent = self.Parent
		while parent do
			if parent.Name == name then
				return parent
			end
			parent = parent.Parent
		end
		return nil
	end

	function host.methods:GetDebugId()
		return self._debugId
	end

	function host.methods:Destroy()
		if self.Parent then
			self.Parent._children[self.Name] = nil
			self.Parent = nil
		end
	end

	globals.game.ReplicatedStorage = services.ReplicatedStorage
	addChild(services.ReplicatedStorage, root)
	assert(fs.isDir("DevPackages"), "Jest dependencies are missing. Run wally install first.")
	addChild(root, buildTree("DevPackages", "DevPackages"))
	local function load(source, name, additions)
		local env = table.clone(globals)
		for key, value in additions or {} do
			env[key] = value
		end
		return luau.load(source, { debugName = name, environment = env, injectGlobals = true })
	end

	globals.loadstring = function(source, name)
		local ok, chunk = pcall(load, source, name)
		if ok then
			return chunk
		end
		return nil, tostring(chunk)
	end

	local cache = {}
	globals.require = function(target)
		assert(host.isInstance(target), "Host require expects a ModuleScript")
		if cache[target] then
			return cache[target].value
		end
		assert(target.Source, "Module has no source: " .. target:GetFullName())
		local chunk = load(target.Source, target:GetFullName(), { script = target })
		local value = chunk()
		cache[target] = { value = value }
		return value
	end

	function host.start()
		host.heartbeat = globals.task.spawn(function()
			while true do
				local delta = globals.task.wait(0.01)
				host.services.RunService.Heartbeat:Fire(delta)
			end
		end)
	end
	function host.stop()
		if host.heartbeat then
			globals.task.cancel(host.heartbeat)
		end
	end
	installSnapshots(root, services, process.env.SCRIBE_UPDATE_SNAPSHOTS == "1")
	return host
end
