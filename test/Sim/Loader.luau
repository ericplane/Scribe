--!nonstrict
-- Loading modules OUTSIDE the harness's shared cache, so a simulation can build
-- many independent servers from the same source on disk.
--
-- The harness caches every module by Instance and hands them all one set of
-- globals, which is right for a test suite: modules are singletons in Roblox too,
-- and a spec wants the same Scribe every other spec has. It is wrong for a
-- simulation. Two simulated servers must disagree about what time it is, which
-- JobId they hold, and what their module-global state contains -- ProfileStore
-- keeps its session bookkeeping in upvalues, and Scribe keeps Health's failure
-- counters in module locals. Shared, "two servers" would be one server counted
-- twice, and every cross-server bug would be invisible by construction.
--
-- So this loads chunks fresh, with a caller-supplied environment and a private
-- cache. `__SimHost` (lune/run-tests.luau) is what makes that possible: modules
-- the shim loaded cannot reach @lune/fs or @lune/luau, so the capability is
-- handed down explicitly rather than smuggled.

local SimHost = __SimHost

local Loader = {}

export type Env = { [string]: any }
export type Cache = { [any]: { Value: any } }

-- Source text is immutable for a run, so it is read once per path no matter how
-- many servers load it. At ~2,200 lines for ProfileStore alone and one load per
-- server, re-reading would be the dominant cost of building a universe.
local sourceCache: { [string]: string } = {}

--- Read a file, cached for the process.
function Loader.Source(path: string): string
	local cached = sourceCache[path]
	if cached == nil then
		cached = SimHost.ReadSource(path)
		sourceCache[path] = cached
	end
	return cached
end

--- Compile and RUN `source` with `env` as its complete global table, returning
--- whatever the chunk returns.
---
--- `env` is the module's entire world: anything absent is nil inside it, not
--- inherited. That is the property the simulation is built on, and also the
--- easiest way to get a confusing failure -- a missing `string` reads as "attempt
--- to index nil", nowhere near the omission.
function Loader.LoadChunk(source: string, env: Env, debugName: string): any
	local chunk = SimHost.LoadChunk(source, env, debugName)
	return chunk()
end

--- A private module cache. One per simulated server.
function Loader.NewCache(): Cache
	return {}
end

--- The safe standard library, freshly copied.
---
--- Deliberately WITHOUT os, task, game, typeof, Enum, Instance, script and
--- require. Those are the per-server ones -- the clock, the scheduler, the server
--- identity -- and defaulting any of them would hand a simulated server the real
--- one silently, which is the failure mode this whole file exists to prevent.
--- Omission gives a loud nil; a default would give a wrong answer.
function Loader.BaseEnv(): Env
	return {
		assert = assert,
		error = error,
		ipairs = ipairs,
		next = next,
		pairs = pairs,
		pcall = pcall,
		print = print,
		warn = warn,
		select = select,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		rawequal = rawequal,
		rawget = rawget,
		rawlen = rawlen,
		rawset = rawset,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		unpack = table.unpack,
		xpcall = xpcall,

		bit32 = bit32,
		buffer = buffer,
		coroutine = coroutine,
		debug = debug,
		math = math,
		string = string,
		table = table,
		utf8 = utf8,
	}
end

--- Require a module Instance into `cache`, loading it fresh rather than reusing
--- the harness's copy.
---
--- Requires made INSIDE the loaded module resolve through this same cache, so one
--- server's Scribe is internally consistent -- its Persistence and its Health and
--- its Node are each other's, not another server's. `overrides` is applied last,
--- which is how a server pins its own Clock/Sched implementations.
function Loader.RequireFresh(target: any, cache: Cache, overrides: Env?): any
	local cached = cache[target]
	if cached ~= nil then
		return cached.Value
	end

	local path = rawget(target, "_source")
	if not path then
		error(`sim: {target:GetFullName()} is not a ModuleScript`)
	end

	local env = Loader.BaseEnv()
	for key, value in overrides or {} do
		env[key] = value
	end
	env.script = target
	env.require = function(child: any)
		return Loader.RequireFresh(child, cache, overrides)
	end

	-- Seed the cache BEFORE running the chunk. Luau modules can require each other
	-- in a cycle, and without this a cycle would recurse until the stack gave out
	-- rather than resolving to the partially-built table the way the real loader
	-- does. The value is filled in below.
	local entry = { Value = nil :: any }
	cache[target] = entry
	entry.Value = Loader.LoadChunk(Loader.Source(path), env, target:GetFullName())
	return entry.Value
end

return Loader
