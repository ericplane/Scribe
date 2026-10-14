--!nonstrict
-- Player and store views must run only their own derived fields.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local Template = require(ScribeRoot.Internal.Template)
local Log = require(ScribeRoot.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

-- Render roots and scalars in key order.
local function shape(data: { [string]: any }?): string
	if data == nil then
		return "<none>"
	end
	local parts = {}
	for key, value in data do
		table.insert(parts, `{key}={if type(value) == "table" then "tbl" else tostring(value)}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function persisted(harness, userId: number): string
	return shape(harness.Fake.Persisted[`Default/PLAYER_{userId}`])
end

local function labels(nodes): string
	local out = {}
	for _, node in nodes do
		table.insert(out, table.concat(node.Path, "."))
	end
	return table.concat(out, ",")
end

-- Render the write index in sorted written>dependent pairs.
local function writeIndex(byWrite): string
	local out = {}
	for pathKey, dependents in byWrite do
		local names = {}
		for _, node in dependents do
			table.insert(names, table.concat(node.Path, "."))
		end
		table.sort(names)
		table.insert(out, `{string.gsub(pathKey, "\31", ".")}>{table.concat(names, "+")}`)
	end
	table.sort(out)
	return table.concat(out, ";")
end

-- Both derived error codes fire OnIssue regardless of the harness log level.
local function watchIssues()
	local counts = { DERIVED_ERROR = 0, DERIVED_FEEDBACK = 0 }
	local connection = Log.OnIssue:Connect(function(entry)
		if counts[entry.Code] ~= nil then
			counts[entry.Code] += 1
		end
	end)
	return counts, function()
		connection:Disconnect()
	end
end

local function joinClient(harness, player)
	harness.Transport.LocalPlayer = player
	-- Client.new sends its own Hello, so it has to exist before the Init is answered.
	return Client.new(harness.Options, harness.Compiled)
end

-- Aaa depends on a later name, so alphabetical order alone is wrong.
local function chainTemplates()
	local template = {
		Coins = Scribe.Int(0),
		Double = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
			return (c or 0) * 2
		end),
		Quad = Scribe.Derived(Scribe.Int(0), { "Double" }, function(d)
			return (d or 0) * 2
		end),
		Aaa = Scribe.Derived(Scribe.Int(0), { "Quad" }, function(q)
			return (q or 0) + 1
		end),
	}
	local store = {
		Biome = Scribe.Int(1),
		Name = Scribe.Derived(Scribe.String(""), { "Biome" }, function(b)
			return `n{tostring(b)}`
		end),
		Upper = Scribe.Derived(Scribe.String(""), { "Name" }, function(n)
			return string.upper(tostring(n))
		end),
	}
	return template, store
end

describe("which derived fields each view holds", function()
	it("keeps every derived field in the full compile, in dependency order", function()
		-- The full compile must still include both sides for the client.
		local template, store = chainTemplates()
		local compiled = Template.Compile(template, { ServerStore = store })
		-- Each chain keeps dependency order; independent chains may interleave.
		local function side(sideTemplate): string
			local out = {}
			for _, node in compiled.DerivedNodes do
				if sideTemplate[node.Path[1]] ~= nil then
					table.insert(out, table.concat(node.Path, "."))
				end
			end
			return table.concat(out, ",")
		end
		expect(`{#compiled.DerivedNodes} player={side(template)} store={side(store)}`).toBe(
			"5 player=Double,Quad,Aaa store=Name,Upper"
		)
		expect(writeIndex(compiled.DerivedByWrite)).toBe("Biome>Name;Coins>Double;Double>Quad;Name>Upper;Quad>Aaa")
	end)

	it("gives each view only the derived fields and write index of its own roots", function()
		local template, store = chainTemplates()
		local compiled = Template.Compile(template, { ServerStore = store })
		local player, storeView = compiled.Views.Player, compiled.Views.Store
		expect(labels(player.DerivedNodes)).toBe("Double,Quad,Aaa")
		expect(labels(storeView.DerivedNodes)).toBe("Name,Upper")
		expect(writeIndex(player.DerivedByWrite)).toBe("Coins>Double;Double>Quad;Quad>Aaa")
		expect(writeIndex(storeView.DerivedByWrite)).toBe("Biome>Name;Name>Upper")
	end)

	it("never makes a store derived field offline-computable", function()
		-- Offline reads can use the full list because store roots never persist.
		local template, store = chainTemplates()
		local compiled = Template.Compile(template, { ServerStore = store })
		local seen = {}
		for _, node in compiled.DerivedNodes do
			table.insert(seen, `{table.concat(node.Path, ".")}={tostring(node.Derived.OfflineComputable)}`)
		end
		table.sort(seen)
		expect(table.concat(seen, ",")).toBe("Aaa=true,Double=true,Name=false,Quad=true,Upper=false")
	end)

	it("refuses every shape of derived field that reads across the boundary", function()
		-- Cross-store dependencies must be rejected.
		local function refusal(template, storeTemplate): string
			local ok, err = pcall(Template.Compile, template, { ServerStore = storeTemplate })
			if ok then
				return "compiled"
			end
			return if string.find(tostring(err), "ServerStore boundary", 1, true) then "boundary" else tostring(err)
		end
		local function read(...)
			local inputs = { ... }
			return Scribe.Derived(Scribe.Int(0), inputs, function()
				return 0
			end)
		end
		local seen = {
			refusal({ Coins = Scribe.Int(0) }, { Out = read("Coins") }),
			refusal({ Coins = Scribe.Int(0) }, { Rec = { Out = read("Coins") } }),
			refusal({ Coins = Scribe.Int(0), D = read("Coins") }, { Out = read("D") }),
			refusal({ Out = read("Rec.V") }, { Rec = { V = Scribe.Int(0) } }),
			refusal({ Out = read("W") }, { W = Scribe.ServerOnly(0) }),
			refusal({ State = Scribe.Session({ Out = read("W") }) }, { W = Scribe.Int(0) }),
			refusal({ Coins = Scribe.Int(0) }, { W = Scribe.Int(0), Out = read("W", "Coins") }),
			-- The control: a chain that stays inside the store compiles.
			refusal({ Coins = Scribe.Int(0) }, { W = Scribe.Int(0), A = read("W"), B = read("A") }),
		}
		expect(table.concat(seen, ",")).toBe("boundary,boundary,boundary,boundary,boundary,boundary,boundary,compiled")
	end)
end)

