local runtime = require("lazyvcs.process_runtime")
local M = {}

---@param winid integer
---@param name string
---@return boolean|integer|string
function M.get_win_option(winid, name)
	return vim.api.nvim_get_option_value(name, { win = winid, scope = "local" })
end

---@param winid integer
---@param name string
---@param value boolean|integer|string
function M.set_win_option(winid, name, value)
	vim.api.nvim_set_option_value(name, value, { win = winid, scope = "local" })
end

---Write transient presentation without dispatching OptionSet listeners.
function M.set_win_option_noautocmd(winid, name, value)
	vim.api.nvim_win_call(winid, function()
		local literal = type(value) == "boolean" and (value and "1" or "0") or vim.fn.string(value)
		vim.api.nvim_cmd({ cmd = "let", args = { "&l:" .. name .. " = " .. literal }, mods = { noautocmd = true } }, {})
	end)
end

---@param winid integer
---@param values table<string, boolean|integer|string>
function M.set_win_options(winid, values)
	for name, value in pairs(values) do
		M.set_win_option(winid, name, value)
	end
end

---@param winid integer
---@param names string[]
---@return table<string, boolean|integer|string>
function M.capture_win_options(winid, names)
	local values = {}
	for _, name in ipairs(names) do
		values[name] = M.get_win_option(winid, name)
	end
	return values
end

-- A second :diffoff restores the last saved pre-diff values, so skip windows that are
-- not in diff mode; their current options may be newer than those values.
---@param winid integer
function M.diff_off(winid)
	if not M.get_win_option(winid, "diff") then
		return
	end
	vim.api.nvim_win_call(winid, function()
		vim.cmd("silent diffoff")
	end)
end

---@param winid integer
---@param bufnr integer
function M.show_win_buffer(winid, bufnr)
	if vim.api.nvim_win_get_buf(winid) == bufnr then
		return
	end
	vim.api.nvim_win_call(winid, function()
		if M.get_win_option(winid, "diff") then
			M.diff_off(winid)
		end
		vim.cmd("keepjumps buffer " .. bufnr)
	end)
end

---@param winid integer
function M.unbind_window(winid)
	M.diff_off(winid)
	M.set_win_options(winid, { scrollbind = false, cursorbind = false })
end

---@param winid integer
function M.editor_window(winid)
	M.unbind_window(winid)
	M.set_win_options(winid, { winbar = "", statusline = "", winfixwidth = false })
end

function M.svn_target(path, revision)
	return path .. "@" .. (revision and tostring(revision) or "")
end

