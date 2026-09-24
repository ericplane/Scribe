--!strict
-- Monetization, perks, and gifting. Receipts are fail-closed: PurchaseGranted is
-- returned only after the grant is durably committed, otherwise NotProcessedYet so
-- Roblox retries. Never eat Robux.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Internal = script.Parent.Parent.Internal
local Util = require(Internal.Util)
local Node = require(Internal.Node)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Health = require(Internal.Health)
local Clock = require(Internal.Clock)
local Sched = require(Internal.Sched)
local Rng = require(Internal.Rng)
local Failure = require(Internal.Failure)
-- For MAX_IDEMPOTENCY_KEY_BYTES only. Wire's own requires are Internal leaves, so
-- this adds no module to the bundle and no cycle.
local Wire = require(Internal.Wire)

local Monetization = {}

-- Shared across bundles via the require cache: ProcessReceipt is a single
-- global callback, so a second receipt-owning bundle would silently steal it.
local receiptsBound = false

local PURCHASE_ID_TTL = 7 * 24 * 3600
local RECEIPT_HISTORY_TTL = 30 * 24 * 3600
local RECEIPT_HISTORY_BYTES = 1024 * 1024
local MAX_RECEIPT_HISTORY_BYTES = 2 * 1024 * 1024
local RECEIPT_PROFILE_BYTES = 3800000

-- Unresolved destinations keep their slots until settlement or cancellation.
local GIFT_AIM_CAP = 64
-- Caller-supplied idempotency keys live in the Timed store under this prefix, which
-- keeps shop claims separate from receipt history.
local PURCHASE_IDEM_PREFIX = "@pi|"
-- Runaway guard on how many claims can be live at once, not a working limit: an
-- eviction can let a retry apply a purchase twice (PURCHASE_CLAIM_EVICTED). A game that
-- outruns it should shorten PurchaseClaimTTL rather than raise this.
local PURCHASE_CLAIM_CAP = 1000

