--!strict
-- Monetization, perks, and gifting. Lives inside the data service because
-- correct receipt handling needs exactly what Scribe owns: durable saving,
-- player lifecycle, idempotency. Receipts are fail-closed: PurchaseGranted is
-- returned only after the grant is durably committed; otherwise NotProcessedYet
-- so Roblox retries. Never eat Robux.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)

local Monetization = {}

-- Shared across bundles via the require cache: ProcessReceipt is a single
-- global callback, so a second receipt-owning bundle would silently steal it.
local receiptsBound = false

local PROCESSED_CAP = 200

function Monetization.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	local compiled: Template.Compiled = ctx.Compiled

	local logOptions = options.PurchaseLog or {}
	-- Floor at 1: the ring evictors loop `while count >= cap`, and a configured
	-- cap of 0 (or negative) would otherwise spin forever on an empty ring
	-- (removing from an empty array is a no-op, so the count never reaches -1).
	local robuxCap: number = math.max(1, tonumber(logOptions.RobuxCap) or 100)
	local inGameCap: number = math.max(1, tonumber(logOptions.InGameCap) or 100)
	local declaredCategories: { [string]: boolean }? = nil
	if logOptions.PurchaseLogCategories then
		declaredCategories = {}
		for _, category in logOptions.PurchaseLogCategories :: { string } do
			(declaredCategories :: { [string]: boolean })[category] = true
		end
	end

	local giftCooldown: number = options.GiftCooldown or 5
	local giftMaxPending: number = options.GiftMaxPending or 20
	local giftIntentTTL: number = options.GiftIntentTTL or 3600
	-- How long a same-product re-gift is blocked while a purchase could still be
	-- in flight (so a second gift can't overwrite a live intent and misdeliver the
	-- first purchase to the second recipient). Past this, a lingering intent is
	-- treated as an abandoned/cancelled prompt (a real purchase would have
	-- receipted by now) and may be overwritten -- so dismissing the purchase dialog
	-- does not block re-gifting for the whole intent TTL.
	local giftPromptWindow: number = math.min(120, giftIntentTTL)
	local allowDuplicateGifts: boolean = options.AllowDuplicateGifts == true
	local noGiftIntentPolicy: string = options.NoGiftIntentPolicy or "GrantOrCredit"

	-- Overridable for the test harness (fake players cannot be prompted).
	local promptProductPurchase: (player: Player, productId: number) -> () = options.PromptProductPurchase
		or function(player: Player, productId: number)
			MarketplaceService:PromptProductPurchase(player, productId)
		end

	-- Registry ----------------------------------------------------------------

	type Product = { Name: string, Id: number, Category: string?, Grant: ((data: any) -> ())?, Grants: string? }
	local productsByName: { [string]: Product } = {}
	local productsById: { [number]: Product } = {}
	for name, config in (options.Products or {}) :: { [string]: any } do
		-- A product Name is persisted as a GiftCredits object key and a PurchaseLog
		-- value; Category is a persisted PurchaseLog value. Invalid UTF-8 in either
		-- would fail the offline gift/receipt DataStore save (error 104), so reject
		-- it at registration -- the earliest, clearest point -- rather than at save.
		if not Util.isUtf8(name) then
			error("Scribe: a product name contains invalid UTF-8 bytes", 0)
		end
		if type(config.Id) ~= "number" then
			error(`Scribe: product "{name}" must declare a numeric Id`, 0)
		end
		if config.Category ~= nil and not Util.isUtf8(config.Category) then
			error(`Scribe: product "{name}" Category contains invalid UTF-8 bytes`, 0)
		end
		local product: Product = {
			Name = name,
			Id = config.Id,
			Category = config.Category,
			Grant = config.Grant,
			Grants = config.Grants,
		}
		productsByName[name] = product
		if productsById[config.Id] then
			error(`Scribe: duplicate product Id {config.Id}`, 0)
		end
		productsById[config.Id] = product
	end

	local passesByName: { [string]: { Id: number, Category: string? } } = {}
	local passNamesById: { [number]: string } = {}
	for name, config in (options.Passes or {}) :: { [string]: any } do
		-- Pass Name/Category feed the same persisted PurchaseLog/gift structures as
		-- products; reject invalid UTF-8 at registration for parity.
		if not Util.isUtf8(name) then
			error("Scribe: a pass name contains invalid UTF-8 bytes", 0)
		end
		if type(config.Id) ~= "number" then
			error(`Scribe: pass "{name}" must declare a numeric Id`, 0)
		end
		if config.Category ~= nil and not Util.isUtf8(config.Category) then
			error(`Scribe: pass "{name}" Category contains invalid UTF-8 bytes`, 0)
		end
		passesByName[name] = { Id = config.Id, Category = config.Category }
		passNamesById[config.Id] = name
	end

	local declaredPerks: { [string]: boolean }? = nil
	if options.Perks then
		declaredPerks = {}
		for _, perk in options.Perks :: { string } do
			(declaredPerks :: { [string]: boolean })[perk] = true
		end
	end

	-- Every string Owns() can legitimately answer true for: a registered pass, a
	-- declared perk, a product's granted perk, or the special "RobloxPlus". Owns
	-- silently returns false for anything else, which hides a typo'd key -- so warn
	-- (DevMode only, once per key) when Owns/OwnsAsync is called with an unknown one.
	local knownOwnsKeys: { [string]: boolean } = { RobloxPlus = true }
	for name in passesByName do
		knownOwnsKeys[name] = true
	end
	if declaredPerks then
		for perk in declaredPerks do
			knownOwnsKeys[perk] = true
		end
	end
	for _, product in productsByName do
		if product.Grants then
			knownOwnsKeys[product.Grants] = true
		end
	end
	local warnedOwnsKeys: { [string]: boolean } = {}
	local function checkOwnsKey(key: string)
		if ctx.DevMode and not knownOwnsKeys[key] and not warnedOwnsKeys[key] then
			warnedOwnsKeys[key] = true
			Log.Warn(
				"Monetization",
				"UNKNOWN_OWNS_KEY",
				`Owns("{key}") — "{key}" is not a registered pass, declared perk, or product grant (typo?); it will always return false`,
				{}
			)
		end
	end

	-- Reserved-root helpers -------------------------------------------------------------

	local function reservedAcc(entry: any): any
		return entry.Tree.Accessor[Template.RESERVED_ROOT]
	end

	local function reservedRaw(data: { [string]: any }): { [string]: any }
		local reserved = data[Template.RESERVED_ROOT]
		if type(reserved) ~= "table" then
			reserved = {}
			data[Template.RESERVED_ROOT] = reserved
		end
		for _, key in { "Perks", "ProcessedPurchaseIds", "PendingGifts", "GiftCredits", "PurchaseLogs" } do
			if type(reserved[key]) ~= "table" then
				reserved[key] = {}
			end
		end
		if type(reserved.PurchaseLogs.Robux) ~= "table" then
			reserved.PurchaseLogs.Robux = {}
		end
		if type(reserved.PurchaseLogs.InGame) ~= "table" then
			reserved.PurchaseLogs.InGame = {}
		end
		return reserved
	end

	local function isProcessedRaw(data: { [string]: any }, purchaseId: string): boolean
		return table.find(reservedRaw(data).ProcessedPurchaseIds, purchaseId) ~= nil
	end

	local function isProcessed(entry: any, purchaseId: string): boolean
		return entry.LiveData ~= nil and isProcessedRaw(entry.LiveData, purchaseId)
	end

	-- Ring evictions use `while`, not `if`: a stored ring larger than the CURRENT
	-- cap (the cap was lowered between deploys) must shrink back under it instead
	-- of staying frozen at its old size forever.
	local function markProcessedRaw(data: { [string]: any }, purchaseId: string)
		local list = reservedRaw(data).ProcessedPurchaseIds
		while #list >= PROCESSED_CAP and #list > 0 do
			table.remove(list, 1)
		end
		table.insert(list, purchaseId)
	end

	local function markProcessed(entry: any, purchaseId: string)
		local accessor = reservedAcc(entry).ProcessedPurchaseIds
		while accessor.Count() >= PROCESSED_CAP and accessor.Count() > 0 do
			accessor.Remove(1)
		end
		accessor.Insert(purchaseId)
	end

	local function checkCategory(category: string?)
		if ctx.DevMode and declaredCategories and category and not declaredCategories[category] then
			Log.Warn("Monetization", "UNDECLARED_CATEGORY", `purchase log category "{category}" is not declared`, {})
		end
	end

	local function appendRing(ringAccessor: any, cap: number, logEntry: { [string]: any })
		while ringAccessor.Count() >= cap and ringAccessor.Count() > 0 do
			ringAccessor.Remove(1)
		end
		ringAccessor.Insert(logEntry)
	end

	-- The Robux log is written only by the receipt/grant path in this module —
	-- game code cannot insert or forge entries.
	local function robuxLog(entry: any, logEntry: { [string]: any })
		checkCategory(logEntry.Category)
		appendRing(reservedAcc(entry).PurchaseLogs.Robux, robuxCap, logEntry)
	end

	local function robuxLogRaw(data: { [string]: any }, logEntry: { [string]: any })
		local ring = reservedRaw(data).PurchaseLogs.Robux
		while #ring >= robuxCap and #ring > 0 do
			table.remove(ring, 1)
		end
		table.insert(ring, logEntry)
	end

	-- Perks and unified ownership ---------------------------------------------------

	local function checkPerkName(key: string)
		if ctx.DevMode and declaredPerks and not declaredPerks[key] then
			Log.Warn("Monetization", "UNDECLARED_PERK", `perk "{key}" is not in the Perks registry (typo?)`, {})
		end
	end

	function self.GrantPerk(player: Player, key: string)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			error("Scribe: GrantPerk requires a Ready player (use Data.WaitForData)", 2)
		end
		checkPerkName(key)
		reservedAcc(entry).Perks[key].Set(true)
		Log.Info("Monetization", "PERK_GRANTED", `perk "{key}" granted`, { Player = player, Perk = key })
	end

	function self.RevokePerk(player: Player, key: string)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			error("Scribe: RevokePerk requires a Ready player", 2)
		end
		reservedAcc(entry).Perks[key].Set(nil)
		Log.Info("Monetization", "PERK_REVOKED", `perk "{key}" revoked`, { Player = player, Perk = key })
	end

	-- True if any of: perk flag set (purchased, gifted, or manually granted);
	-- real pass owned (cached); Roblox Plus. NON-YIELDING: reads the cache that
	-- refreshOwnership fills asynchronously, so right after join a genuinely-owned
	-- gamepass can still read false until that async refresh lands -- use OwnsAsync
	-- when you need an authoritative answer immediately (e.g. gating at join).
	function self.Owns(player: Player, key: string): boolean
		checkOwnsKey(key)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" or not entry.LiveData then
			return false
		end
		local reserved = reservedRaw(entry.LiveData)
		if reserved.Perks[key] == true then
			return true
		end
		local ownsCache = entry.SessionStore[Template.SESSION_ROOT]
		ownsCache = if type(ownsCache) == "table" then ownsCache.OwnsCache else nil
		if type(ownsCache) == "table" and ownsCache[key] == true then
			return true
		end
		if key == "RobloxPlus" then
			return player.HasRobloxSubscription
		end
		return false
	end

	local function setOwnsCache(entry: any, key: string, owned: boolean)
		if entry.Tree and not entry.Tree.Dead then
			entry.Tree.Accessor[Template.SESSION_ROOT].OwnsCache[key].Set(if owned then true else nil)
		end
	end

	-- Flip the replicated OwnsSynced flag and wake any OwnsAsync waiters once every
	-- gamepass check for this entry has resolved. Idempotent per entry.
	local function markOwnershipReady(entry: any)
		if entry.OwnershipReady then
			return
		end
		entry.OwnershipReady = true
		if entry.Tree and not entry.Tree.Dead then
			entry.Tree.Accessor[Template.SESSION_ROOT].OwnsSynced.Set(true)
		end
		local waiters = entry.OwnershipWaiters
		if waiters then
			entry.OwnershipWaiters = nil
			for _, wake in waiters do
				wake()
			end
		end
	end

	local function refreshOwnership(entry: any)
		local player = entry.Player
		entry.OwnershipReady = false
		setOwnsCache(entry, "RobloxPlus", player.HasRobloxSubscription)
		-- Count the outstanding gamepass checks; the last one to resolve marks the
		-- entry ownership-ready. Luau's cooperative scheduling makes `pending`
		-- updates race-free (no yield between the decrement and the check).
		local pending = 0
		for _ in passesByName do
			pending += 1
		end
		if pending == 0 then
			markOwnershipReady(entry)
			return
		end
		for name, pass in passesByName do
			task.spawn(function()
				local ok, owned = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(entry.UserId, pass.Id)
				end)
				if ok and not entry.TornDown then
					setOwnsCache(entry, name, owned == true)
				end
				pending -= 1
				if pending <= 0 and not entry.TornDown then
					markOwnershipReady(entry)
				end
			end)
		end
	end

	-- Like self.Owns, but YIELDS until the initial async gamepass ownership refresh
	-- has completed (the OwnershipWaiters / markOwnershipReady handshake), so it
	-- returns an authoritative answer even the instant a player joins. Perks/gifts
	-- resolve synchronously; only real gamepass ownership has the warm-up. Falls
	-- back to the current cached answer after `timeout` seconds (default 10). Public
	-- API doc-comment lives on Data.OwnsAsync (Server/init.luau) -- keep this a plain
	-- comment so the docgen does not emit a duplicate ".OwnsAsync" entry.
	function self.OwnsAsync(player: Player, key: string, timeout: number?): boolean
		checkOwnsKey(key)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" or not entry.LiveData then
			return false
		end
		if self.Owns(player, key) then
			return true
		end
		if not entry.OwnershipReady then
			local thread = coroutine.running()
			local settled = false
			local function wake()
				if not settled then
					settled = true
					task.spawn(thread)
				end
			end
			entry.OwnershipWaiters = entry.OwnershipWaiters or {}
			table.insert(entry.OwnershipWaiters, wake)
			task.delay(timeout or 10, wake)
			coroutine.yield()
		end
		return self.Owns(player, key)
	end

	-- Grant application ----------------------------------------------------------------------

	-- Applies a product's effects to a Ready entry. Returns false if a Grant
	-- callback threw (fail-closed: caller returns NotProcessedYet).
	local function applyProductGrant(entry: any, product: Product): boolean
		if product.Grant then
			local ok, err = xpcall(function()
				(product.Grant :: (any) -> ())(entry.Tree.Accessor)
			end, function(e)
				return debug.traceback(tostring(e), 2)
			end)
			if not ok then
				Log.Error("Monetization", "GRANT_FAIL", `product "{product.Name}" Grant threw: {err}`, {
					Player = entry.Player,
				})
				return false
			end
		end
		if product.Grants then
			checkPerkName(product.Grants)
			reservedAcc(entry).Perks[product.Grants].Set(true)
		end
		return true
	end

	-- Gift delivery to a Ready entry on this server. Returns (applied, durable):
	-- `applied` = the grant is in the recipient's memory; `durable` = it has
	-- been confirmed saved. Callers that report PurchaseGranted must require
	-- `durable`; the credit path uses `applied` to decide whether to refund.
	local function deliverGiftLocal(
		recipientEntry: any,
		product: Product,
		purchaseId: string,
		giftId: string,
		fromUserId: number
	): (boolean, boolean)
		if isProcessed(recipientEntry, purchaseId) then
			-- Already granted in memory (possibly on a prior attempt whose save
			-- failed); confirm it is durable before acknowledging.
			return true, ctx.Persistence.AwaitSave(recipientEntry, 10)
		end
		if not applyProductGrant(recipientEntry, product) then
			return false, false
		end
		robuxLog(recipientEntry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			From = { Type = "GiftReceived", FromUserId = fromUserId, GiftId = giftId },
			Ts = os.time(),
		})
		markProcessed(recipientEntry, purchaseId)
		Metrics.Add("GiftsDelivered")
		ctx.Signals.OnGiftReceived:Fire(recipientEntry.Player, {
			FromUserId = fromUserId,
			Product = product.Name,
			GiftId = giftId,
		})
		-- Await the RECIPIENT's save: the paid value lives in their profile, so
		-- success must not be reported until it is durable.
		return true, ctx.Persistence.AwaitSave(recipientEntry, 10)
	end

	-- Durable delivery to any recipient: same server -> apply directly; another
	-- server / offline -> ProfileStore MessageAsync (arrives on poll or next load).
	-- Returns (applied, durable) as deliverGiftLocal.
	local function deliverGift(
		product: Product,
		recipientUserId: number,
		purchaseId: string,
		giftId: string,
		fromUserId: number
	): (boolean, boolean)
		local recipientEntry = ctx.Persistence.EntryForUserId(recipientUserId)
		if recipientEntry and recipientEntry.State == "Ready" then
			return deliverGiftLocal(recipientEntry, product, purchaseId, giftId, fromUserId)
		end
		local ok, delivered = pcall(function()
			return ctx.Persistence.Store:MessageAsync(ctx.Persistence.KeyFor(recipientUserId), {
				ScribeGift = true,
				GiftId = giftId,
				PurchaseId = purchaseId,
				Product = product.Name,
				FromUserId = fromUserId,
			})
		end)
		if ok and delivered == true then
			-- MessageAsync durably commits the gift to the recipient's key.
			Health.ReportSuccess("GiftDelivery")
			Metrics.Add("GiftsDelivered")
			return true, true
		end
		Health.ReportFailure("GiftDelivery")
		Log.Warn("Gifting", "GIFT_DELIVERY_RETRY", "MessageAsync failed; receipt will retry", {
			RecipientId = recipientUserId,
			Product = product.Name,
		})
		return false, false
	end

	-- Cross-server message handler (registered by Persistence once Ready).
	function self.OnProfileMessage(entry: any, message: any, processed: () -> ())
		if type(message) ~= "table" or message.ScribeGift ~= true then
			return -- not ours; leave it for other handlers
		end
		local purchaseId = tostring(message.PurchaseId)
		if isProcessed(entry, purchaseId) then
			processed()
			return
		end
		local product = productsByName[tostring(message.Product)]
		if not product then
			Log.Error(
				"Gifting",
				"GIFT_UNKNOWN_PRODUCT",
				`gift message for unregistered product "{tostring(message.Product)}"`,
				{
					Player = entry.Player,
				}
			)
			return -- keep the message; a later deploy can process it
		end
		-- Gate on `durable` (2nd return), NOT `applied` (1st): this queued message is
		-- the only surviving durable copy of the paid gift, and processed() removes
		-- it for good. Ack-ing on a merely-in-memory grant would drop the message
		-- before the recipient's save committed, losing the gift on a crash.
		-- Re-delivery is dedupe-safe: the message carries a FIXED purchaseId that
		-- isProcessed catches, so an un-acked message re-applies harmlessly.
		local _, durable =
			deliverGiftLocal(entry, product, purchaseId, tostring(message.GiftId), tonumber(message.FromUserId) or 0)
		if durable then
			processed()
		end
	end

	-- Receipt handling -------------------------------------------------------------

	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local function recipientAlreadyOwns(recipientUserId: number, perkKey: string): boolean
		local recipientEntry = ctx.Persistence.EntryForUserId(recipientUserId)
		if recipientEntry and recipientEntry.State == "Ready" then
			if self.Owns(recipientEntry.Player, perkKey) then
				return true
			end
		else
			local data = ctx.Persistence.GetOffline(recipientUserId)
			if data then
				local reserved = data[Template.RESERVED_ROOT]
				if
					type(reserved) == "table"
					and type(reserved.Perks) == "table"
					and reserved.Perks[perkKey] == true
				then
					return true
				end
			end
		end
		local pass = passesByName[perkKey]
		if pass then
			local ok, owned = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(recipientUserId, pass.Id)
			end)
			if not ok then
				Metrics.Add("OwnershipCheckFailures")
				Log.Warn(
					"Monetization",
					"OWNERSHIP_CHECK_FAIL",
					tostring(owned),
					{ UserId = recipientUserId, PassId = pass.Id }
				)
			elseif owned == true then
				return true
			end
		end
		return false
	end

	-- Whether THIS purchase was already delivered to the recipient. Returns nil
	-- when the recipient's data can't be read (caller must retry, never credit).
	-- Distinguishes "recipient owns the perk from our own earlier delivery"
	-- (settle as GiftSent) from "recipient owns it independently" (credit).
	local function giftAlreadyDelivered(recipientUserId: number, purchaseId: string): boolean?
		local recipientEntry = ctx.Persistence.EntryForUserId(recipientUserId)
		if recipientEntry and recipientEntry.State == "Ready" then
			return isProcessed(recipientEntry, purchaseId)
		end
		local data = ctx.Persistence.GetOffline(recipientUserId)
		if data == nil then
			return nil
		end
		return isProcessedRaw(data, purchaseId)
	end

	local function intentFor(entry: any, product: Product): { [string]: any }?
		local reserved = reservedRaw(entry.LiveData)
		local intent = reserved.PendingGifts[tostring(product.Id)]
		if type(intent) ~= "table" then
			return nil
		end
		-- Intents are keyed by product ID; if a deploy retired the product and
		-- reused its Id for a different one within the TTL, the stored intent
		-- belongs to the OLD product -- honoring it would deliver the new product
		-- as a gift to the old intended recipient. Expire it instead.
		if intent.Product ~= nil and intent.Product ~= product.Name then
			reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
			Log.Warn("Gifting", "GIFT_INTENT_EXPIRED", "gift intent belonged to a retired product reusing this Id", {
				Player = entry.Player,
				Product = product.Name,
			})
			return nil
		end
		if os.time() - (tonumber(intent.Ts) or 0) > giftIntentTTL then
			-- Stale intent (abandoned prompt): expire it; the
			-- receipt follows the no-intent policy.
			reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
			Log.Warn("Gifting", "GIFT_INTENT_EXPIRED", "stale gift intent expired", {
				Player = entry.Player,
				Product = product.Name,
			})
			return nil
		end
		return intent
	end

	local function handleGiftReceipt(
		entry: any,
		product: Product,
		intent: { [string]: any },
		receiptInfo: any
	): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local recipientId = tonumber(intent.RecipientId) or 0
		local giftId = tostring(intent.GiftId)

		-- The recipient may have acquired the perk between the prompt and the
		-- receipt (bought it themselves, or received another gift). Delivering
		-- would be a no-op grant that burns the buyer's Robux — convert the
		-- purchase into a gift credit for the buyer instead, keeping the
		-- payment as re-aimable value. But ONLY if this purchase was not already
		-- delivered by us on a prior attempt whose buyer-commit failed — that
		-- case must settle as a normal GiftSent (via deliverGift's dedupe), or
		-- one payment yields both the delivered gift AND a buyer credit.
		if
			product.Grants
			and not product.Grant
			and not allowDuplicateGifts
			and recipientAlreadyOwns(recipientId, product.Grants)
			and giftAlreadyDelivered(recipientId, purchaseId) == false
		then
			local creditsAccessor = reservedAcc(entry).GiftCredits[product.Name]
			creditsAccessor.Set((tonumber(creditsAccessor.Get()) or 0) + 1)
			reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
			robuxLog(entry, {
				PurchaseId = purchaseId,
				Product = product.Name,
				Category = product.Category,
				PriceInRobux = receiptInfo.CurrencySpent,
				From = { Type = "GiftCredit", IntendedFor = recipientId },
				Ts = os.time(),
			})
			markProcessed(entry, purchaseId)
			Log.Warn(
				"Gifting",
				"GIFT_RECIPIENT_ALREADY_OWNS",
				"recipient acquired the perk before delivery; converted the purchase to a gift credit",
				{
					Player = entry.Player,
					Product = product.Name,
					RecipientId = recipientId,
				}
			)
			ctx.Signals.OnGiftCredit:Fire(entry.Player, product.Name)
			if ctx.Persistence.AwaitSave(entry, 10) then
				return GRANTED
			end
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED -- idempotency makes the retry safe
		end

		local _, durable = deliverGift(product, recipientId, purchaseId, giftId, entry.UserId)
		if not durable then
			-- Not confirmed durable (delivery failed, or grant applied but the
			-- recipient's save is unconfirmed); intent persists, the receipt
			-- retries, and the retry dedupes on the recipient. Nothing is lost.
			-- Refresh the intent timestamp so PromptGift's short overwrite window
			-- (giftPromptWindow) keeps refusing a second same-product gift while
			-- THIS paid purchase is still actively retrying -- an overwrite here
			-- would route this purchase's value to the second recipient and strand
			-- the first. deliverGift YIELDS, so re-check the intent still exists and
			-- is still OURS first: a blind Ts write after the intent was cleared
			-- would materialize a phantom {Ts} intent (no RecipientId/GiftId) that a
			-- later retry then delivers to userId 0.
			local liveIntent = reservedRaw(entry.LiveData).PendingGifts[tostring(product.Id)]
			if type(liveIntent) == "table" and tostring(liveIntent.GiftId) == giftId then
				reservedAcc(entry).PendingGifts[tostring(product.Id)].Ts.Set(os.time())
			end
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
		robuxLog(entry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			PriceInRobux = receiptInfo.CurrencySpent,
			From = { Type = "GiftSent", ToUserId = recipientId, GiftId = giftId },
			Ts = os.time(),
		})
		markProcessed(entry, purchaseId)
		Log.Info("Gifting", "GIFT_RECEIPT_GRANTED", "gift purchase delivered", {
			Player = entry.Player,
			Product = product.Name,
			PurchaseId = purchaseId,
			RecipientId = recipientId,
		})
		Metrics.Add("ReceiptsGranted")
		if ctx.Persistence.AwaitSave(entry, 10) then
			return GRANTED
		end
		Metrics.Add("ReceiptsRetried")
		return NOT_PROCESSED -- idempotency makes the retry safe
	end

	local function handleOnlineReceipt(entry: any, product: Product, receiptInfo: any): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)

		if isProcessed(entry, purchaseId) then
			Log.Info("Monetization", "RECEIPT_DUPLICATE", "duplicate receipt acknowledged", {
				Player = entry.Player,
				PurchaseId = purchaseId,
				ProductId = product.Id,
			})
			Metrics.Add("ReceiptsDuplicate")
			return GRANTED
		end

		local intent = intentFor(entry, product)
		if intent then
			return handleGiftReceipt(entry, product, intent, receiptInfo)
		end

		-- No matching intent: NoGiftIntentPolicy. A product with
		-- a consumable Grant still delivers real value, so the credit path only
		-- applies to pure perk products the buyer already owns.
		if product.Grants and not product.Grant and self.Owns(entry.Player, product.Grants) then
			-- An unused gift credit means a previous purchase already converted
			-- to re-aimable value; PromptGift would consume it at no charge, so
			-- this money could only stack a second credit. Decline instead —
			-- Roblox retries and refunds a never-processed purchase. If the
			-- credit is spent in the meantime, the retry processes normally.
			if (tonumber(reservedRaw(entry.LiveData).GiftCredits[product.Name]) or 0) > 0 then
				Log.Warn(
					"Gifting",
					"RECEIPT_DECLINED_PENDING_CREDIT",
					"buyer owns the perk and already holds an unused gift credit; declining the purchase",
					{
						Player = entry.Player,
						Product = product.Name,
					}
				)
				Metrics.Add("ReceiptsDeclined")
				return NOT_PROCESSED
			end
			if noGiftIntentPolicy == "Hold" then
				Log.Warn(
					"Gifting",
					"RECEIPT_HELD",
					"no gift intent and buyer owns the perk; holding (NoGiftIntentPolicy=Hold)",
					{
						Player = entry.Player,
						Product = product.Name,
					}
				)
				return NOT_PROCESSED
			end
			-- GrantOrCredit: a no-op grant would burn Robux — write a durable
			-- gift credit instead. (A NO-INTENT purchase never stacks onto a
			-- pending credit — declined above — but an aimed-gift conversion
			-- in handleGiftReceipt may, since that money is already taken.)
			local creditsAccessor = reservedAcc(entry).GiftCredits[product.Name]
			creditsAccessor.Set((creditsAccessor.Get() or 0) + 1)
			robuxLog(entry, {
				PurchaseId = purchaseId,
				Product = product.Name,
				Category = product.Category,
				PriceInRobux = receiptInfo.CurrencySpent,
				From = { Type = "GiftCredit" },
				Ts = os.time(),
			})
			markProcessed(entry, purchaseId)
			Log.Warn("Gifting", "GIFT_CREDIT_ISSUED", "buyer already owns the perk; issued an unassigned gift credit", {
				Player = entry.Player,
				Product = product.Name,
			})
			ctx.Signals.OnGiftCredit:Fire(entry.Player, product.Name)
			if ctx.Persistence.AwaitSave(entry, 10) then
				return GRANTED
			end
			return NOT_PROCESSED
		end

		if product.Grants and not product.Grant then
			-- A giftable perk product bought without intent: grant to the buyer
			-- (real value received).
			Log.Warn("Gifting", "GIFT_NO_INTENT", "perk product purchased with no gift intent; granting to buyer", {
				Player = entry.Player,
				Product = product.Name,
			})
		end

		if not applyProductGrant(entry, product) then
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end
		robuxLog(entry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			PriceInRobux = receiptInfo.CurrencySpent,
			From = { Type = "Purchase" },
			Ts = os.time(),
		})
		markProcessed(entry, purchaseId)
		Log.Info("Monetization", "RECEIPT_GRANTED", "purchase granted", {
			Player = entry.Player,
			PurchaseId = purchaseId,
			ProductId = product.Id,
		})
		Metrics.Add("ReceiptsGranted")

		-- Auto-flush after every grant: a crash between "player paid"
		-- and the next autosave must never eat a purchase.
		if ctx.Persistence.AwaitSave(entry, 10) then
			return GRANTED
		end
		Metrics.Add("ReceiptsRetried")
		Log.Warn("Monetization", "RECEIPT_RETRY", "grant applied but save unconfirmed; letting Roblox retry", {
			Player = entry.Player,
			PurchaseId = purchaseId,
		})
		return NOT_PROCESSED
	end

	-- Player left mid-receipt: grant via UpdateOffline if safely
	-- expressible (perk products), else NotProcessedYet.
	local function handleOfflineReceipt(
		userId: number,
		product: Product,
		receiptInfo: any
	): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local data = ctx.Persistence.GetOffline(userId)
		if not data then
			-- No profile, or the offline read failed (GetOffline logs the read
			-- error separately). Either way this receipt is undebuggable from
			-- logs without the PurchaseId, so record it.
			Metrics.Add("ReceiptsRetried")
			Log.Warn("Monetization", "RECEIPT_OFFLINE_RETRY", "offline receipt could not read the buyer's profile", {
				UserId = userId,
				ProductId = product.Id,
				PurchaseId = purchaseId,
			})
			return NOT_PROCESSED
		end
		if isProcessedRaw(data, purchaseId) then
			Metrics.Add("ReceiptsDuplicate")
			return GRANTED
		end

		local reserved = reservedRaw(data)
		local intent = reserved.PendingGifts[tostring(product.Id)]
		-- Mirror intentFor's reused-Id guard: an intent whose stored Product name
		-- differs belongs to a RETIRED product that reused this Id -- honoring it
		-- would gift the new product to the old intended recipient. Treat as
		-- no-intent (the stale record TTL-expires; the name check keeps catching it).
		if type(intent) == "table" and intent.Product ~= nil and intent.Product ~= product.Name then
			Log.Warn(
				"Gifting",
				"GIFT_INTENT_EXPIRED",
				"offline gift intent belonged to a retired product reusing this Id",
				{
					UserId = userId,
					Product = product.Name,
				}
			)
			intent = nil
		end
		if type(intent) == "table" and os.time() - (tonumber(intent.Ts) or 0) <= giftIntentTTL then
			local recipientId = tonumber(intent.RecipientId) or 0
			local giftId = tostring(intent.GiftId)

			-- Same recipient re-check as the online intent path: a no-op
			-- delivery burns the buyer's Robux, so convert to a gift credit —
			-- but only if we did not already deliver this exact purchase (else
			-- settle as GiftSent below, to avoid minting a duplicate credit).
			if
				product.Grants
				and not product.Grant
				and not allowDuplicateGifts
				and recipientAlreadyOwns(recipientId, product.Grants)
				and giftAlreadyDelivered(recipientId, purchaseId) == false
			then
				local ok = ctx.Persistence.UpdateOffline(userId, function(offlineData)
					local offlineReserved = reservedRaw(offlineData)
					offlineReserved.PendingGifts[tostring(product.Id)] = nil
					offlineReserved.GiftCredits[product.Name] = (
						tonumber(offlineReserved.GiftCredits[product.Name]) or 0
					) + 1
					robuxLogRaw(offlineData, {
						PurchaseId = purchaseId,
						Product = product.Name,
						Category = product.Category,
						PriceInRobux = receiptInfo.CurrencySpent,
						From = { Type = "GiftCredit", IntendedFor = recipientId },
						Ts = os.time(),
					})
					markProcessedRaw(offlineData, purchaseId)
				end)
				if ok then
					Log.Warn(
						"Gifting",
						"GIFT_RECIPIENT_ALREADY_OWNS",
						"recipient acquired the perk before delivery; converted the purchase to a gift credit",
						{
							UserId = userId,
							Product = product.Name,
							RecipientId = recipientId,
						}
					)
				end
				return if ok then GRANTED else NOT_PROCESSED
			end

			local _, durable = deliverGift(product, recipientId, purchaseId, giftId, userId)
			if not durable then
				return NOT_PROCESSED
			end
			local ok = ctx.Persistence.UpdateOffline(userId, function(offlineData)
				local offlineReserved = reservedRaw(offlineData)
				offlineReserved.PendingGifts[tostring(product.Id)] = nil
				robuxLogRaw(offlineData, {
					PurchaseId = purchaseId,
					Product = product.Name,
					Category = product.Category,
					PriceInRobux = receiptInfo.CurrencySpent,
					From = { Type = "GiftSent", ToUserId = recipientId, GiftId = giftId },
					Ts = os.time(),
				})
				markProcessedRaw(offlineData, purchaseId)
			end)
			return if ok then GRANTED else NOT_PROCESSED
		end

		if product.Grants and not product.Grant then
			local perkKey = product.Grants :: string
			-- Pass-aware ownership, matching the online path (perk flag OR game
			-- pass), so an offline buyer who owns the pass isn't re-granted.
			local ownsPerk = reserved.Perks[perkKey] == true or recipientAlreadyOwns(userId, perkKey)
			-- Honor NoGiftIntentPolicy = "Hold" (online parity): hold an
			-- owned-perk purchase for retry instead of auto-crediting.
			if ownsPerk and noGiftIntentPolicy == "Hold" then
				Metrics.Add("ReceiptsRetried")
				return NOT_PROCESSED
			end
			-- Same rule as the online path: owned perk + unused credit means
			-- this purchase could only stack another credit — decline it.
			if ownsPerk and (tonumber(reserved.GiftCredits[product.Name]) or 0) > 0 then
				Log.Warn(
					"Gifting",
					"RECEIPT_DECLINED_PENDING_CREDIT",
					"offline buyer owns the perk and already holds an unused gift credit; declining the purchase",
					{
						UserId = userId,
						Product = product.Name,
					}
				)
				Metrics.Add("ReceiptsDeclined")
				return NOT_PROCESSED
			end
			local ok = ctx.Persistence.UpdateOffline(userId, function(offlineData)
				local offlineReserved = reservedRaw(offlineData)
				-- ownsPerk is pass-aware and resolved before the transaction; the
				-- in-txn flag re-check guards against a concurrent change.
				if ownsPerk or offlineReserved.Perks[perkKey] == true then
					offlineReserved.GiftCredits[product.Name] = (
						tonumber(offlineReserved.GiftCredits[product.Name]) or 0
					) + 1
				else
					offlineReserved.Perks[perkKey] = true
				end
				robuxLogRaw(offlineData, {
					PurchaseId = purchaseId,
					Product = product.Name,
					Category = product.Category,
					PriceInRobux = receiptInfo.CurrencySpent,
					From = { Type = "Purchase" },
					Ts = os.time(),
				})
				markProcessedRaw(offlineData, purchaseId)
			end)
			if ok then
				Log.Info("Monetization", "RECEIPT_GRANTED", "offline perk grant committed", {
					UserId = userId,
					PurchaseId = purchaseId,
				})
				Metrics.Add("ReceiptsGranted")
				return GRANTED
			end
		end
		-- Consumable Grant functions need a live tree; Roblox retries,
		-- including on the player's next session.
		Metrics.Add("ReceiptsRetried")
		return NOT_PROCESSED
	end

	function self.HandleReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
		local userId = tonumber(receiptInfo.PlayerId) or 0
		local productId = tonumber(receiptInfo.ProductId) or 0
		local product = productsById[productId]
		Metrics.Add("ReceiptsReceived")

		if not product then
			Log.Error(
				"Monetization",
				"RECEIPT_UNKNOWN_PRODUCT",
				`receipt for unregistered product {productId} — register it in Products`,
				{
					UserId = userId,
					ProductId = productId,
				}
			)
			return NOT_PROCESSED
		end

		local entry = ctx.Persistence.EntryForUserId(userId)
		if entry and entry.State == "Ready" and isProcessed(entry, tostring(receiptInfo.PurchaseId)) then
			Metrics.Add("ReceiptsDuplicate")
			-- Acknowledge a duplicate only when the grant that set this marker is
			-- durable. Dirty alone is not enough: it resets when a save's payload is
			-- serialized, so Dirty == false with a save still IN FLIGHT (SaveT0 set)
			-- means the covering save has not confirmed and may yet fail -- a crash
			-- after GRANTED would then lose both the grant and the marker. Require a
			-- clean flag AND no in-flight save, else wait for a confirmed save.
			if (not entry.SaveInfo.Dirty and entry.SaveT0 == nil) or ctx.Persistence.AwaitSave(entry, 10) then
				return GRANTED
			end
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		if Health.GetStatus() == "Outage" then
			-- Outage policy matrix: never eat Robux.
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		if entry and entry.State == "Ready" then
			return handleOnlineReceipt(entry, product, receiptInfo)
		end
		return handleOfflineReceipt(userId, product, receiptInfo)
	end

	-- Gifting flow --------------------------------------------------------------------

	function self.PromptGift(buyer: Player, productName: string, recipientUserId: number): (boolean, string?)
		local product = productsByName[productName]
		if not product then
			return false, `unknown product "{productName}"`
		end
		local entry = ctx.Persistence.EntryFor(buyer)
		if not entry or entry.State ~= "Ready" then
			return false, "buyer data not loaded"
		end
		if type(recipientUserId) ~= "number" or recipientUserId <= 0 or recipientUserId % 1 ~= 0 then
			return false, "invalid recipient"
		end
		if recipientUserId == entry.UserId then
			return false, "cannot gift yourself"
		end

		-- Anti-abuse: per-sender cooldown + max pending gifts.
		local now = os.clock()
		if now - entry.GiftLastAt < giftCooldown then
			return false, "gift cooldown"
		end
		if Util.count(reservedRaw(entry.LiveData).PendingGifts) >= giftMaxPending then
			return false, "too many pending gifts"
		end
		if Health.GetStatus() == "Outage" then
			-- Cannot durably record intent -> never take money.
			return false, "data services are experiencing issues; try again later"
		end

		-- Step 1: duplicate guard.
		if product.Grants and not allowDuplicateGifts then
			if recipientAlreadyOwns(recipientUserId, product.Grants) then
				return false, "recipient already owns this"
			end
		end

		entry.GiftLastAt = now

		-- Step 2: credit consumption — no purchase prompt, no charge.
		local reserved = reservedRaw(entry.LiveData)
		local credits = tonumber(reserved.GiftCredits[productName]) or 0
		if credits > 0 then
			local giftId = Util.guid()
			local creditAccessor = reservedAcc(entry).GiftCredits[productName]
			-- Refunds re-read the live count instead of restoring the stale
			-- pre-read value: a receipt retry can issue a credit during the
			-- save/delivery yields below, and an absolute restore would erase it.
			local function refundCredit()
				creditAccessor.Set((tonumber(creditAccessor.Get()) or 0) + 1)
			end
			-- Reserve the credit DURABLY before delivering, so a crash can never
			-- restore a consumed credit after the gift has already gone out
			-- (mirrors the intent path's durability discipline).
			creditAccessor.Set(if credits - 1 > 0 then credits - 1 else nil)
			if not ctx.Persistence.AwaitSave(entry, 10) then
				refundCredit()
				return false, "could not reserve gift credit; try again later"
			end
			-- Gate on `applied` (1st return), NOT `durable`: a same-server recipient's
			-- grant is applied to their live data here and marked processed under this
			-- giftId, so it persists on their next save. Refunding on a merely
			-- non-durable save would let the buyer re-spend the credit under a FRESH
			-- giftId (a new `credit:{giftId}` purchaseId the recipient's dedupe cannot
			-- catch), double-granting a stackable Grant. The rare cost is a recipient
			-- crash before autosave losing the in-memory grant while the credit is
			-- gone; that is the accepted tradeoff (unlike the receipt path, whose
			-- retries reuse the same purchaseId and so are dedupe-safe).
			if not deliverGift(product, recipientUserId, `credit:{giftId}`, giftId, entry.UserId) then
				refundCredit()
				task.spawn(function()
					ctx.Persistence.AwaitSave(entry, 15)
				end)
				return false, "could not deliver gift; try again later"
			end
			Log.Info("Gifting", "GIFT_CREDIT_USED", "gift delivered from an unassigned credit", {
				Player = buyer,
				Product = productName,
				RecipientId = recipientUserId,
			})
			return true, nil
		end

		-- Step 3: durable intent BEFORE money moves.
		-- Refuse a second gift of the SAME product only while a purchase could still
		-- be in flight: a developer-product receipt carries only the product Id
		-- (never the recipient), so intents are keyed by product Id, and overwriting
		-- a live intent would deliver the first purchase's receipt to the second
		-- recipient. Past giftPromptWindow the intent is an abandoned/cancelled
		-- prompt (no receipt ever came) and is safe to overwrite below.
		local pendingIntent = intentFor(entry, product)
		if pendingIntent ~= nil and os.time() - (tonumber(pendingIntent.Ts) or 0) < giftPromptWindow then
			return false, "a gift of this item is already pending; try again shortly"
		end
		local giftId = Util.guid()
		local intentAccessor = reservedAcc(entry).PendingGifts[tostring(product.Id)]
		intentAccessor.Set({
			RecipientId = recipientUserId,
			GiftId = giftId,
			Ts = os.time(),
			Product = productName,
		})
		if not ctx.Persistence.AwaitSave(entry, 10) then
			intentAccessor.Set(nil)
			Log.Error("Gifting", "GIFT_INTENT_WRITE_FAIL", "could not durably record gift intent; refusing prompt", {
				Player = buyer,
				Product = productName,
			})
			return false, "could not record gift intent; try again later"
		end

		-- Step 4: prompt the purchase.
		local ok, err = pcall(function()
			promptProductPurchase(buyer, product.Id)
		end)
		if not ok then
			intentAccessor.Set(nil)
			return false, `purchase prompt failed: {err}`
		end
		Metrics.Add("GiftPrompts")
		return true, nil
	end

	function self.GetGiftCredits(player: Player): { [string]: number }
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return {}
		end
		return Util.deepClone(reservedRaw(entry.LiveData).GiftCredits)
	end

	-- In-game purchases ------------------------------------------------------

	function self.RecordPurchase(player: Player, logEntry: { [string]: any })
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			error("Scribe: RecordPurchase requires a Ready player", 2)
		end
		checkCategory(logEntry.Category)
		local record = table.clone(logEntry)
		record.Ts = record.Ts or os.time()
		appendRing(reservedAcc(entry).PurchaseLogs.InGame, inGameCap, record)
	end

	function self.GetPurchases(player: Player, filter: { [string]: any }?): { { [string]: any } }
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return {}
		end
		local reserved = reservedRaw(entry.LiveData)
		local out = {}
		local function collect(kind: string, ring: { any })
			if filter and filter.Kind and filter.Kind ~= kind then
				return
			end
			for _, item in ring do
				if filter then
					if filter.Category and item.Category ~= filter.Category then
						continue
					end
					if filter.ItemId and item.ItemId ~= filter.ItemId then
						continue
					end
					if filter.Since and (tonumber(item.Ts) or 0) < filter.Since then
						continue
					end
				end
				local record = Util.deepClone(item)
				record.Kind = kind
				table.insert(out, record)
			end
		end
		collect("Robux", reserved.PurchaseLogs.Robux)
		collect("InGame", reserved.PurchaseLogs.InGame)
		table.sort(out, function(a, b)
			return (tonumber(a.Ts) or 0) > (tonumber(b.Ts) or 0)
		end)
		if filter and filter.Limit then
			for i = #out, (filter.Limit :: number) + 1, -1 do
				out[i] = nil
			end
		end
		return out
	end

	-- Atomic soft-currency purchase: check funds, debit, grant, log,
	-- emit analytics — inside a Transaction; a throwing Grant rolls everything
	-- back.
	function self.Purchase(player: Player, spec: { [string]: any }): (boolean, string?)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return false, "player data not loaded"
		end
		local cost = spec.Cost
		if type(cost) ~= "table" or type(cost.Path) ~= "string" or type(cost.Amount) ~= "number" then
			return false, "invalid Cost spec"
		end
		local amount: number = cost.Amount
		-- A non-positive amount would pass the funds check and CREDIT currency
		-- while still granting the item; reject it.
		if amount <= 0 or amount ~= amount then
			return false, "invalid Cost amount"
		end
		local costPath = Util.parsePath(cost.Path)
		local costAccessor = entry.Tree.Accessor
		for _, segment in costPath do
			costAccessor = costAccessor[segment]
		end
		local costSchema = Template.Resolve(compiled, costPath)
		-- A fractional amount on an int currency rounds the debit toward zero
		-- (or to no debit at all) while the grant still runs — reject it.
		if costSchema.ValueType == "int" and amount % 1 ~= 0 then
			return false, "invalid Cost amount"
		end
		local floor: number = costSchema.Min or 0

		local current = costAccessor.Get()
		if type(current) ~= "number" then
			return false, "invalid cost path"
		end
		if current - amount < floor then
			return false, "insufficient funds"
		end

		local ok, err = entry.Tree:RunTransaction(function()
			local balance = costAccessor.Get()
			if balance - amount < floor then
				error("insufficient funds")
			end
			costAccessor.Set(balance - amount)
			if spec.Grant then
				(spec.Grant :: (any) -> ())(entry.Tree.Accessor)
			end
			checkCategory(spec.Category)
			appendRing(reservedAcc(entry).PurchaseLogs.InGame, inGameCap, {
				Category = spec.Category,
				ItemId = spec.ItemId,
				Currency = tostring(costPath[#costPath]),
				Amount = amount,
				Ts = os.time(),
				Meta = spec.Meta,
			})
		end)
		if not ok then
			if err and string.find(err, "insufficient funds", 1, true) then
				return false, "insufficient funds"
			end
			return false, err
		end

		-- Analytics only after commit so a rollback emits no event.
		ctx.Analytics.Economy(player, costPath, -amount, costAccessor.Get(), {
			Source = spec.ItemId or spec.Category or "Purchase",
			Flow = "Sink",
			Item = spec.ItemId,
		})
		return true, nil
	end

	-- Lifecycle -----------------------------------------------------------------------------

	function self.OnLoad(entry: any)
		-- Expire stale gift intents.
		local reserved = reservedRaw(entry.LiveData)
		local now = os.time()
		for productIdStr, intent in reserved.PendingGifts do
			if type(intent) ~= "table" or now - (tonumber(intent.Ts) or 0) > giftIntentTTL then
				reservedAcc(entry).PendingGifts[productIdStr].Set(nil)
			end
		end
		-- Gift credits are durable paid value keyed by product NAME; a product
		-- renamed or removed from the config silently strands them (no read path can
		-- resolve them). Surface it so the operator adds a rename migration or
		-- restores the product entry -- never delete: the credit is player money.
		for creditName, count in reserved.GiftCredits do
			if productsByName[creditName] == nil and (tonumber(count) or 0) > 0 then
				Log.Warn(
					"Gifting",
					"GIFT_CREDIT_UNKNOWN_PRODUCT",
					`player holds {tostring(count)} gift credit(s) for "{tostring(creditName)}", which is not in Products; `
						.. "they are unspendable until the product returns or a migration renames the credit key",
					{ Player = entry.Player, Product = tostring(creditName) }
				)
			end
		end
		task.spawn(refreshOwnership, entry)
	end

	function self.OnUnload(entry: any)
		-- Wake any in-flight OwnsAsync waiters promptly instead of leaving them to
		-- their timeout; on resume they re-check self.Owns, which returns false for
		-- the now-departed entry.
		local waiters = entry.OwnershipWaiters
		if waiters then
			entry.OwnershipWaiters = nil
			for _, wake in waiters do
				wake()
			end
		end
	end

	function self.Start()
		-- Only take over ProcessReceipt when there are developer products to grant.
		-- A data-only or pass-only game keeps its own receipt handler untouched.
		if options.OwnReceipts ~= false and next(productsById) ~= nil then
			if receiptsBound then
				error(
					"Scribe: a Scribe bundle already owns MarketplaceService.ProcessReceipt. "
						.. "Set OwnReceipts = false on the secondary bundle and route its receipts "
						.. "manually via Data.HandleReceipt.",
					0
				)
			end
			receiptsBound = true
			MarketplaceService.ProcessReceipt = function(receiptInfo)
				return self.HandleReceipt(receiptInfo)
			end
			Log.Info(
				"Monetization",
				"RECEIPT_HANDLER_BOUND",
				"Scribe is now handling MarketplaceService.ProcessReceipt; set OwnReceipts = false to keep your own",
				{}
			)
		end

		MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player: Player, passId: number, purchased: boolean)
				if not purchased then
					return
				end
				local passName = passNamesById[passId]
				if not passName then
					return
				end
				local entry = ctx.Persistence.EntryFor(player)
				if entry and entry.State == "Ready" then
					setOwnsCache(entry, passName, true)
					robuxLog(entry, {
						PurchaseId = `pass:{passId}:{os.time()}`,
						Product = passName,
						Category = passesByName[passName].Category or "Gamepass",
						From = { Type = "GamePass" },
						Ts = os.time(),
					})
					task.spawn(function()
						ctx.Persistence.AwaitSave(entry, 15)
					end)
				end
			end
		)

		Players.PlayerMembershipChanged:Connect(function(player: Player)
			local entry = ctx.Persistence.EntryFor(player)
			if entry and entry.State == "Ready" then
				setOwnsCache(entry, "RobloxPlus", player.HasRobloxSubscription)
			end
		end)
	end

	return self
end

return Monetization
