-- Bounded, asynchronous filesystem work for SVN's unversioned diff sections.
local uv = vim.uv
local util = require("lazyvcs.util")
local M = {}

function M.section(rel, text)
	local header = "Index: " .. rel .. "\n" .. string.rep("=", 67) .. "\n"
	if text == "" then
		-- SVN's native header alone cannot express an empty file addition.
		return "diff --git a/" .. rel .. " b/" .. rel .. "\nnew file mode 100644\n"
	end
	if text:sub(1, 8192):find("\0", 1, true) then
		return header .. "Cannot display: file marked as a binary type.\nsvn:mime-type = application/octet-stream\n"
	end
	local lines = text == "" and {} or vim.split(text, "\n", { plain = true })
	local eol = text:sub(-1) == "\n"
	if eol then
		table.remove(lines)
	end
	local parts = { header, "--- " .. rel .. "\t(nonexistent)\n+++ " .. rel .. "\t(working copy)\n" }
	if #lines > 0 then
		parts[#parts + 1] = "@@ -0,0 +1," .. #lines .. " @@\n+" .. table.concat(lines, "\n+") .. "\n"
		if not eol then
			parts[#parts + 1] = "\\ No newline at end of file\n"
		end
	end
	return table.concat(parts)
end

function M.read(task, file, limit, guard, done)
	local function fail(err)
		vim.schedule(guard(function()
			task:finish(nil, err)
		end))
	end
	local function identified(stat)
		return stat
			and stat.type == "file"
			and type(stat.dev) == "number"
			and stat.dev >= 0
			and type(stat.ino) == "number"
			and stat.ino > 0
	end
	if not task:is_active() then
		return
	end
	-- The walker may have classified this path long before its turn to read.
	uv.fs_lstat(file, function(stat_err, entry)
		if not task:is_active() then
			return
		end
		if not identified(entry) then
			return fail(stat_err or "Patch requires a regular file with a verifiable identity")
		end
		local constants = uv.constants
		-- Nonblocking protects a late FIFO; no-follow rejects late symlinks where
		-- supported. The descriptor identity check also protects portable fallbacks.
		local flags = bit.bor(constants.O_RDONLY, constants.O_NONBLOCK or 0, constants.O_NOFOLLOW or 0)
		uv.fs_open(file, flags, 438, function(open_err, fd)
			if not fd then
				return fail(open_err)
			end
			local chunks, size = {}, 0
			local function close(err, binary)
				-- Only the current I/O callback closes its descriptor. Cancellation must
				-- not close it while libuv still owns an in-flight operation.
				uv.fs_close(fd, function(close_err)
					vim.schedule(guard(function()
						if err or close_err then
							return task:finish(nil, err or close_err)
						end
						done(table.concat(chunks), not binary and size >= limit)
					end))
				end)
			end
			if not task:is_active() then
				return close()
			end
			uv.fs_fstat(fd, function(fd_err, stat)
				if not task:is_active() then
					return close()
				end
				if not identified(stat) or stat.dev ~= entry.dev or stat.ino ~= entry.ino then
					return close(fd_err or "Patch file changed before it could be read")
				end
				local read
				read = function()
					if size >= limit then
						return close()
					end
					uv.fs_read(fd, math.min(65536, limit - size), size, function(err, bytes)
						local binary = bytes and size == 0 and bytes:sub(1, 8192):find("\0", 1, true)
						if bytes then
							chunks[#chunks + 1], size = bytes, size + #bytes
						end
						if task:is_active() and not err and bytes and bytes ~= "" and size < limit and not binary then
							return read()
						end
						close(err, binary)
					end)
				end
				read()
			end)
		end)
	end)
end

function M.files(task, repo, paths, guard, done, switched)
	-- The shared walker bounds discovered children; also bound a flat initial list.
	if #paths > 10000 then
		return task:finish(nil, "Too many unversioned paths; narrow the patch path")
	end
	local entries = {}
	for _, path in ipairs(paths) do
		entries[#entries + 1] = { path = path, wc_item = "unversioned" }
	end
	for _, boundary in ipairs(switched or {}) do
		entries[#entries + 1] = type(boundary) == "table" and boundary or { path = boundary, switched = true }
	end
	require("lazyvcs.backends.svn_untracked").expand(
		task,
		repo,
		entries,
		guard(function(files, err)
			if not files then
				return task:finish(nil, err)
			end
			local absolute = {}
			for _, path in ipairs(files) do
				absolute[#absolute + 1] = util.normalize_literal_path(repo.root .. "/" .. path)
			end
			table.sort(absolute)
			done(absolute)
		end),
		{ files_only = true, missing_is_error = true }
	)
end

return M
