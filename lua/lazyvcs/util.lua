local M = {}

function M.notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "lazyvcs.nvim" })
end

-- The outer parentheses are load-bearing: `gsub` returns (string, count), so
-- without them `trim` returns two values. Both backends' `get_root` end with
-- `return util.trim(result.stdout)`, so `local root, err = get_root(path)` was
-- binding the substitution count to `err` -- normally 1, since the command
-- output ends in a newline -- and any `load_err or err` fallback would surface
-- that number to the user as an error message. See `layout.sanitize_root` for
-- the same shape written correctly.
function M.trim(text)
	return ((text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
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

---Describe a failed `vim.system` spawn, naming the command that failed.
---
---Neovim 0.11.0 raises a bare "ENOENT: no such file or directory" with no
---indication of what could not be spawned, while 0.11.7+ includes the command.
---Prefixing it ourselves keeps the message useful, and identical, on every
---supported version: a missing `git` must say so rather than just "ENOENT".
function M.spawn_error(args, err)
	local command = type(args) == "table" and table.concat(args, " ") or tostring(args)
	return string.format("%s: %s", command, tostring(err))
end

function M.system_result(args, opts)
	opts = vim.tbl_extend("keep", opts or {}, { text = true })
	local timeout_ms = opts.timeout or M.SYNC_TIMEOUT_MS
	opts.timeout = nil

	-- vim.system raises synchronously when the executable is missing (ENOENT).
	-- Convert that into a normal non-zero result so callers can handle it via
	-- the usual result.code path instead of crashing.
	local ok, proc = pcall(vim.system, args, opts)
	if not ok then
		return { code = 127, stdout = "", stderr = M.spawn_error(args, proc) }
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
	opts = vim.tbl_extend("force", {}, opts or {})
	local timeout_ms = opts.timeout_ms or opts.timeout
	local output_limit = math.max(256, math.floor(opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024))
	local kill_grace_ms = math.max(0, math.floor(opts.kill_grace_ms or 1000))
	local on_terminate = opts.on_terminate
	opts.timeout = nil
	opts.timeout_ms = nil
	opts.output_limit = nil
	opts.output_limit_bytes = nil
	opts.kill_grace_ms = nil
	opts.on_terminate = nil
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

	local function bounded_text(value, limit)
		value = type(value) == "string" and value or ""
		if #value <= limit then
			return value
		end
		local suffix = string.format("\n... [truncated %d bytes]", #value - limit)
		return value:sub(1, math.max(0, limit - #suffix)) .. suffix
	end

	local stdout_limit = math.floor(output_limit / 2)
	local stderr_limit = output_limit - stdout_limit
	local streams = {
		stdout = { chunks = {}, bytes = 0, omitted = 0, callback = opts.stdout },
		stderr = { chunks = {}, bytes = 0, omitted = 0, callback = opts.stderr },
	}
	local function capture(name, err, data)
		local stream = streams[name]
		if err and not data then
			data = tostring(err)
		end
		if type(data) == "string" and data ~= "" then
			local limit = name == "stdout" and stdout_limit or stderr_limit
			local remaining = math.max(0, limit - stream.bytes)
			if remaining > 0 then
				local chunk = data:sub(1, remaining)
				stream.chunks[#stream.chunks + 1] = chunk
				stream.bytes = stream.bytes + #chunk
			end
			stream.omitted = stream.omitted + math.max(0, #data - remaining)
		end
		if type(stream.callback) == "function" then
			pcall(stream.callback, err, data)
		end
	end
	opts.stdout = function(err, data)
		capture("stdout", err, data)
	end
	opts.stderr = function(err, data)
		capture("stderr", err, data)
	end

	local function stream_value(name, fallback)
		local stream = streams[name]
		local limit = name == "stdout" and stdout_limit or stderr_limit
		if #stream.chunks == 0 and stream.omitted == 0 then
			return bounded_text(fallback, limit)
		end
		local value = table.concat(stream.chunks)
		if stream.omitted > 0 then
			value = value .. string.format("\n... [truncated at least %d bytes]", stream.omitted)
		end
		return bounded_text(value, limit)
	end

	local function bounded_result(result)
		if type(result) ~= "table" then
			return result
		end
		return {
			code = result.code,
			signal = result.signal,
			stdout = stream_value("stdout", result.stdout),
			stderr = stream_value("stderr", result.stderr),
			cancelled = result.cancelled,
			timed_out = result.timed_out,
			reason = result.reason,
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

	local function notify_termination(result)
		if type(on_terminate) == "function" then
			pcall(on_terminate, result.result, result.err, result.raw)
		end
	end

	local function begin_termination(kind, signal, reason)
		if done or forced_result then
			return false
		end
		close_timer(timeout_timer)
		timeout_timer = nil
		local message
		local raw
		if kind == "timeout" then
			message = string.format("Timed out after %dms: %s", timeout_ms, table.concat(args, " "))
			raw = {
				code = 124,
				stdout = "",
				stderr = message,
				timed_out = true,
				reason = "timeout",
			}
		else
			local cancel_reason = reason ~= nil and tostring(reason) or nil
			message = cancel_reason and ("Cancelled: " .. cancel_reason) or ("Cancelled: " .. table.concat(args, " "))
			raw = {
				code = 130,
				stdout = "",
				stderr = message,
				cancelled = true,
				reason = cancel_reason or "cancelled",
			}
		end
		forced_result = {
			result = nil,
			err = message,
			raw = raw,
		}
		if process then
			pcall(process.kill, process, signal or 15)
			if signal ~= 9 then
				schedule_kill()
			end
		end
		notify_termination(forced_result)
		return true
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
		return begin_termination("cancelled", signal or 15)
	end

	function wrapper:cancel(reason)
		if type(reason) == "number" then
			return begin_termination("cancelled", reason)
		end
		return begin_termination("cancelled", 15, reason)
	end

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
		local bounded_raw = bounded_result(result)
		if forced_result then
			forced_result.raw.stdout = bounded_raw and bounded_raw.stdout or ""
			forced_result.raw.signal = bounded_raw and bounded_raw.signal or nil
			complete(forced_result.result, forced_result.err, forced_result.raw)
			return
		end
		if result.code ~= 0 then
			complete(nil, M.system_error(bounded_raw), bounded_raw)
			return
		end
		complete(bounded_raw, nil, bounded_raw)
	end)
	if not ok then
		local result = { code = 127, stdout = "", stderr = M.spawn_error(args, proc) }
		complete(nil, M.system_error(result), result)
		return wrapper
	end
	process = proc
	wrapper.process = proc
	if timeout_ms and timeout_ms > 0 then
		timeout_timer = vim.defer_fn(function()
			timeout_timer = nil
			if done then
				return
			end
			begin_termination("timeout", 15)
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
---Canonical identity for a repository or workspace root.
---
---`vim.fs.normalize` alone only fixes separators and `~`; it does not resolve
---symlinks. That is enough for display but not for identity, and roots ARE
---identities here: `state.path`, `repo.root`, the job scheduler's owner keys and
---the session registry all compare them with `==`.
---
---The mismatch is routine on macOS, where `/tmp` and `/var` are symlinks into
---`/private`. `git rev-parse --show-toplevel` and `svn info` both report the
---resolved path, while a sidebar opened from `vim.fn.getcwd()` in `/tmp/work`
---keeps the unresolved spelling — so the same repository ends up with two
---identities and its cache entries, jobs and sessions stop matching. The test
---fixtures already resolve at creation time for exactly this reason.
---
---Falls back to the normalized input when the path does not exist yet, so a
---not-yet-created directory still gets a stable (if unresolved) identity.
---@param path string|nil
---@return string
function M.canonical_path(path)
	if not path or path == "" then
		return path or ""
	end
	local normalized = vim.fs.normalize(path)
	local resolved = vim.uv.fs_realpath(normalized)
	return resolved and vim.fs.normalize(resolved) or normalized
end

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

---Truncate to a byte budget without ever splitting a UTF-8 sequence.
---
---Use this for payload and message budgets -- an API context cap, an error
---string -- where the limit is about size, not screen space. `text:sub` alone
---could cut mid-codepoint and hand Neovim invalid UTF-8, which renders as
---replacement characters and can be rejected outright by the extmark API.
---For anything that has to fit a column budget use `M.truncate_display`.
function M.truncate(text, max_len)
	if not text or #text <= max_len then
		return text or ""
	end
	local function clip(budget)
		if budget <= 0 then
			return ""
		end
		if budget >= #text then
			return text
		end
		-- Back up while the byte just past the cut is a UTF-8 continuation
		-- byte (10xxxxxx, i.e. 0x80..0xBF), which means the cut landed inside
		-- a multi-byte sequence.
		local cut = budget
		while cut > 0 do
			local following = text:byte(cut + 1)
			if not following or following < 0x80 or following >= 0xC0 then
				break
			end
			cut = cut - 1
		end
		return text:sub(1, cut)
	end
	if max_len <= 3 then
		return clip(max_len)
	end
	return clip(max_len - 3) .. "..."
end

---Truncate to a terminal-cell budget, appending an ellipsis when it does not fit.
---
---`M.truncate` counts bytes, so `blame.max_width = 80` against a CJK author
---name or an emoji in a commit subject produced virtual text roughly twice the
---configured width, and could split a multi-byte character in the process.
---Screen width is what a wrapped or right-aligned label actually needs.
function M.truncate_display(text, max_width)
	text = text or ""
	max_width = max_width or 0
	if max_width <= 0 then
		return ""
	end
	if vim.api.nvim_strwidth(text) <= max_width then
		return text
	end
	if max_width <= 3 then
		return vim.fn.strcharpart(text, 0, max_width)
	end
	local out = ""
	for index = 0, vim.fn.strchars(text) - 1 do
		local candidate = out .. vim.fn.strcharpart(text, index, 1)
		if vim.api.nvim_strwidth(candidate) > max_width - 3 then
			break
		end
		out = candidate
	end
	return out .. "..."
end

return M
