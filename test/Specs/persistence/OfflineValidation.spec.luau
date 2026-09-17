--!nonstrict
-- UpdateOffline's opt-in validation: what the callback introduced, the reserved root, derived
-- fields and the schema version refuse; raw stays the default and a refusal is not an outage.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Log = require(Root.Scribe.Internal.Log)
	local Health = require(Root.Scribe.Internal.Health)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function keyFor(userId: number): string
		return `Default/PLAYER_{userId}`
	end

	local function levelFor(xp: number): number
		return math.floor(xp / 100) + 1
	end

	local function make(extra)
		local cfg = { Options = extra and extra.Options or nil, Template = extra and extra.Template or nil }
		return TestCtx.make(cfg)
	end

	describe("raw mode, the default", function()
		it("still persists a value the template would refuse, and the internal path is the same", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60001)] = { Coins = 5 }
			local ok = harness.Data.UpdateOffline(60001, function(data)
				data.Coins = "hello"
			end)
			local internalOk = harness.Ctx.Persistence.UpdateOffline(60001, function(data)
				data.Nick = "far too long a name"
			end)
			local stored = harness.Fake.Persisted[keyFor(60001)]
			harness.Cleanup()
			expect(`{ok} {internalOk} {stored.Coins} {stored.Nick}`).to.equal("true true hello far too long a name")
		end)
	end)

	describe("Validate = true", function()
		it("refuses a change the template would refuse, names it, and writes nothing", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60002)] = { Coins = 5 }
			local before = #Log.GetRecent({ Code = "OFFLINE_WRITE_FAIL" })
			local ok, reason, violations = harness.Data.UpdateOffline(60002, function(data)
				data.Coins = "hello"
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60002)].Coins
			local after = #Log.GetRecent({ Code = "OFFLINE_WRITE_FAIL" })
			harness.Cleanup()
			expect(`{ok} {reason}`).to.equal(
				'false the change does not match the template at "Coins": expected int, got string'
			)
			expect(`{#violations} {table.concat(violations[1].Path, ".")} {violations[1].Kind}`).to.equal(
				"1 Coins WrongType"
			)
			expect(`stored={stored} logged={after - before}`).to.equal("stored=5 logged=0")
		end)

		it("accepts a valid change and returns the usual contract", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60003)] = { Coins = 5 }
			local ok, reason, violations = harness.Data.UpdateOffline(60003, function(data)
				data.Coins = 42
				data.Nick = "ok"
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60003)]
			harness.Cleanup()
			expect(`{ok} {reason} {violations} {stored.Coins} {stored.Nick}`).to.equal("true nil nil 42 ok")
		end)

		it("judges the change, not the profile: a field that was already wrong passes through untouched", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60004)] = { Coins = 5, Nick = 12345 }
			local ok, reason = harness.Data.UpdateOffline(60004, function(data)
				data.Coins = 6
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60004)]
			local worse, worseReason = harness.Data.UpdateOffline(60004, function(data)
				data.Nick = "far too long a name"
			end, { Validate = true })
			harness.Cleanup()
			expect(`{ok} {reason} {stored.Coins} {stored.Nick}`).to.equal("true nil 6 12345")
			expect(`{worse} {worseReason}`).to.equal(
				'false the change does not match the template at "Nick": 19 bytes exceeds MaxLength 8'
			)
		end)

		it("exempts a pre-existing violation only while its value is unchanged", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60012)] = { Coins = -1 }
			local worse, worseReason = harness.Data.UpdateOffline(60012, function(data)
				data.Coins = -9999
			end, { Validate = true })
			local aside = harness.Data.UpdateOffline(60012, function(data)
				data.Gems = 3
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60012)]
			harness.Cleanup()
			expect(`{worse} {worseReason}`).to.equal(
				'false the change does not match the template at "Coins": -9999 is below Min 0'
			)
			expect(`{aside} {stored.Coins} {stored.Gems}`).to.equal("true -1 3")
		end)

		it("allows an edit inside a container already over its cap, but not growth", function()
			local harness = make({ Template = { Items = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 2 }) } })
			harness.Fake.Persisted[keyFor(60013)] = { Items = { 1, 2, 3 } }
			local edited = harness.Data.UpdateOffline(60013, function(data)
				data.Items[2] = 20
			end, { Validate = true })
			local grown, grownReason = harness.Data.UpdateOffline(60013, function(data)
				table.insert(data.Items, 4)
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60013)].Items
			harness.Cleanup()
			expect(`{edited} {grown} {table.concat(stored, ",")}`).to.equal("true false 1,20,3")
			expect(grownReason).to.equal(
				'the change does not match the template at "Items": holds 4 entries, over MaxItems 2'
			)
		end)

		it("compares a table-valued violation by value, not by size", function()
			local harness = make({
				Template = {
					Wealth = Scribe.Big(0, { Max = 100 }),
					Toggles = Scribe.Flags({ "A", "B" }),
				},
			})
			harness.Fake.Persisted[keyFor(60018)] = { Wealth = { 5, 2 }, Toggles = { "Zed" } }
			local bigOk, bigReason = harness.Data.UpdateOffline(60018, function(data)
				data.Wealth[2] = 3
			end, { Validate = true })
			local flagOk, flagReason = harness.Data.UpdateOffline(60018, function(data)
				data.Toggles[1] = "Zork"
			end, { Validate = true })
			local aside = harness.Data.UpdateOffline(60018, function(data)
				data.Wealth = { 5, 2 }
				data.Toggles = { "Zed" }
			end, { Validate = true })
			harness.Cleanup()
			expect(`{bigOk} {bigReason}`).to.equal(
				'false the change does not match the template at "Wealth": 5000 is above Max 100'
			)
			expect(`{flagOk} {flagReason}`).to.equal(
				'false the change does not match the template at "Toggles": Zork is not a declared flag'
			)
			expect(aside).to.equal(true)
		end)

		it("sees a buffer changed in place", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60019)] = { Nick = buffer.fromstring("ab") }
			local ok, reason = harness.Data.UpdateOffline(60019, function(data)
				buffer.writeu8(data.Nick, 0, 65)
			end, { Validate = true })
			local stored = buffer.tostring(harness.Fake.Persisted[keyFor(60019)].Nick)
			harness.Cleanup()
			expect(`{ok} {stored} {reason}`).to.equal(
				'false ab the change does not match the template at "Nick": expected string, got buffer'
			)
		end)

		it("counts a new overlong key as new, however many keys the dictionary keeps", function()
			local harness = make({ Template = { Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeyLength = 4 }) } })
			harness.Fake.Persisted[keyFor(60020)] = { Resources = { Wood = 1, Obsidian = 2 } }
			local aside = harness.Data.UpdateOffline(60020, function(data)
				data.Resources.Wood = 2
			end, { Validate = true })
			local ok, reason = harness.Data.UpdateOffline(60020, function(data)
				data.Resources.Obsidian = nil
				data.Resources.Bloodstone = 3
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60020)].Resources
			harness.Cleanup()
			expect(`{aside} {stored.Wood} {stored.Obsidian} {stored.Bloodstone}`).to.equal("true 2 2 nil")
			expect(`{ok} {reason}`).to.equal(
				'false the change does not match the template at "Resources.Bloodstone": key "Bloodstone" is 10 bytes, over MaxKeyLength 4'
			)
		end)

		it("counts a set's cap on distinct members, as the cap itself does", function()
			local harness = make({ Template = { Tags = Scribe.SetOf(Scribe.Int(0), { MaxItems = 2 }) } })
			harness.Fake.Persisted[keyFor(60021)] = { Tags = { 1, 1, 2, 3 } }
			local reordered = harness.Data.UpdateOffline(60021, function(data)
				data.Tags = { 3, 2, 1, 1 }
			end, { Validate = true })
			local grown, grownReason = harness.Data.UpdateOffline(60021, function(data)
				data.Tags = { 1, 4, 2, 3 }
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60021)].Tags
			harness.Cleanup()
			expect(`{reordered} {grown} {table.concat(stored, ",")}`).to.equal("true false 3,2,1,1")
			expect(grownReason).to.equal(
				'the change does not match the template at "Tags": holds 4 entries, over MaxItems 2'
			)
		end)

		it("refuses rather than guesses when the profile has more violations than it can compare", function()
			local tooMany =
				"the profile already carries 256 or more template violations, too many for validation to tell the change apart; repair it or write raw"
			local harness = make({ Template = { Items = Scribe.ArrayOf(Scribe.Int(0)) } })
			local function bad(count)
				local items = {}
				for i = 1, count do
					items[i] = "bad"
				end
				return items
			end
			-- Over the cap before: the third the callback did not repair was never all recorded.
			harness.Fake.Persisted[keyFor(60014)] = { Items = bad(300) }
			local repairOk, repairReason = harness.Data.UpdateOffline(60014, function(data)
				for i = 1, 100 do
					data.Items[i] = 0
				end
			end, { Validate = true })
			-- Under the cap before, over it after.
			harness.Fake.Persisted[keyFor(60017)] = { Items = bad(255) }
			local growOk, growReason = harness.Data.UpdateOffline(60017, function(data)
				data.Items[256] = "bad"
				data.Items[257] = "bad"
			end, { Validate = true })
			local stored = #harness.Fake.Persisted[keyFor(60017)].Items
			harness.Cleanup()
			expect(`{repairOk} {repairReason}`).to.equal(`false {tooMany}`)
			expect(`{growOk} {stored} {growReason}`).to.equal(`false 255 {tooMany}`)
		end)

		it("keeps a dotted key and a nested path apart when exempting", function()
			local harness = make({ Template = { Map = Scribe.DictOf(Scribe.DictOf(Scribe.Int(0))) } })
			harness.Fake.Persisted[keyFor(60015)] = { Map = { ["a.b"] = { c = "x" } } }
			local ok, reason = harness.Data.UpdateOffline(60015, function(data)
				data.Map.a = { ["b.c"] = "x" }
			end, { Validate = true })
			harness.Cleanup()
			expect(`{ok} {reason}`).to.equal(
				'false the change does not match the template at "Map.a.b.c": expected int, got string'
			)
		end)

		it("refuses a write to a Session field, which is never stored", function()
			local harness = make({ Template = { Coins = Scribe.Int(0), Round = Scribe.Session(Scribe.Int(0)) } })
			harness.Fake.Persisted[keyFor(60016)] = { Coins = 1 }
			local ok, reason = harness.Data.UpdateOffline(60016, function(data)
				data.Round = "bad"
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60016)].Round
			harness.Cleanup()
			expect(`{ok} {stored} {reason}`).to.equal(
				'false nil the change writes "Round", a Session field that is never stored'
			)
		end)

		it("refuses a profile whose schema version is not this build's, before running the callback", function()
			local harness = make({ Options = { Migrations = { [2] = function() end } } })
			harness.Fake.Persisted[keyFor(60005)] = { Coins = 5, _Scribe = { Version = 1 } }
			local ran = false
			local ok, reason = harness.Data.UpdateOffline(60005, function(data)
				ran = true
				data.Coins = 6
			end, { Validate = true })
			local rawOk = harness.Data.UpdateOffline(60005, function(data)
				data.Coins = 7
			end)
			harness.Fake.Persisted[keyFor(60006)] = { Coins = 5, _Scribe = { Version = 3 } }
			local aheadOk, aheadReason = harness.Data.UpdateOffline(60006, function() end, { Validate = true })
			harness.Cleanup()
			expect(`{ok} {ran} {reason}`).to.equal(
				"false false profile is at schema version 1 and this build is 2; load it in a session to migrate it first"
			)
			expect(rawOk).to.equal(true)
			expect(`{aheadOk} {aheadReason}`).to.equal(
				"false profile is at schema version 3, newer than this build's 2; update the place before editing it"
			)
		end)

		it("refuses a change under the reserved root, which is library-owned", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60007)] = { Coins = 5, _Scribe = { Version = 1, Boards = {} } }
			local ok, reason = harness.Data.UpdateOffline(60007, function(data)
				data._Scribe.Boards.Wins = { Baseline = 0 }
			end, { Validate = true })
			local untouched = harness.Fake.Persisted[keyFor(60007)]._Scribe.Boards.Wins
			harness.Cleanup()
			expect(`{ok} {reason} {untouched}`).to.equal(
				'false the change touches "_Scribe", which Scribe owns and an offline edit may not change nil'
			)
		end)

		it("refuses a write to a derived field, which is never stored", function()
			local harness = make({
				Template = {
					Xp = Scribe.Int(0, { Min = 0 }),
					Level = Scribe.Derived(Scribe.Int(1, { Min = 1 }), { "Xp" }, levelFor),
				},
			})
			harness.Fake.Persisted[keyFor(60008)] = { Xp = 50 }
			local ok, reason = harness.Data.UpdateOffline(60008, function(data)
				data.Level = 9
			end, { Validate = true })
			local inputOk = harness.Data.UpdateOffline(60008, function(data)
				data.Xp = 5000
			end, { Validate = true })
			local stored = harness.Fake.Persisted[keyFor(60008)]
			harness.Cleanup()
			expect(`{ok} {reason}`).to.equal(
				'false the change writes "Level", a derived field that is computed and never stored'
			)
			expect(`{inputOk} {stored.Xp} {stored.Level}`).to.equal("true 5000 nil")
		end)

		it("is a refusal, not an outage: health and the failure log see nothing", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60009)] = { Coins = 5 }
			local statusBefore = Health.GetStatus()
			for _ = 1, 6 do
				harness.Data.UpdateOffline(60009, function(data)
					data.Coins = "no"
				end, { Validate = true })
			end
			local statusAfter = Health.GetStatus()
			harness.Cleanup()
			expect(`{statusBefore} {statusAfter}`).to.equal("Healthy Healthy")
		end)

		it("keeps the session and conflict checks in front of it", function()
			local harness = make()
			harness.Fake.Persisted[keyFor(60010)] = { Coins = 5 }
			harness.Fake.ActiveProfiles[keyFor(60010)] = { PlaceId = 1, JobId = "other-server" }
			local ok, reason = harness.Data.UpdateOffline(60010, function(data)
				data.Coins = "no"
			end, { Validate = true })
			harness.Cleanup()
			expect(`{ok} {string.find(tostring(reason), "another server", 1, true) ~= nil}`).to.equal("false true")
		end)

		it("refuses an option it does not know, naming the one it does", function()
			local harness = make()
			local ok, err = pcall(function()
				return harness.Data.UpdateOffline(60011, function() end, { Validte = true })
			end)
			harness.Cleanup()
			expect(`{ok} {string.find(tostring(err), "Validate", 1, true) ~= nil}`).to.equal("false true")
		end)
	end)
end
