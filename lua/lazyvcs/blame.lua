local backends = require("lazyvcs.backends")
local context = require("lazyvcs.blame_context")
local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local store = require("lazyvcs.store")
local util = require("lazyvcs.util")

local M = {}

local ns_id = vim.api.nvim_create_namespace("lazyvcs_blame_inline")
local augroup
local blame_views = {}
local inline_views = {}
local line_log_views = {}
local inline_enabled = false
local STORE_KEY = "blame_inline_enabled"

local capture_win_options = util.capture_win_options
local apply_win_options = util.set_win_options

local function notify(message, level)
	util.notify(tostring(message):gsub("[\r\n]+", " "), level)
end

local function protect(callback, on_error)
	return function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			if on_error then
				pcall(on_error)
			end
			notify("Blame failed: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end
end

-- Use the shared cached resolver; cursor movement must not spawn repository probes.
local function backend_for_path(path)
	local backend = backends.resolve_cached(path)
	if backend and backend.blame_lines_async then
		return backend
	end
	return nil
end

local function supported_blame_buffer(bufnr)
	if not util.is_real_file_buffer(bufnr) then
		return nil
	end
	local path = util.buf_path(bufnr)
	if not path or math.max(util.file_size(path), util.buffer_size(bufnr)) > config.get().signs.max_file_bytes then
		return nil
	end
	local backend = backend_for_path(path)
	return path, backend
end

local function close_blame(source_bufnr, expected, deferred)
	local view = blame_views[source_bufnr]
	if not view or (expected and view ~= expected) then
		return false
	end
	blame_views[source_bufnr] = nil
	view.closed = true
	if view.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
	end
	if view.timer then
		view.timer:stop()
		view.timer:close()
		view.timer = nil
	end
	if view.handle then
		local handle = view.handle
		view.handle = nil
		pcall(handle.kill, handle, 15)
	end
	if view.source_options and util.win_is_valid(view.source_winid) then
		apply_win_options(view.source_winid, view.source_options)
	end
	local function dispose()
		if util.win_is_valid(view.winid) and vim.api.nvim_win_get_buf(view.winid) == view.bufnr then
			pcall(vim.api.nvim_win_close, view.winid, true)
		end
		if util.buf_is_valid(view.bufnr) then
			pcall(vim.api.nvim_buf_delete, view.bufnr, { force = true })
		end
	end
	if deferred then
		vim.schedule(protect(dispose))
	else
		dispose()
	end
	return true
end

local function close_line_log(source_bufnr, expected, deferred)
	local view = line_log_views[source_bufnr]
	if not view or (expected and view ~= expected) then
		return false
	end
	line_log_views[source_bufnr] = nil
	view.closing = true
	if view.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
	end
	if view.handle then
		local handle = view.handle
		view.handle = nil
		pcall(handle.kill, handle, 15)
	end
	local function dispose()
		if util.win_is_valid(view.winid) and vim.api.nvim_win_get_buf(view.winid) == view.bufnr then
			pcall(vim.api.nvim_win_close, view.winid, true)
		end
		if util.buf_is_valid(view.bufnr) and #vim.fn.win_findbuf(view.bufnr) == 0 then
			pcall(vim.api.nvim_buf_delete, view.bufnr, { force = true })
		end
	end
	if deferred then
		vim.schedule(protect(dispose))
	else
		dispose()
	end
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

-- Reuse one namespace across blame splits. Extmarks are buffer-local; namespaces cannot
-- be deleted.
local split_ns_id = vim.api.nvim_create_namespace("lazyvcs_blame_split")

local function highlight_blame(bufnr, lines)
	local highlight_ns = split_ns_id
	for idx, line in ipairs(lines) do
		local revision = line:match("^%s*(%S+)")
		if revision then
			vim.api.nvim_buf_set_extmark(bufnr, highlight_ns, idx - 1, 0, {
				end_col = #revision + 1,
				hl_group = "LazyVcsBlameRevision",
			})
		end
		local author_start, author_end = line:find("%S+", 10)
		if author_start and author_end then
			vim.api.nvim_buf_set_extmark(bufnr, highlight_ns, idx - 1, author_start - 1, {
				end_col = author_end,
				hl_group = "LazyVcsBlameAuthor",
			})
		end
	end
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
	local view = inline_views[bufnr]
	local win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(win) ~= bufnr then
		win = view and view.origin_win
		if not util.win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
			win = vim.fn.bufwinid(bufnr)
		end
	end
	if not util.win_is_valid(win) then
		return nil
	end
	return vim.api.nvim_win_get_cursor(win)[1]
end

local function format_inline_blame(entry)
	local blame_opts = config.get().blame
	if entry.uncommitted then
		return util.truncate_display(blame_opts.uncommitted_text, blame_opts.max_width)
	end
	-- Parenthesised: `gsub` returns (string, count) and this is a return value.
	local text = (
		blame_opts.format:gsub("{([%w_]+)}", function(key)
			if key == "revision_label" then
				return (entry.backend == "svn" and "r" or "") .. tostring(entry.revision or "")
			end
			return tostring(entry[key] or "")
		end)
	)
	-- `max_width` is a column budget, so measure cells rather than bytes: a CJK
	-- author name or an emoji in a commit subject otherwise produced virtual
	-- text about twice the configured width.
	return util.truncate_display(text, blame_opts.max_width)
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
	view.loading_visible = true
	set_inline_text(bufnr, line, util.truncate_display(config.get().blame.loading_text, config.get().blame.max_width))
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
	set_inline_text(bufnr, line, format_inline_blame(entry))
end

local function load_inline(bufnr, path, backend)
	local view = inline_views[bufnr]
	if not view or view.loading or not backend then
		return
	end

	view.loading = true
	view.loading_visible = false
	view.generation = (view.generation or 0) + 1
	local generation = view.generation
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
	local function failed()
		if inline_views[bufnr] ~= view then
			return
		end
		if view.loading_timer then
			view.loading_timer:stop()
			view.loading_timer:close()
			view.loading_timer = nil
		end
		if view.handle then
			pcall(view.handle.kill, view.handle, 15)
			view.handle = nil
		end
		view.loading = false
		view.loading_visible = false
		view.error = true
	end
	view.loading_timer = vim.defer_fn(
		protect(function()
			local live = inline_views[bufnr]
			if live ~= view or live.generation ~= generation or not live.loading then
				return
			end
			live.loading_timer = nil
			live.loading_visible = true
			render_loading_inline(bufnr)
		end, failed),
		config.get().blame.loading_delay_ms
	)
	protect(function()
		view.handle = backend.blame_lines_async(
			path,
			protect(function(lines, err)
				local live = inline_views[bufnr]
				if live ~= view or live.generation ~= generation or not util.buf_is_valid(bufnr) then
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
					live.error = (not err or not err:match("^Cancelled")) and (err or true) or nil
					pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
					if err and not err:match("^Cancelled") then
						notify(err, vim.log.levels.DEBUG)
					end
					return
				end
				live.error = nil
				live.entries = backend.parse_blame_entries(lines)
				render_inline(bufnr)
			end, failed),
			{
				contents = util.join_lines(util.get_buf_lines(bufnr)),
				fileformat = vim.bo[bufnr].fileformat,
				root = select(2, backends.resolve_cached(path)),
			}
		)
	end, failed)()
end

local invalidate_inline

local function update_inline(bufnr)
	if not inline_enabled then
		return
	end
	local path, backend = supported_blame_buffer(bufnr)
	if not path then
		clear_inline(bufnr)
		return
	end

	local view = inline_views[bufnr]
	if not view then
		view = { enabled = true, path = path, backend = backend, generation = 0 }
		inline_views[bufnr] = view
	elseif view.path ~= path or view.backend ~= backend then
		view.path = path
		view.backend = backend
		invalidate_inline(bufnr)
		return
	end

	local current_win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(current_win) == bufnr then
		view.origin_win = current_win
	end
	if not backend then
		if view.resolving then
			return
		end
		view.resolving = true
		view.generation = (view.generation or 0) + 1
		local generation = view.generation
		protect(function()
			view.handle = backends.resolve_async(
				path,
				protect(function(resolved, _, err)
					local live = inline_views[bufnr]
					if live ~= view or live.generation ~= generation or not util.buf_is_valid(bufnr) then
						return
					end
					live.handle = nil
					live.resolving = false
					if not resolved or not resolved.blame_lines_async then
						live.error = err or "Blame is not supported for this buffer"
						return
					end
					live.backend = resolved
					load_inline(bufnr, path, resolved)
				end, function()
					clear_inline(bufnr)
				end)
			)
		end, function()
			clear_inline(bufnr)
		end)()
		return
	end

	if view.entries then
		render_inline(bufnr)
		return
	end

	if view.error then
		return
	end

	if view.loading then
		if view.loading_visible then
			render_loading_inline(bufnr)
		end
		return
	end

	if view.timer then
		view.timer:stop()
		view.timer:close()
		view.timer = nil
	end
	view.timer = vim.defer_fn(
		protect(function()
			local live = inline_views[bufnr]
			if live ~= view or not inline_enabled then
				return
			end
			live.timer = nil
			local current_path, current_backend = supported_blame_buffer(bufnr)
			if not current_path then
				clear_inline(bufnr)
				return
			end
			if not current_backend or current_path ~= path then
				update_inline(bufnr)
				return
			end
			if not live.entries and not live.loading then
				load_inline(bufnr, current_path, current_backend)
			end
		end, function()
			clear_inline(bufnr)
		end),
		config.get().blame.delay_ms
	)
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
	view.resolving = false
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
	if not inline_enabled and not supported_blame_buffer(vim.api.nvim_get_current_buf()) then
		notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
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

local function source_present(bufnr, winid)
	return util.buf_is_valid(bufnr)
		and vim.api.nvim_buf_is_loaded(bufnr)
		and util.win_is_valid(winid)
		and vim.api.nvim_win_get_buf(winid) == bufnr
end

local function observe_source(view, bufnr, close, changed)
	vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
		group = view.augroup,
		buffer = bufnr,
		callback = protect(function()
			close(true)
		end),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = view.augroup,
		pattern = tostring(view.source_winid),
		callback = protect(function()
			close(true)
		end),
	})
	local check = protect(function()
		if not source_present(bufnr, view.source_winid) then
			close()
		end
	end, close)
	vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWinEnter", "BufEnter" }, {
		group = view.augroup,
		callback = protect(function()
			vim.schedule(check)
		end, close),
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "BufReadPost", "BufFilePost" }, {
		group = view.augroup,
		buffer = bufnr,
		callback = protect(changed, close),
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = view.augroup,
		pattern = "fileformat",
		callback = protect(function()
			if vim.api.nvim_get_current_buf() == bufnr then
				changed()
			end
		end, close),
	})
