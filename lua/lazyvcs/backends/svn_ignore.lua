local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local util = require("lazyvcs.util")
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

function M.load(task, repo, callback)
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
		for _ = 1, 16 do
			local changed = false
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
		if value:find("%%%(.-%)s") then
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
			local inherited, global = {}, {}
			for attrs, body in raw:gmatch("<target%s+([^>]+)>(.-)</target>") do
				local path = xml.attributes(attrs).path
				local content = body:match('<property%s+name="svn:global%-ignores"[^>]*>(.-)</property>')
					or body:match('<inherited_property%s+name="svn:global%-ignores"[^>]*>(.-)</inherited_property>')
				if path and content then
					if path:match("^%a[%w+.-]*://") then
						global[#global + 1] = xml.decode(content)
					else
						inherited[vim.fs.normalize(path)] = xml.decode(content)
					end
				end
			end
			local cache = {}
			local function matches(text, name, property)
				for pattern in text:gmatch(property and "[^\r\n]+" or "%S+") do
					pattern = util.trim(pattern)
					local regex = cache[pattern]
					if not regex then
						local ok, compiled = pcall(vim.regex, vim.fn.glob2regpat(pattern))
						if ok then
							regex = compiled
							cache[pattern] = regex
						end
					end
					if regex and regex:match_str(name) then
						return true
					end
				end
				return false
			end
			callback(function(path, name)
				if matches(value, name) then
					return true
				end
				for _, text in ipairs(global) do
					if matches(text, name, true) then
						return true
					end
				end
				local parent = vim.fs.dirname(path)
				while parent do
					if inherited[parent] and matches(inherited[parent], name, true) then
						return true
					end
					local next_parent = vim.fs.dirname(parent)
					if next_parent == parent then
						break
					end
					parent = next_parent
				end
				return false
			end)
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
				vim.schedule(function()
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
				end)
			end)
		end
	end
	next_source()
end

return M
