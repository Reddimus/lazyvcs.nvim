local backends = require("lazyvcs.backends")
local config = require("lazyvcs.config")
local compare_text = require("lazyvcs.compare_text")
local compat = require("lazyvcs.compat")
local diff = require("lazyvcs.diff")
local confirm = require("lazyvcs.source_control.confirm")
local util = require("lazyvcs.util")
local runtime = require("lazyvcs.process_runtime")

local M = {}

local ns_id = vim.api.nvim_create_namespace("lazyvcs_signs")
local augroup
local buffers = {}
local timers = {}
local base_changes = {}
local preview_workers = {}

local function stop_timer(bufnr)
	local timer = timers[bufnr]
	if not timer then
		return
	end
	timers[bufnr] = nil
	pcall(timer.stop, timer)
	if not timer:is_closing() then
		pcall(timer.close, timer)
	end
end

local function opts()
	return config.get().signs
end

-- All groups link to standard highlights so any colorscheme (TokyoNight, AstroDark,
-- ...) themes them for free. `:colorscheme` clears these definitions, so they are
-- re-applied on ColorScheme in M.setup.
local function setup_highlights()
	vim.api.nvim_set_hl(0, "LazyVcsSignAdd", { default = true, link = "DiffAdd" })
	vim.api.nvim_set_hl(0, "LazyVcsSignChange", { default = true, link = "DiffChange" })
	vim.api.nvim_set_hl(0, "LazyVcsSignDelete", { default = true, link = "DiffDelete" })
	vim.api.nvim_set_hl(0, "LazyVcsBlame", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "LazyVcsBlameRevision", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "LazyVcsBlameAuthor", { default = true, link = "Comment" })
end

local function clear(bufnr)
	local state = buffers[bufnr]
	if util.buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	end
	buffers[bufnr] = nil
	if state and state.preview_pending then
		state.preview_pending.cancel()
	end
	for cancel in pairs(state and state.gitsigns_waiters or {}) do
		cancel()
	end
	if state and state.large_revert_pending then
		state.large_revert_pending()
	end
	stop_timer(bufnr)
	if state and state.command then
		pcall(state.command.kill, state.command, 15)
	end
	if state and state.job and type(state.job.kill) == "function" then
		pcall(state.job.kill, state.job, 15)
	end
end

-- Delegate only when gitsigns can report this buffer's hunks.
local function defers_to_gitsigns(backend_name, bufnr)
	if backend_name ~= "git" or not config.get().use_gitsigns then
		return false
	end
	local gs = package.loaded.gitsigns
	if type(gs) ~= "table" or type(gs.get_hunks) ~= "function" then
		return false
	end
	local usable, hunks = pcall(gs.get_hunks, bufnr)
	return usable and type(hunks) == "table"
end

local function gitsigns_api()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = util.buf_path(bufnr)
	local backend = path and backends.resolve_cached(path) or nil
	if not backend or not defers_to_gitsigns(backend.name, bufnr) then
		return nil
	end
	return package.loaded.gitsigns
end

local function gitsigns_method(method)
	local gitsigns = gitsigns_api()
	if not gitsigns then
		return nil
	end
	local fn = gitsigns[method]
	if type(fn) ~= "function" then
		return nil
	end
	return fn
end

local function call_gitsigns(method, ...)
	local fn = gitsigns_method(method)
	if not fn then
		return false
	end
	local invoked = pcall(fn, ...)
	return invoked
end

