--!strict
-- Economy source/sink analytics. Currency mutations tagged via
-- Increment/Decrement auto-emit AnalyticsService:LogEconomyEvent. Failures log
-- at Debug and never block gameplay.

local AnalyticsService = game:GetService("AnalyticsService")

local Internal = script.Parent.Parent.Internal
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)

local Analytics = {}

function Analytics.new(_ctx: any)
	local self = {} :: any

	function self.Economy(player: Player, path: { string | number }, delta: number, newValue: number, tags: { [string]: any })
		local flow = tags.Flow
		local flowType = if flow == "Sink"
			then Enum.AnalyticsEconomyFlowType.Sink
			else Enum.AnalyticsEconomyFlowType.Source
		local currency = tostring(path[#path])
		local transactionType = tostring(tags.Source or "Gameplay")
		local itemSku = if tags.Item ~= nil then tostring(tags.Item) else nil

		local ok, err = pcall(function()
			AnalyticsService:LogEconomyEvent(
				player,
				flowType,
				currency,
				math.abs(delta),
				newValue,
				transactionType,
				itemSku
			)
		end)
		if ok then
			Metrics.Add("EconomyEvents") -- count successes, not attempts
		else
			-- A systematically failing analytics pipeline is a system fault, not
			-- routine noise: surface a failure counter (Debug logs are suppressed
			-- in production) so operators can see the dashboards go dark.
			Metrics.Add("EconomyEventFailures")
			Log.Debug("Integrity", "ANALYTICS_FAIL", tostring(err), { Player = player, Currency = currency })
		end
	end

	return self
end

return Analytics
