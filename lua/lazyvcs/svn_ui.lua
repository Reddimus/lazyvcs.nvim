local config = require("lazyvcs.config")
local picker = require("lazyvcs.picker")
local signs = require("lazyvcs.signs")
local store = require("lazyvcs.store")
local svn = require("lazyvcs.backends.svn")
local util = require("lazyvcs.util")

local M = {}

local ns_id = vim.api.nvim_create_namespace("lazyvcs_svn_blame_inline")
local augroup
local blame_views = {}
local inline_views = {}

-- Inline blame is a single global preference: when enabled it follows the cursor
-- in every supported (SVN) buffer. The flag is persisted so it is restored on the
-- next launch (see store.lua); per-buffer data lives in `inline_views`.
local inline_enabled = false
local STORE_KEY = "blame_inline_enabled"

local function capture_win_options(winid, names)
	local out = {}
	for _, name in ipairs(names) do
		local ok, value = pcall(function()
			return vim.wo[winid][name]
		end)
		if ok then
			out[name] = value
		end
	end
	return out
end

local function apply_win_options(winid, opts)
	for name, value in pairs(opts or {}) do
		pcall(function()
			vim.wo[winid][name] = value
		end)
	end
end

local function current_path()
	local bufnr = vim.api.nvim_get_current_buf()
	if util.is_real_file_buffer(bufnr) then
		return util.buf_path(bufnr), bufnr
	end
	return vim.fn.getcwd(), bufnr
end

local function close_blame(source_bufnr)
	local view = blame_views[source_bufnr]
	if not view then
		return false
	end
	if view.handle then
		pcall(view.handle.kill, view.handle, 15)
	end
	if view.source_options and util.win_is_valid(view.source_winid) then
		apply_win_options(view.source_winid, view.source_options)
	end
	if util.win_is_valid(view.winid) then
		pcall(vim.api.nvim_win_close, view.winid, true)
	end
	if view.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
	end
	blame_views[source_bufnr] = nil
	return true
end

local function clear_inline(bufnr)
	local view = inline_views[bufnr]
	if view and view.timer then
		view.timer:stop()
		view.timer:close()
	end
	if view and view.loading_timer then
		view.loading_timer:stop()
		view.loading_timer:close()
	end
	if view and view.handle then
		pcall(view.handle.kill, view.handle, 15)
	end
	if util.buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	end
	inline_views[bufnr] = nil
end

local function highlight_blame(bufnr, lines)
	for idx, line in ipairs(lines) do
		local revision = line:match("^%s*(%S+)")
		if revision then
			vim.api.nvim_buf_add_highlight(bufnr, -1, "LazyVcsBlameRevision", idx - 1, 0, #revision + 1)
		end
		local author_start, author_end = line:find("%S+", 8)
		if author_start and author_end then
			vim.api.nvim_buf_add_highlight(bufnr, -1, "LazyVcsBlameAuthor", idx - 1, author_start - 1, author_end)
		end
	end
end

local function supported_blame_buffer(bufnr)
	if vim.fn.executable("svn") ~= 1 or not util.is_real_file_buffer(bufnr) then
		return nil
	end
	local path = util.buf_path(bufnr)
	if not path or util.file_size(path) > config.get().signs.max_file_bytes then
		return nil
	end
	if #vim.fs.find(".svn", { path = vim.fs.dirname(path), upward = true, type = "directory" }) == 0 then
		return nil
	end
	return path
end

local function set_inline_text(bufnr, line, text)
	if not text or text == "" then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line - 1, 0, {
		virt_text = { { "  " .. text, "LazyVcsBlame" } },
		virt_text_pos = "eol",
		hl_mode = "combine",
		priority = 5,
	})
end

local function current_visible_line(bufnr)
	local win = vim.fn.bufwinid(bufnr)
	if not util.win_is_valid(win) then
		return nil
	end
	return vim.api.nvim_win_get_cursor(win)[1]
end

local function format_inline_blame(entry)
	local blame_opts = config.get().blame
	if entry.uncommitted then
		return util.truncate(blame_opts.uncommitted_text, blame_opts.max_width)
	end
	local text = blame_opts.format:gsub("{(%w+)}", function(key)
		return tostring(entry[key] or "")
	end)
	return util.truncate(text, blame_opts.max_width)
end

local function render_loading_inline(bufnr)
	local view = inline_views[bufnr]
	if not view or not view.enabled or not util.buf_is_valid(bufnr) then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	local line = current_visible_line(bufnr)
	if not line then
		return
	end
	view.last_line = line
	set_inline_text(bufnr, line, util.truncate(config.get().blame.loading_text, config.get().blame.max_width))