end

function M.blame_split()
	local source_bufnr, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	if close_blame(source_bufnr) then
		return true
	end
	local path = supported_blame_buffer(source_bufnr)
	if not path then
		notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
		return false
	end
	local view = { source_winid = source_win, generation = 0, loading = true }
	blame_views[source_bufnr] = view
	local function close(deferred)
		close_blame(source_bufnr, view, deferred)
	end
	local safe = function(fn)
		return protect(fn, close)
	end
	view.augroup = vim.api.nvim_create_augroup("lazyvcs_blame_" .. source_bufnr, { clear = true })
	local reload
	local function debounce()
		if blame_views[source_bufnr] ~= view then
			return
		end
		view.generation = view.generation + 1
		if view.handle then
			local handle = view.handle
			view.handle = nil
			pcall(handle.kill, handle, 15)
		end
		if view.timer then
			view.timer:stop()
			view.timer:close()
		end
		view.timer = vim.defer_fn(
			safe(function()
				view.timer = nil
				reload()
			end),
			config.get().blame.delay_ms
		)
	end
	observe_source(view, source_bufnr, close, debounce)
	local syncing = false
	local sync_cursor = safe(function(from, to)
		if
			syncing
			or blame_views[source_bufnr] ~= view
			or not source_present(source_bufnr, source_win)
			or not util.win_is_valid(view.winid)
			or vim.api.nvim_win_get_buf(view.winid) ~= view.bufnr
		then
			return
		end
		syncing = true
		local line = vim.api.nvim_win_get_cursor(from)[1]
		local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(to))
		pcall(vim.api.nvim_win_set_cursor, to, { math.min(line, max_line), 0 })
		syncing = false
	end)
	local function render(lines)
		if view.winid then
			local saved = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
			vim.bo[view.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
			vim.bo[view.bufnr].modifiable = false
			vim.api.nvim_buf_clear_namespace(view.bufnr, split_ns_id, 0, -1)
			highlight_blame(view.bufnr, lines)
			vim.api.nvim_win_call(view.winid, function()
				vim.fn.winrestview(saved)
			end)
			-- The source may have grown or shrunk while the reload ran. Align only the
			-- blame window; :syncbind would also move the source and other bound panes.
			local source_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
			vim.api.nvim_win_call(view.winid, function()
				vim.fn.winrestview({
					lnum = math.min(source_view.lnum, #lines),
					col = 0,
					topline = math.min(source_view.topline, #lines),
				})
			end)
			return
		end
		view.bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(view.bufnr, "lazyvcs://blame/" .. source_bufnr)
		vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
		vim.bo[view.bufnr].buftype = "nofile"
		vim.bo[view.bufnr].bufhidden = "wipe"
		vim.bo[view.bufnr].swapfile = false
		vim.bo[view.bufnr].modifiable = false
		highlight_blame(view.bufnr, lines)
		local blame_opts, width = config.get().blame, 0
		for _, line in ipairs(lines) do
			width = math.max(width, vim.fn.strdisplaywidth(line))
		end
		local max_width = math.min(blame_opts.split_max_width, math.max(blame_opts.split_min_width, vim.o.columns - 10))
		width = math.min(math.max(width + 2, blame_opts.split_min_width), max_width)
		local callback_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_call(source_win, function()
			vim.cmd("leftabove " .. width .. "vsplit")
			view.winid = vim.api.nvim_get_current_win()
		end)
		util.show_win_buffer(view.winid, view.bufnr)
		util.unbind_window(view.winid)
		util.set_win_option(view.winid, "number", false)
		util.set_win_option(view.winid, "relativenumber", false)
		util.set_win_option(view.winid, "signcolumn", "no")
		util.set_win_option(view.winid, "foldcolumn", "0")
		util.set_win_option(view.winid, "wrap", false)
		util.set_win_option(view.winid, "linebreak", false)
		util.set_win_option(view.winid, "list", false)
		util.set_win_option(view.winid, "spell", false)
		util.set_win_option(view.winid, "cursorline", false)
		apply_win_options(view.winid, {
			statuscolumn = "",
			scrollbind = true,
			cursorbind = true,
		})
		util.set_win_option(view.winid, "winfixwidth", true)
		util.set_win_option(
			view.winid,
			"winhighlight",
			"Normal:LazyVcsBlame,NormalNC:LazyVcsBlame,EndOfBuffer:LazyVcsBlame"
		)
		pcall(vim.api.nvim_win_set_width, view.winid, width)
		view.source_options = capture_win_options(source_win, { "scrollbind", "cursorbind" })
		apply_win_options(source_win, { scrollbind = true, cursorbind = true })

		if util.win_is_valid(callback_win) then
			vim.api.nvim_set_current_win(callback_win)
		end
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = view.augroup,
			buffer = source_bufnr,
			callback = safe(function()
				sync_cursor(source_win, view.winid)
			end),
		})
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = view.augroup,
			buffer = view.bufnr,
			callback = safe(function()
				sync_cursor(view.winid, source_win)
			end),
		})
		vim.api.nvim_create_autocmd("WinClosed", {
			group = view.augroup,
			pattern = tostring(view.winid),
			callback = safe(function()
				close(true)
			end),
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = view.augroup,
			buffer = view.bufnr,
			callback = safe(function()
				close(true)
			end),
		})
		for _, key in ipairs({ "q", "<Esc>" }) do
			compat.keymap_set(
				"n",
				key,
				safe(function()
					close()
				end),
				{ buffer = view.bufnr, silent = true, nowait = true, desc = "Close VCS blame" }
			)
		end
		sync_cursor(source_win, view.winid)
	end
	reload = safe(function()
		if blame_views[source_bufnr] ~= view then
			return
		end
		local captured = context.capture(source_bufnr, source_win)
		if not captured then
			return close()
		end
		local contents, capture_err = context.contents(captured, config.get().signs.max_file_bytes)
		if not contents then
			close()
			notify(capture_err, vim.log.levels.WARN)
			return
		end
		view.generation = view.generation + 1
		local generation = view.generation
		local function valid()
			if blame_views[source_bufnr] ~= view or generation ~= view.generation then
				return false
			end
			if not source_present(source_bufnr, source_win) then
				close()
				return false
			end
			return context.valid(captured, true)
		end
		local function resolved(backend, root, err)
			if not valid() then
				return
			end
			view.handle = nil
			if not backend or not backend.blame_lines_async then
				close()
				notify(err or "Blame is not supported for this buffer", vim.log.levels.WARN)
				return
			end
			view.handle = backend.blame_lines_async(
				captured.name,
				safe(function(raw, blame_err)
					if not valid() then
						return
					end
					view.handle = nil
					view.loading = false
					if not raw then
						close()
						notify(blame_err or "No blame information available", vim.log.levels.WARN)
						return
					end
					local lines = backend.parse_blame_metadata(raw, config.get().blame.uncommitted_text)
					if #lines == 0 then
						close()
						notify("No blame information available", vim.log.levels.WARN)
						return
					end
					render(lines)
					if not valid() then
						debounce()
					end
				end),
				{ contents = contents, fileformat = captured.fileformat, root = root }
			)
		end
		local backend, root = backends.resolve_cached(captured.name)
		if backend then
			resolved(backend, root)
		else
			view.handle = backends.resolve_async(captured.name, safe(resolved))
		end
	end)
	reload()
	return true
