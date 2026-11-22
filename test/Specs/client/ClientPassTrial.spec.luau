--!nonstrict
-- Replicated trial access leaves the pass purchasable.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Client = require(Root.Scribe.Client)
local Template = require(Root.Scribe.Internal.Template)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local PASS, PASS_ID = "VIP", 777
local ENDS = 1800003600
local NONE = { Owned = false, Active = false }
local BOUGHT = { Owned = true, Active = true }
local TRIAL = { Owned = false, Active = true, EndTime = ENDS }

local harness

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

local function pump()
	harness.Step()
	harness.Transport:PumpToServer()
	harness.Transport:PumpToClient()
end

--- Return the client and a callback that changes the server's ownership response.
local function make()
	local answer = NONE
	harness = TestCtx.make({
		AutoPump = false,
		Template = { Coins = 0 },
		Options = {
			Passes = { [PASS] = { Id = PASS_ID } },
			GetPassOwnershipAsync = function()
				return answer
			end,
		},
	})
	local player = harness.Join(98101)
	harness.Transport.LocalPlayer = player
	local function roblox(next)
		answer = next
		if next == NONE then
			harness.Data.OwnsAsync(player, PASS)
		else
			harness.Ctx.Monetization.OnPassPurchaseFinished(player, PASS_ID, true)
		end
		pump()
	end
	return Client.new(harness.Options, harness.Compiled), roblox
end

local function read(client): string
	local found = client.GetTrial(PASS)
	return `owns={client.Owns(PASS)} ends={if found then found.EndsAt else "none"} state={client.GetProductState(PASS)}`
end

describe("a pass on free trial, on the client", function()
	itRunning("reads as owned for now, with its end, and stays purchasable until it is bought", function()
		local client, roblox = make()
		pump()
		local before = read(client)
		roblox(TRIAL)
		local during = read(client)
		roblox(BOUGHT)
		expect(`{before} | {during} | {read(client)}`).toBe(
			`owns=false ends=none state=purchasable | owns=true ends={ENDS} state=purchasable | `
				.. "owns=true ends=none state=owned"
		)
	end)

	itRunning("reports the trial and then the purchase to both listeners", function()
		local client, roblox = make()
		local observed, changed = {}, {}
		task.spawn(function()
			client.ObserveOwned(PASS, function(owned, trial)
				table.insert(observed, `{owned}/{trial}`)
			end)
		end)
		client.OnOwnershipChanged:Connect(function(key, owned, trial)
			table.insert(changed, `{key}:{owned}/{trial}`)
		end)
		pump()
		roblox(TRIAL)
		roblox(BOUGHT)
		expect(`{table.concat(observed, ",")} | {table.concat(changed, ",")}`).toBe(
			"false/false,true/true,true/false | VIP:true/true,VIP:true/false"
		)
	end)

	itRunning("reports the end of a trial that was not bought", function()
		local client, roblox = make()
		local changed = {}
		client.OnOwnershipChanged:Connect(function(key, owned, trial)
			table.insert(changed, `{key}:{owned}/{trial}`)
		end)
		pump()
		roblox(TRIAL)
		roblox(NONE)
		expect(`{read(client)} | {table.concat(changed, ",")}`).toBe(
			"owns=false ends=none state=purchasable | VIP:true/true,VIP:false/false"
		)
	end)

	itRunning("repaints a shop button only when the pass is bought", function()
		local client, roblox = make()
		local states = {}
		client.ObserveProductState(PASS, function(state)
			table.insert(states, state)
		end)
		pump()
		roblox(TRIAL)
		roblox(BOUGHT)
		expect(table.concat(states, ",")).toBe("not-loaded,purchasable,owned")
	end)
end)

describe("edit-mode Data.Mock with a trial", function()
	local function mocked(endsAt: number): string
		local options = {
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			ProfileStoreIndex = "ZzMockTrialSpec",
			ProfileKeyPrefix = "PLAYER_",
			IsRunning = false,
			Banner = false,
		}
		local clientData = Client.new(options, Template.Compile(options.Template, {}))
		local seen = {}
		clientData.ObserveOwned(PASS, function(owned, trial)
			table.insert(seen, `{owned}/{trial}`)
		end)
		local ok = pcall(clientData.Mock, nil, { Trials = { [PASS] = endsAt } })
		local found = clientData.GetTrial(PASS)
		pcall(clientData.Stop)
		return `ok={ok} owns={clientData.Owns(PASS)} trial={found ~= nil} ends={found and found.EndsAt} `
			.. `seen={table.concat(seen, ",")}`
	end

	it("seeds a trial with its end", function()
		expect(mocked(ENDS)).toBe(`ok=true owns=true trial=true ends={ENDS} seen=false/false,true/true`)
	end)

	it("seeds a trial with no end as 0", function()
		expect(mocked(0)).toBe("ok=true owns=true trial=true ends=nil seen=false/false,true/true")
	end)
end)