local function command_options(args, opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	if args[1] == "git" then
		opts.env = vim.tbl_extend(
			"force",
			{ GIT_TERMINAL_PROMPT = "0" },
			opts.env or {},
			{ GIT_LITERAL_PATHSPECS = "1", LC_ALL = "C" }
		)
	end
	if args[1] == "svn" and not vim.tbl_contains(args, "--non-interactive") then
		args = vim.list_extend({ "svn", "--non-interactive" }, vim.list_slice(args, 2))
	end
	return opts, args
end

function M.show_text(title, lines)
	vim.cmd("botright split")
	local win = vim.api.nvim_get_current_win()
	M.show_win_buffer(win, vim.api.nvim_create_buf(false, true))
	M.unbind_window(win)
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
	M.set_win_option(win, "winbar", title:gsub("%%", "%%%%"))
	vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
	return buf
end

function M.notify(msg, level)
	vim.notify(tostring(msg):gsub("%s*\n%s*", " "), level or vim.log.levels.INFO, { title = "lazyvcs.nvim" })
end

runtime.setup(M.notify)

function M.safe_callback(fn)
	return function(...)
		local ok, result = pcall(fn, ...)
		if not ok then
			if vim.in_fast_event() then
				vim.schedule(function()
					M.notify(result, vim.log.levels.ERROR)
				end)
			else
				M.notify(result, vim.log.levels.ERROR)
			end
			return nil
		end
		return result
	end
end

-- Parentheses keep gsub's substitution count out of the return values.
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
	opts, args = command_options(args, opts)
	opts = vim.tbl_extend("keep", opts, { text = true })
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
	if runtime.is_shutting_down() then
		return nil
	end
	opts, args = command_options(args, opts)
	local text_mode = opts.text ~= false
	local timeout_ms = opts.timeout_ms or opts.timeout
	local output_limit = math.max(256, math.floor(opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024))
	local kill_grace_ms = math.max(0, math.floor(opts.kill_grace_ms or 1000))
	local on_terminate = opts.on_terminate
	local shutdown_exit = opts.on_exit_during_shutdown
	opts.on_exit_during_shutdown = nil
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
	local exited_result
	local force_sent = false
	local complete_exit
	local windows = vim.fn.has("win32") == 1
	local wrapper = {}
	opts.detach = not windows

	local function group_alive()
		return not windows and process and process.pid and process.pid > 0 and vim.uv.kill(-process.pid, 0) ~= nil
	end

	local function signal_scope(signal)
		if not process then
			return
		end
		if not windows then
			if process.pid and process.pid > 0 then
				pcall(vim.uv.kill, -process.pid, signal)
			else
				pcall(process.kill, process, signal)
			end
		else
			-- taskkill can find descendants only while their parent is still alive.
			if not exited_result and process.pid and not process:is_closing() then
				local ok = pcall(vim.system, { "taskkill", "/T", "/F", "/PID", tostring(process.pid) }, {
					stdout = false,
					stderr = false,
				}, function()
					pcall(process.kill, process, signal)
				end)
				if not ok then
					pcall(process.kill, process, signal)
				end
			else
				pcall(process.kill, process, signal)
			end
		end
		if signal == 9 then
			force_sent = true
		end
	end

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
		if not runtime.is_shutting_down() and type(stream.callback) == "function" then
			M.safe_callback(stream.callback)(err, data)
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
			return bounded_text(text_mode and (fallback or ""):gsub("\r\n", "\n") or fallback, limit)
		end
		local value = table.concat(stream.chunks)
		if text_mode then
			value = value:gsub("\r\n", "\n")
		end
		if stream.omitted > 0 then
			value = value .. string.format("\n... [truncated at least %d bytes]", stream.omitted)
		end
		return bounded_text(value, limit)
	end

	local function stream_truncated(name, fallback)
		local stream = streams[name]
		if stream.omitted > 0 then
			return true
		end
		return #stream.chunks == 0
			and #(type(fallback) == "string" and fallback or "")
				> (name == "stdout" and stdout_limit or stderr_limit)
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
			stdout_truncated = stream_truncated("stdout", result.stdout),
			stderr_truncated = stream_truncated("stderr", result.stderr),
			cancelled = result.cancelled,
			timed_out = result.timed_out,
			reason = result.reason,
		}
	end

	local function schedule_kill()
		if done then
			return
		end
		if kill_grace_ms <= 0 then
			signal_scope(9)
			return
		end
		kill_timer = vim.defer_fn(
			M.safe_callback(function()
				kill_timer = nil
				if not done then
					signal_scope(9)
					if exited_result then
						complete_exit(exited_result)
					end
				end
			end),
			kill_grace_ms
		)
	end

	local function notify_termination(result)
		if not runtime.is_shutting_down() and type(on_terminate) == "function" then
			M.safe_callback(on_terminate)(result.result, result.err, result.raw)
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
				stdout_truncated = streams.stdout.omitted > 0,
				stderr_truncated = false,
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
				stdout_truncated = streams.stdout.omitted > 0,
				stderr_truncated = false,
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
			signal_scope(signal or 15)
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
			runtime.track(wrapper)
			vim.schedule(function()
				if shutdown_exit and runtime.is_shutting_down() and not forced_result then
					result, err = nil, "Cancelled: editor shutdown"
					raw = { code = 130, stdout = "", stderr = err, cancelled = true, reason = "editor shutdown" }
				end
				if shutdown_exit or not runtime.is_shutting_down() then
					M.safe_callback(on_exit)(result, err, raw)
				end
				runtime.untrack(wrapper)
			end)
		else
			runtime.untrack(wrapper)
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

	function wrapper:force()
		if done then
			return false
		end
		signal_scope(9)
		if exited_result then
			complete_exit(exited_result)
		end
		return true
	end

	function wrapper:shutdown()
		if not begin_termination("cancelled", 15, "editor shutdown") and not done then
			signal_scope(15)
		end
	end

	function wrapper:close_timers()
		close_timer(timeout_timer)
		close_timer(kill_timer)
		timeout_timer, kill_timer = nil, nil
	end

	if type(opts.cwd) == "string" and opts.cwd ~= "" and not vim.uv.fs_stat(opts.cwd) then
		local result = {
			code = 127,
			stdout = "",
			stderr = "Working directory does not exist: " .. opts.cwd,
		}
		result = bounded_result(result)
		complete(nil, M.system_error(result), result)
		return wrapper
	end

	complete_exit = function(result)
		if done then
			return
		end
		exited_result = result
		if forced_result and not force_sent and group_alive() then
			return
		end
		local bounded_raw = bounded_result(result)
		if forced_result then
			forced_result.raw.stdout = bounded_raw and bounded_raw.stdout or ""
			forced_result.raw.signal = bounded_raw and bounded_raw.signal or nil
			forced_result.raw.stdout_truncated = bounded_raw and bounded_raw.stdout_truncated or false
			forced_result.raw.stderr_truncated = false
			complete(forced_result.result, forced_result.err, forced_result.raw)
			return
		end
		if result.code ~= 0 then
			complete(nil, M.system_error(bounded_raw), bounded_raw)
			return
		end
		complete(bounded_raw, nil, bounded_raw)
	end
	local ok, proc =
		pcall(vim.system, args, vim.tbl_extend("keep", opts, { text = true }), M.safe_callback(complete_exit))
	if not ok then
		local result = { code = 127, stdout = "", stderr = M.spawn_error(args, proc) }
		result = bounded_result(result)
		complete(nil, M.system_error(result), result)
		return wrapper
	end
	process = proc
	wrapper.process = proc
	if not done then
		runtime.track(wrapper)
	end
	if not done and timeout_ms and timeout_ms > 0 then
		timeout_timer = vim.defer_fn(
			M.safe_callback(function()
				timeout_timer = nil
				if done then
					return
				end
				begin_termination("timeout", 15)
			end),
			timeout_ms
		)
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
		if result.stdout_truncated or result.stderr_truncated then
			return on_exit(nil, "Command output was truncated; refusing incomplete contents", raw)
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
		return M.normalize_literal_path(path)
	end
	return vim.fs.dirname(path)