function Monetization.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options
	local compiled: Template.Compiled = ctx.Compiled

	local logOptions = options.PurchaseLog or {}
	-- Floor at 1: the ring evictors loop `while count >= cap`, so a configured cap of
	-- 0 would spin forever on an empty ring.
	local robuxCap: number = math.max(1, tonumber(logOptions.RobuxCap) or 100)
	local inGameCap: number = math.max(1, tonumber(logOptions.InGameCap) or 100)
	local declaredCategories: { [string]: boolean }? = nil
	if logOptions.PurchaseLogCategories then
		declaredCategories = {}
		for _, category in logOptions.PurchaseLogCategories :: { string } do
			(declaredCategories :: { [string]: boolean })[category] = true
		end
	end

	-- Which (userId, purchaseId) pairs are mid-grant on THIS server. An in-flight marker,
	-- never persisted; ProcessedPurchaseIds holds durable completion records.
	local receiptsInFlight: { [string]: true } = {}

	local giftCooldown: number = options.GiftCooldown or 5
	local giftMaxPending: number = options.GiftMaxPending or 20
	local giftIntentTTL: number = options.GiftIntentTTL or 3600
	local purchaseIdTTL: number = options.PurchaseIdTTL or PURCHASE_ID_TTL
	local receiptHistoryBytes = if options.MaxReceiptHistoryBytes ~= nil
		then options.MaxReceiptHistoryBytes
		else RECEIPT_HISTORY_BYTES
	if
		type(receiptHistoryBytes) ~= "number"
		or receiptHistoryBytes ~= receiptHistoryBytes
		or receiptHistoryBytes % 1 ~= 0
		or receiptHistoryBytes < 1
		or receiptHistoryBytes > MAX_RECEIPT_HISTORY_BYTES
	then
		error(`Scribe: MaxReceiptHistoryBytes must be an integer from 1 to {MAX_RECEIPT_HISTORY_BYTES}`, 0)
	end
	local receiptReservations: { [any]: { [string]: true } } = setmetatable({}, { __mode = "k" }) :: any
	-- Caller-supplied purchase claims keep their own retry window.
	local purchaseClaimTTL: number = options.PurchaseClaimTTL or purchaseIdTTL
	local purchaseClaimCap: number = math.max(1, tonumber(options.MaxPurchaseClaims) or PURCHASE_CLAIM_CAP)
	local giftAimCap: number = math.max(1, GIFT_AIM_CAP)
	local allowDuplicateGifts: boolean = options.AllowDuplicateGifts == true
	local noGiftIntentPolicy: string = options.NoGiftIntentPolicy or "GrantOrCredit"

	-- Overridable for the test harness (fake players cannot be prompted).
	local promptProductPurchase: (player: Player, productId: number) -> () = options.PromptProductPurchase
		or function(player: Player, productId: number)
			MarketplaceService:PromptProductPurchase(player, productId)
		end

	local promptGamePassPurchase: (player: Player, passId: number) -> () = options.PromptGamePassPurchase
		or function(player: Player, passId: number)
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end
	local promptStopped = false
	type PurchasePrompt = { Entry: any, Connection: any?, Closed: boolean, Cancelled: boolean?, Saving: boolean? }
	local purchasePrompts: { [Player]: PurchasePrompt } = {}

	local function clearPurchasePrompt(player: Player, pending: PurchasePrompt)
		pending.Closed = true
		if purchasePrompts[player] == pending then
			purchasePrompts[player] = nil
		end
		local connection = pending.Connection
		pending.Connection = nil
		if connection then
			pcall(function()
				connection:Disconnect()
			end)
		end
	end

	local function finishCancellation(player: Player)
		local pending = purchasePrompts[player]
		if not pending or not pending.Cancelled or pending.Saving then
			return
		end
		pending.Saving = true
		local ok, saved = pcall(ctx.Persistence.AwaitSave, pending.Entry, 10)
		pending.Saving = false
		if ok and saved then
			clearPurchasePrompt(player, pending)
		end
	end

	-- Same seam as the prompt above: patching MarketplaceService itself is illegal on a
	-- real service Instance, so no ownership spec could run in Studio without it.
	local userOwnsGamePass: (userId: number, passId: number) -> boolean = options.UserOwnsGamePassAsync
		or function(userId: number, passId: number): boolean
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end
	local getPolicyInfo: (player: Player) -> any = options.GetPolicyInfoAsync
		or function(player: Player): any
			return (game:GetService("PolicyService") :: any):GetPolicyInfoForPlayerAsync(player)
		end

	-- Registry ----------------------------------------------------------------

	type Product = {
		Name: string,
		Id: number,
		Category: string?,
		Grant: ((data: any) -> ())?,
		Grants: string?,
		PaidRandom: boolean,
		Retired: boolean,
	}
	local productsByName: { [string]: Product } = {}
	local retiredByName: { [string]: Product } = {}
	local productsById: { [number]: Product } = {}
	local function registerProduct(name: string, config: any, retired: boolean)
		-- Name and Category are persisted as table keys and log values, so invalid UTF-8
		-- would fail the DataStore save (error 104). Reject at registration, not at save.
		if not Util.isUtf8(name) then
			error("Scribe: a product name contains invalid UTF-8 bytes", 0)
		end
		if type(config.Id) ~= "number" then
			error(`Scribe: product "{name}" must declare a numeric Id`, 0)
		end
		-- Grants names a perk key persisted under Perks; checked here so a wrong type or
		-- bad UTF-8 does not wait until someone buys the product.
		if config.Grants ~= nil then
			if type(config.Grants) ~= "string" or config.Grants == "" then
				error(`Scribe: product "{name}" Grants must be a non-empty string naming a perk`, 0)
			end
			if not Util.isUtf8(config.Grants) then
				error(`Scribe: product "{name}" Grants contains invalid UTF-8 bytes`, 0)
			end
		end
		if config.Category ~= nil and not Util.isUtf8(config.Category) then
			error(`Scribe: product "{name}" Category contains invalid UTF-8 bytes`, 0)
		end
		if config.PaidRandom ~= nil and type(config.PaidRandom) ~= "boolean" then
			error(`Scribe: product "{name}" PaidRandom must be a boolean`, 0)
		end
		local product: Product = {
			Name = name,
			Id = config.Id,
			Category = config.Category,
			Grant = config.Grant,
			Grants = config.Grants,
			PaidRandom = config.PaidRandom == true,
			Retired = retired,
		}
		if productsByName[name] or retiredByName[name] then
			error(`Scribe: duplicate active/retired product name "{name}"`, 0)
		end
		(if retired then retiredByName else productsByName)[name] = product
		if productsById[config.Id] then
			error(`Scribe: duplicate product Id {config.Id}`, 0)
		end
		productsById[config.Id] = product
	end
	for name, config in (options.Products or {}) :: { [string]: any } do
		registerProduct(name, config, false)
	end
	for name, config in (options.RetiredProducts or {}) :: { [string]: any } do
		registerProduct(name, config, true)
	end

	local passesByName: { [string]: { Id: number, Category: string? } } = {}
	local passNamesById: { [number]: string } = {}
	for name, config in (options.Passes or {}) :: { [string]: any } do
		-- Pass Name/Category feed the same persisted structures as products.
		if not Util.isUtf8(name) then
			error("Scribe: a pass name contains invalid UTF-8 bytes", 0)
		end
		if type(config.Id) ~= "number" then
			error(`Scribe: pass "{name}" must declare a numeric Id`, 0)
		end
		if config.Category ~= nil and not Util.isUtf8(config.Category) then
			error(`Scribe: pass "{name}" Category contains invalid UTF-8 bytes`, 0)
		end
		if config.PaidRandom ~= nil then
			error(
				`Scribe: pass "{name}" cannot be PaidRandom; a pass grants a fixed perk, so only a product can be a paid random item`,
				0
			)
		end
		-- One name, one thing. PromptPurchase resolves a name against both registries, so a
		-- name in both would leave resolution order deciding what the player is charged for.
		if productsByName[name] or retiredByName[name] then
			error(
				`Scribe: "{name}" is declared as both a product and a pass; one name cannot mean two `
					.. "purchasable things, because a prompt resolves by name",
				0
			)
		end
		passesByName[name] = { Id = config.Id, Category = config.Category }
		-- Only this reverse map can collide, and PromptGamePassPurchaseFinished is its one
		-- reader: the sole place an engine-supplied Id must become a name again.
		if passNamesById[config.Id] then
			error(
				`Scribe: duplicate pass Id {config.Id}; two pass names cannot share one gamepass Id, because a `
					.. "purchase reports only the Id and Scribe could credit just one of them",
				0
			)
		end
		passNamesById[config.Id] = name
	end

	local anyPaidRandom = false
	for _, product in productsById do
		anyPaidRandom = anyPaidRandom or product.PaidRandom
	end

	local declaredPerks: { [string]: boolean }? = nil
	if options.Perks then
		declaredPerks = {}
		for _, perk in options.Perks :: { string } do
			(declaredPerks :: { [string]: boolean })[perk] = true
		end
	end

	-- Every string Owns() can legitimately answer true for. Owns silently returns false
	-- for anything else, which hides a typo, so warn once per unknown key in DevMode.
	local knownOwnsKeys: { [string]: boolean } = { RobloxPlus = true }
	for name in passesByName do
		knownOwnsKeys[name] = true
	end
	if declaredPerks then
		for perk in declaredPerks do
			knownOwnsKeys[perk] = true
		end
	end
	for _, product in productsById do
		if product.Grants then
			knownOwnsKeys[product.Grants] = true
			-- Otherwise a typo here only surfaces once a player buys the product: the perk
			-- lands under the wrong key and Owns keeps answering false. A declared PASS
			-- name is a legitimate target, not a typo; see checkPerkName.
			if
				ctx.DevMode
				and declaredPerks
				and not declaredPerks[product.Grants]
				and not passesByName[product.Grants]
			then
				Log.Warn(
					"Monetization",
					"UNDECLARED_PERK",
					`product "{product.Name}" grants perk "{product.Grants}", which is not in the Perks registry (typo?)`,
					{ Product = product.Name, Perk = product.Grants }
				)
			end
		end
	end
	local warnedOwnsKeys: { [string]: boolean } = {}
	-- Every public ownership API calls this first. The type check is load-bearing: without
	-- it a nil key reaches `warnedOwnsKeys[key] = true` below, which raises, and only in
	-- Studio since DevMode gates that branch. Everywhere else it falls through and answers
	-- false, silently denying a player who has paid.
	local function checkOwnsKey(key: string, what: string)
		if type(key) ~= "string" then
			-- 4: checkOwnsKey -> self.<Api> -> Data.<Api> -> the game code that got it wrong.
			error(`Scribe: {what}: key must be a string, got {typeof(key)}`, 4)
		end
		if ctx.DevMode and not knownOwnsKeys[key] and not warnedOwnsKeys[key] then
			warnedOwnsKeys[key] = true
			Log.Warn(
				"Monetization",
				"UNKNOWN_OWNS_KEY",
				`Owns("{key}"): "{key}" is not a registered pass, declared perk, or product grant (typo?); it will always return false`,
				{}
			)
		end
	end

	-- Reserved-root helpers -------------------------------------------------------------

	-- The library's privileged handle on the reserved root. The public
	-- `Tree.Accessor[RESERVED_ROOT]` refuses every mutator; these ledgers are Scribe's.
	local function reservedAcc(entry: any): any
		return entry.Tree.Reserved
	end

	local function reservedRaw(data: { [string]: any }): { [string]: any }
		local reserved = data[Template.RESERVED_ROOT]
		if type(reserved) ~= "table" then
			reserved = {}
			data[Template.RESERVED_ROOT] = reserved
		end
		for _, key in
			{
				"Perks",
				"ProcessedPurchaseIds",
				"ReceiptReservations",
				"PendingGifts",
				"GiftAims",
				"GiftCredits",
				"PurchaseLogs",
			}
		do
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

	-- Accept both timestamped records and older bare IDs.
	local function processedId(item: any): string?
		if type(item) == "string" then
			return item
		end
		if type(item) == "table" and type(item.Id) == "string" then
			return item.Id
		end
		return nil
	end

	local function processedAt(item: any, now: number): number
		local at = if type(item) == "table" then item.At else nil
		return if type(at) == "number" and at == at and at >= 0 and at < math.huge then at else now
	end

	local function isProcessedRaw(data: { [string]: any }, purchaseId: string): boolean
		local now = Clock.Now()
		for _, item in reservedRaw(data).ProcessedPurchaseIds do
			if processedId(item) == purchaseId and now - processedAt(item, now) < RECEIPT_HISTORY_TTL then
				return true
			end
		end
		return false
	end

	local function isProcessed(entry: any, purchaseId: string): boolean
		return entry.LiveData ~= nil and isProcessedRaw(entry.LiveData, purchaseId)
	end

	-- Unknown-age IDs get a full window when migrated.
	local function compactProcessed(list: { any }, preserveUnknown: boolean?): ({ any }, boolean)
		local kept: { any } = {}
		local seen: { [string]: number } = {}
		local now = Clock.Now()
		local changed = false
		for _, item in list do
			local id = processedId(item)
			local at = processedAt(item, now)
			local unknown = type(item) ~= "table" or item.At ~= at
			if id == nil or now - at >= RECEIPT_HISTORY_TTL then
				changed = true
			elseif seen[id] then
				local index = seen[id]
				if at > processedAt(kept[index], now) then
					kept[index] = if preserveUnknown and unknown then id else { Id = id, At = at }
				end
				changed = true
			else
				local record = if preserveUnknown and unknown then id else { Id = id, At = at }
				table.insert(kept, record)
				seen[id] = #kept
				if unknown and (not preserveUnknown or type(item) ~= "string") then
					changed = true
				end
			end
		end
		return kept, changed
	end

	local function historyForProfile(data: { [string]: any }): ({ any }, boolean)
		local previous = reservedRaw(data).ProcessedPurchaseIds
		local kept, changed = compactProcessed(previous)
		if changed then
			-- Leave migration pending if timestamps would overflow the profile.
			local growth = Util.approxSize(kept) - Util.approxSize(previous)
			if growth > 0 and Util.approxSize(data) + growth > RECEIPT_PROFILE_BYTES then
				return compactProcessed(previous, true)
			end
		end
		return kept, changed
	end

	local function pruneProcessed(entry: any)
		local kept, changed = historyForProfile(entry.LiveData)
		if changed then
			reservedAcc(entry).ProcessedPurchaseIds.Set(kept)
		end
	end

	local function pruneProcessedRaw(data: { [string]: any })
		local reserved = reservedRaw(data)
		reserved.ProcessedPurchaseIds = historyForProfile(data)
	end

	local function canRecordReceipt(
		data: { [string]: any },
		purchaseId: string,
		entry: any?,
		userId: number?,
		route: any?
	): boolean
		if isProcessedRaw(data, purchaseId) then
			return true
		end
		local reserved = reservedRaw(data)
		local existing = reserved.ReceiptReservations[purchaseId]
		if existing and (route == nil or type(existing) == "table") then
			return true -- finishing a durable reservation releases its capacity
		end
		local ids = compactProcessed(reserved.ProcessedPurchaseIds)
		local completedBytes = Util.approxSize(ids)
		local seen = {}
		for _, record in ids do
			seen[record.Id] = true
		end
		local function include(id: string)
			if not seen[id] then
				seen[id] = true
				table.insert(ids, { Id = id, At = Clock.Now() })
			end
		end
		for id in reserved.ReceiptReservations do
			include(id)
		end
		for id in (entry and receiptReservations[entry]) or {} do
			include(id)
		end
		include(purchaseId)
		local bytes = Util.approxSize(ids)
		local profileBytes = Util.approxSize(data) - Util.approxSize(reserved.ProcessedPurchaseIds) + bytes
		if route then
			profileBytes += Util.approxSize({ [purchaseId] = route }) - Util.approxSize(
				if existing ~= nil then { [purchaseId] = existing } else {}
			)
		end
		if (existing or bytes <= receiptHistoryBytes) and profileBytes <= RECEIPT_PROFILE_BYTES then
			return true
		end
		Log.Error(
			"Monetization",
			"RECEIPT_HISTORY_FULL",
			"receipt history is full; grant deferred without dropping unexpired IDs",
			{
				Player = entry and entry.Player,
				UserId = if entry then entry.UserId else userId,
				PurchaseId = purchaseId,
				Bytes = bytes,
				Limit = receiptHistoryBytes,
				ProfileBytes = profileBytes,
				CompletedBytes = completedBytes,
			}
		)
		Metrics.Add("ReceiptHistoryRefusals")
		return false
	end

	local function reserveReceipt(entry: any, purchaseId: string): ((() -> ())?, boolean)
		local pending = receiptReservations[entry]
		if pending and pending[purchaseId] then
			return nil, false
		end
		if not canRecordReceipt(entry.LiveData, purchaseId, entry) then
			return nil, true
		end
		if not pending then
			pending = {}
			receiptReservations[entry] = pending
		end
		pending[purchaseId] = true
		return function()
			pending[purchaseId] = nil
			if next(pending) == nil then
				receiptReservations[entry] = nil
			end
		end,
			false
	end

	local function markProcessedRaw(data: { [string]: any }, purchaseId: string)
		local reserved = reservedRaw(data)
		local kept = historyForProfile(data)
		if not isProcessedRaw(data, purchaseId) then
			table.insert(kept, { Id = purchaseId, At = Clock.Now() })
		end
		reserved.ProcessedPurchaseIds = kept
		reserved.ReceiptReservations[purchaseId] = nil
	end

	local function markProcessed(entry: any, purchaseId: string)
		local accessor = reservedAcc(entry).ProcessedPurchaseIds
		local kept = historyForProfile(entry.LiveData)
		if not isProcessed(entry, purchaseId) then
			table.insert(kept, { Id = purchaseId, At = Clock.Now() })
		end
		accessor.Set(kept)
		if reservedRaw(entry.LiveData).ReceiptReservations[purchaseId] then
			reservedAcc(entry).ReceiptReservations[purchaseId].Set(nil)
		end
	end

	-- Gift records: the live intent and the archived aim -------------------------
	--
	-- Both have the same shape ({ RecipientId, GiftId, Ts, Product }), so the receipt arms
	-- settle an aim with the code that settles an intent rather than a hand-mirrored copy
	-- that drifts. `fromAim` selects the container everywhere.
	local PENDING_GIFTS = "PendingGifts"
	local GIFT_AIMS = "GiftAims"

	local function giftRecordKey(fromAim: boolean): string
		return if fromAim then GIFT_AIMS else PENDING_GIFTS
	end

	local function validRecipientId(value: any): number?
		local recipientId = tonumber(value)
		if
			recipientId == nil
			or recipientId ~= recipientId
			or recipientId == math.huge
			or recipientId == -math.huge
			or recipientId <= 0
			or recipientId % 1 ~= 0
		then
			return nil
		end
		return recipientId
	end

	-- Receipt-bound routes outlive replaceable product intents and aims.
	local function readReceiptRoute(reserved: any, purchaseId: string, product: Product): (any?, boolean)
		local route = reserved.ReceiptReservations[purchaseId]
		if route == nil or route == true then
			return nil, false
		end
		if
			type(route) ~= "table"
			or route.Product ~= product.Name
			or route.ProductId ~= product.Id
			or type(route.RecipientId) ~= "number"
			or validRecipientId(route.RecipientId) == nil
			or type(route.GiftId) ~= "string"
			or route.GiftId == ""
			or type(route.FromAim) ~= "boolean"
		then
			return nil, true
		end
		return route, false
	end

	local function giftReceiptRoute(product: Product, record: any, fromAim: boolean): any
		return {
			Product = product.Name,
			ProductId = product.Id,
			RecipientId = validRecipientId(record.RecipientId),
			GiftId = record.GiftId,
			FromAim = fromAim,
		}
	end

	-- Only complete records for this product can supply a destination.
	local function readGiftRecord(
		reserved: { [string]: any },
		fromAim: boolean,
		product: Product
	): {
		[string]: any,
	}?
		local record = reserved[giftRecordKey(fromAim)][tostring(product.Id)]
		if type(record) ~= "table" then
			return nil
		end
		if record.Product ~= nil and record.Product ~= product.Name then
			return nil
		end
		if validRecipientId(record.RecipientId) == nil or type(record.GiftId) ~= "string" or record.GiftId == "" then
			return nil
		end
		-- Age does not release an unresolved destination.
		return record
	end

	-- Clear only this gift: a saved receipt route may outlive its product slot.
	local function clearGiftRecord(entry: any, productIdStr: string, giftId: string): boolean
		local cleared = false
		for _, key in { PENDING_GIFTS, GIFT_AIMS } do
			local live = reservedRaw(entry.LiveData)[key][productIdStr]
			if type(live) == "table" and tostring(live.GiftId) == giftId then
				reservedAcc(entry)[key][productIdStr].Set(nil)
				cleared = true
			end
		end
		return cleared
	end

	local function hasPendingGift(entry: any, productId: number): boolean
		local reserved = reservedRaw(entry.LiveData)
		local key = tostring(productId)
		return reserved.PendingGifts[key] ~= nil or reserved.GiftAims[key] ~= nil
	end

	local function hasConflictingGiftRecords(reserved: any, productId: number): boolean
		local key = tostring(productId)
		local pending, aim = reserved.PendingGifts[key], reserved.GiftAims[key]
		if pending == nil or aim == nil then
			return false
		end
		return type(pending) ~= "table"
			or type(aim) ~= "table"
			or pending.GiftId ~= aim.GiftId
			or pending.RecipientId ~= aim.RecipientId
			or pending.Product ~= aim.Product
	end

	local function giftHasReceipt(reserved: any, giftId: string): boolean
		for _, route in reserved.ReceiptReservations do
			if route == true or (type(route) == "table" and route.GiftId == giftId) then
				return true
			end
		end
		return false
	end

	local function cancelGiftRecord(entry: any, productIdStr: string, giftId: string): boolean
		if entry.State ~= "Ready" or entry.TornDown or ctx.Persistence.EntryFor(entry.Player) ~= entry then
			return false
		end
		-- A close event cannot cancel a receipt already being settled.
		if giftHasReceipt(reservedRaw(entry.LiveData), giftId) then
			return false
		end
		return clearGiftRecord(entry, productIdStr, giftId)
	end

	--- The offline mirror, for use INSIDE an UpdateOffline transform where the slot
	--- has to be re-read against the compare-and-set's own draft.
	local function clearGiftRecordRaw(reserved: { [string]: any }, productIdStr: string, giftId: string)
		for _, key in { PENDING_GIFTS, GIFT_AIMS } do
			local container = reserved[key]
			local live = container[productIdStr]
			if type(live) == "table" and tostring(live.GiftId) == giftId then
				container[productIdStr] = nil
			end
		end
	end

	local function cancelUnopenedGift(entry: any, productIdStr: string, giftId: string, pending: PurchasePrompt?)
		if entry.State == "Ready" and not entry.TornDown and ctx.Persistence.EntryFor(entry.Player) == entry then
			local cleared = cancelGiftRecord(entry, productIdStr, giftId)
			if cleared and pending and purchasePrompts[entry.Player] == pending and not pending.Closed then
				pending.Cancelled = true
				finishCancellation(entry.Player)
			elseif cleared and promptStopped then
				ctx.Persistence.AwaitSave(entry, 10)
			end
			return
		end
		-- The buyer may have left while the intent save was yielding.
		ctx.Persistence.UpdateOffline(entry.UserId, function(data)
			local reserved = reservedRaw(data)
			if not giftHasReceipt(reserved, giftId) then
				clearGiftRecordRaw(reserved, productIdStr, giftId)
			end
		end)
	end

	--- Keep a record alive while its purchase is still retrying. Same ownership guard as
	--- the clears, plus a bare `[id].Ts = now` on an absent slot materializes a phantom.
	local function refreshGiftRecordTs(entry: any, fromAim: boolean, productIdStr: string, giftId: string)
		local key = giftRecordKey(fromAim)
		local live = reservedRaw(entry.LiveData)[key][productIdStr]
		if type(live) == "table" and tostring(live.GiftId) == giftId then
			reservedAcc(entry)[key][productIdStr].Ts.Set(Clock.Now())
		end
	end

	-- Archive only when the destination fits; otherwise keep the pending intent.
	local function archiveGiftAim(entry: any, productIdStr: string, intent: any): boolean
		if
			type(intent) ~= "table"
			or validRecipientId(intent.RecipientId) == nil
			or type(intent.GiftId) ~= "string"
			or intent.GiftId == ""
		then
			return false -- Keep malformed records for repair.
		end
		local aims = reservedRaw(entry.LiveData).GiftAims
		local existing = aims[productIdStr]
		if existing ~= nil then
			return type(existing) == "table"
				and existing.GiftId == intent.GiftId
				and existing.RecipientId == intent.RecipientId
				and existing.Product == intent.Product
		end
		if Util.count(aims) >= giftAimCap then
			Log.Warn(
				"Gifting",
				"GIFT_AIM_CAP_REACHED",
				`the gift aim store is at its cap ({giftAimCap}); keeping the pending gift until it settles`,
				{
					Player = entry.Player,
					Product = tostring(intent.Product),
					RecipientId = tonumber(intent.RecipientId),
				}
			)
			return false
		end
		reservedAcc(entry).GiftAims[productIdStr].Set({
			RecipientId = tonumber(intent.RecipientId),
			GiftId = tostring(intent.GiftId),
			Ts = tonumber(intent.Ts) or Clock.Now(),
			Product = intent.Product,
		})
		return true
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

	-- Written only by the receipt/grant path here; game code cannot forge entries.
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

	--- A declared PASS is a legitimate perk name, for the same reason it is a legitimate
	--- Grants target: a pass cannot be transferred, so granting the perk of the same name
	--- is how a gift confers it, and Owns answers across both namespaces.
	local function checkPerkName(key: string)
		if ctx.DevMode and declaredPerks and not declaredPerks[key] and not passesByName[key] then
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

	-- The ownership predicate: perk flag, cached pass ownership, or Roblox Plus. No DevMode
	-- warning and no entry lookup, because internal scans legitimately walk keys that were
	-- never registered.
	local function ownsInternal(player: Player, entry: any, key: string): boolean
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
			-- Coerce: the property is nil on a player object that predates it, and a nil
			-- would read as "changed" against a false baseline on every ownership scan.
			return player.HasRobloxSubscription == true
		end
		return false
	end

	-- Paid random items. The policy is per session, read once off the join path;
	-- unknown refuses.
	local POLICY_ATTEMPTS = 3
	local POLICY_RETRY_BASE = 2
	local POLICY_REARM_AFTER = 30

	local function readPolicy(entry: any, attempts: number)
		local policy = entry.Policy
		for attempt = 1, attempts do
			policy.LastAttempt = Clock.Monotonic()
			local ok, info = pcall(getPolicyInfo, entry.Player)
			if ok and type(info) == "table" then
				policy.Restricted = info.ArePaidRandomItemsRestricted == true
				policy.Phase = "known"
				return
			end
			if attempt == attempts then
				policy.Phase = "failed"
				if not policy.Logged then
					policy.Logged = true
					Log.Warn(
						"Monetization",
						"POLICY_READ_FAIL",
						`could not read the player's policy: {tostring(info)}; paid random items stay refused`,
						{ Player = entry.Player }
					)
				end
				return
			end
			Clock.Wait(Rng.Jitter(POLICY_RETRY_BASE * 2 ^ (attempt - 1)))
		end
	end

	local function ensurePolicy(entry: any)
		local policy = entry.Policy
		if policy == nil then
			policy = { Phase = "pending", Restricted = false, LastAttempt = 0, Logged = false }
			entry.Policy = policy
			Sched.Spawn(readPolicy, entry, POLICY_ATTEMPTS)
		elseif policy.Phase == "failed" and Clock.Monotonic() - policy.LastAttempt >= POLICY_REARM_AFTER then
			policy.Phase = "pending"
			Sched.Spawn(readPolicy, entry, 1)
		end
		return policy
	end

	-- Purchase and PromptGift answer in sentences; PromptPurchase answers in ProductState.
	local PAID_RANDOM_REASON: { [string]: string } = {
		["paid-random-restricted"] = "paid random items are not available for this account",
		["policy-pending"] = "cannot check account settings right now; try again in a moment",
	}

	-- nil when the player may buy paid random items.
	local function paidRandomState(entry: any): string?
		local policy = ensurePolicy(entry)
		if policy.Phase == "known" then
			return if policy.Restricted then "paid-random-restricted" else nil
		end
		return "policy-pending"
	end

	-- NON-YIELDING: reads the cache refreshOwnership fills asynchronously, so a
	-- genuinely-owned gamepass can still read false just after join. Use OwnsAsync when
	-- the answer has to be authoritative immediately.
	function self.Owns(player: Player, key: string): boolean
		checkOwnsKey(key, "Owns")
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" or not entry.LiveData then
			return false
		end
		return ownsInternal(player, entry, key)
	end

	-- One function behind both the query and the prompt, so they cannot disagree.
	local function productState(entry: any, name: string, product: any, pass: any): string
		if not entry or entry.State ~= "Ready" then
			return "not-loaded"
		end
		if product and product.PaidRandom then
			local refused = paidRandomState(entry)
			if refused ~= nil then
				return refused
			end
		end
		local ownedKey = if pass then name else product.Grants
		if ownedKey ~= nil and self.Owns(entry.Player, ownedKey) then
			return "owned"
		end
		return "purchasable"
	end

	function self.GetProductState(player: Player, name: string): string
		local product, pass = productsByName[name], passesByName[name]
		if not product and not pass then
			-- 3: here -> Data.GetProductState -> the caller.
			error(`Scribe.GetProductState: "{tostring(name)}" is not a declared pass or product`, 3)
		end
		return productState(ctx.Persistence.EntryFor(player), name, product, pass)
	end

	local function setOwnsCache(entry: any, key: string, owned: boolean)
		if entry.Tree and not entry.Tree.Dead then
			entry.Tree.Accessor[Template.SESSION_ROOT].OwnsCache[key].Set(if owned then true else nil)
		end
	end

	-- Ownership only gains during a session, so a late answer must not clear a confirmed pass.
	local function foldOwnsCache(entry: any, key: string, owned: boolean): boolean
		if not entry.Tree or entry.Tree.Dead then
			return owned
		end
		local kept = owned or entry.Tree.Accessor[Template.SESSION_ROOT].OwnsCache[key].Get() == true
		setOwnsCache(entry, key, kept)
		return kept
	end

	-- Every key whose ownership is worth tracking: everything registered, plus whatever
	-- the profile actually holds.
	local function ownershipCandidates(entry: any): { [string]: boolean }
		local candidates: { [string]: boolean } = {}
		for key in knownOwnsKeys do
			candidates[key] = true
		end
		local reserved = reservedRaw(entry.LiveData)
		for key in reserved.Perks do
			candidates[key] = true
		end
		local session = entry.SessionStore[Template.SESSION_ROOT]
		local ownsCache = if type(session) == "table" then session.OwnsCache else nil
		if type(ownsCache) == "table" then
			for key in ownsCache do
				candidates[key] = true
			end
		end
		return candidates
	end

	-- Recompute effective ownership and fire OnOwnershipChanged for keys that actually
	-- flipped. Watching the two inputs (Perks and OwnsCache) covers every write site
	-- with no per-site instrumentation. `silent` seeds the baseline at load.
	local function scanOwnership(entry: any, silent: boolean?)
		if entry.TornDown or not entry.LiveData or entry.State ~= "Ready" then
			return
		end
		local player = entry.Player
		local last = entry.OwnsLast
		if not last then
			last = {}
			entry.OwnsLast = last
		end
		local candidates = ownershipCandidates(entry)
		-- A key that went away still needs its false. ownershipCandidates is built from
		-- current state, so a perk revoked under a name outside the Perks registry is listed
		-- nowhere and its false would never fire. The baseline records what was last
		-- reported, so unioning it in is exactly the set that could still owe a transition,
		-- and it cannot grow without bound: a false fired here never fires again.
		for key in last do
			candidates[key] = true
		end
		for key in candidates do
			local owned = ownsInternal(player, entry, key)
			if owned ~= (last[key] == true) then
				last[key] = owned
				if not silent then
					ctx.Signals.OnOwnershipChanged:Fire(player, key, owned)
				end
			end
		end
	end

	-- Attach the ownership watchers for an entry. Detached on unload.
	local function watchOwnership(entry: any)
		if not entry.Tree or entry.Tree.Dead then
			return
		end
		local accessor = entry.Tree.Accessor
		scanOwnership(entry, true) -- baseline: record current state without firing
		local function onChange()
			scanOwnership(entry)
		end
		entry.OwnsWatchers = {
			-- Through the privileged handle, not the public child: a public read hands back
			-- a detached deep copy (readOut in Node.luau), and this callback ignores the
			-- value entirely.
			reservedAcc(entry).Perks.Changed(onChange),
			accessor[Template.SESSION_ROOT].OwnsCache.Changed(onChange),
		}
	end

	-- Push the player's current ownership of `key`, then again on every change, deduped so
	-- only real transitions fire. Returns a disconnect. The public doc-comment lives on
	-- Data.ObserveOwned (Server/init.luau); keep this a plain comment so docgen does not
	-- emit a duplicate entry.
	function self.ObserveOwned(player: Player, key: string, callback: (owned: boolean) -> ()): () -> ()
		checkOwnsKey(key, "ObserveOwned")
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" or not entry.Tree or entry.Tree.Dead then
			error("Scribe: ObserveOwned requires a Ready player (use Data.WaitForData)", 3)
		end
		local last: boolean? = nil
		local function push()
			if entry.TornDown or not entry.LiveData then
				return
			end
			local owned = ownsInternal(player, entry, key)
			if owned ~= last then
				last = owned
				Sched.Spawn(callback, owned)
			end
		end
		local accessor = entry.Tree.Accessor
		-- Privileged handle: see the note in watchOwnership.
		local disconnectPerk = reservedAcc(entry).Perks.Changed(push)
		local disconnectCache = accessor[Template.SESSION_ROOT].OwnsCache.Changed(push)
		push()
		return function()
			disconnectPerk()
			disconnectCache()
		end
	end

	-- Flip the replicated OwnsSynced flag once every gamepass check has resolved, so the
	-- client OwnsAsync knows the initial sync is complete. Idempotent per entry.
	local function markOwnershipReady(entry: any)
		if entry.OwnershipReady then
			return
		end
		entry.OwnershipReady = true
		if entry.Tree and not entry.Tree.Dead then
			entry.Tree.Accessor[Template.SESSION_ROOT].OwnsSynced.Set(true)
		end
	end

	local function refreshOwnership(entry: any)
		local player = entry.Player
		entry.OwnershipReady = false
		setOwnsCache(entry, "RobloxPlus", player.HasRobloxSubscription)
		-- Count the outstanding gamepass checks; the last to resolve marks the entry
		-- ownership-ready. No yield between the decrement and the check, so this is safe.
		local pending = 0
		for _ in passesByName do
			pending += 1
		end
		if pending == 0 then
			markOwnershipReady(entry)
			return
		end
		for name, pass in passesByName do
			Sched.Spawn(function()
				local ok, owned = pcall(function()
					return userOwnsGamePass(entry.UserId, pass.Id)
				end)
				if ok and not entry.TornDown then
					-- Fold this resolution into the join baseline before writing it.
					-- watchOwnership takes its silent baseline while this network round trip
					-- is still out, so without this every player who already owned a pass got
					-- a spurious owned=true. OR, never assign: ownership is the union of
					-- Perks, OwnsCache and RobloxPlus. A nil OwnsLast means the baseline has
					-- not been taken yet and that scan absorbs this by itself.
					local last = entry.OwnsLast
					if last ~= nil and entry.Tree and not entry.Tree.Dead then
						last[name] = last[name] == true or owned == true
					end
					foldOwnsCache(entry, name, owned == true)
				elseif not ok then
					-- A throw or throttle leaves this pass unresolved and the cache not-owned.
					-- Surface it rather than treating a failed check as a confirmed not-owned.
					Metrics.Add("OwnershipCheckFailures")
					Log.Warn(
						"Monetization",
						"OWNERSHIP_CHECK_FAIL",
						tostring(owned),
						{ Player = entry.Player, Pass = name, PassId = pass.Id }
					)
				end
				pending -= 1
				if pending <= 0 and not entry.TornDown then
					markOwnershipReady(entry)
				end
			end)
		end
	end

	-- Like self.Owns, but AUTHORITATIVE: a cached "owned" is returned as-is, anything else
	-- is verified live against MarketplaceService, so a pass bought moments ago shows
	-- immediately. Yields. `_timeout` exists only for parity with the client version. The
	-- public doc-comment lives on Data.OwnsAsync (Server/init.luau); keep this a plain
	-- comment so docgen does not emit a duplicate entry.
	function self.OwnsAsync(player: Player, key: string, _timeout: number?): boolean
		checkOwnsKey(key, "OwnsAsync")
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" or not entry.LiveData then
			return false
		end
		-- Ownership only ever gains for the session, so a cached true is already
		-- verified; skip the query.
		if self.Owns(player, key) then
			return true
		end
		-- Not owned per the cache. Verify live with the server-side UserOwnsGamePassAsync:
		-- this is the exploit-proof check to gate grants on, and the client's Owns/OwnsAsync
		-- are mirror reads that must never gate one. Refresh the cache while we are here.
		local pass = passesByName[key]
		if pass and not entry.TornDown then
			local ok, owned = pcall(function()
				return userOwnsGamePass(entry.UserId, pass.Id)
			end)
			if ok then
				if not entry.TornDown then
					return foldOwnsCache(entry, key, owned == true)
				end
				return owned == true
			end
			Metrics.Add("OwnershipCheckFailures")
			Log.Warn(
				"Monetization",
				"OWNERSHIP_CHECK_FAIL",
				tostring(owned),
				{ Player = entry.Player, Pass = key, PassId = pass.Id }
			)
		end
		return self.Owns(player, key)
	end

	-- Grant application ----------------------------------------------------------------------

	-- DevMode only. A Grant that writes THROUGH a key naming no element dereferences a
	-- dangling pointer: the element seeds from its defaults, the receipt settles
	-- PurchaseGranted, and the goods land where the player can never see them. A warning
	-- and not a refusal, because a dangling id is indistinguishable from a deliberate one.
	local function seedWatcher(entry: any, label: string): ((seeded: { { string | number } }) -> ())?
		if not ctx.DevMode then
			return nil
		end
		return function(seeded)
			local paths = table.create(#seeded)
			for _, path in seeded do
				table.insert(paths, Util.pathString(path))
			end
			local joined = table.concat(paths, ", ")
			Log.Warn(
				"Monetization",
				"GRANT_SEEDED_ELEMENT",
				`{label} brought {#paths} container element(s) into existence by writing THROUGH a key `
					.. `that named none: {joined}. Expected when the id is one you just minted -- a fresh `
					.. "key starting from the element defaults is ordinary. The case to check is an id "
					.. "that came from STORED data (a slot, an equipped item, any pointer): if it names "
					.. "nothing, this grant landed where the player will never see it and the receipt "
					.. "still settles as delivered. Resolve the id before you spend it. To silence this "
					.. "for a genuinely new element, create it with a whole-element Set instead.",
				{ Player = entry.Player, Paths = joined }
			)
		end
	end

	-- Applies a product's effects to a Ready entry. Returns (granted, partial): `granted`
	-- false means a Grant callback threw, and `partial` says whether writes from before the
	-- throw are still in the tree. Only the yielding path can leave them, and the caller has
	-- to know because retrying a partial re-applies it.
	local function applyProductGrant(entry: any, product: Product): (boolean, boolean)
		if not product.Grant and not product.Grants then
			return true, false
		end
		-- Atomic, because a receipt is retried: a Grant that wrote part-way and then threw
		-- would leave those writes in the profile while markProcessed never ran, so every
		-- retry re-applies them. The Grant must therefore not yield, which is refused loudly
		-- rather than silently rolled back.
		local function apply()
			if product.Grant then
				(product.Grant :: (any) -> ())(entry.Tree.Accessor)
			end
			if product.Grants then
				checkPerkName(product.Grants)
				reservedAcc(entry).Perks[product.Grants].Set(true)
			end
		end

		local ok, err = entry.Tree:RunTransaction(apply, seedWatcher(entry, `product "{product.Name}"`))
		if ok then
			return true, false
		end

		if err == Node.YIELD_ERROR then
			-- The Grant yielded, so it cannot be made atomic: a rollback across a yield would
			-- revert unrelated writes that landed meanwhile, which here means destroying paid
			-- currency. Refusing outright is a permanent NotProcessedYet, which is worse. Run
			-- it non-atomically and say so loudly.
			Log.Error(
				"Monetization",
				"GRANT_FAIL",
				`product "{product.Name}" Grant yields, so it cannot be applied atomically. `
					.. "It ran WITHOUT rollback: if it throws part-way, its partial writes stay "
					.. "and Roblox re-applies them on every receipt retry. Move the async work "
					.. "outside Grant (do it before the prompt, or after via OnSave).",
				{ Player = entry.Player, Product = product.Name }
			)
			local ranOk, ranErr = xpcall(apply, function(e)
				return debug.traceback(tostring(e), 2)
			end)
			if not ranOk then
				Log.Error("Monetization", "GRANT_FAIL", `product "{product.Name}" Grant threw: {ranErr}`, {
					Player = entry.Player,
				})
				-- PARTIAL: the pre-throw writes are in the tree and cannot be rolled back.
				return false, true
			end
			return true, false
		end

		Log.Error("Monetization", "GRANT_FAIL", `product "{product.Name}" Grant failed: {err}`, {
			Player = entry.Player,
		})
		-- Not partial: RunTransaction rolled this one back.
		return false, false
	end

	-- Gift delivery to a Ready entry on this server. Returns (applied, durable,
	-- refundable): `applied` means the grant is in the recipient's memory, `durable` that it
	-- is confirmed saved, and callers reporting PurchaseGranted must require `durable`.
	-- `refundable` means the delivery PROVABLY did not happen, and is false by default:
	-- every other failure is ambiguous, and refunding one that did happen grants twice.
	local function deliverGiftLocalCore(
		recipientEntry: any,
		product: Product,
		purchaseId: string,
		giftId: string,
		fromUserId: number
	): (boolean, boolean, boolean)
		if isProcessed(recipientEntry, purchaseId) then
			-- Already granted in memory (possibly on a prior attempt whose save failed);
			-- confirm it is durable before acknowledging. Held in a local rather than
			-- tail-returned: a tail call would land AwaitSave's second return in `refundable`.
			local durable = ctx.Persistence.AwaitSave(recipientEntry, 10)
			return true, durable, false
		end
		local granted, partial = applyProductGrant(recipientEntry, product)
		if not granted and not partial then
			-- PROVABLY not delivered: RunTransaction rolled the Grant back, so there is no
			-- write and no marker. Refunding here is correct.
			return false, false, true
		end
		if not granted then
			-- Same rule as the online receipt path: a yielding Grant that threw leaves
			-- writes that cannot be rolled back, and answering "not delivered" makes the
			-- receipt retry and re-apply them on the RECIPIENT. Settle it once, loudly.
			Metrics.Add("ReceiptsPartial")
			Failure.Report({
				Subsystem = "Receipt",
				Key = purchaseId,
				Category = "Monetization",
				Code = "GRANT_PARTIAL",
				Message = `gifted product "{product.Name}" Grant yielded and then threw; its partial writes stand, `
					.. "and the gift is being settled so retries cannot compound them",
				Context = { Player = recipientEntry.Player, Product = product.Name, PurchaseId = purchaseId },
			})
		end
		robuxLog(recipientEntry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			From = { Type = "GiftReceived", FromUserId = fromUserId, GiftId = giftId },
			Ts = Clock.Now(),
		})
		markProcessed(recipientEntry, purchaseId)
		Metrics.Add("GiftsDelivered")
		ctx.Signals.OnGiftReceived:Fire(recipientEntry.Player, {
			FromUserId = fromUserId,
			Product = product.Name,
			GiftId = giftId,
		})
		-- Await the RECIPIENT's save: the paid value lives in their profile. Held in a
		-- local for the same reason as the isProcessed exit above.
		local durable = ctx.Persistence.AwaitSave(recipientEntry, 10)
		return true, durable, false
	end

	local function deliverGiftLocal(
		recipientEntry: any,
		product: Product,
		purchaseId: string,
		giftId: string,
		fromUserId: number
	): (boolean, boolean, boolean)
		pruneProcessed(recipientEntry)
		if isProcessed(recipientEntry, purchaseId) then
			return deliverGiftLocalCore(recipientEntry, product, purchaseId, giftId, fromUserId)
		end
		local release, clean = reserveReceipt(recipientEntry, purchaseId)
		if not release then
			return false, false, clean
		end
		local ok, applied, durable, refundable =
			pcall(deliverGiftLocalCore, recipientEntry, product, purchaseId, giftId, fromUserId)
		release()
		if not ok then
			error(applied, 0)
		end
		return applied, durable, refundable
	end

	-- Durable delivery to any recipient: same server applies directly, another server or
	-- offline goes by ProfileStore MessageAsync. Returns (applied, durable, refundable)
	-- as deliverGiftLocal, under the same default.
	local function deliverGift(
		product: Product,
		recipientUserId: number,
		purchaseId: string,
		giftId: string,
		fromUserId: number
	): (boolean, boolean, boolean)
		local recipientEntry = ctx.Persistence.EntryForUserId(recipientUserId)
		if recipientEntry and recipientEntry.State == "Ready" then
			return deliverGiftLocal(recipientEntry, product, purchaseId, giftId, fromUserId)
		end
		-- Not durable and not refundable: the receipt retries on a live server.
		if ctx.Persistence.Mode == "NoSave" then
			ctx.Persistence.RefuseNoSave("GiftDelivery")
			return false, false, false
		end
		local ok, delivered, reason, provablyClean = pcall(function()
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
			return true, true, false
		end
		if ok and reason == "QueueFull" then
			-- The recipient's inbox is at its cap. `durable = false` keeps the PAID gift
			-- alive: the buyer's escrow intent stands, the receipt answers NotProcessedYet
			-- and Roblox's retry re-sends. This arm cannot say on its own that the CALL wrote
			-- nothing, because MessageAsync retries UpdateAsync inside one call, so a
			-- QueueFull can be reported for a message an earlier attempt already queued;
			-- `provablyClean` is the only value entitled to claim otherwise.
			--
			-- Not reported through Failure.Report: a full inbox is a property of one player's
			-- profile rather than a DataStore fault, and degrading to Outage would start
			-- refusing every Robux grant, including this receipt's retry.
			Metrics.Add("MessageQueueFull")
			if provablyClean ~= true then
				-- The ambiguous shape, the one that can end in two grants off one payment. A
				-- second counter rather than a split, so a dashboard watching
				-- MessageQueueFull still sees every refusal.
				Metrics.Add("MessageQueueFullAmbiguous")
			end
			Log.Warn(
				"Gifting",
				"MESSAGE_QUEUE_FULL",
				if provablyClean == true
					then "the recipient's message queue is at its cap and no attempt in this call reached "
						.. "storage; the gift was not delivered and the receipt will retry"
					else "the recipient's message queue is at its cap, but an earlier attempt in the same "
						.. "call may already have queued this gift; it is being retried and could arrive twice",
				{
					RecipientId = recipientUserId,
					Product = product.Name,
					-- False means this refusal is not evidence the gift is absent.
					ProvablyClean = provablyClean == true,
				}
			)
			-- Refundable only where the store says the whole call is clean. A refund after a
			-- commit hands back a credit whose retry mints a fresh giftId the recipient's
			-- receipt history has never seen, so one credit grants twice. Not "was this the first
			-- attempt?" either: a throttled request never reaches storage, so a full inbox
			-- behind one is as clean as a full inbox behind nothing.
			return false, false, provablyClean == true
		end
		-- Keyed by recipient. Past this point the send threw, MessageAsync gave up
		-- retrying, or it refused at its IsClosing door without attempting anything.
		-- Reporting is the same for all three; the refund below is not.
		Failure.Report({
			Subsystem = "GiftDelivery",
			Key = tostring(recipientUserId),
			Error = if ok then nil else delivered,
			Category = "Gifting",
			Code = "GIFT_DELIVERY_RETRY",
			Message = "MessageAsync failed; receipt will retry",
			Context = { RecipientId = recipientUserId, Product = product.Name },
		})
		-- AMBIGUOUS BY DEFAULT, refundable only where the store says otherwise. This is the
		-- lost-answer exit: a throw carries the doubt inside one attempt (a 504 may have
		-- landed), and a bare `false` carries it whenever the retry loop ended at BindToClose
		-- after an attempt that could have committed. ProfileStore retries inside this call,
		-- so the class of the last attempt says nothing about the ones before it;
		-- `provablyClean` is its aggregate across them. Every throw therefore reads as
		-- ambiguous, because one lost credit is preferred over one double grant.
		return false, false, ok and provablyClean == true
	end

	-- Cross-server message handler (registered by Persistence once Ready).
	function self.OnProfileMessage(entry: any, message: any, processed: () -> ())
		if type(message) ~= "table" or message.ScribeGift ~= true then
			return -- not ours; leave it for other handlers
		end
		pruneProcessed(entry)
		local purchaseId = tostring(message.PurchaseId)
		if isProcessed(entry, purchaseId) then
			processed()
			return
		end
		local product = productsByName[tostring(message.Product)] or retiredByName[tostring(message.Product)]
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
		-- Gate on `durable` (2nd return), NOT `applied` (1st): this queued message is the
		-- only surviving durable copy of the paid gift, and processed() removes it for good.
		-- Ack-ing a merely in-memory grant loses the gift on a crash.
		--
		-- Completion records deduplicate redelivery within the retention window.
		local _, durable =
			deliverGiftLocal(entry, product, purchaseId, tostring(message.GiftId), tonumber(message.FromUserId) or 0)
		if durable then
			processed()
		end
	end

	-- Receipt handling -------------------------------------------------------------

	local NOT_PROCESSED = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

	local function canInferGift(receiptInfo: any): boolean
		local channel = receiptInfo.ProductPurchaseChannel
		-- Legacy receipts omit the channel; other channels cannot select an in-game gift.
		return channel == nil or channel == Enum.ProductPurchaseChannel.InExperience
	end

	local function retryGiftRoute(userId: number, product: Product, purchaseId: string): Enum.ProductPurchaseDecision
		Metrics.Add("ReceiptsRetried")
		Log.Warn("Monetization", "RECEIPT_RETRY", "gift route or recipient proof unavailable; letting Roblox retry", {
			UserId = userId,
			Product = product.Name,
			PurchaseId = purchaseId,
		})
		return NOT_PROCESSED
	end

	local function checkGiftRecord(userId: number, product: Product, purchaseId: string, record: any): boolean
		if type(record) ~= "table" then
			retryGiftRoute(userId, product, purchaseId)
			return false
		end
		if validRecipientId(record.RecipientId) == nil then
			Log.Error(
				"Gifting",
				"GIFT_INVALID_RECIPIENT",
				"gift has an invalid recipient; holding the receipt for repair",
				{
					UserId = userId,
					Product = product.Name,
					PurchaseId = purchaseId,
					RecipientId = record.RecipientId,
				}
			)
			Metrics.Add("ReceiptsRetried")
			return false
		end
		if type(record.GiftId) ~= "string" or record.GiftId == "" then
			retryGiftRoute(userId, product, purchaseId)
			return false
		end
		return true
	end

	-- Malformed gift slots cannot fall through to a self purchase.
	local function checkGiftSlots(reserved: any, userId: number, product: Product, purchaseId: string): boolean
		for _, key in { PENDING_GIFTS, GIFT_AIMS } do
			local record = reserved[key][tostring(product.Id)]
			if record == nil then
				continue
			end
			if type(record) == "table" and record.Product ~= nil and record.Product ~= product.Name then
				continue
			end
			if not checkGiftRecord(userId, product, purchaseId, record) then
				return false
			end
		end
		return true
	end

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

	-- Whether THIS purchase was already delivered to the recipient. Returns nil when the
	-- recipient's data cannot be read, and the caller must then retry, never credit.
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
		-- Intents are keyed by product Id, so if a deploy retired the product and reused its
		-- Id within the TTL the stored intent belongs to the OLD product. Honouring it would
		-- gift the new product to the old recipient, so expire it.
		if intent.Product ~= nil and intent.Product ~= product.Name then
			reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
			Log.Warn("Gifting", "GIFT_INTENT_EXPIRED", "gift intent belonged to a retired product reusing this Id", {
				Player = entry.Player,
				Product = product.Name,
			})
			return nil
		end
		return intent
	end

	--- Settle a receipt as the gift it was bought as. `fromAim` says which container holds
	--- the record: false for a live PendingGifts intent, true for an archived GiftAims aim
	--- the sweep kept after the intent went stale. One implementation for both, because a
	--- hand-mirrored copy drifts and every drift here is real money.
	local function handleGiftReceipt(
		entry: any,
		product: Product,
		intent: { [string]: any },
		receiptInfo: any,
		fromAim: boolean
	): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local route, invalid = readReceiptRoute(reservedRaw(entry.LiveData), purchaseId, product)
		if invalid then
			return retryGiftRoute(entry.UserId, product, purchaseId)
		end
		if route == nil then
			if not checkGiftRecord(entry.UserId, product, purchaseId, intent) then
				return NOT_PROCESSED
			end
			route = giftReceiptRoute(product, intent, fromAim)
			if not canRecordReceipt(entry.LiveData, purchaseId, entry, nil, route) then
				return NOT_PROCESSED
			end
			reservedAcc(entry).ReceiptReservations[purchaseId].Set(route)
		end
		-- Pin the receipt's destination before another profile receives value.
		if not ctx.Persistence.AwaitSave(entry, 10) then
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end
		fromAim = route.FromAim
		local recipientId = route.RecipientId
		local giftId = route.GiftId
		local productIdStr = tostring(product.Id)

		-- The recipient may have acquired the perk between the prompt and the receipt, so
		-- delivering would be a no-op grant that burns the buyer's Robux; convert to a gift
		-- credit instead. Only if this purchase was not already delivered on a prior attempt
		-- whose buyer-commit failed, or one payment yields both a gift and a credit.
		local convertToCredit = false
		if
			product.Grants
			and not product.Grant
			and not allowDuplicateGifts
			and recipientAlreadyOwns(recipientId, product.Grants)
		then
			local delivered = giftAlreadyDelivered(recipientId, purchaseId)
			if delivered == nil then
				return retryGiftRoute(entry.UserId, product, purchaseId)
			end
			convertToCredit = not delivered
		end
		if convertToCredit then
			local creditsAccessor = reservedAcc(entry).GiftCredits[product.Name]
			creditsAccessor.Set((tonumber(creditsAccessor.Get()) or 0) + 1)
			-- Receipt retries may outlive their original product slot.
			clearGiftRecord(entry, productIdStr, giftId)
			robuxLog(entry, {
				PurchaseId = purchaseId,
				Product = product.Name,
				Category = product.Category,
				PriceInRobux = receiptInfo.CurrencySpent,
				From = { Type = "GiftCredit", IntendedFor = recipientId },
				Ts = Clock.Now(),
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
			-- Refresh only our record; delivery may have yielded past a replacement.
			refreshGiftRecordTs(entry, fromAim, productIdStr, giftId)
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		-- A retry must never clear another gift's product slot.
		clearGiftRecord(entry, productIdStr, giftId)
		robuxLog(entry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			PriceInRobux = receiptInfo.CurrencySpent,
			-- IntendedFor only on an aim-settled line: it is the field every other
			-- aim-resolved line carries, so one query finds them all.
			From = {
				Type = "GiftSent",
				ToUserId = recipientId,
				GiftId = giftId,
				IntendedFor = if fromAim then recipientId else nil,
			},
			Ts = Clock.Now(),
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
		-- No duplicate check here, deliberately: handleReceipt does it and there is no yield
		-- between the two, so a copy here could never see anything new.

		local reserved = reservedRaw(entry.LiveData)
		local route, invalid = readReceiptRoute(reserved, purchaseId, product)
		if invalid then
			return retryGiftRoute(entry.UserId, product, purchaseId)
		end
		if route then
			return handleGiftReceipt(entry, product, route, receiptInfo, route.FromAim)
		end
		if
			(canInferGift(receiptInfo) or reserved.ReceiptReservations[purchaseId] == true)
			and not checkGiftSlots(reserved, entry.UserId, product, purchaseId)
		then
			return NOT_PROCESSED
		end
		-- Older builds could leave two destinations for one product. Never guess.
		if
			hasConflictingGiftRecords(reserved, product.Id)
			and (canInferGift(receiptInfo) or reserved.ReceiptReservations[purchaseId] == true)
		then
			return retryGiftRoute(entry.UserId, product, purchaseId)
		end
		local staleIntent = readGiftRecord(reserved, false, product)
		if reserved.ReceiptReservations[purchaseId] == true then
			local legacyRecord = staleIntent or readGiftRecord(reserved, true, product)
			if legacyRecord == nil then
				return retryGiftRoute(entry.UserId, product, purchaseId)
			end
			return handleGiftReceipt(entry, product, legacyRecord, receiptInfo, staleIntent == nil)
		end

		local inferGift = canInferGift(receiptInfo)
		local intent = if inferGift then intentFor(entry, product) else nil
		if intent then
			return handleGiftReceipt(entry, product, intent, receiptInfo, false)
		end

		-- Retained aims still own in-experience receipts, regardless of age.
		local record, fromAim = staleIntent, false
		if record == nil then
			record = readGiftRecord(reservedRaw(entry.LiveData), true, product)
			fromAim = record ~= nil
		end
		if record then
			local aimedAt = tonumber(record.RecipientId) or 0
			local presumable = inferGift and fromAim
			local delivered = if presumable then true else giftAlreadyDelivered(aimedAt, purchaseId)
			if delivered == nil then
				return retryGiftRoute(entry.UserId, product, purchaseId)
			end
			if delivered then
				if fromAim then
					Log.Warn(
						"Gifting",
						"GIFT_AIM_SETTLED",
						"a receipt arrived after its gift intent had been swept; settling it from the durable aim "
							.. "instead of granting it to the buyer",
						{
							Player = entry.Player,
							Product = product.Name,
							PurchaseId = purchaseId,
							RecipientId = aimedAt,
						}
					)
					Metrics.Add("GiftAimsSettled")
				end
				return handleGiftReceipt(entry, product, record, receiptInfo, fromAim)
			end
			if inferGift and not fromAim then
				clearGiftRecord(entry, tostring(product.Id), tostring(record.GiftId))
			end
		end

		-- No matching intent: NoGiftIntentPolicy. A product with a consumable Grant still
		-- delivers real value, so the credit path only covers pure perk products.
		if product.Grants and not product.Grant and self.Owns(entry.Player, product.Grants) then
			-- Hold further credits until the existing paid credit is spent. Roblox may retry later.
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
			-- GrantOrCredit: a no-op grant would burn Robux, so write a durable gift credit.
			-- A no-intent purchase never stacks onto a pending credit (declined above), but
			-- an aimed-gift conversion in handleGiftReceipt may, since that money is taken.
			local creditsAccessor = reservedAcc(entry).GiftCredits[product.Name]
			creditsAccessor.Set((creditsAccessor.Get() or 0) + 1)
			robuxLog(entry, {
				PurchaseId = purchaseId,
				Product = product.Name,
				Category = product.Category,
				PriceInRobux = receiptInfo.CurrencySpent,
				From = { Type = "GiftCredit" },
				Ts = Clock.Now(),
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
			-- A giftable perk product bought without intent: grant to the buyer.
			Log.Warn("Gifting", "GIFT_NO_INTENT", "perk product purchased with no gift intent; granting to buyer", {
				Player = entry.Player,
				Product = product.Name,
			})
		end

		local granted, partial = applyProductGrant(entry, product)
		if not granted and not partial then
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end
		if not granted then
			-- The Grant yielded and then threw, so its writes cannot be taken back and every
			-- NotProcessedYet retry re-applies them. Settle it as delivered-once and be loud
			-- so an operator can compensate; unbounded inflation is worse than one partial.
			Metrics.Add("ReceiptsPartial")
			Failure.Report({
				Subsystem = "Receipt",
				Key = purchaseId,
				Category = "Monetization",
				Code = "GRANT_PARTIAL",
				Message = `product "{product.Name}" Grant yielded and then threw; its partial writes stand, and the `
					.. "receipt is being settled so retries cannot compound them",
				Context = { Player = entry.Player, Product = product.Name, PurchaseId = purchaseId },
			})
		end
		robuxLog(entry, {
			PurchaseId = purchaseId,
			Product = product.Name,
			Category = product.Category,
			PriceInRobux = receiptInfo.CurrencySpent,
			From = { Type = "Purchase", Partial = if granted then nil else true },
			Ts = Clock.Now(),
		})
		markProcessed(entry, purchaseId)
		Log.Info("Monetization", "RECEIPT_GRANTED", "purchase granted", {
			Player = entry.Player,
			PurchaseId = purchaseId,
			ProductId = product.Id,
		})
		Metrics.Add("ReceiptsGranted")

		-- Auto-flush after every grant: a crash between "player paid" and the next
		-- autosave must never eat a purchase.
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

	--- The offline mirror of handleGiftReceipt, for a buyer no longer on this server.
	--- `fromAim` selects the container exactly as it does online.
	---
	--- Hand-mirrored rather than shared with the online arm because the two write through
	--- different machinery (accessor tree vs. an UpdateOffline compare-and-set), so
	--- GiftArmParity.spec is what holds them level.
	local function settleOfflineGift(
		userId: number,
		product: Product,
		receiptInfo: any,
		record: { [string]: any },
		fromAim: boolean
	): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local productIdStr = tostring(product.Id)

		-- Persist the route and capacity before another profile receives value.
		local completed = false
		local reservedOk = ctx.Persistence.UpdateOffline(userId, function(offlineData)
			pruneProcessedRaw(offlineData)
			if isProcessedRaw(offlineData, purchaseId) then
				completed = true
				return
			end
			local reserved = reservedRaw(offlineData)
			local route, invalid = readReceiptRoute(reserved, purchaseId, product)
			if invalid then
				error("gift receipt route does not match this product", 0)
			end
			if route == nil then
				if not checkGiftRecord(userId, product, purchaseId, record) then
					error("invalid gift record", 0)
				end
				if canInferGift(receiptInfo) or reserved.ReceiptReservations[purchaseId] == true then
					if not checkGiftSlots(reserved, userId, product, purchaseId) then
						error("invalid gift record", 0)
					end
					if hasConflictingGiftRecords(reserved, product.Id) then
						retryGiftRoute(userId, product, purchaseId)
						error("ambiguous gift route", 0)
					end
				end
				-- Recheck the selected destination against the writable profile.
				local current = readGiftRecord(reserved, fromAim, product)
				if
					current == nil
					or current.GiftId ~= record.GiftId
					or validRecipientId(current.RecipientId) ~= validRecipientId(record.RecipientId)
				then
					retryGiftRoute(userId, product, purchaseId)
					error("gift destination changed before reservation", 0)
				end
				route = giftReceiptRoute(product, record, fromAim)
			end
			if not canRecordReceipt(offlineData, purchaseId, nil, userId, route) then
				error("receipt history full", 0)
			end
			reservedRaw(offlineData).ReceiptReservations[purchaseId] = route
			record, fromAim = route, route.FromAim
		end)
		if not reservedOk then
			return NOT_PROCESSED
		end
		if completed then
			return GRANTED
		end
		local recipientId = record.RecipientId
		local giftId = record.GiftId

		-- Same recipient re-check as the online intent path: a no-op delivery burns the
		-- buyer's Robux, so convert to a credit, but only if this exact purchase is undelivered.
		local convertToCredit = false
		if
			product.Grants
			and not product.Grant
			and not allowDuplicateGifts
			and recipientAlreadyOwns(recipientId, product.Grants)
		then
			local delivered = giftAlreadyDelivered(recipientId, purchaseId)
			if delivered == nil then
				return retryGiftRoute(userId, product, purchaseId)
			end
			convertToCredit = not delivered
		end
		if convertToCredit then
			local ok = ctx.Persistence.UpdateOffline(userId, function(offlineData)
				-- The dedupe marker, re-read INSIDE the transaction: the decision above was
				-- made against a GetOffline snapshot, so a cycle that committed in between is
				-- invisible both to it and to the compare-and-set, whose fingerprint is by
				-- now the fresh one. Returning early still commits the unchanged draft, so
				-- the caller answers GRANTED, which is correct: the purchase IS granted, just
				-- not by this cycle.
				if isProcessedRaw(offlineData, purchaseId) then
					return
				end
				local offlineReserved = reservedRaw(offlineData)
				-- Clear OUR record, and only ours. Re-reading the slot inside the transform
				-- is NOT this guard: the decision that this receipt owns one was made from a
				-- snapshot taken before two round trips, and a second gift of the same
				-- product can hold the slot by now with the key unlocked, so nothing refuses.
				-- Identity is the GiftId, never the slot.
				clearGiftRecordRaw(offlineReserved, productIdStr, giftId)
				offlineReserved.GiftCredits[product.Name] = (tonumber(offlineReserved.GiftCredits[product.Name]) or 0)
					+ 1
				robuxLogRaw(offlineData, {
					PurchaseId = purchaseId,
					Product = product.Name,
					Category = product.Category,
					PriceInRobux = receiptInfo.CurrencySpent,
					From = { Type = "GiftCredit", IntendedFor = recipientId },
					Ts = Clock.Now(),
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
			-- Keep retry activity current without modifying a replacement record.
			ctx.Persistence.UpdateOffline(userId, function(offlineData)
				local offlineReserved = reservedRaw(offlineData)
				local live = offlineReserved[giftRecordKey(fromAim)][productIdStr]
				if type(live) == "table" and tostring(live.GiftId) == giftId then
					live.Ts = Clock.Now()
				end
			end)
			return NOT_PROCESSED
		end
		local ok = ctx.Persistence.UpdateOffline(userId, function(offlineData)
			-- The dedupe marker, re-read INSIDE the transaction; see the credit arm above.
			pruneProcessedRaw(offlineData)
			if isProcessedRaw(offlineData, purchaseId) then
				return
			end
			local offlineReserved = reservedRaw(offlineData)
			-- Clear OUR record, and only ours. The decision that this receipt owns one was
			-- made from a snapshot taken before deliverGift's cross-server round trip, and a
			-- second gift of the same product can hold the slot by now. Identity is the
			-- GiftId, never the slot.
			clearGiftRecordRaw(offlineReserved, productIdStr, giftId)
			robuxLogRaw(offlineData, {
				PurchaseId = purchaseId,
				Product = product.Name,
				Category = product.Category,
				PriceInRobux = receiptInfo.CurrencySpent,
				-- IntendedFor only on an aim-settled line; see the online arm.
				From = {
					Type = "GiftSent",
					ToUserId = recipientId,
					GiftId = giftId,
					IntendedFor = if fromAim then recipientId else nil,
				},
				Ts = Clock.Now(),
			})
			markProcessedRaw(offlineData, purchaseId)
		end)
		return if ok then GRANTED else NOT_PROCESSED
	end

	-- Player left mid-receipt: grant via UpdateOffline where that is safely expressible
	-- (perk products), else NotProcessedYet.
	local function handleOfflineReceipt(
		userId: number,
		product: Product,
		receiptInfo: any
	): Enum.ProductPurchaseDecision
		local purchaseId = tostring(receiptInfo.PurchaseId)
		local data = ctx.Persistence.GetOffline(userId)
		if not data then
			-- No profile, or the offline read failed (GetOffline logs that separately).
			-- Either way this receipt is undebuggable without the PurchaseId.
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
		local route, invalid = readReceiptRoute(reserved, purchaseId, product)
		if invalid then
			return retryGiftRoute(userId, product, purchaseId)
		end
		if route then
			return settleOfflineGift(userId, product, receiptInfo, route, route.FromAim)
		end
		if
			(canInferGift(receiptInfo) or reserved.ReceiptReservations[purchaseId] == true)
			and not checkGiftSlots(reserved, userId, product, purchaseId)
		then
			return NOT_PROCESSED
		end
		if
			hasConflictingGiftRecords(reserved, product.Id)
			and (canInferGift(receiptInfo) or reserved.ReceiptReservations[purchaseId] == true)
		then
			return retryGiftRoute(userId, product, purchaseId)
		end
		if reserved.ReceiptReservations[purchaseId] == true then
			local legacyIntent = readGiftRecord(reserved, false, product)
			local legacyRecord = legacyIntent or readGiftRecord(reserved, true, product)
			if legacyRecord == nil then
				return retryGiftRoute(userId, product, purchaseId)
			end
			return settleOfflineGift(userId, product, receiptInfo, legacyRecord, legacyIntent == nil)
		end
		local inferGift = canInferGift(receiptInfo)
		local intent = if inferGift then reserved.PendingGifts[tostring(product.Id)] else nil
		-- Mirror intentFor's reused-Id guard: an intent whose stored Product name differs
		-- belongs to a retired product that reused this Id. Treat as no-intent.
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
		if type(intent) == "table" then
			return settleOfflineGift(userId, product, receiptInfo, intent, false)
		end

		-- NO LIVE INTENT, offline: the same two questions the online arm asks, in the same
		-- order. Both are here because the arm a receipt takes depends only on whether the
		-- buyer is still on this server, which is not a fact about the purchase.
		local record, fromAim = readGiftRecord(reserved, false, product), false
		if record == nil then
			record = readGiftRecord(reserved, true, product)
			fromAim = record ~= nil
		end
		if record then
			local aimedAt = tonumber(record.RecipientId) or 0
			local presumable = inferGift and fromAim
			local delivered = if presumable then true else giftAlreadyDelivered(aimedAt, purchaseId)
			if delivered == nil then
				return retryGiftRoute(userId, product, purchaseId)
			end
			if delivered then
				if fromAim then
					Log.Warn(
						"Gifting",
						"GIFT_AIM_SETTLED",
						"a receipt arrived after its gift intent had been swept; settling it from the durable aim "
							.. "instead of granting it to the buyer",
						{
							UserId = userId,
							Product = product.Name,
							PurchaseId = purchaseId,
							RecipientId = aimedAt,
						}
					)
					Metrics.Add("GiftAimsSettled")
				end
				return settleOfflineGift(userId, product, receiptInfo, record, fromAim)
			end
		end

		if product.Grants and not product.Grant then
			local perkKey = product.Grants :: string
			-- Pass-aware ownership, matching the online path, so an offline buyer who owns
			-- the pass is not re-granted.
			local ownsPerk = reserved.Perks[perkKey] == true or recipientAlreadyOwns(userId, perkKey)
			-- Online parity: hold an owned-perk purchase for retry instead of crediting.
			if ownsPerk and noGiftIntentPolicy == "Hold" then
				Metrics.Add("ReceiptsRetried")
				return NOT_PROCESSED
			end
			-- Same rule as the online path: owned perk plus an unused credit means this
			-- purchase could only stack another credit, so decline it.
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
				-- The dedupe marker, re-read INSIDE the transaction; see settleOfflineGift.
				pruneProcessedRaw(offlineData)
				if isProcessedRaw(offlineData, purchaseId) then
					return
				end
				if not canRecordReceipt(offlineData, purchaseId, nil, userId) then
					error("receipt history full", 0)
				end
				local offlineReserved = reservedRaw(offlineData)
				-- ownsPerk is pass-aware and resolved before the transaction; the in-txn
				-- flag re-check guards against a concurrent change.
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
					Ts = Clock.Now(),
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
		-- Consumable Grant functions need a live tree; Roblox retries, including on the
		-- player's next session.
		Metrics.Add("ReceiptsRetried")
		return NOT_PROCESSED
	end

	local function processReceipt(userId: number, product: Product, receiptInfo: any): Enum.ProductPurchaseDecision
		if promptStopped or ctx.Persistence.Stopped or ctx.Persistence.Closing then
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end
		local productId = product.Id
		local entry: { [string]: any }? = ctx.Persistence.EntryForUserId(userId)
		local player = if entry then entry.Player else Players:GetPlayerByUserId(userId)
		if player and (not entry or entry.State ~= "Ready") then
			-- Join receipts can arrive before Scribe starts or finishes loading.
			local timeout = math.max(60, tonumber(options.LoadTimeout) or 120)
			local data = ctx.Persistence.WaitForData(player, timeout)
			entry = ctx.Persistence.EntryForUserId(userId)
			if
				promptStopped
				or ctx.Persistence.Stopped
				or ctx.Persistence.Closing
				or not data
				or not entry
				or entry.Player ~= player
				or entry.State ~= "Ready"
				or entry.TornDown
			then
				Metrics.Add("ReceiptsRetried")
				return NOT_PROCESSED
			end
		end
		if entry and entry.State == "Ready" then
			pruneProcessed(entry)
		end
		if
			product.PaidRandom
			and entry
			and entry.Policy
			and entry.Policy.Phase == "known"
			and entry.Policy.Restricted
			and not isProcessed(entry, tostring(receiptInfo.PurchaseId))
		then
			-- External sales bypass prompt checks; the buyer has already paid.
			Log.Warn(
				"Monetization",
				"PAID_RANDOM_RECEIPT",
				`receipt for paid random product "{product.Name}" from a player whose policy restricts it; granted`,
				{ Player = entry.Player, ProductId = productId }
			)
		end
		if entry and entry.State == "Ready" and isProcessed(entry, tostring(receiptInfo.PurchaseId)) then
			Metrics.Add("ReceiptsDuplicate")
			-- Logged as well as counted: the metric alone leaves an operator with no
			-- per-receipt record to correlate.
			Log.Info("Monetization", "RECEIPT_DUPLICATE", "duplicate receipt acknowledged", {
				Player = entry.Player,
				PurchaseId = tostring(receiptInfo.PurchaseId),
				ProductId = productId,
			})
			-- Acknowledge a duplicate only when the grant that set this marker is durable.
			-- Dirty alone is not enough: it resets when a save's payload is serialized, so a
			-- clean flag with a save still in flight means the covering save may yet fail,
			-- and a crash after GRANTED would lose both the grant and the marker.
			if (not entry.SaveInfo.Dirty and entry.SavesInFlight == 0) or ctx.Persistence.AwaitSave(entry, 10) then
				return GRANTED
			end
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		if Health.GetStatus() == "Outage" then
			-- Outage policy: never eat Robux.
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		if entry and entry.State == "Ready" then
			local release = reserveReceipt(entry, tostring(receiptInfo.PurchaseId))
			if not release then
				Metrics.Add("ReceiptsRetried")
				return NOT_PROCESSED
			end
			local ok, result = pcall(handleOnlineReceipt, entry, product, receiptInfo)
			release()
			if not ok then
				error(result, 0)
			end
			return result
		end
		return handleOfflineReceipt(userId, product, receiptInfo)
	end

	-- Unknown products fall through only when an external receipt router owns them.
	local function handleReceipt(receiptInfo: any, strict: boolean): Enum.ProductPurchaseDecision?
		local userId = tonumber(receiptInfo.PlayerId) or 0
		local productId = tonumber(receiptInfo.ProductId) or 0
		local product = productsById[productId]
		if not product then
			if not strict then
				return nil
			end
			Metrics.Add("ReceiptsReceived")
			Log.Error(
				"Monetization",
				"RECEIPT_UNKNOWN_PRODUCT",
				`receipt for unregistered product {productId}: register it in Products`,
				{ UserId = userId, ProductId = productId }
			)
			return NOT_PROCESSED
		end
		Metrics.Add("ReceiptsReceived")

		-- Claim before waiting so duplicate callbacks cannot queue another grant.
		local flightKey = `{userId}|{tostring(receiptInfo.PurchaseId)}`
		if receiptsInFlight[flightKey] then
			Metrics.Add("ReceiptsRetried")
			Log.Warn(
				"Monetization",
				"RECEIPT_IN_FLIGHT",
				"the same receipt is already being processed on this server; letting Roblox retry",
				{ UserId = userId, PurchaseId = tostring(receiptInfo.PurchaseId), ProductId = product.Id }
			)
			return NOT_PROCESSED
		end
		receiptsInFlight[flightKey] = true
		-- Release the claim even if loading or granting throws.
		local dispatchOk, decision = pcall(processReceipt, userId, product, receiptInfo)
		receiptsInFlight[flightKey] = nil
		if not dispatchOk then
			error(decision, 0)
		end
		return decision
	end

	function self.HandleReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
		return handleReceipt(receiptInfo, true) :: Enum.ProductPurchaseDecision
	end

	function self.TryHandleReceipt(receiptInfo: any): Enum.ProductPurchaseDecision?
		return handleReceipt(receiptInfo, false)
	end

	-- Gifting flow --------------------------------------------------------------------

	--- What a finished gamepass purchase does. Named rather than inline in the Connect so a
	--- spec can drive it: a real RBXScriptSignal has no Fire, so the only other way to
	--- reach this is a real purchase.
	function self.OnPassPurchaseFinished(player: Player, passId: number, purchased: boolean)
		if not purchased then
			return
		end
		local passName = passNamesById[passId]
		if not passName then
			return
		end
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return
		end
		-- CONFIRM BEFORE CREDITING. This reports that the purchase DIALOG closed, not a
		-- completed transaction: a gamepass has no ProcessReceipt to be authoritative. The
		-- session cache would heal on the next join, but robuxLog writes the PERSISTED
		-- purchase history, so an unconfirmed event falsifies it.
		Sched.Spawn(function()
			local ok, owned = pcall(function()
				return userOwnsGamePass(entry.UserId, passId)
			end)
			if entry.TornDown then
				return
			end
			if not ok or owned ~= true then
				-- Self-heals: the join scan re-resolves every declared pass, so a real
				-- purchase the API had not caught up with is credited on the next load.
				Metrics.Add("PassPurchasesUnconfirmed")
				Log.Warn(
					"Monetization",
					"PASS_PURCHASE_UNCONFIRMED",
					if ok then "ownership check says not owned" else tostring(owned),
					{ Player = player, Pass = passName, PassId = passId, Errored = not ok }
				)
				return
			end
			setOwnsCache(entry, passName, true)
			robuxLog(entry, {
				PurchaseId = `pass:{passId}:{Clock.Now()}`,
				Product = passName,
				Category = passesByName[passName].Category or "Gamepass",
				From = { Type = "GamePass" },
				Ts = Clock.Now(),
			})
			ctx.Persistence.AwaitSave(entry, 15)
		end)
	end

	-- Client requests and direct server calls share the same eligibility gate and
	-- active dialog. A request carries a registry name, never an arbitrary asset ID.
	function self.PromptPurchase(player: Player, name: string): (boolean, string?)
		local product = productsByName[name]
		local pass = passesByName[name]
		if not product and not pass then
			return false, `unknown product or pass "{name}"`
		end
		local entry = ctx.Persistence.EntryFor(player)
		if promptStopped or not entry or entry.State ~= "Ready" or entry.TornDown then
			return false, "not-loaded"
		end
		finishCancellation(player)
		if promptStopped or entry.State ~= "Ready" or entry.TornDown or ctx.Persistence.EntryFor(player) ~= entry then
			return false, "not-loaded"
		end
		local state = productState(entry, name, product, pass)
		if state ~= "purchasable" then
			if state == "paid-random-restricted" or state == "policy-pending" then
				Metrics.Add("PaidRandomRefused")
			end
			return false, state
		end

		if purchasePrompts[player] or (product and hasPendingGift(entry, product.Id)) then
			return false, "purchase prompt already open"
		end
		local promptId = if pass then pass.Id else (product :: Product).Id
		local prompt = if pass then promptGamePassPurchase else promptProductPurchase
		local pending: PurchasePrompt = { Entry = entry, Closed = false }
		purchasePrompts[player] = pending
		local prompted = false

		-- Subscribe before prompting: even a prompt which closes immediately releases
		-- its guard. The listener exists only while this player's dialog is active.
		local ok, err = pcall(function()
			local finished = if pass
				then options.PromptGamePassPurchaseFinished or MarketplaceService.PromptGamePassPurchaseFinished
				else options.PromptProductPurchaseFinished or MarketplaceService.PromptProductPurchaseFinished
			local connection = finished:Connect(function(target: any, finishedId: number)
				local matchingPlayer = if pass then target == player else target == entry.UserId
				if matchingPlayer and finishedId == promptId and ctx.Persistence.EntryFor(player) == entry then
					clearPurchasePrompt(player, pending)
				end
			end)
			pending.Connection = connection
			-- A test seam may yield or run teardown from Connect. Never leave its late
			-- connection attached, nor prompt for a session that ended in that gap.
			if
				pending.Closed
				or promptStopped
				or entry.State ~= "Ready"
				or entry.TornDown
				or ctx.Persistence.EntryFor(player) ~= entry
			then
				clearPurchasePrompt(player, pending)
				return
			end
			prompt(player, promptId)
			prompted = true
		end)
		if not ok then
			clearPurchasePrompt(player, pending)
			return false, `purchase prompt failed: {err}`
		end
		if not prompted then
			return false, "not-loaded"
		end
		Metrics.Add("PurchasePrompts")
		return true, nil
	end

	local function promptGift(
		buyer: Player,
		productName: string,
		recipientUserId: number,
		pending: PurchasePrompt?
	): (boolean, string?)
		local product = productsByName[productName] or retiredByName[productName]
		if not product then
			return false, `unknown product "{productName}"`
		end
		local entry = ctx.Persistence.EntryFor(buyer)
		if promptStopped or not entry or entry.State ~= "Ready" or entry.TornDown then
			return false, "buyer data not loaded"
		end
		if product.Retired and (tonumber(reservedRaw(entry.LiveData).GiftCredits[productName]) or 0) <= 0 then
			return false, "product retired"
		end
		if type(recipientUserId) ~= "number" or recipientUserId <= 0 or recipientUserId % 1 ~= 0 then
			return false, "invalid recipient"
		end
		if recipientUserId == entry.UserId then
			return false, "cannot gift yourself"
		end
		if product.PaidRandom then
			local refused = paidRandomState(entry)
			if refused == nil then
				-- Readable only for a Player on this server; anyone else stays unknown.
				local recipientEntry = ctx.Persistence.EntryForUserId(recipientUserId)
				if recipientEntry and recipientEntry.State == "Ready" then
					refused = paidRandomState(recipientEntry)
				else
					refused = "policy-pending"
				end
			end
			if refused ~= nil then
				Metrics.Add("PaidRandomRefused")
				return false, PAID_RANDOM_REASON[refused]
			end
		end

		-- Anti-abuse: per-sender cooldown + max pending gifts.
		local now = Clock.Monotonic()
		if now - entry.GiftLastAt < giftCooldown then
			return false, "gift cooldown"
		end
		if Util.count(reservedRaw(entry.LiveData).PendingGifts) >= giftMaxPending then
			return false, "too many pending gifts"
		end
		-- Reserve archive capacity before opening a paid prompt.
		local productIdStr = tostring(product.Id)
		-- Count each product once across active and archived intents.
		local function aimStoreIsFull(): boolean
			local live = reservedRaw(entry.LiveData)
			local aims, intents = live.GiftAims, live.PendingGifts
			if aims[productIdStr] ~= nil or intents[productIdStr] ~= nil then
				return false
			end
			local reservedSlots = Util.count(aims)
			for pendingIdStr in intents do
				if aims[pendingIdStr] == nil then
					reservedSlots += 1
				end
			end
			return reservedSlots >= giftAimCap
		end
		if aimStoreIsFull() then
			Log.Warn(
				"Gifting",
				"GIFT_AIM_CAP_REACHED",
				`the gift aim store is at its cap ({giftAimCap}); refusing the prompt rather than taking money for `
					.. "a gift whose recipient could not be recorded durably",
				{ Player = buyer, Product = productName }
			)
			return false, "too many unsettled gift purchases; try again later"
		end
		if Health.GetStatus() == "Outage" then
			-- Cannot durably record intent, so never take money.
			return false, "data services are experiencing issues; try again later"
		end

		-- Charge the sender's cooldown BEFORE the first expensive step: recipientAlreadyOwns
		-- issues a full-profile GetAsync for an offline recipient, and with the stamp below
		-- it a refused prompt left the cooldown unspent, letting one sender repeat that work
		-- without limit. The checks above are local and cheap, so they still cost nothing.
		entry.GiftLastAt = now

		-- Step 1: duplicate guard.
		if product.Grants and not allowDuplicateGifts then
			if recipientAlreadyOwns(recipientUserId, product.Grants) then
				return false, "recipient already owns this"
			end
		end

		-- recipientAlreadyOwns YIELDED, so the buyer has had a round trip in which to leave.
		-- Every step below writes through the accessor tree and a torn-down tree RAISES,
		-- which is the one thing PromptGift is documented not to do: its contract is
		-- (false, reason). It sits here because both the credit path and the intent path
		-- take their first accessor write after this point.
		--
		-- State, not entry.Tree.Dead: teardown sets SessionEnded before it destroys the tree,
		-- so State is the strictly earlier signal and also covers the window where the
		-- session is going away but the tree is still alive.
		if promptStopped or entry.State ~= "Ready" or entry.TornDown or ctx.Persistence.EntryFor(buyer) ~= entry then
			return false, "buyer data not loaded"
		end

		-- Step 2: credit consumption. No purchase prompt, no charge.
		local reserved = reservedRaw(entry.LiveData)
		local credits = tonumber(reserved.GiftCredits[productName]) or 0
		if credits > 0 then
			local giftId = Util.guid()
			local creditAccessor = reservedAcc(entry).GiftCredits[productName]
			-- Refunds re-read the live count instead of restoring the stale pre-read value: a
			-- receipt retry can issue a credit during the yields below, and an absolute
			-- restore would erase it. Both steps between the spend and this refund yield, so
			-- the buyer can be gone by the time a delivery failure brings us back here;
			-- writing through the accessor would raise on the dead tree and skip the refund
			-- on a credit that is PAID FOR, so a departed buyer goes through UpdateOffline.
			local function refundCredit()
				if entry.State == "Ready" and not entry.Tree.Dead then
					creditAccessor.Set((tonumber(creditAccessor.Get()) or 0) + 1)
					return
				end
				local restored, why = ctx.Persistence.UpdateOffline(entry.UserId, function(offlineData)
					local offlineReserved = reservedRaw(offlineData)
					local have = tonumber(offlineReserved.GiftCredits[productName]) or 0
					offlineReserved.GiftCredits[productName] = have + 1
				end)
				if not restored then
					Failure.Report({
						Subsystem = "GiftCredit",
						Key = tostring(entry.UserId),
						Category = "Gifting",
						Code = "GIFT_CREDIT_REFUND_FAIL",
						Message = "the buyer left during a gift delivery that failed, and the paid credit "
							.. "could not be restored to their stored profile; it is lost",
						Context = { UserId = entry.UserId, Product = productName, Reason = why },
					})
				end
			end
			-- Reserve the credit DURABLY before delivering, so a crash can never restore a
			-- consumed credit after the gift has already gone out.
			creditAccessor.Set(if credits - 1 > 0 then credits - 1 else nil)
			if not ctx.Persistence.AwaitSave(entry, 10) then
				refundCredit()
				return false, "could not reserve gift credit; try again later"
			end
			-- ONE RULE AT TWO GATES: prefer a bounded value loss over a double grant. This
			-- spend has no id a retry could reuse, so a credit handed back can buy a SECOND
			-- grant under a purchaseId the recipient's receipt history has never seen.
			-- First gate, on `applied` not `durable`: a same-server grant is marked processed
			-- under this giftId and persists on the next save. Second gate, on `refundable`:
			-- MessageAsync can commit and lose its answer. A raise out of deliverGift would
			-- unwind past both gates, so it is caught and read as AMBIGUOUS.
			local deliveryOk, applied, _, refundable =
				pcall(deliverGift, product, recipientUserId, `credit:{giftId}`, giftId, entry.UserId)
			local deliveryError = if deliveryOk then nil else tostring(applied)
			if not deliveryOk then
				-- `applied` currently holds the error message, which is truthy. Both values are
				-- forced to the ambiguous reading before either gate reads them, so a raise can
				-- neither report a delivery nor buy a refund.
				applied, refundable = false, false
			end
			if not applied and refundable then
				refundCredit()
				Sched.Spawn(function()
					ctx.Persistence.AwaitSave(entry, 15)
				end)
				return false, "could not deliver gift; try again later"
			end
			if not applied then
				-- Ambiguous. The credit STAYS SPENT and the buyer is told not to send it again,
				-- because the alternative is the double grant above. No save is spawned as the
				-- refund arm does one: the spend was already made durable. Loud, because this
				-- is the one outcome where a player is out paid value with no retry that would
				-- help. Log.Warn rather than Failure.Report: deliverGift already reported this
				-- once, and a second report would count one fault twice against the health window.
				Metrics.Add("GiftCreditsUnconfirmed")
				Log.Warn(
					"Gifting",
					"GIFT_CREDIT_UNCONFIRMED",
					"the gift delivery neither succeeded nor provably failed, so the paid credit was NOT handed "
						.. "back: the gift may already be queued, and refunding would let one payment be spent "
						.. "again under a new id and grant twice",
					{
						Player = buyer,
						Product = productName,
						RecipientId = recipientUserId,
						GiftId = giftId,
						-- Present only when the delivery RAISED, which is a bug in
						-- this file rather than a DataStore fault.
						Error = deliveryError,
					}
				)
				return false, "gift delivery could not be confirmed; do not send it again"
			end
			Log.Info("Gifting", "GIFT_CREDIT_USED", "gift delivered from an unassigned credit", {
				Player = buyer,
				Product = productName,
				RecipientId = recipientUserId,
			})
			return true, nil
		end

		if product.Retired then
			return false, "product retired"
		end

		-- Recheck after recipient lookups: no yield may replace an unresolved destination.
		if not pending or pending.Closed or purchasePrompts[buyer] ~= pending or hasPendingGift(entry, product.Id) then
			return false, "a gift of this item is already pending; try again shortly"
		end
		local giftId = Util.guid()
		local intentAccessor = reservedAcc(entry).PendingGifts[productIdStr]
		intentAccessor.Set({
			RecipientId = recipientUserId,
			GiftId = giftId,
			Ts = Clock.Now(),
			Product = productName,
		})
		-- Roll back only this attempt, never a replacement written during the save.
		if not ctx.Persistence.AwaitSave(entry, 10) then
			cancelUnopenedGift(entry, productIdStr, giftId, pending)
			Log.Error("Gifting", "GIFT_INTENT_WRITE_FAIL", "could not durably record gift intent; refusing prompt", {
				Player = buyer,
				Product = productName,
			})
			return false, "could not record gift intent; try again later"
		end

		local function stillCurrent(): boolean
			local live = reservedRaw(entry.LiveData).PendingGifts[productIdStr]
			return not promptStopped
				and not pending.Closed
				and purchasePrompts[buyer] == pending
				and entry.State == "Ready"
				and not entry.TornDown
				and ctx.Persistence.EntryFor(buyer) == entry
				and type(live) == "table"
				and live.GiftId == giftId
		end
		if not stillCurrent() then
			cancelUnopenedGift(entry, productIdStr, giftId, pending)
			return false, "buyer data not loaded"
		end

		local opened = false
		local ok, err = pcall(function()
			local finished = options.PromptProductPurchaseFinished or MarketplaceService.PromptProductPurchaseFinished
			local connection = finished:Connect(function(userId: number, finishedId: number, purchased: boolean)
				if not opened or pending.Closed or pending.Cancelled or purchasePrompts[buyer] ~= pending then
					return
				end
				if userId ~= entry.UserId or finishedId ~= product.Id or ctx.Persistence.EntryFor(buyer) ~= entry then
					return
				end
				if purchased == false and cancelGiftRecord(entry, productIdStr, giftId) then
					-- Save cancellation before another receipt can be prompted.
					pending.Cancelled = true
					finishCancellation(buyer)
					return
				end
				clearPurchasePrompt(buyer, pending)
			end)
			pending.Connection = connection
			if not stillCurrent() then
				clearPurchasePrompt(buyer, pending)
				return
			end
			opened = true
			promptProductPurchase(buyer, product.Id)
		end)
		if not ok then
			cancelUnopenedGift(entry, productIdStr, giftId, pending)
			return false, `purchase prompt failed: {err}`
		end
		if not opened then
			cancelUnopenedGift(entry, productIdStr, giftId, pending)
			return false, "buyer data not loaded"
		end
		Metrics.Add("GiftPrompts")
		return true, nil
	end

	function self.PromptGift(buyer: Player, productName: string, recipientUserId: number): (boolean, string?)
		finishCancellation(buyer)
		local entry = ctx.Persistence.EntryFor(buyer)
		local product = productsByName[productName] or retiredByName[productName]
		if not product or product.Retired or promptStopped or not entry or entry.State ~= "Ready" or entry.TornDown then
			return promptGift(buyer, productName, recipientUserId, nil)
		end
		-- Credits create no purchase dialog or unbound receipt.
		if (tonumber(reservedRaw(entry.LiveData).GiftCredits[productName]) or 0) > 0 then
			return promptGift(buyer, productName, recipientUserId, nil)
		end
		if purchasePrompts[buyer] or hasPendingGift(entry, product.Id) then
			return false, "a gift of this item is already pending; try again shortly"
		end
		local pending: PurchasePrompt = { Entry = entry, Closed = false }
		purchasePrompts[buyer] = pending
		local ok, prompted, reason = pcall(promptGift, buyer, productName, recipientUserId, pending)
		if (not ok or not prompted) and not pending.Cancelled then
			clearPurchasePrompt(buyer, pending)
		end
		if not ok then
			error(prompted, 0)
		end
		-- A credit could have arrived during the recipient lookup.
		if pending.Connection == nil and not pending.Cancelled then
			clearPurchasePrompt(buyer, pending)
		end
		return prompted, reason
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
		record.Ts = record.Ts or Clock.Now()
		appendRing(reservedAcc(entry).PurchaseLogs.InGame, inGameCap, record)
	end

	function self.GetPurchases(player: Player, filter: { [string]: any }?): { { [string]: any } }
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return {}
		end
		local reserved = reservedRaw(entry.LiveData)
		local out: { { [string]: any } } = {}
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

	-- Atomic soft-currency purchase: check funds, debit, grant, log and emit analytics
	-- inside a Transaction. A throwing Grant rolls everything back.
	function self.Purchase(player: Player, spec: { [string]: any }): (boolean, string?)
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return false, "player data not loaded"
		end
		if spec.PaidRandom == true then
			local refused = paidRandomState(entry)
			if refused ~= nil then
				Metrics.Add("PaidRandomRefused")
				return false, PAID_RANDOM_REASON[refused]
			end
		end
		-- Optional caller-supplied idempotency key. Deliberately NOT stored in
		-- _Scribe.ProcessedPurchaseIds: ordinary shop claims should expire independently.
		local idemKey = spec.IdempotencyKey
		if idemKey ~= nil then
			-- Wire's cap, read at the use site rather than aliased: a local literal is how
			-- this path came to enforce its own 64 while Wire's comment claimed it was shared.
			if type(idemKey) ~= "string" or idemKey == "" or #idemKey > Wire.MAX_IDEMPOTENCY_KEY_BYTES then
				return false, "invalid IdempotencyKey"
			end
			-- The key becomes a raw persisted table key, bypassing the accessor write
			-- guard, so invalid UTF-8 would fail the whole profile save.
			if not Util.isUtf8(idemKey) then
				return false, "invalid IdempotencyKey"
			end
		end

		local cost = spec.Cost
		if type(cost) ~= "table" or type(cost.Path) ~= "string" or type(cost.Amount) ~= "number" then
			return false, "invalid Cost spec"
		end
		local amount: number = cost.Amount
		-- A non-positive amount would pass the funds check and CREDIT currency while
		-- still granting the item.
		if amount <= 0 or amount ~= amount then
			return false, "invalid Cost amount"
		end
		local costPath = Util.parsePath(cost.Path)
		-- The index walk can THROW for a path that typos a closed element field, and a
		-- bad cost path must come back as (false, err) like every other Purchase refusal.
		local walked, costAccessor = pcall(function()
			local acc = entry.Tree.Accessor
			for _, segment in costPath do
				acc = acc[segment]
			end
			return acc
		end)
		if not walked then
			return false, "invalid cost path"
		end
		-- Follow the schema the way the accessor above does. Template.Resolve descends
		-- node.Children only, so a DictOf/ArrayOf element would stop the walk at the
		-- container, silently disabling the fractional-amount guard and flooring Min at 0.
		local costSchema, dynStart = Template.Resolve(compiled, costPath :: { string | number })
		for i = dynStart, #costPath do
			local next_ = Template.ChildSchema(costSchema, costPath[i])
			if next_ == nil then
				break
			end
			costSchema = next_
		end
		-- A fractional amount on an int currency rounds the debit toward zero, or to no
		-- debit at all, while the grant still runs.
		if costSchema.ValueType == "int" and amount % 1 ~= 0 then
			return false, "invalid Cost amount"
		end
		local floor: number = costSchema.Min or 0

		-- A DictOf currency key the player never touched reads nil, but the declared element
		-- default is its true balance, so without this a starting balance is unspendable.
		local isElementLeaf = false
		do
			local cursor: any = costSchema
			while cursor do
				if cursor.IsElement then
					isElementLeaf = true
					break
				end
				cursor = cursor.Parent
			end
		end
		local function readBalance(): any
			local value = costAccessor.Get()
			if value == nil and isElementLeaf and type(costSchema.Default) == "number" then
				return costSchema.Default
			end
			return value
		end

		-- Already granted under this key? Return the ORIGINAL outcome, matching the receipt
		-- path; the "this was a duplicate" signal goes to logs and metrics rather than into
		-- the return value, where a caller would have to special-case it.
		if idemKey ~= nil and ctx.Timed.IsClaimed(entry, PURCHASE_IDEM_PREFIX .. idemKey) then
			Metrics.Add("PurchasesDuplicate")
			Log.Info("Monetization", "PURCHASE_DUPLICATE", "purchase skipped: idempotency key already applied", {
				Player = player,
				Key = idemKey,
			})
			return true, nil
		end

		local current = readBalance()
		if type(current) ~= "number" then
			-- Two different refusals wearing one string. The accessor walk above already
			-- SUCCEEDED, so the path is not a typo: it resolved to something real that cannot
			-- be spent, Scribe.Big being the case that bites (stored as a table, while
			-- Purchase does plain arithmetic). Only for a DECLARED non-numeric type: an
			-- element of a dynamic container has no ValueType, and there the old string is
			-- still the honest answer.
			local valueType = costSchema.ValueType
			if valueType ~= nil and valueType ~= "any" and valueType ~= "int" and valueType ~= "number" then
				return false, "cost path is not a spendable number"
			end
			return false, "invalid cost path"
		end
		if current - amount < floor then
			return false, "insufficient funds"
		end

		local ok, err = entry.Tree:RunTransaction(function()
			local balance = readBalance()
			if balance - amount < floor then
				error("insufficient funds")
			end
			costAccessor.Set(balance - amount)
			if spec.Grant then
				(spec.Grant :: (any) -> ())(entry.Tree.Accessor)
			end
			checkCategory(spec.Category)
			-- Claimed INSIDE the transaction, so a Grant that throws rolls the claim back with
			-- the debit. A claim taken outside would survive the rollback and permanently
			-- block a retry of a purchase that never happened.
			if idemKey ~= nil then
				-- Make room INSIDE the transaction, so an eviction rolls back with its purchase.
				local dropped = ctx.Timed.PruneClaims(entry, PURCHASE_IDEM_PREFIX, purchaseClaimCap)
				if dropped > 0 then
					Log.Warn(
						"Monetization",
						"PURCHASE_CLAIM_EVICTED",
						`dropped {dropped} un-expired purchase idempotency claim(s) to stay under MaxPurchaseClaims `
							.. `({purchaseClaimCap}); a retry of one of them would apply the purchase again; `
							.. "raise the cap or shorten PurchaseClaimTTL",
						{ Player = player, Dropped = dropped, Cap = purchaseClaimCap }
					)
					Metrics.Add("PurchaseClaimsEvicted", dropped)
				end
				ctx.Timed.Claim(entry, PURCHASE_IDEM_PREFIX .. idemKey, purchaseClaimTTL)
			end
			appendRing(reservedAcc(entry).PurchaseLogs.InGame, inGameCap, {
				Category = spec.Category,
				ItemId = spec.ItemId,
				Currency = tostring(costPath[#costPath]),
				Amount = amount,
				Ts = Clock.Now(),
				Meta = spec.Meta,
			})
		end, seedWatcher(entry, `Data.Purchase "{tostring(spec.ItemId or spec.Category or "?")}"`))
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
		pruneProcessed(entry)
		-- Archive stale intents without discarding unresolved destinations.
		local reserved = reservedRaw(entry.LiveData)
		local now = Clock.Now()
		for productIdStr, intent in reserved.PendingGifts do
			if type(intent) ~= "table" or now - (tonumber(intent.Ts) or 0) > giftIntentTTL then
				if archiveGiftAim(entry, productIdStr, intent) then
					reservedAcc(entry).PendingGifts[productIdStr].Set(nil)
				end
			end
		end
		-- Time alone cannot prove an unresolved gift was cancelled.
		-- Gift credits are durable paid value keyed by product NAME, so a renamed or removed
		-- product silently strands them. Surface it, never delete: the credit is player money.
		for creditName, count in reserved.GiftCredits do
			if
				productsByName[creditName] == nil
				and retiredByName[creditName] == nil
				and (tonumber(count) or 0) > 0
			then
				Log.Warn(
					"Gifting",
					"GIFT_CREDIT_UNKNOWN_PRODUCT",
					`player holds {tostring(count)} gift credit(s) for "{tostring(creditName)}", which is not in Products; `
						.. "they are unspendable until the product returns or a migration renames the credit key",
					{ Player = entry.Player, Product = tostring(creditName) }
				)
			end
		end
		if next(passesByName) == nil then
			refreshOwnership(entry)
		else
			Sched.Spawn(refreshOwnership, entry)
		end
		watchOwnership(entry)
		-- Last and spawned: the hooks after this one end with the first snapshot.
		if anyPaidRandom then
			ensurePolicy(entry)
		end
	end

	function self.OnUnload(entry: any)
		local pending = purchasePrompts[entry.Player]
		if pending and pending.Entry == entry then
			clearPurchasePrompt(entry.Player, pending)
		end
		local watchers = entry.OwnsWatchers
		if watchers then
			entry.OwnsWatchers = nil
			for _, disconnect in watchers do
				disconnect()
			end
		end
	end

	local connections: { any } = {}
	function self.ListenerCount(): number
		return #connections
	end
	local boundReceipts = false

	function self.Start()
		-- Only take over ProcessReceipt when there are developer products to grant, so a
		-- data-only or pass-only game keeps its own receipt handler.
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
			boundReceipts = true
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

		if next(passesByName) ~= nil then
			connections[#connections + 1] = MarketplaceService.PromptGamePassPurchaseFinished:Connect(
				function(player: Player, passId: number, purchased: boolean)
					self.OnPassPurchaseFinished(player, passId, purchased)
				end
			)
		end

		connections[#connections + 1] = Players.PlayerMembershipChanged:Connect(function(player: Player)
			local entry = ctx.Persistence.EntryFor(player)
			if entry and entry.State == "Ready" then
				setOwnsCache(entry, "RobloxPlus", player.HasRobloxSubscription)
			end
		end)
	end

	-- Release the marketplace listeners and hand ProcessReceipt back. The receiptsBound
	-- guard is module-global, so leaving it set would make a later bundle in the same
	-- process throw even though nothing owns the handler.
	function self.Stop()
		promptStopped = true
		for player, pending in purchasePrompts do
			clearPurchasePrompt(player, pending)
		end
		for _, connection in connections do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(connections)
		if boundReceipts then
			boundReceipts = false
			receiptsBound = false
			pcall(function()
				MarketplaceService.ProcessReceipt = nil
			end)
		end
	end

	return self
end

return Monetization
