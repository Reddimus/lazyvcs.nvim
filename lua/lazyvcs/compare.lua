local backends = require("lazyvcs.backends")
local common = require("lazyvcs.backends.comparison")
local util = require("lazyvcs.util")
local json = require("lazyvcs.json_file")
local view = require("lazyvcs.compare_view")
local highlighting = require("lazyvcs.highlighting")
local navigation = require("lazyvcs.compare_navigation")
local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local buffers = require("lazyvcs.compare_buffers")
local catalog = require("lazyvcs.compare_actions")
local worktree = require("lazyvcs.compare_worktree")
local worktree_event
local M = {}
local sessions = {}
local write, display = view.write, view.display

local function protected(callback)
	return function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			util.notify("Comparison: " .. tostring(err):gsub("%s+", " "), vim.log.levels.ERROR)
		end
	end
end
local function schedule(callback)
	vim.schedule(protected(callback))
end
local function autocmd(events, opts)
	opts.callback = protected(opts.callback)
	return vim.api.nvim_create_autocmd(events, opts)
end
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
-- A picker may preview another buffer in the sidebar window; its cursor and
-- view are not the file list's.
local function sidebar_shown(s)
	return valid(s.sidewin) and vim.api.nvim_win_get_buf(s.sidewin) == s.sidebar
end
local function selected(s)
	return sidebar_shown(s) and s.rows and s.rows[vim.api.nvim_win_get_cursor(s.sidewin)[1]] or nil
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
local function bind(_s, buf)
	buffers.context(buf)
	require("lazyvcs.window_controls").sync()
end
local function preview_options(s, win)
	-- The buffer this pane holds Compare state for; only that one is reset.
	s.pane_state = s.pane_state or {}
	s.pane_state[win] = vim.api.nvim_win_get_buf(win)
	if s.mode == "text" then
		highlighting.apply(win, require("lazyvcs.config").get().diff_highlighting)
	else
		highlighting.release(win)
	end
	vim.api.nvim_win_call(win, function()
		vim.w.lazyvcs_compare = true
		util.set_win_option(0, "winfixbuf", false)
		vim.cmd(s.mode == "text" and "diffthis" or "diffoff")
		if s.mode ~= "text" then
			util.set_win_options(win, { foldenable = false, cursorbind = false, scrollbind = false })
		end
	end)
end
local function sidebar_options(s)
	vim.w[s.sidewin].lazyvcs_compare = true
	util.unbind_window(s.sidewin)
	util.set_win_options(s.sidewin, {
		winfixwidth = true,
		winfixbuf = false,
		cursorline = true,
		number = false,
		relativenumber = false,
		wrap = false,
		spell = false,
		foldenable = false,
		signcolumn = "no",
		foldcolumn = "0",
		list = true,
		listchars = "extends:>,precedes:<",
	})
end
local function layout_constraints()
	return { min_width = vim.o.winminwidth, min_height = vim.o.winminheight, height = vim.o.lines - vim.o.cmdheight - 3 }
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
	local width, stacked, err = view.layout(
		vim.o.columns,
		s.manual_width,
		s.auto_width,
		s.rows_cache and s.rows_cache.width or 0,
		layout_constraints()
	)
	if err then
		s.resizing = false
		return
	end
	local focused = vim.api.nvim_get_current_win()
	local left_view, right_view = capture(s.leftwin), capture(s.rightwin)
	local right_focused = focused == s.rightwin
	if stacked ~= s.stacked then
		-- Move the existing windows so their native jump histories survive.
		vim.api.nvim_win_call(s.rightwin, function()
			vim.cmd(stacked and "wincmd J" or "wincmd L")
		end)
		vim.api.nvim_win_call(s.sidewin, function()
			vim.cmd("wincmd H")
		end)
		s.stacked = stacked
		preview_options(s, s.leftwin)
		preview_options(s, s.rightwin)
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
	local item, saved = selected(s), sidebar_shown(s) and capture(s.sidewin)
	s.message = text
	view.render(s)
	if item and s.row_by_path[item.relpath] and sidebar_shown(s) then
		if saved then
			saved.lnum = s.row_by_path[item.relpath]
		end
		restore(s.sidewin, saved)
	end
end
-- Labels are already escaped for the winbar. A pane can show another buffer,
-- such as a picker preview; Neovim would save the label with that buffer's
-- options, so write it only while the pane shows its own buffer. The routing
-- restore applies the latest label when the pane gets its buffer back.
local function set_label(win, label, expected)
	if not valid(win) or vim.api.nvim_win_get_buf(win) ~= expected then
		return
	end
	local value = "%<" .. (label or "")
	util.set_win_option(win, "winbar", value)
	local buf = vim.api.nvim_win_get_buf(win)
	if not buffers.is_managed(buf) then
		worktree.mark_pane(buf, value)
	end
end
local function labels(s, left, right)
	s.left_label, s.right_label = display(left):gsub("%%", "%%%%"), display(right):gsub("%%", "%%%%")
	set_label(s.leftwin, s.left_label, s.left)
	set_label(s.rightwin, s.right_label, s.right)
end
-- Neovim saves a pane's options for the buffer it hides. Leave no Compare state
-- for an ordinary window to inherit when it later shows that real buffer. A
-- pane showing a buffer Compare did not set up, such as a picker preview,
-- keeps that buffer's options.
local function release_pane_buffer(s, win, next_buf)
	if valid(win) then
		local buf = vim.api.nvim_win_get_buf(win)
		if buf ~= next_buf and s.pane_state and s.pane_state[win] == buf then
			s.pane_state[win] = nil
			if not buffers.is_managed(buf) then
				worktree.reset_pane(win)
			end
		end
	end
end
-- Whether the pane shows the buffer Compare set it up for.
local function owns_shown(s, win)
	return valid(win) and s.pane_state ~= nil and s.pane_state[win] == vim.api.nvim_win_get_buf(win)
end
-- Switch a pane to one of Compare's slot buffers. A buffer Compare did not set
-- up there, such as a picker preview, keeps its own winbar and bindings; a
-- recognized Compare label identifies inherited pane state to reset. Its diff
-- ends in the pane, as Neovim otherwise keeps a hidden buffer in the tab's diff.
-- Only the pane's own record of that buffer changes.
local function show_slot(s, win, buf)
	if vim.api.nvim_win_get_buf(win) ~= buf and not owns_shown(s, win) then
		if worktree.is_label(vim.api.nvim_win_get_buf(win), util.get_win_option(win, "winbar")) then
			worktree.reset_pane(win)
		elseif util.get_win_option(win, "diff") then
			local keep = util.capture_win_options(win, { "scrollbind", "cursorbind", "winbar" })
			util.diff_off(win)
			util.set_win_options(win, keep)
		end
	end
	util.show_win_buffer(win, buf)
