local backends = require("lazyvcs.backends")
local common = require("lazyvcs.backends.comparison")
local util = require("lazyvcs.util")
local json = require("lazyvcs.json_file")
local view = require("lazyvcs.compare_view")
local highlighting = require("lazyvcs.highlighting")
local navigation = require("lazyvcs.compare_navigation")
local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local M = {}
local sessions = {}
local write, display = view.write, view.display

local function valid(win)
	return win and vim.api.nvim_win_is_valid(win)
end
local function alive(s)
	return not s.closed and vim.api.nvim_tabpage_is_valid(s.tab)
end
local function owned(win)
	return valid(win)
		and (vim.w[win].lazyvcs_compare or vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "lazyvcs-source-control")
end
local function state_path()
	return vim.fn.stdpath("state") .. "/lazyvcs/comparisons.json"
end
local function cancel(s, field)
	local job = s[field]
	s[field] = nil
	if job then
		job:kill()
	end
end
local function selected(s)
	return valid(s.sidewin) and s.rows and s.rows[vim.api.nvim_win_get_cursor(s.sidewin)[1]] or nil
end
local function capture(win)
	if valid(win) then
		return vim.api.nvim_win_call(win, vim.fn.winsaveview)
	end
end
local function restore(win, saved)
	if valid(win) and saved then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(saved)
			if vim.wo.diff then
				vim.cmd("normal! zv")
				vim.fn.winrestview(saved)
			end
		end)
	end
end
local function bind(s, buf)
	for _, mapping in ipairs(s.keymaps and s.keymaps[buf] or {}) do
		compat.keymap_set("n", mapping.key, mapping.callback, {
			buffer = buf,
			nowait = mapping.nowait,
			silent = true,
			desc = mapping.desc,
		})
	end
end
local function preview_options(s, win)
	if s.mode == "text" then
		highlighting.apply(win, require("lazyvcs.config").get().diff_highlighting)
	else
		highlighting.release(win)
	end
	vim.api.nvim_win_call(win, function()
		vim.w.lazyvcs_compare = true
		vim.wo.winfixbuf = false
		vim.cmd(s.mode == "text" and "diffthis" or "diffoff")
		if s.mode ~= "text" then
			vim.wo.foldenable, vim.wo.cursorbind, vim.wo.scrollbind = false, false, false
		end
	end)
end
local function sidebar_options(s)
	vim.w[s.sidewin].lazyvcs_compare = true
	local wo = vim.wo[s.sidewin]
	wo.winfixwidth, wo.winfixbuf, wo.cursorline = true, false, true
	wo.number, wo.relativenumber, wo.wrap, wo.spell, wo.foldenable = false, false, false, false, false
	wo.diff, wo.cursorbind, wo.scrollbind = false, false, false
	wo.signcolumn, wo.foldcolumn, wo.list, wo.listchars = "no", "0", true, "extends:>,precedes:<"
end
local function resize(s, manual_event)
	if not alive(s) or vim.api.nvim_get_current_tabpage() ~= s.tab or s.resizing then
		return
	end
	if not (valid(s.sidewin) and valid(s.leftwin) and valid(s.rightwin)) then
		return
	end
	-- A file-opening action may temporarily occupy a pane until its scheduled
	-- restoration. Never close or rebuild that window around a borrowed buffer.
	if
		vim.api.nvim_win_get_buf(s.sidewin) ~= s.sidebar
		or vim.api.nvim_win_get_buf(s.leftwin) ~= s.left
		or vim.api.nvim_win_get_buf(s.rightwin) ~= s.right
	then
		return
	end
	if
		manual_event
		and s.applied_width
		and vim.api.nvim_win_get_width(s.sidewin) ~= s.applied_width
		and not s.auto_width
	then
		s.manual_width = vim.api.nvim_win_get_width(s.sidewin)
	end
	s.resizing = true
	local width, stacked =
		view.layout(vim.o.columns, s.manual_width, s.auto_width, s.rows_cache and s.rows_cache.width or 0)
	local focused = vim.api.nvim_get_current_win()
	local left_view, right_view = capture(s.leftwin), capture(s.rightwin)
	local right_focused = focused == s.rightwin
	if stacked ~= s.stacked then
		vim.api.nvim_win_close(s.rightwin, true)
		vim.api.nvim_win_call(s.leftwin, function()
			vim.cmd(stacked and "rightbelow split" or "rightbelow vsplit")
			s.rightwin = vim.api.nvim_get_current_win()
			vim.wo.winfixbuf = false
			vim.api.nvim_win_set_buf(s.rightwin, s.right)
		end)
		s.stacked = stacked
		preview_options(s, s.leftwin)
		preview_options(s, s.rightwin)
		vim.wo[s.rightwin].winbar = s.right_label or "SAVED WORKTREE"
	end
	vim.api.nvim_win_set_width(s.sidewin, width)
	if stacked then
		vim.api.nvim_win_set_height(s.leftwin, math.max(1, math.floor((vim.o.lines - 5) / 2)))
	else
		vim.api.nvim_win_set_width(s.leftwin, math.max(1, math.floor((vim.o.columns - width - 2) / 2)))
	end
	s.applied_width = vim.api.nvim_win_get_width(s.sidewin)
	s.resizing = false
	restore(s.leftwin, left_view)
	restore(s.rightwin, right_view)
	if right_focused then
		vim.api.nvim_set_current_win(s.rightwin)
	end
	view.hints(s)
