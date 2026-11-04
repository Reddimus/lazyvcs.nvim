-- Parse the fixed svn info/status/list XML schemas and decode text and attribute
-- entities.
local M = {}

-- SVN uses native separators in local XML paths, but URLs always use '/'.
-- Backslashes remain literal filename bytes on POSIX.
function M.local_path(path)
	return vim.fn.has("win32") == 1 and (path:gsub("\\", "/")) or path
end

local entities = {
	amp = "&",
	apos = "'",
	gt = ">",
	lt = "<",
	quot = '"',
}

local function codepoint(value, base)
	local number = tonumber(value, base)
	if not number or number < 0 or number > 0x10FFFF or (number >= 0xD800 and number <= 0xDFFF) then
		return nil
	end
	if vim.fn and vim.fn.nr2char then
		local ok, char = pcall(vim.fn.nr2char, number)
		if ok then
			return char
		end
	end
	if number <= 0x7F then
		return string.char(number)
	end
	return nil
end

function M.decode(value)
	if type(value) ~= "string" or value == "" then
		return value
	end
	return (
		value:gsub("&([^;]+);", function(entity)
			local hex = entity:match("^#[xX]([%da-fA-F]+)$")
			local decimal = entity:match("^#(%d+)$")
			return entities[entity]
				or (hex and codepoint(hex, 16))
				or (decimal and codepoint(decimal, 10))
				or ("&" .. entity .. ";")
		end)
	)
end

function M.attributes(tag)
	local attrs, cursor = {}, 1
	tag = tag or ""
	while cursor <= #tag do
		local first, last, name = tag:find("([%w_:%-]+)", cursor)
		if not first then
			break
		end
		cursor = last + 1
		local _, value_start, quote = tag:find("^%s*=%s*([\"'])", cursor)
		if value_start then
			local value_end = tag:find(quote, value_start + 1, true)
			if not value_end then
				break
			end
			attrs[name] = M.decode(tag:sub(value_start + 1, value_end - 1))
			cursor = value_end + 1
		end
	end
	return attrs
end