end
local function panes_usable(s, epoch)
	if not alive(s) or sessions[s.tab] ~= s or s.panes_invalid or epoch ~= (s.pane_epoch or 0) then
		return false
	end
	for _, win in ipairs({ s.sidewin, s.leftwin, s.rightwin }) do
		if not valid(win) or vim.api.nvim_win_get_tabpage(win) ~= s.tab then
			return false
		end
	end
	return true
end

local function invalidate_panes(s)
	if s.panes_invalid then
		return
	end
	s.panes_invalid, s.pane_epoch = true, (s.pane_epoch or 0) + 1
	s.preview_generation = (s.preview_generation or 0) + 1
	s.deferred_display = nil
	navigation.cancel(s)
	if s.router then
		s.router.cancel()
	end
	cancel(s, "job")
	cancel(s, "preview_job")
	for _, pair in pairs(s.buffer_cache.pairs) do
		pair.reload_generation = (pair.reload_generation or 0) + 1
		cancel(pair, "reload_job")
	end
end

local function pane_request(s, value)
	value.generation, value.preview_generation, value.pane_epoch = s.generation, s.preview_generation, s.pane_epoch or 0
	return value
end

local function set_panes(s, next_display)
	if
		not panes_usable(s, next_display.pane_epoch)
		or next_display.generation ~= s.generation
		or next_display.preview_generation ~= s.preview_generation
	then
		return "stale"
	end
	if not next_display.routing_win and (s.transitioning or s.router and s.router.busy()) then
		s.deferred_display = next_display
		return "deferred"
	end
	local before = {
		left = s.left,
		right = s.right,
		mode = s.mode,
		result = s.preview_result,
		item = s.shown_item,
		stamp = s.preview_stamp,
		text_views = s.text_views,
		display = s.display,
		navigation = s.navigation,
		intent = s.navigation_intent,
		left_label = s.left_label,
		right_label = s.right_label,
		views = { capture(s.leftwin), capture(s.rightwin) },
		worktree = s.worktree,
	}
	local borrowed = {}
	for _, win in ipairs({ s.leftwin, s.rightwin }) do
		local buf = vim.api.nvim_win_get_buf(win)
		if not buffers.is_managed(buf) and borrowed[buf] == nil then
			borrowed[buf] = vim.bo[buf].bufhidden
			vim.bo[buf].bufhidden = "hide"
		end
	end
	local acquired_worktree
	local presentation = {}
	for _, buf in ipairs({ s.message_left, s.message_right }) do
		presentation[buf] = { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), ft = vim.bo[buf].filetype }
	end
	local function check()
		assert(panes_usable(s, next_display.pane_epoch), "Comparison panes changed during installation")
	end
	s.transitioning, s.swapping = true, (s.swapping or 0) + 1
	local ok, err = pcall(function()
		check()
		if next_display.routing_win then
			local win = next_display.routing_win
			local buf = win == s.sidewin and s.sidebar or win == s.leftwin and s.left or s.right
			show_slot(s, win, buf)
			check()
			assert(vim.api.nvim_win_get_buf(win) == buf, "Comparison restoration was redirected")
			if win == s.sidewin then
				sidebar_options(s)
				view.labels(s)
			else
				preview_options(s, win)
				set_label(win, win == s.leftwin and s.left_label or s.right_label, buf)
			end
			bind(s, buf)
			if s.mode == "text" then
				vim.api.nvim_win_call(s.leftwin, function()
					vim.cmd("diffupdate")
				end)
			end
			local saved = next_display.views or {}
			for index, pane in ipairs({ s.leftwin, s.rightwin, s.sidewin }) do
				if vim.api.nvim_win_get_buf(pane) == ({ s.left, s.right, s.sidebar })[index] then
					restore(pane, saved[index])
				end
			end
			return
		end
		local d = next_display
		local left, right = s.message_left, s.message_right
		local result, item = d.result, d.item
		local text_views = d.text_views
		if d.mode == "metadata" and s.mode == "text" then
			text_views = { capture(s.leftwin), capture(s.rightwin) }
		end
		for _, win in ipairs({ s.leftwin, s.rightwin }) do
			highlighting.release(win)
			if owns_shown(s, win) then
				util.diff_off(win)
			end
		end
		local next_worktree
		if
			d.mode == "text"
			and result
			and not (item.kind == "dir" or item.property_only or result.right_label == "SUBMODULE / DIRECTORY")
		then
			next_worktree = worktree.acquire(s, item, result, function(kind, record)
				worktree_event(s, kind, record)
			end)
			acquired_worktree = next_worktree
			if next_worktree then
				result = assert(worktree.result(next_worktree, result))
			end
			local pair = buffers.store(s, item, next_worktree and result or result.disk_result or result)
			left, right = pair.left, next_worktree and next_worktree.buf or pair.right
		end
		for _, slot in ipairs({ { s.leftwin, left }, { s.rightwin, right } }) do
			release_pane_buffer(s, slot[1], slot[2])
			show_slot(s, slot[1], slot[2])
			check()
			assert(vim.api.nvim_win_get_buf(slot[1]) == slot[2], "Comparison installation was redirected")
		end
		check()
		if left == s.message_left then
			write(left, d.left or {})
			write(right, d.right or {})
			vim.bo[left].filetype, vim.bo[right].filetype = d.left_ft or "", d.right_ft or ""
			check()
		end
		s.worktree = next_worktree
		if next_worktree then
			local current = worktree.capture(next_worktree)
			if current then
				result = assert(worktree.result(next_worktree, result, current))
				local pair = buffers.store(s, item, result)
				if left ~= pair.left then
					left = pair.left
					show_slot(s, s.leftwin, left)
					check()
				end
				d.right_label = (vim.bo[right].modified and "WORKTREE (unsaved)" or "WORKTREE") .. " | " .. item.relpath
			end
		end
		s.left, s.right, s.mode = left, right, d.mode
		s.preview_result, s.shown_item, s.preview_stamp, s.text_views = result, item, d.stamp, text_views
		if not d.keep_labels then
			labels(s, d.left_label or "", d.right_label or "")
		end
		preview_options(s, s.leftwin)
		preview_options(s, s.rightwin)
		bind(s, left)
		bind(s, right)
		if d.mode == "text" then
			vim.api.nvim_win_call(s.leftwin, function()
				vim.cmd("diffupdate")
			end)
			if s.text_views then
				restore(s.leftwin, s.text_views[1])
				restore(s.rightwin, s.text_views[2])
				s.text_views = nil
			end
		end
		check()
		s.display = d
		local documents = result and { result.left_document, result.right_document }
		local changed_documents = d.mode == "text"
			and s.navigation
			and not vim.deep_equal(s.navigation.documents, documents)
		if d.load_navigation or changed_documents then
			if changed_documents and s.file_views then
				s.file_views[item.relpath] = nil
			end
			navigation.load(s, result, item)
			local remembered = s.file_views and s.file_views[item.relpath]
			if
				remembered
				and (not result.loaded or result.loaded.text)
				and remembered.profile_key ~= result.profile_key
			then
				s.file_views[item.relpath], remembered = nil, nil
				d.saved_views, d.saved_reviewed = nil, nil
			end
			if not d.saved_views and remembered and remembered.old_path == item.old_path then
				if s.mode == "metadata" then
					s.text_views = vim.deepcopy(remembered.views)
				else
					restore(s.leftwin, remembered.views[1])
					restore(s.rightwin, remembered.views[2])
				end
				navigation.restore(s, remembered, d.stamp)
			end
			if d.saved_views and s.mode == "text" then
				restore(s.leftwin, d.saved_views[1])
				restore(s.rightwin, d.saved_views[2])
				if remembered then
					navigation.restore(s, remembered, d.stamp)
				end
			end
			if (d.saved_views and s.mode == "text") or d.saved_reviewed ~= nil then
				s.navigation.reviewed = d.saved_reviewed == true
			end
		end
		view.marker(s)
		buffers.trim(s)
		worktree.trim_jumps(s)
	end)
	if not ok then
		local rolled_back = pcall(function()
			check()
			for _, slot in ipairs({ { s.leftwin, before.left }, { s.rightwin, before.right } }) do
				release_pane_buffer(s, slot[1], slot[2])
				show_slot(s, slot[1], slot[2])
				check()
				assert(vim.api.nvim_win_get_buf(slot[1]) == slot[2], "Comparison rollback was redirected")
			end
			local previous_pair = before.item and s.buffer_cache.pairs[before.item.relpath]
			if
				before.result
				and previous_pair
				and previous_pair.left == before.left
				and previous_pair.right == before.right
			then
				buffers.store(s, before.item, before.result)
			end
			for buf, value in pairs(presentation) do
				write(buf, value.lines)
				vim.bo[buf].filetype = value.ft
			end
			s.worktree = before.worktree
			s.left, s.right, s.mode = before.left, before.right, before.mode
			s.preview_result, s.shown_item, s.preview_stamp = before.result, before.item, before.stamp
			s.text_views, s.display = before.text_views, before.display
			s.navigation, s.navigation_intent = before.navigation, before.intent
			s.left_label, s.right_label = before.left_label, before.right_label
			set_label(s.leftwin, before.left_label, s.left)
			set_label(s.rightwin, before.right_label, s.right)
			preview_options(s, s.leftwin)
			preview_options(s, s.rightwin)
			restore(s.leftwin, before.views[1])
			restore(s.rightwin, before.views[2])
		end)
		if not rolled_back then
			invalidate_panes(s)
			s.preview_result, s.mode = nil, "message"
			schedule(function()
				local closed, close_err = pcall(M.close, s)
				if not closed then
					util.notify(tostring(close_err):gsub("%s+", " "), vim.log.levels.ERROR)
				end
			end)
		end
	end
	for buf, hidden in pairs(borrowed) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].bufhidden == "hide" then
			vim.bo[buf].bufhidden = hidden
		end
	end
	if ok then
		if before.worktree ~= s.worktree then
			worktree.release(s, before.worktree)
		end
	elseif acquired_worktree and acquired_worktree ~= before.worktree then
		worktree.release(s, acquired_worktree)
	end
	s.transitioning, s.swapping = false, s.swapping - 1
	if not ok then
		util.notify("Could not update comparison: " .. tostring(err):gsub("%s+", " "), vim.log.levels.ERROR)
		return "stale", tostring(err)
	end
	if next_display.load_navigation then
		s.navigation_intent = next_display.intent
		navigation.complete(s, next_display.intent)
	end
	if s.deferred_display and not s.pending_transition then
		s.pending_transition = true
		schedule(function()
			s.pending_transition = false
			if s.closed or not s.deferred_display then
				return
			end
			if not s.transitioning and (not s.router or not s.router.busy()) then
				local deferred = s.deferred_display
				s.deferred_display = nil
				if deferred then
					set_panes(s, deferred)
				end
			end
		end)
	end
	return "installed"
