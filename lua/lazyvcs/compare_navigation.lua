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
	if s.mode ~= "text" or not navigation or #navigation.saved == 0 then
		util.notify("No text hunks to review; use p for metadata", vim.log.levels.INFO)
		return
	end
	local win = #s.preview_result.right == 0 and s.leftwin or s.rightwin
	if intent.kind == "review" and navigation.reviewed then
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
