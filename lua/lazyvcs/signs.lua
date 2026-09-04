local backends = require("lazyvcs.backends")
local config = require("lazyvcs.config")
local compat = require("lazyvcs.compat")
local diff = require("lazyvcs.diff")
local confirm = require("lazyvcs.source_control.confirm")
local util = require("lazyvcs.util")

local M = {}

local ns_id = vim.api.nvim_create_namespace("lazyvcs_signs")
local augroup
local buffers = {}
local timers = {}

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
	stop_timer(bufnr)
	if state and state.job and type(state.job.kill) == "function" then
		pcall(state.job.kill, state.job, 15)
	end
end

-- Rendering our own Git signs on top of gitsigns.nvim would double up the gutter,
-- so defer to it when it is installed and enabled. SVN has no such plugin, so
-- lazyvcs always owns those signs.
local function defers_to_gitsigns(backend_name)
	if backend_name ~= "git" or not config.get().use_gitsigns then
		return false
	end
	return package.loaded["gitsigns"] ~= nil or pcall(require, "gitsigns")
end

local function gitsigns_api()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = util.buf_path(bufnr)
	local backend = path and backends.resolve_cached(path) or nil
	if not backend or not defers_to_gitsigns(backend.name) then
		return nil
	end
	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok then
		return nil
	end
	return gitsigns
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
	if not opts().enabled then
		return nil
	end
	if not util.is_real_file_buffer(bufnr) then
		return nil
	end
	local path = util.buf_path(bufnr)
	if not path or util.file_size(path) > opts().max_file_bytes then
		return nil
	end

	return path
end

local function hunk_kind(hunk)
	if hunk.current_count == 0 then
		return hunk.current_start <= 1 and "topdelete" or "delete"
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

local function render(bufnr)
	local state = buffers[bufnr]
	if not state or not util.buf_is_valid(bufnr) then
		return
	end

	state.hunks = diff.compute_hunks(state.base_lines, util.get_buf_lines(bufnr))
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	local text = opts().text
	for _, hunk in ipairs(state.hunks) do
		local kind = hunk_kind(hunk)
		local sign_text = text[kind] or text.change
		local hl_group = kind == "add" and "LazyVcsSignAdd"
			or (kind == "delete" or kind == "topdelete") and "LazyVcsSignDelete"
			or "LazyVcsSignChange"
		for _, row in ipairs(hunk_rows(bufnr, hunk)) do
			pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, row, 0, {
				sign_text = sign_text,
				sign_hl_group = hl_group,
				priority = opts().sign_priority,
			})
		end
	end
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
		base_lines = {},
		hunks = {},
		loading = false,
	}
	buffers[bufnr] = state
	return state
end

function M.refresh(bufnr, reload_base, on_ready)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	local path = supported_buffer(bufnr)
	if not path then
		clear(bufnr)
		if on_ready then
			on_ready(nil, "No supported VCS buffer")
		end
		return
	end

	local state = ensure_state(bufnr, path)
	if not reload_base and state.loaded then
		render(bufnr)
		if on_ready then
			on_ready(state)
		end
		return state
	end

	if state.job and type(state.job.kill) == "function" then
		pcall(state.job.kill, state.job, 15)
	end
	state.generation = state.generation + 1
	local generation = state.generation
	state.loading = true
	local job
	job = backends.load_base_async(path, function(result, err)
		local live = buffers[bufnr]
		if not live or live.generation ~= generation or not util.buf_is_valid(bufnr) then
			return
		end
		live.job = nil
		live.loading = false
		if not result then
			clear(bufnr)
			if err and err:match("tracked") == nil then
				util.notify(err, vim.log.levels.DEBUG)
			end
			if on_ready then
				on_ready(nil, err)
			end
			return
		end
		local backend = backends.resolve_cached(path)
		if backend and defers_to_gitsigns(backend.name) then
			clear(bufnr)
			if on_ready then
				on_ready(nil, "Git signs are delegated to gitsigns.nvim")
			end
			return
		end
		live.root = result.root
		live.relpath = result.relpath
		live.base_label = result.base_label
		live.base_lines = result.base_lines
		live.loaded = true
		render(bufnr)
		if on_ready then
			on_ready(live)
		end
	end)
	state.job = job
	return job
end

local function schedule(bufnr)
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
		vim.schedule_wrap(function()
			stop_timer(bufnr)
			timers[bufnr] = nil
			M.refresh(bufnr, false)
		end)
	)
end

local function with_current_state(on_ready)
	local bufnr = vim.api.nvim_get_current_buf()
	local state = buffers[bufnr]
	if state and state.loaded then
		render(bufnr)
		local result = on_ready(state)
		if result ~= nil then
			return result
		end
		return true
	end
	M.refresh(bufnr, true, function(loaded, err)
		if not loaded then
			util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
			return
		end
		if vim.api.nvim_get_current_buf() ~= bufnr then
			return
		end
		on_ready(loaded)
	end)
	return true
end

