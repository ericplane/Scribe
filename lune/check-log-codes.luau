--!strict
-- Every log code Scribe emits must be declared in Types.LogCode and documented
-- in the log-codes guide -- AND every code declared or documented must actually
-- be emitted. Both directions, because the decay runs both ways.
--
-- WHY THIS IS A GATE RATHER THAN A CONVENTION. Nothing else checks it. The type
-- union is only enforced where a value is annotated as a LogCode, and Log.Warn
-- takes its code as a plain string, so an unregistered code type-checks
-- perfectly; and CI's analyze step covers test/TypeCheck.luau by explicit design,
-- which never names one. The result is silent decay, measured: the four codes
-- added by the frame-fragmentation work registered 0 of 4 in the union and 3 of 4
-- in the docs, and PURCHASE_DUPLICATE had been missing from both for longer.
--
-- The union is what a game's own LogCode-typed handler switches on, and the guide
-- is where an operator looks a code up after seeing one in the console. A code
-- absent from either is a code nobody can handle or explain; a code present in
-- either but emitted nowhere is a promise the library no longer keeps.

local fs = require("@lune/fs")
local process = require("@lune/process")

local function readAll(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			readAll(path, out)
		elseif string.sub(name, -5) == ".luau" then
			table.insert(out, path)
		end
	end
end

-- Codes EMITTED. Scribe emits through more doors than any one call shape
-- describes, and every previous version of this gate was written around the doors
-- that existed when it was written -- which is how it spent two tiers blind to 19
-- codes while printing "all declared and documented".
--
-- So the patterns below are deliberately shaped by ARGUMENT POSITION rather than
-- by callee name. `Log.Warn("Replication", "OP_BEFORE_INIT", ...)` and
-- `report("Persistence", "PROFILE_SCHEMA_VIOLATION", ...)` -- where `report` is a
-- local bound to Log.Warn or Log.Error by a conditional -- are the same shape, and
-- naming the callee would have caught only the first. It did: that emission at
-- src/Server/Persistence.luau shipped undocumented, and the gate said all clear.
--
--   1. <anything>("<Category>", "<CODE>"   -- any logger, aliased or not
--   2. Code = "<CODE>"                     -- Failure.Report{ Code = ... }
--   3. throttledWarn(<entry>, "<CODE>"     -- Commands' per-player throttle
--   4. <anything>("<CODE>"                 -- Node's onIssue(code, label, detail)
--
-- Shape 4 is as broad as it looks and that is safe here rather than lucky:
-- measured across all of src/ it matches exactly three call sites, all of them log
-- codes. If it ever starts matching an unrelated SCREAMING_CASE first argument,
-- this gate fails loudly and someone narrows it -- which is the right failure
-- direction. `%s*` spans newlines, so the multi-line call sites are covered too.
--
-- Shape 3 is the one exception to the argument-position rule, and it is named
-- rather than general BECAUSE the general version was tried and measured wrong:
-- `<anything>(<identifier>, "<CODE>"` also matches
-- `pcall(ProfileStore.SetConstant, "AUTO_SAVE_PERIOD", interval)` at
-- src/Server/Persistence.luau:305, and reported a ProfileStore tuning constant as
-- an unregistered log code. A second throttling wrapper would be invisible to
-- this shape -- but not to the gate: the reverse check below turns an emission
-- the patterns cannot see into a RED build naming the code, not a silent gap.
--
-- The vendored store is excluded -- it is upstream code kept line-identical and
-- does not use Scribe's logger.
local EMISSION_PATTERNS = {
	'[%w_.:]+%(%s*"%a+"%s*,%s*"([A-Z][A-Z0-9_]+)"',
	'Code%s*=%s*"([A-Z][A-Z0-9_]+)"',
	'throttledWarn%(%s*[%w_.]+%s*,%s*"([A-Z][A-Z0-9_]+)"',
	'[%w_.:]+%(%s*"([A-Z][A-Z0-9_]+)"',
}

local emitted: { [string]: string } = {}
local files: { string } = {}
readAll("src", files)
for _, path in files do
	if string.find(path, "src/Internal/Store/", 1, true) then
		continue
	end
	local source = fs.readFile(path)
	for _, pattern in EMISSION_PATTERNS do
		for code in string.gmatch(source, pattern) do
			emitted[code] = path
		end
	end
end

local declared: { [string]: boolean } = {}
for code in string.gmatch(fs.readFile("src/Types.luau"), '|?%s*"([A-Z][A-Z0-9_]+)"') do
	declared[code] = true
end

-- The guide's TABLE ROWS, not every backticked capital in the file. Matching any
-- `LIKE_THIS` span picked up prose -- `AUTO_SAVE_PERIOD` is named inside another
-- code's description, and the sentence explaining autocomplete contains a literal
-- `PRO` -- so the reverse check below would have failed the build on two things
-- that are not codes at all. A row's first cell is the definition; anything else
-- is a mention.
local documented: { [string]: boolean } = {}
for code in string.gmatch(fs.readFile("docgen/guides/log-codes.md"), "\n|%s*`([A-Z][A-Z0-9_]+)`%s*|") do
	documented[code] = true
end

local missingUnion: { string } = {}
local missingDocs: { string } = {}
for code, path in emitted do
	if not declared[code] then
		table.insert(missingUnion, `{code}  (emitted at {path})`)
	end
	if not documented[code] then
		table.insert(missingDocs, `{code}  (emitted at {path})`)
	end
end

-- The reverse direction. A code deleted from src/ but left in the union and the
-- guide is undetectable from the forward checks alone -- the union a game switches
-- on decays silently, and an operator looking up a code they will now never see
-- finds a row describing behaviour that no longer exists.
--
-- Measured when this half was added: RECEIPT_DUPLICATE was emitted at
-- src/Server/Monetization.luau:985 at HEAD b381c89, the emission was dropped while
-- the duplicate check moved earlier, and the union entry, the guide row and the
-- ReceiptsDuplicate metric all stayed. The gate printed "139 emitted, all declared
-- and documented" across that whole change.
--
-- This check is shape-based like the forward one, and that coupling is on purpose:
-- a code emitted through a NEW door the patterns above do not know is reported
-- here as "declared but never emitted", so the gate goes red and names it instead
-- of silently shrinking its own coverage. Loud is the correct failure.
--
-- No allowlist. Every code in the union is emitted today; if one ever genuinely
-- needs to be declared ahead of its use, add it here with a comment saying why,
-- never a pattern that happens to skip it.
local deadUnion: { string } = {}
local deadDocs: { string } = {}
for code in declared do
	if not emitted[code] then
		table.insert(deadUnion, code)
	end
end
for code in documented do
	if not emitted[code] then
		table.insert(deadDocs, code)
	end
end

table.sort(missingUnion)
table.sort(missingDocs)
table.sort(deadUnion)
table.sort(deadDocs)

local total = 0
for _ in emitted do
	total += 1
end

if #missingUnion == 0 and #missingDocs == 0 and #deadUnion == 0 and #deadDocs == 0 then
	print(`log codes: {total} emitted, all declared in Types.LogCode and documented, none stale`)
	return
end

if #missingUnion > 0 then
	print("::error::log codes emitted but missing from the Types.LogCode union:")
	for _, line in missingUnion do
		print(`  {line}`)
	end
end
if #missingDocs > 0 then
	print("::error::log codes emitted but missing from docgen/guides/log-codes.md:")
	for _, line in missingDocs do
		print(`  {line}`)
	end
end
if #deadUnion > 0 then
	print("::error::log codes declared in Types.LogCode but emitted nowhere in src/:")
	for _, code in deadUnion do
		print(`  {code}`)
	end
	print("  Either restore the emission or remove the code from the union and the guide.")
	print("  If it is emitted through a call shape this gate does not know, teach it the shape.")
end
if #deadDocs > 0 then
	print("::error::log codes documented in docgen/guides/log-codes.md but emitted nowhere in src/:")
	for _, code in deadDocs do
		print(`  {code}`)
	end
end
process.exit(1)
