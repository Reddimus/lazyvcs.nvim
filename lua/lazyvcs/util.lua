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

local git_work_tree_cache = {}
local function uses_git_work_tree(environment, cwd)
	local git_dir, work_tree
	for key, value in pairs(environment) do
		local name = key:upper()
		if name == "GIT_DIR" then
			git_dir = value
		elseif name == "GIT_WORK_TREE" then
			work_tree = value
		end
	end
	if git_work_tree_cache.git_dir ~= git_dir or git_work_tree_cache.work_tree ~= work_tree then
		git_work_tree_cache = { git_dir = git_dir, work_tree = work_tree }
		if type(git_dir) == "string" and git_dir ~= "" and type(work_tree) == "string" and work_tree ~= "" then
			git_work_tree_cache.canonical = M.canonical_path(work_tree)
		end
	end
	if not git_work_tree_cache.canonical or not cwd or cwd == "" then
		return false
	end
	return relative_normalized_path(git_work_tree_cache.canonical, M.canonical_path(cwd), vim.fn.has("win32") == 1)
		~= nil
end

local function command_options(args, opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	if args[1] == "git" then
		-- Preserve a dotfiles repository only within its explicit work tree.
		-- Snapshot via libuv because commands can start in fast-event callbacks.
		local environment = vim.tbl_extend(
			"force",
			opts.clear_env and {} or vim.uv.os_environ(),
			{ GIT_TERMINAL_PROMPT = "0" },
			opts.env or {}
		)
		local keep_work_tree = uses_git_work_tree(environment, opts.cwd)
		local selectors = {
			GIT_DIR = not keep_work_tree,
			GIT_WORK_TREE = not keep_work_tree,
			GIT_COMMON_DIR = true,
			GIT_INDEX_FILE = true,
			GIT_OBJECT_DIRECTORY = true,
			GIT_ALTERNATE_OBJECT_DIRECTORIES = true,
			GIT_NAMESPACE = true,
			GIT_PREFIX = true,
			GIT_SHALLOW_FILE = true,
			GIT_GRAFT_FILE = true,
			GIT_IMPLICIT_WORK_TREE = true,
		}
		for key in pairs(environment) do
			if selectors[key:upper()] then
				environment[key] = nil
			end
		end
		opts.clear_env = true
		opts.env = vim.tbl_extend("force", environment, {
			GIT_LITERAL_PATHSPECS = "1",
			GIT_GLOB_PATHSPECS = "0",
			GIT_NOGLOB_PATHSPECS = "0",
			GIT_ICASE_PATHSPECS = "0",
			LC_ALL = "C",
		})
	end
	if args[1] == "svn" and not vim.tbl_contains(args, "--non-interactive") then
		args = vim.list_extend({ "svn", "--non-interactive" }, vim.list_slice(args, 2))
	end
	return opts, args
end

-- Neovim before 0.11.3 passes clear_env straight to libuv, which needs a list.
local function system_options(opts)
	if opts.clear_env and opts.env and vim.fn.has("nvim-0.11.3") == 0 and not vim.islist(opts.env) then
		local entries = {}
		for name, value in pairs(opts.env) do
			entries[#entries + 1] = name .. "=" .. tostring(value)
		end
		return vim.tbl_extend("force", opts, { env = entries })
	end
	return opts
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
	require("lazyvcs.compat").keymap_set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
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

-- Normalize display text only; file bytes must reach compare_text unchanged.
function M.split_text_lines(text)
	return M.split_lines(((text or ""):gsub("\r\n", "\n")))
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
	local ok, proc = pcall(vim.system, args, system_options(opts))
	if not ok or not proc then
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
	if result and (result.signal or 0) ~= 0 then
		return string.format("Process terminated by signal %d", result.signal)
	end
	local stderr = M.trim(result and result.stderr)
	local stdout = M.trim(result and result.stdout)
	return stderr ~= "" and stderr or stdout
end

function M.system(args, opts)
	local result = M.system_result(args, opts)
	if result.code ~= 0 or (result.signal or 0) ~= 0 then
		return nil, M.system_error(result)
	end
	return result
end

-- Cancellation walks trees only for mutation/remote scopes and the Git/SVN
-- commands below, which can own hooks or credential helpers. Other reads,
-- including URL reads, need only direct termination: their transport helpers
-- exit when the parent's pipes close. Timeouts and shutdown always walk trees.
local function cancel_tree(args, scope)
	if type(args) ~= "table" or type(args[1]) ~= "string" or args[1] == "" then
		return false
	end
	local executable = args[1]:gsub("\\", "/"):match("([^/]+)$")
	if not executable then
		return false
	end
	if scope == "mutation" or scope == "remote" then
		return true
	end
	executable = executable:lower():gsub("%.exe$", "")
	if executable ~= "git" and executable ~= "svn" then
		return false
	end
	local commands = executable == "git"
			and {
				fetch = true,
				pull = true,
				push = true,
				commit = true,
				clone = true,
				["ls-remote"] = true,
			}
		or {
			checkout = true,
			co = true,
			update = true,
			up = true,
			switch = true,
			sw = true,
			merge = true,
			commit = true,
			ci = true,
			import = true,
		}
	local index = 2
	while type(args[index]) == "string" and args[index]:sub(1, 1) == "-" do
		local option = args[index]
		index = index
			+ (
				(
						option == "-C"
						or option == "-c"
						or option == "--git-dir"
						or option == "--work-tree"
						or option == "--namespace"
						or option == "--config-env"
					)
					and 2
				or 1
			)
	end
	if commands[args[index]] or (executable == "git" and args[index] == "remote" and args[index + 1] == "update") then
		return true
	end
	if executable == "svn" and args[index] == "status" then
		for _, arg in ipairs(args) do
			if arg == "-u" or arg == "--show-updates" then
				return true
			end
		end
	end
	return false
end

function M.system_start(args, opts, on_exit)
	if runtime.is_shutting_down() then
		local function finished(_)
			return false
		end
		if opts and opts.on_exit_during_shutdown and type(on_exit) == "function" then
			vim.schedule(function()
				local err = "Cancelled: editor shutdown"
				M.safe_callback(on_exit)(nil, err, {
					code = 130,
					stdout = "",
					stderr = err,
					cancelled = true,
					reason = "editor shutdown",
				})
			end)
		end
		return { done = true, cancel = finished, kill = finished, force = finished, shutdown = finished }
	end
	local tree_termination = cancel_tree(args, opts and opts.scope)
	opts, args = command_options(args, opts)
	opts.scope = nil
	local text_mode = opts.text ~= false
	local timeout_ms = opts.timeout_ms or opts.timeout
	local output_limit = math.max(256, math.floor(opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024))
	local kill_grace_ms = math.max(0, math.floor(opts.kill_grace_ms or 1000))
	local on_terminate = opts.on_terminate
	local shutdown_exit = opts.on_exit_during_shutdown
	local preserve_on_shutdown = opts.preserve_on_shutdown
	opts.on_exit_during_shutdown = nil
	opts.preserve_on_shutdown = nil
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
	local reap_timer
	local forced_result
	local exited_result
	local force_sent = false
	local taskkill_running = false
	local group_gone = false
	local complete_exit
	local reap_windows
	local windows = vim.fn.has("win32") == 1
	local owned_windows_tree = windows and (preserve_on_shutdown or tree_termination)
	local wrapper = {}
	-- Windows libuv assigns non-detached children to Neovim's kill-on-close
	-- job. Only started mutations may outlive the editor; explicit cancellation
	-- still uses taskkill /T for their complete process tree.
	opts.detach = not windows or preserve_on_shutdown == true

	local function group_alive()
		if windows or group_gone or not process or not process.pid or process.pid <= 0 then
			return false
		end
		local alive = vim.uv.kill(-process.pid, 0) ~= nil
		if not alive and (exited_result or (process.is_closing and process:is_closing())) then
			group_gone = true
		end
		return alive
	end

	local function signal_scope(signal)
		if not process then
			return
		end
		if not windows then
			if force_sent or group_gone then
				return
			end
			group_alive()
			if group_gone then
				return
			end
			if process.pid and process.pid > 0 then
				pcall(vim.uv.kill, -process.pid, signal)
			else
				pcall(process.kill, process, signal)
			end
		elseif owned_windows_tree then
			-- Before the helper establishes its restrictive job it has no
			-- children; afterward killing it closes the job and its entire tree.
			local ok, closing = pcall(function()
				return process:is_closing()
			end)
			if not done and not (ok and closing) then
				pcall(process.kill, process, signal)
			end
		else
			-- Keep the parent alive while taskkill enumerates its descendants.
			if
				tree_termination
				and not taskkill_running
				and not exited_result
				and process.pid
				and not process:is_closing()
			then
				taskkill_running = true
				local ok = pcall(vim.system, { "taskkill", "/T", "/F", "/PID", tostring(process.pid) }, {
					stdout = false,
					stderr = false,
					timeout = 2000,
				}, function()
					taskkill_running = false
					local ok, closing = pcall(function()
						return process:is_closing()
					end)
					if not done and not (ok and closing) then
						pcall(process.kill, process, force_sent and 9 or signal)
					end
				end)
				if not ok then
					taskkill_running = false
				end
			end
			-- Shutdown has a shorter global deadline than taskkill. Otherwise its
			-- own deadline bounds the wait without cutting off the tree walk.
			if not taskkill_running or (signal == 9 and runtime.is_shutting_down()) then
				local ok, closing = pcall(function()
					return process:is_closing()
				end)
				if not done and not (ok and closing) then
					pcall(process.kill, process, signal)
				end
			end
		end
		if signal == 9 then
			force_sent = true
			if windows and forced_result then
				reap_windows()
			end
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

	-- vim.system waits for pipe EOF after the process handle closes. Windows
	-- cannot find descendants of an exited parent with taskkill, so an inherited
	-- pipe must not keep a cancelled command's worker forever. After the grace
	-- period, discard those pipes only once the direct process has really exited.
	-- Both supported Neovim versions keep these handles in SystemObj._state;
	-- there is no public method for closing its output pipes.
	reap_windows = function()
		if done or reap_timer or not process or not process.is_closing then
			return
		end
		if process:is_closing() then
			---@diagnostic disable-next-line: invisible
			local state = process._state
			if state then
				for _, name in ipairs({ "stdout", "stderr" }) do
					local pipe = state[name]
					if pipe then
						local ok, closing = pcall(function()
							return pipe:is_closing()
						end)
						if ok and not closing then
							pcall(pipe.read_stop, pipe)
							pcall(pipe.close, pipe)
						end
					end
				end
			end
			return
		end
		reap_timer = vim.defer_fn(
			M.safe_callback(function()
				reap_timer = nil
				reap_windows()
			end),
			10
		)
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
		tree_termination = tree_termination or kind == "timeout" or reason == "editor shutdown"
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
		close_timer(reap_timer)
		timeout_timer = nil
		kill_timer = nil
		reap_timer = nil
		if type(on_exit) == "function" then
			runtime.track(wrapper)
			vim.schedule(function()
				if shutdown_exit and runtime.is_shutting_down() and not forced_result and not preserve_on_shutdown then
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
		if preserve_on_shutdown and not forced_result then
			self:close_timers()
			runtime.untrack(self)
			return
		end
		if not begin_termination("cancelled", 15, "editor shutdown") and not done and not force_sent then
			signal_scope(15)
		end
	end

	function wrapper:close_timers()
		close_timer(timeout_timer)
		close_timer(kill_timer)
		close_timer(reap_timer)
		timeout_timer, kill_timer, reap_timer = nil, nil, nil
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
		if result.code ~= 0 or (result.signal or 0) ~= 0 then
			complete(nil, M.system_error(bounded_raw), bounded_raw)
			return
		end
		complete(bounded_raw, nil, bounded_raw)
	end
	local spawn_args, spawn_opts = args, opts
	if owned_windows_tree then
		spawn_args, spawn_opts = require("lazyvcs.windows_process").wrap(args, opts)
	end
	local ok, proc = pcall(
		vim.system,
		spawn_args,
		system_options(vim.tbl_extend("keep", spawn_opts, { text = true })),
		M.safe_callback(complete_exit)
	)
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

---Find a command directory for an entry whose parent directories may be deleted.
function M.existing_directory(path)
	local cwd = M.dir_of(path)
	while cwd do
		local stat, err, code = vim.uv.fs_stat(cwd)
		if stat then
			if stat.type ~= "directory" then
				return nil, "Not a directory: " .. cwd
			end
			return M.normalize_literal_path(cwd)
		end
		-- Only absent entries permit ascent. A dangling link still owns its path.
		if code ~= "ENOENT" then
			return nil, err
		end
		local entry, entry_err, entry_code = vim.uv.fs_lstat(cwd)
		if entry or entry_code ~= "ENOENT" then
			return nil, entry_err or err
		end
		local parent = vim.fs.dirname(cwd)
		if parent == cwd then
			break
		end
		cwd = parent
	end
	return nil, "No existing directory for " .. path
end

---Discover ancestors without blocking navigation; cancellation stops the walk.
function M.existing_directory_async(path, callback)
	local task = require("lazyvcs.backends.task").new(callback)
	local pending
	task:on_cancel(function()
		if pending then
			pcall(vim.uv.cancel, pending)
		end
	end)
	local function stat_async(method, candidate, done)
		pending = vim.uv[method](candidate, function(err, stat)
			vim.schedule(M.safe_callback(function()
				pending = nil
				if task:is_active() then
					done(err, stat)
				end
			end))
		end)
	end
	local visit
	visit = function(cwd)
		if not cwd then
			return task:finish(nil, "No existing directory for " .. path)
		end
		stat_async("fs_stat", cwd, function(err, stat)
			if stat then
				if stat.type ~= "directory" then
					return task:finish(nil, "Not a directory: " .. cwd)
				end
				return task:finish(M.normalize_literal_path(cwd))
			end
			if not err or not err:match("^ENOENT:") then
				return task:finish(nil, err)
			end
			-- Distinguish a missing ancestor from a dangling symlink before ascent.
			stat_async("fs_lstat", cwd, function(entry_err, entry)
				if entry or not entry_err or not entry_err:match("^ENOENT:") then
					return task:finish(nil, entry_err or err)
				end
				local parent = vim.fs.dirname(cwd)
				visit(parent ~= cwd and parent or nil)
			end)
		end)
	end
	stat_async("fs_stat", path, function(_, stat)
		if stat and stat.type == "directory" then
			return task:finish(M.normalize_literal_path(path))
		end
		visit(vim.fs.dirname(path))
	end)
	return task
end

---Normalize filesystem data literally. Join repository entries to their root first.
---Unlike user-input expansion, this also preserves a leading tilde in a filename.
---@param path string
---@return string
function M.normalize_literal_path(path)
	return vim.fs.normalize(path:sub(1, 1) == "~" and ("./" .. path) or path, { expand_env = false })
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

---@param path string
---@return string? absolute, string? err
local function absolute_literal_path(path)
	local windows_paths = vim.fn.has("win32") == 1
	if windows_paths then
		path = path:gsub("\\", "/")
	end
	if path:sub(1, 1) == "/" or (windows_paths and path:match("^%a:/")) then
		return path
	end
	local ok, absolute = pcall(vim.fs.abspath, path:sub(1, 1) == "~" and ("./" .. path) or path)
	if not ok then
		return nil, "Cannot make repository path absolute: " .. tostring(absolute):gsub("[%c]", " ")
	end
	return absolute
end

---Expand command-input paths without collapsing symlink traversal.
---@param path string
---@return string expanded
function M.expand_user_path(path)
	return require("lazyvcs.command_path").expand(path)
end

-- Canonicalize root identities by resolving symlinks. Missing paths retain their
-- normalized spelling; verified membership uses relpath instead.
---@param path string|nil
---@return string
function M.canonical_path(path)
	if not path or path == "" then
		return path or ""
	end
	local absolute = absolute_literal_path(path)
	local normalized = M.normalize_literal_path(absolute or path)
	local resolved = absolute and vim.uv.fs_realpath(absolute)
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
	local absolute, absolute_err = absolute_literal_path(path)
	if not absolute then
		if strict then
			return nil, absolute_err
		end
		return M.normalize_literal_path(path), absolute_err
	end
	local normalized = M.normalize_literal_path(absolute)
	local parent = vim.fs.dirname(absolute)
	local suffix = { vim.fs.basename(absolute) }
	-- A final dot component denotes a directory, not an entry to preserve.
	-- Resolve it as a whole: Windows collapses .. before following junctions.
	if suffix[1] == "." or suffix[1] == ".." then
		parent, suffix = absolute, {}
	end
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
		local component = vim.fs.basename(parent)
		if
			code ~= "ENOENT"
			or vim.uv.fs_lstat(parent)
			or component == "."
			or component == ".."
			or suffix[1] == "."
			or suffix[1] == ".."
		then
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
	local absolute = absolute_literal_path(root)
	local real_root = absolute and vim.uv.fs_realpath(absolute)
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
