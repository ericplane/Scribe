--!nonstrict
-- Keep harness ownership outside the yielding test coroutine: Jest closes that
-- coroutine on timeout, so a trailing pcall/final cleanup there cannot run.
-- Register Cleanup with afterEach and afterAll (the latter also covers beforeAll
-- failures). Explicit Cleanup calls remain useful between save/reload phases.
local HarnessScope = {}

function HarnessScope.new()
	local pending = {}
	local scope = {}

	function scope.Track(harness)
		assert(type(harness.Cleanup) == "function", "HarnessScope requires a Cleanup function")
		assert(table.find(pending, harness) == nil, "HarnessScope already owns this harness")
		local cleanup = harness.Cleanup
		local released = false
		table.insert(pending, harness)
		function harness.Cleanup()
			if released then
				return
			end
			cleanup()
			-- Retain failed cleanup for the next hook's retry. Do not mark resources
			-- released before cleanup succeeds (or before a yielding cleanup returns).
			released = true
			local index = table.find(pending, harness)
			if index then
				table.remove(pending, index)
			end
		end
		return harness
	end

	function scope.Cleanup()
		local failures = {}
		-- Cleanup removes successful entries, so iterate a stable copy in reverse.
		local remaining = table.clone(pending)
		for index = #remaining, 1, -1 do
			local ok, err = pcall(remaining[index].Cleanup)
			if not ok then
				table.insert(failures, tostring(err))
			end
		end
		if #failures > 0 then
			error("Harness cleanup failed:\n" .. table.concat(failures, "\n"), 0)
		end
	end

	return scope
end

return HarnessScope