local function open_tag(block, name)
	block = block or ""
	local needle = "<" .. name
	local start = 1
	while true do
		local first = block:find(needle, start, true)
		if not first then
			return nil
		end
		local boundary = block:sub(first + #needle, first + #needle)
		if boundary == ">" or boundary == "/" or boundary:match("%s") then
			local last = block:find(">", first + #needle, true)
			return last and block:sub(first, last) or nil
		end
		start = first + #needle
	end
end

local function child_text(block, name)
	name = vim.pesc(name)
	local value = (block or ""):match("<" .. name .. "%f[%s/>][^>]*>(.-)</" .. name .. "%s*>")
	return value and M.decode(value) or nil
end

local function each_entry(raw)
	local entries = {}
	for block in (raw or ""):gmatch("<entry%f[%s>].-</entry%s*>") do
		entries[#entries + 1] = block
	end
	return entries
end

function M.parse_info(raw)
	local block = each_entry(raw)[1]
	if not block then
		return nil
	end
	local entry = M.attributes(open_tag(block, "entry"))
	return {
		url = child_text(block, "url"),
		root = child_text(block, "root"),
		wcroot_abspath = child_text(block, "wcroot-abspath"),
		revision = entry.revision,
		path = entry.path and M.local_path(entry.path),
		kind = entry.kind,
		schedule = child_text(block, "schedule"),
		copy_from_url = child_text(block, "copy-from-url"),
		copy_from_revision = child_text(block, "copy-from-rev"),
		checksum = child_text(block, "checksum"),
	}
end

-- Root discovery needs a complete record; the other info consumers also accept
-- fragments from their existing bounded command protocols.
function M.wcroot_abspath(raw)
	local invalid = "SVN returned incomplete or invalid working-copy root XML"
	if type(raw) ~= "string" or not require("lazyvcs.compare_text").valid_utf8(raw) then
		return nil, invalid
	end
	local body = raw:gsub("^%s*<%?xml%s.-%?>", "")
	if not body:match("^%s*<info>%s*<entry%f[%s>]") or not body:match("</entry>%s*</info>%s*$") then
		return nil, invalid
	end
	local stack, cursor, counts = {}, 1, {}
	while true do
		local first, last, tag = body:find("<([^>]+)>", cursor)
		if not first then
			break
		end
		if body:sub(cursor, first - 1):find("<", 1, true) then
			return nil, invalid
		end
		local closing, name, suffix = tag:match("^(/?)([%w_:%-]+)(.*)$")
		if not name then
			return nil, invalid
		end
		if closing == "/" then
			if not suffix:match("^%s*$") or table.remove(stack) ~= name then
				return nil, invalid
			end
		else
			counts[name] = (counts[name] or 0) + 1
			if not suffix:match("/%s*$") then
				stack[#stack + 1] = name
			end
		end
		cursor = last + 1
	end
	if
		#stack ~= 0
		or body:sub(cursor):find("<", 1, true)
		or counts.info ~= 1
		or counts.entry ~= 1
		or counts["wc-info"] ~= 1
		or counts["wcroot-abspath"] ~= 1
	then
		return nil, invalid
	end
	local info = body:match("<wc%-info%f[%s>][^>]*>(.-)</wc%-info>")
	local value = info and info:match("<wcroot%-abspath>([^<]*)</wcroot%-abspath>")
	if not value then
		return nil, invalid
	end
	local valid = true
	local remaining = value:gsub("&([^;]*);", function(entity)
		local hex, decimal = entity:match("^#[xX]([%da-fA-F]+)$"), entity:match("^#(%d+)$")
		if
			(hex and tonumber(hex, 16) == 0)
			or (decimal and tonumber(decimal) == 0)
			or (not entities[entity] and not (hex and codepoint(hex, 16)) and not (decimal and codepoint(decimal, 10)))
		then
			valid = false
		end
		return ""
	end)
	local decoded = M.decode(value)
	if not valid or remaining:find("&", 1, true) or decoded == "" or decoded:find("%z") then
		return nil, invalid
	end
	return M.local_path(decoded)
end

function M.parse_info_entries(raw)
	local entries = {}
	for _, block in ipairs(each_entry(raw)) do
		local entry = M.attributes(open_tag(block, "entry"))
		if entry.path then
			entries[#entries + 1] = { path = M.local_path(entry.path), kind = entry.kind }
		end
	end
	return entries
end

function M.parse_status(raw)
	local entries = {}
	for _, block in ipairs(each_entry(raw)) do
		local entry = M.attributes(open_tag(block, "entry"))
		local wc = M.attributes(open_tag(block, "wc-status"))
		local repos_tag = open_tag(block, "repos-status")
		local repos = M.attributes(repos_tag)
		if entry.path and wc.item then
			entries[#entries + 1] = {
				path = M.local_path(entry.path),
				wc_item = wc.item,
				wc_props = wc.props or "none",
				repos_item = repos_tag and (repos.item or "none") or "none",
				repos_props = repos_tag and (repos.props or "none") or "none",
				revision = wc.revision,
				tree_conflicted = wc["tree-conflicted"] == "true",
				switched = wc.switched == "true",
				copied = wc.copied == "true",
				file_external = wc["file-external"] == "true",
			}
		end
	end
	return entries
end

function M.parse_list(raw)
	local entries = {}
	for _, block in ipairs(each_entry(raw)) do
		local entry = M.attributes(open_tag(block, "entry"))
		local commit = M.attributes(open_tag(block, "commit"))
		local name = child_text(block, "name")
		if entry.kind == "dir" and name and name ~= "" then
			entries[#entries + 1] = {
				name = name:gsub("/$", ""),
				revision = commit.revision or "",
				author = child_text(block, "author") or "",
				date = child_text(block, "date") or "",
			}
		end
	end
	return entries
end

return M
