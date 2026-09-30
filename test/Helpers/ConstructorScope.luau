--!nonstrict
-- Own public-constructor fixtures without weakening the production shutdown path.
-- Install for each test; cleanup drains private fake stores before releasing the
-- engine callbacks, and restores Server.build even if a fixture cannot drain.
local Root = script.Parent.Parent.Parent
local Server = require(Root.Scribe.Server)
local HarnessScope = require(script.Parent.HarnessScope)

local ConstructorScope = {}

function ConstructorScope.new()
	local handles = HarnessScope.new()
	local scope = {}
	local originalBuild, wrappedBuild

	function scope.Install()
		if wrappedBuild ~= nil then
			return
		end
		originalBuild = Server.build
		wrappedBuild = function(options, compiled)
			local fake = options.ProfileStore
			assert(
				type(fake) == "table"
					and type(fake.ActiveProfiles) == "table"
					and type(fake.ActiveLoadJobs) == "number"
					and type(fake.BeginClose) == "function"
					and type(fake.AwaitClose) == "function",
				"ConstructorScope requires a private FakeProfileStore"
			)
			local data, ctx = originalBuild(options, compiled)
			local releases = {}
			handles.Track({
				Cleanup = function()
					fake.BeginClose()
					fake.AwaitClose()
					-- AwaitClose snapshots profiles before waiting for in-flight loads.
					-- Once those jobs finish, release anything the snapshot missed.
					if fake.ActiveLoadJobs == 0 and next(fake.ActiveProfiles) ~= nil then
						fake.AwaitClose()
					end
					assert(fake.ActiveLoadJobs == 0, "Constructor fixture still has active load jobs")
					assert(next(fake.ActiveProfiles) == nil, "Constructor fixture still has active profiles")
					assert(next(ctx.Persistence.Entries) == nil, "Constructor fixture still has persistence entries")
					data.Stop()
					for _, release in releases do
						release()
					end
				end,
			})
			local bindShutdown = ctx.Persistence.BindShutdown
			ctx.Persistence.BindShutdown = function()
				local release = bindShutdown()
				assert(type(release) == "function", "BindShutdown must return a release function")
				table.insert(releases, release)
				return release
			end
			return data, ctx
		end
		Server.build = wrappedBuild
	end

	function scope.TrackClient(api)
		handles.Track({ Cleanup = api.Stop })
		return api
	end

	function scope.Cleanup()
		-- Restore before any drain can yield: a cleanup timeout also closes its
		-- coroutine, so a trailing restoration would never execute.
		if wrappedBuild ~= nil then
			Server.build = originalBuild
			originalBuild, wrappedBuild = nil, nil
		end
		handles.Cleanup()
	end

	return scope
end

return ConstructorScope
