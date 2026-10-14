--!nonstrict
-- The session cache is reserved; public reads return copies.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local PASS_ID = 4401
local owned = false
local harness: any = nil

afterEach(function()
	owned = false
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

local function make()
	harness = TestCtx.make({
		Template = {
			Coins = Scribe.Int(0, { Min = 0 }),
			Boost = Scribe.Timed(false),
		},
		Options = {
			Passes = { VIP = { Id = PASS_ID } },
			UserOwnsGamePassAsync = function(_userId: number, passId: number): boolean
				return owned and passId == PASS_ID
			end,
		},
	})
	return harness
end

local function attempt(fn): string
	local ok, err = pcall(fn)
	if ok then
		return "allowed"
	end
	return if string.find(tostring(err), "_ScribeSession", 1, true) then "refused" else `raised: {err}`
end

describe("the _ScribeSession root refuses game code", function()
	it("refuses a write to the ownership cache, so Owns stays false", function()
		make()
		local player, _entry, data = harness.Join(88501)
		local direct = attempt(function()
			data._ScribeSession.OwnsCache.VIP.Set(true)
		end)
		local viaGet = attempt(function()
			harness.Data.Get(player)._ScribeSession.OwnsCache.VIP.Set(true)
		end)
		expect(`direct={direct} viaGet={viaGet} owns={harness.Data.Owns(player, "VIP")}`).toBe(
			"direct=refused viaGet=refused owns=false"
		)
	end)

	it("refuses the root's Remove of it", function()
		make()
		local _player, entry, data = harness.Join(88502)
		local verdict = attempt(function()
			data.Remove("_ScribeSession")
		end)
		expect(`{verdict} kept={type(entry.SessionStore._ScribeSession)}`).toBe("refused kept=table")
	end)

	it("refuses Set, Update and Clear on its fields", function()
		make()
		local _player, _entry, data = harness.Join(88503)
		local seen = {}
		table.insert(
			seen,
			attempt(function()
				data._ScribeSession.SaveInfo.Set({ Dirty = false })
			end)
		)
		table.insert(
			seen,
			attempt(function()
				data._ScribeSession.OwnsSynced.Update(function()
					return true
				end)
			end)
		)
		table.insert(
			seen,
			attempt(function()
				data._ScribeSession.Timed.Clear()
			end)
		)
		expect(table.concat(seen, ",")).toBe("refused,refused,refused")
	end)

	it("hands a read back as a copy, so editing it cannot grant a pass", function()
		make()
		local player, _entry, data = harness.Join(88504)
		local cache = data._ScribeSession.OwnsCache.Get()
		cache.VIP = true
		local whole = data._ScribeSession.Get()
		whole.OwnsCache.VIP = true
		expect(`owns={harness.Data.Owns(player, "VIP")}`).toBe("owns=false")
	end)

	it("hands the root's child listeners a copy of it", function()
		make()
		local player, _entry, data = harness.Join(88505)
		local edited = false
		data.OnChildChanged(function(key, value)
			if key == "_ScribeSession" and type(value) == "table" and type(value.OwnsCache) == "table" then
				value.OwnsCache.VIP = true
				edited = true
			end
		end)
		-- Dirtying the profile emits mirrored save info under _ScribeSession.
		data.Coins.Set(3)
		harness.Data.Flush(player)
		task.wait()
		expect(`edited={edited} owns={harness.Data.Owns(player, "VIP")}`).toBe("edited=true owns=false")
	end)
end)

describe("Scribe's own writes to _ScribeSession still land", function()
	it("caches a pass the player owns", function()
		owned = true
		make()
		local player = harness.Join(88506)
		expect(harness.Data.Owns(player, "VIP")).toBe(true)
	end)

	it("mirrors the save info and the timers", function()
		make()
		local player, entry, data = harness.Join(88507)
		local function mirroredDirty()
			return entry.SessionStore._ScribeSession.SaveInfo.Dirty
		end
		data.Coins.Set(4)
		task.wait()
		local dirtyBefore = mirroredDirty()
		harness.Data.Flush(player)
		local dirtyAfter = mirroredDirty()
		data.Boost.SetTimed(true, 60)
		local timed = entry.SessionStore._ScribeSession.Timed
		local timers = 0
		for _ in timed do
			timers += 1
		end
		expect(`before={dirtyBefore} after={dirtyAfter} timers={timers}`).toBe("before=true after=false timers=1")
	end)
end)