end

---Normalize filesystem data literally. Join repository entries to their root first.
---Unlike user-input expansion, this also preserves a leading tilde in a filename.
---@param path string
---@return string
function M.normalize_literal_path(path)
	return vim.fs.normalize(path:sub(1, 1) == "~" and ("./" .. path) or path, { expand_env = false })
end

local function relative_normalized_path(root, path, ignorecase)
	local base, target = root, path
	if ignorecase then
		base, target = base:lower(), target:lower()
	end
	if base == target then
		return "."
	end
	local prefix = base:sub(-1) == "/" and base or (base .. "/")
	if target:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return nil
end

---Lexical membership only: no environment expansion, realpath, or per-file I/O.
---Use Neovim's filename case convention for display and buffer matching.
---@param root string
---@param path string
---@return string? relative
function M.relative_literal_path(root, path)
	if root == "" or path == "" then
		return nil
	end
	return relative_normalized_path(
		M.normalize_literal_path(root),
		M.normalize_literal_path(path),
		vim.o.fileignorecase
	)
end

-- Canonicalize root identities by resolving symlinks. Missing paths retain their
-- normalized spelling; verified membership uses relpath instead.
---@param path string|nil
---@return string
function M.canonical_path(path)
	if not path or path == "" then
		return path or ""
	end
	local normalized = M.normalize_literal_path(path)
	local resolved = vim.uv.fs_realpath(normalized)
	return resolved and M.normalize_literal_path(resolved) or normalized
end

