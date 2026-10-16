local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local util = require("lazyvcs.util")
local M = {}

local function decode(value)
	if value:find("<", 1, true) then
		return nil
	end
	local parts, cursor = {}, 1
	while true do
		local first = value:find("&", cursor, true)
		if not first then
			break
		end
		local last = value:find(";", first + 1, true)
		if not last then
			return nil
		end
		local entity = value:sub(first, last)
		local decoded = xml.decode(entity)
		if decoded == entity then
			return nil
		end
		parts[#parts + 1], parts[#parts + 2] = value:sub(cursor, first - 1), decoded
		cursor = last + 1
	end
	parts[#parts + 1] = value:sub(cursor)
	return table.concat(parts)
end

local function parse(raw, expected)
	local body = raw:gsub("^%s*<%?xml.-%?>", ""):match("^%s*<properties>%s*(.-)%s*</properties>%s*$")
	if not body then
		return nil, "Malformed SVN property XML"
	end
	if body == "" then
		return {}
	end
	local attrs, content = body:match("^<target%s+([^>]+)>%s*(.-)%s*</target>$")
	local path = attrs and xml.attributes(attrs).path
	if
		not path
		or (
			path ~= expected
			and (
				path:match("^%a[%w+.-]*://")
				or util.normalize_literal_path(xml.local_path(path)) ~= util.normalize_literal_path(expected)
			)
		)
	then
		return nil, "Unexpected SVN property target"
	end
	local properties, cursor, size = {}, 1, 0
	while cursor <= #content do
		local first, last, attributes = content:find("^%s*<property%s+([^>]+)>", cursor)
		if not first then
			return nil, "Malformed SVN property XML"
		end
		local attribute = xml.attributes(attributes)
		local value
		if attributes:match("/%s*$") then
			value, cursor = "", last + 1
		else
			local close, finish = content:find("</property>", last + 1, true)
			if not close then
				return nil, "Malformed SVN property XML"
			end
			value, cursor = content:sub(last + 1, close - 1), finish + 1
		end
		if attribute.encoding == "base64" then
			local ok, decoded = pcall(vim.base64.decode, (value:gsub("%s", "")))
			value = ok and decoded or nil
		elseif not attribute.encoding then
			value = decode(value)
		else
			value = nil
		end
		local name = attribute.name
		if not name or name == "" or value == nil or properties[name] ~= nil then
			return nil, "Malformed SVN property XML"
		end
		size = size + #name + #value
		if size > common.max_file_bytes then
			return nil, "Decoded properties exceed the 1 MiB limit"
		end
		properties[name] = value
		local _, whitespace = content:find("^%s*", cursor)
		cursor = (whitespace or cursor - 1) + 1
	end
	return properties
end

local function printable(value)
	if value:find("[%z\1-\8\11\12\14-\31]") or vim.fn.strtrans(value):find("<[%x][%x]>") then
		return "[base64] " .. vim.base64.encode(value) .. "\n"
	end
	return value
end

local function display(value)
	return (value:gsub("[%c]", function(char)
		return string.format("\\%03d", char:byte())
	end))
end

local function render(path, before, after)
	local names, seen, lines, size = {}, {}, {}, 0
	for name in pairs(before) do
		names[#names + 1], seen[name] = name, true
	end
	for name in pairs(after) do
		if not seen[name] then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	local function append(value)
		size = size + #value + 1
		if size > common.max_file_bytes then
			return false
		end
		lines[#lines + 1] = value
		return true
	end
	for _, name in ipairs(names) do
		local old, new = before[name], after[name]
		if old ~= new then
			if #lines == 0 then
				if not append("Property changes on: " .. display(path)) or not append(string.rep("_", 67)) then
					return nil, "Property patch exceeds the 1 MiB preview limit"
				end
			end
			local action = old == nil and "Added" or new == nil and "Deleted" or "Modified"
			local patch = require("lazyvcs.compat").diff(
				printable(old or ""),
				printable(new or ""),
				{ result_type = "unified", ctxlen = 3 }
			)
			if not append(action .. ": " .. display(name)) then
				return nil, "Property patch exceeds the 1 MiB preview limit"
			end
			for _, line in ipairs(util.split_lines(patch)) do
				if not append(line) then
					return nil, "Property patch exceeds the 1 MiB preview limit"
				end
			end
		end
	end
	return #lines > 0 and lines or nil
end

---@param task table
---@param snapshot table
---@param item table
---@param done fun(lines: string[]?, err: string?)
function M.load_directory_patch(task, snapshot, item, done)
	local path = snapshot.root .. "/" .. item.relpath
	local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, item.relpath)
	local function read(target, revision, callback)
		local args = { "svn", "--non-interactive", "proplist", "--xml", "--verbose", "--depth", "empty" }
		if revision then
			vim.list_extend(args, { "-r", revision })
		end
		vim.list_extend(args, { "--", target .. "@" .. (revision or "") })
		common.command(task, snapshot, args, function(raw, err, result)
			if result and (result.stdout_truncated or result.stderr_truncated) then
				return callback(nil, "Property XML exceeds its transport limit")
			end
			if not raw then
				return callback(nil, err)
			end
			local ok, properties, parse_err = pcall(parse, raw, target)
			if not ok then
				return callback(nil, "Malformed SVN property XML")
			end
			callback(properties, parse_err)
		end, { output_limit_bytes = 16 * common.max_file_bytes })
	end
	local function finish(before, after)
		local ok, lines, err = pcall(render, item.relpath, before, after)
		if not ok then
			return done(nil, "Could not render SVN properties")
		end
		done(lines, err)
	end
	local function working(before)
		if item.status == "D" then
			return finish(before, {})
		end
		read(path, nil, function(after, err)
			if not after then
				return done(nil, err)
			end
			finish(before, after)
		end)
	end
	if item.status == "A" then
		working({})
	else
		read(url, snapshot.revision, function(before, err)
			if not before then
				return done(nil, err)
			end
			working(before)
		end)
	end
end

return M
