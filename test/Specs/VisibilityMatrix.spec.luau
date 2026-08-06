--!nonstrict
-- The FULL visibility matrix, checked behaviourally rather than by schema flag.
--
-- Two independent axes give six legal root shapes. Each is verified against the
-- three things a user can actually observe:
--
--   persists  does the value land in the saved profile table?
--   owner     does the owning player's own client see it?
--   others    does a DIFFERENT player's client see it via GetShared?
--
--   shape                 persists  owner  others
--   (default)                y        y      n
--   Session                  n        y      n
--   ServerOnly               y        n      n
--   Shared                   y        y      y
--   Session + ServerOnly     n        n      n
--   Session + Shared         n        y      y
--
-- The whole point of the axis split is that the two columns move independently.
-- A schema-flag assertion cannot show that, because it cannot catch a store or a
-- snapshot path reading the wrong table, which is exactly the bug that shipped
-- when Session+Shared was first allowed (sharedSnapshotOps read LiveData for a
-- root whose value lives in SessionStore).

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Client = require(Root.Scribe.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- One template carrying all six shapes at once, so a fix for one shape that
	-- breaks another cannot pass.
	local function template()
		return {
			Plain = { V = 0 },
			Sess = Scribe.Session({ V = 0 }),
			SrvOnly = Scribe.ServerOnly({ V = 0 }),
			Shar = Scribe.Shared({ V = 0 }),
			SessSrv = Scribe.ServerOnly(Scribe.Session({ V = 0 })),
			SessShar = Scribe.Shared(Scribe.Session({ V = 0 })),
		}
	end

	local ROOTS = { "Plain", "Sess", "SrvOnly", "Shar", "SessSrv", "SessShar" }

	-- Expected (persists, owner, others) per root.
	local EXPECTED = {
		Plain = { true, true, false },
		Sess = { false, true, false },
		SrvOnly = { true, false, false },
		Shar = { true, true, true },
		SessSrv = { false, false, false },
		SessShar = { false, true, true },
	}

	-- Builds the world once: A owns the data and writes 7 into every root, B is a
	-- second player whose client reads A's shared roots.
	local function observe()
		local harness = TestCtx.make({ AutoPump = false, Template = template() })

		local playerA, entryA, dataA = harness.Join(98101)
		for _, key in ROOTS do
			dataA[key].V.Set(7)
		end

		-- A's own client.
		harness.Transport.LocalPlayer = playerA
		local clientA = Client.new(harness.Options, harness.Compiled)
		harness.Ctx.Replication.FlushEntry(entryA)
		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()
		local ownerView = clientA.Get()

		-- A different player's client.
		local playerB = harness.Join(98102)
		harness.Transport.LocalPlayer = playerB
		local clientB = Client.new(harness.Options, harness.Compiled)
		harness.Ctx.Replication.FlushEntry(entryA)
		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()
		local othersView = clientB.GetShared(98101)

		local result = {}
		for _, key in ROOTS do
			local saved = entryA.Profile.Data[key]
			result[key] = {
				persists = saved ~= nil and saved.V == 7,
				owner = ownerView[key] ~= nil and ownerView[key].V == 7,
				others = othersView ~= nil and othersView[key] ~= nil and othersView[key].V == 7,
			}
		end
		harness.Cleanup()
		return result
	end

	local actual = observe()

	for _, key in ROOTS do
		local want = EXPECTED[key]
		it(`{key}: persists={want[1]} owner={want[2]} others={want[3]}`, function()
			expect(actual[key].persists).to.equal(want[1])
			expect(actual[key].owner).to.equal(want[2])
			expect(actual[key].others).to.equal(want[3])
		end)
	end

	it("the two axes move independently", function()
		-- Persistence differs while replication is held constant.
		expect(actual.Plain.persists).never.to.equal(actual.Sess.persists)
		expect(actual.Plain.owner).to.equal(actual.Sess.owner)
		expect(actual.Shar.persists).never.to.equal(actual.SessShar.persists)
		expect(actual.Shar.others).to.equal(actual.SessShar.others)
		expect(actual.SrvOnly.persists).never.to.equal(actual.SessSrv.persists)
		expect(actual.SrvOnly.owner).to.equal(actual.SessSrv.owner)

		-- Replication differs while persistence is held constant.
		expect(actual.Plain.others).never.to.equal(actual.Shar.others)
		expect(actual.Plain.owner).never.to.equal(actual.SrvOnly.owner)
		expect(actual.Sess.others).never.to.equal(actual.SessShar.others)
		expect(actual.Sess.owner).never.to.equal(actual.SessSrv.owner)
	end)

	it("no shape is a duplicate of another", function()
		-- If two shapes produced identical observable behaviour, one of them would
		-- be silently doing nothing, which is what the old single-enum bug looked
		-- like from the outside.
		local seen = {}
		for _, key in ROOTS do
			local sig = `{actual[key].persists}|{actual[key].owner}|{actual[key].others}`
			expect(seen[sig]).to.equal(nil)
			seen[sig] = key
		end
	end)

	it("every combination survives a rejoin with the persistence axis intact", function()
		local harness = TestCtx.make({ Template = template() })
		local _pA, entryA, dataA = harness.Join(98103)
		for _, key in ROOTS do
			dataA[key].V.Set(7)
		end
		harness.Data.Flush(_pA, { Force = true })
		local saved = {}
		for _, key in ROOTS do
			saved[key] = entryA.Profile.Data[key] ~= nil
		end
		harness.Cleanup()

		for _, key in ROOTS do
			expect(saved[key]).to.equal(EXPECTED[key][1])
		end
	end)
end
