--!strict
-- Check staged code and the sources actually packed into each model.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local staging = "dist/rbxm"
local sourcesOnly = false
local argument = 1
while argument <= #process.args do
	local value = process.args[argument]
	if value == "--staging" then
		argument += 1
		staging = assert(process.args[argument], "--staging requires a directory")
	elseif value == "--sources-only" then
		sourcesOnly = true
	else
		error(`Unknown verification argument: {value}`)
	end
	argument += 1
end
staging ..= "/"
local mapping = serde.decode("json", fs.readFile(staging .. "Scribe-source-map.json"))
local options = { optimizationLevel = 2, debugLevel = 0, typeInfoLevel = 0 }
local sources: { [string]: string } = {}
local count = 0

-- Luau retains function line numbers even with debug information disabled.
local function restoreLinePositions(packed: string, segments: { { number } }): string
	local lines = string.split(packed, "\n")
	local parts = {}
	local sourceLine = 1
	local segment = 1
	for packedLine, line in lines do
		while segment < #segments and segments[segment + 1][1] <= packedLine do
			segment += 1
		end
		local originalLine = segments[segment][2] + packedLine - segments[segment][1]
		assert(originalLine >= sourceLine, "Invalid source line map")
		table.insert(parts, string.rep("\n", originalLine - sourceLine))
		table.insert(parts, line)
		if packedLine < #lines then
			table.insert(parts, "\n")
		end
		sourceLine = originalLine + 1
	end
	return table.concat(parts)
end

for path, entry in mapping.files do
	local original = fs.readFile(path)
	local packed = fs.readFile(staging .. path)
	assert(serde.hash("sha256", original) == entry.sourceSha256, `Source changed after staging: {path}`)
	assert(serde.hash("sha256", packed) == entry.packedSha256, `Staged source changed: {path}`)
	local aligned = restoreLinePositions(packed, entry.segments)
	assert(luau.compile(original, options) == luau.compile(aligned, options), `Bytecode changed: {path}`)
	sources[path] = packed
	count += 1
end

if sourcesOnly then
	print(`Verified identical executable bytecode for {count} staged modules.`)
	return
end

local function verifyModel(filename: string, paths: { string }, readme: boolean?)
	local expected: { [string]: number } = {}
	for _, path in paths do
		local source = assert(sources[path], `Missing staged module: {path}`)
		expected[source] = (expected[source] or 0) + 1
	end
	if readme then
		local source = fs.readFile(staging .. "bundle/README.luau")
		expected[source] = (expected[source] or 0) + 1
	end
	local function visit(instance: any)
		if instance:IsA("LuaSourceContainer") then
			local source = instance.Source
			assert((expected[source] or 0) > 0, `Unexpected source in {filename}: {instance:GetFullName()}`)
			expected[source] -= 1
		end
		for _, child in instance:GetChildren() do
			visit(child)
		end
	end
	for _, root in roblox.deserializeModel(fs.readFile(filename)) do
		visit(root)
	end
	for _, remaining in expected do
		assert(remaining == 0, `Missing module in {filename}`)
	end
end

local function pathsUnder(prefix: string): { string }
	local paths = {}
	for path in sources do
		if string.sub(path, 1, #prefix) == prefix then
			table.insert(paths, path)
		end
	end
	return paths
end

verifyModel("Scribe.rbxm", pathsUnder("src/"), true)
verifyModel("ScribeTelemetry-Addon.rbxm", pathsUnder("addons/telemetry/ScribeTelemetry/"))
verifyModel("ScribeUIAdapters-Addon.rbxm", {
	"addons/ui/ScribeVide.luau",
	"addons/ui/ScribeReact.luau",
	"addons/ui/ScribeFusion.luau",
})
verifyModel("ScribeLeaderstats-Addon.rbxm", { "addons/leaderstats/ScribeLeaderstats.luau" })
print(`Verified identical executable bytecode for {count} staged modules and source contents of all four models.`)
