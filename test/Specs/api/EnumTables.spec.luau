--!nonstrict
-- The frozen tables behind the string unions, and the naming rule in CONTRIBUTING.md: a
-- PascalCase union's member name IS its value, and no union mixes a code with a sentence.

return function()
	local Scribe = require(script.Parent.Parent.Parent.Parent.Scribe) :: any

	--- Name and value are the same word, for a union that names things rather than outcomes.
	local IDENTITY = {
		OpKind = { "Init", "Set", "Insert", "Remove", "Clear" },
		LogLevel = { "Debug", "Info", "Warn", "Error", "Fatal" },
		LogCategory = {
			"Persistence",
			"Replication",
			"Transport",
			"Commands",
			"Leaderboards",
			"Monetization",
			"Gifting",
			"Integrity",
			"Lifecycle",
			"Derived",
			"Exchanges",
		},
		Status = { "Healthy", "Degraded", "Outage" },
		SessionState = { "Loading", "Ready", "SessionEnded" },
		Visibility = { "Replicated", "ServerOnly", "Shared" },
	}

	it("gives every PascalCase union a table whose member name IS its value", function()
		local wrong = {}
		for name, members in IDENTITY do
			local tbl = Scribe[name]
			if type(tbl) ~= "table" then
				table.insert(wrong, `{name}=missing`)
				continue
			end
			for _, member in members do
				if tbl[member] ~= member then
					table.insert(wrong, `{name}.{member}={tostring(tbl[member])}`)
				end
			end
			local count = 0
			for _ in tbl do
				count += 1
			end
			if count ~= #members then
				table.insert(wrong, `{name} has {count} members, expected {#members}`)
			end
		end
		table.sort(wrong)
		expect(table.concat(wrong, " ")).to.equal("")
	end)

	it("freezes them, so one bundle cannot rewrite another's constants", function()
		local unfrozen = {}
		for _, name in { "OpKind", "LogLevel", "LogCategory", "Status", "SessionState", "Visibility" } do
			local ok = pcall(function()
				Scribe[name].Injected = "x"
			end)
			if ok then
				table.insert(unfrozen, name)
			end
		end
		expect(table.concat(unfrozen, " ")).to.equal("")
	end)

	it("hands LifecycleReason the SAME table as the older Reason name", function()
		expect(`same={Scribe.LifecycleReason == Scribe.Reason} loadFailed={Scribe.LifecycleReason.LoadFailed}`).to.equal(
			"same=true loadFailed=load-failed"
		)
	end)

	it("keeps the sentence unions free of codes, which is what a game shows a player", function()
		-- A code here means a refusal nobody can display; that is the drift the rule stops.
		local codes = {}
		for _, union in { "PurchaseReason", "GiftReason" } do
			for member, value in Scribe[union] do
				if string.find(value, "-") ~= nil and string.find(value, " ") == nil then
					table.insert(codes, `{union}.{member}={value}`)
				end
			end
		end
		table.sort(codes)
		expect(table.concat(codes, " ")).to.equal("")
	end)

	it("keeps the code unions free of sentences, which nobody should branch on", function()
		local sentences = {}
		for _, union in { "ProductState", "Reason", "RequestReason" } do
			for member, value in Scribe[union] do
				if string.find(value, " ") ~= nil then
					table.insert(sentences, `{union}.{member}={value}`)
				end
			end
		end
		table.sort(sentences)
		expect(table.concat(sentences, " ")).to.equal("")
	end)
end
