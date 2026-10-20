--!nonstrict
-- ServerOnly elements must stay hidden in snapshots and later writes.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local Wire = require(ScribeRoot.Internal.Wire)
local Util = require(ScribeRoot.Internal.Util)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local OWNER = 67101
local WATCHER = 67102

-- Cover each container kind and nested elements.
local function hiddenShapes(): { [string]: any }
	return {
		ArrSo = Scribe.ArrayOf(Scribe.ServerOnly(Scribe.Int(0))),
		ArrOptSo = Scribe.ArrayOf(Scribe.Optional(Scribe.ServerOnly(Scribe.Int(0)))),
		ArrSoRec = Scribe.ArrayOf(Scribe.ServerOnly({ P = Scribe.Int(0) })),
		DictSo = Scribe.DictOf(Scribe.ServerOnly(Scribe.Int(0))),
		MapSo = Scribe.MapOf("integer", Scribe.ServerOnly(Scribe.Int(0))),
		SetSo = Scribe.SetOf(Scribe.ServerOnly(Scribe.Int(0))),
		Outer = Scribe.ArrayOf({ Inner = Scribe.ArrayOf(Scribe.ServerOnly(Scribe.Int(0))) }),
		-- Control: visible writes must reach the client.
		Visible = Scribe.ArrayOf(Scribe.Int(0)),
	}
end

local HIDDEN_ROOTS = { ArrSo = true, ArrOptSo = true, ArrSoRec = true, DictSo = true, MapSo = true, SetSo = true }

-- Hidden container depth, or nil.
local function hiddenDepth(path: { any }): number?
	if HIDDEN_ROOTS[path[1]] then
		return 1
	elseif path[1] == "Outer" and path[3] == "Inner" then
		return 3
	elseif path[1] == "Board" and path[2] == "Hidden" then
		return 2
	end
	return nil
end

-- Empty container Sets are safe; Insert/Remove still expose element positions.
local function leaks(frames: { { [string]: any } }): string
	local out = {}
	for _, frame in frames do
		for _, op in frame.Ops or {} do
			local depth = hiddenDepth(op.Path)
			if depth ~= nil then
				local value = op.Value
				local carries = #op.Path > depth
					or op.Kind == "Insert"
					or op.Kind == "Remove"
					or (value ~= nil and (type(value) ~= "table" or next(value) ~= nil))
				if carries then
					table.insert(out, `{op.Kind}:{Util.pathString(op.Path)}`)
				end
			end
		end
	end
	return table.concat(out, " ")
end

local function count(value: any): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local n = 0
	for _ in value do
		n += 1
	end
	return tostring(n)
end

local function flatten(value: any): string
	local parts = {}
	for _, item in value do
		table.insert(parts, if type(item) == "table" then "{P=" .. tostring(item.P) .. "}" else tostring(item))
	end
	return table.concat(parts, ",")
end

-- Cover writes resolved against both container and element schemas.
local function writeAfterInit(data: any)
	data.ArrSo.Insert(6)
	data.ArrSo.Insert(7)
	data.ArrSo[1].Set(5)
	data.ArrSo.Remove(2)
	data.ArrOptSo.Insert(8)
	data.ArrSoRec.Insert({ P = 3 })
	data.DictSo.k.Set(5)
	data.MapSo.Child(7).Set(9)
	data.SetSo.Add(4)
	data.Outer[1].Inner.Insert(5)
	data.Visible.Insert(1)
end

local function mirror(data: any): string
	return `arrSo={count(data.ArrSo.Get())} arrOptSo={count(data.ArrOptSo.Get())}`
		.. ` arrSoRec={count(data.ArrSoRec.Get())} dictSo={count(data.DictSo.Get())}`
		.. ` mapSo={count(data.MapSo.Get())} setSo={count(data.SetSo.Get())}`
		.. ` inner={count(data.Outer.Get()[1].Inner)} visible={count(data.Visible.Get())}`
end

local function serverValues(data: any): string
	return `arrSo={flatten(data.ArrSo.Get())} arrOptSo={flatten(data.ArrOptSo.Get())}`
		.. ` arrSoRec={flatten(data.ArrSoRec.Get())} dictSo={data.DictSo.Get().k} mapSo={data.MapSo.Get()[7]}`
		.. ` setSo={flatten(data.SetSo.Get())} inner={flatten(data.Outer.Get()[1].Inner)}`
		.. ` visible={flatten(data.Visible.Get())}`
