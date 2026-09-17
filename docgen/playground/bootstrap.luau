-- Appended to the generated module bundle. Roblox services are deliberately absent.
-- The template and action functions are compiled separately, so they cannot access
-- the bundle's local module table, store objects, or mock service handles.

-- Globals are read-only here, so user code gets print and warn as shadowing
-- parameters. Formatting in Luau keeps nil, tables and floats reading as Studio prints them.
local function formatted(send: ((string) -> ())?): (...any) -> ()
    return function(...)
        if send == nil then return end
        local parts = table.create(select("#", ...))
        for index = 1, select("#", ...) do
            parts[index] = tostring((select(index, ...)))
        end
        send(table.concat(parts, "\t"))
    end
end
local userPrint, userWarn = formatted(print), formatted(warn)
local function display(value: any): string
    -- One global budget per snapshot, including keys. Nested breadth cannot turn
    -- a per-level entry limit into hundreds of thousands of rendered values.
    local parts, seen = {}, {}
    local remaining, visited = 5960, 0
    local truncated = false
    local function write(text: string)
        if remaining <= 0 then truncated = true; return end
        if #text > remaining then
            -- Do not split a UTF-8 code point at the display boundary.
            local cut = string.sub(text, 1, remaining)
            while #cut > 0 and utf8.len(cut) == nil do cut = string.sub(cut, 1, -2) end
            table.insert(parts, cut)
            remaining = 0
            truncated = true
        else
            table.insert(parts, text)
            remaining -= #text
        end
    end
    local render
    render = function(item: any, depth: number)
        if remaining <= 0 or visited >= 200 then truncated = true; return end
        visited += 1
        if type(item) == "string" then
            local text = string.sub(item, 1, 400)
            while #text > 0 and utf8.len(text) == nil do text = string.sub(text, 1, -2) end
            write(string.format("%q", text .. (if #item > #text then "…" else "")))
        elseif type(item) ~= "table" then
            write(tostring(item))
        elseif seen[item] then
            write("<cycle>")
        elseif depth >= 5 then
            write("<nested table>")
        else
            seen[item] = true
            local keys = {}
            for key in item do
                table.insert(keys, key)
                if #keys == 51 then break end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            write("{")
            for index, key in keys do
                if remaining <= 0 or visited >= 200 then truncated = true; break end
                if index > 1 then write(",") end
                write("\n" .. string.rep("  ", depth + 1))
                if index > 50 then write("…"); break end
                write("["); render(key, depth + 1); write("] = ")
                render(item[key], depth + 1)
            end
            if #keys > 0 then write("\n" .. string.rep("  ", depth)) end
            write("}")
            seen[item] = nil
        end
    end
    render(value, 0)
    if truncated then table.insert(parts, "\n[Snapshot display limit reached]") end
    return table.concat(parts)
end

-- HttpService is a stub, so the schema is hand-encoded.
local function json(value: any, depth: number?): string
    local level = depth or 0
    local kind = type(value)
    if kind == "string" then
        local escaped = string.gsub(value, '[%c"\\]', function(c)
            if c == '"' then return '\\"' end
            if c == "\\" then return "\\\\" end
            if c == "\n" then return "\\n" end
            if c == "\t" then return "\\t" end
            return string.format("\\u%04x", string.byte(c))
        end)
        return '"' .. escaped .. '"'
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        return string.format("%.17g", value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" and level < 12 then
        if #value > 0 or next(value) == nil then
            local items = {}
            for _, item in ipairs(value) do table.insert(items, json(item, level + 1)) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local keys = {}
        for key in value do
            if type(key) == "string" then table.insert(keys, key) end
        end
        table.sort(keys)
        local items = {}
        for _, key in keys do table.insert(items, json(key) .. ":" .. json(value[key], level + 1)) end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

local function schemaOf(node: any): any
    local out = {
        name = node.Name,
        type = node.ValueType,
        container = node.Container,
        unique = node.Unique,
        keyType = node.KeyType,
        nullable = node.Nullable,
        timed = node.Timed,
        derived = node.Derived ~= nil,
        persist = node.Persist,
        visibility = node.Visibility,
        min = node.Min,
        max = node.Max,
        maxLength = node.MaxLength,
        maxItems = node.MaxItems,
        maxKeys = node.MaxKeys,
        members = node.Members,
        default = if type(node.Default) == "function" then nil else node.Default,
    }
    if node.Children then
        local children = {}
        for _, key in node.ChildOrder or {} do
            local child = node.Children[key]
            -- _Scribe and _ScribeSession are bookkeeping roots.
            if child and not string.find(child.Name or "", "^_Scribe") then table.insert(children, schemaOf(child)) end
        end
        out.children = children
    end
    if node.Container and node.AnyChild then
        out.element = schemaOf(node.AnyChild)
    end
    return out
end

local function newTree(templateFactory, policy)
    local compiled = modules.Template.Compile(templateFactory(Scribe, userPrint, userWarn))
    local tree = modules.Node.NewTree({
        Compiled = compiled,
        Stores = {
            Persist = modules.Template.BuildDefaults(compiled, "Persistent"),
            Session = modules.Template.BuildDefaults(compiled, "Session"),
        },
        IsServer = true,
        Label = "playground",
        BoundsPolicy = policy,
        DevMode = false,
        LogError = function(message) print("Error: " .. message) end,
        LogWarn = function(message) print("Warning: " .. message) end,
    })
    return compiled, tree
end

local function run(templateFactory, actions, policy)
    assert(policy == "Clamp" or policy == "Reject", "Choose Clamp or Reject")
    local _, tree = newTree(templateFactory, policy)
    local before = display(tree.Accessor.Get())
    local ok, reason = pcall(actions, tree.Accessor, Scribe, userPrint, userWarn)
    local after = display(tree.Accessor.Get())
    return ok, before, after, if ok then "" else tostring(reason)
end

-- Compiles the template alone: true and the schema as JSON, or false and the error.
local function describe(templateFactory)
    local ok, result = pcall(function()
        local compiled = newTree(templateFactory, "Clamp")
        return json(schemaOf(compiled.Root))
    end)
    return ok, if ok then result else tostring(result)
end

return run, describe