describe("the store tree", function()
	itRunning("never runs a player derived field, so the report's template logs no DERIVED_ERROR", function()
		-- The reported Session field compares a sibling with a root and rejects nil.
		local calls = {}
		local template = {
			Capacity = Scribe.Int(16, { Min = 0 }),
			State = Scribe.Session({
				InventoryCount = Scribe.Int(0, { Min = 0 }),
				InventoryFull = Scribe.Derived(false, { "State.InventoryCount", "Capacity" }, function(count, capacity)
					table.insert(calls, `{tostring(count)}/{tostring(capacity)}`)
					return count >= capacity
				end),
			}),
		}
		local issues, stopWatching = watchIssues()
		local harness = TestCtx.make({
			Template = template,
			Options = { ServerStore = { Biome = Scribe.Int(1) } },
			AutoPump = true,
		})
		local afterBuild = table.concat(calls, " ")
		local _player, _entry, acc = harness.Join(64001)
		local afterJoin = table.concat(calls, " ")
		acc.State.InventoryCount.Set(16)
		local full = acc.State.InventoryFull.Get()
		local storeData = shape(harness.Ctx.ServerStore.Data)
		harness.Cleanup()
		stopWatching()
		-- The compile-time default, then the profile load. Nothing from the store tree.
		expect(
			`build=[{afterBuild}] join=[{afterJoin}] errors={issues.DERIVED_ERROR} full={tostring(full)} store={storeData}`
		).toBe("build=[0/16] join=[0/16 0/16] errors=0 full=true store=Biome=1")
	end)

	itRunning("keeps player roots out of the store, so the owner's Init carries their own value", function()
		-- A hidden input forces transmission; nil-tolerant compute exposed the wrong-tree write.
		local template = {
			Secret = Scribe.ServerOnly({ Level = Scribe.Int(5) }),
			Badge = Scribe.Derived(Scribe.String(""), { "Secret.Level" }, function(level)
				return `L{tostring(level)}`
			end),
		}
		local harness = TestCtx.make({
			Template = template,
			Options = { ServerStore = { Biome = Scribe.Int(1) } },
			AutoPump = true,
		})
		local storeData = shape(harness.Ctx.ServerStore.Data)
		local player, _entry, acc = harness.Join(64002)
		local clientData = joinClient(harness, player)
		-- Before the Init a client read answers the template default, which is "L5" here.
		harness.StepUntil(function()
			return clientData.IsReady()
		end)
		local atInit = clientData.Badge.Get()
		acc.Secret.Level.Set(6)
		harness.StepUntil(function()
			return clientData.Badge.Get() == "L6"
		end)
		local afterWrite = clientData.Badge.Get()
		harness.Cleanup()
		expect(`store={storeData} init={atInit} after={afterWrite}`).toBe("store=Biome=1 init=L5 after=L6")
	end)
end)

