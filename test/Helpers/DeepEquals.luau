--!strict
-- Structural equality for test assertions, with a readable diff message.

local function deepEquals(a: any, b: any, path: string?): (boolean, string?)
	local where = path or "value"
	if type(a) ~= type(b) then
		return false, `{where}: type {type(a)} ~= {type(b)}`
	end
	if type(a) ~= "table" then
		if a ~= b then
			return false, `{where}: {tostring(a)} ~= {tostring(b)}`
		end
		return true, nil
	end
	for key, valueA in a do
		local ok, why = deepEquals(valueA, (b :: any)[key], `{where}.{tostring(key)}`)
		if not ok then
			return false, why
		end
	end
	for key in b :: any do
		if (a :: any)[key] == nil then
			return false, `{where}.{tostring(key)}: missing in expected`
		end
	end
	return true, nil
end

return deepEquals
