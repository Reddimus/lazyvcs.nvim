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
	local output_limit = math.max(1024, math.floor(opts.output_limit or 4 * 1024 * 1024))
	local kill_grace_ms = math.max(0, math.floor(opts.kill_grace_ms or 1000))
	opts.timeout = nil
	opts.output_limit = nil
	opts.kill_grace_ms = nil
	local done = false
	local process
	local timeout_timer
	local kill_timer
	local forced_result
	local wrapper = {}

	local function close_timer(timer)
		if not timer then
			return
		end
		local ok, closing = pcall(timer.is_closing, timer)
		if ok and not closing then
			pcall(timer.stop, timer)
			pcall(timer.close, timer)
		end
	end

	local function bounded(text)
		text = type(text) == "string" and text or ""
		if #text <= output_limit then
			return text
		end
		local suffix = string.format("\n... [truncated %d bytes]", #text - output_limit)
		return text:sub(1, math.max(0, output_limit - #suffix)) .. suffix
	end

	local function bounded_result(result)
		if type(result) ~= "table" then
			return result
		end
		return {
			code = result.code,
			signal = result.signal,
			stdout = bounded(result.stdout),
			stderr = bounded(result.stderr),
		}
	end

	local function schedule_kill()
		if done then
			return
		end
		if not process or kill_grace_ms <= 0 then
			if process then
				pcall(process.kill, process, 9)
			end
			return
		end
		kill_timer = vim.defer_fn(function()
			kill_timer = nil
			if process and not done then
				pcall(process.kill, process, 9)
			end
		end, kill_grace_ms)
	end

	local function complete(result, err, raw)
		if done then
			return false
		end
		done = true
		close_timer(timeout_timer)
		close_timer(kill_timer)
		timeout_timer = nil
		kill_timer = nil
		if type(on_exit) == "function" then
			vim.schedule(function()
				on_exit(result, err, raw)
			end)
		end
		return true
	end

	function wrapper:kill(signal)
		if done then
			return false
		end
		if process then
			pcall(process.kill, process, signal or 15)
		end
		if forced_result then
			return true
		end
		local message = "Cancelled: " .. table.concat(args, " ")
		close_timer(timeout_timer)
		timeout_timer = nil
		forced_result = {
			result = nil,
			err = message,
			raw = {
				code = 130,
				stdout = "",
				stderr = message,
				cancelled = true,
				reason = "cancelled",
			},
		}
		if process and signal ~= 9 then
			schedule_kill()
		end
		return true
	end

	wrapper.cancel = wrapper.kill

	if type(opts.cwd) == "string" and opts.cwd ~= "" and not vim.uv.fs_stat(opts.cwd) then
		local result = {
			code = 127,
			stdout = "",
			stderr = "Working directory does not exist: " .. opts.cwd,
		}
		complete(nil, M.system_error(result), result)
		return wrapper
	end

	local ok, proc = pcall(vim.system, args, vim.tbl_extend("keep", opts, { text = true }), function(result)
		if done then
			return
		end
		if forced_result then
			complete(forced_result.result, forced_result.err, forced_result.raw)
			return
		end
		local bounded_raw = bounded_result(result)
		if result.code ~= 0 then
			complete(nil, M.system_error(bounded_raw), bounded_raw)
			return
		end
		complete(bounded_raw, nil, bounded_raw)
	end)
	if not ok then
		local result = { code = 127, stdout = "", stderr = tostring(proc) }
		complete(nil, M.system_error(result), result)
		return nil
	end
	process = proc
	wrapper.process = proc
	if timeout_ms and timeout_ms > 0 then
		timeout_timer = vim.defer_fn(function()
			timeout_timer = nil
			if done then
				return
			end
			if process then
				pcall(process.kill, process, 15)
			end
			local message = string.format("Timed out after %dms: %s", timeout_ms, table.concat(args, " "))
			forced_result = {
				result = nil,
				err = message,
				raw = {
					code = 124,
					stdout = "",
					stderr = message,
					timed_out = true,
					reason = "timeout",
				},
			}
			if process then
				schedule_kill()
			end
		end, timeout_ms)
	end
	return wrapper
end

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

--- Directory to run a VCS command in for `path`.
---
--- `path` is usually a file, but callers also pass directories (for example
--- `buffer_ops` falls back to the cwd when the current buffer is not a real
--- file). Blindly taking `vim.fs.dirname` would then probe the PARENT of a
--- working copy, so a repo root resolves to "no working copy found".
---@return string
function M.dir_of(path)
	local stat = path and vim.uv.fs_stat(path)
	if stat and stat.type == "directory" then
		return vim.fs.normalize(path)
	end
	return vim.fs.dirname(path)
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
