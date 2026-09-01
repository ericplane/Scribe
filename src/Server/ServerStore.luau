--!strict
-- The server-owned tree: one store per bundle, shared by everyone on the server.
-- Nothing here persists (store roots compile with Persist = false), so there is no key,
-- no session lock and no migration. Built with the bundle, destroyed with it.

local Internal = script.Parent.Parent.Internal
local Node = require(Internal.Node)
local Template = require(Internal.Template)
local Log = require(Internal.Log)
local Metrics = require(Internal.Metrics)
local Util = require(Internal.Util)

local ServerStore = {}

--- Builds the store tree, or returns nil when the bundle declared no ServerStore.
function ServerStore.new(ctx: any): any?
	local storeView = ctx.Compiled.Views.Store
	if storeView == nil then
		return nil
	end

	local self = {}
	-- One table under both stores: nothing here persists, so the split separates nothing.
	local data = Template.BuildDefaults(storeView, "Session")

	local tree = Node.NewTree({
		Compiled = storeView,
		Stores = { Persist = data, Session = data },
		IsServer = true,
		IsServerStore = true,
		Label = "ServerStore",
		OnOp = function(op: Node.Op, schema: Template.SchemaNode?)
			ctx.Replication.PushStoreOp(op, schema)
		end,
		OnAnomaly = function(path, _value, reason)
			Metrics.Add("Anomalies")
			Log.Warn("Integrity", "ANOMALY", `implausible store write at "{Util.pathString(path)}": {reason}`, {
				Path = Util.pathString(path),
				Reason = reason,
			})
		end,
		BoundsPolicy = ctx.Options.BoundsPolicy,
		DevMode = ctx.DevMode,
		-- A deadline is swept per profile and economy is reported per player; the store has
		-- neither. Timed is refused at compile time, economy tags are accepted and dropped.
		TimedHooks = nil,
		OnEconomy = nil,
		-- Same codes a player tree uses; no Player to name, so the label goes in the context.
		LogError = function(message: string)
			Log.Error("Lifecycle", "LISTENER_ERROR", message, { Field = "ServerStore" })
		end,
		LogWarn = function(message: string)
			Log.Warn("Lifecycle", "DEV_WARNING", message, { Field = "ServerStore" })
		end,
		OnDerivedIssue = function(code: any, field: string, detail: string)
			local report: typeof(Log.Warn) = if code == "DERIVED_MISMATCH" then Log.Warn else Log.Error
			report("Derived", code, `"{field}": {detail}`, { Field = field })
		end,
		OnBatchEnd = function()
			ctx.Replication.FlushStoreQueue()
		end,
	})
	-- Not done by the constructor: without it a derived store field serves a value computed
	-- from template defaults, which is a plausible wrong number.
	tree:SeedDerived()

	self.Tree = tree
	self.Data = data
	self.Accessor = tree.Accessor

	-- A closure, not a method: the failed-build unwind calls pcall(subsystem.Stop) with no
	-- receiver. Destroy does not release Params.Stores, so clear the data table here.
	function self.Stop()
		tree:Destroy()
		table.clear(data)
	end

	return self
end

return ServerStore