end

local function render_inline(bufnr)
	local view = inline_views[bufnr]
	if not view or not view.enabled or not util.buf_is_valid(bufnr) then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	if not view.entries then
		return
	end

	local line = current_visible_line(bufnr)
	if not line then
		return
	end
	view.last_line = line
	local entry = view.entries[line]
	if not entry then
		return
	end
	local text = format_inline_blame(entry)
	if text == "" then
		return
	end
	set_inline_text(bufnr, line, text)
end

local function load_inline(bufnr, path)
	local view = inline_views[bufnr]
	if not view or view.loading then
		return
	end

	view.loading = true
	view.loading_visible = false
	view.generation = (view.generation or 0) + 1
	local generation = view.generation
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	view.loading_timer = vim.defer_fn(function()
		local live = inline_views[bufnr]
		if not live or live.generation ~= generation or not live.loading then
			return
		end
		live.loading_timer = nil
		live.loading_visible = true
		render_loading_inline(bufnr)
	end, config.get().blame.loading_delay_ms)
	view.handle = svn.blame_lines_async(path, function(lines, err)
		local live = inline_views[bufnr]
		if not live or live.generation ~= generation or not util.buf_is_valid(bufnr) then
			return
		end
		if live.loading_timer then
			live.loading_timer:stop()
			live.loading_timer:close()
			live.loading_timer = nil
		end
		live.loading = false
		live.loading_visible = false
		live.handle = nil
		if not lines then
			live.entries = nil
			live.error = err or true
			pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
			if err then
				util.notify(err, vim.log.levels.DEBUG)
			end
			return
		end
		live.error = nil
		live.entries = svn.parse_blame_entries(lines)
		render_inline(bufnr)
	end)
end

local invalidate_inline

-- Drive the inline overlay for `bufnr` in response to cursor/buffer events. When
-- blame data is already cached we render immediately so the overlay tracks the
-- cursor with no perceptible lag; only the expensive `svn blame` fetch is
-- debounced (it runs at most once per buffer until the file changes).
local function update_inline(bufnr)
	if not inline_enabled then
		return
	end
	local path = supported_blame_buffer(bufnr)
	if not path then
		clear_inline(bufnr)
		return
	end

	local view = inline_views[bufnr]
	if not view then
		view = { enabled = true, path = path, generation = 0 }
		inline_views[bufnr] = view
	elseif view.path ~= path then
		-- The buffer now shows a different file; refetch blame from scratch.
		view.path = path
		invalidate_inline(bufnr)
		return
	end

	if view.entries then
		-- Cheap path: move the overlay now, skipping redundant redraws when the
		-- cursor stays on the same line (horizontal motion, insert-mode edits).
		local line = current_visible_line(bufnr)
		if line and line ~= view.last_line then
			render_inline(bufnr)
		end
		return
	end

	if view.error then
		return
	end

	if view.loading then
		-- A fetch is already in flight. Once the slow-load text is visible, keep
		-- it attached to the current cursor line instead of letting it lag.
		if view.loading_visible then
			local line = current_visible_line(bufnr)
			if line and line ~= view.last_line then
				render_loading_inline(bufnr)
			end
		end
		return
	end

	-- No data yet: debounce the blame fetch so rapid buffer switches don't spawn
	-- an `svn blame` process per event.
	if view.timer then
		view.timer:stop()
		view.timer:close()
		view.timer = nil
	end
	view.timer = vim.defer_fn(function()
		local live = inline_views[bufnr]
		if not live or not inline_enabled then
			return
		end
		live.timer = nil
		local current = supported_blame_buffer(bufnr)
		if not current then
			clear_inline(bufnr)
			return
		end
		if not live.entries and not live.loading then
			load_inline(bufnr, current)
		end
	end, config.get().blame.delay_ms)
end

function invalidate_inline(bufnr)
	local view = inline_views[bufnr]
	if not view then
		update_inline(bufnr)
		return
	end
	if view.handle then
		pcall(view.handle.kill, view.handle, 15)
		view.handle = nil
	end
	if view.loading_timer then
		view.loading_timer:stop()
		view.loading_timer:close()
		view.loading_timer = nil
	end
	if view.timer then
		view.timer:stop()
		view.timer:close()
		view.timer = nil
	end
	view.entries = nil
	view.last_line = nil
	view.error = nil
	view.loading = false
	view.loading_visible = false
	view.generation = (view.generation or 0) + 1
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	update_inline(bufnr)
end

local function clear_all_inline()
	for bufnr in pairs(inline_views) do
		clear_inline(bufnr)
	end