describe("a player tree", function()
	itRunning("never runs a store derived field, so a joining player's profile gains no store root", function()
		-- One compute exposes stray writes; the other exposes nil inputs.
		local calls = {}
		local store = {
			Biome = Scribe.Int(1),
			BiomeName = Scribe.Derived(Scribe.String(""), { "Biome" }, function(biome)
				table.insert(calls, tostring(biome))
				return `biome{tostring(biome)}`
			end),
			Calm = Scribe.Derived(false, { "Biome" }, function(biome)
				return biome <= 3
			end),
		}
		local issues, stopWatching = watchIssues()
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = store },
			AutoPump = true,
		})
		local afterBuild = table.concat(calls, " ")
		local player, entry, acc = harness.Join(64003)
		local afterJoin = table.concat(calls, " ")
		local live = shape(entry.LiveData)
		acc.Coins.Increment(1)
		harness.Data.Flush(player, { Force = true })
		local saved = persisted(harness, 64003)
		local storeValues = `{harness.Data.ServerStore.BiomeName.Get()},{tostring(harness.Data.ServerStore.Calm.Get())}`
		harness.Cleanup()
		stopWatching()
		-- The compile-time default and the store tree's own seed; the join adds nothing.
		expect(
			`build=[{afterBuild}] join=[{afterJoin}] live={live} saved={saved} store={storeValues} errors={issues.DERIVED_ERROR}`
		).toBe("build=[1 1] join=[1 1] live=Coins=0,_Scribe=tbl saved=Coins=1,_Scribe=tbl store=biome1,true errors=0")
	end)

	itRunning("does not create a nested store record in the profile", function()
		local store = {
			World = {
				Biome = Scribe.Int(7),
				Name = Scribe.Derived(Scribe.String(""), { "World.Biome" }, function(biome)
					return `w{tostring(biome)}`
				end),
			},
		}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = store },
			AutoPump = true,
		})
		local _player, entry = harness.Join(64004)
		local live = shape(entry.LiveData)
		-- Move off the default to prove store recomputes still run.
		harness.Data.ServerStore.World.Biome.Set(8)
		local storeName = harness.Data.ServerStore.World.Name.Get()
		harness.Cleanup()
		expect(`live={live} store={storeName}`).toBe("live=Coins=0,_Scribe=tbl store=w8")
	end)

	itRunning("keeps a transmitted store derived field out of the profile and still delivers it", function()
		-- A hidden input forces the server to send the derived value.
		local store = {
			Hidden = Scribe.ServerOnly({ Seed = Scribe.Int(7) }),
			Label = Scribe.Derived(Scribe.String(""), { "Hidden.Seed" }, function(seed)
				return `s{tostring(seed)}`
			end),
		}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = store },
			AutoPump = true,
		})
		local player, _entry, acc = harness.Join(64005)
		acc.Coins.Increment(1)
		harness.Data.Flush(player, { Force = true })
		local saved = persisted(harness, 64005)
		-- Moved off the default ("s7") first, so the Init has to carry the server's value.
		harness.Data.ServerStore.Hidden.Seed.Set(9)
		local clientData = joinClient(harness, player)
		harness.StepUntil(function()
			return clientData.IsReady()
		end)
		local atInit = clientData.ServerStore.Label.Get()
		harness.Data.ServerStore.Hidden.Seed.Set(8)
		harness.StepUntil(function()
			return clientData.ServerStore.Label.Get() == "s8"
		end)
		local afterWrite = clientData.ServerStore.Label.Get()
		harness.Cleanup()
		expect(`saved={saved} init={atInit} after={afterWrite}`).toBe("saved=Coins=1,_Scribe=tbl init=s9 after=s8")
	end)

	itRunning("refuses a player write to a key of the same name, so the store's derived field never runs", function()
		-- Player writes under store root names must refuse before touching the store graph.
		local calls = {}
		local store = {
			Biome = Scribe.Int(1),
			BiomeName = Scribe.Derived(Scribe.String(""), { "Biome" }, function(biome)
				table.insert(calls, tostring(biome))
				return `biome{tostring(biome)}`
			end),
		}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = store },
			AutoPump = true,
		})
		local _player, entry, acc = harness.Join(64006)
		table.clear(calls)
		local issues, stopWatching = watchIssues()
		local ok, err = pcall(function()
			acc.Child("Biome").Set(5)
		end)
		local refused = not ok and string.find(tostring(err), "Data.ServerStore.Biome", 1, true) ~= nil
		local live = shape(entry.LiveData)
		harness.Cleanup()
		stopWatching()
		expect(
			`refused={tostring(refused)} calls=[{table.concat(calls, " ")}] feedback={issues.DERIVED_FEEDBACK} live={live}`
		).toBe("refused=true calls=[] feedback=0 live=Coins=0,_Scribe=tbl")
	end)
