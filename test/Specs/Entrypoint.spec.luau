--!nonstrict
-- The Scribe(options) entry point itself: the option guards that run before any
-- server context exists. Every other spec builds through Server.build (TestCtx),
-- so without these the guards in src/init.luau are never executed.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Config = require(Root.Scribe.Internal.Config)

	-- Every guard below errors before the bundle is built, and
	-- Config.BundleConstructed is only set once they all pass, so a failed call
	-- leaves no process-global trace (see the Configure case at the bottom).
	local function callGuard(options: any): (boolean, string)
		local ok, err = pcall(Scribe, options)
		return ok, tostring(err)
	end

	it("rejects a non-table options argument", function()
		local ok, err = callGuard("nope" :: any)
		expect(ok).to.equal(false)
		expect(string.find(err, "options must be a table", 1, true) ~= nil).to.equal(true)
	end)

	it("requires a table Template", function()
		local ok, err = callGuard({ ProfileStoreIndex = "D", ProfileKeyPrefix = "P_" })
		expect(ok).to.equal(false)
		expect(string.find(err, "options.Template is required", 1, true) ~= nil).to.equal(true)
	end)

	it("requires a non-empty ProfileStoreIndex", function()
		local ok, err = callGuard({ Template = {}, ProfileKeyPrefix = "P_" })
		expect(ok).to.equal(false)
		expect(string.find(err, "options.ProfileStoreIndex is required", 1, true) ~= nil).to.equal(true)

		local ok2, err2 = callGuard({ Template = {}, ProfileStoreIndex = "", ProfileKeyPrefix = "P_" })
		expect(ok2).to.equal(false)
		expect(string.find(err2, "options.ProfileStoreIndex is required", 1, true) ~= nil).to.equal(true)
	end)

	it('requires a string ProfileKeyPrefix but accepts ""', function()
		local ok, err = callGuard({ Template = {}, ProfileStoreIndex = "D" })
		expect(ok).to.equal(false)
		expect(string.find(err, "options.ProfileKeyPrefix is required", 1, true) ~= nil).to.equal(true)

		local ok2, err2 = callGuard({ Template = {}, ProfileStoreIndex = "D", ProfileKeyPrefix = 5 })
		expect(ok2).to.equal(false)
		expect(string.find(err2, "options.ProfileKeyPrefix is required", 1, true) ~= nil).to.equal(true)

		-- "" is a legitimate prefix (bare user-id keys), so it must get PAST this
		-- guard. The template deliberately fails to compile on the next step, so
		-- the call still errors and no bundle is built; the point is only that the
		-- failure is no longer about the prefix. This is the assertion that fails
		-- if the "" rejection is ever reintroduced here.
		local ok3, err3 = callGuard({
			Template = { Bad = function() end },
			ProfileStoreIndex = "D",
			ProfileKeyPrefix = "",
		})
		expect(ok3).to.equal(false)
		expect(string.find(err3, "ProfileKeyPrefix", 1, true)).to.equal(nil)
	end)

	it("a call that fails a guard does not block a later Scribe.Configure", function()
		Config.AutoSaveInterval = nil
		Config.AutoSaveSource = nil
		Config.BundleConstructed = false

		-- No bundle was constructed, so Configure must still be allowed. The flag
		-- used to be set above these guards, which made this report that a bundle
		-- already existed. It must be a table that fails a LATER guard: a non-table
		-- argument errors before the flag was ever reached, even in the old order.
		callGuard({ ProfileStoreIndex = "D", ProfileKeyPrefix = "P_" })
		expect(function()
			Scribe.Configure({ AutoSaveInterval = 30 })
		end).never.to.throw()

		Config.AutoSaveInterval = nil
		Config.AutoSaveSource = nil
		Config.BundleConstructed = false
	end)

	-- A UI Labs / Hoarcekat story requires the same shared bundle module a live
	-- client does, and RunService:IsServer() is true in edit mode. Dispatching on
	-- that alone built the SERVER half inside the storybook: the transport folder
	-- and its RemoteEvents appeared in ReplicatedStorage (and got saved into the
	-- place), and the story's `.Client` was the stub that throws on first use.
	describe("edit mode", function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")

		-- IsRunning is the seam, not RunService: it reports true under both
		-- TestEZ-in-Studio and the Lune shim, and a real service Instance cannot
		-- be patched. Scribe(options) also poisons BundleConstructed, so put it
		-- back for the Configure specs.
		local function buildEditMode(): any
			local constructed = Config.BundleConstructed
			local bundle = Scribe({
				Template = { Coins = Scribe.Int(0, { Min = 0 }) },
				ProfileStoreIndex = "EntrypointSpec",
				ProfileKeyPrefix = "PLAYER_",
				IsRunning = false,
				Banner = false,
			})
			Config.BundleConstructed = constructed
			return bundle
		end

		it("builds the client half without touching the transport", function()
			local before = ReplicatedStorage:FindFirstChild("ScribeTransport")
			local bundle = buildEditMode()

			-- Nothing was added to ReplicatedStorage: the client skips the
			-- transport in edit mode, and the server half never ran.
			expect(ReplicatedStorage:FindFirstChild("ScribeTransport")).to.equal(before)

			-- A real client, initialized to template defaults with no handshake.
			expect(bundle.Client.Coins.Get()).to.equal(0)

			-- Mock errors outside edit mode, so seeding through it is the proof
			-- that this is the edit-mode client and not a live one.
			bundle.Client.Mock({ Coins = 25 })
			expect(bundle.Client.Coins.Get()).to.equal(25)
		end)

		it("explains the missing server half in edit-mode terms", function()
			local bundle = buildEditMode()
			local ok, err = pcall(function()
				return bundle.Server.Command
			end)
			expect(ok).to.equal(false)
			-- Not the "on the client — use Data.Request" wording: in a storybook
			-- there is no server to request from.
			expect(string.find(tostring(err), "edit mode", 1, true) ~= nil).to.equal(true)
		end)
	end)
end
