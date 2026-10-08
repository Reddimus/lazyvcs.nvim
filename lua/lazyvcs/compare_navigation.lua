local diff = require("lazyvcs.diff")
local util = require("lazyvcs.util")
local M = {}

function M.owns(s)
	local win = vim.api.nvim_get_current_win()
	return s and not s.closed and (win == s.sidewin or win == s.leftwin or win == s.rightwin)
end

function M.cancel(s)
	s.navigation_intent = nil
end

function M.remember(s)
	if not s.preview_result or not s.shown_item or not s.navigation then
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

function M.load(s, result, item)
	s.navigation = { base = {}, saved = {}, reviewed = false }
	if item.kind == "dir" or item.property_only or result.right_label == "SUBMODULE / DIRECTORY" then
		return
	end
	local hunks = diff.compute_hunks(result.left, result.right)
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

function M.complete(s, intent)
	if s.navigation_intent ~= intent or not intent then
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
	local navigation = s.navigation
	if intent.kind == "search" and intent.position and s.mode == "text" and #s.preview_result.right > 0 then
		local line = math.min(intent.position[1], #s.preview_result.right)
		local column = math.min(intent.position[2], #(s.preview_result.right[line] or ""))
		vim.api.nvim_set_current_win(s.rightwin)
		vim.api.nvim_win_set_cursor(s.rightwin, { line, column })
		vim.cmd("normal! zv")
		navigation.reviewed, navigation.index, navigation.positions = true, nil, nil
		return
	end
	if s.mode ~= "text" or not navigation or #navigation.saved == 0 then
		if intent.kind ~= "file" and intent.kind ~= "search" then
			util.notify("No text hunks to review; use p for metadata", vim.log.levels.INFO)
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
	focus(s, intent.kind == "last" and #navigation.saved or 1, win)
end

function M.jump(s, direction)
	local navigation = s.navigation
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
	focus(s, index, win)
end

return M
