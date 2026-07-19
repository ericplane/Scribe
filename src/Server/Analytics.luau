--!strict
-- Economy source/sink analytics. Currency mutations tagged via
-- Increment/Decrement (and Data.Purchase) auto-emit
-- AnalyticsService:LogEconomyEvent. The currency is the mutated field's name;
-- per-currency custom fields, an ambient Resolve, and a currency-label override
-- are declared once in options.Economy. Failures log at Debug and never block
-- gameplay.

local AnalyticsService = game:GetService("AnalyticsService")

local Internal = script.Parent.Parent.Internal
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Types = require(script.Parent.Parent.Types)

local Analytics = {}

-- Roblox exposes exactly three economy custom-field slots.
local MAX_FIELDS = 3

-- Resolve a transaction type from the tag: an Enum.AnalyticsEconomyTransactionType
-- (a real EnumItem, or the headless test fake, which is a table carrying .Name),
-- a plain string, or nil -> "Gameplay".
local function txnName(value: any): string
	if value == nil then
		return "Gameplay"
	end
	if typeof(value) == "EnumItem" then
		return (value :: EnumItem).Name
	end
	if type(value) == "table" and type((value :: any).Name) == "string" then
		return (value :: any).Name
	end
	return tostring(value)
end

type FieldSpec = { Name: string, Prefix: boolean }
type Currency = {
	Label: string?,
	Resolve: ((player: Player) -> { [string]: any })?,
	Fields: { FieldSpec },
	Declared: { [string]: boolean },
}

