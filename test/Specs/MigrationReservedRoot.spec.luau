--!nonstrict
-- The reserved `_Scribe` root survives the GAME's migration chain.
--
-- Migrations are handed the whole profile table, reserved root included, and the
-- chain is entirely game-supplied. A step that rebuilds the profile from its own
-- whitelist of keys -- or simply does `data._Scribe = nil` -- used to take the
-- receipt dedupe ring and the gift escrow with it, because only `Version` was
-- restored afterwards. The consequence is the thing under test here, not the
-- mechanism: a receipt Roblox retries after such a migration must NOT grant a
-- second time, and a gift already paid for must still be deliverable.
--
-- The discard is also REPORTED, at Error. Silently reverting a developer's edit
-- is its own trap -- their migration appears to work and does nothing -- so the
-- control tests below are as load-bearing as the positive ones: a migration that
-- leaves the reserved root alone must stay silent.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local CODE = "MIGRATION_RESERVED_DISCARDED"

	local function makeHarness(migrations)
		return TestCtx.make({
			Options = {
				Migrations = migrations,
				Products = {
					Coins1000 = {
						Id = 111,
						Category = "Currency",
						Grant = function(data)
							data.Coins.Increment(1000)
						end,
					},
					GiftVIP = { Id = 222, Category = "Gamepass", Grants = "VIP" },
				},
			},
		})
	end

	-- A version-1 profile carrying real library state under the reserved root: a
	-- receipt that has already been granted once, a gift intent in escrow, paid
	-- gift credits, and an owned perk. Every one of them is money.
	local function seed(harness, userId)
		local now = os.time()
		harness.Fake.Persisted[`Default/PLAYER_{userId}`] = {
			Coins = 9,
			Nick = "before",
			_Scribe = {
				Version = 1,
				ProcessedPurchaseIds = { { Id = "pid-granted", At = now } },
				PendingGifts = {
					["222"] = { RecipientId = 4242, GiftId = "gift-1", Ts = now, Product = "GiftVIP" },
				},
				GiftCredits = { GiftVIP = 2 },
				Perks = { VIP = true },
			},
		}
	end

	local function receipt(userId, productId, purchaseId)
		return {
			PlayerId = userId,
			ProductId = productId,
			PurchaseId = purchaseId,
			CurrencySpent = 99,
			CurrencyType = Enum.CurrencyType.Robux,
			PlaceIdWherePurchased = 0,
		}
	end

	-- The dedupe ring stores `{ Id, At }` and still reads bare legacy strings.
	local function processedIds(list)
		local out = {}
		for _, item in list or {} do
			table.insert(out, if type(item) == "string" then item else item.Id)
		end
		return out
	end

	-- The log ring is process-wide and every spec shares it, so entries are matched
	-- by userId as well as by code. Each test below uses its own id.
	local function discardLogs(userId)
		local out = {}
		for _, entry in Scribe.GetRecentLogs({ Code = CODE, Limit = 100 }) do
			local player = if entry.Context then entry.Context.Player else nil
			if player ~= nil and player.UserId == userId then
				table.insert(out, entry)
			end
		end
		return out
	end

	-- A compact, readable description of everything the reserved root is supposed
	-- to still be carrying. Asserted as one string so a failure names every field
	-- that survived rather than only the first.
	local function reservedSummary(reserved)
		local intent = reserved.PendingGifts and reserved.PendingGifts["222"]
		return `ids={table.concat(processedIds(reserved.ProcessedPurchaseIds), ",")} `
			.. `gift={if intent then `{intent.GiftId}/{intent.RecipientId}` else "MISSING"} `
			.. `credits={tostring(reserved.GiftCredits and reserved.GiftCredits.GiftVIP)} `
			.. `perk={tostring(reserved.Perks and reserved.Perks.VIP)} `
			.. `version={tostring(reserved.Version)}`
	end

	local INTACT = "ids=pid-granted gift=gift-1/4242 credits=2 perk=true version=2"

	it("keeps the reserved root when a migration nils it, so a retried receipt cannot grant twice", function()
		local harness = makeHarness({
			[2] = function(data)
				-- The shape that bites: the step rebuilds what it cares about and
				-- drops the rest, taking library state with it.
				data.Coins = (data.Coins or 0) + 1
				data._Scribe = nil
			end,
		})
		seed(harness, 71001)

		local player, entry, data = harness.Join(71001)

		-- The game's own migration still applied.
		expect(data.Coins.Get()).to.equal(10)

		-- THE CONSEQUENCE FIRST. Roblox retries a receipt that was already granted
		-- before the migration. With the dedupe marker destroyed it is a brand-new
		-- receipt and the Grant callback runs again: 1000 coins nobody paid for.
		-- Asserted ahead of the structural check on purpose, so the money is what
		-- fails when the preserve is removed.
		local decision = harness.Data.HandleReceipt(receipt(71001, 111, "pid-granted"))
		expect(`coins={data.Coins.Get()} granted={decision == GRANTED}`).to.equal("coins=10 granted=true")

		-- ...and every reserved child is still there, with its real contents.
		expect(reservedSummary(entry.LiveData._Scribe)).to.equal(INTACT)

		-- And it survives the save, not just the load.
		harness.Data.Flush(player)
		local persisted = harness.Fake.Persisted["Default/PLAYER_71001"]
		expect(reservedSummary(persisted._Scribe)).to.equal(INTACT)

		expect(#discardLogs(71001) > 0).to.equal(true)
		harness.Cleanup()
	end)

	it("discards a PARTIAL rewrite of the reserved root too", function()
		local harness = makeHarness({
			[2] = function(data)
				-- Keeps the key, empties the ring, drops the escrow: the "helpful"
				-- migration that tidies up a table it does not own.
				data._Scribe = { Version = 1, ProcessedPurchaseIds = {} }
				data.Nick = "after"
			end,
		})
		seed(harness, 71002)

		local _player, entry, data = harness.Join(71002)

		expect(data.Nick.Get()).to.equal("after")
		expect(reservedSummary(entry.LiveData._Scribe)).to.equal(INTACT)

		local decision = harness.Data.HandleReceipt(receipt(71002, 111, "pid-granted"))
		expect(`coins={data.Coins.Get()} granted={decision == GRANTED}`).to.equal("coins=9 granted=true")

		expect(#discardLogs(71002) > 0).to.equal(true)
		harness.Cleanup()
	end)

	it("reports the discard at Error, with the reserved root named, and fires OnIssue", function()
		local issues = {}
		local connection = Scribe.OnIssue:Connect(function(entry)
			if entry.Code == CODE and entry.Context and entry.Context.Player.UserId == 71003 then
				table.insert(issues, entry)
			end
		end)

		local harness = makeHarness({
			[2] = function(data)
				data._Scribe.ProcessedPurchaseIds = {}
			end,
		})
		seed(harness, 71003)
		harness.Join(71003)

		local logs = discardLogs(71003)
		expect(#logs).to.equal(1)
		expect(logs[1].Level).to.equal("Error")
		expect(logs[1].Category).to.equal("Persistence")
		expect(string.find(logs[1].Message, "_Scribe", 1, true) ~= nil).to.equal(true)
		expect(logs[1].Context.Path).to.equal("_Scribe")

		task.wait() -- OnIssue handlers run on their own threads
		expect(#issues).to.equal(1)

		if connection.Disconnect then
			connection:Disconnect()
		end
		harness.Cleanup()
	end)

	it("CONTROL: a migration that leaves the reserved root alone migrates normally and stays silent", function()
		local harness = makeHarness({
			[2] = function(data)
				data.Gems = (data.Gems or 0) + 5
			end,
			[3] = function(data)
				data.Nick = "migrated"
			end,
		})
		seed(harness, 71004)

		local player, entry, data = harness.Join(71004)

		-- Both steps ran, in order, and the stamp is current.
		expect(`gems={data.Gems.Get()} nick={data.Nick.Get()} version={entry.LiveData._Scribe.Version}`).to.equal(
			"gems=5 nick=migrated version=3"
		)
		-- Reserved state untouched (version 3 here, so not the shared INTACT string).
		expect(reservedSummary(entry.LiveData._Scribe)).to.equal(
			"ids=pid-granted gift=gift-1/4242 credits=2 perk=true version=3"
		)
		-- Nothing was discarded, so nothing is reported. This is the half that keeps
		-- the log from becoming noise every developer learns to ignore.
		expect(#discardLogs(71004)).to.equal(0)

		harness.Data.Flush(player)
		expect(harness.Fake.Persisted["Default/PLAYER_71004"]._Scribe.Version).to.equal(3)
		harness.Cleanup()
	end)

	it("CONTROL: a migration that only moves Version does not trip the warning; the library stamp wins", function()
		local harness = makeHarness({
			[2] = function(data)
				-- Reading the reserved root is fine, and writing only Version is
				-- pointless rather than destructive: Scribe stamps it either way.
				data._Scribe.Version = 99
				data.Coins = (data.Coins or 0) + 1
			end,
		})
		seed(harness, 71005)

		local _player, entry, data = harness.Join(71005)

		expect(`coins={data.Coins.Get()} version={entry.LiveData._Scribe.Version}`).to.equal("coins=10 version=2")
		expect(reservedSummary(entry.LiveData._Scribe)).to.equal(INTACT)
		expect(#discardLogs(71005)).to.equal(0)
		harness.Cleanup()
	end)

	it("CONTROL: a legacy profile with no reserved root keeps the one its migration built", function()
		-- The fallback branch. There is nothing stored to preserve, so a root the
		-- migration created is kept exactly as it built it: nothing was destroyed,
		-- so nothing is discarded and nothing is reported.
		local harness = makeHarness({
			[2] = function(data)
				data.Coins = (data.Coins or 0) + 1
			end,
		})
		harness.Fake.Persisted["Default/PLAYER_71006"] = { Coins = 41 }

		local _player, entry, data = harness.Join(71006)

		expect(`coins={data.Coins.Get()} version={entry.LiveData._Scribe.Version}`).to.equal("coins=42 version=2")
		expect(#discardLogs(71006)).to.equal(0)
		harness.Cleanup()
	end)
end
