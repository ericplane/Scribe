--!strict
-- Portable CI artifacts, including collection errors and all cleanup failures.
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local function xml(value: any): string
	local text = tostring(value or "")
	-- Reports are plain XML; strip complete color codes before invalid controls.
	text = string.gsub(text, "\27%[[%d;]*m", "")
	text = string.gsub(text, "[%z\1-\8\11\12\14-\31]", "")
	for _, pair in { { "&", "&amp;" }, { "<", "&lt;" }, { ">", "&gt;" }, { '"', "&quot;" }, { "'", "&apos;" } } do
		text = string.gsub(text, pair[1], pair[2])
	end
	return text
end

return function(directory: string, report: any)
	if not fs.isDir(directory) then
		fs.writeDir(directory)
	end
	fs.writeFile(directory .. "/results.json", serde.encode("json", report, true))
	local lines = { '<?xml version="1.0" encoding="UTF-8"?>', '<testsuites name="Scribe">' }
	for _, suite in report.suites or {} do
		local failures, skipped = 0, 0
		for _, test in suite.tests do
			if test.status == "failed" then
				failures += 1
			elseif test.status ~= "passed" then
				skipped += 1
			end
		end
		-- A suite can fail both a test body and afterAll. Preserve the separate
		-- execution error even when a child already contributes a failure.
		local runtimeMessage = suite.runtimeError or (if failures == 0 then suite.failureMessage else nil)
		local runtimeFailure = runtimeMessage ~= nil and runtimeMessage ~= ""
		table.insert(
			lines,
			string.format(
				'<testsuite name="%s" tests="%d" failures="%d" skipped="%d">',
				xml(suite.path),
				#suite.tests + (if runtimeFailure then 1 else 0),
				failures + (if runtimeFailure then 1 else 0),
				skipped
			)
		)
		for _, test in suite.tests do
			table.insert(
				lines,
				string.format(
					'<testcase classname="%s" name="%s" time="%.6f">',
					xml(suite.path),
					xml(test.name),
					(test.duration or 0) / 1000
				)
			)
			if test.status == "failed" then
				table.insert(
					lines,
					'<failure message="Test failed">'
						.. xml(table.concat(test.failureMessages or {}, "\n"))
						.. "</failure>"
				)
			elseif test.status ~= "passed" then
				table.insert(lines, '<skipped message="' .. xml(test.status) .. '"/>')
			end
			table.insert(lines, "</testcase>")
		end
		if runtimeFailure then
			table.insert(
				lines,
				'<testcase name="Suite execution"><failure message="Suite failed">'
					.. xml(runtimeMessage)
					.. "</failure></testcase>"
			)
		end
		table.insert(lines, "</testsuite>")
	end
	if report.infrastructureError then
		table.insert(
			lines,
			'<testsuite name="Test infrastructure" tests="1" errors="1"><testcase name="Runner"><error message="Runner failed">'
				.. xml(report.infrastructureError)
				.. "</error></testcase></testsuite>"
		)
	end
	table.insert(lines, "</testsuites>")
	fs.writeFile(directory .. "/junit.xml", table.concat(lines, "\n") .. "\n")
end
