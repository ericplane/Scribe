--!nonstrict
-- Rollback recomputes derived fields once, after all restores.
local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Log = require(ScribeRoot.Internal.Log)
local Wire = require(ScribeRoot.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local function on(log, label, accessor)
	accessor.Changed(function(new, old)
		table.insert(log, `{label}:{tostring(old)}->{tostring(new)}`)
	end)
end

local function sumTemplate(calls)
	return {
		Aaa = Scribe.Int(0), -- restored first, and feeds nothing
		Coins = Scribe.Int(0),
		Gems = Scribe.Int(0),
		Total = Scribe.Derived(Scribe.Int(0), { "Coins", "Gems" }, function(c, g)
			table.insert(calls, `{c}+{g}`)
			return c + g
		end),
	}
end

describe("a rolled-back transaction settles derived fields once", function()
	it("recomputes once, after every restore, and fires nothing when the value is unchanged", function()
		local calls = {}
		local harness = TestCtx.make({ Template = sumTemplate(calls) })
		local player, _entry, data = harness.Join(72001)
		local fires = {}
		on(fires, "Total", data.Total)
		table.clear(calls)
		local ok = harness.Data.Transaction(player, function()
			data.Aaa.Set(1)
			data.Coins.Set(5)
			data.Gems.Set(3)
			error("abort")
		end)
		local seen =
			`ok={tostring(ok)} calls=[{table.concat(calls, " ")}] fires=[{table.concat(fires, " ")}] total={data.Total.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false calls=[0+0] fires=[] total=0")
	end)

	it("puts no intermediate value of a transmitted Shared derived field on the wire", function()
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0),
				Secret = Scribe.ServerOnly(0),
				Shown = Scribe.Shared(Scribe.Derived(Scribe.Int(0), { "Coins", "Secret" }, function(c, s)
					return c + s
				end)),
			},
			AutoPump = true,
		})
		local watcher = harness.Join(72002)
		local player, entry, data = harness.Join(72003)
		harness.SendHello(watcher)
		harness.StepUntil(function()
			return entry ~= nil and #harness.FramesFor(watcher, Wire.Frames.SharedInit) > 0
		end)
		-- The control: an ordinary committed write does reach the watcher.
		data.Coins.Set(1)
		harness.Step()
		local control = {}
		for _, frame in harness.FramesFor(watcher, Wire.Frames.SharedDiff) do
			for _, op in frame.Ops do
				table.insert(control, `{table.concat(op.Path, ".")}={tostring(op.Value)}`)
			end
		end
		table.clear(harness.Transport.SentToClientLog)
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(5)
			data.Secret.Set(2)
			error("abort")
		end)
		harness.Step()
		harness.Step()
		local ops = {}
		for _, frame in harness.FramesFor(watcher, Wire.Frames.SharedDiff) do
			for _, op in frame.Ops do
				table.insert(ops, `{table.concat(op.Path, ".")}={tostring(op.Value)}`)
			end
		end
		local seen =
			`control=[{table.concat(control, " ")}] ok={tostring(ok)} watcherOps=[{table.concat(ops, " ")}] shown={data.Shown.Get()}`
		harness.Cleanup()
		expect(seen).toBe("control=[Shown=1] ok=false watcherOps=[] shown=1")
	end)

	it("logs no DERIVED_ERROR for an invariant only a part-restored tree breaks", function()
		local errors = 0
		local connection = Log.OnIssue:Connect(function(entry)
			if entry.Code == "DERIVED_ERROR" then
				errors += 1
			end
		end)
		local genuine = false
		local harness = TestCtx.make({
			Template = {
				Budget = Scribe.Int(10),
				Spent = Scribe.Int(0),
				Left = Scribe.Derived(Scribe.Int(0), { "Budget", "Spent" }, function(b, s)
					assert(s <= b, "spent exceeds budget")
					assert(not genuine, "a genuine error")
					return b - s
				end),
			},
		})
		local player, _entry, data = harness.Join(72004)
		local ok = harness.Data.Transaction(player, function()
			data.Budget.Set(100)
			data.Spent.Set(50)
			error("abort")
		end)
		local afterRollback = errors
		-- The error is logged once per field per tree, so a false one spends the only report.
		genuine = true
		data.Spent.Set(1)
		connection:Disconnect()
		local seen = `ok={tostring(ok)} afterRollback={afterRollback} afterGenuine={errors} left={data.Left.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false afterRollback=0 afterGenuine=1 left=10")
	end)

	it("settles a chain once and fires none of it", function()
		local calls = {}
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0),
				Gems = Scribe.Int(0),
				Sum = Scribe.Derived(Scribe.Int(0), { "Coins", "Gems" }, function(c, g)
					table.insert(calls, `S{c}+{g}`)
					return c + g
				end),
				Double = Scribe.Derived(Scribe.Int(0), { "Sum" }, function(s)
					table.insert(calls, `D{s}`)
					return s * 2
				end),
				Quad = Scribe.Derived(Scribe.Int(0), { "Double" }, function(d)
					table.insert(calls, `Q{d}`)
					return d * 2
				end),
			},
		})
		local player, _entry, data = harness.Join(72005)
		data.Coins.Set(1)
		data.Gems.Set(1)
		local fires = {}
		on(fires, "Sum", data.Sum)
		on(fires, "Double", data.Double)
		on(fires, "Quad", data.Quad)
		table.clear(calls)
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(5)
			data.Gems.Set(7)
			error("abort")
		end)
		local seen =
			`ok={tostring(ok)} calls=[{table.concat(calls, " ")}] fires=[{table.concat(fires, " ")}] chain={data.Sum.Get()},{data.Double.Get()},{data.Quad.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false calls=[S1+1] fires=[] chain=2,4,8")
	end)

	it("restores a derived field the body read, with one fire back to the old value", function()
		-- Aaa sorts before its inputs, so its own snapshot is restored first.
		local calls = {}
		local harness = TestCtx.make({
			Template = {
				Aaa = Scribe.Derived(Scribe.Int(0), { "Coins", "Gems" }, function(c, g)
					table.insert(calls, `{c}+{g}`)
					return c + g
				end),
				Coins = Scribe.Int(0),
				Gems = Scribe.Int(0),
			},
		})
		local player, _entry, data = harness.Join(72006)
		data.Coins.Set(1)
		local fires = {}
		on(fires, "Aaa", data.Aaa)
		table.clear(calls)
		local readInside
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(5)
			data.Gems.Set(2)
			readInside = data.Aaa.Get()
			data.Gems.Set(4)
			error("abort")
		end)
		local seen = `ok={tostring(ok)} read={readInside} calls=[{table.concat(calls, " ")}] fires=[{table.concat(
			fires,
			" "
		)}] aaa={data.Aaa.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false read=7 calls=[5+2 1+0] fires=[Aaa:1->7 Aaa:7->1] aaa=1")
	end)

	it("still lands, emits and settles a listener's write made during the drain", function()
		local calls = {}
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0 }),
				Gems = Scribe.Int(0, { Min = 0 }),
				Total = Scribe.Derived(Scribe.Int(0), { "Coins", "Gems" }, function(c, g)
					table.insert(calls, `{c}+{g}`)
					return c + g
				end),
			},
		})
		local player, _entry, data = harness.Join(72007)
		data.Coins.Set(100)
		data.Gems.Set(5)
		data.Coins.Changed(function(new)
			data.Gems.Set(new + 1)
		end)
		local fires = {}
		on(fires, "Total", data.Total)
		table.clear(calls)
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(200)
			data.Gems.Set(300)
			error("abort")
		end)
		local seen =
			`ok={tostring(ok)} calls=[{table.concat(calls, " ")}] fires=[{table.concat(fires, " ")}] final={data.Coins.Get()}/{data.Gems.Get()}/{data.Total.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false calls=[100+5 100+101] fires=[Total:105->201] final=100/101/201")
	end)

	it("settles on the next write after a restore throws part-way", function()
		local harness = TestCtx.make({ Template = sumTemplate({}) })
		local player, _entry, data = harness.Join(72008)
		local fires = {}
		on(fires, "Coins", data.Coins)
		on(fires, "Total", data.Total)
		local push = harness.Ctx.Replication.PushOp
		local armed = false
		-- Throw during restore, before the final recompute.
		harness.Ctx.Replication.PushOp = function(e, op, schema)
			if armed and op.Path[1] == "Gems" then
				armed = false
				error("injected restore failure")
			end
			return push(e, op, schema)
		end
		local pok, perr = pcall(harness.Data.Transaction, player, function()
			data.Coins.Set(5)
			data.Gems.Set(2)
			armed = true
			error("abort")
		end)
		harness.Ctx.Replication.PushOp = push
		local threw =
			`threw={tostring(not pok and string.find(tostring(perr), "injected restore failure", 1, true) ~= nil)}`
		table.clear(fires)
		-- No read in between: a read settles on its own, and would hide a write that does not.
		data.Coins.Set(9)
		local seen = `{threw} fires=[{table.concat(fires, " ")}]`
		harness.Cleanup()
		-- No partial restore may replace Total's pre-transaction value.
		expect(seen).toBe("threw=true fires=[Coins:0->9 Total:0->9]")
	end)

	it("inside Data.Batch the rollback already recomputes once", function()
		local calls = {}
		local harness = TestCtx.make({ Template = sumTemplate(calls) })
		local player, _entry, data = harness.Join(72009)
		local fires = {}
		on(fires, "Total", data.Total)
		table.clear(calls)
		local okTxn
		harness.Data.Batch(player, function()
			data.Coins.Set(1)
			okTxn = harness.Data.Transaction(player, function()
				data.Aaa.Set(1)
				data.Coins.Set(5)
				data.Gems.Set(2)
				error("abort")
			end)
		end)
		local seen =
			`ok={tostring(okTxn)} calls=[{table.concat(calls, " ")}] fires=[{table.concat(fires, " ")}] total={data.Total.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false calls=[1+0] fires=[Total:0->1] total=1")
	end)

	it("leaves no derived field stale when a read inside the transaction spent its mark", function()
		-- A read inside the transaction settles a pending batch write.
		-- Rollback must restore that value even when none of its inputs were restored.
		local harness = TestCtx.make({ Template = sumTemplate({}) })
		local player, _entry, data = harness.Join(72010)
		local okTxn
		harness.Data.Batch(player, function()
			data.Coins.Set(1)
			okTxn = harness.Data.Transaction(player, function()
				local _ = data.Total.Get()
				error("abort")
			end)
		end)
		local seen = `ok={tostring(okTxn)} coins={data.Coins.Get()} total={data.Total.Get()}`
		harness.Cleanup()
		expect(seen).toBe("ok=false coins=1 total=1")
	end)

	it("sends no restore op for a derived field the client computes itself", function()
		-- The client never saw the body's derived op; it recomputes from restored inputs.
		-- The production wire: Studio defaults DevMode on, which sends what a client
		-- computes itself so it can audit the function.
		local harness = TestCtx.make({ Template = sumTemplate({}), AutoPump = true, Options = { DevMode = false } })
		local player, _entry, data = harness.Join(72011)
		harness.SendHello(player)
		harness.StepUntil(function()
			return #harness.FramesFor(player, Wire.Frames.Init) > 0
		end)
		table.clear(harness.Transport.SentToClientLog)
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(5)
			data.Gems.Set(3)
			local _ = data.Total.Get()
			error("abort")
		end)
		harness.Step()
		local ops = {}
		for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
			for _, op in frame.Ops do
				-- The save-state mirror is deferred, so on a real engine its write can land
				-- in this frame; it is not what this case is about.
				if op.Path[1] ~= "_ScribeSession" then
					table.insert(ops, `{table.concat(op.Path, ".")}={tostring(op.Value)}`)
				end
			end
		end
		table.sort(ops)
		harness.Cleanup()
		expect(`ok={tostring(ok)} ops=[{table.concat(ops, " ")}]`).toBe("ok=false ops=[Coins=0 Gems=0]")
	end)
end)
