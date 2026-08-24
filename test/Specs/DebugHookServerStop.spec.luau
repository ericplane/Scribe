--!nonstrict
-- The DebugHook remover has to reach `Data.Stop()`.
--
-- `DebugHook.Attach` returns a `detach` function, and DebugHookTeardown.spec
-- proves that function does its job: it releases the `Log` sink and the
-- `Health.OnStatusChanged` listener, both library-level singletons that outlive
-- the bundle, and it is idempotent. That fix landed. It was never wired to its
-- only caller -- `Server.new` called `Attach` inside a `pcall` and threw the
-- remover away -- so in a real Studio session `Data.Stop()` left the sink, the
-- listener and the 8 Hz digest pump attached to a dead ctx.
--
-- Studio-only, and Studio tears the DataModel down on stop, so the practical bite
-- is a session that stops a bundle and keeps running. What makes it worth fixing
-- is not the runtime cost: it is that a known, already-fixed, already-spec'd
-- defect had its fix disconnected from its caller, and nothing in the suite would
-- have noticed it silently regressing.
--
-- THE SPY IS THE POINT. `DebugHook`'s `attached` flag is a process singleton that
-- `detach` deliberately never clears (its docstring argues why), so a second real
-- attach anywhere in a run is refused -- which would make a spec built on the real
-- hook silently vacuous depending on spec order. Substituting `Attach` tests
-- exactly the thing that was broken, the WIRING, and leaves the behaviour of the
-- real remover where it is already covered.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Server = require(Root.Scribe.Server) :: any
	local DebugHook = require(Root.Scribe.Server.DebugHook) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
	local StubTransport = require(Root.Test.Helpers.StubTransport)

	local compiled = Template.Compile({ Coins = Scribe.Int(0, { Min = 0 }) }, {})

	local function baseOptions()
		return {
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Transport = StubTransport.new(),
			ProfileStore = FakeProfileStore.new(),
			ProfileStoreIndex = "Default",
			ProfileKeyPrefix = "PLAYER_",
			UseMock = true,
			OwnReceipts = false,
			KickOnSessionEnd = false,
			LogLevel = "Fatal",
			Banner = false,
		}
	end

	--- Run `body` with IsStudio pinned true and DebugHook.Attach replaced by
	--- `attach`, restoring both whatever happens. Headless pins IsStudio false
	--- (lune/run-tests.luau), so without the first half the whole branch is dead;
	--- under real TestEZ in Studio it is already true and left alone.
	local function withStudioHook(attach, body)
		local realIsStudio = nil
		if not RunService:IsStudio() then
			realIsStudio = RunService.IsStudio
			RunService.IsStudio = function()
				return true
			end
		end
		local realAttach = DebugHook.Attach
		DebugHook.Attach = attach
		local ok, err = pcall(body)
		DebugHook.Attach = realAttach
		if realIsStudio ~= nil then
			RunService.IsStudio = realIsStudio
		end
		if not ok then
			error(err, 0)
		end
	end

	describe("Server.new and the DebugHook remover", function()
		it("calls the remover Attach handed back, exactly once, on Stop", function()
			-- The defect. Attach's return value was discarded, so nothing could ever
			-- call it.
			local attaches, detaches = 0, 0
			withStudioHook(function()
				attaches += 1
				return function()
					detaches += 1
				end
			end, function()
				local data = Server.new(baseOptions(), compiled)
				expect(attaches).to.equal(1)
				expect(detaches).to.equal(0)

				data.Stop()
				expect(detaches).to.equal(1)

				-- Stop is called more than once in real teardown paths; the remover is
				-- idempotent, but Server.new must not lean on that.
				data.Stop()
				expect(detaches).to.equal(1)
			end)
		end)

		it("releases the remover BEFORE the subsystems it was watching", function()
			-- Ordering, and it is the reason to hold the remover in the Server.new
			-- scope rather than inside build: the hook watches ctx -- its digest pump
			-- reads Persistence.Entries once a tick -- so it has to let go before what
			-- it watches is dismantled underneath it.
			--
			-- Asserted from INSIDE the remover, against the ctx the spy was handed,
			-- because that is the only vantage point that can see the difference.
			-- Wrapping Data.Stop from outside cannot: both orderings look identical
			-- from there.
			local persistenceStoppedAtDetach = nil
			local detached = false
			withStudioHook(function(_data, ctx)
				return function()
					detached = true
					persistenceStoppedAtDetach = ctx.Persistence.Stopped
				end
			end, function()
				local data = Server.new(baseOptions(), compiled)
				data.Stop()
			end)

			expect(detached).to.equal(true)
			-- False means the subsystems had not been torn down yet when the hook was
			-- asked to let go.
			expect(persistenceStoppedAtDetach).to.equal(false)
		end)

		it("stops cleanly when the hook itself failed to attach", function()
			-- Attach is pcalled because a broken hook must never stop a bundle
			-- booting. The mirror of that has to hold too: a bundle whose hook threw
			-- must still Stop without raising on a remover that never existed.
			local stopped = false
			withStudioHook(function()
				error("mock debug hook failure")
			end, function()
				local data = Server.new(baseOptions(), compiled)
				data.Stop()
				stopped = true
			end)
			expect(stopped).to.equal(true)
		end)

		it("stops cleanly when Attach returns nothing at all", function()
			-- The refusal path of the real hook: a second bundle in one process gets
			-- DEBUG_HOOK_DUPLICATE and Attach returns nil. Stop must not care.
			local stopped = false
			withStudioHook(function()
				return nil
			end, function()
				local data = Server.new(baseOptions(), compiled)
				data.Stop()
				stopped = true
			end)
			expect(stopped).to.equal(true)
		end)
	end)
end
