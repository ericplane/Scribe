--!strict
-- MicroProfiler spans and memory attribution. `debug.profilebegin` exists only in the
-- Roblox VM, so the functions are resolved once here and the headless path costs one
-- nil check. There is no exposed Begin/End pair on purpose: an unclosed span skews every
-- label after it for the rest of the frame, so the only entry point wraps the call and
-- closes through the error unwind too.
local Profile = {}

local profileBegin: ((label: string) -> ())? = (debug :: any).profilebegin
local profileEnd: (() -> ())? = (debug :: any).profileend
local setMemoryCategory: ((tag: string) -> ())? = (debug :: any).setmemorycategory

-- Kept so Install can put them back.
local nativeBegin, nativeEnd, nativeCategory = profileBegin, profileEnd, setMemoryCategory

--- Can this VM profile at all? False headless.
function Profile.Available(): boolean
	return profileBegin ~= nil and profileEnd ~= nil
end

--- Substitute the profiler, the way Clock and Sched are substituted. Without the seam
--- the profiling path is unreachable from a test, and two mutations to it survived the
--- whole suite.
function Profile.Install(impl: { Begin: (string) -> (), End: () -> (), Category: ((string) -> ())? })
	profileBegin = impl.Begin
	profileEnd = impl.End
	setMemoryCategory = impl.Category
end

--- Put the real ones back, or the absence of them.
function Profile.Reset()
	profileBegin, profileEnd, setMemoryCategory = nativeBegin, nativeEnd, nativeCategory
end

--- Run `fn` inside a named span and return whatever it returns. The span closes when
--- `fn` raises, and the error is re-raised at level 0 to keep its original message and
--- origin.
---
--- `fn` MUST NOT YIELD. An annotation belongs to the thread's current synchronous slice,
--- so a yield loses it and the close then logs "No active profile annotation" on every
--- call. Measure anything that waits with a Metrics.Observe instead.
function Profile.SyncSpan(label: string, fn: (...any) -> ...any, ...: any): ...any
	-- Read as a pair up front: Install can replace the seam while `fn` runs, and closing
	-- with a different profiler than opened is worse than not profiling.
	local begin, finish = profileBegin, profileEnd
	if begin == nil or finish == nil then
		return fn(...)
	end
	begin(label)
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		finish()
		error(results[2], 0)
	end
	finish()
	return table.unpack(results, 2, results.n)
end

--- Attribute this THREAD's allocations to a category in the developer console.
--- Per thread, so only Scribe's own long-lived loops call it: a write made from game
--- code runs on the caller's thread and stays under their category. Never call it from
--- a handler the engine recycles, or the tag outlives the call.
function Profile.MemoryCategory(tag: string): ()
	if setMemoryCategory ~= nil then
		setMemoryCategory(tag)
	end
end

return Profile
