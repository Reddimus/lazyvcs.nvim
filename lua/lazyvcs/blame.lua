local backends = require("lazyvcs.backends")
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

-- Resolve through the shared dispatcher, which caches the probe per directory.
-- This used to re-implement probing locally, so it spawned `git rev-parse` (and
-- `svn info`) on every CursorMoved/CursorMovedI -- two blocking subprocesses per
-- cursor movement while inline blame was on.
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
	if not path or util.file_size(path) > config.get().signs.max_file_bytes then
		return nil
	end
	local backend = backend_for_path(path)
	return path, backend
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

local function close_line_log(source_bufnr)
	local view = line_log_views[source_bufnr]
	if not view or view.closing then
		return false
	end
	view.closing = true
	if view.handle and type(view.handle.kill) == "function" then
		pcall(view.handle.kill, view.handle, 15)
	end
	if view.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, view.augroup)
	end
	if util.win_is_valid(view.winid) then
		pcall(vim.api.nvim_win_close, view.winid, true)
	end
	if util.buf_is_valid(view.bufnr) and #vim.fn.win_findbuf(view.bufnr) == 0 then
		pcall(vim.api.nvim_buf_delete, view.bufnr, { force = true })
	end
	line_log_views[source_bufnr] = nil
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

-- One namespace for every blame split, not one per buffer. Namespaces have no
-- deletion API, so keying the name on `bufnr` leaked a new one for every split
-- ever opened in a session. Extmarks are already buffer-scoped, so a shared
-- namespace is sufficient to isolate and clear them.
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
	local win = vim.fn.bufwinid(bufnr)
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
	local text = (blame_opts.format:gsub("{(%w+)}", function(key)
		return tostring(entry[key] or "")
	end))
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
	view.handle = backend.blame_lines_async(path, function(lines, err)
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
		live.entries = backend.parse_blame_entries(lines)
		render_inline(bufnr)
	end, { contents = util.join_lines(util.get_buf_lines(bufnr)) })
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

	if not backend then
		if view.resolving then
			return
		end
		view.resolving = true
		view.generation = (view.generation or 0) + 1
		local generation = view.generation
		view.handle = backends.resolve_async(path, function(resolved, _, err)
			local live = inline_views[bufnr]
			if not live or live.generation ~= generation or not util.buf_is_valid(bufnr) then
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
		end)
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
	view.timer = vim.defer_fn(function()
		local live = inline_views[bufnr]
		if not live or not inline_enabled then
			return
		end
		live.timer = nil
		local current_path, current_backend = supported_blame_buffer(bufnr)
		if not current_path then
			clear_inline(bufnr)
			return
		end
		if not live.entries and not live.loading then
			load_inline(bufnr, current_path, current_backend)
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
	if not inline_enabled and not supported_blame_buffer(vim.api.nvim_get_current_buf()) then
		util.notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
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

function M.blame_split(resolved)
	local source_bufnr = resolved and resolved.source_bufnr or vim.api.nvim_get_current_buf()
	if not resolved and close_blame(source_bufnr) then
		return true
	end

	local path, backend
	if resolved then
		path, backend = resolved.path, resolved.backend
	else
		path, backend = supported_blame_buffer(source_bufnr)
	end
	if not path then
		util.notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
		return
	end
	local source_win = resolved and resolved.source_win or vim.api.nvim_get_current_win()
	if not backend then
		local token = {}
		local pending = { loading = true, token = token }
		blame_views[source_bufnr] = pending
		pending.handle = backends.resolve_async(path, function(found, _, err)
			local live = blame_views[source_bufnr]
			if live ~= pending or live.token ~= token then
				return
			end
			blame_views[source_bufnr] = nil
			if
				not found
				or not found.blame_lines_async
				or not util.win_is_valid(source_win)
				or vim.api.nvim_win_get_buf(source_win) ~= source_bufnr
			then
				util.notify(err or "Current buffer is not a Git or SVN file", vim.log.levels.WARN)
				return
			end
			M.blame_split({
				source_bufnr = source_bufnr,
				source_win = source_win,
				path = path,
				backend = found,
			})
		end)
		return true
	end
	local token = {}
	local view = {
		loading = true,
		token = token,
	}
	blame_views[source_bufnr] = view
	view.handle = backend.blame_lines_async(path, function(raw, err)
		local pending = blame_views[source_bufnr]
		if not pending or pending.token ~= token then
			return
		end
		pending.handle = nil
		if
			not util.buf_is_valid(source_bufnr)
			or not util.win_is_valid(source_win)
			or vim.api.nvim_win_get_buf(source_win) ~= source_bufnr
		then
			close_blame(source_bufnr)
			return
		end
		if not raw then
			close_blame(source_bufnr)
			util.notify(err or "No blame information available", vim.log.levels.WARN)
			return
		end

		local lines = backend.parse_blame_metadata(raw, config.get().blame.uncommitted_text)
		if #lines == 0 then
			close_blame(source_bufnr)
			util.notify("No blame information available", vim.log.levels.WARN)
			return
		end

		local callback_win = vim.api.nvim_get_current_win()
		local created_buf
		local created_win
		local source_options
		-- Hoisted alongside `created_buf`/`created_win` so the failure cleanup
		-- below can actually delete it. Declared inside the xpcall body, the
		-- group survived a mid-construction error and its CursorMoved
		-- autocommands kept firing against a window that no longer existed.
		local split_augroup
		local ok, build_err = xpcall(function()
			local blame_opts = config.get().blame
			local width = 0
			for _, line in ipairs(lines) do
				width = math.max(width, vim.fn.strdisplaywidth(line))
			end
			local max_width =
				math.min(blame_opts.split_max_width, math.max(blame_opts.split_min_width, vim.o.columns - 10))
			width = math.min(math.max(width + 2, blame_opts.split_min_width), max_width)

			created_buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(created_buf, "lazyvcs://blame/" .. source_bufnr)
			vim.api.nvim_buf_set_lines(created_buf, 0, -1, false, lines)
			vim.bo[created_buf].buftype = "nofile"
			vim.bo[created_buf].bufhidden = "wipe"
			vim.bo[created_buf].swapfile = false
			vim.bo[created_buf].modifiable = false
			highlight_blame(created_buf, lines)

			vim.api.nvim_win_call(source_win, function()
				vim.cmd("leftabove " .. width .. "vnew")
				created_win = vim.api.nvim_get_current_win()
			end)
			vim.api.nvim_win_set_buf(created_win, created_buf)
			vim.wo[created_win].number = false
			vim.wo[created_win].relativenumber = false
			vim.wo[created_win].signcolumn = "no"
			vim.wo[created_win].foldcolumn = "0"
			vim.wo[created_win].wrap = false
			vim.wo[created_win].linebreak = false
			vim.wo[created_win].list = false
			vim.wo[created_win].spell = false
			vim.wo[created_win].cursorline = false
			apply_win_options(created_win, {
				statuscolumn = "",
				scrollbind = true,
				cursorbind = true,
			})
			vim.wo[created_win].winfixwidth = true
			vim.wo[created_win].winhighlight = "Normal:LazyVcsBlame,NormalNC:LazyVcsBlame,EndOfBuffer:LazyVcsBlame"
			pcall(vim.api.nvim_win_set_width, created_win, width)
			source_options = capture_win_options(source_win, { "scrollbind", "cursorbind" })
			apply_win_options(source_win, { scrollbind = true, cursorbind = true })

			split_augroup = vim.api.nvim_create_augroup(
				"lazyvcs_blame_" .. source_bufnr .. "_" .. tostring(vim.uv.hrtime()),
				{ clear = true }
			)
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
					sync_cursor(source_win, created_win)
				end,
			})
			vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
				group = split_augroup,
				buffer = created_buf,
				callback = function()
					sync_cursor(created_win, source_win)
				end,
			})
			local function schedule_close()
				vim.schedule(function()
					close_blame(source_bufnr)
				end)
			end
			vim.api.nvim_create_autocmd("WinClosed", {
				group = split_augroup,
				pattern = { tostring(source_win), tostring(created_win) },
				callback = schedule_close,
			})
			vim.api.nvim_create_autocmd("BufWipeout", {
				group = split_augroup,
				buffer = source_bufnr,
				callback = schedule_close,
			})
			vim.api.nvim_create_autocmd("BufWipeout", {
				group = split_augroup,
				buffer = created_buf,
				callback = schedule_close,
			})
			local close = function()
				close_blame(source_bufnr)
			end
			compat.keymap_set(
				"n",
				"q",
				close,
				{ buffer = created_buf, silent = true, nowait = true, desc = "Close VCS blame" }
			)
			compat.keymap_set(
				"n",
				"<Esc>",
				close,
				{ buffer = created_buf, silent = true, nowait = true, desc = "Close VCS blame" }
			)
			blame_views[source_bufnr] = {
				bufnr = created_buf,
				winid = created_win,
				source_winid = source_win,
				source_options = source_options,
				augroup = split_augroup,
				token = token,
			}
			sync_cursor(source_win, created_win)
		end, debug.traceback)

		if util.win_is_valid(callback_win) then
			pcall(vim.api.nvim_set_current_win, callback_win)
		end
		if not ok then
			if split_augroup then
				pcall(vim.api.nvim_del_augroup_by_id, split_augroup)
			end
			if source_options and util.win_is_valid(source_win) then
				apply_win_options(source_win, source_options)
			end
			if util.win_is_valid(created_win) then
				pcall(vim.api.nvim_win_close, created_win, true)
			end
			if util.buf_is_valid(created_buf) then
				pcall(vim.api.nvim_buf_delete, created_buf, { force = true })
			end
			blame_views[source_bufnr] = nil
			util.notify("Could not open blame split: " .. util.truncate(tostring(build_err), 200), vim.log.levels.ERROR)
		end
	end, { contents = util.join_lines(util.get_buf_lines(source_bufnr)) })
	return true
