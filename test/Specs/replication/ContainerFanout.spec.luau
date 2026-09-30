--!nonstrict
-- A whole-table write changes every leaf beneath it. `fire` only touches the
-- written pathKey and `fireAncestors` only walks upward, so without an explicit
-- descendant pass a bound Observe/Changed renders a stale value forever while
-- Get() returns the new one: silent, permanent, and on the ergonomic centerpiece.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local TestCtx = require(Root.Test.Helpers.TestCtx)

it("a whole-container Set fires Changed/Observe on descendant leaves", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	local observed, changed = 0, 0
	local lastObserved
	data.Settings.Music.Observe(function(v)
		observed += 1
		lastObserved = v
	end)
	data.Settings.Sfx.Changed(function()
		changed += 1
	end)
	-- Observe fires once immediately; count only what the Set causes.
	local base = observed

	data.Settings.Set({ Music = false, Sfx = false })

	expect(data.Settings.Music.Get()).toBe(false)
	expect(observed - base).toBe(1)
	expect(lastObserved).toBe(false)
	expect(changed).toBe(1)

	harness.Cleanup()
end)

it("fires only the descendants that actually changed", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	data.Settings.Set({ Music = true, Sfx = true })
	local music, sfx = 0, 0
	data.Settings.Music.Changed(function()
		music += 1
	end)
	data.Settings.Sfx.Changed(function()
		sfx += 1
	end)

	-- Sfx keeps its value, so only Music may fire.
	data.Settings.Set({ Music = false, Sfx = true })
	expect(music).toBe(1)
	expect(sfx).toBe(0)

	harness.Cleanup()
end)

it("does not double-fire the written container's own listener", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	local container = 0
	data.Settings.Changed(function()
		container += 1
	end)
	data.Settings.Set({ Music = false, Sfx = false })
	expect(container).toBe(1)

	harness.Cleanup()
end)

it("reaches a dictionary element's leaf", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	data.Inventory.Sword.Set({ Health = 1, Dmg = 1 })
	local dmg = 0
	data.Inventory.Sword.Dmg.Changed(function()
		dmg += 1
	end)

	data.Inventory.Set({ Sword = { Health = 1, Dmg = 9 } })
	expect(data.Inventory.Sword.Dmg.Get()).toBe(9)
	expect(dmg).toBe(1)

	harness.Cleanup()
end)

it("Clear fires descendant leaves too", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	data.Inventory.Sword.Set({ Health = 5, Dmg = 5 })
	local dmg = 0
	data.Inventory.Sword.Dmg.Changed(function()
		dmg += 1
	end)

	data.Inventory.Clear()
	expect(dmg).toBe(1)

	harness.Cleanup()
end)

it("Remove ignores an out-of-range index instead of destroying a real element", function()
	local harness = TestCtx.make()
	local _p, _e, data = harness.Join()

	data.QuestProgress.Insert(10)
	data.QuestProgress.Insert(20)
	data.QuestProgress.Insert(30)

	-- Past the end: used to clamp to #arr and delete the LAST element.
	expect(data.QuestProgress.Remove(99)).toBe(nil)
	expect(data.QuestProgress.Count()).toBe(3)
	-- Below the start: used to clamp to 1 and delete the FIRST element.
	expect(data.QuestProgress.Remove(0)).toBe(nil)
	expect(data.QuestProgress.Count()).toBe(3)
	expect(data.QuestProgress[1].Get()).toBe(10)
	expect(data.QuestProgress[3].Get()).toBe(30)

	-- In range still works, and no argument still means the last element.
	expect(data.QuestProgress.Remove(1)).toBe(10)
	expect(data.QuestProgress.Remove()).toBe(30)
	expect(data.QuestProgress.Count()).toBe(1)

	harness.Cleanup()
end)