end
local function message(s, text)
	if not alive(s) then
		return
	end
	local item, saved = selected(s), capture(s.sidewin)
	s.message = text
	view.render(s)
	if item and s.row_by_path[item.relpath] then
		if saved then
			saved.lnum = s.row_by_path[item.relpath]
		end
		restore(s.sidewin, saved)
	end
end
local function labels(s, left, right)
	s.left_label, s.right_label = display(left):gsub("%%", "%%%%"), display(right):gsub("%%", "%%%%")
	if valid(s.leftwin) then
		vim.wo[s.leftwin].winbar = "%<" .. s.left_label
	end
	if valid(s.rightwin) then
		vim.wo[s.rightwin].winbar = "%<" .. s.right_label
	end
end
local function failure(s, err)
	navigation.cancel(s)
	s.navigation = nil
	s.preview_result, s.shown_item, s.mode = nil, nil, "message"
	message(s, "Comparison unavailable")
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	vim.bo[s.left].filetype, vim.bo[s.right].filetype = "", ""
	bind(s, s.left)
	bind(s, s.right)
	labels(s, "Comparison unavailable", "Recovery")
	write(s.left, util.split_lines(tostring(err)))
	write(s.right, s.context and { "b: choose another base", "R: retry", "q: close" } or { "R: retry", "q: close" })
end
local function file_stamp(path)
	local stat = vim.uv.fs_lstat(path)
	return stat and table.concat({ stat.type, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.mode }, ":") or "missing"
end
local function show_result(s, mode)
	local result, item = s.preview_result, s.shown_item
	if not result or not item then
		return
	end
	s.mode = mode or "text"
	local path = s.root .. "/" .. item.relpath
	if s.mode == "metadata" then
		s.text_views = { capture(s.leftwin), capture(s.rightwin) }
		write(s.left, result.properties or result.details or { "No metadata or property changes for this path." })
		write(s.right, { "p or Enter: return to text" })
		vim.bo[s.left].filetype, vim.bo[s.right].filetype = result.properties and "diff" or "", ""
		labels(s, "METADATA / PROPERTIES: " .. item.relpath, "Return to text")
	else
		write(s.left, result.left)
		write(s.right, result.right)
		local ft = vim.filetype.match({ filename = path }) or ""
		vim.bo[s.left].filetype, vim.bo[s.right].filetype = ft, ft
		labels(
			s,
			result.left_label .. " | " .. (item.old_path or item.relpath),
			result.right_label .. " | " .. item.relpath
		)
	end
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	bind(s, s.left)
	bind(s, s.right)
	if s.mode == "text" then
		vim.api.nvim_win_call(s.leftwin, function()
			vim.cmd("diffupdate")
		end)
		if s.text_views then
			restore(s.leftwin, s.text_views[1])
			restore(s.rightwin, s.text_views[2])
			s.text_views = nil
		end
	end
	view.marker(s)
