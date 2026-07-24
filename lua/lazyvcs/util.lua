local M = {}

function M.notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "lazyvcs.nvim" })
end

function M.trim(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.split_lines(text)
	if not text or text == "" then
		return {}
	end

	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines, #lines)
	end
	return lines
end

function M.join_lines(lines)
	if #lines == 0 then
		return ""
	end
	return table.concat(lines, "\n") .. "\n"
end

-- Upper bound for any synchronous VCS call. `proc:wait()` with no timeout blocks
-- the UI thread indefinitely, so a hung `svn` against an unreachable server would
-- freeze Neovim outright. Callers may override via `opts.timeout`.
M.SYNC_TIMEOUT_MS = 30000

function M.system_result(args, opts)
	opts = vim.tbl_extend("keep", opts or {}, { text = true })
	local timeout_ms = opts.timeout or M.SYNC_TIMEOUT_MS
	opts.timeout = nil

	-- vim.system raises synchronously when the executable is missing (ENOENT).
	-- Convert that into a normal non-zero result so callers can handle it via
	-- the usual result.code path instead of crashing.
	local ok, proc = pcall(vim.system, args, opts)
	if not ok then
		return { code = 127, stdout = "", stderr = tostring(proc) }
	end

	-- On timeout `wait()` kills the process and returns nil rather than raising.
	local completed, result = pcall(proc.wait, proc, timeout_ms)
	if not completed or result == nil then
		pcall(proc.kill, proc, "sigkill")
		return {
			code = 124,
			stdout = "",
			stderr = string.format("Timed out after %dms: %s", timeout_ms, table.concat(args, " ")),
		}
	end
	return result
end

function M.system_error(result)
	local stderr = M.trim(result and result.stderr)
	local stdout = M.trim(result and result.stdout)
	return stderr ~= "" and stderr or stdout
end

function M.system(args, opts)
	local result = M.system_result(args, opts)
	if result.code ~= 0 then
		return nil, M.system_error(result)
	end
	return result
end

function M.system_start(args, opts, on_exit)
	opts = opts or {}
	local timeout_ms = opts.timeout
	opts.timeout = nil
	local done = false
	local handle
	local timer
	if timeout_ms and timeout_ms > 0 then
		timer = vim.defer_fn(function()
			if done or not handle then
				return
			end
			done = true
			pcall(handle.kill, handle, 15)
			if type(on_exit) == "function" then
				vim.schedule(function()
					on_exit(nil, string.format("Timed out after %dms: %s", timeout_ms, table.concat(args, " ")))
				end)
			end
		end, timeout_ms)
	end
	local ok, proc = pcall(vim.system, args, vim.tbl_extend("keep", opts, { text = true }), function(result)
		if done then
			return
		end
		done = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if type(on_exit) ~= "function" then
			return
		end
		vim.schedule(function()
			if result.code ~= 0 then
				return on_exit(nil, M.system_error(result), result)
			end
			on_exit(result, nil, result)
		end)
	end)
	if not ok then
		done = true
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if type(on_exit) == "function" then
			vim.schedule(function()
				local result = { code = 127, stdout = "", stderr = tostring(proc) }
				on_exit(nil, M.system_error(result), result)
			end)
		end
		return nil
	end
	handle = proc
	return handle
end

--- Run async jobs one at a time per key.
---
--- Subversion takes an exclusive working-copy lock, so concurrent `svn`
--- processes against one working copy serialize inside svn itself — each waiting
--- one holds the lock for as long as its peer runs. Buffer navigation fires the
--- signs, blame and live-diff paths at once, so without this they pile up and a
--- single slow command stalls all of them. Git has no such lock and is unqueued.
---@param key string
---@param start fun(done: fun()) spawns the job; must call `done` exactly once
function M.enqueue(key, start)
	local queue = M._queues[key]
	if not queue then
		queue = { running = false, pending = {} }
		M._queues[key] = queue
	end

	local function run_next()
		local next_job = table.remove(queue.pending, 1)
		if not next_job then
			queue.running = false
			-- Drop the empty queue so long-lived sessions do not accumulate one
			-- table per working copy ever visited.
			M._queues[key] = nil
			return
		end
		queue.running = true
		local finished = false
		next_job(function()
			if finished then
				return
			end
			finished = true
			vim.schedule(run_next)
		end)
	end

	queue.pending[#queue.pending + 1] = start
	if not queue.running then
		run_next()
	end
end

M._queues = {}

function M.system_lines(args, opts)
	local result, err = M.system(args, opts)
	if not result then
		return nil, err
	end
	return M.split_lines(result.stdout), nil
end

function M.system_lines_start(args, opts, on_exit)
	return M.system_start(args, opts, function(result, err, raw)
		if err then
			return on_exit(nil, err, raw)
		end
		on_exit(M.split_lines(result.stdout), nil, raw)
	end)
end

--- Path of `path` relative to `root`.
---
--- Never returns nil: callers concatenate the result into buffer names and VCS
--- arguments. `vim.fs.relpath` returns nil whenever the two paths share no
--- textual prefix, which happens on Windows when one side is an 8.3 short name
--- (`C:/Users/RUNNER~1/...`) and the other is the long form
--- (`C:/Users/runneradmin/...`) — the same directory, spelled differently.
---@return string
function M.relpath(root, path)
	if not root or root == "" then
		return path
	end

	local rel = vim.fs.relpath and vim.fs.relpath(root, path)
	if rel then
		return rel
	end

	local function strip_prefix(base, target)
		if target:sub(1, #base) == base then
			local out = target:sub(#base + 2)
			if out ~= "" then
				return out
			end
		end
		return nil
	end

	-- Resolve symlinks and short names, then retry.
	local real_root = vim.uv.fs_realpath(root)
	local real_path = vim.uv.fs_realpath(path)
	if real_root and real_path then
		real_root, real_path = vim.fs.normalize(real_root), vim.fs.normalize(real_path)
		rel = vim.fs.relpath and vim.fs.relpath(real_root, real_path)
		if rel then
			return rel
		end
		rel = strip_prefix(real_root, real_path)
		if rel then
			return rel
		end
	end

	return strip_prefix(root, path) or vim.fs.basename(path)
end

function M.slice(lines, start_line, count)
	if count <= 0 then
		return {}
	end

	local start_idx = math.max(start_line, 1)
	local stop_idx = math.min(start_idx + count - 1, #lines)
	local out = {}
	for idx = start_idx, stop_idx do
		out[#out + 1] = lines[idx]
	end
	return out
end

function M.get_buf_lines(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.is_real_file_buffer(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return false
	end

	return vim.bo[bufnr].buftype == ""
end

function M.buf_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return nil
	end
	return vim.fs.normalize(name)
end

function M.file_size(path)
	local stat = path and vim.uv.fs_stat(path)
	return stat and stat.size or 0
end

function M.win_is_valid(winid)
	return winid and winid ~= 0 and vim.api.nvim_win_is_valid(winid)
end

function M.buf_is_valid(bufnr)
	return bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr)
end

function M.truncate(text, max_len)
	if not text or #text <= max_len then
		return text or ""
	end
	if max_len <= 3 then
		return text:sub(1, max_len)
	end
	return text:sub(1, max_len - 3) .. "..."
end

return M
