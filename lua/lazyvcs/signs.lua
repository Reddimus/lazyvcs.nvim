local backends = require("lazyvcs.backends")
local config = require("lazyvcs.config")
local diff = require("lazyvcs.diff")
local util = require("lazyvcs.util")

local M = {}

local ns_id = vim.api.nvim_create_namespace("lazyvcs_signs")
local augroup
local buffers = {}
local timers = {}

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
	if util.buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	end
	buffers[bufnr] = nil
	if timers[bufnr] then
		timers[bufnr]:stop()
		timers[bufnr]:close()
		timers[bufnr] = nil
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

	-- Backend resolution is cached per directory, so this is a table lookup once a
	-- directory has been seen.
	--
	-- Deliberately no is_versioned() check: it spawns `git ls-files` / `svn info`
	-- synchronously, and this runs on every BufEnter, BufReadPost and TextChanged.
	-- load_base_async already reports trackedness, and M.refresh clears the buffer
	-- when the backend reports no base, so the check was redundant as well as
	-- blocking.
	local backend_name = backends.name_for(path)
	if not backend_name or defers_to_gitsigns(backend_name) then
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
	if state then
		return state
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

function M.refresh(bufnr, reload_base)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	local path = supported_buffer(bufnr)
	if not path then
		clear(bufnr)
		return
	end

	local state = ensure_state(bufnr, path)
	if not reload_base and state.loaded then
		render(bufnr)
		return
	end

	state.generation = state.generation + 1
	local generation = state.generation
	state.loading = true
	backends.load_base_async(path, function(result, err)
		local live = buffers[bufnr]
		if not live or live.generation ~= generation or not util.buf_is_valid(bufnr) then
			return
		end
		live.loading = false
		if not result then
			clear(bufnr)
			if err and err:match("tracked") == nil then
				util.notify(err, vim.log.levels.DEBUG)
			end
			return
		end
		live.root = result.root
		live.relpath = result.relpath
		live.base_label = result.base_label
		live.base_lines = result.base_lines
		live.loaded = true
		render(bufnr)
	end)
end

function M.refresh_sync(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	local path = supported_buffer(bufnr)
	if not path then
		clear(bufnr)
		return nil
	end
	local result, err = backends.load_base(path)
	if not result then
		clear(bufnr)
		return nil, err
	end
	local state = ensure_state(bufnr, path)
	state.generation = state.generation + 1
	state.root = result.root
	state.relpath = result.relpath
	state.base_label = result.base_label
	state.base_lines = result.base_lines
	state.loaded = true
	state.loading = false
	render(bufnr)
	return state
end

local function schedule(bufnr)
	if timers[bufnr] then
		timers[bufnr]:stop()
	end
	timers[bufnr] = vim.defer_fn(function()
		timers[bufnr] = nil
		M.refresh(bufnr, false)
	end, opts().debounce_ms)
end

local function current_state_or_load()
	local bufnr = vim.api.nvim_get_current_buf()
	local state = buffers[bufnr]
	if state and state.loaded then
		render(bufnr)
		return state
	end
	return M.refresh_sync(bufnr)
end

function M.current_state(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	return buffers[bufnr]
end

function M.revert_hunk()
	local state, err = current_state_or_load()
	if not state then
		util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
		return false
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local hunk = diff.find_current_hunk(state.hunks or {}, line)
	if not hunk then
		util.notify("No modified hunk at the cursor", vim.log.levels.WARN)
		return false
	end
	diff.reset_hunk(bufnr, state.base_lines, hunk)
	schedule(bufnr)
	return true
end

function M.jump_to_hunk(direction)
	local state, err = current_state_or_load()
	if not state then
		util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
		return false
	end
	local hunks = state.hunks or {}
	if #hunks == 0 then
		util.notify("No hunks in the current buffer", vim.log.levels.INFO)
		return false
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	diff.focus_hunk(0, vim.api.nvim_get_current_buf(), diff.find_neighbor_hunk(hunks, line, direction))
	return true
end

function M.preview_diff()
	local state, err = current_state_or_load()
	if not state then
		util.notify(err or "No VCS signs state for the current buffer", vim.log.levels.WARN)
		return false
	end

	local text = vim.diff(util.join_lines(state.base_lines), util.join_lines(util.get_buf_lines(0)), {
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
	vim.keymap.set("n", "q", function()
		if util.win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "<Esc>", function()
		if util.win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, silent = true, nowait = true })
	return true
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
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
		group = augroup,
		callback = function(args)
			M.refresh(args.buf, true)
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