end
local function preview(s, item, mode, saved_views, intent, saved_reviewed)
	item = item or selected(s)
	if not item or not s.snapshot then
		return
	end
	navigation.remember(s)
	s.preview_generation = (s.preview_generation or 0) + 1
	cancel(s, "preview_job")
	navigation.cancel(s)
	s.navigation, s.preview_mode = nil, mode or "text"
	local generation = s.preview_generation
	s.preview_result, s.text_views, s.shown_item, s.mode = nil, nil, item, "message"
	local path = s.root .. "/" .. item.relpath
	local stamp = file_stamp(path)
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	vim.bo[s.left].filetype, vim.bo[s.right].filetype = "", ""
	bind(s, s.left)
	bind(s, s.right)
	labels(s, "Loading: " .. item.relpath, "SAVED WORKTREE")
	write(s.left, { "Loading " .. display(item.relpath) .. "..." })
	write(s.right, {})
	view.marker(s)
	s.navigation_intent = intent
	s.preview_job = s.provider.preview(s.snapshot, item, function(result, err)
		if not alive(s) or generation ~= s.preview_generation then
			return
		end
		s.preview_job = nil
		if stamp ~= file_stamp(path) then
			result, err = nil, "File changed during preview; press R to refresh"
		end
		if not result then
			navigation.cancel(s)
			labels(s, "Preview unavailable: " .. item.relpath, "SAVED WORKTREE")
			write(s.left, vim.list_extend({ "Preview unavailable" }, util.split_lines(tostring(err))))
			write(s.right, {})
			return
		end
		s.preview_result, s.preview_stamp = result, stamp
		navigation.load(s, result, item)
		-- nvim_win_call emits window events while configuring and restoring panes.
		-- Those internal visits must not cancel an explicit review request.
		local pending = s.navigation_intent
		s.navigation_intent = nil
		show_result(s, s.preview_mode)
		local remembered = s.file_views and s.file_views[item.relpath]
		if not saved_views and remembered and remembered.old_path == item.old_path then
			if s.mode == "metadata" then
				s.text_views = vim.deepcopy(remembered.views)
			else
				restore(s.leftwin, remembered.views[1])
				restore(s.rightwin, remembered.views[2])
			end
			navigation.restore(s, remembered, stamp)
		end
		if saved_views and s.mode == "text" then
			restore(s.leftwin, saved_views[1])
			restore(s.rightwin, saved_views[2])
			if remembered then
				navigation.restore(s, remembered, stamp)
			end
			s.navigation.reviewed = saved_reviewed == true
		end
		s.navigation_intent = pending
		navigation.complete(s, s.navigation_intent)
	end)
end
local function request_preview(s, kind)
	local item = vim.api.nvim_get_current_win() == s.sidewin and selected(s) or s.shown_item
	navigation.cancel(s)
	if not item then
		return
	end
	local intent = kind ~= "preview" and navigation.intent(s, item, kind) or nil
	if item == s.shown_item and s.preview_result then
		if s.mode ~= "text" then
			show_result(s, "text")
		end
		navigation.complete(s, intent)
	elseif item == s.shown_item and s.preview_job then
		s.preview_mode = "text"
	else
		preview(s, item, "text", nil, intent)
	end
end
local function choose_base(s)
	if s.prompting then
		return
	end
	s.prompting = true
	vim.ui.input({
		prompt = s.vcs == "git" and "Comparison base (branch or commit): " or "SVN base URL@revision:",
		default = s.base or s.context.suggestion or "",
	}, function(value)
		s.prompting = false
		if not alive(s) then
			return
		end
		if not value or value == "" then
			if not s.base then
				M.close(s)
			elseif not s.snapshot then
				M.refresh(s)
			end
			return
		end
		s.base, s.explicit_base = value, true
		M.refresh(s)
	end)
end
local function matching(s)
	for _, other in pairs(sessions) do
		if other ~= s and alive(other) and other.origin_tab == s.origin_tab and other.root == s.root then
			return other
		end
	end
