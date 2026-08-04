--!nonstrict
-- Scribe.SetOf: a collection of unique entries, for the shape people otherwise
-- express as a dictionary of `true` values (owned items, unlocked levels,
-- completed quests). It compiles to the same Array container as Scribe.ArrayOf
-- and adds a uniqueness invariant, so it inherits the element schema, the wire
-- codec, and MaxItems for free.
--
-- The stored form is deduplicated and sorted, so two profiles holding the same
-- members hold the same table and Add is idempotent regardless of write order.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function makeHarness()
		return TestCtx.make({
			AutoPump = true,
			Template = { Unlocked = Scribe.SetOf(Scribe.String("")) },
		})
	end

	it("adds, removes, and reports membership by value", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97201)

		expect(data.Unlocked.Add("Desert")).to.equal(true)
		expect(data.Unlocked.Has("Desert")).to.equal(true)
		expect(data.Unlocked.Count()).to.equal(1)
		-- Remove takes the VALUE, not an index: a set has no order to index into.
		expect(data.Unlocked.Remove("Desert")).to.equal(true)
		expect(data.Unlocked.Has("Desert")).to.equal(false)

		harness.Cleanup()
	end)

	it("treats a duplicate Add and an absent Remove as no-ops", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97202)

		local fires = 0
		data.Unlocked.Changed(function()
			fires += 1
		end)

		expect(data.Unlocked.Add("Desert")).to.equal(true)
		expect(data.Unlocked.Add("Desert")).to.equal(false) -- already a member
		expect(data.Unlocked.Remove("Arctic")).to.equal(false) -- never was one
		expect(data.Unlocked.Count()).to.equal(1)
		-- Only the one real transition wrote, replicated, and fired.
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)

	it("keeps the stored form deduplicated and sorted", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97203)

		data.Unlocked.Add("Desert")
		data.Unlocked.Add("Arctic")
		data.Unlocked.Add("Beach")
		-- Sorted, not insertion order, so the stored value is canonical.
		expect(table.concat(data.Unlocked.Get(), ",")).to.equal("Arctic,Beach,Desert")

		-- A whole-value Set is normalized on the same path.
		data.Unlocked.Set({ "Zed", "Alpha", "Zed" })
		expect(table.concat(data.Unlocked.Get(), ",")).to.equal("Alpha,Zed")

		harness.Cleanup()
	end)

	it("works with a numeric element type", function()
		local harness = TestCtx.make({ Template = { Ids = Scribe.SetOf(Scribe.Int(0)) } })
		local _player, _entry, data = harness.Join(97204)

		data.Ids.Add(30)
		data.Ids.Add(4)
		data.Ids.Add(30)
		expect(table.concat(data.Ids.Get(), ",")).to.equal("4,30")
		expect(data.Ids.Has(4)).to.equal(true)

		harness.Cleanup()
	end)

	it("caps membership with MaxItems and refuses Evict", function()
		local capped = TestCtx.make({ Template = { S = Scribe.SetOf(Scribe.Int(0), { MaxItems = 2 }) } })
		local _player, _entry, data = capped.Join(97205)
		data.S.Add(1)
		data.S.Add(2)
		expect(function()
			data.S.Add(3)
		end).to.throw()
		-- A duplicate at the cap is still a no-op rather than an error.
		expect(data.S.Add(2)).to.equal(false)
		capped.Cleanup()

		-- A set has no oldest entry, so an eviction policy is meaningless on it. The
		-- declarator refuses it as an unknown option, which is why there is no
		-- separate compile-time guard: it could never be reached.
		expect(function()
			Scribe.SetOf(Scribe.Int(0), { MaxItems = 2, Evict = "Front" })
		end).to.throw()
	end)

	it("refuses Insert and positional writes, which bypass dedupe and ordering", function()
		-- A set's stored form is deduplicated and sorted by the whole-value write
		-- path. Insert and a positional write go straight to the array, so they
		-- persisted duplicates and broke the ordering that Add/Has/Remove rely on.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97230)
		data.Unlocked.Add("Desert")

		expect(function()
			data.Unlocked.Insert("Desert")
		end).to.throw()
		-- Remove is the set's own by-VALUE remove, so it needs no guard: an index is
		-- simply not a member. This pins that it stayed that way.
		expect(data.Unlocked.Remove(1)).to.equal(false)

		expect(data.Unlocked.Count()).to.equal(1)
		expect(#entry.LiveData.Unlocked).to.equal(1)
		-- The membership surface is unaffected.
		expect(data.Unlocked.Add("Arctic")).to.equal(true)
		expect(data.Unlocked.Remove("Desert")).to.equal(true)

		harness.Cleanup()
	end)

	it("refuses an element it cannot order", function()
		-- Members are deduplicated and sorted into a canonical stored form, so the
		-- element has to be comparable. A record, a datatype or a Scribe.Big compiled
		-- clean, accepted the FIRST Add (one member never reaches a comparison), then
		-- threw a bare "attempt to compare table < table" on the second, naming
		-- neither Scribe nor the field.
		for _, element in
			{
				{ A = Scribe.Int(0) } :: any,
				Scribe.Big(0),
				Scribe.Vector3(Vector3.zero),
				false,
				Scribe.ArrayOf(Scribe.Int(0)),
			}
		do
			expect(function()
				TestCtx.make({ Template = { S = Scribe.SetOf(element) } }).Cleanup()
			end).to.throw()
		end

		-- The orderable scalars all still compile.
		for _, element in { Scribe.Int(0) :: any, Scribe.Number(0), Scribe.String(""), Scribe.Enum("a", { "a", "b" }) } do
			expect(function()
				TestCtx.make({ Template = { S = Scribe.SetOf(element) } }).Cleanup()
			end).never.to.throw()
		end
	end)

	it("survives a save and reload", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97206)
		data.Unlocked.Add("Desert")
		data.Unlocked.Add("Arctic")
		harness.Leave(player)

		local saved = harness.Fake.Persisted["Default/PLAYER_97206"]
		expect(table.concat(saved.Unlocked, ",")).to.equal("Arctic,Desert")

		local reloaded = makeHarness()
		reloaded.Fake.Persisted["Default/PLAYER_97206"] = saved
		local _p2, _e2, d2 = reloaded.Join(97206)
		expect(d2.Unlocked.Has("Desert")).to.equal(true)
		expect(d2.Unlocked.Count()).to.equal(2)
		reloaded.Cleanup()

		harness.Cleanup()
	end)

	it("rolls a membership change back with a failed transaction", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97207)
		data.Unlocked.Add("Desert")

		local ok = harness.Data.Transaction(player, function()
			data.Unlocked.Add("Arctic")
			data.Unlocked.Remove("Desert")
			error("boom")
		end)

		expect(ok).to.equal(false)
		expect(table.concat(data.Unlocked.Get(), ",")).to.equal("Desert")

		harness.Cleanup()
	end)

	itRunning("replicates membership to the client", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(97208)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		data.Unlocked.Add("Desert")
		data.Unlocked.Add("Arctic")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()
		expect(table.concat(client.Unlocked.Get(), ",")).to.equal("Arctic,Desert")

		data.Unlocked.Remove("Arctic")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()
		expect(table.concat(client.Unlocked.Get(), ",")).to.equal("Desert")

		harness.Cleanup()
	end)
end