function Analytics.new(ctx: any)
	local self = {} :: any
	local options = ctx.Options or {}
	local economy = options.Economy or {}
	local devMode: boolean = ctx.DevMode == true

	-- Cast the (any-typed) override to the seam's function type so the default
	-- and the call site below are both concretely callable, not `~(false?)`.
	local logEconomy = (economy.LogEconomyEvent :: Types.EconomyLogFn?)
		or function(
			player: Player,
			flowType: Enum.AnalyticsEconomyFlowType,
			currency: string,
			amount: number,
			balance: number,
			transactionType: string,
			itemSku: string?,
			customFields: { [string]: any }?
		)
			AnalyticsService:LogEconomyEvent(
				player,
				flowType,
				currency,
				amount,
				balance,
				transactionType,
				itemSku,
				customFields
			)
		end

	local defaultPrefix: boolean = economy.Prefix ~= false -- default true
	local globalResolve = economy.Resolve

	-- CustomField01/02/03 key names (the strings LogEconomyEvent expects).
	local slotKeys: { string } = {}
	for i = 1, MAX_FIELDS do
		slotKeys[i] = (Enum.AnalyticsCustomFieldKeys :: any)[string.format("CustomField%02d", i)].Name
	end

	-- Precompile each currency's ordered {Name, Prefix} slot specs (capped at the
	-- 3 hard Roblox slots), a declared-name set for typo warnings, the optional
	-- label override, and the optional currency-specific resolver.
	local currencies: { [string]: Currency } = {}
	for name, raw in (economy.Currencies or {}) :: { [string]: any } do
		local fields: { FieldSpec } = {}
		local declared: { [string]: boolean } = {}
		for _, spec in (raw.Fields or {}) :: { any } do
			local fieldName: any
			local fieldPrefix: boolean
			if type(spec) == "table" then
				fieldName = spec.Name
				fieldPrefix = if spec.Prefix == nil then defaultPrefix else spec.Prefix == true
			else
				fieldName = spec
				fieldPrefix = defaultPrefix
			end
			if type(fieldName) ~= "string" then
				error(
					`Scribe: Economy.Currencies["{name}"].Fields entries must be a field name or \{ Name = "..." }`,
					0
				)
			end
			declared[fieldName] = true
			if #fields >= MAX_FIELDS then
				-- Silent truncation would read as "recorded" when it wasn't.
				if devMode then
					Log.Warn(
						"Integrity",
						"ECONOMY_FIELDS_OVERFLOW",
						`currency "{name}" declares more than {MAX_FIELDS} custom fields; "{fieldName}" and any beyond it are dropped (Roblox allows {MAX_FIELDS})`,
						{ Currency = name, Field = fieldName }
					)
				end
			else
				table.insert(fields, { Name = fieldName, Prefix = fieldPrefix })
			end
		end
		currencies[name] = { Label = raw.Label, Resolve = raw.Resolve, Fields = fields, Declared = declared }
	end

	-- Merge a resolver's output into the pool, fail-safe: a throwing resolver
	-- drops its fields (logged at Debug) rather than losing the whole event.
	local function resolveInto(pool: { [string]: any }, fn: any, player: Player)
		if not fn then
			return
		end
		local ok, res = pcall(fn, player)
		if ok and type(res) == "table" then
			for key, value in res do
				pool[key] = value
			end
		elseif not ok then
			Log.Debug("Integrity", "ANALYTICS_FAIL", `economy Resolve threw: {tostring(res)}`, { Player = player })
		end
	end

	local function buildCustomFields(player: Player, currency: Currency?, tags: { [string]: any }): { [string]: any }?
		-- Custom fields need a declared slot mapping; an undeclared currency (or
		-- one with no Fields) logs a plain event.
		if not currency or #currency.Fields == 0 then
			return nil
		end
		local pool: { [string]: any } = {}
		resolveInto(pool, globalResolve, player)
		resolveInto(pool, currency.Resolve, player)
		local perCall = tags.Fields
		if type(perCall) == "table" then
			for key, value in perCall do
				pool[key] = value
				if devMode and not currency.Declared[key] then
					Log.Warn(
						"Integrity",
						"ECONOMY_FIELD_UNDECLARED",
						`economy field "{key}" is not declared for this currency and will not be recorded (typo?)`,
						{ Player = player, Field = key }
					)
				end
			end
		end
		local out: { [string]: any } = {}
		local any = false
		for i, spec in currency.Fields do
			local value = pool[spec.Name]
			if value ~= nil then
				out[slotKeys[i]] = if spec.Prefix then `{spec.Name} - {value}` else value
				any = true
			end
		end
		return if any then out else nil
	end

	function self.Economy(
		player: Player,
		path: { string | number },
		delta: number,
		newValue: number,
		tags: { [string]: any }
	)
		local fieldName = tostring(path[#path]) -- internal path segment; always safe
		local currency = currencies[fieldName]
		local flowType = if tags.Flow == "Sink"
			then Enum.AnalyticsEconomyFlowType.Sink
			else Enum.AnalyticsEconomyFlowType.Source
		-- Safe fallback so the failure log below always has a label, even when the
		-- caller-supplied Currency is the value that threw.
		local currencyLabel = fieldName

		-- FORMAT every caller-supplied value, build the custom fields, AND log inside
		-- one guard. Formatting a user-supplied value (a `__tostring` that throws, a
		-- resolver whose returned table has a throwing `__iter`) must never escape into
		-- the Increment/Decrement caller and abort gameplay after the write already
		-- applied. Currency, TransactionType, Source, ItemSku, and Item are all
		-- caller-supplied, so their tostring calls belong inside the guard too.
		local ok, err = pcall(function()
			currencyLabel = tostring(tags.Currency or (currency and currency.Label) or fieldName)
			local transactionType = txnName(if tags.TransactionType ~= nil then tags.TransactionType else tags.Source)
			local itemSkuRaw = if tags.ItemSku ~= nil then tags.ItemSku else tags.Item
			local itemSku = if itemSkuRaw ~= nil then tostring(itemSkuRaw) else nil
			local customFields = buildCustomFields(player, currency, tags)
			logEconomy(
				player,
				flowType,
				currencyLabel,
				math.abs(delta),
				newValue,
				transactionType,
				itemSku,
				customFields
			)
		end)
		if ok then
			Metrics.Add("EconomyEvents") -- count successes, not attempts
		else
			-- A systematically failing analytics pipeline is a system fault, not
			-- routine noise: surface a failure counter (Debug logs are suppressed
			-- in production) so operators can see the dashboards go dark.
			Metrics.Add("EconomyEventFailures")
			Log.Debug("Integrity", "ANALYTICS_FAIL", tostring(err), { Player = player, Currency = currencyLabel })
		end
	end

	return self
end

return Analytics
