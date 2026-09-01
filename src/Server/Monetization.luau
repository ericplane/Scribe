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
local Failure = require(Internal.Failure)
-- For MAX_IDEMPOTENCY_KEY_BYTES only. Wire's own requires are Internal leaves, so
-- this adds no module to the bundle and no cycle.
local Wire = require(Internal.Wire)

local Monetization = {}

-- Shared across bundles via the require cache: ProcessReceipt is a single
-- global callback, so a second receipt-owning bundle would silently steal it.
local receiptsBound = false

local PROCESSED_CAP = 200 -- default ceiling on the receipt-dedupe ring
local PURCHASE_ID_TTL = 7 * 24 * 3600

-- Durable gift aims. The load sweep MOVES a stale gift intent into _Scribe.GiftAims
-- rather than deleting it, and the no-intent receipt paths consult it before granting
-- the buyer: without that record a late receipt is indistinguishable from a
-- self-purchase, so one payment produces two grants. This bounds how long the
-- recipient's identity must survive, so it is floored at purchaseIdTTL (see giftAimTTL).
local GIFT_AIM_TTL = 7 * 24 * 3600
-- Eviction is age-only: an aim inside the receipt-retry window may be the only record
-- of a gift already paid for, so at the cap the store refuses intake instead.
local GIFT_AIM_CAP = 64
-- Caller-supplied idempotency keys live in the Timed store under this prefix, which
-- keeps them out of the capped ProcessedPurchaseIds ring.
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
	-- never persisted; the ProcessedPurchaseIds ring is the only durable completion record.
	local receiptsInFlight: { [string]: true } = {}

	local giftCooldown: number = options.GiftCooldown or 5
	local giftMaxPending: number = options.GiftMaxPending or 20
	local giftIntentTTL: number = options.GiftIntentTTL or 3600
	local purchaseIdTTL: number = options.PurchaseIdTTL or PURCHASE_ID_TTL
	local processedCap: number = options.MaxProcessedPurchaseIds or PROCESSED_CAP
	-- Separate from PurchaseIdTTL, which governs Roblox's receipt-retry window where
	-- shortening risks double-granting real money. A caller-supplied Data.Purchase key is
	-- retried by the game within seconds, so it can be bounded here without touching that.
	local purchaseClaimTTL: number = options.PurchaseClaimTTL or purchaseIdTTL
	local purchaseClaimCap: number = math.max(1, tonumber(options.MaxPurchaseClaims) or PURCHASE_CLAIM_CAP)
	-- How long a same-product re-gift is blocked while a purchase could still be in flight,
	-- so a second gift cannot overwrite a live intent and misdeliver the first purchase.
	-- Past this a lingering intent is an abandoned prompt and may be overwritten.
	local giftPromptWindow: number = math.min(120, giftIntentTTL)
	-- A floor, never an alias: lengthening the receipt horizon lengthens this, and
	-- shortening PurchaseIdTTL cannot shorten it.
	local giftAimTTL: number = math.max(GIFT_AIM_TTL, purchaseIdTTL)
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

	-- Same seam as the prompt above: patching MarketplaceService itself is illegal on a
	-- real service Instance, so no ownership spec could run in Studio without it.
	local userOwnsGamePass: (userId: number, passId: number) -> boolean = options.UserOwnsGamePassAsync
		or function(userId: number, passId: number): boolean
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end

	-- Registry ----------------------------------------------------------------

	type Product = { Name: string, Id: number, Category: string?, Grant: ((data: any) -> ())?, Grants: string? }
	local productsByName: { [string]: Product } = {}
	local productsById: { [number]: Product } = {}
	for name, config in (options.Products or {}) :: { [string]: any } do
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
		-- One name, one thing. PromptPurchase resolves a name against both registries, so a
		-- name in both would leave resolution order deciding what the player is charged for.
		if productsByName[name] then
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
	for _, product in productsByName do
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
		for _, key in { "Perks", "ProcessedPurchaseIds", "PendingGifts", "GiftAims", "GiftCredits", "PurchaseLogs" } do
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

	-- A ring entry is `{ Id, At }`. Entries written before age-based eviction shipped are
	-- bare strings, and both forms have to read alike.
	local function processedId(item: any): string?
		if type(item) == "string" then
			return item
		end
		if type(item) == "table" then
			return item.Id
		end
		return nil
	end

	local function isProcessedRaw(data: { [string]: any }, purchaseId: string): boolean
		for _, item in reservedRaw(data).ProcessedPurchaseIds do
			if processedId(item) == purchaseId then
				return true
			end
		end
		return false
	end

	local function isProcessed(entry: any, purchaseId: string): boolean
		return entry.LiveData ~= nil and isProcessedRaw(entry.LiveData, purchaseId)
	end

	-- The ring is the only thing between a retried receipt and a second grant. Age is the
	-- primary rule: past PurchaseIdTTL a receipt is beyond any retry. The count backstop is
	-- for a player buying faster than the TTL drains, and it is the one eviction that can
	-- lose a live entry, so it says so. A legacy bare string is stamped with `now` rather
	-- than treated as expired; guessing old is precisely the guess that double-grants.
	local function pruneProcessed(list: { any }, player: any?): { any }
		local now = Clock.Now()
		local kept = {}
		for _, item in list do
			local id = processedId(item)
			if id == nil then
				continue -- unreadable entry; nothing can match it, so it only takes space
			end
			local at = if type(item) == "table" then tonumber(item.At) else nil
			if at == nil then
				table.insert(kept, { Id = id, At = now }) -- legacy: stamp, never assume old
			elseif now - at <= purchaseIdTTL then
				table.insert(kept, item)
			end
		end
		-- `while`, not `if`: a stored ring larger than the current cap must shrink back
		-- under it rather than stay frozen at its old size.
		local dropped = 0
		while #kept >= processedCap and #kept > 0 do
			table.remove(kept, 1)
			dropped += 1
		end
		if dropped > 0 then
			Log.Warn(
				"Monetization",
				"PURCHASE_ID_EVICTED",
				`dropped {dropped} un-expired purchase id(s) to stay under MaxProcessedPurchaseIds ({processedCap}); `
					.. `a receipt Roblox retries for one of them would be granted twice; raise the cap`,
				{ Player = player, Dropped = dropped, Cap = processedCap }
			)
			Metrics.Add("PurchaseIdsEvicted", dropped)
		end
		return kept
	end

	local function markProcessedRaw(data: { [string]: any }, purchaseId: string, player: any?)
		local reserved = reservedRaw(data)
		local kept = pruneProcessed(reserved.ProcessedPurchaseIds, player)
		table.insert(kept, { Id = purchaseId, At = Clock.Now() })
		reserved.ProcessedPurchaseIds = kept
	end

	local function markProcessed(entry: any, purchaseId: string)
		local accessor = reservedAcc(entry).ProcessedPurchaseIds
		local kept = pruneProcessed(accessor.Get(), entry.Player)
		table.insert(kept, { Id = purchaseId, At = Clock.Now() })
		-- One Set rather than a Remove loop plus an Insert: pruning rewrites the whole
		-- list, and a single op is what a surrounding Transaction rolls back cleanly.
		accessor.Set(kept)
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

	--- The stored record for this product, or nil unless it is complete and belongs to
	--- this product. A differing Product name means a retired product reused this Id, so
	--- the recipient was aimed at something else; a missing RecipientId is the phantom
	--- shape a blind `Ts` write leaves behind, and honouring one gifts to userId 0.
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
		if (tonumber(record.RecipientId) or 0) <= 0 or record.GiftId == nil then
			return nil
		end
		-- No age check here on purpose: the horizon bounds what a record may be PRESUMED
		-- to mean, not whether it may be read. A record past it can still prove a delivery.
		return record
	end

	--- Clear a gift record, and only if it is still ours. Every caller has yielded by the
	--- time it gets here, and a second PromptGift past giftPromptWindow can take the slot
	--- over: a blind clear would strand that gift, whose receipt then grants the perk to
	--- the buyer. Identity is the GiftId, never the slot.
	local function clearGiftRecord(entry: any, fromAim: boolean, productIdStr: string, giftId: string)
		local key = giftRecordKey(fromAim)
		local live = reservedRaw(entry.LiveData)[key][productIdStr]
		if type(live) == "table" and tostring(live.GiftId) == giftId then
			reservedAcc(entry)[key][productIdStr].Set(nil)
		end
	end

	--- The offline mirror, for use INSIDE an UpdateOffline transform where the slot
	--- has to be re-read against the compare-and-set's own draft.
	local function clearGiftRecordRaw(
		reserved: { [string]: any },
		fromAim: boolean,
		productIdStr: string,
		giftId: string
	)
		local container = reserved[giftRecordKey(fromAim)]
		local live = container[productIdStr]
		if type(live) == "table" and tostring(live.GiftId) == giftId then
			container[productIdStr] = nil
		end
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

	--- Reclaim room in the aim store, and say what it cost. Returns how many went.
	---
	--- Only aims past the presumption horizon are dropped; inside it an aim may be the last
	--- durable record of a gift already paid for, so at the cap the store refuses intake.
	--- Called on intake, not on load: an aim nobody competes for costs nothing to keep, and
	--- keeping it is what lets it still prove a delivery.
	local function reclaimGiftAims(entry: any): number
		local aims = reservedRaw(entry.LiveData).GiftAims
		local now = Clock.Now()
		local dropped = 0
		for productIdStr, aim in aims do
			if type(aim) == "table" and now - (tonumber(aim.Ts) or 0) <= giftAimTTL then
				continue
			end
			if type(aim) == "table" then
				Log.Warn(
					"Gifting",
					"GIFT_AIM_EXPIRED",
					"a gift aim past the receipt-retry horizon was dropped to make room; if Roblox ever retries "
						.. "its receipt it will now be granted to the buyer instead of the recipient",
					{
						Player = entry.Player,
						Product = tostring(aim.Product),
						RecipientId = tonumber(aim.RecipientId),
					}
				)
				Metrics.Add("GiftAimsExpired")
			end
			reservedAcc(entry).GiftAims[productIdStr].Set(nil)
			dropped += 1
		end
		return dropped
	end

	--- Move a stale intent into the aim store, called by the OnLoad sweep. Deleting it
	--- instead is what made a late receipt indistinguishable from a self-purchase. The cap
	--- refuses INTAKE, not eviction: a stored aim may be the only surviving record of a
	--- gift already paid for, so the NEW aim is refused and says so.
	local function archiveGiftAim(entry: any, productIdStr: string, intent: any)
		if type(intent) ~= "table" or (tonumber(intent.RecipientId) or 0) <= 0 or intent.GiftId == nil then
			return -- nothing to route a receipt with; the sweep just drops it
		end
		local function aimStoreIsFull(): boolean
			local aims = reservedRaw(entry.LiveData).GiftAims
			return aims[productIdStr] == nil and Util.count(aims) >= giftAimCap
		end
		if aimStoreIsFull() then
			reclaimGiftAims(entry) -- past-horizon aims only; re-read after it
		end
		if aimStoreIsFull() then
			Log.Warn(
				"Gifting",
				"GIFT_AIM_CAP_REACHED",
				`the gift aim store is at its cap ({giftAimCap}); this gift's recipient was not recorded, so a `
					.. "receipt Roblox retries for it will be granted to the buyer",
				{
					Player = entry.Player,
					Product = tostring(intent.Product),
					RecipientId = tonumber(intent.RecipientId),
				}
			)
			Metrics.Add("GiftAimsDropped")
			return
		end
		reservedAcc(entry).GiftAims[productIdStr].Set({
			RecipientId = tonumber(intent.RecipientId),
			GiftId = tostring(intent.GiftId),
			Ts = tonumber(intent.Ts) or Clock.Now(),
			Product = intent.Product,
		})
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

	local function setOwnsCache(entry: any, key: string, owned: boolean)
		if entry.Tree and not entry.Tree.Dead then
			entry.Tree.Accessor[Template.SESSION_ROOT].OwnsCache[key].Set(if owned then true else nil)
		end
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
					setOwnsCache(entry, name, owned == true)
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
					setOwnsCache(entry, key, owned == true)
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
	local function deliverGiftLocal(
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
			-- dedupe ring has never seen, so one credit grants twice. Not "was this the first
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
		-- Gate on `durable` (2nd return), NOT `applied` (1st): this queued message is the
		-- only surviving durable copy of the paid gift, and processed() removes it for good.
		-- Ack-ing a merely in-memory grant loses the gift on a crash.
		--
		-- Re-delivery is dedupe-safe for PurchaseIdTTL and NOT after: the recipient's
		-- ProcessedPurchaseIds ring expires and is capped, while the GlobalUpdates queue
		-- that re-delivers has no horizon at all. Closing that has a storage or correctness
		-- cost and is written up for the owner. Widening the TTL moves the boundary rather
		-- than removing it.
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
		if Clock.Now() - (tonumber(intent.Ts) or 0) > giftIntentTTL then
			-- Stale intent (abandoned prompt); the receipt follows the no-intent policy.
			reservedAcc(entry).PendingGifts[tostring(product.Id)].Set(nil)
			Log.Warn("Gifting", "GIFT_INTENT_EXPIRED", "stale gift intent expired", {
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
		local recipientId = tonumber(intent.RecipientId) or 0
		local giftId = tostring(intent.GiftId)
		local productIdStr = tostring(product.Id)

		-- The recipient may have acquired the perk between the prompt and the receipt, so
		-- delivering would be a no-op grant that burns the buyer's Robux; convert to a gift
		-- credit instead. Only if this purchase was not already delivered on a prior attempt
		-- whose buyer-commit failed, or one payment yields both a gift and a credit.
		if
			product.Grants
			and not product.Grant
			and not allowDuplicateGifts
			and recipientAlreadyOwns(recipientId, product.Grants)
			and giftAlreadyDelivered(recipientId, purchaseId) == false
		then
			local creditsAccessor = reservedAcc(entry).GiftCredits[product.Name]
			creditsAccessor.Set((tonumber(creditsAccessor.Get()) or 0) + 1)
			-- Clear OUR intent, and only ours: both legs of the condition above yield on the
			-- recipient's profile, and a second PromptGift past giftPromptWindow can take the
			-- one-per-product slot over inside that window. Identity is the GiftId, never the
			-- slot.
			clearGiftRecord(entry, fromAim, productIdStr, giftId)
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
			-- Not confirmed durable; the intent persists, the receipt retries and the retry
			-- dedupes on the recipient. Refresh the Ts so giftPromptWindow keeps refusing a
			-- second same-product gift while this paid purchase is still retrying, since an
			-- overwrite would route its value to the second recipient. deliverGift YIELDS, so
			-- the refresh re-checks the intent is still ours rather than materializing a
			-- phantom delivered to userId 0.
			refreshGiftRecordTs(entry, fromAim, productIdStr, giftId)
			Metrics.Add("ReceiptsRetried")
			return NOT_PROCESSED
		end

		-- Clear OUR intent, and only ours: deliverGift yielded above, so a second PromptGift
		-- past giftPromptWindow may hold the slot by now. Identity is the GiftId, never the slot.
		clearGiftRecord(entry, fromAim, productIdStr, giftId)
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

		-- Read the slot BEFORE intentFor, which clears it when it expires one. What is in
		-- it decides which of the two questions below may be asked.
		local staleIntent = readGiftRecord(reservedRaw(entry.LiveData), false, product)

		local intent = intentFor(entry, product)
		if intent then
			return handleGiftReceipt(entry, product, intent, receiptInfo, false)
		end

		-- NO LIVE INTENT. Two questions before the no-intent policy may grant this to the
		-- buyer. (1) PROOF: was THIS PurchaseId already delivered to the named recipient? A
		-- self-purchase's id never appears in another ring, so a hit is one payment and two
		-- grants. (2) PRESUMPTION: a record says a gift of this product was aimed and never
		-- settled. A guess, bounded to an ARCHIVED aim inside giftAimTTL. Past the horizon
		-- it falls through to the no-intent policy: value to the wrong player rather than a
		-- receipt refused forever. The proof leg still works past it.
		local record, fromAim = staleIntent, false
		if record == nil then
			record = readGiftRecord(reservedRaw(entry.LiveData), true, product)
			fromAim = record ~= nil
		end
		if record then
			local aimedAt = tonumber(record.RecipientId) or 0
			local presumable = fromAim and Clock.Now() - (tonumber(record.Ts) or 0) <= giftAimTTL
			-- `or` short-circuits: a presumable aim spends no round trip on the recipient.
			if presumable or giftAlreadyDelivered(aimedAt, purchaseId) == true then
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
		end

		-- No matching intent: NoGiftIntentPolicy. A product with a consumable Grant still
		-- delivers real value, so the credit path only covers pure perk products.
		if product.Grants and not product.Grant and self.Owns(entry.Player, product.Grants) then
			-- An unused gift credit means a previous purchase already converted to re-aimable
			-- value, so this money could only stack a second credit. Decline; Roblox retries
			-- and refunds a never-processed purchase, and a credit spent meanwhile lets the
			-- retry process normally.
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
		local recipientId = tonumber(record.RecipientId) or 0
		local giftId = tostring(record.GiftId)
		local productIdStr = tostring(product.Id)

		-- Same recipient re-check as the online intent path: a no-op delivery burns the
		-- buyer's Robux, so convert to a credit, but only if this exact purchase is undelivered.
		if
			product.Grants
			and not product.Grant
			and not allowDuplicateGifts
			and recipientAlreadyOwns(recipientId, product.Grants)
			and giftAlreadyDelivered(recipientId, purchaseId) == false
		then
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
				clearGiftRecordRaw(offlineReserved, fromAim, productIdStr, giftId)
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
			-- The record's age is wall time and keeps running while Roblox retries, so without
			-- this refresh an offline buyer's retries outlive giftIntentTTL and the next attempt
			-- grants the perk to the BUYER. Through an UpdateOffline transform, never a bare
			-- write on the GetOffline snapshot: deliverGift YIELDED, so the slot may now belong
			-- to a second gift. Best effort; the answer stays NotProcessedYet.
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
			if isProcessedRaw(offlineData, purchaseId) then
				return
			end
			local offlineReserved = reservedRaw(offlineData)
			-- Clear OUR record, and only ours. The decision that this receipt owns one was
			-- made from a snapshot taken before deliverGift's cross-server round trip, and a
			-- second gift of the same product can hold the slot by now. Identity is the
			-- GiftId, never the slot.
			clearGiftRecordRaw(offlineReserved, fromAim, productIdStr, giftId)
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
		local intent = reserved.PendingGifts[tostring(product.Id)]
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
		if type(intent) == "table" and Clock.Now() - (tonumber(intent.Ts) or 0) <= giftIntentTTL then
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
			local presumable = fromAim and Clock.Now() - (tonumber(record.Ts) or 0) <= giftAimTTL
			if presumable or giftAlreadyDelivered(aimedAt, purchaseId) == true then
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
				if isProcessedRaw(offlineData, purchaseId) then
					return
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

	-- Shared receipt path. `strict` decides what an UNREGISTERED product means:
	--  * true (Scribe owns ProcessReceipt): a configuration mistake. Log it and return
	--    NotProcessedYet, so Roblox retries and the Robux are never eaten.
	--  * false (an external router owns it): not ours. Return nil with no log so the
	--    caller falls through; NotProcessedYet would stall their purchase in a retry loop.
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
				{
					UserId = userId,
					ProductId = productId,
				}
			)
			return NOT_PROCESSED
		end
		Metrics.Add("ReceiptsReceived")

		local entry: { [string]: any }? = ctx.Persistence.EntryForUserId(userId)
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

		-- The in-flight guard sits here because all three delivery paths dispatch from the
		-- two lines below. The persisted ring is a COMPLETION record, written only after the
		-- grant commits, so between the duplicate check above and that write a second
		-- delivery of the same receipt sees "not yet granted", and every yield inside widens
		-- the window. It does NOT wait for the other invocation: that would park one
		-- ProcessReceipt callback across another's AwaitSave, and on the gift path could wait
		-- on the offline lock it is queued behind. Roblox retries a NotProcessedYet instead.
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
		-- pcall because applyProductGrant calls Tree:RunTransaction unguarded and assertAlive
		-- raises on a torn-down tree, the receipt-vs-departure race. Releasing only on a
		-- normal return would leak this key and refuse the receipt for the rest of the session.
		local dispatchOk, decision = pcall(function()
			if entry and entry.State == "Ready" then
				return handleOnlineReceipt(entry, product, receiptInfo)
			end
			return handleOfflineReceipt(userId, product, receiptInfo)
		end)
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

	function self.PromptPurchase(player: Player, name: string): (boolean, string?)
		local product = productsByName[name]
		local pass = passesByName[name]
		if not product and not pass then
			return false, `unknown product or pass "{name}"`
		end
		local entry = ctx.Persistence.EntryFor(player)
		if not entry or entry.State ~= "Ready" then
			return false, "player data not loaded"
		end

		local promptId: number
		local prompt: (player: Player, id: number) -> ()
		if pass then
			-- A pass IS its own ownership key, and the join scan warms the cache for every
			-- declared pass.
			if self.Owns(player, name) then
				return false, `player already owns "{name}"`
			end
			promptId, prompt = pass.Id, promptGamePassPurchase
		else
			-- A product owns nothing unless it Grants a perk. Without one it is a
			-- consumable and is always promptable.
			local grants = (product :: any).Grants
			if grants ~= nil and self.Owns(player, grants) then
				return false, `player already owns "{grants}"`
			end
			promptId, prompt = (product :: any).Id, promptProductPurchase
		end

		local ok, err = pcall(function()
			prompt(player, promptId)
		end)
		if not ok then
			return false, `purchase prompt failed: {err}`
		end
		Metrics.Add("PurchasePrompts")
		return true, nil
	end

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
		local now = Clock.Monotonic()
		if now - entry.GiftLastAt < giftCooldown then
			return false, "gift cooldown"
		end
		if Util.count(reservedRaw(entry.LiveData).PendingGifts) >= giftMaxPending then
			return false, "too many pending gifts"
		end
		-- The aim store's cap, enforced at INTAKE before money moves: if this prompt goes
		-- stale while the buyer is away the load sweep has to be able to archive where it was
		-- aimed, and refusing an unpaid prompt is the cheap end of that trade. It RESERVES
		-- rather than measures, because every pending intent is a slot this store already
		-- owes. A product whose slot is already taken is free, since the record overwrites it.
		local productIdStr = tostring(product.Id)
		-- Counts the STORE alone, unlike PromptGift's reservation: by now the intent is
		-- being spent into a slot, and counting it too would charge the same gift twice.
		local function aimStoreIsFull(): boolean
			local live = reservedRaw(entry.LiveData)
			local aims, pending = live.GiftAims, live.PendingGifts
			if aims[productIdStr] ~= nil or pending[productIdStr] ~= nil then
				return false
			end
			local reservedSlots = Util.count(aims)
			for pendingIdStr in pending do
				if aims[pendingIdStr] == nil then
					reservedSlots += 1
				end
			end
			return reservedSlots >= giftAimCap
		end
		if aimStoreIsFull() then
			reclaimGiftAims(entry) -- past-horizon aims only; re-read after it
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
		if entry.State ~= "Ready" then
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
			-- grant under a purchaseId the recipient's dedupe ring has never seen.
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

		-- Step 3: durable intent BEFORE money moves. Refuse a second gift of the same product
		-- only while a purchase could still be in flight: a receipt carries only the product
		-- Id, never the recipient, so intents are keyed by it and overwriting a live one
		-- would deliver the first purchase to the second recipient. Past giftPromptWindow no
		-- receipt ever came and the slot is safe to overwrite.
		local pendingIntent = intentFor(entry, product)
		if pendingIntent ~= nil and Clock.Now() - (tonumber(pendingIntent.Ts) or 0) < giftPromptWindow then
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
		-- Both rollbacks below clear through clearGiftRecord and neither reuses
		-- `intentAccessor`: that accessor is a PATH captured before the AwaitSave yields, so
		-- Set(nil) on it would delete whatever occupies the slot when the rollback runs, and
		-- inside a ten-second save a second PromptGift can legally have taken it over. A
		-- GiftId comparison rather than an existence test, because in the hazard the slot IS
		-- occupied, just by someone else.
		if not ctx.Persistence.AwaitSave(entry, 10) then
			clearGiftRecord(entry, false, productIdStr, giftId)
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
			clearGiftRecord(entry, false, productIdStr, giftId)
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
		-- Optional caller-supplied idempotency key. Deliberately NOT stored in
		-- _Scribe.ProcessedPurchaseIds: pushing ordinary shop traffic through that capped
		-- ring would flush real receipt ids.
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
		-- Expire stale gift intents, but ARCHIVE what they aimed at first. Deleting the
		-- recipient outright leaves a late receipt indistinguishable from a self-purchase, so
		-- the buyer is granted a gift they already paid to send. The intent itself still
		-- goes, or the buyer loses gift capacity for good.
		local reserved = reservedRaw(entry.LiveData)
		local now = Clock.Now()
		for productIdStr, intent in reserved.PendingGifts do
			if type(intent) ~= "table" or now - (tonumber(intent.Ts) or 0) > giftIntentTTL then
				archiveGiftAim(entry, productIdStr, intent)
				reservedAcc(entry).PendingGifts[productIdStr].Set(nil)
			end
		end
		-- No prune here on purpose. An aim past the horizon can no longer CLAIM a receipt but
		-- can still PROVE one was delivered, and that proof is free to keep: the store is
		-- bounded by its cap and reclaims on intake, where something competes for the room.
		-- Gift credits are durable paid value keyed by product NAME, so a renamed or removed
		-- product silently strands them. Surface it, never delete: the credit is player money.
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
		Sched.Spawn(refreshOwnership, entry)
		watchOwnership(entry)
	end

	function self.OnUnload(entry: any)
		local watchers = entry.OwnsWatchers
		if watchers then
			entry.OwnsWatchers = nil
			for _, disconnect in watchers do
				disconnect()
			end
		end
	end

	local connections: { any } = {}
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

		connections[#connections + 1] = MarketplaceService.PromptGamePassPurchaseFinished:Connect(
			function(player: Player, passId: number, purchased: boolean)
				self.OnPassPurchaseFinished(player, passId, purchased)
			end
		)

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
