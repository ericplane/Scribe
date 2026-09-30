--!nonstrict
-- Replication and persistence are INDEPENDENT axes.
--
--   Scribe.Session              never saves
--   Scribe.ServerOnly           nobody receives it
--   Scribe.Shared               everyone receives it
--   (default)                   the owner receives it
--
-- So one of each combines: Session+ServerOnly is runtime state only the server
-- sees, Session+Shared is runtime state everyone sees. Two of the SAME axis do
-- not: Shared+ServerOnly asks for a field that is both broadcast and hidden.
--
-- The unwrap loop used to overwrite a single Visibility enum, so every pairing
-- compiled and the INNER wrapper silently won. Scribe.ServerOnly(Scribe.Session(x))
-- resolved to Session and replicated a secret to its owner.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Template = require(Root.Scribe.Internal.Template)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local function compile(field)
	return function()
		Template.Compile({ F = field })
	end
end

local function nodeOf(field)
	return Template.Compile({ F = field }).Root.Children.F
end

local body = { A = 1 }

it("allows Session combined with ServerOnly, in either order", function()
	expect(compile(Scribe.ServerOnly(Scribe.Session(body)))).never.toThrow()
	expect(compile(Scribe.Session(Scribe.ServerOnly(body)))).never.toThrow()

	local node = nodeOf(Scribe.ServerOnly(Scribe.Session(body)))
	expect(node.Visibility).toBe("ServerOnly")
	expect(node.Persist).toBe(false)
end)

it("allows Session combined with Shared, in either order", function()
	expect(compile(Scribe.Shared(Scribe.Session(body)))).never.toThrow()
	expect(compile(Scribe.Session(Scribe.Shared(body)))).never.toThrow()

	local node = nodeOf(Scribe.Session(Scribe.Shared(body)))
	expect(node.Visibility).toBe("Shared")
	expect(node.Persist).toBe(false)
end)

it("refuses Shared combined with ServerOnly, in either order", function()
	-- Two replication targets for one field. This is the contradiction.
	expect(compile(Scribe.Shared(Scribe.ServerOnly(body)))).toThrow()
	expect(compile(Scribe.ServerOnly(Scribe.Shared(body)))).toThrow()
end)

it("names both wrappers when it refuses", function()
	local ok, err = pcall(compile(Scribe.Shared(Scribe.ServerOnly(body))))
	expect(ok).toBe(false)
	expect(string.find(tostring(err), "Shared", 1, true) ~= nil).toBe(true)
	expect(string.find(tostring(err), "ServerOnly", 1, true) ~= nil).toBe(true)
end)

it("refuses a redundant doubled wrapper on the same axis", function()
	expect(compile(Scribe.Session(Scribe.Session(body)))).toThrow()
	expect(compile(Scribe.ServerOnly(Scribe.ServerOnly(body)))).toThrow()
	expect(compile(Scribe.Shared(Scribe.Shared(body)))).toThrow()
end)

it("carries the combination over a scalar leaf", function()
	local node = nodeOf(Scribe.ServerOnly(Scribe.Session(Scribe.Int(7))))
	expect(node.Visibility).toBe("ServerOnly")
	expect(node.Persist).toBe(false)
	expect(node.ValueType).toBe("int")
	expect(node.Default).toBe(7)
end)

it("keeps the plain wrappers meaning what they did", function()
	expect(nodeOf(Scribe.ServerOnly(body)).Visibility).toBe("ServerOnly")
	expect(nodeOf(Scribe.ServerOnly(body)).Persist).toBe(true)
	expect(nodeOf(Scribe.Shared(body)).Visibility).toBe("Shared")
	expect(nodeOf(Scribe.Shared(body)).Persist).toBe(true)
	-- A plain Session still replicates to its owner, as the guide's table says.
	expect(nodeOf(Scribe.Session(body)).Visibility).toBe("Replicated")
	expect(nodeOf(Scribe.Session(body)).Persist).toBe(false)
	expect(nodeOf(body).Visibility).toBe("Replicated")
	expect(nodeOf(body).Persist).toBe(true)
end)