end

local function failure(s, err)
	navigation.cancel(s)
	s.navigation = nil
	message(s, "Comparison unavailable")
	set_panes(
		s,
		pane_request(s, {
			mode = "message",
			left_label = "Comparison unavailable",
			right_label = "Recovery",
			left = util.split_text_lines(tostring(err)),
			right = s.context and {
				":LazyVCS compare base: choose another base",
				":LazyVCS compare refresh: retry",
				":LazyVCS compare close: close",
			} or { ":LazyVCS compare refresh: retry", ":LazyVCS compare close: close" },
		})
	)
end
local function file_stamp(path)
	local stat = vim.uv.fs_lstat(path)
	return stat and table.concat({ stat.type, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.mode }, ":") or "missing"
end
local function result_display(s, result, item, mode)
	local d =
		{ mode = mode or "text", result = result, item = item, text_views = s.text_views, stamp = s.preview_stamp }
	if d.mode == "metadata" then
		d.left = result.properties or result.details or { "No metadata or property changes for this path." }
		if result.properties and result.details then
			d.left = vim.list_extend(vim.deepcopy(result.details), result.properties)
		end
		d.right = { ":LazyVCS compare metadata: return to text" }
		d.left_ft = result.properties and "diff" or ""
		d.left_label, d.right_label = "METADATA / PROPERTIES: " .. item.relpath, "Return to text"
	else
		d.left, d.right, d.left_ft = result.left, result.right, "diff"
		d.left_label = result.left_label .. " | " .. (item.old_path or item.relpath)
		d.right_label = result.right_label .. " | " .. item.relpath
	end
	return pane_request(s, d)
end
local preview
local function show_result(s, mode)
	if s.preview_result and s.shown_item then
		if mode == "text" and s.preview_result.loaded and not s.preview_result.loaded.text then
			return preview(s, s.shown_item, "text")
		end
		set_panes(s, result_display(s, s.preview_result, s.shown_item, mode))
	end
