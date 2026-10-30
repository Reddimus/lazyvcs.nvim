local M = {}

function M.expand(argument)
	local expanded = argument:gsub("%$(%$?[%w_]*)", function(name)
		if name:sub(1, 1) == "$" then
			return "$" .. name:sub(2)
		end
		return vim.uv.os_getenv(name) or ("$" .. name)
	end)
	local user = argument:match("^~([^/\\]*)")
	if user and user:match("^[%w_.-]*$") then
		local home = user == "" and vim.uv.os_homedir() or vim.fn.expand("~" .. user, true)
		if home and home ~= "" and home ~= "~" .. user then
			expanded = home:gsub("[/\\]$", "") .. expanded:sub(#user + 2)
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
	if windows and parent == "" and path:match("^%a:") then
		parent, prefix = path:sub(1, 2), path:sub(3)
	end
	local ignored = {}
	for _, pattern in ipairs(vim.opt.wildignore:get()) do
		ignored[#ignored + 1] = {
			regex = vim.fn.glob2regpat(pattern),
			directories = pattern:find("/", 1, true) or (windows and pattern:find("\\", 1, true)),
		}
	end
	local function excluded(candidate)
		-- Vim tests directory names with their trailing separator. Patterns with
		-- separators also match the full name; the tail of a directory name is empty.
		local full = vim.fn.fnamemodify(candidate, ":p")
		if not candidate:match("^[/\\]") and not candidate:match("^%a:[/\\]") then
			full = full:gsub("[/\\]$", "")
		end
		local case = vim.o.fileignorecase and "\\c" or "\\C"
		for _, pattern in ipairs(ignored) do
			local regex = case .. pattern.regex
			if
				vim.fn.match(pattern.directories and candidate or "", regex) >= 0
				or (pattern.directories and vim.fn.match(full, regex) >= 0)
			then
				return true
			end
		end
		return false
	end
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
		local folded_name, folded_prefix = name, prefix
		if vim.o.fileignorecase or vim.o.wildignorecase then
			folded_name, folded_prefix = vim.fn.tolower(name), vim.fn.tolower(prefix)
		end
		if
			(name:sub(1, 1) ~= "." or prefix:sub(1, 1) == ".")
			and folded_name:sub(1, #folded_prefix) == folded_prefix
		then
			local candidate = (parent == "" and name:sub(1, 1) == "~") and ("./" .. name) or (parent .. name)
			local stat = (kind == "link" or kind == "unknown") and vim.uv.fs_stat(candidate)
			if (kind == "directory" or (stat and stat.type == "directory")) and not excluded(candidate .. "/") then
				candidates[#candidates + 1] = M.escape(candidate .. "/")
			end
		end
	end
	table.sort(candidates)
	return candidates
end

return M