end

function M.line_log()
	local source_bufnr = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	close_line_log(source_bufnr)
	local path, cached_backend = supported_blame_buffer(source_bufnr)
	if not path then
		util.notify("Current buffer is not a Git or SVN file", vim.log.levels.WARN)
		return false
	end

	local token = {}
	local view = {
		source_winid = source_win,
		token = token,
		loading = true,
	}
	line_log_views[source_bufnr] = view

	local function valid()
		return line_log_views[source_bufnr] == view
			and view.token == token
			and util.buf_is_valid(source_bufnr)
			and util.win_is_valid(source_win)
			and vim.api.nvim_win_get_buf(source_win) == source_bufnr
	end

	local function fail(message)
		if not valid() then
			return
		end
		close_line_log(source_bufnr)
		util.notify(message, vim.log.levels.WARN)
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
		local popup_augroup = vim.api.nvim_create_augroup(
			"lazyvcs_line_log_" .. source_bufnr .. "_" .. tostring(vim.uv.hrtime()),
			{ clear = true }
		)
		view.loading = false
		view.handle = nil
		view.bufnr = buf
		view.winid = win
		view.augroup = popup_augroup
		local function close()
			close_line_log(source_bufnr)
		end
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = popup_augroup,
			buffer = source_bufnr,
			once = true,
			callback = close,
		})
		vim.api.nvim_create_autocmd("WinClosed", {
			group = popup_augroup,
			pattern = { tostring(source_win), tostring(win) },
			callback = function()
				vim.schedule(close)
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = popup_augroup,
			buffer = source_bufnr,
			callback = function()
				vim.schedule(close)
			end,
		})
		compat.keymap_set("n", "q", close, { buffer = buf, silent = true, nowait = true, desc = "Close VCS log" })
		compat.keymap_set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true, desc = "Close VCS log" })
	end

	local line_number = vim.api.nvim_win_get_cursor(source_win)[1]
	local function resolved(backend, _, resolve_err)
		if not valid() then
			return
		end
		if not backend or not backend.line_revision_async or not backend.revision_log_async then
			return fail(resolve_err or "Line history is not supported for this buffer")
		end
		view.handle = backend.line_revision_async(path, line_number, function(revision, blame_err)
			if not valid() then
				return
			end
			if not revision then
				return fail(blame_err or "No blame information for this line")
			end
			view.handle = backend.revision_log_async(path, revision, function(lines, log_err)
				if not valid() then
					return
				end
				if not lines then
					return fail(log_err or ("No log information for revision " .. revision))
				end
				open_popup(backend, revision, lines)
			end)
		end)
	end
	if cached_backend then
		resolved(cached_backend)
	else
		view.handle = backends.resolve_async(path, resolved)
	end
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
		callback = function(args)
			update_inline(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "BufFilePost" }, {
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