end

local function step(harness)
	for _ = 1, 4 do
		harness.Step()
	end
end

describe("a whole-element ServerOnly container", function()
	it("sends no element from a player tree, to its owner or to a Shared watcher", function()
		local template = hiddenShapes()
		template.Board = Scribe.Shared({
			Hidden = Scribe.ArrayOf(Scribe.ServerOnly(Scribe.Int(0))),
			Seen = Scribe.Int(0),
		})
		local harness = TestCtx.make({ Template = template, AutoPump = true })
		local owner, _entry, acc = harness.Join(OWNER)
		-- Seed hidden values before Init.
		acc.ArrSo.Insert(1)
		acc.Outer.Insert({ Inner = {} })
		acc.Board.Hidden.Insert(2)

		-- The stub has one client listener: create the owner last; check the watcher on the wire.
		local watcher = harness.Join(WATCHER)
		harness.Transport.LocalPlayer = watcher
		local watcherClient = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return watcherClient.IsReady()
		end)
		harness.Transport.LocalPlayer = owner
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local atInit = `arrSo={count(client.ArrSo.Get())} hidden={count(client.Board.Get().Hidden)}`

		writeAfterInit(acc)
		acc.Board.Hidden.Insert(3)
		acc.Board.Seen.Set(1)
		step(harness)

		local seen = `{mirror(client)} hidden={count(client.Board.Get().Hidden)} seen={client.Board.Get().Seen}`
		local server = `{serverValues(acc)} hidden={flatten(acc.Board.Get().Hidden)}`
		local ownerLeaks = leaks(harness.FramesFor(owner))
		local watcherLeaks = leaks(harness.FramesFor(watcher))
		-- Control: the watcher must receive a SharedDiff.
		local watcherSeen = 0
		for _, frame in harness.FramesFor(watcher, Wire.Frames.SharedDiff) do
			for _, op in frame.Ops do
				if op.Path[1] == "Board" then
					watcherSeen += 1
				end
			end
		end
		harness.Cleanup()

		-- Report all observations together; server values confirm writes still apply.
		expect(table.concat({
			`init: {atInit}`,
			`client: {seen}`,
			`owner wire: [{ownerLeaks}]`,
			`watcher wire: [{watcherLeaks}] watcher saw Board: {watcherSeen > 0}`,
			`server: {server}`,
		}, "\n")).toBe(table.concat({
			"init: arrSo=0 hidden=0",
			"client: arrSo=0 arrOptSo=0 arrSoRec=0 dictSo=0 mapSo=0 setSo=0 inner=0 visible=1 hidden=0 seen=1",
			"owner wire: []",
			"watcher wire: [] watcher saw Board: true",
			"server: arrSo=5,7 arrOptSo=8 arrSoRec={P=3} dictSo=5 mapSo=9 setSo=4 inner=5 visible=1 hidden=2,3",
		}, "\n"))
	end)

	it("sends no element from the ServerStore", function()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = hiddenShapes() },
			AutoPump = true,
		})
		local store = harness.Data.ServerStore
		store.ArrSo.Insert(1)
		store.Outer.Insert({ Inner = {} })
		local player = harness.Join(OWNER)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local atInit = `arrSo={count(client.ServerStore.ArrSo.Get())}`

		writeAfterInit(store)
		step(harness)

		local seen = mirror(client.ServerStore)
		local server = serverValues(store)
		local wire = leaks(harness.FramesFor(player))
		harness.Cleanup()

		expect(table.concat({
			`init: {atInit}`,
			`client: {seen}`,
			`wire: [{wire}]`,
			`server: {server}`,
		}, "\n")).toBe(table.concat({
			"init: arrSo=0",
			"client: arrSo=0 arrOptSo=0 arrSoRec=0 dictSo=0 mapSo=0 setSo=0 inner=0 visible=1",
			"wire: []",
			"server: arrSo=5,7 arrOptSo=8 arrSoRec={P=3} dictSo=5 mapSo=9 setSo=4 inner=5 visible=1",
		}, "\n"))
	end)
end)