end
function M.refresh(s, context_checked)
	s = s or sessions[vim.api.nvim_get_current_tabpage()]
	if not s or not alive(s) then
		return
	end
	if not context_checked then
		navigation.cancel(s)
		navigation.remember(s)
		if not s.restore and s.snapshot then
			local cursor = selected(s)
			s.restore = {
				cursor = cursor and cursor.relpath,
				shown = s.shown_item and s.shown_item.relpath,
				side = capture(s.sidewin),
				index = cursor and s.rows_cache.by_path[cursor.relpath],
				views = s.text_views or { capture(s.leftwin), capture(s.rightwin) },
				reviewed = s.navigation and s.navigation.reviewed,
			}
		end
		s.navigation = nil
		s.generation, s.preview_generation = (s.generation or 0) + 1, (s.preview_generation or 0) + 1
		cancel(s, "job")
		cancel(s, "preview_job")
		s.preview_result, s.text_views, s.snapshot = nil, nil, nil
	end
	local generation = s.generation
	if not s.provider then
		if s.resolution_failed then
			backends.invalidate()
		end
		message(s, "Finding repository...")
		s.job = backends.resolve_async(s.path, function(backend, root, err)
			if not alive(s) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not backend then
				s.resolution_failed = true
				return failure(s, err)
			end
			s.resolution_failed = nil
			s.root, s.vcs, s.provider = root, backend.name, common.provider(backend.name)
			local other = matching(s)
			if other then
				if s.explicit_base then
					other.base, other.explicit_base = s.base, true
				end
				if s.explicit_untracked ~= nil then
					other.include_untracked = s.explicit_untracked
				end
				other.choose_base_requested = s.choose_base_requested
				M.close(s, false)
				vim.api.nvim_set_current_tabpage(other.tab)
				vim.api.nvim_set_current_win(other.sidewin)
				M.refresh(other)
				return
			end
			M.refresh(s)
		end)
		return
	end
	if not context_checked then
		message(s, "Loading saved changes...")
		s.job = s.provider.context(s, function(context, err)
			if not alive(s) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not context then
				return failure(s, err)
			end
			if (not s.context or s.context.branch ~= context.branch) and not s.explicit_base then
				s.base = context.branch and json.read(state_path())[s.root .. "\n" .. context.branch] or nil
			end
			s.context = context
			M.refresh(s, true)
		end)
		return
	end
	s.explicit_base = false
	if s.choose_base_requested then
		s.choose_base_requested = nil
		return choose_base(s)
	end
	if not s.base then
		message(s, "Select a comparison base")
		return choose_base(s)
	end
	s.items, s.snapshot, s.uncounted, s.shown_item, s.mode = {}, nil, nil, nil, "message"
	message(s, "Loading saved changes...")
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	write(s.left, {})
	write(s.right, {})
	s.job = s.provider.resolve(s, s.base, function(snapshot, err)
		if not alive(s) or generation ~= s.generation then
			return
		end
		if not snapshot then
			s.job = nil
			return failure(s, err)
		end
		s.job = s.provider.list(snapshot, s.include_untracked, function(items, list_err)
			if not alive(s) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not items then
				return failure(s, list_err)
			end
			navigation.reconcile(s, snapshot, items)
			s.snapshot, s.items = snapshot, items
			if s.context.branch and s.context.branch ~= "" then
				local saved = json.read(state_path())
				saved[s.root .. "\n" .. s.context.branch] = s.base
				local ok, save_err = json.write(state_path(), saved)
				if not ok then
					util.notify(save_err, vim.log.levels.WARN)
				end
			end
			local added, deleted, unknown = 0, 0, 0
			for _, item in ipairs(items) do
				if item.added and item.deleted then
					added, deleted = added + item.added, deleted + item.deleted
				else
					unknown = unknown + 1
				end
			end
			s.uncounted = unknown > 0 and unknown or nil
			message(s, #items == 0 and "No saved changes" or string.format("%d paths +%d -%d", #items, added, deleted))
			resize(s)
			local saved = s.restore
			s.restore = nil
			if #items > 0 then
				local index = saved and saved.cursor and s.rows_cache.by_path[saved.cursor]
				index = index or math.min(#items, saved and saved.index or 1)
				local item = items[index]
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
				if saved and saved.side then
					saved.side.lnum = s.row_by_path[item.relpath]
					restore(s.sidewin, saved.side)
				end
				local shown = saved and saved.shown and s.rows_cache.by_path[saved.shown]
				preview(s, shown and items[shown] or item, "text", saved and saved.views, nil, saved and saved.reviewed)
			else
				labels(s, "No saved changes", "SAVED WORKTREE")
			end
		end)
	end)
end
function M.base()
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if s and s.context then
		navigation.cancel(s)
		choose_base(s)
	else
		M.open({ choose_base = true })
	end
end
function M.jump_to_hunk(direction)
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if not navigation.owns(s) then
		return false
	end
	if vim.api.nvim_get_current_win() == s.sidewin then
		request_preview(s, direction == "next" and "first" or "last")
	else
		navigation.cancel(s)
		if s.preview_result and s.mode ~= "text" then
			show_result(s, "text")
		end
		navigation.jump(s, direction)
	end
	return true
end

function M.navigate_file(direction, count)
	count = count == nil and 1 or count
	if type(count) ~= "number" or count < 1 or count == math.huge or count ~= math.floor(count) then
		error("lazyvcs comparison file count must be a positive integer")
	end
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if not navigation.owns(s) then
		return false
	end
	if not s.snapshot or #s.items == 0 then
		util.notify(s.snapshot and "No comparison files" or "Comparison is still loading", vim.log.levels.INFO)
		return true
	end
	local item = vim.api.nvim_get_current_win() == s.sidewin and selected(s) or s.shown_item
	item = item or s.shown_item
	local index = item and s.rows_cache.by_path[item.relpath]
	local step = direction == "next" and count or -count
	index = index and (index - 1 + step % #s.items) % #s.items + 1 or (direction == "next" and 1 or #s.items)
	item = s.items[index]
	if item == s.shown_item and vim.api.nvim_get_current_win() ~= s.sidewin and (s.preview_result or s.preview_job) then
		return true
	end
	vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
	local intent = navigation.intent(s, item, "file")
	if item == s.shown_item and s.preview_result then
		if s.mode ~= "text" then
			show_result(s, "text")
		end
		navigation.complete(s, intent)
	elseif item == s.shown_item and s.preview_job then
		s.preview_mode = "text"
	else
		preview(s, item, "text", nil, intent)
	end
	return true
end
local function editor_window(win)
	return valid(win)
		and not owned(win)
		and vim.api.nvim_win_get_config(win).relative == ""
		and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function origin_window(s, editing, buf)
	local win = editing and s.origin_edit_win or s.origin_win
	if valid(win) and (not editing or editor_window(win)) then
		return win
	end
	if vim.api.nvim_tabpage_is_valid(s.origin_tab) then
		for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(s.origin_tab)) do
			if editor_window(candidate) then
				s.origin_edit_win = candidate
				return candidate
			end
		end
		vim.api.nvim_set_current_tabpage(s.origin_tab)
		vim.cmd(buf and "rightbelow sbuffer " .. buf or "rightbelow new")
	else
		vim.cmd(buf and "tab sbuffer " .. buf or "tabnew")
		s.origin_tab = vim.api.nvim_get_current_tabpage()
	end
	s.origin_edit_win = vim.api.nvim_get_current_win()
	return s.origin_edit_win
end
function M.source_control(action, opts)
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if not s then
		return
	end
	vim.api.nvim_set_current_win(origin_window(s, false))
	local native = require("lazyvcs.source_control.native")
	if action == "open" or action == "toggle" then
		local current = native._state()
		local path = opts and (opts.path or opts.root)
		if current and valid(current.winid) and not path then
			vim.api.nvim_set_current_win(current.winid)
			return current
		end
		return native.open({ path = path or s.origin_sidebar_path or s.root or s.path })
	end
	if action == "refresh" then
		return native.refresh(true)
	end
	if action == "cancel" then
		return native.cancel(opts)
	end
	return native.close()
end
function M.close(s, return_focus)
	s = s or sessions[vim.api.nvim_get_current_tabpage()]
	if not s or s.closed then
		return
	end
	s.closed = true
	navigation.cancel(s)
	highlighting.release(s.leftwin)
	highlighting.release(s.rightwin)
	cancel(s, "job")
	cancel(s, "preview_job")
	sessions[s.tab] = nil
	if s.augroup then
		vim.api.nvim_del_augroup_by_id(s.augroup)
	end
	if valid(s.helpwin) then
		vim.api.nvim_win_close(s.helpwin, true)
	end
	if vim.api.nvim_tabpage_is_valid(s.tab) then
		vim.api.nvim_set_current_tabpage(s.tab)
		if #vim.api.nvim_list_tabpages() == 1 then
			origin_window(s, true)
		end
		if vim.api.nvim_get_current_tabpage() == s.tab then
			vim.cmd("tabclose")
		else
			vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(s.tab))
		end
	end
	for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
	if return_focus ~= false and valid(s.origin_win) then
		vim.api.nvim_set_current_win(s.origin_win)
	end
end
local function target(s)
	return vim.api.nvim_get_current_win() == s.sidewin and selected(s) or s.shown_item
end
local function edit_buffer(s, buf, position)
	local win = origin_window(s, true, buf)
	vim.api.nvim_set_current_win(win)
	if vim.wo.winfixbuf or (vim.bo.modified and not vim.o.hidden) then
		vim.cmd("rightbelow sbuffer " .. buf)
		s.origin_edit_win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_win_set_buf(0, buf)
	if position then
		local line = math.min(position[1], vim.api.nvim_buf_line_count(buf))
		local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
		vim.api.nvim_win_set_cursor(0, { line, math.min(position[2], #text) })
	end
end
local function edit(s)
	local item = target(s)
	if not item then
		return
	end
	local path = s.root .. "/" .. item.relpath
	if not vim.uv.fs_lstat(path) then
		return util.notify("This path is deleted from the working tree", vim.log.levels.INFO)
	end
	local buf = vim.fn.bufadd(path)
	vim.bo[buf].buflisted = true
	vim.fn.bufload(buf)
	edit_buffer(s, buf)
end
local function help(s)
	if valid(s.helpwin) then
		vim.api.nvim_win_close(s.helpwin, true)
		return
	end
	local lines = {
		"Comparison help",
		"",
		"Enter / double-click: review selected file at its first hunk",
		"P: preview without leaving the file list; Esc: return to the list",
		"e: fit sidebar width; press again to restore",
		"o: edit the real file in the original editing window",
		"p: toggle metadata or properties; Enter returns to text",
		"R: refresh and pin the base again",
		"b: choose a base",
		"q: close comparison and return",
		"",
		"Your source-control mapping returns to the original sidebar.",
		"C in source control reopens and refreshes this comparison.",
		"Both preview panes are read-only. Save buffers before refreshing.",
		"Git: common ancestor against saved worktree; no implicit fetch.",
		"SVN: chosen URL@revision against saved working copy.",
		"Nonignored untracked files are included by default.",
		"Binary files and files larger than 1 MiB have no text preview.",
	}
	local opts = config.get()
	if opts.session_keymaps then
		for _, mapping in ipairs({ { opts.keymaps.next_file, "next" }, { opts.keymaps.prev_file, "previous" } }) do
			if mapping[1] then
				table.insert(lines, 5, mapping[1] .. ": " .. mapping[2] .. " file; wraps and restores your position")
			end
		end
		for _, mapping in ipairs({ { opts.keymaps.next_hunk, "next" }, { opts.keymaps.prev_hunk, "previous" } }) do
			if mapping[1] then
				table.insert(lines, 5, mapping[1] .. ": " .. mapping[2] .. " hunk; wraps within this file")
			end
		end
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	write(buf, lines)
	s.helpwin = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		row = 1,
		col = 1,
		width = math.max(1, math.min(76, vim.o.columns - 4)),
		height = math.max(1, math.min(#lines, vim.o.lines - 5)),
	})
	vim.w[s.helpwin].lazyvcs_compare = true
	for _, key in ipairs({ "q", "?", "<Esc>" }) do
		compat.keymap_set("n", key, function()
			if valid(s.helpwin) then
				vim.api.nvim_win_close(s.helpwin, true)
			end
		end, { buffer = buf, silent = true })
	end
	local helpwin = s.helpwin
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				if valid(helpwin) then
					vim.api.nvim_win_close(helpwin, true)
				end
			end)
		end,
	})
end
local function open_session(opts, origin)
	local current_buf = vim.api.nvim_get_current_buf()
	local path = opts.path or (util.is_real_file_buffer(current_buf) and util.buf_path(current_buf)) or vim.fn.getcwd()
	path = util.canonical_path(vim.fn.fnamemodify(path, ":p"))
	for _, existing in pairs(sessions) do
		if
			alive(existing)
			and existing.origin_tab == origin.origin_tab
			and (existing.path == path or existing.root == path)
		then
			vim.api.nvim_set_current_tabpage(existing.tab)
			vim.api.nvim_set_current_win(existing.sidewin)
			if opts.base then
				existing.base, existing.explicit_base = opts.base, true
			end
			if opts.include_untracked ~= nil then
				existing.include_untracked = opts.include_untracked
			end
			existing.choose_base_requested = opts.choose_base or nil
			M.refresh(existing)
			return existing
		end
	end
	local s = vim.tbl_extend("force", origin, {
		path = path,
		base = opts.base,
		explicit_base = opts.base ~= nil,
		include_untracked = opts.include_untracked ~= false,
		explicit_untracked = opts.include_untracked,
		choose_base_requested = opts.choose_base,
		items = {},
		rows = {},
		row_by_path = {},
		mode = "message",
		manual_width = math.min(38, math.max(20, math.floor(vim.o.columns / 4))),
	})
	local function scratch()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "hide", false
		return buf
	end
	s.sidebar, s.left, s.right = scratch(), scratch(), scratch()
	vim.cmd("tab sbuffer " .. s.sidebar)
	s.tab, s.sidewin = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
	for label, buf in pairs({ files = s.sidebar, base = s.left, saved = s.right }) do
		vim.api.nvim_buf_set_name(buf, "lazyvcs://compare/" .. s.tab .. "/" .. label)
	end
	vim.wo.winfixbuf = false
	vim.cmd("rightbelow vsplit")
	s.leftwin = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.leftwin, s.left)
	vim.cmd("rightbelow vsplit")
	s.rightwin, s.stacked = vim.api.nvim_get_current_win(), false
	vim.api.nvim_win_set_buf(s.rightwin, s.right)
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	vim.bo[s.sidebar].filetype = "lazyvcs-comparison"
	sidebar_options(s)
	sessions[s.tab] = s
	resize(s)
	local function enter()
		if vim.api.nvim_get_current_win() == s.sidewin then
			request_preview(s, "review")
		else
			request_preview(s, "preview")
		end
	end
	s.keymaps = {}
	for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
		s.keymaps[buf] = {}
		local bindings = {
			q = {
				function()
					M.close(s)
				end,
				"Close comparison",
			},
			R = {
				function()
					M.refresh(s)
				end,
				"Refresh comparison",
			},
			b = {
				function()
					if s.context then
						choose_base(s)
					end
				end,
				"Choose comparison base",
			},
			["?"] = {
				function()
					help(s)
				end,
				"Comparison help",
			},
			o = {
				function()
					edit(s)
				end,
				"Edit comparison file",
			},
			e = {
				function()
					local width = vim.api.nvim_win_get_width(s.sidewin)
					if not s.auto_width then
						s.manual_width = width
					end
					s.auto_width = not s.auto_width
					resize(s)
					if s.auto_width and vim.api.nvim_win_get_width(s.sidewin) == width then
						util.notify(
							(s.rows_cache and s.rows_cache.width or 0) < width and "Comparison file list already fits"
								or "Comparison file list is at its width limit; enlarge the terminal",
							vim.log.levels.INFO
						)
					end
				end,
				"Fit or restore comparison width",
			},
			p = {
				function()
					navigation.cancel(s)
					local item = target(s)
					if s.preview_result and item == s.shown_item then
						show_result(s, s.mode == "metadata" and "text" or "metadata")
					else
						preview(s, item, "metadata")
					end
				end,
				"Toggle metadata or properties",
			},
			["<CR>"] = { enter, "Review comparison file" },
			P = {
				function()
					request_preview(s, "preview")
				end,
				"Preview comparison file",
			},
		}
		if buf ~= s.sidebar then
			bindings["<Esc>"] = {
				function()
					navigation.cancel(s)
					local item = s.shown_item
					if item and s.row_by_path[item.relpath] then
						vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
					end
					vim.api.nvim_set_current_win(s.sidewin)
				end,
				"Return to comparison files",
			}
		end
		for key, binding in pairs(bindings) do
			s.keymaps[buf][#s.keymaps[buf] + 1] = { key = key, callback = binding[1], nowait = true, desc = binding[2] }
		end
		local opts = config.get()
		if opts.session_keymaps then
			for _, mapping in ipairs({ { opts.keymaps.next_file, "next" }, { opts.keymaps.prev_file, "prev" } }) do
				if mapping[1] then
					s.keymaps[buf][#s.keymaps[buf] + 1] = {
						key = mapping[1],
						callback = function()
							M.navigate_file(mapping[2], vim.v.count1)
						end,
						desc = "lazyvcs " .. mapping[2] .. " comparison file",
					}
				end
			end
			for _, mapping in ipairs({ { opts.keymaps.next_hunk, "next" }, { opts.keymaps.prev_hunk, "prev" } }) do
				if mapping[1] then
					s.keymaps[buf][#s.keymaps[buf] + 1] = {
						key = mapping[1],
						callback = function()
							M.jump_to_hunk(mapping[2])
						end,
						desc = "lazyvcs " .. mapping[2] .. " hunk",
					}
				end
			end
		end
		bind(s, buf)
	end
	compat.keymap_set("n", "<2-LeftMouse>", enter, { buffer = s.sidebar, silent = true })
	s.augroup = vim.api.nvim_create_augroup("lazyvcs_compare_" .. s.tab, { clear = true })
	require("lazyvcs.compare_open").setup(s, {
		remember = navigation.remember,
		restore = function(views)
			views = views or {}
			sidebar_options(s)
			preview_options(s, s.leftwin)
			preview_options(s, s.rightwin)
			for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
				bind(s, buf)
			end
			if s.mode == "text" then
				vim.api.nvim_win_call(s.leftwin, function()
					vim.cmd("diffupdate")
				end)
			end
			restore(s.leftwin, views[1])
			restore(s.rightwin, views[2])
			restore(s.sidewin, views[3])
			resize(s)
		end,
		select = function(item, position)
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
			local intent = navigation.intent(s, item, "search")
			intent.position = position
			if item == s.shown_item and s.preview_result then
				if s.mode ~= "text" then
					show_result(s, "text")
				end
				navigation.complete(s, intent)
			elseif item == s.shown_item and s.preview_job then
				s.preview_mode = "text"
			else
				preview(s, item, "text", nil, intent)
			end
		end,
		edit = function(buf, position)
			edit_buffer(s, buf, position)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinLeave", "TabLeave", "CursorMoved" }, {
		group = s.augroup,
		callback = function(args)
			local intent = s.navigation_intent
			if intent and not s.resizing then
				local item = selected(s)
				if
					args.event ~= "CursorMoved" or (vim.api.nvim_get_current_win() == s.sidewin and item ~= intent.item)
				then
					navigation.cancel(s)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("TabClosed", {
		group = s.augroup,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(s.tab) then
				M.close(s, false)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "TabEnter", "WinResized" }, {
		group = s.augroup,
		callback = function(args)
			resize(s, args.event == "WinResized")
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = s.augroup,
		callback = function()
			vim.schedule(function()
				if alive(s) and not (valid(s.sidewin) and valid(s.leftwin) and valid(s.rightwin)) then
					M.close(s)
				end
			end)
		end,
	})
	vim.api.nvim_set_current_win(s.sidewin)
	M.refresh(s)
	return s
end
function M.open(opts)
	opts = opts or {}
	local existing = sessions[vim.api.nvim_get_current_tabpage()]
	if existing and (not opts.path or opts.path == existing.root or opts.path == existing.path) then
		if opts.base then
			existing.base, existing.explicit_base = opts.base, true
		end
		if opts.include_untracked ~= nil then
			existing.include_untracked = opts.include_untracked
		end
		existing.choose_base_requested = opts.choose_base or nil
		M.refresh(existing)
		return existing
	end
	local native = package.loaded["lazyvcs.source_control.native"]
	local context = native and native.comparison_context()
	local origin = existing
			and {
				origin_tab = existing.origin_tab,
				origin_win = existing.origin_win,
				origin_edit_win = existing.origin_edit_win,
				origin_sidebar_path = existing.origin_sidebar_path,
			}
		or context
		or {
			origin_tab = vim.api.nvim_get_current_tabpage(),
			origin_win = vim.api.nvim_get_current_win(),
			origin_edit_win = vim.api.nvim_get_current_win(),
		}
	if context and not opts.path then
		if context.path then
			opts = vim.tbl_extend("force", opts, { path = context.path })
		elseif #context.repos == 1 then
			opts = vim.tbl_extend("force", opts, { path = context.repos[1].root })
		elseif #context.repos > 1 then
			return require("lazyvcs.picker").select(context.repos, {
				prompt = "Repository to compare",
				format_item = function(repo)
					return repo.root
				end,
			}, function(repo)
				if repo and valid(origin.origin_win) then
					open_session(vim.tbl_extend("force", opts, { path = repo.root }), origin)
				end
			end)
		else
			return util.notify(
				"No visible repository to compare. Wait for discovery or select a repository.",
				vim.log.levels.INFO
			)
		end
	end
	return open_session(opts, origin)
end
function M.blame_target(buf)
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if not s or (buf ~= s.left and buf ~= s.right) then
		return nil
	end
	if s.mode ~= "text" or not s.preview_result or not s.shown_item then
		return nil, "Select a text preview before requesting blame"
	end
	local item, snapshot, result = s.shown_item, s.snapshot, s.preview_result
	local side = buf == s.left and "base" or "saved"
	local lines = side == "base" and result.left or result.right
	if #lines == 0 or item.kind == "dir" or item.property_only or result.right_label == "SUBMODULE / DIRECTORY" then
		return nil, "This preview has no file lines to blame"
	end
	return {
		path = s.root .. "/" .. item.relpath,
		snapshot = snapshot,
		item = item,
		side = side,
		valid = function()
			return alive(s) and s.snapshot == snapshot and s.preview_result == result and s.mode == "text"
		end,
	}
end

function M.current()
	return sessions[vim.api.nvim_get_current_tabpage()]
end
M._state = M.current
return M
