--!nonstrict
-- Scribe.Flags: a fixed set of named booleans in one field. Stored as the enabled
-- member NAMES in declaration order, packed to a bitmask only on the wire.
--
-- That split is the whole design. A bitmask is positional, so if it were the stored
-- form, reordering or removing a member in a later release would silently remap
-- every existing player's flags. Storing names makes reordering a no-op, and the
-- positional packing never outlives the frame that created it, because both ends of
-- a replication frame come from the same build.

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
			Template = { Tut = Scribe.Flags({ "Move", "Combat", "Trade" }) },
		})
	end

	it("refuses a duplicate or non-UTF-8 member name at declaration", function()
		-- A member NAME is persisted verbatim, and it is the one persisted string with
		-- no write-path guard because it comes from the template rather than a Set.
		-- Invalid UTF-8 fails the whole profile save, opaquely, the first time that
		-- flag is enabled. A duplicate is unreachable instead: the index keeps only
		-- the last, so the earlier bit can never be read back.
		expect(function()
			TestCtx.make({ Template = { F = Scribe.Flags({ "A", "B", "A" }) } }).Cleanup()
		end).to.throw()
		expect(function()
			TestCtx.make({ Template = { F = Scribe.Flags({ "A", "\xff\xfe" }) } }).Cleanup()
		end).to.throw()
		expect(function()
			TestCtx.make({ Template = { F = Scribe.Flags({ "A", "B" }) } }).Cleanup()
		end).never.to.throw()
	end)

	it("refuses container mutation, which would corrupt the member list", function()
		-- Flags is a leaf whose stored form is the list of enabled member names, so
		-- the container mutations reached it: Insert stored a non-member, and a
		-- positional write overwrote an enabled flag in place. Both persisted.
		local harness = TestCtx.make({ Template = { Tutorial = Scribe.Flags({ "Move", "Combat" }) } })
		local _player, entry, data = harness.Join(97930)
		data.Tutorial.Enable("Combat")

		expect(function()
			data.Tutorial.Insert("NotAMember")
		end).to.throw()
		expect(function()
			return data.Tutorial[1].Set("NotAMember")
		end).to.throw()
		expect(function()
			data.Tutorial.Remove(1)
		end).to.throw()

		expect(data.Tutorial.Has("Combat")).to.equal(true)
		expect(#entry.LiveData.Tutorial).to.equal(1)
		-- Clear is legitimate: {} is a real state, "nothing enabled".
		expect(function()
			data.Tutorial.Clear()
		end).never.to.throw()
		expect(data.Tutorial.Has("Combat")).to.equal(false)

		harness.Cleanup()
	end)

	it("enables, disables, and reports membership by name", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97101)

		expect(#data.Tut.Get()).to.equal(0)
		data.Tut.Enable("Combat")
		expect(data.Tut.Has("Combat")).to.equal(true)
		expect(data.Tut.Has("Trade")).to.equal(false)
		data.Tut.Disable("Combat")
		expect(data.Tut.Has("Combat")).to.equal(false)

		harness.Cleanup()
	end)

	it("stores enabled names in declaration order, whatever order they were set in", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97102)

		-- Enabled back to front.
		data.Tut.Enable("Trade")
		data.Tut.Enable("Move")
		-- Canonical order means two profiles with the same flags hold the same table,
		-- so equality and diffing do not depend on which order the game happened to
		-- flip them in.
		expect(table.concat(data.Tut.Get(), ",")).to.equal("Move,Trade")

		-- A whole-value Set normalizes too, and drops duplicates.
		data.Tut.Set({ "Trade", "Move", "Trade" })
		expect(table.concat(data.Tut.Get(), ",")).to.equal("Move,Trade")

		harness.Cleanup()
	end)

	it("refuses a name that is not a member, rather than storing it", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97103)

		expect(function()
			data.Tut.Enable("Nope")
		end).to.throw()
		expect(function()
			data.Tut.Disable("Nope")
		end).to.throw()
		expect(function()
			data.Tut.Toggle("Nope")
		end).to.throw()
		-- Including through the whole-value write path.
		expect(function()
			data.Tut.Set({ "Move", "Nope" })
		end).to.throw()
		expect(#data.Tut.Get()).to.equal(0)

		harness.Cleanup()
	end)

	it("does not fire Changed when a flag is set to what it already is", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97104)

		local fires = 0
		data.Tut.Changed(function()
			fires += 1
		end)

		data.Tut.Enable("Combat")
		data.Tut.Enable("Combat") -- no transition
		data.Tut.Disable("Trade") -- was never on
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)

	it("flips several flags in one write under Batch", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97105)

		local fires = 0
		data.Tut.Changed(function()
			fires += 1
		end)

		harness.Data.Batch(player, function()
			data.Tut.Enable("Move")
			data.Tut.Enable("Combat")
			data.Tut.Enable("Trade")
		end)

		-- Three flags, one leaf field, so three writes to the SAME leaf. A leaf
		-- reports every transition, which is the documented rule.
		expect(fires).to.equal(3)
		expect(table.concat(data.Tut.Get(), ",")).to.equal("Move,Combat,Trade")

		harness.Cleanup()
	end)

	it("Toggle flips a named flag and returns its new state", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97106)

		expect(data.Tut.Toggle("Combat")).to.equal(true)
		expect(data.Tut.Has("Combat")).to.equal(true)
		expect(data.Tut.Toggle("Combat")).to.equal(false)
		expect(data.Tut.Has("Combat")).to.equal(false)
		-- A boolean field's Toggle is untouched by the flags branch.
		local plain = TestCtx.make({ Template = { Music = true } })
		local _p, _e, d = plain.Join(97107)
		expect(d.Music.Toggle()).to.equal(false)
		plain.Cleanup()

		harness.Cleanup()
	end)

	it("survives a save and reload, and a member reorder", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97108)
		data.Tut.Enable("Move")
		data.Tut.Enable("Trade")
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97108"]

		-- The stored form is the NAMES, which is what makes the reorder below safe.
		expect(type(saved.Tut)).to.equal("table")
		expect(table.concat(saved.Tut, ",")).to.equal("Move,Trade")

		-- A later release reorders the member list. A packed bitmask would now read
		-- as a completely different set of flags.
		local reordered = TestCtx.make({
			Template = { Tut = Scribe.Flags({ "Trade", "Combat", "Move" }) },
		})
		reordered.Fake.Persisted["Default/PLAYER_97108"] = saved
		local _p2, _e2, d2 = reordered.Join(97108)
		expect(d2.Tut.Has("Move")).to.equal(true)
		expect(d2.Tut.Has("Trade")).to.equal(true)
		expect(d2.Tut.Has("Combat")).to.equal(false)
		reordered.Cleanup()

		harness.Cleanup()
	end)

	it("rejects more than 32 members at compile time", function()
		local members = {}
		for i = 1, 33 do
			members[i] = `M{i}`
		end
		-- bit32 is 32 bits, so a 33rd member would fall off the wire packing rather
		-- than round-tripping.
		expect(function()
			TestCtx.make({ Template = { T = Scribe.Flags(members) } }).Cleanup()
		end).to.throw()
		members[33] = nil
		expect(function()
			TestCtx.make({ Template = { T = Scribe.Flags(members) } }).Cleanup()
		end).never.to.throw()
	end)

	itRunning("round-trips the bitmask packing to the client", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(97109)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		data.Tut.Enable("Move")
		data.Tut.Enable("Trade")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()

		-- Packed to bits on the way out, unpacked back to names on the way in.
		expect(table.concat(client.Tut.Get(), ",")).to.equal("Move,Trade")

		data.Tut.Disable("Move")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()
		expect(table.concat(client.Tut.Get(), ",")).to.equal("Trade")

		harness.Cleanup()
	end)

	itRunning("packs every member of a wide flags field, past one byte", function()
		-- The width is chosen by member count (u8, u16, u32). A 20-member field
		-- exercises the u32 branch, where an off-by-one in the bit maths shows up as
		-- a dropped or invented flag.
		local members = {}
		for i = 1, 20 do
			members[i] = `M{i}`
		end
		local harness = TestCtx.make({ AutoPump = true, Template = { Wide = Scribe.Flags(members) } })
		local player, entry, data = harness.Join(97110)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		-- First, last, and one in the middle.
		data.Wide.Enable("M1")
		data.Wide.Enable("M13")
		data.Wide.Enable("M20")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()

		expect(table.concat(client.Wide.Get(), ",")).to.equal("M1,M13,M20")

		harness.Cleanup()
	end)
end