end

local function persist_enabled()
	if config.get().blame.persist then
		store.set(STORE_KEY, inline_enabled)
	end
end

local function set_inline_enabled(enabled)
	enabled = enabled and true or false
	if inline_enabled == enabled then
		return
	end
	inline_enabled = enabled
	persist_enabled()
	if inline_enabled then
		update_inline(vim.api.nvim_get_current_buf())
	else
		clear_all_inline()
	end
end

local function toggle_inline()
	-- Only reject an unsupported buffer when turning blame ON, so the user gets
	-- immediate feedback; turning it off (a global preference) always succeeds.
	if not inline_enabled and not supported_blame_buffer(vim.api.nvim_get_current_buf()) then
		util.notify("Current buffer is not an SVN file", vim.log.levels.WARN)
		return false
	end
	set_inline_enabled(not inline_enabled)
	return true
end

function M.blame()
	local mode = config.get().blame.mode
	if mode == "off" then
		M.blame_clear()
		return false
	end
	if mode == "split" then
		return M.blame_split()
	end
	return toggle_inline()
end

function M.blame_clear()
	set_inline_enabled(false)
	return true
end

function M.blame_split()
	local source_bufnr = vim.api.nvim_get_current_buf()
	if close_blame(source_bufnr) then
		return
	end

	local path = util.buf_path(source_bufnr)
	if not path then
		util.notify("Current buffer has no file path", vim.log.levels.WARN)
		return
	end

	local source_win = vim.api.nvim_get_current_win()
	local token = {}
	blame_views[source_bufnr] = {
		loading = true,
		token = token,
		handle = svn.blame_lines_async(path, function(raw, err)
			local pending = blame_views[source_bufnr]
			if not pending or pending.token ~= token then
				return
			end
			if not util.buf_is_valid(source_bufnr) or not util.win_is_valid(source_win) then
				close_blame(source_bufnr)
				return
			end
			if not raw then
				close_blame(source_bufnr)
				util.notify(err or "No SVN blame information available", vim.log.levels.WARN)
				return
			end

			local lines = svn.parse_blame_metadata(raw, config.get().blame.uncommitted_text)
			if #lines == 0 then
				close_blame(source_bufnr)
				util.notify("No SVN blame information available", vim.log.levels.WARN)
				return
			end

			local blame_opts = config.get().blame
			local width = 0
			for _, line in ipairs(lines) do
				width = math.max(width, vim.fn.strdisplaywidth(line))
			end
			local max_width =
				math.min(blame_opts.split_max_width, math.max(blame_opts.split_min_width, vim.o.columns - 10))
			width = math.min(math.max(width + 2, blame_opts.split_min_width), max_width)

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "lazyvcs://svn-blame/" .. source_bufnr)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "wipe"
			vim.bo[buf].swapfile = false
			vim.bo[buf].modifiable = false
			highlight_blame(buf, lines)

			vim.api.nvim_set_current_win(source_win)
			vim.cmd("leftabove " .. width .. "vnew")
			local win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
			vim.wo[win].number = false
			vim.wo[win].relativenumber = false
			vim.wo[win].signcolumn = "no"
			vim.wo[win].foldcolumn = "0"
			vim.wo[win].wrap = false
			vim.wo[win].linebreak = false
			vim.wo[win].list = false
			vim.wo[win].spell = false
			vim.wo[win].cursorline = false
			apply_win_options(win, {
				statuscolumn = "",
				scrollbind = true,
				cursorbind = true,
			})
			vim.wo[win].winfixwidth = true
			vim.wo[win].winhighlight = "Normal:LazyVcsBlame,NormalNC:LazyVcsBlame,EndOfBuffer:LazyVcsBlame"
			pcall(vim.api.nvim_win_set_width, win, width)
			local source_options = capture_win_options(source_win, { "scrollbind", "cursorbind" })
			apply_win_options(source_win, {
				scrollbind = true,
				cursorbind = true,
			})
			vim.api.nvim_set_current_win(source_win)

			local split_augroup = vim.api.nvim_create_augroup("lazyvcs_svn_blame_" .. source_bufnr, { clear = true })
			local syncing = false
			local function sync_cursor(from_win, to_win)
				if syncing or not util.win_is_valid(from_win) or not util.win_is_valid(to_win) then
					return
				end
				syncing = true
				local line = vim.api.nvim_win_get_cursor(from_win)[1]
				local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(to_win))
				pcall(vim.api.nvim_win_set_cursor, to_win, { math.min(line, max_line), 0 })
				syncing = false
			end

			vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
				group = split_augroup,
				buffer = source_bufnr,
				callback = function()
					sync_cursor(source_win, win)
				end,
			})
			vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
				group = split_augroup,
				buffer = buf,
				callback = function()
					sync_cursor(win, source_win)
				end,
			})
			vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
				group = split_augroup,
				callback = function()
					if
						not util.buf_is_valid(source_bufnr)
						or not util.win_is_valid(source_win)
						or not util.win_is_valid(win)
					then
						close_blame(source_bufnr)
					end
				end,
			})
			local close = function()
				close_blame(source_bufnr)
			end
			vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true, desc = "Close SVN blame" })
			vim.keymap.set(
				"n",
				"<Esc>",
				close,
				{ buffer = buf, silent = true, nowait = true, desc = "Close SVN blame" }
			)
			blame_views[source_bufnr] = {
				bufnr = buf,
				winid = win,
				source_winid = source_win,
				source_options = source_options,
				augroup = split_augroup,
			}
			sync_cursor(source_win, win)
		end),
	}
	return true
