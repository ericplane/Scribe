--!nonstrict
-- The stored-shape validator.
--
-- The audit's finding was that 11 of 11 corrupt stored shapes reached Ready
-- silently. These specs are the corresponding detections, plus the cases that must
-- NOT be reported -- which matter just as much, because a validator that flags
-- healthy profiles is one that gets turned off.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Template = require(Root.Scribe.Internal.Template)
	local Conform = require(Root.Scribe.Internal.Conform)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local function compile(template)
		return Template.Compile(template, {})
	end

	local function kinds(violations)
		local out = {}
		for _, v in violations do
			table.insert(out, v.Kind)
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	describe("a healthy profile reports nothing", function()
		it("accepts stored data that matches the template", function()
			local compiled = compile({
				Coins = Scribe.Int(0, { Min = 0, Max = 1000 }),
				Name = Scribe.String("", { MaxLength = 16 }),
				Team = Scribe.Enum("Red", { "Red", "Blue" }),
			})
			expect(#Conform.Check(compiled, { Coins = 250, Name = "ok", Team = "Blue" })).to.equal(0)
		end)

		it("accepts a profile missing fields the template has since added", function()
			-- The reason this walk is data-driven. A profile written before a field
			-- existed simply does not carry it; Reconcile backfills moments later. A
			-- schema-driven walk would report every legitimately old profile as
			-- corrupt, which is worse than not checking at all.
			local compiled = compile({
				Coins = Scribe.Int(0),
				AddedLater = Scribe.String(""),
			})
			expect(#Conform.Check(compiled, { Coins = 5 })).to.equal(0)
		end)

		it("ignores a stale copy of a Session subtree", function()
			-- Session data is never stored, so a stored copy is stale rather than
			-- corrupt -- it is what an older build left behind. Reporting it would put
			-- a violation on every profile from before the field became Session.
			local compiled = compile({
				Coins = Scribe.Int(0),
				Runtime = Scribe.Session({ InCombat = false }),
			})
			expect(#Conform.Check(compiled, { Coins = 1, Runtime = { InCombat = "not a boolean" } })).to.equal(0)
		end)

		it("accepts an empty profile", function()
			local compiled = compile({ Coins = Scribe.Int(0) })
			expect(#Conform.Check(compiled, {})).to.equal(0)
		end)
	end)

	describe("wrong types are caught", function()
		it("catches a string where a number belongs", function()
			local compiled = compile({ Coins = Scribe.Int(0) })
			local found = Conform.Check(compiled, { Coins = "lots" })
			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("WrongType")
			expect(found[1].Path[1]).to.equal("Coins")
		end)

		it("catches a non-integer in an Int field", function()
			local compiled = compile({ Coins = Scribe.Int(0) })
			expect(kinds(Conform.Check(compiled, { Coins = 1.5 }))).to.equal("WrongType")
		end)

		it("catches NaN, which survives some JSON round trips", function()
			local compiled = compile({ Health = Scribe.Number(100) })
			expect(kinds(Conform.Check(compiled, { Health = 0 / 0 }))).to.equal("WrongType")
		end)

		it("catches a scalar where a table belongs", function()
			local compiled = compile({ Stats = { Wins = Scribe.Int(0) } })
			expect(kinds(Conform.Check(compiled, { Stats = 7 }))).to.equal("WrongType")
		end)
	end)

	describe("declared constraints are enforced", function()
		it("catches a number outside its bounds", function()
			local compiled = compile({ Coins = Scribe.Int(0, { Min = 0, Max = 100 }) })
			expect(kinds(Conform.Check(compiled, { Coins = 5000 }))).to.equal("OutOfBounds")
			expect(kinds(Conform.Check(compiled, { Coins = -1 }))).to.equal("OutOfBounds")
		end)

		it("catches a string past MaxLength", function()
			local compiled = compile({ Name = Scribe.String("", { MaxLength = 4 }) })
			expect(kinds(Conform.Check(compiled, { Name = "far too long" }))).to.equal("OverMaxLength")
		end)

		it("catches an enum value that is not a member", function()
			local compiled = compile({ Team = Scribe.Enum("Red", { "Red", "Blue" }) })
			expect(kinds(Conform.Check(compiled, { Team = "Green" }))).to.equal("NotAMember")
		end)

		describe("a Scribe.Big against its declared bounds", function()
			-- Compared through Big.from/Big.compare, which is the SAME pair the write
			-- path uses (Node.luau's `vt == "big"` branch). A plain `<`/`>` cannot do
			-- this job: a bound past 1.8e308 has to be written as a numeric string,
			-- because a bigger literal is already math.huge, so an ordinary comparison
			-- either throws on a mixed pair or orders two strings lexically.
			--
			-- The stored form is a { mantissa, exponent } pair, so every fixture below
			-- is written the way the datastore holds it rather than as a number.

			it("accepts a value inside them", function()
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 0, Max = 100 }) })
				expect(#Conform.Check(compiled, { Gold = { 5, 1 } })).to.equal(0) -- 50
			end)

			it("accepts a value exactly ON either bound", function()
				-- Inclusive, matching the write path: it refuses on `compare < 0` and
				-- `compare > 0`, so the bounds themselves are legal values.
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 10, Max = 100 }) })
				expect(#Conform.Check(compiled, { Gold = { 1, 1 } })).to.equal(0) -- 10
				expect(#Conform.Check(compiled, { Gold = { 1, 2 } })).to.equal(0) -- 100
			end)

			it("catches a value below Min", function()
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 10 }) })
				local found = Conform.Check(compiled, { Gold = { 1, 0 } }) -- 1
				expect(#found).to.equal(1)
				expect(found[1].Kind).to.equal("OutOfBounds")
				expect(table.concat(found[1].Path, ".")).to.equal("Gold")
			end)

			it("catches a value above Max", function()
				-- 5e50 against a Max of 100. This is the case the audit measured
				-- reporting NOTHING.
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 0, Max = 100 }) })
				expect(kinds(Conform.Check(compiled, { Gold = { 5, 50 } }))).to.equal("OutOfBounds")
			end)

			it("honours a bound past the double range, written as a string", function()
				-- The reason this goes through Big rather than through `>`. 1e600 is
				-- math.huge as a literal, so the bound can only be expressed as text --
				-- and a value on either side of it has to be ordered correctly.
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 0, Max = "1e600" }) })
				expect(#Conform.Check(compiled, { Gold = { 1, 500 } })).to.equal(0)
				expect(kinds(Conform.Check(compiled, { Gold = { 1, 700 } }))).to.equal("OutOfBounds")
			end)

			it("reports nothing when no bounds are declared", function()
				local compiled = compile({ Gold = Scribe.Big(0) })
				expect(#Conform.Check(compiled, { Gold = { 9, 999 } })).to.equal(0)
			end)

			it("catches a pair whose halves are not finite", function()
				-- The shape check passes -- both halves ARE numbers -- but the value is
				-- not a big at all, and every comparison against it is meaningless. The
				-- number branch calls NaN out for the same reason.
				local compiled = compile({ Gold = Scribe.Big(0, { Min = 0 }) })
				expect(kinds(Conform.Check(compiled, { Gold = { 0 / 0, 0 } }))).to.equal("WrongType")
				expect(kinds(Conform.Check(compiled, { Gold = { 1, math.huge } }))).to.equal("WrongType")
			end)
		end)

		it("catches invalid UTF-8, which would fail every future save", function()
			-- Not pedantry: one bad byte fails the WHOLE profile save with a
			-- DataStore 104, so the profile silently stops persisting.
			local compiled = compile({ Name = Scribe.String("") })
			local bad = "ok" .. string.char(0xFF, 0xFE)
			expect(kinds(Conform.Check(compiled, { Name = bad }))).to.equal("BadEncoding")
		end)
	end)

	describe("stored form, not read form", function()
		it("does not mistake a correctly-packed datatype for corruption", function()
			-- A datatype is stored as a packed buffer. Checking the READ form here
			-- would report every healthy profile that uses one.
			local compiled = compile({ Spawn = Scribe.Vector3(Vector3.new(0, 0, 0)) })
			local packed = buffer.create(16)
			expect(#Conform.Check(compiled, { Spawn = packed })).to.equal(0)
		end)

		it("catches a datatype stored raw instead of packed", function()
			local compiled = compile({ Spawn = Scribe.Vector3(Vector3.new(0, 0, 0)) })
			local found = Conform.Check(compiled, { Spawn = { X = 1, Y = 2, Z = 3 } })
			expect(kinds(found)).to.equal("WrongType")
		end)

		it("accepts a Big in its stored mantissa/exponent form", function()
			local compiled = compile({ Gold = Scribe.Big(0) })
			expect(#Conform.Check(compiled, { Gold = { 1.5, 6 } })).to.equal(0)
		end)

		it("catches a Big stored as a plain number", function()
			local compiled = compile({ Gold = Scribe.Big(0) })
			expect(kinds(Conform.Check(compiled, { Gold = 1500000 }))).to.equal("WrongType")
		end)

		it("accepts a Flags field in its stored member-name form", function()
			-- The third of the three value types whose stored form is not its read
			-- form, and the one that had no case here. Scribe.Flags defaults to `{}`,
			-- which made the compiled node Kind "table" -- so the walk recursed INTO
			-- the stored array of member names and reported "expected a table, got
			-- string" once per ENABLED FLAG, on a completely healthy profile.
			local compiled = compile({ Tutorial = Scribe.Flags({ "Movement", "Combat", "Trading" }) })
			expect(#Conform.Check(compiled, { Tutorial = {} })).to.equal(0)
			expect(#Conform.Check(compiled, { Tutorial = { "Combat" } })).to.equal(0)
			expect(#Conform.Check(compiled, { Tutorial = { "Movement", "Combat", "Trading" } })).to.equal(0)
		end)

		it("catches a flag name the template does not declare", function()
			-- NotAMember, the same kind an enum reports -- not the WrongType that
			-- recursing into the array produced.
			local compiled = compile({ Tutorial = Scribe.Flags({ "Movement", "Combat" }) })
			local found = Conform.Check(compiled, { Tutorial = { "Nonsense" } })
			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("NotAMember")
			expect(table.concat(found[1].Path, ".")).to.equal("Tutorial")
		end)

		it("catches a Flags field stored as something other than an array", function()
			local compiled = compile({ Tutorial = Scribe.Flags({ "Movement" }) })
			expect(kinds(Conform.Check(compiled, { Tutorial = "Movement" }))).to.equal("WrongType")
		end)

		it("accepts Scribe's own reserved subtree", function()
			-- The reason this defect does not need a Scribe.Flags field to bite. The
			-- reserved `_Scribe` root is Persist = true, so Conform walks it, and every
			-- one of its subkeys is declared as an untyped `{}` in
			-- Template.buildInternalRoots -- with SCALARS underneath: a Timed deadline,
			-- a perk boolean, a gift-credit count, the purchase-id ring. So a profile
			-- holding one live cooldown reported a violation per stored key, and a
			-- purchase log blew past the 32-violation cap on its own.
			local compiled = compile({ Coins = Scribe.Int(0) })
			local found = Conform.Check(compiled, {
				Coins = 10,
				_Scribe = {
					Version = 1,
					Timed = { ["Booster"] = 1755000000 },
					Perks = { VIP = true },
					GiftCredits = { Coins = 500 },
					PendingGifts = {},
					ProcessedPurchaseIds = { { Id = "abc123", At = 1755000000 } },
					PurchaseLogs = {
						InGame = { { Category = "Shop", ItemId = "sword", Amount = 10 } },
						Robux = {},
					},
				},
			})
			expect(#found).to.equal(0)
		end)

		it("accepts scalars inside an untyped bag", function()
			-- The same dispatch bug from the other side. An undeclared key on an open
			-- record resolves to the `any` child ChildSchema synthesises, which carries
			-- no schema at all -- so there is nothing to check and nothing to recurse
			-- into. Treating it as a container reported every scalar in every untyped
			-- bag as corrupt.
			local compiled = compile({ Bag = {} })
			expect(#Conform.Check(compiled, { Bag = { Sword = 3, Shield = "blue", Worn = true } })).to.equal(0)
			expect(#Conform.Check(compiled, { Bag = { Nested = { Deep = 1 } } })).to.equal(0)
		end)
	end)

	describe("limits and safety", function()
		it("stops at the violation cap rather than collecting everything", function()
			-- A corrupt profile can have a million bad leaves. Collecting them all
			-- turns a diagnostic into an out-of-memory.
			local fields = {}
			local data = {}
			for i = 1, 200 do
				fields[`F{i}`] = Scribe.Int(0)
				data[`F{i}`] = "not a number"
			end
			local found = Conform.Check(compile(fields), data, { Limit = 5 })
			expect(#found).to.equal(5)
		end)

		it("survives a cyclic stored table", function()
			-- Stored data arrives from a datastore, not from the accessor tree, so
			-- the walk cannot assume the shape is sane.
			local compiled = compile({ Bag = {} }) -- an untyped bag
			local cyclic = {}
			cyclic.self = cyclic
			local ok = pcall(function()
				return Conform.Check(compiled, { Bag = cyclic })
			end)
			expect(ok).to.equal(true)
		end)

		it("reports a profile that is not a table at all", function()
			local compiled = compile({ Coins = Scribe.Int(0) })
			expect(kinds(Conform.Check(compiled, "corrupt" :: any))).to.equal("WrongType")
		end)
	end)

	describe("SchemaPolicy at load", function()
		-- The template every case here loads against, with one field the corrupt
		-- fixtures violate.
		local function harnessWith(policy, stored, devMode)
			local options: any = {}
			if policy then
				options.SchemaPolicy = policy
			end
			if devMode ~= nil then
				options.DevMode = devMode
			end
			local harness = TestCtx.make({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				Options = options,
			})
			harness.Fake.Persisted["Default/PLAYER_95001"] = stored
			return harness
		end

		-- Every case below watches OnAnomaly rather than only the load outcome. The
		-- outcome alone cannot tell the three policies apart: a gate forced always-on
		-- still resolves to Warn when no policy is configured, so it lets the player
		-- through exactly as "off" does. Whether the violation was REPORTED is the
		-- only thing that separates them, and it is what the signal shows.
		local function watchAnomalies(harness)
			local seen = {}
			harness.Data.OnAnomaly:Connect(function(event)
				table.insert(seen, event)
			end)
			return seen
		end

		it("is off on a live server unless asked for", function()
			-- Off on live: an existing game must load exactly as it did before, corrupt
			-- stored value and all -- and the check must not RUN at all.
			--
			-- DevMode is passed explicitly rather than leaned on. It defaults to
			-- RunService:IsStudio(), which this harness pins FALSE, so the default would
			-- give the right answer for the wrong reason -- and would keep giving it if
			-- the gate were later keyed on something else entirely.
			local harness = harnessWith(nil, { Coins = "not a number" }, false)
			local anomalies = watchAnomalies(harness)
			local _player, entry, accessor = harness.TryJoin(95001)
			expect(entry).never.to.equal(nil)
			expect(#anomalies).to.equal(0)
			-- ...and the violating value is still there, untouched and readable. The
			-- absence of a policy is not a quiet repair.
			expect(accessor.Coins.Get()).to.equal("not a number")
			harness.Cleanup()
		end)

		it("loads the player anyway under Warn", function()
			-- Warn is a diagnostic, not a gate. A game that turns this on to find out
			-- what is wrong must not start kicking players as a side effect.
			--
			-- This is also the positive control for the two assertions on SILENCE
			-- above and below: it proves the anomaly this spec watches for is one the
			-- SchemaPolicy gate really emits, so `#anomalies == 0` elsewhere means the
			-- check did not run rather than that the observable was never wired up.
			local harness = harnessWith("Warn", { Coins = "not a number" })
			local anomalies = watchAnomalies(harness)
			local _player, entry = harness.TryJoin(95001)
			expect(entry).never.to.equal(nil)
			expect(#anomalies).to.equal(1)
			expect(anomalies[1].Reason).to.equal("WrongType")
			expect(table.concat(anomalies[1].Path, ".")).to.equal("Coins")
			harness.Cleanup()
		end)

		it("defaults to Warn in DevMode, with no policy configured", function()
			-- The default that closes the gap for developers without touching live
			-- servers. Five violation kinds -- schema-relative WrongType, OutOfBounds,
			-- OverMaxLength, NotAMember, UnknownKey -- are caught by nothing else, so
			-- fully off meant Conform shipped in every bundle and ran in none.
			--
			-- DevMode and not live, because on an upgraded game the report is mostly
			-- noise: ordinary template edits (a retired enum member, a tightened bound,
			-- a removed element field) report, and UnknownKey reports once per stored
			-- ELEMENT, so one retired field on a 40-item inventory fills the whole
			-- 32-violation cap. In DevMode that lands in front of the person who just
			-- made the edit; on live it would overwrite the diagnostic ring.
			local harness = harnessWith(nil, { Coins = "not a number" }, true)
			local anomalies = watchAnomalies(harness)
			local _player, entry, accessor = harness.TryJoin(95001)
			-- Warn, so the player still loads and the value is still there: a default
			-- that could refuse a load would be a very different decision.
			expect(entry).never.to.equal(nil)
			expect(accessor.Coins.Get()).to.equal("not a number")
			expect(`n={#anomalies} reason={anomalies[1] and anomalies[1].Reason}`).to.equal("n=1 reason=WrongType")
			harness.Cleanup()
		end)

		it("lets an explicit Reject win over the DevMode default", function()
			-- The default fills in only where nothing was configured. A game that asked
			-- for Reject gets Reject in DevMode too, rather than being quietly softened
			-- to Warn by the very gate that exists to avoid surprising people.
			local harness = harnessWith("Reject", { Coins = "not a number" }, true)
			local _player, entry = harness.TryJoin(95001)
			expect(entry).to.equal(nil)
			harness.Cleanup()
		end)

		it("refuses the load under Reject, leaving the stored bytes untouched", function()
			-- Fail-closed: the profile that failed the check must not be overwritten
			-- by the load that rejected it.
			--
			-- The teardown is pinned through the SessionEnded signal and the CANONICAL
			-- reason, not through `entry == nil` alone. EndSession and the Kick above
			-- the teardown already make the entry unreachable, so an assertion on
			-- absence passes with the teardown deleted: the load just hangs, WaitForData
			-- eventually answers "timeout", and the spec reads that as a rejection.
			local harness = harnessWith("Reject", { Coins = "not a number" })
			local anomalies = watchAnomalies(harness)
			local ended = {}
			harness.Data.SessionEnded:Connect(function(_player, reason)
				table.insert(ended, reason)
			end)

			local _player, entry, accessor, reason = harness.TryJoin(95001, 1)
			expect(entry).to.equal(nil)
			expect(accessor).to.equal(nil)
			expect(reason).to.equal(Scribe.Reason.LoadFailed)
			expect(#ended).to.equal(1)
			expect(ended[1]).to.equal(Scribe.Reason.LoadFailed)
			expect(#anomalies).to.equal(1)
			expect(harness.Fake.Persisted["Default/PLAYER_95001"].Coins).to.equal("not a number")
			harness.Cleanup()
		end)

		it("lets a healthy profile through under Reject", function()
			-- The other half: a gate that refuses everything is not a gate.
			local harness = harnessWith("Reject", { Coins = 42 })
			local _player, entry, accessor = harness.TryJoin(95001)
			expect(entry).never.to.equal(nil)
			expect(accessor).never.to.equal(nil)
			harness.Cleanup()
		end)

		it("rejects a stored Big that is outside its declared bounds", function()
			-- A deliberate behaviour change, made at the repo owner's direction: a
			-- profile whose stored big is out of bounds LOADED before this and is now
			-- refused under Reject. Nothing rewrites the value -- releaseWithoutWriting
			-- leaves the stored bytes alone -- so this is a gate on a profile an
			-- operator has to repair, exactly like every other Reject violation.
			--
			-- Reachable without corruption: the write path CLAMPS under the default
			-- BoundsPolicy, so an out-of-bounds stored value comes from a raw write
			-- (UpdateOffline, OnPlayerInit, a migration) or from a bound that was
			-- tightened after the value was stored.
			local harness = TestCtx.make({
				Template = { Gold = Scribe.Big(0, { Min = 0, Max = 100 }) },
				Options = { SchemaPolicy = "Reject" },
			})
			harness.Fake.Persisted["Default/PLAYER_95003"] = { Gold = { 5, 50 } }
			local anomalies = watchAnomalies(harness)
			local _player, entry, accessor, reason = harness.TryJoin(95003, 1)

			expect(`entry={entry == nil} accessor={accessor == nil} reason={reason}`).to.equal(
				`entry=true accessor=true reason={Scribe.Reason.LoadFailed}`
			)
			expect(`anomalies={#anomalies} kind={anomalies[1] and anomalies[1].Reason}`).to.equal(
				"anomalies=1 kind=OutOfBounds"
			)
			-- ...and the stored value is untouched.
			expect(`stored={harness.Fake.Persisted["Default/PLAYER_95003"].Gold[2]}`).to.equal("stored=50")
			harness.Cleanup()
		end)

		it("does not kick a healthy profile that uses Flags or an untyped bag", function()
			-- The whole cost of the dispatch bug, at the layer a player feels it.
			-- Reject ends the session and kicks, and releaseWithoutWriting correctly
			-- leaves the stored bytes alone -- so the profile that failed is the same
			-- profile that gets loaded on the rejoin, and the kick repeats forever.
			local harness = TestCtx.make({
				Template = {
					Tutorial = Scribe.Flags({ "Movement", "Combat", "Trading" }),
					Bag = {},
				},
				Options = { SchemaPolicy = "Reject" },
			})
			harness.Fake.Persisted["Default/PLAYER_95002"] = {
				Tutorial = { "Movement", "Combat" },
				Bag = { Sword = 3, Shield = "blue" },
			}
			local anomalies = watchAnomalies(harness)
			local _player, entry, accessor = harness.TryJoin(95002)
			expect(entry).never.to.equal(nil)
			expect(accessor).never.to.equal(nil)
			expect(#anomalies).to.equal(0)
			expect(accessor.Tutorial.Has("Combat")).to.equal(true)
			harness.Cleanup()
		end)
	end)

	describe("container shape and caps", function()
		-- The gap these close. Conform checked every LEAF against its schema and
		-- nothing whatsoever about the CONTAINERS holding them: no MaxItems, no
		-- MaxKeys, no MaxKeyLength, no array contiguity -- and no check for the one
		-- stored shape that fails the whole profile save, a table mixing array
		-- indices and string keys. Every check below mirrors one Node.validateWrite
		-- already refuses at the write boundary; the point of having it here too is
		-- that stored data never went through that boundary. It arrives from a
		-- datastore, a migration, an UpdateOffline draft or an OnPlayerInit hook.

		local function detail(violations)
			return if violations[1] then violations[1].Detail else "<none>"
		end

		local function has(violations, needle)
			return string.find(detail(violations), needle, 1, true) ~= nil
		end

		describe("a table that mixes array indices and string keys", function()
			-- The shape worth having a detector for at all: JSON has no encoding for
			-- it, so the DataStore save of the ENTIRE profile fails -- not just this
			-- field -- and keeps failing on every save from here on.

			it("catches it inside a declared record", function()
				local compiled = compile({ Stats = { Wins = Scribe.Int(0) } })
				local found = Conform.Check(compiled, { Stats = { Wins = 3, [1] = "stray" } })
				expect(#found).to.equal(1)
				expect(found[1].Kind).to.equal("WrongType")
				expect(table.concat(found[1].Path, ".")).to.equal("Stats")
				expect(has(found, "mixes array indices and string keys")).to.equal(true)
			end)

			it("catches it inside a declared container", function()
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0)) })
				expect(kinds(Conform.Check(compiled, { Resources = { Wood = 1, [1] = 2 } }))).to.equal("WrongType")
			end)

			it("stops descending into a table that cannot be stored", function()
				-- One finding, not one per leaf underneath. Nothing below an
				-- unencodable table can be acted on until the table itself is repaired,
				-- and a per-leaf pile would crowd out the rest of the report at the
				-- 32-violation cap.
				local compiled = compile({ Stats = { Wins = Scribe.Int(0), Losses = Scribe.Int(0) } })
				local found = Conform.Check(compiled, { Stats = { Wins = "no", Losses = "no", [1] = "stray" } })
				expect(#found).to.equal(1)
			end)

			it("does not report a Scribe.MapOf('integer'), whose keys are all numbers", function()
				-- The false positive that would have mattered most: an integer map is
				-- numerically keyed BY DESIGN, JSON stores it perfectly well as an
				-- object, and Template.CoerceMapKeys has already turned its keys back
				-- into numbers by the time this walk runs.
				local compiled = compile({ Slots = Scribe.MapOf("integer", Scribe.Int(0)) })
				expect(#Conform.Check(compiled, { Slots = { [3] = 1, [9] = 2 } })).to.equal(0)
			end)
		end)

		describe("array shape", function()
			it("catches an array with a hole in it", function()
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.String("")) })
				local found = Conform.Check(compiled, { Inventory = { [1] = "a", [3] = "c" } })
				expect(kinds(found)).to.equal("WrongType")
				expect(has(found, "contiguously")).to.equal(true)
			end)

			it("catches an array whose entries came back as string keys", function()
				-- What a hole actually looks like after a DataStore round trip: JSON
				-- cannot express a sparse array, so the encoder writes an OBJECT and
				-- the decode hands back "1"/"3" rather than 1/3. Checking contiguity
				-- without also checking this would be theatre on real stored data.
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.String("")) })
				local found = Conform.Check(compiled, { Inventory = { ["1"] = "a", ["3"] = "c" } })
				expect(#found >= 1).to.equal(true)
				expect(found[1].Kind).to.equal("WrongType")
				expect(has(found, "string key")).to.equal(true)
			end)

			it("catches an array index that is not a positive integer", function()
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.String("")) })
				local found = Conform.Check(compiled, { Inventory = { [0] = "a" } })
				expect(kinds(found)).to.equal("WrongType")
				expect(has(found, "positive integer")).to.equal(true)
			end)

			it("accepts a contiguous array, and an empty one", function()
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.String("")) })
				expect(#Conform.Check(compiled, { Inventory = { "a", "b", "c" } })).to.equal(0)
				expect(#Conform.Check(compiled, { Inventory = {} })).to.equal(0)
			end)
		end)

		describe("declared caps", function()
			it("catches an array past MaxItems", function()
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 3 }) })
				local found = Conform.Check(compiled, { Inventory = { 1, 2, 3, 4 } })
				expect(kinds(found)).to.equal("OverMaxLength")
				expect(has(found, "MaxItems 3")).to.equal(true)
			end)

			it("accepts an array exactly AT MaxItems", function()
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 3 }) })
				expect(#Conform.Check(compiled, { Inventory = { 1, 2, 3 } })).to.equal(0)
			end)

			it("counts a set's membership rather than its stored length", function()
				-- Mirrors the write path exactly: a set is stored deduplicated, so its
				-- cap is on MEMBERSHIP. Counting raw entries would refuse a stored set
				-- whose membership fits, which is the same mistake Node.validateWrite
				-- already had to fix for Set({1,1,1}) against MaxItems 2.
				local compiled = compile({ Badges = Scribe.SetOf(Scribe.String(""), { MaxItems = 2 }) })
				expect(#Conform.Check(compiled, { Badges = { "a", "a", "a" } })).to.equal(0)
				expect(kinds(Conform.Check(compiled, { Badges = { "a", "b", "c" } }))).to.equal("OverMaxLength")
			end)

			it("catches a dictionary past MaxKeys", function()
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeys = 2 }) })
				local found = Conform.Check(compiled, { Resources = { Wood = 1, Stone = 2, Iron = 3 } })
				expect(kinds(found)).to.equal("OverMaxLength")
				expect(has(found, "MaxKeys 2")).to.equal(true)
			end)

			it("catches a dictionary key past MaxKeyLength", function()
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeyLength = 4 }) })
				local found = Conform.Check(compiled, { Resources = { Wood = 1, Obsidian = 2 } })
				expect(kinds(found)).to.equal("OverMaxLength")
				expect(has(found, "MaxKeyLength 4")).to.equal(true)
				expect(has(found, "Obsidian")).to.equal(true)
			end)

			it("accepts keys exactly AT MaxKeyLength", function()
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeyLength = 4 }) })
				expect(#Conform.Check(compiled, { Resources = { Wood = 1, Iron = 2 } })).to.equal(0)
			end)

			it("reports nothing when no cap is declared", function()
				local compiled = compile({
					Inventory = Scribe.ArrayOf(Scribe.Int(0)),
					Resources = Scribe.DictOf(Scribe.Int(0)),
				})
				local data = { Inventory = {}, Resources = {} }
				for i = 1, 40 do
					data.Inventory[i] = i
					data.Resources[`a-very-long-resource-key-{i}`] = i
				end
				expect(#Conform.Check(compiled, data)).to.equal(0)
			end)

			it("does not measure an untyped bag, which declares no container at all", function()
				-- An untyped `{}` declares no Container, so it has no caps and no
				-- key shape to measure. Measuring it would report every bag that
				-- happens to hold an array.
				--
				-- It is NOT exempt from the walk, though -- see the mixed-key spec
				-- below. A declared `Bag = {}` compiles to a table node with empty
				-- Children (Template.luau's `Kind = if type(value) == "table"`), not
				-- to a `ValueType "any"` leaf, so walkNode descends into it. Only its
				-- CHILDREN resolve to `any`, through AnyChild.
				local compiled = compile({ Bag = {} })
				expect(#Conform.Check(compiled, { Bag = { "a", "b", "c" } })).to.equal(0)
				expect(#Conform.Check(compiled, { Bag = { [1] = "a", [3] = "c" } })).to.equal(0)
			end)

			it("measures MaxKeyLength in BYTES, not characters", function()
				-- The cap the write path applies is `#key`, which is a byte count, so
				-- a three-CHARACTER CJK key is nine bytes and trips a cap of eight.
				-- Documented nowhere before this; a game whose players type non-ASCII
				-- keys hits it at a third of the length it looks like it allows.
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeyLength = 8 }) })
				local key = "\230\151\165\230\156\172\232\170\158" -- three CJK characters, nine bytes
				expect(utf8.len(key)).to.equal(3)
				expect(#key).to.equal(9)
				local found = Conform.Check(compiled, { Resources = { [key] = 1 } })
				expect(kinds(found)).to.equal("OverMaxLength")
				expect(has(found, "is 9 bytes, over MaxKeyLength 8")).to.equal(true)
			end)
		end)

		it("reports a mixed-key table inside a declared untyped bag", function()
			-- Backs the guide's claim that a declared `Bag = {}` is NOT exempt. A
			-- bag compiles to a table node with empty Children, so the mixed-key
			-- check -- the one finding that still ends a session -- runs on it. Both
			-- of TestCtx.defaultTemplate's `Inventory` and `Quests` are this form.
			local compiled = compile({ Bag = {} })
			local found = Conform.Check(compiled, { Bag = { Sword = 3, [1] = "stray" } })
			expect(#found).to.equal(1)
			expect(found[1].Kind).to.equal("WrongType")
			expect(has(found, "mixes array indices and string keys")).to.equal(true)
			expect(found[1].Advisory).to.equal(nil)
		end)

		describe("which findings are advisory", function()
			-- The policy split, at the unit layer. `Advisory` is a FLAG rather than a
			-- Kind on purpose: Kind says what is WRONG, not what policy applies, and
			-- "OverMaxLength" has to mean both "a string past MaxLength", which
			-- rejects, and "a container past MaxItems", which advises. One Kind
			-- cannot carry both answers; a flag alongside it can.

			local function policies(violations)
				local out = {}
				for _, v in violations do
					table.insert(out, `{v.Kind}:{if v.Advisory then "advisory" else "reject"}`)
				end
				table.sort(out)
				return table.concat(out, ",")
			end

			it("marks the mixed-key table as the one container finding that rejects", function()
				-- The only stored shape here that fails the DataStore save of the
				-- WHOLE profile. Kicking preserves data that would otherwise be lost
				-- silently at save time, so this one earns its reject.
				local compiled = compile({ Resources = Scribe.DictOf(Scribe.Int(0)) })
				expect(policies(Conform.Check(compiled, { Resources = { Wood = 1, [1] = 2 } }))).to.equal(
					"WrongType:reject"
				)
			end)

			it("marks all three array-shape findings advisory", function()
				-- A sparse array saves fine: JSON has no sparse array, so the encoder
				-- writes an object and the profile round-trips. Off declared shape,
				-- not unstorable.
				local compiled = compile({ Inventory = Scribe.ArrayOf(Scribe.String("")) })
				expect(policies(Conform.Check(compiled, { Inventory = { [1] = "a", [3] = "c" } }))).to.equal(
					"WrongType:advisory"
				)
				-- Twice: one finding per string key, as the round-trip spec above pins.
				expect(policies(Conform.Check(compiled, { Inventory = { ["1"] = "a", ["3"] = "c" } }))).to.equal(
					"WrongType:advisory,WrongType:advisory"
				)
				expect(policies(Conform.Check(compiled, { Inventory = { [0] = "a" } }))).to.equal("WrongType:advisory")
			end)

			it("marks all three container caps advisory", function()
				-- These fire on a state Scribe's own write path calls LEGAL.
				-- Node.luau's cap check is growth-only: an entry beyond the cap that
				-- already exists stays writable, because stranding it would turn a
				-- rolling deploy into lost writes. Rejecting here would contradict
				-- the library about the same byte of data.
				local items = compile({ Inventory = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 3 }) })
				expect(policies(Conform.Check(items, { Inventory = { 1, 2, 3, 4 } }))).to.equal(
					"OverMaxLength:advisory"
				)

				local keys = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeys = 2 }) })
				expect(policies(Conform.Check(keys, { Resources = { Wood = 1, Stone = 2, Iron = 3 } }))).to.equal(
					"OverMaxLength:advisory"
				)

				local keyLen = compile({ Resources = Scribe.DictOf(Scribe.Int(0), { MaxKeyLength = 4 }) })
				expect(policies(Conform.Check(keyLen, { Resources = { Obsidian = 2 } }))).to.equal(
					"OverMaxLength:advisory"
				)
			end)

			it("keeps a STRING past MaxLength rejecting, on the same Kind", function()
				-- Why the flag cannot be folded back into Kind. A string has no
				-- growth-only tolerance anywhere -- Node.validateWrite refuses or
				-- truncates it -- so the same "OverMaxLength" Kind must reject here
				-- and advise on a container cap.
				local compiled = compile({ Name = Scribe.String("", { MaxLength = 4 }) })
				expect(policies(Conform.Check(compiled, { Name = "far too long" }))).to.equal("OverMaxLength:reject")
			end)

			it("leaves every non-container finding rejecting", function()
				-- The advisory flag is scoped to the six container findings and
				-- nothing else: a wrong type, a bound, an enum member and an
				-- undeclared key on a closed record all still end the session.
				local compiled = compile({
					Coins = Scribe.Int(0, { Min = 0 }),
					Team = Scribe.Enum("Red", { "Red", "Blue" }),
				})
				expect(policies(Conform.Check(compiled, { Coins = "lots" }))).to.equal("WrongType:reject")
				expect(policies(Conform.Check(compiled, { Coins = -5 }))).to.equal("OutOfBounds:reject")
				expect(policies(Conform.Check(compiled, { Team = "Green" }))).to.equal("NotAMember:reject")
			end)
		end)

		describe("advisory findings under Reject, end to end", function()
			-- The policy split at the layer a player feels it, driven through the
			-- real load path -- Conform.Check cannot be asked about a SESSION
			-- OUTCOME, only about a list of findings.
			--
			-- Both directions are pinned, because a one-directional spec passes
			-- under either policy: an over-cap profile that loads proves nothing on
			-- its own unless a mixed-key profile in the same suite still kicks.

			local function anomaliesOf(harness)
				local seen = {}
				harness.Data.OnAnomaly:Connect(function(event)
					table.insert(seen, event)
				end)
				return seen
			end

			local function reasons(seen)
				local out = {}
				for _, event in seen do
					table.insert(out, event.Reason)
				end
				table.sort(out)
				return table.concat(out, ",")
			end

			it("loads an over-cap inventory under Reject, and still reports it", function()
				-- ADVISORY. The write path deliberately tolerates a container that is
				-- already over cap in storage -- a lowered MaxItems, or data written
				-- before the cap existed -- and refuses only growth past the stored
				-- size, so that a rolling deploy does not strand a profile the newer
				-- server wrote. Kicking on load for the same byte of data would have
				-- the library contradict itself.
				--
				-- Still reported: this is not a downgrade to silence. The violation
				-- is counted, logged and fired on OnAnomaly exactly as under "Warn".
				local harness = TestCtx.make({
					Template = { Inventory = Scribe.ArrayOf(Scribe.String(""), { MaxItems = 3 }) },
					Options = { SchemaPolicy = "Reject" },
				})
				harness.Fake.Persisted["Default/PLAYER_95004"] = { Inventory = { "a", "b", "c", "d" } }
				local anomalies = anomaliesOf(harness)
				local _player, entry, accessor, reason = harness.TryJoin(95004, 1)

				expect(`entry={entry == nil} accessor={accessor == nil} reason={reason}`).to.equal(
					"entry=false accessor=false reason=nil"
				)
				-- The player is served their data, over-cap entries and all.
				expect(accessor.Inventory.Count()).to.equal(4)
				expect(`anomalies={#anomalies} kind={anomalies[1] and anomalies[1].Reason}`).to.equal(
					"anomalies=1 kind=OverMaxLength"
				)
				expect(#harness.Fake.Persisted["Default/PLAYER_95004"].Inventory).to.equal(4)
				harness.Cleanup()
			end)

			it("survives the memo drift Node calls the one supported way to reach the live table", function()
				-- The scenario that forced this change, driven end to end rather than
				-- described. Node.luau's MaxKeys re-derivation calls "a caller mutating
				-- the live table handed back by a container Get()" the ONE SUPPORTED
				-- WAY its key-count memo drifts -- so what happens below is ordinary
				-- gameplay code reaching the data through a documented door, not
				-- corruption and not a raw datastore write.
				--
				-- Before this change the resulting hole was a rejecting violation, so
				-- the player was kicked on rejoin -- and kicked again on every rejoin
				-- after that, because releaseWithoutWriting correctly leaves the stored
				-- bytes for the next load to fail on again. The profile was unrecoverable
				-- without operator intervention.
				local harness = TestCtx.make({
					Template = { Inventory = Scribe.ArrayOf(Scribe.String("")) },
					Options = { SchemaPolicy = "Reject" },
				})
				local player, _entry, data = harness.Join(95008)
				data.Inventory.Insert("a")
				data.Inventory.Insert("b")
				local live = data.Inventory.Get()
				live[5] = "x" -- three entries, highest index 5: a hole
				harness.Data.Flush(player)
				harness.Leave(player)

				-- The hole really did reach storage; this is not a spec about a write
				-- that never happened.
				local stored = harness.Fake.Persisted["Default/PLAYER_95008"].Inventory
				expect(`{tostring(stored[1])}{tostring(stored[2])}{tostring(stored[5])}`).to.equal("abx")

				local anomalies = anomaliesOf(harness)
				local _p2, entry2, data2, reason2 = harness.TryJoin(95008, 1)
				expect(`entry={entry2 == nil} accessor={data2 == nil} reason={reason2}`).to.equal(
					"entry=false accessor=false reason=nil"
				)
				-- Reported, though: advisory is not silent.
				expect(`anomalies={#anomalies} kind={anomalies[1] and anomalies[1].Reason}`).to.equal(
					"anomalies=1 kind=WrongType"
				)
				harness.Cleanup()
			end)

			it("still kicks a mixed array/hash table under Reject", function()
				-- REJECTS, and is the only container shape that does. JSON has no
				-- encoding for a table with both array indices and string keys, so
				-- the DataStore save of the WHOLE profile fails -- not just this
				-- field, and not just once. Ending the session preserves data that
				-- would otherwise be lost silently at the next save.
				local harness = TestCtx.make({
					Template = { Resources = Scribe.DictOf(Scribe.Int(0)) },
					Options = { SchemaPolicy = "Reject" },
				})
				harness.Fake.Persisted["Default/PLAYER_95006"] = { Resources = { Wood = 1, [1] = 2 } }
				local anomalies = anomaliesOf(harness)
				local ended = {}
				harness.Data.SessionEnded:Connect(function(_player, why)
					table.insert(ended, why)
				end)
				local _player, entry, accessor, reason = harness.TryJoin(95006, 1)

				expect(`entry={entry == nil} accessor={accessor == nil} reason={reason}`).to.equal(
					`entry=true accessor=true reason={Scribe.Reason.LoadFailed}`
				)
				-- Pinned through SessionEnded and the canonical reason, not through
				-- `entry == nil` alone: the Kick already makes the entry unreachable,
				-- so absence alone also passes when the load merely hangs.
				expect(`ended={#ended} why={ended[1]}`).to.equal(`ended=1 why={Scribe.Reason.LoadFailed}`)
				expect(`anomalies={#anomalies} kind={anomalies[1] and anomalies[1].Reason}`).to.equal(
					"anomalies=1 kind=WrongType"
				)
				-- Fail-closed: the stored bytes are left for an operator to repair.
				expect(harness.Fake.Persisted["Default/PLAYER_95006"].Resources[1]).to.equal(2)
				harness.Cleanup()
			end)

			it("kicks when both kinds are present -- the reject wins", function()
				-- The mixed case is the one that decides whether the rule is "reject
				-- if ANY violation is non-advisory" or the weaker "reject only if
				-- ALL are". One unstorable table still ends the session no matter how
				-- many advisory findings sit beside it -- and the advisory ones are
				-- still reported on the way out, so the operator's log names every
				-- problem rather than only the fatal one.
				local harness = TestCtx.make({
					Template = {
						-- Field names unique to this spec, so the log assertion below can
						-- pick its own entries out of a ring shared with the whole suite
						-- (and which wraps long before this spec runs).
						AdvisoryItems = Scribe.ArrayOf(Scribe.String(""), { MaxItems = 3 }),
						AdvisoryBag = Scribe.DictOf(Scribe.Int(0)),
					},
					Options = { SchemaPolicy = "Reject" },
				})
				harness.Fake.Persisted["Default/PLAYER_95007"] = {
					AdvisoryItems = { "a", "b", "c", "d" },
					AdvisoryBag = { Wood = 1, [1] = 2 },
				}
				local anomalies = anomaliesOf(harness)
				local _player, entry, accessor, reason = harness.TryJoin(95007, 1)

				expect(`entry={entry == nil} accessor={accessor == nil} reason={reason}`).to.equal(
					`entry=true accessor=true reason={Scribe.Reason.LoadFailed}`
				)
				-- Sorted, because the root walk iterates Children in hash order.
				expect(`anomalies={#anomalies} kinds={reasons(anomalies)}`).to.equal(
					"anomalies=2 kinds=OverMaxLength,WrongType"
				)

				-- LEVEL, not just presence. An advisory finding stays at Warn even on
				-- the load that is rejecting: promoting every passenger to Error would
				-- tell an operator that four inventory entries cost the player their
				-- session, when the unstorable table is what did.
				local levels = {}
				for _, logEntry in Log.GetRecent({ Code = "PROFILE_SCHEMA_VIOLATION" }) do
					local context = logEntry.Context
					local path = context and context.Path
					if type(path) == "string" and string.sub(path, 1, 8) == "Advisory" then
						table.insert(levels, `{path}:{logEntry.Level}:{tostring(context.Advisory)}`)
					end
				end
				table.sort(levels)
				expect(table.concat(levels, ",")).to.equal("AdvisoryBag:Error:false,AdvisoryItems:Warn:true")
				harness.Cleanup()
			end)
		end)

		it("loads that same profile untouched with no policy set", function()
			-- The control for the case above: nothing about an over-cap stored
			-- container is refused today, and must keep not being refused where the
			-- policy is off.
			local harness = TestCtx.make({
				Template = { Inventory = Scribe.ArrayOf(Scribe.String(""), { MaxItems = 3 }) },
				Options = { DevMode = false },
			})
			harness.Fake.Persisted["Default/PLAYER_95005"] = { Inventory = { "a", "b", "c", "d" } }
			local _player, entry, accessor = harness.TryJoin(95005)
			expect(entry).never.to.equal(nil)
			expect(accessor.Inventory.Count()).to.equal(4)
			harness.Cleanup()
		end)
	end)
end
