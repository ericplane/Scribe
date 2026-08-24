--!nonstrict
-- Three gaps in the accessor tree, all of them silent to the caller.
--
-- 1. `Insert(item, <non-number>)` raised `invalid argument #1 to 'clamp'` from
--    inside Node.luau. The dedicated `Scribe: Insert position must be an integer`
--    message existed but sat BELOW the `math.clamp` that computes the prospective
--    index, so the commonest mistake with this API could never reach it.
--
-- 2. `applySet`'s no-op early-out used `Util.leafEquals`, which reports every table
--    and every buffer as changed. A `Big`, a `Flags` and a packed datatype all
--    STORE as a table or a buffer, so `Set` with the value already there fired
--    `Changed` and queued a replication op -- while the same no-op on an `Int`
--    cost nothing. Measured: 0 fires for the Int, 1 for the Big.
--    `validateWrite` has just rebuilt those three into a canonical stored form, so
--    a value comparison over that form is sound where a deep compare of an
--    arbitrary user table would not be.
--
-- 3. `OnKeyAdded`/`OnKeyRemoved` were fired only for the ONE key a write touched,
--    on that key's direct parent. A whole-table `Set` at an ancestor introduces or
--    drops keys several levels down and said nothing, while `Count()` and `Get()`
--    both moved. Measured: `Root.Set({ Inner = { a = 1, b = 2 } })` fired
--    `Root.Inner.OnKeyAdded` 0 times.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Wire = require(ScribeRoot.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	describe("Insert position validation", function()
		it("names the position argument when it is not a number", function()
			local harness = TestCtx.make({ Template = { Bag = Scribe.ArrayOf(Scribe.Int(0)) } })
			local _player, _entry, data = harness.Join(98101)

			local ok, err = pcall(data.Bag.Insert, 1, "notanumber")
			expect(ok).to.equal(false)
			local message = tostring(err)
			expect(string.find(message, "Scribe: Insert position must be an integer", 1, true) ~= nil).to.equal(true)
			expect(string.find(message, "clamp", 1, true)).to.equal(nil)
			-- A refused Insert materializes nothing.
			expect(data.Bag.Count()).to.equal(0)

			harness.Cleanup()
		end)

		it("still refuses a fractional position, and still accepts a valid one", function()
			local harness = TestCtx.make({ Template = { Bag = Scribe.ArrayOf(Scribe.Int(0)) } })
			local _player, _entry, data = harness.Join(98102)

			local ok, err = pcall(data.Bag.Insert, 1, 1.5)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "Scribe: Insert position must be an integer", 1, true) ~= nil).to.equal(
				true
			)

			data.Bag.Insert(7)
			data.Bag.Insert(8, 1)
			expect(data.Bag.Count()).to.equal(2)
			expect(data.Bag[1].Get()).to.equal(8)
			expect(data.Bag[2].Get()).to.equal(7)

			harness.Cleanup()
		end)
	end)

	describe("no-op Set on a canonical stored form", function()
		local function makeHarness(userId)
			local harness = TestCtx.make({
				Template = {
					N = Scribe.Int(5),
					B = Scribe.Big(5),
					F = Scribe.Flags({ "A", "B", "C" }),
					V = Scribe.Vector3(Vector3.new(1, 2, 3)),
				},
			})
			local player, entry, data = harness.Join(userId)
			harness.SendHello(player)
			return harness, player, entry, data
		end

		local function counters(data)
			local seen = { N = 0, B = 0, F = 0, V = 0 }
			data.N.Changed(function()
				seen.N += 1
			end)
			data.B.Changed(function()
				seen.B += 1
			end)
			data.F.Changed(function()
				seen.F += 1
			end)
			data.V.Changed(function()
				seen.V += 1
			end)
			return seen
		end

		it("fires nothing and emits nothing when the value is already stored", function()
			local harness, player, entry, data = makeHarness(98201)
			data.F.Enable("A")
			harness.Ctx.Replication.FlushEntry(entry)
			local before = #harness.FramesFor(player, Wire.Frames.Diff)

			local seen = counters(data)
			data.N.Set(5)
			data.B.Set(5)
			data.F.Set({ "A" })
			data.V.Set(Vector3.new(1, 2, 3))
			harness.Ctx.Replication.FlushEntry(entry)

			expect(seen.N).to.equal(0)
			expect(seen.B).to.equal(0)
			expect(seen.F).to.equal(0)
			expect(seen.V).to.equal(0)
			expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(before)

			harness.Cleanup()
		end)

		it("still fires and still emits an op for a real change", function()
			local harness, player, entry, data = makeHarness(98202)
			data.F.Enable("A")
			harness.Ctx.Replication.FlushEntry(entry)

			local seen = counters(data)
			data.B.Set(7)
			data.F.Set({ "A", "B" })
			data.V.Set(Vector3.new(9, 9, 9))
			harness.Ctx.Replication.FlushEntry(entry)

			expect(seen.B).to.equal(1)
			expect(seen.F).to.equal(1)
			expect(seen.V).to.equal(1)
			expect(tostring(data.B.Get())).to.equal("7")
			expect(table.concat(data.F.Get(), ",")).to.equal("A,B")
			-- The headless runner models Vector3 as a table, so `==` on the value
			-- itself would compare identity and never hold. Compare components.
			local v = data.V.Get()
			expect(`{v.X},{v.Y},{v.Z}`).to.equal("9,9,9")

			local frames = harness.FramesFor(player, Wire.Frames.Diff)
			local ops = frames[#frames].Ops
			local paths = {}
			for _, op in ops do
				paths[table.concat(op.Path, ".")] = true
			end
			expect(paths.B).to.equal(true)
			expect(paths.F).to.equal(true)
			expect(paths.V).to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("key events under an ancestor whole-table Set", function()
		local function makeHarness(userId)
			local harness = TestCtx.make({
				Template = { Root = { Inner = Scribe.DictOf(Scribe.Int(0), { MaxKeys = 8 }) } },
			})
			local player, entry, data = harness.Join(userId)
			return harness, player, entry, data
		end

		it("fires OnKeyAdded on a nested container the Set fills", function()
			local harness, _player, _entry, data = makeHarness(98301)

			local added = {}
			data.Root.Inner.OnKeyAdded(function(key, value)
				table.insert(added, `{key}={value}`)
			end)

			data.Root.Set({ Inner = { a = 1, b = 2 } })

			table.sort(added)
			expect(#added).to.equal(2)
			expect(added[1]).to.equal("a=1")
			expect(added[2]).to.equal("b=2")
			expect(data.Root.Inner.Count()).to.equal(2)

			harness.Cleanup()
		end)

		it("fires OnKeyRemoved on a nested container the Set empties", function()
			local harness, _player, _entry, data = makeHarness(98302)
			data.Root.Set({ Inner = { a = 1, b = 2 } })

			local removed = {}
			data.Root.Inner.OnKeyRemoved(function(key, value)
				table.insert(removed, `{key}={value}`)
			end)

			data.Root.Set({ Inner = { a = 1 } })

			expect(#removed).to.equal(1)
			expect(removed[1]).to.equal("b=2")
			expect(data.Root.Inner.Count()).to.equal(1)

			harness.Cleanup()
		end)

		it("reports a key appearing or disappearing, never one changing", function()
			local harness, _player, _entry, data = makeHarness(98303)
			data.Root.Set({ Inner = { a = 1, b = 2 } })

			local keyEvents = 0
			data.Root.Inner.OnKeyAdded(function()
				keyEvents += 1
			end)
			data.Root.Inner.OnKeyRemoved(function()
				keyEvents += 1
			end)

			data.Root.Set({ Inner = { a = 5, b = 2 } })

			expect(keyEvents).to.equal(0)
			expect(data.Root.Inner.a.Get()).to.equal(5)

			harness.Cleanup()
		end)

		it("delivers every key event on a container before that container's Changed", function()
			local harness, _player, _entry, data = makeHarness(98304)

			local log = {}
			data.Root.Inner.OnKeyAdded(function(key)
				table.insert(log, `add:{key}`)
			end)
			data.Root.Inner.Changed(function()
				table.insert(log, "changed")
			end)

			data.Root.Set({ Inner = { a = 1, b = 2 } })

			expect(#log).to.equal(3)
			expect(log[3]).to.equal("changed")
			expect(log[1] ~= "changed").to.equal(true)
			expect(log[2] ~= "changed").to.equal(true)

			harness.Cleanup()
		end)
	end)
end