it("still allows nesting that is inheritance rather than combination", function()
	expect(compile(Scribe.ServerOnly({ Inner = { Deep = 1 } }))).never.toThrow()
	expect(compile(Scribe.ServerOnly({ Inner = Scribe.ServerOnly({ Deep = 1 }) }))).never.toThrow()
	expect(compile({ Public = 1, Secret = Scribe.ServerOnly(0) })).never.toThrow()
end)

it("still refuses Shared and Session below the root", function()
	expect(compile({ Nested = Scribe.Shared({ A = 1 }) })).toThrow()
	expect(compile({ Nested = Scribe.Session({ A = 1 }) })).toThrow()
end)

it("a Session+ServerOnly field neither saves nor reaches the client", function()
	local harness = TestCtx.make({
		AutoPump = true,
		Template = {
			Coins = Scribe.Int(0, { Min = 0 }),
			Hidden = Scribe.ServerOnly(Scribe.Session({ Strikes = 0 })),
		},
	})
	local player, entry, data = harness.Join(99501)

	data.Coins.Set(5)
	data.Hidden.Strikes.Set(3)
	expect(data.Hidden.Strikes.Get()).toBe(3)

	-- Never persisted: the value lives in the session store, not profile data.
	expect(entry.Profile.Data.Hidden).toBe(nil)
	expect(harness.Ctx.Persistence.EntryForUserId(99501).SessionStore.Hidden.Strikes).toBe(3)

	-- And never replicated. This is the half that used to break: before the
	-- axes were split, the inner Session won and the client saw Strikes.
	harness.Transport.LocalPlayer = player
	local client = Client.new(harness.Options, harness.Compiled)
	local whole = client.Get()
	expect(whole.Coins).toBe(5)
	expect(whole.Hidden).toBe(nil)

	harness.Cleanup()
end)

it("a Session+Shared field does not save but still reaches another player", function()
	local harness = TestCtx.make({
		AutoPump = false,
		Template = {
			Coins = Scribe.Int(0, { Min = 0 }),
			Status = Scribe.Shared(Scribe.Session({ Stunned = false })),
		},
	})
	-- Player A owns the field; player B is the local client and must receive it.
	local _playerA, entryA, dataA = harness.Join(99502)
	dataA.Status.Stunned.Set(true)

	local playerB = harness.Join(99503)
	harness.Transport.LocalPlayer = playerB
	local clientB = Client.new(harness.Options, harness.Compiled)

	harness.Ctx.Replication.FlushEntry(entryA)
	harness.Transport:PumpToServer() -- B's Hello
	harness.Transport:PumpToClient()

	-- The Shared half: B genuinely receives A's field.
	local sharedA = clientB.GetShared(99502)
	expect(sharedA ~= nil).toBe(true)
	expect((sharedA :: any).Status.Stunned).toBe(true)

	-- The Session half: it never lands in profile data.
	expect(entryA.Profile.Data.Status).toBe(nil)

	-- Now the DIFF path rather than the snapshot: a write made while B is
	-- already connected has to reach them too.
	dataA.Status.Stunned.Set(false)
	harness.Ctx.Replication.FlushEntry(entryA)
	harness.Transport:PumpToClient()
	expect((clientB.GetShared(99502) :: any).Status.Stunned).toBe(false)

	harness.Cleanup()
end)

it("a plain Shared field still persists, so Session is what removed it", function()
	-- The control for the test above. Without this, "not in Profile.Data" could
	-- just mean Shared roots never persist, and the Session half would be untested.
	local harness = TestCtx.make({
		AutoPump = true,
		Template = { Status = Scribe.Shared({ Stunned = false }) },
	})
	local _p, entry, data = harness.Join(99504)

	data.Status.Stunned.Set(true)
	expect(entry.Profile.Data.Status.Stunned).toBe(true)

	harness.Cleanup()
end)
