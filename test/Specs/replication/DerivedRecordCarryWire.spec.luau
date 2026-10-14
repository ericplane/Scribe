--!nonstrict
-- Record ops carry transmitted derived values without duplicate updates.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local Log = require(ScribeRoot.Internal.Log)
local Wire = require(ScribeRoot.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local function step(harness)
	for _ = 1, 4 do
		harness.Step()
	end
end

-- Render table ops in key order.
local function describeOp(op): string
	local path = table.concat(op.Path, ".")
	if op.Kind == "Clear" then
		return `Clear {path}`
	end
	local value = op.Value
	if type(value) == "table" then
		local parts = {}
		for k, v in value do
			table.insert(parts, `{tostring(k)}={tostring(v)}`)
		end
		table.sort(parts)
		value = `\{{table.concat(parts, ",")}\}`
	end
	return `{op.Kind} {path}={tostring(value)}`
end

-- Read matching ops, then clear the send log.
local function opsFor(harness, player, frameType): string
	local ops = {}
	for _, frame in harness.FramesFor(player, frameType) do
		for _, op in frame.Ops do
			table.insert(ops, describeOp(op))
		end
	end
	table.clear(harness.Transport.SentToClientLog)
	return table.concat(ops, "; ")
end

describe("a Shared record holding derived fields, seen by another player", function()
	itRunning("keeps every field the server sends through a record Set and a Clear", function()
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(3),
				Hidden = Scribe.ServerOnly(Scribe.Int(4)),
				Pub = Scribe.Shared(Scribe.Session({
					Level = Scribe.Int(1),
					-- Every input is Shared: a watcher computes it for itself.
					Badge = Scribe.Derived(Scribe.String(""), { "Pub.Level" }, function(l)
						return `L{tostring(l)}`
					end),
					-- A ServerOnly input: sent to everyone.
					Rank = Scribe.Derived(Scribe.Int(0), { "Hidden" }, function(h)
						return (h or 0) * 2 + 1
					end),
					-- A Replicated input: sent to watchers, computed by the owner.
					Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return (c or 0) * 2
					end),
				})),
			},
			-- The production wire. Studio defaults DevMode on, which also sends what a
			-- client computes itself, for the purity audit below.
			Options = { DevMode = false },
			AutoPump = true,
		})
		local watcher = harness.Join(73101)
		local owner, _entry, acc = harness.Join(73102)
		harness.Transport.LocalPlayer = watcher
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.SendHello(owner)
		acc.Coins.Set(5)
		acc.Hidden.Set(5)
		local events = {}
		client.OnSharedChanged:Connect(function(userId, shared)
			if userId == owner.UserId and shared ~= nil then
				local pub = shared.Pub
				table.insert(
					events,
					`{tostring(pub.Level)},{tostring(pub.Badge)},{tostring(pub.Rank)},{tostring(pub.Twice)}`
				)
			end
		end)
		harness.StepUntil(function()
			return #events > 0 and events[#events] == "1,L1,11,10"
		end)
		local logs = { Badge = {}, Rank = {}, Twice = {} }
		for name, log in logs do
			acc.Pub[name].Changed(function(new, old)
				table.insert(log, `{tostring(old)}>{tostring(new)}`)
			end)
		end
		opsFor(harness, watcher, Wire.Frames.SharedDiff)
		table.clear(events)
		local seen = {}
		local function record(label: string)
			step(harness)
			table.insert(
				seen,
				`{label}: server Badge[{table.concat(logs.Badge, " ")}] Rank[{table.concat(logs.Rank, " ")}]`
					.. ` Twice[{table.concat(logs.Twice, " ")}] | ops {opsFor(harness, watcher, Wire.Frames.SharedDiff)}`
					.. ` | watcher {table.concat(events, " ")}`
			)
			for _, log in logs do
				table.clear(log)
			end
			table.clear(events)
		end
		acc.Pub.Set({ Level = 2 })
		record("set")
		acc.Pub.Clear()
		record("clear")
		harness.Cleanup()
		expect(table.concat(seen, "\n")).toBe(table.concat({
			"set: server Badge[L1>L2] Rank[] Twice[] | ops Set Pub={Level=2,Rank=11,Twice=10} | watcher 2,L2,11,10",
			"clear: server Badge[L2>Lnil] Rank[] Twice[] | ops Clear Pub; Set Pub.Rank=11; Set Pub.Twice=10"
				.. " | watcher nil,Lnil,11,10",
		}, "\n"))
	end)
end)

describe("the DevMode purity audit on a derived field inside a record", function()
	itRunning("reports the impure field, and sends nothing for a pure one the record write left unchanged", function()
		local calls = 0
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(3),
				Stats = Scribe.Session({
					Kept = Scribe.Int(7),
					Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return (c or 0) * 2
					end),
					-- The positive control: a different value on every call.
					Impure = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						calls += 1
						return (c or 0) + calls
					end),
				}),
			},
			Options = { DevMode = true },
			AutoPump = true,
		})
		local player, _entry, acc = harness.Join(73103)
		acc.Coins.Set(5)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		step(harness)
		local mismatched = {}
		local remove = Log.AddSink(function(entry)
			if entry.Code == "DERIVED_MISMATCH" then
				table.insert(mismatched, tostring(entry.Context and entry.Context.Field))
			end
		end, { Level = "Warn" })
		local twice = {}
		acc.Stats.Twice.Changed(function(new, old)
			table.insert(twice, `{tostring(old)}>{tostring(new)}`)
		end)
		opsFor(harness, player, Wire.Frames.Diff)
		acc.Stats.Set({ Kept = 9 })
		step(harness)
		task.wait() -- sinks are spawned, not called inline
		remove()
		local ops = {}
		for _, op in string.split(opsFor(harness, player, Wire.Frames.Diff), "; ") do
			-- Impure's value is the call count, which depends on how often each realm ran it.
			table.insert(ops, (string.gsub(op, "Impure=%d+", "Impure=n")))
		end
		table.sort(mismatched)
		local seen = `server Twice[{table.concat(twice, " ")}] = {acc.Stats.Twice.Get()} client {tostring(
			client.Stats.Twice.Get()
		)} | ops {table.concat(ops, "; ")} | mismatched {table.concat(mismatched, ",")}`
		harness.Cleanup()
		expect(seen).toBe(
			"server Twice[] = 10 client 10 | ops Set Stats={Kept=9}; Set Stats.Impure=n | mismatched Stats.Impure"
		)
	end)
end)
