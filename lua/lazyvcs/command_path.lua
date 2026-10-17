local M = {}

function M.expand(argument)
	local expanded = argument:gsub("%$(%$?[%w_]*)", function(name)
		if name:sub(1, 1) == "$" then
			return "$" .. name:sub(2)
		end
		return vim.uv.os_getenv(name) or ("$" .. name)
	end)
	if argument:sub(1, 1) == "~" then
		local home = vim.uv.os_homedir()
		if home then
			expanded = home:gsub("[/\\]$", "") .. expanded:sub(2)
		end
	end
	return expanded
end

function M.escape(literal)
	return vim.fn.escape(literal:gsub("%$", "$$"), "\\ \t")
end

function M.complete(lead)
	local path = M.expand((lead:gsub("\\([\\ \t])", "%1")))
	local windows = vim.fn.has("win32") == 1
	local parent, prefix = path:match(windows and "^(.*[/\\])([^/\\]*)$" or "^(.*/)([^/]*)$")
	parent, prefix = parent or "", prefix or path
	local scan = vim.uv.fs_scandir(parent == "" and "." or parent)
	local candidates = {}
	if not scan then
		return candidates
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(scan)
		if not name then
			break
		end
		local lead_name = name:sub(1, #prefix)
		local fold = vim.o.fileignorecase or vim.o.wildignorecase
		if (fold and lead_name:lower() == prefix:lower()) or (not fold and lead_name == prefix) then
			local candidate = (parent == "" and name:sub(1, 1) == "~") and ("./" .. name) or (parent .. name)
			local stat = (kind == "link" or kind == "unknown") and vim.uv.fs_stat(candidate)
			if kind == "directory" or (stat and stat.type == "directory") then
				candidates[#candidates + 1] = M.escape(candidate .. "/")
			end
		end
	end
	table.sort(candidates)
	return candidates
end

return M
