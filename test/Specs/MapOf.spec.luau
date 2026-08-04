--!nonstrict
-- Scribe.MapOf: a dictionary whose KEY type is declared. Scribe.DictOf is the
-- string-keyed shorthand.
--
-- The declared key type is not sugar. A DataStore serializes every object key to a
-- JSON string, so an integer-keyed map comes back holding "123" where it stored
-- 123, and only the declaration makes converting it back unambiguous: without it,
-- "123" on disk could equally have been the number 123 or the string "123". Scribe
-- already fights that ambiguity internally, which is why a numeric key and its
-- string form are refused in the same container.

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
			Template = {
				Friends = Scribe.MapOf("integer", { Name = Scribe.String(""), Seen = Scribe.Int(0) }),
				Tags = Scribe.MapOf("string", Scribe.Int(0)),
			},
		})
	end

	it("takes integer keys without a tostring at the boundary", function()
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97301)

		data.Friends[123456].Name.Set("Ada")
		expect(data.Friends[123456].Name.Get()).to.equal("Ada")
		-- Stored as a real number, not a stringified one.
		expect(type(next(entry.LiveData.Friends))).to.equal("number")

		harness.Cleanup()
	end)

	it("refuses a key of the wrong declared type on either map", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97302)

		-- The string form of a valid integer key is still refused: allowing both
		-- would let 123 and "123" name the same slot through different paths.
		expect(function()
			data.Friends["123"].Name.Set("Nope")
		end).to.throw()
		expect(function()
			data.Tags[7].Set(1)
		end).to.throw()

		harness.Cleanup()
	end)

	it("refuses integer keys that cannot survive the round trip", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97303)

		expect(function()
			data.Friends[1.5].Name.Set("Nope")
		end).to.throw()
		expect(function()
			data.Friends[0 / 0].Name.Set("Nope")
		end).to.throw()
		expect(function()
			data.Friends[math.huge].Name.Set("Nope")
		end).to.throw()

		harness.Cleanup()
	end)

	it("restores integer keys that a DataStore handed back as strings", function()
		-- The case the fake store cannot produce on its own, and the one that makes
		-- this feature correct rather than cosmetic.
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97304)
		data.Friends[123456].Name.Set("Ada")
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97304"]

		local asJson = { Tags = {}, Friends = {}, _Scribe = saved._Scribe }
		for key, value in saved.Friends do
			asJson.Friends[tostring(key)] = value
		end
		expect(type(next(asJson.Friends))).to.equal("string")

		local reloaded = makeHarness()
		reloaded.Fake.Persisted["Default/PLAYER_97304"] = asJson
		local _p2, entry2, data2 = reloaded.Join(97304)

		expect(type(next(entry2.LiveData.Friends))).to.equal("number")
		expect(data2.Friends[123456].Name.Get()).to.equal("Ada")
		reloaded.Cleanup()

		harness.Cleanup()
	end)

	it("leaves a key that was never a canonical integer alone", function()
		-- "07" and "1.5" were not written by this map, so relocating them would be
		-- inventing data rather than restoring it.
		local harness = makeHarness()
		local player, _entry, data = harness.Join(97305)
		data.Friends[1].Name.Set("One")
		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97305"]

		local reloaded = makeHarness()
		reloaded.Fake.Persisted["Default/PLAYER_97305"] = {
			Tags = {},
			Friends = { ["07"] = { Name = "Odd", Seen = 0 } },
			_Scribe = saved._Scribe,
		}
		local _p2, entry2 = reloaded.Join(97305)
		expect(type(next(entry2.LiveData.Friends))).to.equal("string")
		reloaded.Cleanup()

		harness.Cleanup()
	end)

	it("accepts its own key type on a WHOLE-container write", function()
		-- The per-key accessor path and the whole-table validator are separate gates.
		-- The validator assumed DictOf's string keys, so a map rejected its own
		-- integer keys on Set/Update and accepted the strings it cannot store. Writing
		-- one key at a time never touches this path.
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97308)

		data.Friends.Set({ [123] = { Name = "Ada", Seen = 1 } })
		expect(data.Friends[123].Name.Get()).to.equal("Ada")

		data.Friends.Update(function(current)
			current[456] = { Name = "Bob", Seen = 2 }
			return current
		end)
		expect(data.Friends[456].Name.Get()).to.equal("Bob")

		-- And the keys it cannot store are still refused here, not just per-key.
		expect(function()
			data.Friends.Set({ ["789"] = { Name = "Str", Seen = 0 } })
		end).to.throw()
		expect(function()
			data.Friends.Set({ [1.5] = { Name = "Frac", Seen = 0 } })
		end).to.throw()

		-- A string map is unaffected.
		data.Tags.Set({ Alpha = 1 })
		expect(data.Tags.Alpha.Get()).to.equal(1)

		harness.Cleanup()
	end)

	it("refuses a numeric key whose string form already exists in the container", function()
		-- A numeric key and its string form cannot coexist: a DataStore refuses the
		-- mixed table, and the load-time key coercion resolves the pair by
		-- overwriting one with the other, silently losing a saved write. A nested
		-- write reaches the container through a different path than a direct one, so
		-- it gets its own coverage.
		local harness = TestCtx.make({
			Template = { Rooms = Scribe.DictOf({ Level = Scribe.Int(0) }) },
		})
		local _player, entry, data = harness.Join(97815)

		data.Rooms["11"].Level.Set(1)
		expect(entry.LiveData.Rooms["11"]).to.be.ok()
		-- Now reach the same container through the NUMERIC form.
		expect(function()
			data.Rooms[11].Level.Set(2)
		end).to.throw()
		-- Nothing partial was seeded on the way to the error.
		expect(entry.LiveData.Rooms[11]).to.equal(nil)
		expect(entry.LiveData.Rooms["11"].Level).to.equal(1)

		harness.Cleanup()
	end)

	it("refuses a write that would leave both key types in one table", function()
		-- Load-time coercion is all-or-nothing: a key that is not a canonical integer
		-- spelling ("07") blocks the whole container, so the strings stay. Writing an
		-- integer key then produces a table holding both types, which no DataStore
		-- will store, so the WHOLE profile save fails rather than just this field.
		local harness = TestCtx.make({
			Template = { Friends = Scribe.MapOf("integer", Scribe.String("")) },
		})
		local player, entry, data = harness.Join(97820)
		-- Stand in for a profile that loaded with an uncoercible key.
		entry.LiveData.Friends["07"] = "Legacy"

		expect(function()
			data.Friends[22].Set("Ada")
		end).to.throw()
		-- Nothing partial was written, so the container is still saveable as it was.
		expect(entry.LiveData.Friends[22]).to.equal(nil)
		expect(entry.LiveData.Friends["07"]).to.equal("Legacy")

		-- Writing an EXISTING integer key is unaffected, and so is removal.
		entry.LiveData.Friends["07"] = nil
		data.Friends[22].Set("Ada")
		expect(data.Friends[22].Get()).to.equal("Ada")

		harness.Leave(player)
		harness.Cleanup()
	end)

	it("rejects a bad key type or option at declaration", function()
		expect(function()
			Scribe.MapOf("float", Scribe.Int(0))
		end).to.throw()
		expect(function()
			Scribe.MapOf("integer", Scribe.Int(0), { MaxKeyz = 4 })
		end).to.throw()
		-- MaxKeyLength is meaningless for integer keys, so accepting it would read as
		-- a cap that does nothing.
		expect(function()
			Scribe.MapOf("integer", Scribe.Int(0), { MaxKeyLength = 4 })
		end).to.throw()
		expect(function()
			Scribe.MapOf("string", Scribe.Int(0), { MaxKeyLength = 4 })
		end).never.to.throw()
	end)

	it("supports the dictionary surface on an integer map", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97306)

		data.Friends[10].Name.Set("Ten")
		data.Friends[20].Name.Set("Twenty")
		expect(data.Friends.Count()).to.equal(2)

		local added = {}
		data.Friends.OnKeyAdded(function(key)
			table.insert(added, tostring(key))
		end)
		data.Friends[30].Name.Set("Thirty")
		expect(table.concat(added, ",")).to.equal("30")

		data.Friends.Remove(10)
		expect(data.Friends.Count()).to.equal(2)

		harness.Cleanup()
	end)

	itRunning("replicates an integer-keyed map to the client", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(97307)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		data.Friends[123456].Name.Set("Ada")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()

		-- The key has to arrive as a number, or the mirror indexes a different slot
		-- than the server wrote.
		expect(client.Friends[123456].Name.Get()).to.equal("Ada")
		expect(type(next(client.Friends.Get()))).to.equal("number")

		harness.Cleanup()
	end)
end