end
preview = function(s, item, mode, saved_views, intent, saved_reviewed)
	item = item or selected(s)
	if not item or not s.snapshot then
		return
	end
	navigation.remember(s)
	s.preview_generation = (s.preview_generation or 0) + 1
	cancel(s, "preview_job")
	navigation.cancel(s)
	s.navigation, s.preview_mode = nil, mode or "text"
	local generation, epoch = s.preview_generation, s.pane_epoch or 0
	if s.worktree_deleted ~= item.relpath then
		s.worktree_deleted = nil
	end
	local path = s.root .. "/" .. item.relpath
	local stamp = file_stamp(path)
	set_panes(
		s,
		pane_request(s, {
			mode = "message",
			item = item,
			left_label = "Loading: " .. item.relpath,
			right_label = "SAVED WORKTREE",
			left = { "Loading " .. display(item.relpath) .. "..." },
			right = {},
		})
	)
	s.navigation_intent = intent
	s.preview_job = s.provider.preview(s.snapshot, item, function(result, err)
		if not panes_usable(s, epoch) or generation ~= s.preview_generation then
			return
		end
		s.preview_job = nil
		if result and (not result.loaded or result.loaded.text) and stamp ~= file_stamp(path) then
			result, err = nil, "File changed during preview; use :LazyVCS compare refresh"
		end
		if not result then
			navigation.cancel(s)
			set_panes(
				s,
				pane_request(s, {
					mode = "message",
					item = item,
					left_label = "Preview unavailable: " .. item.relpath,
					right_label = "SAVED WORKTREE",
					left = vim.list_extend({ "Preview unavailable" }, util.split_text_lines(tostring(err))),
					right = {},
				})
			)
			return
		end
		if s.preview_mode == "text" and result.loaded and not result.loaded.text then
			return preview(s, item, "text", saved_views, s.navigation_intent, saved_reviewed)
		end
		local d = result_display(s, result, item, s.preview_mode)
		d.stamp, d.load_navigation, d.intent = stamp, true, s.navigation_intent
		d.saved_views, d.saved_reviewed = saved_views, saved_reviewed
		s.navigation_intent = nil
		set_panes(s, d)
	end, { mode = mode or "text", editable = s.editable })
end
local function update_worktree(s, record)
	if not alive(s) or s.worktree ~= record or s.mode ~= "text" or not s.preview_result then
		return
	end
	if record.unloading then
		return
	end
	local current = worktree.capture(record)
	if not current then
		return worktree_event(s, "deleted", record)
	end
	local result = assert(worktree.result(record, s.preview_result, current))
	if result.profile_key ~= s.preview_result.profile_key then
		if set_panes(s, result_display(s, result, s.shown_item, "text")) ~= "installed" then
			return
		end
		result = s.preview_result
	end
	s.preview_result = result
	-- Clear stale navigation immediately. A single worker coalesces subsequent
	-- edits, so neither VCS subprocesses nor histogram diff block each keystroke.
	s.navigation = { base = {}, saved = {}, reviewed = false }
	s.worktree_diff = s.worktree_diff or require("lazyvcs.diff_work").latest()
	local tick, item, version = vim.api.nvim_buf_get_changedtick(record.buf), s.shown_item, record.version
	local text = require("lazyvcs.compare_text")
	s.worktree_diff:request(text.serialize(result.left_document), text.serialize(current), function(raw, failure)
		if
			not alive(s)
			or s.worktree ~= record
			or s.preview_result ~= result
			or record.version ~= version
			or not vim.api.nvim_buf_is_valid(record.buf)
			or vim.api.nvim_buf_get_changedtick(record.buf) ~= tick
		then
			return
		end
		if not raw then
			return util.notify(failure or "Could not update comparison hunks", vim.log.levels.WARN)
		end
		local hunks = require("lazyvcs.diff").text_hunks(raw, result.left_document, current)
		navigation.load(s, result, item, hunks)
	end)
	labels(
		s,
		result.left_label .. " | " .. (s.shown_item.old_path or s.shown_item.relpath),
		(vim.bo[record.buf].modified and "WORKTREE (unsaved)" or "WORKTREE") .. " | " .. s.shown_item.relpath
	)
end

local function refresh_worktree_list(s, record)
	if not s.snapshot then
		return
	end
	cancel(s, "worktree_list_job")
	local snapshot, generation = s.snapshot, s.generation
	s.worktree_list_generation = (s.worktree_list_generation or 0) + 1
	local request = s.worktree_list_generation
	s.worktree_list_job = s.provider.list(snapshot, s.include_untracked, function(items, err)
		if s.worktree_list_generation ~= request then
			return
		end
		s.worktree_list_job = nil
		if not alive(s) or s.snapshot ~= snapshot or s.generation ~= generation then
			return
		end
		if not items then
			return util.notify(err or "Could not refresh comparison files", vim.log.levels.WARN)
		end
		local chosen = selected(s)
		s.items = items
		buffers.reconcile(s, snapshot, items)
		navigation.reconcile(s, snapshot, items)
		local added, deleted = 0, 0
		for _, item in ipairs(items) do
			added, deleted = added + (item.added or 0), deleted + (item.deleted or 0)
		end
		message(s, #items == 0 and "No saved changes" or string.format("%d paths +%d -%d", #items, added, deleted))
		if chosen and s.row_by_path[chosen.relpath] and sidebar_shown(s) then
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[chosen.relpath], 0 })
		end
		view.marker(s)
		update_worktree(s, record)
	end)
end

worktree_event = function(s, kind, record)
	if not alive(s) or s.worktree ~= record then
		return
	end
	if kind == "unloading" then
		s.navigation = nil
		return
	end
	if kind == "deleted" then
		local item = s.shown_item
		if not item then
			return
		end
		if not valid(s.rightwin) then
			if not valid(s.sidewin) or not valid(s.leftwin) then
				return M.close(s)
			end
			local focused = vim.api.nvim_get_current_win()
			s.swapping = (s.swapping or 0) + 1
			vim.api.nvim_win_call(s.leftwin, function()
				vim.cmd(s.stacked and "rightbelow split" or "rightbelow vsplit")
				s.rightwin = vim.api.nvim_get_current_win()
				s.right = s.message_right
				util.show_win_buffer(s.rightwin, s.right)
			end)
			s.swapping = s.swapping - 1
			s.panes_invalid = nil
			if valid(focused) then
				vim.api.nvim_set_current_win(focused)
			end
		end
		-- Buffer-removal plugins may preserve the pane by showing an alternate.
		-- Accept that settled destination before loading the snapshot, so the
		-- picker router cannot defer recovery behind its own obsolete request.
		if s.router then
			s.router.cancel()
		end
		s.right = vim.api.nvim_win_get_buf(s.rightwin)
		s.worktree_deleted = item.relpath
		s.worktree = nil
		worktree.release(s, record)
		preview(s, item, "text")
		resize(s)
		return
	end
	if kind == "reloaded" then
		-- A native reload invalidates both text bindings and encoding metadata.
		record.retained = true
		local views = { capture(s.leftwin), capture(s.rightwin) }
		return preview(s, s.shown_item, "text", views)
	end
	if kind == "saved" then
		update_worktree(s, record)
		refresh_worktree_list(s, record)
	else
		if s.mode == "text" then
			s.navigation = { base = {}, saved = {}, reviewed = false }
		end
		s.worktree_update_record = record
		if s.worktree_update_pending then
			return
		end
		s.worktree_update_pending = true
		vim.defer_fn(
			protected(function()
				s.worktree_update_pending = false
				local latest = s.worktree_update_record
				s.worktree_update_record = nil
				update_worktree(s, latest)
			end),
			config.get().debounce_ms
		)
	end