end)

describe("recompute on both sides", function()
	itRunning("settles a player chain and a store chain on the server and the client", function()
		local template, store = chainTemplates()
		local harness = TestCtx.make({ Template = template, Options = { ServerStore = store }, AutoPump = true })
		local player, _entry, acc = harness.Join(64007)
		local clientData = joinClient(harness, player)
		acc.Coins.Set(3)
		harness.Data.ServerStore.Biome.Set(4)
		harness.StepUntil(function()
			return clientData.Aaa.Get() == 13 and clientData.ServerStore.Upper.Get() == "N4"
		end)
		local server =
			`{acc.Double.Get()},{acc.Quad.Get()},{acc.Aaa.Get()},{harness.Data.ServerStore.Name.Get()},{harness.Data.ServerStore.Upper.Get()}`
		local client =
			`{clientData.Double.Get()},{clientData.Quad.Get()},{clientData.Aaa.Get()},{clientData.ServerStore.Name.Get()},{clientData.ServerStore.Upper.Get()}`
		harness.Cleanup()
		expect(`server={server} client={client}`).toBe("server=6,12,13,n4,N4 client=6,12,13,n4,N4")
	end)

	itRunning("settles the report's Session field on the server and the client after a write", function()
		local template = {
			Capacity = Scribe.Int(16, { Min = 0 }),
			State = Scribe.Session({
				InventoryCount = Scribe.Int(0, { Min = 0 }),
				InventoryFull = Scribe.Derived(false, { "State.InventoryCount", "Capacity" }, function(count, capacity)
					return (count or 0) >= (capacity or 0)
				end),
			}),
		}
		local harness = TestCtx.make({
			Template = template,
			Options = { ServerStore = { Biome = Scribe.Int(1) } },
			AutoPump = true,
		})
		local player, _entry, acc = harness.Join(64008)
		local clientData = joinClient(harness, player)
		acc.State.InventoryCount.Set(16)
		harness.StepUntil(function()
			return clientData.State.InventoryFull.Get() == true
		end)
		local seen =
			`server={tostring(acc.State.InventoryFull.Get())} client={tostring(clientData.State.InventoryFull.Get())}`
		harness.Cleanup()
		expect(seen).toBe("server=true client=true")
	end)
end)