---Resolve existing ancestors, retaining missing suffixes and the final symlink entry.
---Strict callers reject inaccessible, dangling, or non-directory parents.
---@param path string?
---@param strict? boolean
---@return string? entry, string? err
function M.canonical_entry_path(path, strict)
	if not path or path == "" then
		if strict then
			return nil, "Cannot resolve an empty repository entry path"
		end
		return path or ""
	end
	local normalized = M.normalize_literal_path(path)
	local parent = vim.fs.dirname(normalized)
	local suffix = { vim.fs.basename(normalized) }
	while parent do
		local resolved, err, code = vim.uv.fs_realpath(parent)
		if resolved then
			local stat = vim.uv.fs_stat(resolved)
			if stat and stat.type == "directory" then
				local parts = { resolved }
				for i = #suffix, 1, -1 do
					parts[#parts + 1] = suffix[i]
				end
				return M.normalize_literal_path(table.concat(parts, "/"))
			end
			break
		end
		-- ENOENT can mean a missing directory or a dangling symlink. Only the
		-- former has a knowable entry identity beneath an existing ancestor.
		if code ~= "ENOENT" or vim.uv.fs_lstat(parent) then
			if strict then
				return nil, "Cannot resolve repository entry parent: " .. tostring(err):gsub("[%c]", " ")
			end
			return normalized
		end
		suffix[#suffix + 1] = vim.fs.basename(parent)
		local next_parent = vim.fs.dirname(parent)
		if next_parent == parent then
			break
		end
		parent = next_parent
	end
	if strict then
		return nil, "Cannot resolve repository entry parent"
	end
	return normalized
end

---Verified repository entry, never a guessed basename. Resolve roots and ancestors
---again at mutation start; retain the final component even when it is a symlink.
---@param root string?
---@param path string?
---@return string? relative, string? err
function M.relpath(root, path)
	local err = "Cannot place path in repository"
	if not root or root == "" or not path or path == "" then
		return nil, err .. ": missing root or entry"
	end
	local real_root = vim.uv.fs_realpath(M.normalize_literal_path(root))
	local stat = real_root and vim.uv.fs_stat(real_root)
	if not real_root or not stat or stat.type ~= "directory" then
		return nil, err .. ": unresolved root"
	end
	local entry, entry_err = M.canonical_entry_path(path, true)
	if not entry then
		return nil, entry_err
	end
	-- realpath supplies filesystem casing for existing ancestors. A user-set
	-- 'fileignorecase' must never authorize a different case-sensitive checkout.
	local relative = relative_normalized_path(M.normalize_literal_path(real_root), entry, false)
	if not relative then
		return nil, err .. ": entry is outside root"
	end
	return relative
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
	return M.normalize_literal_path(name)
end

function M.buffer_size(bufnr)
	return vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr))
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

function M.buffer_text_options(bufnr)
	local values = {}
	for _, name in ipairs({ "fileencoding", "fileformat", "bomb", "binary", "endofline", "fixendofline" }) do
		values[name] = vim.bo[bufnr][name]
	end
	return values
end

function M.capture_buffer_context(winid)
	winid = winid or vim.api.nvim_get_current_win()
	if not M.win_is_valid(winid) then
		return nil
	end
	local bufnr = vim.api.nvim_win_get_buf(winid)
	if not M.buf_is_valid(bufnr) then
		return nil
	end
	return {
		winid = winid,
		bufnr = bufnr,
		path = M.buf_path(bufnr),
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		cursor = vim.api.nvim_win_get_cursor(winid),
		text_identity = require("lazyvcs.compare_text").identity(bufnr),
	}
end

function M.buffer_context_is_unchanged(context, opts)
	if
		not context
		or not M.win_is_valid(context.winid)
		or not M.buf_is_valid(context.bufnr)
		or vim.api.nvim_win_get_buf(context.winid) ~= context.bufnr
	then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(context.winid)
	return M.buf_path(context.bufnr) == context.path
		and vim.api.nvim_buf_get_changedtick(context.bufnr) == context.changedtick
		and vim.deep_equal(require("lazyvcs.compare_text").identity(context.bufnr), context.text_identity)
		and ((opts and opts.ignore_cursor) or (cursor[1] == context.cursor[1] and cursor[2] == context.cursor[2]))
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
	local function fit(budget)
		local low, high = 0, vim.fn.strchars(text)
		while low < high do
			local middle = math.floor((low + high + 1) / 2)
			if vim.api.nvim_strwidth(vim.fn.strcharpart(text, 0, middle)) <= budget then
				low = middle
			else
				high = middle - 1
			end
		end
		return vim.fn.strcharpart(text, 0, low)
	end
	-- Too narrow for content plus an ellipsis: spend the whole budget on
	-- content rather than emitting a bare "..." that says nothing.
	if max_width <= 3 then
		return fit(max_width)
	end
	return fit(max_width - 3) .. "..."
end

return M
