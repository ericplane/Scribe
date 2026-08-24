--!nonstrict
-- What the ROOT accessor's whole-data reads hand back. The store is not the
-- answer: it carries Scribe's library-owned roots, which the declared type has
-- never had, and it is only one of the two stores, so Session roots went missing
-- on the server. Get, Clone, Observe, and Changed all build from the declared
-- roots instead, and Get's result is frozen so a stray write raises.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- A template covering all three visibilities, so a snapshot that reads the
	-- wrong store drops a key we assert on.
	local function makeHarness()
		return TestCtx.make({
			Template = {
				Coins = 0,
				Settings = { Music = true },
				Runtime = Scribe.Session({ InCombat = false }),
				Secret = Scribe.ServerOnly({ Flagged = false }),
			},
		})
	end

	local function keySet(t)
		local out = {}
		for key in t do
			out[key] = true
		end
		return out
	end

	it("root Get() omits Scribe's library-owned roots", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(94001)
		local whole = data.Get()

		expect(whole._Scribe).to.equal(nil)
		expect(whole._ScribeSession).to.equal(nil)
		-- Exactly the declared roots, nothing else. A bare nil check would still
		-- pass if some future reserved root started riding along.
		local keys = keySet(whole)
		expect(keys.Coins).to.equal(true)
		expect(keys.Settings).to.equal(true)
		expect(keys.Runtime).to.equal(true)
		expect(keys.Secret).to.equal(true)
		local count = 0
		for _ in whole do
			count += 1
		end
		expect(count).to.equal(4)

		harness.Cleanup()
	end)

	it("root Get() includes Session roots, which the store alone does not hold", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(94002)
		data.Runtime.InCombat.Set(true)

		-- Session roots live in Stores.Session; reading Stores.Persist directly
		-- (what an empty-path readValue does) dropped them, so this was a nil index
		-- on a field the accessor type promises.
		expect(data.Get().Runtime).to.be.ok()
		expect(data.Get().Runtime.InCombat).to.equal(true)

		harness.Cleanup()
	end)

	it("root Get() is frozen, so a raw write raises instead of reaching the profile", function()
		local harness = makeHarness()
		local _player, entry, data = harness.Join(94003)
		local whole = data.Get()

		expect(table.isfrozen(whole)).to.equal(true)
		expect(function()
			whole.Coins = 999
		end).to.throw()
		expect(entry.LiveData.Coins).to.equal(0)

		harness.Cleanup()
	end)

	it("the root freeze does not depend on whether the template declares a datatype", function()
		-- The bug this pins: unpackRead returned the live store by reference only
		-- when HasPacked was false, so `Get().Coins = 1` wrote through on a plain
		-- template and was silently discarded on one declaring a single Vector3.
		-- Same code, opposite outcome, decided by an unrelated field.
		local plain = TestCtx.make({ Template = { Coins = 0 } })
		local _p1, entry1, data1 = plain.Join(94004)
		expect(table.isfrozen(data1.Get())).to.equal(true)
		expect(function()
			data1.Get().Coins = 999
		end).to.throw()
		expect(entry1.LiveData.Coins).to.equal(0)
		plain.Cleanup()

		local datatype = TestCtx.make({ Template = { Coins = 0, Spawn = Scribe.Vector3(Vector3.zero) } })
		local _p2, entry2, data2 = datatype.Join(94005)
		expect(table.isfrozen(data2.Get())).to.equal(true)
		expect(function()
			data2.Get().Coins = 999
		end).to.throw()
		expect(entry2.LiveData.Coins).to.equal(0)
		-- The shell still unpacks datatypes on the way out.
		expect(typeof(data2.Get().Spawn)).to.equal("Vector3")
		datatype.Cleanup()
	end)

	it("root Clone() omits the library-owned roots and stays mutable", function()
		local harness = makeHarness()
		local _player, entry, data = harness.Join(94006)
		local copy = data.Clone()

		expect(copy._Scribe).to.equal(nil)
		expect(copy._ScribeSession).to.equal(nil)
		expect(copy.Runtime).to.be.ok()
		-- Editing a copy is the entire point of Clone, so unlike Get it must NOT
		-- be frozen, and the edit must not reach the store.
		expect(table.isfrozen(copy)).to.equal(false)
		copy.Coins = 42
		copy.Settings.Music = false
		expect(entry.LiveData.Coins).to.equal(0)
		expect(entry.LiveData.Settings.Music).to.equal(true)

		harness.Cleanup()
	end)

	it("a non-root Get() still returns the live table by reference and is not frozen", function()
		local harness = makeHarness()
		local _player, entry, data = harness.Join(94007)

		-- The documented container-by-reference contract is root-only in what it
		-- changed; nested reads are untouched.
		expect(data.Settings.Get()).to.equal(entry.LiveData.Settings)
		expect(table.isfrozen(data.Settings.Get())).to.equal(false)

		harness.Cleanup()
	end)

	it("root Observe and Changed hand back the same shape as Get, preserving new == old", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(94008)

		local observed
		data.Observe(function(value)
			observed = value
		end)
		-- Observe calls back immediately, so this is the initial read.
		expect(observed._Scribe).to.equal(nil)
		expect(observed.Runtime).to.be.ok()
		expect(table.isfrozen(observed)).to.equal(true)

		local changedNew, sameRef
		data.Changed(function(new, old)
			changedNew = new
			sameRef = new == old
		end)
		data.Coins.Set(7)

		expect(changedNew).to.be.ok()
		expect(changedNew._Scribe).to.equal(nil)
		expect(changedNew.Runtime).to.be.ok()
		expect(changedNew.Coins).to.equal(7)
		expect(table.isfrozen(changedNew)).to.equal(true)
		-- A root fire only ever comes from fireAncestors, which passes one
		-- reference for both, so a listener's `if new == old then return` guard
		-- must keep working.
		expect(sameRef).to.equal(true)
		-- Observe re-fired with the new value too.
		expect(observed.Coins).to.equal(7)

		harness.Cleanup()
	end)

	it("Scribe's internals stay reachable by indexing the root accessor", function()
		-- Guards the over-correction: hiding the reserved roots from whole-data
		-- reads must not hide them from the accessor, which is how the server
		-- layers (Monetization, Timed, Persistence) read and write them.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(94009)

		-- The layers write through the library's privileged handle. The PUBLIC
		-- accessor refuses that write (see ReservedRootGuard.spec) but still reads
		-- the same paths, which is the reachability this test is about.
		entry.Tree.Reserved.Perks.VIP.Set(true)
		expect(entry.LiveData._Scribe.Perks.VIP).to.equal(true)
		expect(data._Scribe.Perks.VIP.Get()).to.equal(true)
		expect(data._Scribe.Version.Get()).to.be.ok()

		harness.Cleanup()
	end)

	it("refuses to write the root back, which is what makes omitting _Scribe safe", function()
		-- Load-bearing for the omission above. Get() and Clone() no longer carry
		-- _Scribe, so if a whole-root write ever started working, the natural
		-- `Set(Get())` round trip would silently drop Scribe's internals: every
		-- perk and gift credit, the processed receipt ids, and the migration
		-- Version, whose loss makes runMigrations re-run every step against
		-- already-migrated data. The runtime refuses the write instead, and the
		-- accessor type omits Set and Update at the root for the same reason.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(94011)
		entry.Tree.Reserved.Perks.VIP.Set(true)
		data.Coins.Set(10)

		expect(function()
			data.Set(data.Get())
		end).to.throw()
		expect(function()
			data.Set(data.Clone())
		end).to.throw()
		-- The callable shorthand routes to Set, so it must refuse too.
		expect(function()
			data(data.Clone())
		end).to.throw()
		expect(function()
			data.Update(function(current)
				return current
			end)
		end).to.throw()

		-- Nothing was partially applied on the way to any of those errors.
		expect(entry.LiveData._Scribe).to.be.ok()
		expect(entry.LiveData._Scribe.Perks.VIP).to.equal(true)
		expect(entry.LiveData._Scribe.Version).to.be.ok()
		expect(entry.LiveData.Coins).to.equal(10)

		harness.Cleanup()
	end)

	itRunning("the client root Get() omits both library-owned roots", function()
		local harness = TestCtx.make({
			AutoPump = true,
			Template = { Coins = 0, Runtime = Scribe.Session({ InCombat = false }) },
		})
		local player = harness.Join(94010)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)

		local whole = client.Get()
		-- The client's two stores are one mirror table, so _ScribeSession rode
		-- along here as well as _Scribe.
		expect(whole._Scribe).to.equal(nil)
		expect(whole._ScribeSession).to.equal(nil)
		expect(whole.Coins).to.equal(0)
		expect(whole.Runtime).to.be.ok()
		expect(table.isfrozen(whole)).to.equal(true)

		harness.Cleanup()
	end)
end
