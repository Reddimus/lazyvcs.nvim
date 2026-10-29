-- Bounded, asynchronous filesystem work for SVN's unversioned diff sections.
local uv = vim.uv
local util = require("lazyvcs.util")
local M = {}

function M.section(rel, text)
	local header = "Index: " .. rel .. "\n" .. string.rep("=", 67) .. "\n"
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
	uv.fs_open(file, "r", 438, function(open_err, fd)
		if not fd then
			return vim.schedule(guard(function()
				task:finish(nil, open_err)
			end))
		end
		-- Every path closes the descriptor, including a cancelled pending read.
		local chunks, size = {}, 0
		local read
		read = function()
			uv.fs_read(fd, math.min(65536, limit - size), size, function(err, bytes)
				local binary = bytes and size == 0 and bytes:sub(1, 8192):find("\0", 1, true)
				if bytes then
					chunks[#chunks + 1], size = bytes, size + #bytes
				end
				if task:is_active() and not err and bytes ~= "" and size < limit and not binary then
					return read()
				end
				uv.fs_close(fd, function()
					vim.schedule(guard(function()
						if err then
							return task:finish(nil, err)
						end
						done(table.concat(chunks), not binary and size >= limit)
					end))
				end)
			end)
		end
		read()
	end)
end

function M.files(task, repo, paths, guard, done, switched)
	require("lazyvcs.backends.svn_ignore").load(
		task,
		repo,
		guard(function(ignored, err)
			if not ignored then
				return task:finish(nil, err)
			end
			local files, visited, scanned = {}, 0, 0
			local visit
			visit = guard(function()
				local current = table.remove(paths)
				if not current then
					table.sort(files)
					return done(files)
				end
				visited = visited + 1
				if visited > 10000 then
					return task:finish(nil, "Too many unversioned paths; narrow the patch path")
				end
				uv.fs_lstat(current, function(stat_err, stat)
					vim.schedule(guard(function()
						if stat_err then
							return task:finish(nil, stat_err)
						end
						if stat.type == "file" then
							files[#files + 1] = current
							return visit()
						end
						-- Do not follow directory symlinks out of the requested subtree.
						if stat.type ~= "directory" then
							return visit()
						end
						uv.fs_scandir(current, function(scan_err, scanner)
							local consume
							consume = guard(function()
								if scan_err then
									return task:finish(nil, scan_err)
								end
								for _ = 1, 128 do
									local name = uv.fs_scandir_next(scanner)
									if not name then
										return visit()
									end
									scanned = scanned + 1
									local child = util.normalize_literal_path(current .. "/" .. name)
									if name ~= ".svn" and name ~= ".git" and not ignored(child, name) then
										paths[#paths + 1] = child
									end
									if #paths + visited > 10000 or scanned > 100000 then
										return task:finish(nil, "Too many unversioned paths; narrow the patch path")
									end
								end
								vim.schedule(consume)
							end)
							vim.schedule(consume)
						end)
					end))
				end)
			end)
			visit()
		end),
		switched
	)
end

return M