end

local function request_preview(s, kind)
	local item = vim.api.nvim_get_current_win() == s.sidewin and selected(s) or s.shown_item
	navigation.cancel(s)
	if not item then
		return
	end
	local intent = kind ~= "preview" and navigation.intent(s, item, kind) or nil
	if s.worktree_deleted == item.relpath and kind == "review" then
		s.worktree_deleted = nil
		return preview(s, item, "text", nil, intent)
	end
	if item == s.shown_item and s.preview_result then
		if s.preview_result.loaded and not s.preview_result.loaded.text then
			preview(s, item, "text", nil, intent)
			return true
		end
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
		s.worktree_deleted = nil
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
	local generation, epoch = s.generation, s.pane_epoch or 0
	if not s.provider then
		if s.resolution_failed then
			backends.invalidate()
		end
		message(s, "Finding repository...")
		s.job = backends.resolve_async(s.path, function(backend, root, err)
			if not panes_usable(s, epoch) or generation ~= s.generation then
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
				if s.explicit_editable ~= nil then
					other.editable = s.explicit_editable
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
			if not panes_usable(s, epoch) or generation ~= s.generation then
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
	s.items, s.snapshot, s.uncounted = {}, nil, nil
	message(s, "Loading saved changes...")
	set_panes(
		s,
		pane_request(s, {
			mode = "message",
			left = {},
			right = {},
			keep_labels = true,
		})
	)
	s.job = s.provider.resolve(s, s.base, function(snapshot, err)
		if not panes_usable(s, epoch) or generation ~= s.generation then
			return
		end
		if not snapshot then
			s.job = nil
			return failure(s, err)
		end
		s.job = s.provider.list(snapshot, s.include_untracked, function(items, list_err)
			if not panes_usable(s, epoch) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not items then
				return failure(s, list_err)
			end
			local paths = {}
			for _, item in ipairs(items) do
				if paths[item.relpath] then
					return failure(s, "Duplicate comparison path: " .. display(item.relpath))
				end
				paths[item.relpath] = true
			end
			buffers.reconcile(s, snapshot, items)
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
				if sidebar_shown(s) then
					vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
					if saved and saved.side then
						saved.side.lnum = s.row_by_path[item.relpath]
						restore(s.sidewin, saved.side)
					end
				end
				local shown = saved and saved.shown and s.rows_cache.by_path[saved.shown]
				preview(s, shown and items[shown] or item, "text", saved and saved.views, nil, saved and saved.reviewed)
			else
				set_panes(
					s,
					pane_request(s, {
						mode = "message",
						left = {},
						right = {},
						left_label = "No saved changes",
						right_label = "SAVED WORKTREE",
					})
				)
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
		if s.preview_result and s.preview_result.loaded and not s.preview_result.loaded.text then
			preview(
				s,
				s.shown_item,
				"text",
				nil,
				navigation.intent(s, s.shown_item, direction == "next" and "first" or "last")
			)
			return true
		end
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
	if
		s.mode == "text"
		and (
			buffers.resource(vim.api.nvim_get_current_buf())
			or (
				s.worktree
				and vim.api.nvim_get_current_win() == s.rightwin
				and vim.api.nvim_get_current_buf() == s.worktree.buf
			)
		)
	then
		vim.cmd("normal! m'")
	end
	if sidebar_shown(s) then
		vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
	end
	local intent = navigation.intent(s, item, "file")
	if item == s.shown_item and s.preview_result then
		if s.preview_result.loaded and not s.preview_result.loaded.text then
			preview(s, item, "text", nil, intent)
			return true
		end
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
	if valid(win) and vim.api.nvim_win_get_tabpage(win) ~= s.tab and (not editing or editor_window(win)) then
		return win
	end
	if s.origin_tab ~= s.tab and vim.api.nvim_tabpage_is_valid(s.origin_tab) then
		for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(s.origin_tab)) do
			if editor_window(candidate) then
				s.origin_edit_win = candidate
				return candidate
			end
		end
	end
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if tab ~= s.tab and not sessions[tab] then
			for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
				if editor_window(candidate) then
					s.origin_edit_win = candidate
					return candidate
				end
			end
		end
	end
	vim.cmd("tab split")
	util.editor_window(vim.api.nvim_get_current_win())
	util.show_win_buffer(vim.api.nvim_get_current_win(), buf or vim.api.nvim_create_buf(true, false))
	util.editor_window(vim.api.nvim_get_current_win())
	s.origin_tab = vim.api.nvim_get_current_tabpage()
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
	require("lazyvcs.window_controls").unregister(s)
	invalidate_panes(s)
	if s.router then
		s.router.cancel()
	end
	s.deferred_display = nil
	navigation.cancel(s)
	highlighting.release(s.leftwin)
	highlighting.release(s.rightwin)
	cancel(s, "job")
	cancel(s, "preview_job")
	cancel(s, "worktree_list_job")
	if s.worktree_diff then
		s.worktree_diff:close()
	end
	sessions[s.tab] = nil
	if s.augroup then
		vim.api.nvim_del_augroup_by_id(s.augroup)
	end
	if valid(s.helpwin) then
		vim.api.nvim_win_close(s.helpwin, true)
	end
	local borrowed = {}
	-- A session loaded from the Compare tab replaces Compare's windows with its
	-- own. That tab belongs to the session now: leave its windows and keep it.
	local replaced = s.session_replaced and vim.api.nvim_tabpage_is_valid(s.tab)
	if replaced then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(s.tab)) do
			vim.w[win].lazyvcs_compare = nil
		end
	end
	if vim.api.nvim_tabpage_is_valid(s.tab) and not replaced then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(s.tab)) do
			-- Reset only the panes, and only a buffer they hold Compare state for.
			-- Other windows in this tab, and a picker preview in a pane, keep
			-- their own options.
			if win == s.leftwin or win == s.rightwin then
				release_pane_buffer(s, win)
			end
			local buf = vim.api.nvim_win_get_buf(win)
			if not buffers.is_managed(buf) and vim.bo[buf].modified then
				borrowed[buf] = borrowed[buf] or vim.bo[buf].bufhidden
				vim.bo[buf].bufhidden = "hide"
			end
		end
	end
	if vim.api.nvim_tabpage_is_valid(s.tab) and not replaced then
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
	for buf, hidden in pairs(borrowed) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].bufhidden = hidden
		end
	end
	worktree.release(s, s.worktree)
	worktree.trim_jumps(s, true)
	s.worktree = nil
	buffers.close(s)
	if vim.api.nvim_buf_is_valid(s.sidebar) then
		vim.api.nvim_buf_delete(s.sidebar, { force = true })
	end
	if return_focus ~= false and not replaced and valid(s.origin_win) then
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
		vim.cmd("rightbelow split")
		s.origin_edit_win = vim.api.nvim_get_current_win()
		util.editor_window(s.origin_edit_win)
	end
	-- Neovim gives a window without its own option record for the buffer the
	-- live pane's options: diff mode, bindings, and the Compare label. Undo only
	-- those. A window that already shows the buffer, a window whose own record
	-- has a diff, and a live diff's window keep their diff.
	local editor = vim.api.nvim_get_current_win()
	local before, copied
	if vim.api.nvim_win_get_buf(editor) ~= buf and not require("lazyvcs.state").for_window(editor) then
		before = util.capture_win_options(editor, { "diff", "scrollbind", "cursorbind" })
		-- Any Compare session's live pane can be the source.
		local panes = {}
		for _, session in pairs(sessions) do
			if alive(session) then
				vim.list_extend(panes, { session.leftwin, session.rightwin })
			end
		end
		copied = worktree.copies_pane(editor, buf, panes)
	end
	vim.api.nvim_win_set_buf(editor, buf)
	-- An autocommand may have shown another buffer; its options are its own.
	if valid(editor) and vim.api.nvim_win_get_buf(editor) == buf then
		if before then
			worktree.reset_editor(editor, before, copied)
		end
		worktree.reset_label(editor)
	end
	if position then
		local line = math.min(position[1], vim.api.nvim_buf_line_count(buf))
		local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
		vim.api.nvim_win_set_cursor(0, { line, math.min(position[2], #text) })
	end
end
local function map_position(from, to, position)
	local line, column = position[1], position[2]
	local delta = 0
	for _, hunk in ipairs(require("lazyvcs.diff").compute_hunks(from, to)) do
		if hunk.base_count > 0 and line >= hunk.base_start and line < hunk.base_start + hunk.base_count then
			return { math.max(1, hunk.current_start), 0 }
		end
		local finish = hunk.base_count == 0 and hunk.base_start or hunk.base_start + hunk.base_count - 1
		if line > finish then
			delta = delta + hunk.current_count - hunk.base_count
		end
	end
	return { math.max(1, line + delta), column }
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
	local buf = -1
	do
		local resolved = util.canonical_path(path)
		for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
			if
				util.is_real_file_buffer(candidate)
				and util.canonical_path(vim.api.nvim_buf_get_name(candidate)) == resolved
			then
				buf = candidate
				break
			end
		end
	end
	buf = buf < 0 and vim.fn.bufadd(path) or buf
	vim.bo[buf].buflisted = true
	vim.fn.bufload(buf)
	local position = { 1, 0 }
	local win = vim.api.nvim_get_current_win()
	if s.mode == "text" and s.preview_result and (win == s.leftwin or win == s.rightwin) then
		position = vim.api.nvim_win_get_cursor(win)
		local saved = s.preview_result.right
		if win == s.leftwin then
			position = map_position(s.preview_result.left, saved, position)
		end
		if vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) <= common.max_file_bytes then
			position = map_position(saved, vim.api.nvim_buf_get_lines(buf, 0, -1, false), position)
		else
			util.notify("Large editing buffer: review position is clamped to its line count", vim.log.levels.INFO)
		end
	end
	edit_buffer(s, buf, position)
end
local function help(s)
	if valid(s.helpwin) then
		vim.api.nvim_win_close(s.helpwin, true)
		return
	end
	local lines = { "Comparison help", "", "File list:" }
	for _, action in ipairs(catalog) do
		if action.key then
			lines[#lines + 1] = action.key .. ": " .. action.description
		end
	end
	vim.list_extend(lines, {
		"",
		s.worktree and "Text panes use normal Vim keys; the right pane edits the real file."
			or "Text panes use normal Vim keys; both panes are read-only snapshots.",
		s.worktree and "Use :write to save. Edited buffers survive closing Compare."
			or "Save editing buffers before refreshing to include their changes.",
		"File search opens your editing buffer; the list selects a review.",
		"Commands: :LazyVCS compare metadata / width / base / refresh / close",
	})
	local opts = config.get()
	if opts.session_keymaps then
		for name, key in pairs(opts.compare.keymaps) do
			if key then
				lines[#lines + 1] = key .. ": " .. name
			end
		end
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
	util.unbind_window(s.helpwin)
	vim.w[s.helpwin].lazyvcs_compare = true
	for _, key in ipairs({ "q", "?", "<Esc>" }) do
		compat.keymap_set("n", key, function()
			if valid(s.helpwin) then
				vim.api.nvim_win_close(s.helpwin, true)
			end
		end, { buffer = buf, silent = true })
	end
	local helpwin = s.helpwin
	autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			schedule(function()
				if valid(helpwin) then
					vim.api.nvim_win_close(helpwin, true)
				end
			end)
		end,
	})
end
local function construct_session(s)
	local width, stacked, err = view.layout(vim.o.columns, s.manual_width, false, 0, layout_constraints())
	if err then
		error(err)
	end
	s.sidebar = buffers.scratch(s)
	buffers.init(s)
	local previous_tabs = {}
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		previous_tabs[tab] = true
	end
	local opened, open_err = pcall(function()
		vim.cmd("tab split")
	end)
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if not previous_tabs[tab] then
			s.tab = tab
			break
		end
	end
	if not opened then
		error(open_err)
	end
	if not s.tab or vim.api.nvim_get_current_tabpage() ~= s.tab then
		error("Comparison tab changed while opening")
	end
	s.sidewin = vim.api.nvim_get_current_win()
	util.show_win_buffer(s.sidewin, s.sidebar)
	for label, buf in pairs({ files = s.sidebar, base = s.left, saved = s.right }) do
		vim.api.nvim_buf_set_name(buf, "lazyvcs://compare/" .. s.buffer_id .. "/" .. label)
	end
	util.set_win_option(0, "winfixbuf", false)
	vim.cmd("rightbelow vsplit")
	s.leftwin = vim.api.nvim_get_current_win()
	util.show_win_buffer(s.leftwin, s.left)
	vim.api.nvim_win_set_width(s.sidewin, width)
	vim.cmd(stacked and "rightbelow split" or "rightbelow vsplit")
	s.rightwin, s.stacked = vim.api.nvim_get_current_win(), stacked
	util.show_win_buffer(s.rightwin, s.right)
	preview_options(s, s.leftwin)
	preview_options(s, s.rightwin)
	vim.bo[s.sidebar].filetype = "lazyvcs-comparison"
	sidebar_options(s)
	sessions[s.tab] = s
	resize(s)
	s.actions = {
		review = function()
			request_preview(s, "review")
		end,
		preview = function()
			request_preview(s, "preview")
		end,
		edit = function()
			edit(s)
		end,
		files = function()
			navigation.cancel(s)
			vim.api.nvim_set_current_win(s.sidewin)
		end,
		close = function()
			M.close(s)
		end,
		refresh = function()
			M.refresh(s)
		end,
		base = function()
			if s.context then
				choose_base(s)
			end
		end,
		help = function()
			help(s)
		end,
		metadata = function()
			navigation.cancel(s)
			local item = target(s)
			if s.preview_result and item == s.shown_item then
				show_result(s, s.mode == "metadata" and "text" or "metadata")
			else
				preview(s, item, "metadata")
			end
		end,
		width = function()
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
	}
	s.keymaps, s.pane_mappings = {}, {}
	local sidebar_mappings, opts = {}, config.get()
	for _, action in ipairs(catalog) do
		local callback = function()
			local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
			if
				not s.closed
				and (
					(win == s.sidewin and buf == s.sidebar)
					or (win == s.leftwin and buf == s.left)
					or (win == s.rightwin and buf == s.right)
				)
			then
				s.actions[action.name]()
			end
		end
		if action.key then
			sidebar_mappings[#sidebar_mappings + 1] =
				{ key = action.key, callback = callback, nowait = true, desc = "lazyvcs " .. action.description }
		end
		local key = opts.compare.keymaps[action.name]
		if opts.session_keymaps and key then
			s.pane_mappings[#s.pane_mappings + 1] =
				{ key = key, callback = callback, desc = "lazyvcs " .. action.description }
		end
	end
	if opts.session_keymaps then
		for _, mapping in ipairs({
			{ opts.keymaps.next_file, "next", "file" },
			{ opts.keymaps.prev_file, "prev", "file" },
			{ opts.keymaps.next_hunk, "next", "hunk" },
			{ opts.keymaps.prev_hunk, "previous", "hunk" },
		}) do
			if mapping[1] then
				local definition = {
					key = mapping[1],
					callback = function()
						if mapping[3] == "file" then
							M.navigate_file(mapping[2], vim.v.count1)
						else
							M.jump_to_hunk(mapping[2])
						end
					end,
					desc = "lazyvcs " .. mapping[2] .. " comparison " .. mapping[3],
				}
				s.pane_mappings[#s.pane_mappings + 1] = definition
				sidebar_mappings[#sidebar_mappings + 1] = definition
			end
		end
	end
	s.keymaps[s.sidebar], s.keymaps[s.left], s.keymaps[s.right] = sidebar_mappings, s.pane_mappings, s.pane_mappings
	require("lazyvcs.window_controls").register(s, function(win, buf)
		if not s.closed then
			if win == s.sidewin and buf == s.sidebar then
				return sidebar_mappings
			end
			if (win == s.leftwin and buf == s.left) or (win == s.rightwin and buf == s.right) then
				return s.pane_mappings
			end
		end
	end, 20)
	for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
		bind(s, buf)
	end
	compat.keymap_set("n", "<2-LeftMouse>", s.actions.review, { buffer = s.sidebar, silent = true })
	s.select_snapshot = function(resource, position)
		local index = s.rows_cache and s.rows_cache.by_path[resource.pair.path]
		if not index then
			return
		end
		local item = s.items[index]
		if sidebar_shown(s) then
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[item.relpath], 0 })
		end
		local intent = navigation.intent(s, item, "native")
		intent.position, intent.side = position, resource.side
		preview(s, item, "text", nil, intent)
	end
	s.reload = function(resource)
		local pair = resource.pair
		local index = s.rows_cache and s.rows_cache.by_path[pair.path]
		if not index then
			return
		end
		if not s.snapshot or not s.items[index] then
			return util.notify("Comparison is refreshing; the snapshot is unchanged", vim.log.levels.INFO)
		end
		if pair.reload_job then
			pair.reload_job:cancel()
		end
		local generation, item, version = s.generation, s.items[index], pair.version
		local preview_generation = s.preview_generation
		local epoch = s.pane_epoch or 0
		local path = s.root .. "/" .. item.relpath
		local stamp = file_stamp(path)
		pair.reload_generation = (pair.reload_generation or 0) + 1
		local reload_generation = pair.reload_generation
		pair.reload_job = s.provider.preview(s.snapshot, item, function(result, err)
			if pair.reload_generation ~= reload_generation then
				return
			end
			pair.reload_job = nil
			if not panes_usable(s, epoch) or s.generation ~= generation or s.buffer_cache.pairs[pair.path] ~= pair then
				return
			end
			local ok, update_err = pcall(function()
				if pair.version ~= version then
					buffers.trim(s)
					return
				end
				if result and stamp ~= file_stamp(path) then
					result, err = nil, "File changed during reload; use :LazyVCS compare refresh"
				end
				if result then
					if
						not (
							s.preview_result
							and s.shown_item
							and s.shown_item.relpath == item.relpath
							and s.mode == "text"
						)
					then
						buffers.store(s, item, result)
					end
					if
						preview_generation == s.preview_generation
						and s.display
						and s.display.preview_generation == preview_generation
						and s.preview_result
						and s.shown_item
						and s.shown_item.relpath == item.relpath
					then
						local reviewed = s.navigation and s.navigation.reviewed
						local d = result_display(s, result, item, s.mode)
						d.stamp, d.load_navigation = stamp, true
						d.saved_views = { capture(s.leftwin), capture(s.rightwin) }
						d.saved_reviewed = reviewed
						set_panes(s, d)
					end
				else
					util.notify(err, vim.log.levels.WARN)
				end
				buffers.trim(s)
			end)
			if not ok then
				util.notify(tostring(update_err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
			end
		end)
	end
	s.augroup = vim.api.nvim_create_augroup("lazyvcs_compare_" .. s.tab, { clear = true })
	s.router = require("lazyvcs.compare_open").setup(s, {
		remember = navigation.remember,
		restore = function(win, views)
			local status = set_panes(s, pane_request(s, { routing_win = win, views = views }))
			if status == "installed" then
				resize(s)
			end
			return status
		end,
		-- A slot got its own buffer back from a picker without a routing restore.
		-- Its window record holds the labels from before the picker opened.
		relabel = function()
			set_label(s.leftwin, s.left_label, s.left)
			set_label(s.rightwin, s.right_label, s.right)
			view.labels(s)
		end,
		resume = function()
			local deferred = s.deferred_display
			s.deferred_display = nil
			if deferred then
				set_panes(s, deferred)
			end
			resize(s)
		end,
		snapshot = function(resource, position)
			local owner = resource.session
			if owner and alive(owner) then
				if owner ~= s then
					vim.api.nvim_set_current_tabpage(owner.tab)
					vim.api.nvim_set_current_win(resource.side == "base" and owner.leftwin or owner.rightwin)
				end
				owner.select_snapshot(resource, position)
			end
		end,
		jump = function(buf, position)
			local name = util.buf_path(buf)
			local path = name and util.relative_literal_path(s.root, name)
			if path and s.rows_cache and s.rows_cache.by_path[path] then
				s.select_snapshot({ pair = { path = path }, side = "saved" }, position)
				return true
			end
		end,
		edit = function(buf, position)
			edit_buffer(s, buf, position)
		end,
	})
	autocmd({ "WinLeave", "TabLeave", "CursorMoved" }, {
		group = s.augroup,
		callback = function(args)
			local intent = s.navigation_intent
			if intent and not s.resizing and (s.swapping or 0) == 0 then
				local item = selected(s)
				if
					args.event ~= "CursorMoved"
					or (vim.api.nvim_get_current_win() == s.sidewin and item ~= intent.item)
				then
					navigation.cancel(s)
				end
			end
		end,
	})
	autocmd("TabClosed", {
		group = s.augroup,
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(s.tab) then
				M.close(s, false)
			end
		end,
	})
	autocmd({ "VimResized", "TabEnter", "WinResized" }, {
		group = s.augroup,
		callback = function(args)
			resize(s, args.event == "WinResized")
		end,
	})
	-- A session sourced from this tab closes all but one of Compare's windows
	-- (:only) and edits its own files in the one that is left.
	autocmd("SessionLoadPost", {
		group = s.augroup,
		callback = function()
			local left = 0
			for _, win in ipairs({ s.sidewin, s.leftwin, s.rightwin }) do
				if valid(win) then
					left = left + 1
				end
			end
			if vim.api.nvim_tabpage_is_valid(s.tab) and left <= 1 then
				s.session_replaced = true
			end
		end,
	})
	autocmd("WinClosed", {
		group = s.augroup,
		callback = function(event)
			local win = tonumber(event.match)
			if win == s.sidewin or win == s.leftwin or win == s.rightwin then
				-- End owned pane state while the surviving panes still show their
				-- buffers. A session's :only closes siblings before hiding the last
				-- pane's file, when the router can no longer restore the layout.
				for _, pane in ipairs({ s.leftwin, s.rightwin }) do
					release_pane_buffer(s, pane)
				end
				local record = win == s.rightwin and s.worktree or nil
				invalidate_panes(s)
				schedule(function()
					if record and record.deleted and alive(s) and s.worktree == record then
						worktree_event(s, "deleted", record)
					elseif not valid(s.rightwin) or not valid(s.leftwin) or not valid(s.sidewin) then
						M.close(s)
					end
				end)
			end
		end,
	})
	vim.api.nvim_set_current_win(s.sidewin)
	M.refresh(s)
	return s
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
			if opts.editable ~= nil then
				existing.editable = opts.editable
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
		editable = opts.editable,
		explicit_editable = opts.editable,
		pane_epoch = 0,
		manual_width = math.min(38, math.max(20, math.floor(vim.o.columns / 4))),
	})

	if s.editable == nil then
		s.editable = config.get().compare.editable
	end
	local ok, result = pcall(construct_session, s)
	if ok then
		return result
	end
	s.closed = true
	require("lazyvcs.window_controls").unregister(s)
	for _, field in ipairs({ "job", "preview_job", "worktree_list_job" }) do
		pcall(cancel, s, field)
	end
	if s.router then
		pcall(s.router.cancel)
	end
	if s.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
	end
	if s.tab then
		sessions[s.tab] = nil
		if vim.api.nvim_tabpage_is_valid(s.tab) then
			pcall(function()
				vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(s.tab))
			end)
		end
	end
	for _, win in ipairs({ s.leftwin, s.rightwin }) do
		pcall(highlighting.release, win)
	end
	worktree.release(s, s.worktree)
	worktree.trim_jumps(s, true)
	buffers.abort(s)
	if valid(s.origin_win) then
		pcall(vim.api.nvim_set_current_win, s.origin_win)
	end
	util.notify("Could not open comparison: " .. tostring(result):gsub("%s+", " "), vim.log.levels.ERROR)
	return nil
end
function M.action(name)
	local found = false
	for _, action in ipairs(catalog) do
		if action.name == name and action.public then
			found = true
			break
		end
	end
	if not found then
		error("lazyvcs unknown comparison action: " .. tostring(name))
	end
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if not s or s.closed then
		return false
	end
	s.actions[name]()
	return true
end

function M.open(opts)
	opts = opts or {}
	if opts.editable ~= nil then
		vim.validate("compare editable", opts.editable, "boolean")
	end
	local existing = sessions[vim.api.nvim_get_current_tabpage()]
	if existing and (not opts.path or opts.path == existing.root or opts.path == existing.path) then
		if opts.base then
			existing.base, existing.explicit_base = opts.base, true
		end
		if opts.include_untracked ~= nil then
			existing.include_untracked = opts.include_untracked
		end
		if opts.editable ~= nil then
			existing.editable = opts.editable
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
	if s.worktree and buf == s.worktree.buf then
		return nil
	end
	local item, snapshot, result = s.shown_item, s.snapshot, s.preview_result
	local side = buf == s.left and "base" or "saved"
	local lines = side == "base" and result.left or result.right
	if
		#lines == 0
		or (item.kind == "dir" and not item.kind_before)
		or (side == "base" and item.kind_before == "dir")
		or (side == "saved" and item.kind_after == "dir")
		or item.property_only
		or result.right_label == "SUBMODULE / DIRECTORY"
	then
		return nil, "This preview has no file lines to blame"
	end
	return {
		path = s.root .. "/" .. item.relpath,
		snapshot = snapshot,
		item = item,
		side = side,
		bytes = side == "base" and result.left_bytes or result.right_bytes,
		text = side == "base" and result.left_document or result.right_document,
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
