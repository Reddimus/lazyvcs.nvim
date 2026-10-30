local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local util = require("lazyvcs.util")
local glob = require("lazyvcs.backends.svn_glob")
local M = {}
local defaults =
	"*.o *.lo *.la *.al .libs *.so *.so.[0-9]* *.a *.pyc *.pyo __pycache__ *.rej *~ #*# .#* .*.swp .DS_Store [Tt]humbs.db"

local function parse(raw, sections)
	local section, key
	for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
		local name = line:match("^%[([^%]]+)%]%s*$")
		if name then
			section, key = name:lower(), nil
			sections[section] = sections[section] or {}
		elseif section and not line:match("^%s*[#;]") then
			if line:match("^%s+") and key then
				sections[section][key] = sections[section][key] .. " " .. util.trim(line)
			else
				local option, value = line:match("^([^:=]+)%s*[:=]%s*(.*)$")
				if option then
					key = util.trim(option):lower()
					sections[section][key] = util.trim(value)
				end
			end
		end
	end
end

-- Ordinary and inherited properties share XML attributes and value encoding.
local function property_values(raw)
	local values = {}
	for tag, attrs, content in raw:gmatch("<([%w_]+)%s+([^>]+)>([^<]*)</[%w_]+>") do
		local attribute = xml.attributes(attrs)
		if (tag == "property" or tag == "inherited_property") and attribute.name == "svn:global-ignores" then
			if attribute.encoding == "base64" then
				local ok, decoded = pcall(vim.base64.decode, (content:gsub("%s", "")))
				if not ok then
					return nil, "Malformed base64 SVN ignore property"
				end
				content = decoded
			elseif attribute.encoding then
				return nil, "Unsupported SVN ignore property encoding: " .. attribute.encoding
			else
				content = xml.decode(content)
			end
			values[#values + 1] = content
		end
	end
	return values
end

function M.load(task, repo, callback, switched)
	local sections = { miscellany = {} }
	local sources
	if vim.fn.has("win32") == 1 then
		sources = {
			{ registry = "HKLM" },
			{ path = (vim.env.PROGRAMDATA or "C:/ProgramData") .. "/Subversion/config" },
			{ registry = "HKCU" },
			{ path = (vim.env.APPDATA or vim.fn.expand("~")) .. "/Subversion/config" },
		}
	else
		sources = { { path = "/etc/subversion/config" }, { path = vim.fn.expand("~/.subversion/config") } }
	end
	local cursor = 0
	local function finish()
		local value = sections.miscellany["global-ignores"] or defaults
		local changed
		for _ = 1, 16 do
			changed = false
			value = value:gsub("%%%((.-)%)s", function(key)
				local replacement = sections.miscellany[key:lower()] or (sections.default or {})[key:lower()]
				if replacement then
					changed = true
					return replacement
				end
			end)
			if not changed then
				break
			end
		end
		if changed then
			return callback(nil, "Cannot resolve SVN ignore configuration interpolation")
		end
		common.command(task, repo, {
			"svn",
			"propget",
			"--xml",
			"--show-inherited-props",
			"-R",
			"svn:global-ignores",
			util.svn_target(repo.root),
		}, function(raw, err)
			if not raw then
				return callback(nil, err)
			end
			local inherited, global, boundaries_at = {}, {}, {}
			local function local_path(path)
				path = xml.local_path(path)
				if path:sub(1, 1) == "/" or (vim.fn.has("win32") == 1 and path:match("^%a:")) then
					return util.normalize_literal_path(path)
				end
				return util.normalize_literal_path(repo.root .. "/" .. path)
			end
			for attrs, body in raw:gmatch("<target%s+([^>]+)>(.-)</target>") do
				local path = xml.attributes(attrs).path
				local values, decode_err = property_values(body)
				if not values then
					return callback(nil, decode_err)
				end
				if path and #values > 0 then
					local content = table.concat(values, "\n")
					if path:match("^%a[%w+.-]*://") then
						global[#global + 1] = content
					else
						inherited[local_path(path)] = content
					end
				end
			end
			local function finish_properties()
				local cache = {}
				local function matches(text, name, property)
					for pattern in text:gmatch(property and "[^\r\n]+" or "%S+") do
						local compiled = cache[pattern]
						if not compiled then
							compiled = glob.compile(pattern)
							cache[pattern] = compiled
						end
						if glob.matches(compiled, name) then
							return true
						end
					end
					return false
				end
				callback(function(path, name)
					if matches(value, name) then
						return true
					end

					local parent = vim.fs.dirname(local_path(path))
					while parent do
						if inherited[parent] and matches(inherited[parent], name, true) then
							return true
						end
						if boundaries_at[parent] then
							return false
						end
						local next_parent = vim.fs.dirname(parent)
						if next_parent == parent then
							break
						end
						parent = next_parent
					end
					for _, text in ipairs(global) do
						if matches(text, name, true) then
							return true
						end
					end
					return false
				end)
			end
			-- Status already reports clean switched nodes. Avoid an info dump of
			-- every versioned file and URL-encoding differences in boundary detection.
			local boundaries = {}
			for _, path in ipairs(switched or {}) do
				boundaries[#boundaries + 1] = local_path(path)
			end
			local index = 0
			local function next_boundary()
				index = index + 1
				local path = boundaries[index]
				if not path then
					return finish_properties()
				end
				common.command(task, repo, {
					"svn",
					"propget",
					"--xml",
					"--show-inherited-props",
					"svn:global-ignores",
					util.svn_target(path),
				}, function(props, props_err)
					if not props then
						return callback(nil, props_err)
					end
					local values, decode_err = property_values(props)
					if not values then
						return callback(nil, decode_err)
					end
					inherited[path] = table.concat(values, "\n")
					boundaries_at[path] = true
					next_boundary()
				end)
			end
			next_boundary()
		end)
	end
	local next_source
	next_source = function()
		cursor = cursor + 1
		local source = sources[cursor]
		if not source then
			return finish()
		end
		if source.registry then
			common.command(task, repo, {
				"reg",
				"query",
				source.registry .. "\\Software\\Tigris.org\\Subversion\\Config\\Miscellany",
				"/v",
				"global-ignores",
			}, function(raw, err, result)
				if not raw and (not result or result.code ~= 1) then
					return callback(nil, err)
				end
				local value = raw and raw:match("global%-ignores%s+REG_SZ%s+([^\r\n]*)")
				if value then
					sections.miscellany["global-ignores"] = value
				end
				next_source()
			end)
		else
			vim.uv.fs_realpath(source.path, function(path_err, resolved)
				vim.schedule(util.safe_callback(function()
					if not task:is_active() then
						return
					end
					if not resolved then
						if tostring(path_err):match("ENOENT") then
							next_source()
						else
							callback(nil, path_err)
						end
						return
					end
					common.read_file(task, resolved, function(raw, err)
						if not raw then
							return callback(nil, err)
						end
						parse(raw, sections)
						next_source()
					end)
				end))
			end)
		end
	end
	next_source()
end

return M
