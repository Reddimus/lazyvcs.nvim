local diff = require("lazyvcs.diff")
local util = require("lazyvcs.util")
local M = {}

local function panes_owned(s)
	for _, side in ipairs({ { s.leftwin, s.left }, { s.rightwin, s.right }, { s.sidewin, s.sidebar } }) do
		if
			not side[1]
			or not vim.api.nvim_win_is_valid(side[1])
			or vim.api.nvim_win_get_tabpage(side[1]) ~= s.tab
			or vim.api.nvim_win_get_buf(side[1]) ~= side[2]
		then
			return false
		end
	end
	return true
end

function M.owns(s)
	local win = vim.api.nvim_get_current_win()
	return s and not s.closed and (win == s.sidewin or win == s.leftwin or win == s.rightwin)
end

function M.cancel(s)
	s.navigation_intent = nil
end

function M.remember(s)
	if
		not s.preview_result
		or (s.preview_result.loaded and not s.preview_result.loaded.text)
		or not s.shown_item
		or not s.navigation
	then
		return
	end
	local views = s.text_views
		or {
			vim.api.nvim_win_call(s.leftwin, vim.fn.winsaveview),
			vim.api.nvim_win_call(s.rightwin, vim.fn.winsaveview),
		}
	s.file_views = s.file_views or {}
	s.file_views[s.shown_item.relpath] = {
		views = vim.deepcopy(views),
		reviewed = s.navigation.reviewed,
		index = s.navigation.index,
		positions = s.navigation.positions
			and { s.navigation.positions[s.leftwin], s.navigation.positions[s.rightwin] },
		stamp = s.preview_stamp,
		old_path = s.shown_item.old_path,
		profile_key = s.preview_result.profile_key,
	}
end

function M.reconcile(s, snapshot, items)
	local identity = { snapshot.vcs, snapshot.root, snapshot.revision, snapshot.url or "" }
	local changed = s.view_identity and not vim.deep_equal(s.view_identity, identity)
	s.view_identity = identity
	if changed then
		s.file_views = {}
		if s.restore then
			s.restore.views, s.restore.reviewed = nil, nil
		end
	else
		local retained = {}
		for _, item in ipairs(items) do
			local saved = s.file_views and s.file_views[item.relpath]
			if saved and saved.old_path == item.old_path then
				retained[item.relpath] = saved
			end
		end
		s.file_views = retained
	end
end

function M.restore(s, saved, stamp)
	s.navigation.reviewed = saved.reviewed == true
	if saved.stamp == stamp and saved.index and saved.index <= #s.navigation.saved then
		s.navigation.index = saved.index
		if saved.positions then
			s.navigation.positions = { [s.leftwin] = saved.positions[1], [s.rightwin] = saved.positions[2] }
		end
	end
end

function M.load(s, result, item, computed)
	s.navigation = {
		base = {},
		saved = {},
		reviewed = false,
		documents = { result.left_document, result.right_document },
		tick = s.worktree and vim.api.nvim_buf_get_changedtick(s.worktree.buf),
		version = s.worktree and s.worktree.version,
		diffopt = vim.o.diffopt,
		epoch = s.pane_epoch,
	}
	if
		(result.loaded and not result.loaded.text)
		or item.kind == "dir"
		or item.kind_before == "dir"
		or item.property_only
		or result.right_label == "SUBMODULE / DIRECTORY"
	then
		return
	end
	if not computed and result.left_document and result.right_document then
		local text = require("lazyvcs.compare_text")
		local left, right = text.serialize(result.left_document), text.serialize(result.right_document)
		if #left + #right > 32768 and left ~= right then
			local pending = s.navigation
			pending.pending = true
			s.navigation_diff = s.navigation_diff or require("lazyvcs.diff_work").latest()
			s.navigation_diff:request(left, right, function(raw, failure)
				if
					s.closed
					or s.panes_invalid
					or s.pane_epoch ~= pending.epoch
					or s.navigation ~= pending
					or s.preview_result ~= result
					or not vim.api.nvim_win_is_valid(s.leftwin)
					or not vim.api.nvim_win_is_valid(s.rightwin)
					or not vim.api.nvim_win_is_valid(s.sidewin)
				then
					return
				end
				if
					s.worktree
					and (
						not vim.api.nvim_buf_is_valid(s.worktree.buf)
						or vim.api.nvim_buf_get_changedtick(s.worktree.buf) ~= pending.tick
						or s.worktree.version ~= pending.version
					)
				then
					return
				end
				if vim.o.diffopt ~= pending.diffopt then
					M.load(s, result, item)
					return
				end
				if not raw then
					pending.pending = nil
					return util.notify(failure or "Could not update comparison hunks", vim.log.levels.WARN)
				end
				M.load(s, result, item, diff.text_hunks(raw, result.left_document, result.right_document))
				s.navigation.reviewed = pending.reviewed
				M.complete(s, s.navigation_intent)
			end)
			return
		end
	end
	local hunks = computed
		or (
			result.left_document
				and result.right_document
				and diff.compute_text_hunks(result.left_document, result.right_document)
			or diff.compute_hunks(result.left, result.right)
		)
	s.navigation.saved = hunks
	for i, hunk in ipairs(hunks) do
		s.navigation.base[i] = {
			current_start = hunk.base_start,
			current_count = hunk.base_count,
			base_start = hunk.current_start,
			base_count = hunk.current_count,
		}
	end
