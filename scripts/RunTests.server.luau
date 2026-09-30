--!nonstrict
-- Visible startup for the isolated Studio test place. Ordinary server Scripts
-- cannot read ModuleScript.Source, which unmodified Jest needs for its loader.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	warn("[Scribe tests] This test place is intended for Roblox Studio.")
	return
end

print("[Scribe tests] Studio test place started.")
local root = game:GetService("ReplicatedStorage"):FindFirstChild("ScribeDev")
assert(root and root:FindFirstChild("Test"), "[Scribe tests] Missing ScribeDev.Test; rebuild test.project.json")
local runTests = root.Test:FindFirstChild("RunTests")
assert(runTests and runTests:IsA("ModuleScript"), "[Scribe tests] Missing Test.RunTests ModuleScript")
assert(
	root:FindFirstChild("DevPackages") and root.DevPackages:FindFirstChild("Jest"),
	"[Scribe tests] Run wally install, then rebuild test.project.json"
)

local specCount = 0
for _, descendant in root.Test.Specs:GetDescendants() do
	if descendant:IsA("ModuleScript") and string.match(descendant.Name, "%.spec$") then
		specCount += 1
	end
end
assert(specCount > 0, "[Scribe tests] No spec modules found; rebuild test.project.json")
print(`[Scribe tests] Found {specCount} spec modules.`)

local canReadSource = pcall(function()
	return runTests.Source
end)
if canReadSource then
	-- Supports a host that grants source access without weakening its permissions.
	require(runTests)()
	return
end

warn("[Scribe tests] Tests have not started: Jest needs the Studio command bar's script-source permissions.")
print("[Scribe tests] While Run is active, select the SERVER command bar and execute:")
print('require(game:GetService("ReplicatedStorage").ScribeDev.Test.RunTests)()')
