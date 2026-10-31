-- Windows SVN clients can narrow argv and decode patch headers in a legacy
-- codepage. Keep this boundary about filenames; hunk and property bytes are raw.
local util = require("lazyvcs.util")
local M = { error = "Windows SVN patch filenames must be ASCII; native filename encoding is not lossless" }

function M.path(repo, path)
	local relative = util.relative_literal_path(repo.root, path, false) or path
	return not relative:find("[\128-\255]")
end

function M.headers(repo, task, text, guard, done, truncated)
	local limit = #text
	if truncated then
		-- system_start appends one of these exact transport suffixes. Inspect
		-- only captured command bytes; the caller still appends the original text.
		local marker = text:find("\n%.%.%. %[truncated at least [1-9]%d* bytes%]$")
			or text:find("\n%.%.%. %[truncated [1-9]%d* bytes%]$")
		if marker then
			limit = marker - 1
		end
	end
	local cursor, old, new = 1, 0, 0
	local step
	step = function()
		for _ = 1, 4096 do
			if cursor > limit then
				return done()
			end
			local last = text:find("\n", cursor, true)
			last = last and math.min(last, limit + 1) or limit + 1
			local line = text:sub(cursor, last - 1):gsub("\r$", "")
			cursor = last + 1
			local prefix = line:sub(1, 1)
			if old > 0 or new > 0 then
				if prefix == "+" then
					new = new - 1
				elseif prefix == "-" then
					old = old - 1
				elseif prefix == " " then
					old, new = old - 1, new - 1
				elseif prefix ~= "\\" then
					return task:finish(nil, "Malformed SVN patch hunk")
				end
			else
				local left, right = line:match("^[@#][@#] %-%d+(,?%d*) %+%d+(,?%d*) [@#][@#]")
				if left then
					old, new = tonumber(left:sub(2)) or 1, tonumber(right:sub(2)) or 1
				else
					local path = line:match("^Index: (.*)$")
						or line:match("^Property changes on: (.*)$")
						or line:match("^%-%-%- ([^\t]+)")
						or line:match("^%+%+%+ ([^\t]+)")
					if
						(path and not M.path(repo, path))
						or (line:match("^diff %-%-git ") and line:find("[\128-\255]"))
					then
						return task:finish(nil, M.error)
					end
				end
			end
		end
		vim.schedule(guard(step))
	end
	vim.schedule(guard(step))
end

return M
