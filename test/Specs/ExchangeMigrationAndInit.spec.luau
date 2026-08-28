--!nonstrict
-- L4: an exchange survives the two things that rewrite a profile at load time.
--
-- A migration reshapes game data. `OnPlayerInit` and `Scribe.Dynamic` factories write
-- into the profile directly. Both run BEFORE the tree exists, so neither passes the
-- accessor refusal that protects the reserved root everywhere else, and both are handed
-- `profile.Data` itself.
--
-- That matters more here than anywhere else in Scribe. A receipt id or a perk surviving
-- a migration is bookkeeping; an in-flight exchange surviving one is the difference between
-- a player getting their item back and it ceasing to exist, because the matching hole in
-- their inventory has already been saved.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RESERVED = Template.RESERVED_ROOT
	local TID = "tid_migrate"
	local USER, PARTNER = 93701, 93702

	local V1 = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	--- The same template one migration later: a renamed currency.
	local V2 = {
		Gold = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	--- A profile that left with an exchange staked, on the V1 template.
	local function stakedOnV1(options)
		local harness = TestCtx.make({ Template = V1, Options = options })
		local player, entry = harness.Join(USER)
		local data = harness.Data.Get(player)
		data.Coins.Set(250)
		data.Inventory["relic"].Set({ Qty = 1 })
		harness.Data.Flush(player)

		local ctx = ctxFor(harness, player, entry)
		expect(select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "A", Partner = PARTNER }))).to.equal(true)
		expect(select(1, ExchangeLeg.Escrow(ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "relic" } }))).to.equal(
			true
		)
		harness.Data.Flush(player)
		harness.Leave(player)
		return harness
	end

	it("carries an in-flight exchange through a migration that reshapes game data", function()
		-- The migration renames Coins to Gold, which rewrites the game half of the
		-- profile wholesale. The reserved half is preserved by the migration path, and
		-- the load hook then resolves the exchange and returns the relic.
		local first = stakedOnV1()
		local second = TestCtx.make({
			Template = V2,
			Fake = first.Fake,
			Options = {
				-- Keyed by the version they migrate TO, and they mutate in place.
				Migrations = {
					[2] = function(data)
						data.Gold = data.Coins
						data.Coins = nil
					end,
				},
			},
		})

		local player = second.Join(USER)
		local data = second.Data.Get(player)
		local entry = second.Ctx.Persistence.EntryFor(player)

		expect(
			`gold={data.Gold.Get()} relic={tostring(data.Inventory["relic"].Get() ~= nil)} record={tostring(
				entry.Tree.Reserved.Exchange[TID].Get()
			)}`
		).to.equal("gold=250 relic=true record=nil")

		second.Cleanup()
		first.Cleanup()
	end)

	it("PARKS rather than loses a delivery whose destination the migration deleted", function()
		-- The harder shape. The item is owed, the container it was owed into is gone,
		-- and the honest outcome is that it waits where somebody can see it rather than
		-- being written into a path that no longer exists.
		local first = TestCtx.make({ Template = V1 })
		local player, entry = first.Join(USER)
		first.Data.Flush(player)
		entry.Tree.Reserved.ExchangeInbox[TID].Set({
			Id = TID,
			Verdict = "Commit",
			Legs = { { Path = { "Vault" }, Kind = "Key", Key = "relic", Value = { Qty = 1 } } },
		})
		first.Data.Flush(player)
		first.Leave(player)

		-- Loads against a template with no `Vault` at all.
		local second = TestCtx.make({ Template = V1, Fake = first.Fake })
		local rejoined = second.Join(USER)
		local parked = second.Ctx.Persistence.EntryFor(rejoined).Tree.Reserved.ExchangeInbox[TID].Get()

		expect(`parked={tostring(parked ~= nil)} legs={tostring(parked and #parked.Legs)}`).to.equal(
			"parked=true legs=1"
		)

		second.Cleanup()
		first.Cleanup()
	end)

	it("REVERTS an exchange ledger edited by OnPlayerInit, and says so", function()
		-- OnPlayerInit is handed profile.Data itself, before the tree exists, so the
		-- accessor refusal that guards the reserved root has nothing to refuse through.
		-- A starter kit that clears `_Scribe` to "start clean" would destroy an in-flight
		-- exchange silently, with the matching hole in the inventory already saved.
		local first = stakedOnV1()
		local tampered = false
		local second = TestCtx.make({
			Template = V1,
			Fake = first.Fake,
			Options = {
				OnPlayerInit = function(_player, data)
					if type(data[RESERVED]) == "table" then
						tampered = true
						data[RESERVED].Exchange = {}
						data[RESERVED].ExchangeInbox = {}
					end
				end,
			},
		})

		local reported = false
		local conn = Scribe.OnIssue:Connect(function(entry)
			if entry.Code == "EXCHANGE_INIT_TAMPER" then
				reported = true
			end
		end)
		local player = second.Join(USER)
		conn:Disconnect()
		local data = second.Data.Get(player)

		-- The hook really did fire and really did try, and it was REPORTED rather than
		-- quietly undone: a developer whose starter kit is eating exchanges needs telling.
		expect(`tried={tostring(tampered)} reported={tostring(reported)}`).to.equal("tried=true reported=true")
		-- ...and the relic came back anyway, because the edit was reverted before the
		-- tree was built and the load hook then resolved the exchange normally.
		expect(`relic={tostring(data.Inventory["relic"].Get() ~= nil)}`).to.equal("relic=true")

		second.Cleanup()
		first.Cleanup()
	end)

	it("leaves an untouched ledger alone, so the guard is not rewriting every load", function()
		-- The control. A guard that restored a snapshot unconditionally would pass the
		-- case above while quietly undoing legitimate work on every single load.
		local first = stakedOnV1()
		local second = TestCtx.make({
			Template = V1,
			Fake = first.Fake,
			Options = {
				OnPlayerInit = function(_player, data)
					data.Coins = 999 -- ordinary, allowed, nothing to do with exchanges
				end,
			},
		})

		-- And it must stay QUIET. Restoring the snapshot unconditionally leaves the data
		-- identical and cries wolf on every load, which is the version of this guard that
		-- survives a data-only assertion.
		local reported = false
		local conn = Scribe.OnIssue:Connect(function(entry)
			if entry.Code == "EXCHANGE_INIT_TAMPER" then
				reported = true
			end
		end)
		local player = second.Join(USER)
		conn:Disconnect()
		local data = second.Data.Get(player)
		expect(
			`coins={data.Coins.Get()} relic={tostring(data.Inventory["relic"].Get() ~= nil)} reported={tostring(
				reported
			)}`
		).to.equal("coins=999 relic=true reported=false")

		second.Cleanup()
		first.Cleanup()
	end)
end
