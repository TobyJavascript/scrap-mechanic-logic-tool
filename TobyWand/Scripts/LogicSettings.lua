-- TobyWand: what is remembered between sessions (settings and the script
-- library), as plain tables. The tool reads and writes them with sm.json;
-- this file only packs, checks and restores them, so it runs offline too.

LogicSettings = {}

LogicSettings.VERSION = 1
LogicSettings.NAME_MAX = 40       -- script names
LogicSettings.SCRIPTS_MAX = 200   -- saved scripts

-- spec = {
--   enums = { field = { value, value ... } },  -- state[field] is an index; saved as the value
--   bools = { field, ... },
--   texts = { field = maxLength, ... },
-- }
function LogicSettings.pack(state, spec)
	local out = { version = LogicSettings.VERSION }
	for field, values in pairs(spec.enums or {}) do
		local v = values[state[field]]
		if v ~= nil then out[field] = v end
	end
	for _, field in ipairs(spec.bools or {}) do
		if type(state[field]) == "boolean" then out[field] = state[field] end
	end
	for field, max in pairs(spec.texts or {}) do
		local t = state[field]
		if type(t) == "string" and #t <= max then out[field] = t end
	end
	return out
end

-- Puts the saved values into `state`. Anything missing, of the wrong type or
-- no longer a valid choice keeps its default. Returns how many were skipped.
function LogicSettings.unpack(saved, spec, state)
	if type(saved) ~= "table" then return 0 end
	local skipped = 0
	for field, values in pairs(spec.enums or {}) do
		local v = saved[field]
		if v ~= nil then
			local found
			for i, x in ipairs(values) do
				if x == v then found = i break end
			end
			if found then state[field] = found else skipped = skipped + 1 end
		end
	end
	for _, field in ipairs(spec.bools or {}) do
		local v = saved[field]
		if type(v) == "boolean" then
			state[field] = v
		elseif v ~= nil then
			skipped = skipped + 1
		end
	end
	for field, max in pairs(spec.texts or {}) do
		local v = saved[field]
		if type(v) == "string" and #v <= max then
			state[field] = v
		elseif v ~= nil then
			skipped = skipped + 1
		end
	end
	return skipped
end

---------------------------------------------------------------------------
-- Script library: the player's saved scripts { name =, code = }, kept in
-- name order, followed by the built-in examples (read-only).
---------------------------------------------------------------------------

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The saved list from a file, keeping only well-formed entries.
function LogicSettings.readScripts(saved)
	local out, seen = {}, {}
	local list = type(saved) == "table" and saved.scripts
	if type(list) ~= "table" then return out end
	for _, e in ipairs(list) do
		if type(e) == "table" and type(e.name) == "string" and type(e.code) == "string" then
			local name = trim(e.name)
			if name ~= "" and #name <= LogicSettings.NAME_MAX and not seen[name:lower()] then
				seen[name:lower()] = true
				out[#out + 1] = { name = name, code = e.code }
			end
		end
		if #out >= LogicSettings.SCRIPTS_MAX then break end
	end
	table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
	return out
end

function LogicSettings.packScripts(list)
	local out = {}
	for i, e in ipairs(list) do out[i] = { name = e.name, code = e.code } end
	return { version = LogicSettings.VERSION, scripts = out }
end

-- Every entry the < > buttons step through: saved scripts, then examples.
function LogicSettings.entries(list, examples)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = { name = e.name, code = e.code, example = false } end
	for _, e in ipairs(examples or {}) do out[#out + 1] = { name = e.name, code = e.code, example = true } end
	return out
end

local function indexOf(list, name)
	local key = name:lower()
	for i, e in ipairs(list) do
		if e.name:lower() == key then return i end
	end
end
LogicSettings.indexOf = indexOf

-- Saves `code` as `name` (names ignore case; the same name overwrites).
-- Returns the cleaned name and whether it replaced one, or nil and why not.
function LogicSettings.saveScript(list, name, code)
	name = trim(name or "")
	if name == "" then return nil, "Type a name for the script first" end
	if #name > LogicSettings.NAME_MAX then return nil, "Names can be at most " .. LogicSettings.NAME_MAX .. " characters" end
	local i = indexOf(list, name)
	if i then
		list[i] = { name = name, code = code }
	else
		if #list >= LogicSettings.SCRIPTS_MAX then
			return nil, "The library is full (" .. LogicSettings.SCRIPTS_MAX .. " scripts); delete some first"
		end
		list[#list + 1] = { name = name, code = code }
		table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
	end
	return name, i ~= nil
end

function LogicSettings.deleteScript(list, name)
	local i = indexOf(list, trim(name or ""))
	if not i then return false end
	table.remove(list, i)
	return true
end
