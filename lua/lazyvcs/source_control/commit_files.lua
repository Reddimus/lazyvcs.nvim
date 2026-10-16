local M = {}
local sequence = 0

local function directory()
	return vim.fn.stdpath("cache") .. "/lazyvcs/commit"
end

function M.create(message)
	local dir = directory()
	local ok, err = pcall(vim.fn.mkdir, dir, "p", 448)
	if not ok then
		return nil, "Could not create private commit directory: " .. tostring(err)
	end
	local private, chmod_err = vim.uv.fs_chmod(dir, 448)
	if not private then
		return nil, "Could not protect commit directory: " .. tostring(chmod_err)
	end
	sequence = sequence + 1
	local path = string.format("%s/%d-%.0f-%d.txt", dir, vim.fn.getpid(), vim.uv.hrtime(), sequence)
	local fd, open_err = vim.uv.fs_open(path, "wx", 384)
	if not fd then
		return nil, "Could not create private commit message: " .. tostring(open_err)
	end
	local written_ok, written, write_err = pcall(require("lazyvcs.fs").write_all, fd, message, 0)
	local closed, close_err = vim.uv.fs_close(fd)
	if not written_ok or not written or not closed then
		pcall(vim.uv.fs_unlink, path)
		return nil, "Could not write commit message: " .. tostring(written_ok and (write_err or close_err) or written)
	end
	return path
end

-- A preserved commit can outlive Neovim, so its completion cannot remove its
-- message. Prune abandoned files asynchronously on the next setup.
function M.prune()
	local dir, cutoff = directory(), os.time() - 86400
	pcall(vim.uv.fs_scandir, dir, function(err, scan)
		if err or not scan then
			return
		end
		while true do
			local scanned, name, kind = pcall(vim.uv.fs_scandir_next, scan)
			if not scanned or not name then
				break
			end
			if kind == "file" then
				local path = dir .. "/" .. name
				pcall(vim.uv.fs_stat, path, function(stat_err, stat)
					if not stat_err and stat and stat.type == "file" and stat.mtime.sec < cutoff then
						pcall(vim.uv.fs_unlink, path, function() end)
					end
				end)
			end
		end
	end)
end

return M