end

function M.line_log()
	local path = util.buf_path(0)
	if not path then
		util.notify("Current buffer has no file path", vim.log.levels.WARN)
		return
	end

	local revision, blame_err = svn.line_revision(path, vim.api.nvim_win_get_cursor(0)[1])
	if not revision then
		util.notify(blame_err or "No SVN blame information for this line", vim.log.levels.WARN)
		return
	end

	local lines, log_err = svn.revision_log(path, revision)
	if not lines then
		util.notify(log_err or ("No SVN log information for revision " .. revision), vim.log.levels.WARN)
		return
	end

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	width = math.min(math.max(width + 2, 40), vim.o.columns - 4)
	local height = math.min(math.max(#lines, 1), math.max(vim.o.lines - 6, 1))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "svn"

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " SVN r" .. revision .. " ",
	})
	local augroup = vim.api.nvim_create_augroup("lazyvcs_svn_line_log", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
		group = augroup,
		once = true,
		callback = function()
			if util.win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			pcall(vim.api.nvim_del_augroup_by_id, augroup)
		end,
	})
end

function M.files()
	local path = current_path()
	local root, root_err = svn.root(path)
	if not root then
		util.notify(root_err or "Not an SVN working copy", vim.log.levels.WARN)
		return
	end

	local items, err = svn.changed_files(root)
	if not items then
		util.notify(err or "Unable to list SVN files", vim.log.levels.ERROR)
		return
	end
	if #items == 0 then
		util.notify("No modified SVN files", vim.log.levels.INFO)
		return
	end

	picker.select(items, {
		prompt = "SVN files",
		format_item = function(item)
			return string.format("%s %s", item.status, item.path)
		end,
	}, function(item)
		if not item then
			return
		end
		vim.cmd.edit(vim.fn.fnameescape(item.absolute_path))
	end)
end

function M.preview_diff()
	return signs.preview_diff()
end

function M.revert_hunk()
	return signs.revert_hunk()
end

function M.revert_buffer()
	return signs.revert_buffer()
end

function M.refresh()
	invalidate_inline(vim.api.nvim_get_current_buf())
	return signs.refresh(vim.api.nvim_get_current_buf(), true)
end

function M.setup()
	if augroup then
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		augroup = nil
	end
	for bufnr in pairs(inline_views) do
		clear_inline(bufnr)
	end
	for bufnr in pairs(blame_views) do
		close_blame(bufnr)
	end

	-- Restore the persisted on/off preference (only meaningful for inline mode).
	local blame_opts = config.get().blame
	if blame_opts.persist and blame_opts.mode == "inline" then
		inline_enabled = store.get(STORE_KEY, false) and true or false
	else
		inline_enabled = false
	end

	augroup = vim.api.nvim_create_augroup("lazyvcs_svn_blame_inline", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter", "BufWinEnter" }, {
		group = augroup,
		callback = function(args)
			update_inline(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
		group = augroup,
		callback = function(args)
			if inline_enabled then
				invalidate_inline(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = augroup,
		callback = function(args)
			clear_inline(args.buf)
		end,
	})

	if inline_enabled then
		-- Show the overlay on the buffer already open at startup; other buffers
		-- pick it up through the autocmd as they are entered.
		local bufnr = vim.api.nvim_get_current_buf()
		vim.schedule(function()
			update_inline(bufnr)
		end)
	end
end

function M._test_blame_views()
	return blame_views
end

function M._test_inline_state()
	return {
		namespace = ns_id,
		views = inline_views,
	}
end

function M._test_inline_enabled()
	return inline_enabled
end

return M