end

function M.line_log()
	local source_bufnr, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	close_line_log(source_bufnr)
	local path, cached_backend = supported_blame_buffer(source_bufnr)
	local captured = context.capture(source_bufnr, source_win)
	if not path or not captured then
		notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
		return false
	end
	local contents, capture_err = context.contents(captured, config.get().signs.max_file_bytes)
	if not contents then
		notify(capture_err, vim.log.levels.WARN)
		return false
	end
	local line_number = vim.api.nvim_win_get_cursor(source_win)[1]
	local view = { source_winid = source_win, loading = true }
	line_log_views[source_bufnr] = view
	local function close(deferred)
		close_line_log(source_bufnr, view, deferred)
	end
	local function safe(fn)
		return protect(fn, close)
	end
	view.augroup = vim.api.nvim_create_augroup("lazyvcs_line_log_" .. source_bufnr, { clear = true })
	observe_source(view, source_bufnr, close, function()
		close()
	end)
	local function valid()
		if line_log_views[source_bufnr] ~= view then
			return false
		end
		if not context.valid(captured, true) then
			close()
			return false
		end
		return true
	end
	local function fail(message)
		if not valid() then
			return
		end
		close()
		notify(message, vim.log.levels.WARN)
	end
	local function open_popup(backend, revision, lines)
		if not valid() then
			return
		end
		local width = 0
		for _, line in ipairs(lines) do
			width = math.max(width, vim.fn.strdisplaywidth(line))
		end
		width = math.min(math.max(width + 2, 40), vim.o.columns - 4)
		local height = math.min(math.max(#lines, 1), math.max(vim.o.lines - 6, 1))
		local buf = vim.api.nvim_create_buf(false, true)
		view.bufnr = buf
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = backend.name == "git" and "git" or "svn"

		local win
		vim.api.nvim_win_call(source_win, function()
			win = vim.api.nvim_open_win(buf, false, {
				relative = "cursor",
				row = 1,
				col = 0,
				width = width,
				height = height,
				style = "minimal",
				border = "rounded",
				title = " " .. backend.name:upper() .. " " .. revision .. " ",
			})
		end)
		view.winid = win
		util.unbind_window(win)
		view.loading = false
		view.handle = nil
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = view.augroup,
			buffer = source_bufnr,
			once = true,
			callback = safe(function()
				close()
			end),
		})
		vim.api.nvim_create_autocmd("WinClosed", {
			group = view.augroup,
			pattern = tostring(win),
			callback = safe(function()
				close(true)
			end),
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = view.augroup,
			buffer = buf,
			callback = safe(function()
				close(true)
			end),
		})
		for _, key in ipairs({ "q", "<Esc>" }) do
			compat.keymap_set(
				"n",
				key,
				safe(function()
					close()
				end),
				{ buffer = buf, silent = true, nowait = true, desc = "Close VCS log" }
			)
		end
	end
	local resolved = safe(function(backend, root, resolve_err)
		if not valid() then
			return
		end
		view.handle = nil
		if not backend or not backend.line_revision_async or not backend.revision_log_async then
			return fail(resolve_err or "Line history is not supported for this buffer")
		end
		view.handle = backend.line_revision_async(
			path,
			line_number,
			safe(function(revision, blame_err)
				if not valid() then
					return
				end
				view.handle = nil
				if not revision then
					return fail(blame_err or "No blame information for this line")
				end
				view.handle = backend.revision_log_async(
					path,
					revision,
					safe(function(lines, log_err)
						if not valid() then
							return
						end
						view.handle = nil
						if not lines then
							return fail(log_err or ("No log information for revision " .. revision))
						end
						open_popup(backend, revision, lines)
					end),
					{ root = root }
				)
			end),
			{ contents = contents, fileformat = captured.fileformat, root = root }
		)
	end)
	safe(function()
		if cached_backend then
			resolved(cached_backend, select(2, backends.resolve_cached(path)))
		else
			view.handle = backends.resolve_async(path, resolved)
		end
	end)()
	return true