local function with_unchanged_buffer(context, callback)
	if not util.buffer_context_is_unchanged(context) then
		util.notify("Hunk context changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
		return false
	end

	local ok, result = pcall(vim.api.nvim_win_call, context.winid, function()
		return callback()
	end)
	if not ok then
		util.notify("Unable to restore the confirmed hunk context", vim.log.levels.WARN)
		return false
	end
	return result
end

local function supported_buffer(bufnr)
	if not vim.api.nvim_buf_is_loaded(bufnr) or not util.is_real_file_buffer(bufnr) then
		return nil
	end
	local path = util.buf_path(bufnr)
	if not path then
		return nil
	end
	local size, bo = util.buffer_size(bufnr), vim.bo[bufnr]
	-- The offset counts the final newline 'fixendofline' would write; capture
	-- omits it for an unmodified buffer. Full text validation stays in capture.
	if size == 1 and vim.api.nvim_buf_call(bufnr, function()
		return vim.fn.wordcount().chars == 0
	end) then
		size = 0
	elseif not bo.endofline and bo.fixendofline and not bo.binary and not bo.modified then
		size = size - 1
	end
	if util.file_size(path) > opts().max_file_bytes or size > opts().max_file_bytes then
		return nil, "too_large", path
	end

	return path
end

local function hunk_kind(hunk)
	if hunk.current_count == 0 then
		return hunk.current_start == 0 and "topdelete" or "delete"
	end
	if hunk.base_count == 0 then
		return "add"
	end
	if hunk.current_count < hunk.base_count then
		return "changedelete"
	end
	return "change"
end

local function hunk_rows(bufnr, hunk)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	if hunk.current_count == 0 then
		return { math.max(math.min(diff.hunk_anchor(hunk), line_count), 1) - 1 }
	end

	local rows = {}
	for offset = 0, hunk.current_count - 1 do
		rows[#rows + 1] = math.max(math.min(hunk.current_start + offset, line_count), 1) - 1
	end
	return rows
end

local function render_signs(bufnr, state)
	if state.delegate_after_command and defers_to_gitsigns(state.backend or "git", bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
		state.decorated_hunks, state.decorated_enabled = nil, nil
		return
	end
	if state.decorated_hunks == state.hunks and state.decorated_enabled == opts().enabled then
		return
	end
	state.decorated_hunks, state.decorated_enabled = state.hunks, opts().enabled
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	if not opts().enabled then
		return
	end
	local text = opts().text
	for _, hunk in ipairs(state.hunks) do
		local kind = hunk_kind(hunk)
		local sign_text = text[kind] or text.change
		local hl_group = kind == "add" and "LazyVcsSignAdd"
			or (kind == "delete" or kind == "topdelete") and "LazyVcsSignDelete"
			or "LazyVcsSignChange"
		for _, row in ipairs(hunk_rows(bufnr, hunk)) do
			local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, row, 0, {
				sign_text = sign_text,
				sign_hl_group = hl_group,
				priority = opts().sign_priority,
			})
			if not ok and state.sign_error_generation ~= state.generation then
				state.sign_error_generation = state.generation
				util.notify("Could not render native sign: " .. tostring(err), vim.log.levels.WARN)
			end
		end
	end
end

local start_diff_work = require("lazyvcs.diff_work").start

local delegate_to_gitsigns
local threaded_diff
local render

local function delegate_after_command(bufnr, state)
	if
		buffers[bufnr] == state
		and state.delegate_after_command
		and (state.native_holds or 0) == 0
		and (state.notifying_waiters or 0) == 0
	then
		if not delegate_to_gitsigns(bufnr, state) then
			state.delegate_after_command = nil
			render(bufnr)
		end
	end
end

local function notify_waiters(bufnr, state, keys, loaded, err)
	local waiters = {}
	for _, key in ipairs(keys) do
		vim.list_extend(waiters, state[key] or {})
		state[key] = nil
	end
	state.notifying_waiters = (state.notifying_waiters or 0) + 1
	for _, waiter in ipairs(waiters) do
		util.safe_callback(waiter)(loaded, err)
	end
	state.notifying_waiters = state.notifying_waiters - 1
	delegate_after_command(bufnr, state)
end

local function hold_native(bufnr, state)
	local backend = backends.resolve_cached(state.path)
	if defers_to_gitsigns(state.backend or (backend and backend.name), bufnr) then
		state.delegate_after_command = true
	end
	state.native_holds = (state.native_holds or 0) + 1
	state.native, state.delegated = true, nil
	local released = false
	return function()
		if released then
			return
		end
		released = true
		state.native_holds = state.native_holds - 1
		delegate_after_command(bufnr, state)
	end
end

render = function(bufnr, on_ready)
	local state = buffers[bufnr]
	if not state or not vim.api.nvim_buf_is_loaded(bufnr) then
		return false
	end
	if not state.native and delegate_to_gitsigns(bufnr, state, on_ready) then
		return false
	end
	local function complete(loaded, err)
		notify_waiters(bufnr, state, { "compute_waiters" }, loaded, err)
	end
	if on_ready then
		state.compute_waiters = state.compute_waiters or {}
		state.compute_waiters[#state.compute_waiters + 1] = on_ready
	end
	local identity, identity_err = compare_text.identity(bufnr)
	if not identity or not state.base_text or identity.profile_key ~= state.base_text.profile_key then
		state.hunks, state.loaded = {}, false
		render_signs(bufnr, state)
		complete(nil, identity_err or "Buffer decoding profile changed; reload the VCS base")
		return false
	end
	if vim.deep_equal(state.rendered_identity, identity) and state.rendered_base == state.base_text then
		render_signs(bufnr, state)
		complete(state)
		return true
	end
	if state.computing then
		return false
	end
	local current, err = compare_text.capture(bufnr, opts().max_file_bytes)
	if not current then
		state.hunks = {}
		render_signs(bufnr, state)
		complete(nil, err)
		return false
	end
	local base, generation = state.base_text, state.base_generation
	local function apply(hunks)
		if not state.native and delegate_to_gitsigns(bufnr, state) then
			return
		end
		state.rendered_identity, state.rendered_base = identity, base
		state.current_text, state.hunks = current, hunks
		render_signs(bufnr, state)
		complete(state)
	end
	local base_bytes, current_bytes = compare_text.serialize(base), compare_text.serialize(current)
	if threaded_diff ~= false and #base_bytes + #current_bytes > 32768 and base_bytes ~= current_bytes then
		local work, start_err
		work, start_err = start_diff_work(base_bytes, current_bytes, "indices", function(supported, packed, diff_err)
			if buffers[bufnr] ~= state or state.computing ~= work then
				return
			end
			state.computing = nil
			threaded_diff = supported
			if not vim.api.nvim_buf_is_loaded(bufnr) then
				return clear(bufnr)
			end
			if supported_buffer(bufnr) ~= state.path then
				return M.refresh(bufnr, false)
			end
			if
				state.base_text ~= base
				or state.base_generation ~= generation
				or not vim.deep_equal(compare_text.identity(bufnr), identity)
			then
				return render(bufnr)
			end
			if diff_err then
				complete(nil, diff_err)
				return util.notify(diff_err, vim.log.levels.WARN)
			end
			if not supported then
				return render(bufnr)
			end
			apply(diff.text_hunks(vim.mpack.decode(packed), base, current))
		end)
		state.computing = work
		if not work then
			complete(nil, start_err)
			util.notify(start_err, vim.log.levels.WARN)
		end
		return false
	end
	apply(diff.compute_text_hunks(base, current))
	return true
end

local function ensure_state(bufnr, path)
	local state = buffers[bufnr]
	if state and state.path == path then
		return state
	end
	if state then
		clear(bufnr)
	end
	state = {
		path = path,
		generation = 0,
		base_generation = 0,
		base_lines = {},
		hunks = {},
		loading = false,
	}
	buffers[bufnr] = state
	return state
end

local function path_identity(path, entry)
	local canonical = entry and util.canonical_entry_path(path) or util.canonical_path(path)
	return vim.o.fileignorecase and canonical:lower() or canonical
end

local function matches_change(change, state)
	local _, cached_root = backends.resolve_cached(state.path)
	local root = state.root or cached_root
	local path = path_identity(state.path, true)
	return (
		root and path_identity(root) == change.root
		or (not root and util.relative_literal_path(change.root, path) ~= nil)
	) and (not change.paths or change.paths[path] == true)
end

local function changing_base(state)
	for change in pairs(base_changes) do
		if matches_change(change, state) then
			return true
		end
	end
	return false
end

local function invalidate_base(bufnr, state, reason)
	if state.preview_pending then
		state.preview_pending.cancel()
	end
	for cancel in pairs(state.gitsigns_waiters or {}) do
		cancel(reason)
	end
	-- Base changes and gitsigns hand-offs retry a suspended base.
	state.unavailable_reason = nil
	state.generation = (state.generation or 0) + 1
	state.base_generation = (state.base_generation or 0) + 1
	local job = state.job
	state.job, state.loading, state.loaded = nil, false, false
	state.base_text, state.base_lines, state.base_identity = nil, nil, nil
	state.current_text, state.rendered_identity, state.rendered_base = nil, nil, nil
	state.hunks = {}
	stop_timer(bufnr)
	if job then
		pcall(job.kill, job, 15)
	end
	if vim.api.nvim_buf_is_loaded(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	end
end

local function suspend_base(bufnr, state, reason)
	reason = reason or "VCS base is unavailable"
	invalidate_base(bufnr, state)
	state.computing = nil
	state.decorated_hunks, state.decorated_enabled = nil, nil
	state.unavailable_reason = reason
	notify_waiters(bufnr, state, { "load_waiters", "compute_waiters" }, nil, reason)
end

-- Release every continuation before abandoning a native load or diff worker.
delegate_to_gitsigns = function(bufnr, state, on_ready)
	local backend = backends.resolve_cached(state.path)
	if not defers_to_gitsigns(state.backend or (backend and backend.name), bufnr) then
		return false
	end
	if (state.native_holds or 0) > 0 or (state.notifying_waiters or 0) > 0 then
		-- Serve commands already using the native base before handing signs over.
		state.delegate_after_command = true
		if on_ready then
			local key = state.loading and "load_waiters" or "compute_waiters"
			state[key] = state[key] or {}
			state[key][#state[key] + 1] = on_ready
		end
		return true
	end
	state.delegate_after_command = nil
	state.delegated, state.native = true, nil
	local waiters = {}
	for _, key in ipairs({ "load_waiters", "compute_waiters", "base_waiters" }) do
		vim.list_extend(waiters, state[key] or {})
		state[key] = nil
	end
	state.computing = nil
	invalidate_base(bufnr, state)
	for _, waiter in ipairs(waiters) do
		util.safe_callback(waiter)(nil, "Git signs are delegated to gitsigns.nvim")
	end
	if on_ready then
		util.safe_callback(on_ready)(nil, "Git signs are delegated to gitsigns.nvim")
	end
	return true
end

function M.begin_base_change(root, paths)
	local change = { root = path_identity(root) }
	if paths then
		change.paths = {}
		for _, path in ipairs(paths) do
			change.paths[path_identity(path, true)] = true
		end
	end
	base_changes[change] = true
	for buf, state in pairs(buffers) do
		if matches_change(change, state) then
			invalidate_base(buf, state, "base_changed")
		end
	end
	return change
end

function M.finish_base_change(change)
	if not base_changes[change] then
		return
	end
	base_changes[change] = nil
	for buf, state in pairs(buffers) do
		if matches_change(change, state) then
			invalidate_base(buf, state, "base_changed")
			if not changing_base(state) then
				state.gitsigns_refresh_needed = defers_to_gitsigns(state.backend or "git", buf) or nil
				local waiters = state.base_waiters or {}
				state.base_waiters = nil
				local awaiting = #waiters > 0 or state.load_waiters ~= nil or state.compute_waiters ~= nil
				if awaiting or opts().enabled then
					local ready
					if #waiters > 0 then
						ready = function(loaded, err)
							for _, waiter in ipairs(waiters) do
								util.safe_callback(waiter)(loaded, err)
							end
						end
					end
					M.refresh(buf, false, ready, awaiting)
				end
			end
		end
	end
end

function M.refresh(bufnr, reload_base, on_ready, native)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	local path, reason, skipped_path = supported_buffer(bufnr)
	if not path then
		local state = buffers[bufnr]
		if
			reason == "too_large"
			and state
			and state.path == skipped_path
			and ((state.native_holds or 0) > 0 or state.gitsigns_refresh_needed)
		then
			-- A delegated revert shares the native command hold and settlement waiters,
			-- but cannot load a native base. Preserve it across automatic refreshes.
			if (state.native_holds or 0) == 0 then
				invalidate_base(bufnr, state)
				state.native, state.delegated, state.computing = nil, nil, nil
				state.decorated_hunks, state.decorated_enabled = nil, nil
				state.skipped = true
			end
			if changing_base(state) then
				if on_ready then
					state.base_waiters = state.base_waiters or {}
					state.base_waiters[#state.base_waiters + 1] = on_ready
				end
			elseif on_ready then
				on_ready(state)
			end
			return
		end
		clear(bufnr)
		if reason == "too_large" then
			ensure_state(bufnr, skipped_path).skipped = true
		end
		if on_ready then
			on_ready(nil, "No supported VCS buffer")
		end
		return
	end

	local state = ensure_state(bufnr, path)
	if reload_base and state.preview_pending then
		state.preview_pending.cancel()
	end
	state.skipped = nil
	if changing_base(state) then
		if on_ready then
			state.base_waiters = state.base_waiters or {}
			state.base_waiters[#state.base_waiters + 1] = on_ready
		end
		return
	end
	if not native and delegate_to_gitsigns(bufnr, state, on_ready) then
		return
	end
	-- Autocmd reloads share the command's native ownership, including async callbacks.
	native = native or (state.native_holds or 0) > 0 or nil
	local profile, profile_err = compare_text.profile(bufnr)
	if not profile then
		clear(bufnr)
		if on_ready then
			on_ready(nil, profile_err)
		end
		return
	end
	if on_ready then
		state.load_waiters = state.load_waiters or {}
		state.load_waiters[#state.load_waiters + 1] = on_ready
	end
	if state.loading and not reload_base then
		return state.job
	end
	state.native, state.delegated = native, nil
	on_ready = function(loaded, err)
		local keys = loaded and { "load_waiters" } or { "load_waiters", "compute_waiters" }
		notify_waiters(bufnr, state, keys, loaded, err)
	end
	if not reload_base and state.loaded and state.base_text and state.base_text.profile_key == profile.key then
		render(bufnr, state.load_waiters and on_ready or nil)
		return state
	end

	if state.job and type(state.job.kill) == "function" then
		pcall(state.job.kill, state.job, 15)
	end
	state.base_generation = state.base_generation + 1
	state.generation = state.generation + 1
	state.loaded = false
	local generation = state.generation
	state.loading = true
	local job = require("lazyvcs.backends.task").new()
	local resolved_backend = false
	local function loaded_impl(result, err, rejection)
		local live = buffers[bufnr]
		if not live or live ~= state or live.generation ~= generation then
			return
		end
		if not native and delegate_to_gitsigns(bufnr, live) then
			return
		end
		job:finish()
		local eligible, reason, skipped_path = supported_buffer(bufnr)
		local current_profile = compare_text.profile(bufnr)
		if
			not vim.api.nvim_buf_is_loaded(bufnr)
			or eligible ~= path
			or not current_profile
			or current_profile.key ~= profile.key
		then
			clear(bufnr)
			if reason == "too_large" then
				ensure_state(bufnr, skipped_path).skipped = true
			end
			if on_ready then
				on_ready(nil, "Buffer decoding context changed while loading")
			end
			return
		end
		live.job = nil
		live.loading = false
		if not result then
			if resolved_backend then
				suspend_base(bufnr, live, err)
			else
				clear(bufnr)
				on_ready(nil, err)
			end
			if
				err
				and not rejection
				and err:match("tracked") == nil
				and not err:match("No Git or SVN working copy found")
				and not err:match("^Cancelled")
			then
				util.notify(err, vim.log.levels.DEBUG)
			end
			return
		end
		live.root = result.root
		live.relpath = result.relpath
		live.base_label = result.base_label
		local document, decode_err = diff.decode_base(bufnr, result, opts().max_file_bytes)
		if not document then
			suspend_base(bufnr, live, decode_err)
			return
		end
		live.unavailable_reason = nil
		live.base_text, live.base_lines = document, document.lines
		live.base_identity = result.base_identity
		live.loaded = true
		render(bufnr, state.load_waiters and on_ready or nil)
	end
	local loaded = util.safe_callback(loaded_impl)
	job:add(backends.resolve_async(
		path,
		util.safe_callback(function(backend, root, err)
			if not job:is_active() then
				return
			end
			if not backend then
				return loaded(nil, err)
			end
			resolved_backend = true
			state.backend = backend.name
			if not native and delegate_to_gitsigns(bufnr, state) then
				return
			end
			state.root = root
			if changing_base(state) then
				state.loading = false
				job:finish()
				state.job = nil
				state.base_waiters = state.base_waiters or {}
				if on_ready then
					state.base_waiters[#state.base_waiters + 1] = on_ready
				end
				return
			end
			job:add(backends.load_base_async(path, loaded))
		end)
	))
	state.job = job
	return job
end

local function delegated_owner_available(bufnr, state)
	if not state or not state.delegated then
		return false
	end
	if defers_to_gitsigns(state.backend or "git", bufnr) then
		return true
	end
	state.delegated = nil
	return false
end

local function schedule(bufnr)
	if not opts().enabled or delegated_owner_available(bufnr, buffers[bufnr]) then
		return
	end
	stop_timer(bufnr)
	local timer = vim.uv.new_timer()
	if not timer then
		M.refresh(bufnr, false)
		return
	end
	timers[bufnr] = timer
	timer:start(
		opts().debounce_ms,
		0,
		vim.schedule_wrap(util.safe_callback(function()
			if timers[bufnr] ~= timer or not vim.api.nvim_buf_is_loaded(bufnr) then
				return
			end
			stop_timer(bufnr)
			M.refresh(bufnr, false)
		end))
	)
end

local function with_current_state(context, on_ready, asynchronous)
	local bufnr = context.bufnr
	local path = supported_buffer(bufnr)
	local state = path and ensure_state(bufnr, path)
	if not state then
		M.refresh(bufnr, true, function(_, err)
			util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
		end, true)
		return true
	end
	local release = hold_native(bufnr, state)
	local result = false
	local function ready(loaded, err)
		if loaded and vim.api.nvim_get_current_win() == context.winid and util.buffer_context_is_unchanged(context) then
			local ok, value = pcall(on_ready, loaded, release)
			if not asynchronous or not ok then
				release()
			end
			if not ok then
				error(value)
			end
			result = value
		else
			release()
			if not loaded or err then
				util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
			end
		end
	end
	local profile = compare_text.profile(bufnr)
	if state.loaded and profile and state.base_text and state.base_text.profile_key == profile.key then
		local completed = render(bufnr, ready)
		if completed and result ~= nil then
			return result
		end
		return true
	end
	M.refresh(bufnr, true, ready, true)
	return true
end

function M.current_state(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	return buffers[bufnr]
end

-- Index settlement precedes gitsigns' debounced watcher. Share one deadline
-- between the refresh request and its buffer-specific update event.
local function after_gitsigns_refresh(context, state, release, on_ready)
	local bufnr = context.bufnr
	if
		buffers[bufnr] ~= state
		or vim.api.nvim_get_current_win() ~= context.winid
		or not util.buffer_context_is_unchanged(context)
	then
		release()
		return false
	end
	local gs = package.loaded.gitsigns
	local timer = vim.uv.new_timer()
	local autocmd, finished, cancel
	local function finish(refreshed)
		if finished then
			return
		end
		finished = true
		if state.gitsigns_waiters then
			state.gitsigns_waiters[cancel] = nil
		end
		if timer then
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
		end
		if autocmd then
			pcall(vim.api.nvim_del_autocmd, autocmd)
		end
		if not refreshed or package.loaded.gitsigns ~= gs then
			release()
			return
		end
		local ok, err = pcall(on_ready)
		if not ok then
			release()
			error(err, 0)
		end
	end
	cancel = function(reason)
		if finished then
			return
		end
		finish(false)
		if reason == "base_changed" then
			util.notify("Hunk base changed while waiting; nothing was reverted", vim.log.levels.WARN)
		end
	end
	state.gitsigns_waiters = state.gitsigns_waiters or {}
	state.gitsigns_waiters[cancel] = true
	local function timeout()
		if finished then
			return
		end
		-- Keep the freshness mark: without native validation, a retry could reset
		-- against hunks gitsigns computed from the previous base.
		cancel()
		util.notify(
			"gitsigns.nvim has not refreshed its hunks, so nothing was reverted; retry after its signs update",
			vim.log.levels.WARN
		)
	end
	if not timer then
		timeout()
		return false
	end
	local ok, err = pcall(function()
		autocmd = vim.api.nvim_create_autocmd("User", {
			group = augroup,
			pattern = "GitSignsUpdate",
			callback = util.safe_callback(function(args)
				if (args.data and args.data.buffer or args.buf) == bufnr then
					finish(true)
				end
			end),
		})
		timer:start(2000, 0, vim.schedule_wrap(util.safe_callback(timeout)))
		-- The public API refreshes all attached buffers; only this buffer's update
		-- releases the wait. Install the listener before calling it.
		if type(gs) == "table" and type(gs.refresh) == "function" then
			vim.api.nvim_buf_call(bufnr, gs.refresh)
		end
	end)
	if not ok then
		cancel()
		util.notify("Unable to refresh gitsigns.nvim hunks: " .. tostring(err), vim.log.levels.WARN)
		return false
	end
	return true
end

-- Match gitsigns' all-or-nothing DOS normalization, preserving an unterminated
-- last line (and LF base blobs) when it has no CR to strip.
local function strip_gitsigns_cr(lines)
	for i = 1, #lines - 1 do
		if lines[i]:sub(-1) ~= "\r" then
			return lines
		end
	end
	local result = {}
	for i, line in ipairs(lines) do
		result[i] = line:sub(-1) == "\r" and line:sub(1, -2) or line
	end
	return result
end

-- Only the native size limit is bypassed; gitsigns still owns eligibility and hunks.
local function revert_large_gitsigns_hunk(context)
	local bufnr = context.bufnr
	local state = ensure_state(bufnr, context.path)
	if state.large_revert_pending then
		util.notify("A hunk revert is already pending for this buffer", vim.log.levels.WARN)
		return false
	end
	state.skipped = true
	local release_native = hold_native(bufnr, state)
	local function release()
		if state.large_revert_pending == release then
			state.large_revert_pending = nil
		end
		release_native()
	end
	state.large_revert_pending = release
	local function ready()
		if
			buffers[bufnr] ~= state
			or vim.api.nvim_get_current_win() ~= context.winid
			or not util.buffer_context_is_unchanged(context)
		then
			release()
			return false
		end
		local gs = gitsigns_api()
		if not gs then
			release()
			util.notify("Unable to read gitsigns.nvim hunk state", vim.log.levels.WARN)
			return false
		end
		local ok, hunks = pcall(gs.get_hunks, bufnr)
		if not ok or type(hunks) ~= "table" then
			release()
			util.notify("Unable to read gitsigns.nvim hunk state", vim.log.levels.WARN)
			return false
		end
		local selected
		for _, hunk in ipairs(hunks) do
			if
				diff.find_current_hunk(
					{ {
						current_start = hunk.added.start,
						current_count = hunk.added.count,
					} },
					context.cursor[1]
				)
			then
				selected = vim.deepcopy(hunk)
				break
			end
		end
		if not selected then
			release()
			util.notify("No modified gitsigns hunk at the cursor", vim.log.levels.WARN)
			return false
		end
		local confirmed_generation = state.base_generation
		local confirmed_hunks = vim.deepcopy(hunks)
		local function context_is_unchanged()
			local current_ok, current_hunks = pcall(gs.get_hunks, bufnr)
			local unchanged = util.buffer_context_is_unchanged(context)
				and buffers[bufnr] == state
				and not changing_base(state)
				and state.base_generation == confirmed_generation
				and package.loaded.gitsigns == gs
				and defers_to_gitsigns("git", bufnr)
				and current_ok
				and vim.deep_equal(current_hunks, confirmed_hunks)
			if not unchanged then
				release()
				util.notify(
					"Hunk context or base changed while confirmation was open; nothing was reverted",
					vim.log.levels.WARN
				)
			end
			return unchanged
		end
		local confirmed, result = pcall(confirm.mutation, {
			prompt = "Revert hunk under cursor?",
			before_confirm = context_is_unchanged,
		}, function()
			if not context_is_unchanged() then
				return false
			end
			local reverted = with_unchanged_buffer(context, function()
				local added, removed = selected.added, selected.removed
				local added_lines, removed_lines = added.lines, removed.lines
				if vim.bo[bufnr].fileformat == "dos" then
					added_lines, removed_lines = strip_gitsigns_cr(added_lines), strip_gitsigns_cr(removed_lines)
				end
				local start_row = added.count == 0 and added.start or math.max(added.start - 1, 0)
				local end_row = start_row + added.count
				local line_count = vim.api.nvim_buf_line_count(bufnr)
				if
					#added.lines ~= added.count
					or #removed.lines ~= removed.count
					or start_row < 0
					or end_row > line_count
					or not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false), added_lines)
				then
					util.notify("Reported hunk no longer matches the buffer; nothing was reverted", vim.log.levels.WARN)
					return false
				end
				local base_eol
				local empty = context.text_identity.empty
				if end_row == line_count or (empty and added.count == 0 and start_row == 0) then
					if added.count > 0 and (added.no_nl_at_eof or false) ~= not vim.bo[bufnr].endofline then
						util.notify("Reported hunk EOF state changed; nothing was reverted", vim.log.levels.WARN)
						return false
					end
					base_eol = not removed.no_nl_at_eof
				end
				if empty and added.count == 0 and start_row == 0 then
					end_row = -1
				end
				diff.reset_hunk_lines(bufnr, start_row, end_row, removed_lines, base_eol)
				return true
			end)
			release()
			return reverted
		end, release)
		if not confirmed then
			release()
			error(result, 0)
		end
		return result
	end
	if changing_base(state) then
		state.base_waiters = state.base_waiters or {}
		state.base_waiters[#state.base_waiters + 1] = function()
			return after_gitsigns_refresh(context, state, release, ready)
		end
		return true
	end
	if state.gitsigns_refresh_needed then
		return after_gitsigns_refresh(context, state, release, ready)
	end
	return ready()
end

local function revert_hunk(context)
	if not context then
		return false
	end

	local bufnr = context.bufnr
	local _, reason = supported_buffer(bufnr)
	if reason == "too_large" and gitsigns_api() then
		return revert_large_gitsigns_hunk(context)
	end
	local function ready(state, release)
		if vim.api.nvim_get_current_win() ~= context.winid or not util.buffer_context_is_unchanged(context) then
			release()
			return false
		end
		local line = context.cursor[1]
		local hunk = diff.find_current_hunk(state.hunks or {}, line)
		if not hunk then
			util.notify("No modified hunk at the cursor", vim.log.levels.WARN)
			release()
			return
		end
		local confirmed_generation = state.base_generation
		local confirmed_base = vim.deepcopy(state.base_text)
		local confirmed_identity = vim.deepcopy(state.base_identity)
		local confirmed_hunk = vim.deepcopy(hunk)
		local function release_on_error(callback)
			return function(...)
				local ok, result = pcall(callback, ...)
				if not ok then
					release()
					error(result, 0)
				end
				return result
			end
		end
		local function context_is_unchanged()
			if not util.buffer_context_is_unchanged(context) then
				util.notify(
					"Hunk context changed while confirmation was open; nothing was reverted",
					vim.log.levels.WARN
				)
				return false
			end
			local live = buffers[bufnr]
			if live then
				render(bufnr)
			end
			local current_hunk = live and diff.find_current_hunk(live.hunks or {}, context.cursor[1]) or nil
			if
				live ~= state
				or not live.loaded
				or live.base_generation ~= confirmed_generation
				or not vim.deep_equal(live.base_text, confirmed_base)
				or not vim.deep_equal(live.base_identity, confirmed_identity)
				or not vim.deep_equal(current_hunk, confirmed_hunk)
			then
				util.notify("Hunk base changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
				return false
			end
			return true
		end
		local function on_confirm()
			if not context_is_unchanged() then
				release()
				return false
			end
			local function reset()
				if not context_is_unchanged() then
					release()
					return false
				end
				local result = with_unchanged_buffer(context, function()
					diff.reset_text_hunk(bufnr, confirmed_base, state.current_text, confirmed_hunk)
					schedule(bufnr)
					return true
				end)
				release()
				return result
			end
			if not state.base_identity then
				return reset()
			end
			return backends.validate_editable_base_async(
				context.path,
				state.base_identity,
				util.safe_callback(release_on_error(function(valid, err)
					if buffers[bufnr] ~= state or state.base_generation ~= confirmed_generation then
						util.notify(
							"Hunk base changed while confirmation was open; nothing was reverted",
							vim.log.levels.WARN
						)
						release()
						return
					end
					if not valid then
						clear(bufnr)
						release()
						return util.notify(err or "Hunk base is no longer editable", vim.log.levels.WARN)
					end
					reset()
				end))
			)
		end
		return confirm.mutation(
			{
				prompt = "Revert hunk under cursor?",
				before_confirm = release_on_error(function()
					local valid = context_is_unchanged()
					if not valid then
						release()
					end
					return valid
				end),
			},
			release_on_error(on_confirm),
			function()
				release()
				return false
			end
		)
	end
	return with_current_state(context, ready, true)
end

local function jump_to_hunk(context, direction)
	if call_gitsigns("nav_hunk", direction) or call_gitsigns(direction == "next" and "next_hunk" or "prev_hunk") then
		return true
	end
	local bufnr = vim.api.nvim_get_current_buf()
	return with_current_state(context, function(state)
		local hunks = state.hunks or {}
		if #hunks == 0 then
			util.notify("No hunks in the current buffer", vim.log.levels.INFO)
			return
		end
		local line = vim.api.nvim_win_get_cursor(0)[1]
		diff.focus_hunk(0, bufnr, diff.find_neighbor_hunk(hunks, line, direction))
	end)
end

local function show_preview(text)
	local lines = util.split_lines(text)
	if #lines == 0 then
		lines = { "No changes" }
	end

	local width = math.min(math.max(60, math.floor(vim.o.columns * 0.7)), vim.o.columns - 4)
	local height = math.min(math.max(10, #lines), vim.o.lines - 6)
	if width < 1 or height < 1 then
		return util.notify("Editor is too small for a diff preview", vim.log.levels.INFO)
	end
	local buf, win
	local ok, err = pcall(function()
		buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].filetype = "diff"
		win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.max(1, math.floor((vim.o.lines - height) / 2)),
			col = math.max(1, math.floor((vim.o.columns - width) / 2)),
			style = "minimal",
			border = "rounded",
			title = " LazyVCS Diff ",
		})
		util.unbind_window(win)
		local close_preview = util.safe_callback(function()
			if util.win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end)
		compat.keymap_set("n", "q", close_preview, { buffer = buf, silent = true, nowait = true })
		compat.keymap_set("n", "<Esc>", close_preview, { buffer = buf, silent = true, nowait = true })
	end)
	if not ok then
		if win and util.win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if buf and util.buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		util.notify("Unable to open diff preview: " .. tostring(err), vim.log.levels.WARN)
	end
end

local function preview_request(context, loaded, release)
	local bufnr = context.bufnr
	local generation, base = loaded.base_generation, loaded.base_text
	local request = { context = context }
	function request.valid()
		return loaded.preview_pending == request
			and buffers[bufnr] == loaded
			and not runtime.is_shutting_down()
			and loaded.base_text == base
			and loaded.base_generation == generation
			and vim.api.nvim_get_current_win() == context.winid
			and util.buffer_context_is_unchanged(context)
	end
	local group = vim.api.nvim_create_augroup("lazyvcs_preview_" .. bufnr, { clear = true })
	loaded.preview_pending = request
	function request.cancel()
		if loaded.preview_pending ~= request then
			return
		end
		loaded.preview_pending = nil
		pcall(vim.api.nvim_del_augroup_by_id, group)
		release()
	end
	local configured, configure_err = pcall(function()
		vim.api.nvim_create_autocmd(
			{ "TextChanged", "TextChangedI", "BufLeave", "WinLeave", "BufFilePost", "BufUnload", "VimLeavePre" },
			{
				group = group,
				buffer = bufnr,
				callback = util.safe_callback(request.cancel),
			}
		)
		vim.api.nvim_create_autocmd("WinClosed", {
			group = group,
			pattern = tostring(context.winid),
			callback = util.safe_callback(request.cancel),
		})
	end)
	if not configured then
		request.cancel()
		util.notify(configure_err, vim.log.levels.WARN)
		return nil
	end
	return request
end

local function preview_diff(context)
	if call_gitsigns("preview_hunk") then
		return true
	end
	local bufnr = context.bufnr
	local function queue_if_busy()
		local busy = preview_workers[bufnr]
		if not busy then
			return false
		end
		local state = buffers[bufnr]
		if state then
			local pending = state.preview_pending
			if pending and pending.valid() then
				return true
			end
			if pending then
				pending.cancel()
			end
			-- Queue only the context. A cancelled physical worker owns no command hold.
			busy.latest = preview_request(context, state, function() end)
		end
		return true
	end
	if queue_if_busy() then
		return true
	end
	return with_current_state(context, function(loaded, release)
		if queue_if_busy() then
			release()
			return true
		end
		local base, current = loaded.base_text, loaded.current_text
		local left, right = compare_text.serialize(base), compare_text.serialize(current)
		if #left + #right <= 32768 or left == right then
			release()
			return show_preview(compat.diff(left, right, { algorithm = "histogram", result_type = "unified" }))
		end
		local request = preview_request(context, loaded, release)
		if not request then
			return true
		end
		local work, err
		work, err = start_diff_work(left, right, "unified", function(supported, output, diff_err)
			if preview_workers[bufnr] == request then
				preview_workers[bufnr] = nil
			end
			if loaded.preview_work == work then
				loaded.preview_work = nil
			end
			local latest = request.latest
			if latest then
				local checked, valid = pcall(latest.valid)
				valid = checked and valid
				latest.cancel()
				request.cancel()
				if valid then
					preview_diff(latest.context)
				end
				return
			end
			local ok, valid = pcall(request.valid)
			request.cancel()
			if not ok then
				return util.notify(valid, vim.log.levels.WARN)
			end
			if not valid then
				return
			end
			if diff_err or not supported then
				return util.notify(
					diff_err or "Threaded diff is unavailable for a large native preview",
					vim.log.levels.WARN
				)
			end
			show_preview(output)
		end)
		loaded.preview_work = work
		preview_workers[bufnr] = work and request or nil
		if not work then
			request.cancel()
			util.notify(err, vim.log.levels.WARN)
		end
		return true
	end, true)
end

local function dispatch_command(operation)
	local context = util.capture_buffer_context()
	if
		not context
		or not context.path
		or not vim.api.nvim_buf_is_loaded(context.bufnr)
		or not util.is_real_file_buffer(context.bufnr)
	then
		util.notify("No supported VCS buffer", vim.log.levels.WARN)
		return false
	end
	local state = supported_buffer(context.bufnr) and ensure_state(context.bufnr, context.path)
		or buffers[context.bufnr]
	local function dispatch(backend, _, err)
		if
			buffers[context.bufnr] ~= state
			or not vim.api.nvim_buf_is_loaded(context.bufnr)
			or vim.api.nvim_get_current_win() ~= context.winid
			or not util.buffer_context_is_unchanged(context)
		then
			return
		end
		if not backend then
			return util.notify(err or "No supported VCS buffer", vim.log.levels.WARN)
		end
		if operation == "revert" then
			return revert_hunk(context)
		elseif operation == "preview" then
			return preview_diff(context)
		end
		return jump_to_hunk(context, operation)
	end
	local backend = backends.resolve_cached(context.path)
	if backend then
		return dispatch(backend)
	end
	local command = backends.resolve_async(context.path, util.safe_callback(dispatch))
	if state then
		state.command = command
	end
	return true
end

function M.revert_hunk()
	return dispatch_command("revert")
end

function M.jump_to_hunk(direction)
	return dispatch_command(direction)
end

function M.preview_diff()
	return dispatch_command("preview")
end

-- Whole-buffer revert lives in `lazyvcs.buffer_ops`, which dispatches through the
-- backend registry instead of shelling out to `svn` directly.

function M.setup()
	setup_highlights()
	if augroup then
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		augroup = nil
	end

	local attached = vim.tbl_keys(buffers)
	for _, bufnr in ipairs(attached) do
		clear(bufnr)
	end

	-- Register highlights even with signs disabled; blame also needs them after ColorScheme.
	local hl_group = vim.api.nvim_create_augroup("lazyvcs_highlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = hl_group,
		callback = util.safe_callback(setup_highlights),
	})

	augroup = vim.api.nvim_create_augroup("lazyvcs_signs", { clear = true })
	-- GitSignsUpdate also fires after attach; its target can be a background buffer.
	vim.api.nvim_create_autocmd("User", {
		group = augroup,
		pattern = "GitSignsUpdate",
		callback = util.safe_callback(function(args)
			local buf = args.data and args.data.buffer or args.buf
			local state = buffers[buf]
			if state then
				state.gitsigns_refresh_needed = nil
			end
			if state and not state.skipped then
				delegate_to_gitsigns(buf, state)
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufFilePost" }, {
		group = augroup,
		callback = util.safe_callback(function(args)
			if opts().enabled then
				M.refresh(args.buf, true)
			else
				clear(args.buf)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = util.safe_callback(function(args)
			-- Reuse the cached base on window changes; reload_base would spawn and cancel a VCS
			-- read on every switch.
			if opts().enabled then
				M.refresh(args.buf, false)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		callback = util.safe_callback(function(args)
			if opts().enabled then
				M.refresh(args.buf, true)
			else
				clear(args.buf)
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		callback = util.safe_callback(function(args)
			local state = buffers[args.buf]
			-- A suspended base waits for a base change, write, buffer entry or refresh.
			if
				opts().enabled
				and state
				and not state.unavailable_reason
				and not delegated_owner_available(args.buf, state)
			then
				schedule(args.buf)
			end
		end),
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = augroup,
		pattern = { "fileencoding", "fileformat", "bomb", "binary", "endofline", "fixendofline" },
		callback = util.safe_callback(function()
			local buf = vim.api.nvim_get_current_buf()
			if opts().enabled and buffers[buf] and not buffers[buf].unavailable_reason then
				schedule(buf)
			end
		end),
	})

	vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
		group = augroup,
		callback = util.safe_callback(function(args)
			clear(args.buf)
		end),
	})

	if opts().enabled and vim.api.nvim_get_current_buf() ~= 0 then
		M.refresh(vim.api.nvim_get_current_buf(), true)
	end
end

function M._test_state()
	return {
		buffers = buffers,
		namespace = ns_id,
		hunk_kind = hunk_kind,
	}
end

return M