end

function M.intent(s, item, kind)
	local intent = { item = item, kind = kind, win = vim.api.nvim_get_current_win(), tab = s.tab }
	s.navigation_intent = intent
	return intent
end

local function focus(s, index, win)
	local navigation = s.navigation
	-- Position both panes from the same hunk, including the side with only filler.
	for _, side in ipairs({ { s.leftwin, s.left, navigation.base }, { s.rightwin, s.right, navigation.saved } }) do
		if side[1] ~= win then
			diff.focus_hunk(side[1], side[2], side[3][index])
		end
	end
	navigation.index, navigation.reviewed = index, true
	vim.api.nvim_set_current_win(win)
	diff.focus_hunk(
		win,
		vim.api.nvim_win_get_buf(win),
		(win == s.leftwin and navigation.base or navigation.saved)[index]
	)
	navigation.positions = {
		[s.leftwin] = vim.api.nvim_win_get_cursor(s.leftwin)[1],
		[s.rightwin] = vim.api.nvim_win_get_cursor(s.rightwin)[1],
	}
end

local function current_navigation(s)
	local nav, record = s.navigation, s.worktree
	if nav and nav.diffopt ~= vim.o.diffopt and s.preview_result and s.shown_item then
		local reviewed = nav.reviewed
		M.load(s, s.preview_result, s.shown_item)
		s.navigation.reviewed = reviewed
		nav = s.navigation
	end
	if
		record
		and vim.api.nvim_buf_is_valid(record.buf)
		and (not nav or nav.tick ~= vim.api.nvim_buf_get_changedtick(record.buf) or nav.version ~= record.version)
	then
		local current = require("lazyvcs.compare_worktree").capture(record)
		if not current then
			return nil
		end
		local result = require("lazyvcs.compare_worktree").result(record, s.preview_result, current)
		if not result then
			return nil
		end
		local reviewed = nav and nav.reviewed
		s.preview_result = result
		M.load(s, result, s.shown_item)
		s.navigation.reviewed = reviewed == true
	end
	return s.navigation
end

function M.complete(s, intent)
	if s.navigation_intent ~= intent or not intent or not panes_owned(s) then
		return
	end
	local navigation = current_navigation(s)
	if navigation and navigation.pending then
		return
	end
	M.cancel(s)
	local row = s.rows[vim.api.nvim_win_get_cursor(s.sidewin)[1]]
	if
		s.closed
		or vim.api.nvim_get_current_tabpage() ~= intent.tab
		or vim.api.nvim_get_current_win() ~= intent.win
		or (intent.win == s.sidewin and row ~= intent.item)
	then
		return
	end
	if intent.kind == "native" and intent.position and s.mode == "text" then
		local win = intent.side == "base" and s.leftwin or s.rightwin
		local buf = vim.api.nvim_win_get_buf(win)
		local line = math.min(intent.position[1], vim.api.nvim_buf_line_count(buf))
		local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
		local column = math.min(intent.position[2], #text)
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { line, column })
		vim.cmd("normal! zv")
		navigation.reviewed, navigation.index, navigation.positions = true, nil, nil
		return
	end
	if s.mode ~= "text" or not navigation or #navigation.saved == 0 then
		if intent.kind ~= "file" and intent.kind ~= "native" then
			util.notify("No text hunks to review; use :LazyVCS compare metadata", vim.log.levels.INFO)
		end
		return
	end
	local win = #s.preview_result.right == 0 and s.leftwin or s.rightwin
	if intent.kind == "file" and intent.win == s.leftwin and #s.preview_result.left > 0 then
		win = s.leftwin
	end
	if (intent.kind == "review" or intent.kind == "file") and navigation.reviewed then
		vim.api.nvim_set_current_win(win)
		return
	end
	local supported, why = diff.native_hunks_supported()
	if not supported then
		util.notify(why, vim.log.levels.WARN)
		vim.api.nvim_set_current_win(win)
		return
	end
	focus(s, intent.kind == "last" and #navigation.saved or 1, win)
end

function M.jump(s, direction)
	if not panes_owned(s) then
		util.notify("Comparison panes changed; hunk navigation is unavailable", vim.log.levels.WARN)
		return
	end
	local supported, why = diff.native_hunks_supported()
	if not supported then
		util.notify(why, vim.log.levels.WARN)
		return
	end
	local navigation = current_navigation(s)
	if navigation and navigation.pending then
		return
	end
	if not navigation or #navigation.saved == 0 then
		util.notify("No text hunks in this preview", vim.log.levels.INFO)
		return
	end
	local win = vim.api.nvim_get_current_win()
	local hunks = win == s.leftwin and navigation.base or navigation.saved
	local line = vim.api.nvim_win_get_cursor(win)[1]
	local index = navigation.index
	if index and navigation.positions and navigation.positions[win] == line then
		index = (index - 1 + (direction == "next" and 1 or -1)) % #hunks + 1
	else
		local neighbor = diff.find_neighbor_hunk(hunks, line, direction)
		for i, hunk in ipairs(hunks) do
			if hunk == neighbor then
				index = i
				break
			end
		end
	end
	vim.cmd("normal! m'")
	focus(s, index, win)
end

return M