function M.current_state(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	return buffers[bufnr]
end

function M.revert_hunk()
	local context = util.capture_buffer_context()
	if not context then
		return false
	end
	local reset_hunk = gitsigns_method("reset_hunk")
	if reset_hunk then
		local gitsigns = gitsigns_api()
		if not gitsigns or type(gitsigns.get_hunks) ~= "function" then
			util.notify("gitsigns.nvim cannot report hunk state; update it before reverting", vim.log.levels.WARN)
			return false
		end
		local ok, hunks = pcall(gitsigns.get_hunks, context.bufnr)
		if not ok or type(hunks) ~= "table" then
			util.notify("Unable to read gitsigns.nvim hunk state", vim.log.levels.WARN)
			return false
		end
		local confirmed_hunks = vim.deepcopy(hunks)
		local function context_is_unchanged()
			if not util.buffer_context_is_unchanged(context) then
				util.notify(
					"Hunk context changed while confirmation was open; nothing was reverted",
					vim.log.levels.WARN
				)
				return false
			end
			local current_ok, current_hunks = pcall(gitsigns.get_hunks, context.bufnr)
			if not current_ok or not vim.deep_equal(current_hunks, confirmed_hunks) then
				util.notify("Hunk base changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
				return false
			end
			return true
		end
		return confirm.mutation({
			prompt = "Revert hunk under cursor?",
			before_confirm = context_is_unchanged,
		}, function()
			if not context_is_unchanged() then
				return false
			end
			return with_unchanged_buffer(context, function()
				return pcall(reset_hunk)
			end)
		end)
	end
	local bufnr = context.bufnr
	return with_current_state(function(state)
		context = util.capture_buffer_context()
		if not context then
			return false
		end
		local line = context.cursor[1]
		local hunk = diff.find_current_hunk(state.hunks or {}, line)
		if not hunk then
			util.notify("No modified hunk at the cursor", vim.log.levels.WARN)
			return
		end
		local confirmed_base_lines = vim.deepcopy(state.base_lines)
		local confirmed_hunk = vim.deepcopy(hunk)
		local function context_is_unchanged()
			if not util.buffer_context_is_unchanged(context) then
				util.notify(
					"Hunk context changed while confirmation was open; nothing was reverted",
					vim.log.levels.WARN
				)
				return false
			end
			local live = buffers[bufnr]
			local current_hunk = live and diff.find_current_hunk(live.hunks or {}, context.cursor[1]) or nil
			if
				not live
				or not live.loaded
				or not vim.deep_equal(live.base_lines, confirmed_base_lines)
				or not vim.deep_equal(current_hunk, confirmed_hunk)
			then
				util.notify("Hunk base changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
				return false
			end
			return true
		end
		return confirm.mutation({
			prompt = "Revert hunk under cursor?",
			before_confirm = context_is_unchanged,
		}, function()
			if not context_is_unchanged() then
				return false
			end
			return with_unchanged_buffer(context, function()
				diff.reset_hunk(bufnr, confirmed_base_lines, confirmed_hunk)
				schedule(bufnr)
				return true
			end)
		end)
	end)
end

function M.jump_to_hunk(direction)
	if call_gitsigns("nav_hunk", direction) or call_gitsigns(direction == "next" and "next_hunk" or "prev_hunk") then
		return true
	end
	local bufnr = vim.api.nvim_get_current_buf()
	return with_current_state(function(state)
		local hunks = state.hunks or {}
		if #hunks == 0 then
			util.notify("No hunks in the current buffer", vim.log.levels.INFO)
			return
		end
		local line = vim.api.nvim_win_get_cursor(0)[1]
		diff.focus_hunk(0, bufnr, diff.find_neighbor_hunk(hunks, line, direction))
	end)
end

function M.preview_diff()
	if call_gitsigns("preview_hunk") then
		return true
	end
	local bufnr = vim.api.nvim_get_current_buf()
	return with_current_state(function(state)
		local text = compat.diff(util.join_lines(state.base_lines), util.join_lines(util.get_buf_lines(bufnr)), {
			algorithm = "histogram",
			result_type = "unified",
		})
		local lines = util.split_lines(text)
		if #lines == 0 then
			lines = { "No changes" }
		end

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "diff"

		local width = math.min(math.max(60, math.floor(vim.o.columns * 0.7)), vim.o.columns - 4)
		local height = math.min(math.max(10, #lines), vim.o.lines - 6)
		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.max(1, math.floor((vim.o.lines - height) / 2)),
			col = math.max(1, math.floor((vim.o.columns - width) / 2)),
			style = "minimal",
			border = "rounded",
			title = " LazyVCS Diff ",
		})
		local function close_preview()
			if util.win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		compat.keymap_set("n", "q", close_preview, { buffer = buf, silent = true, nowait = true })
		compat.keymap_set("n", "<Esc>", close_preview, { buffer = buf, silent = true, nowait = true })
	end)
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

	-- Highlight groups must be re-registered even when signs are disabled, since
	-- blame uses them too. `:colorscheme` wipes `default = true` links, so without
	-- this every lazyvcs highlight silently falls back to Normal after a theme
	-- switch.
	local hl_group = vim.api.nvim_create_augroup("lazyvcs_highlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = hl_group,
		callback = setup_highlights,
	})

	if not opts().enabled then
		return
	end

	augroup = vim.api.nvim_create_augroup("lazyvcs_signs", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = augroup,
		callback = function(args)
			M.refresh(args.buf, true)
		end,
	})
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function(args)
			-- Without `reload_base = true` this reuses the cached base. Passing it
			-- here bypassed the `state.loaded` short-circuit and spawned (then
			-- killed) a `git show :file` / `svn cat` on every single window or
			-- buffer switch -- `<C-w>w`, `:bnext`, the tabline picker.
			M.refresh(args.buf, false)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		callback = function(args)
			M.refresh(args.buf, true)
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		callback = function(args)
			if buffers[args.buf] then
				schedule(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = augroup,
		callback = function(args)
			clear(args.buf)
		end,
	})

	if vim.api.nvim_get_current_buf() ~= 0 then
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