end

function M.refresh(bufnr)
	invalidate_inline(bufnr or vim.api.nvim_get_current_buf())
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
	for bufnr in pairs(line_log_views) do
		close_line_log(bufnr)
	end

	local blame_opts = config.get().blame
	if blame_opts.persist and blame_opts.mode == "inline" then
		inline_enabled = store.get(STORE_KEY, false) and true or false
	else
		inline_enabled = false
	end

	augroup = vim.api.nvim_create_augroup("lazyvcs_blame_inline", { clear = true })
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter", "BufWinEnter" }, {
		group = augroup,
		callback = protect(function(args)
			update_inline(args.buf)
		end),
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "BufFilePost" }, {
		group = augroup,
		callback = protect(function(args)
			if inline_enabled then
				invalidate_inline(args.buf)
			end
		end),
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = augroup,
		pattern = "fileformat",
		callback = protect(function()
			if inline_enabled and inline_views[vim.api.nvim_get_current_buf()] then
				invalidate_inline(vim.api.nvim_get_current_buf())
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = augroup,
		callback = protect(function(args)
			clear_inline(args.buf)
		end),
	})

	if inline_enabled then
		local bufnr = vim.api.nvim_get_current_buf()
		vim.schedule(protect(function()
			update_inline(bufnr)
		end))
	end
end

function M._test_blame_views()
	return blame_views
end

function M._test_line_log_views()
	return line_log_views
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
