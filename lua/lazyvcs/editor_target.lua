local api = vim.api
local util = require("lazyvcs.util")
local state = require("lazyvcs.state")
local M = {}

function M.eligible(win, tab)
	if not util.win_is_valid(win) or api.nvim_win_get_tabpage(win) ~= tab then
		return false
	end
	local session = state.for_window(win)
	return api.nvim_win_get_config(win).relative == ""
		and vim.bo[api.nvim_win_get_buf(win)].buftype == ""
		and vim.bo[api.nvim_win_get_buf(win)].filetype ~= "lazyvcs-source-control"
		and not util.get_win_option(win, "winfixbuf")
		and not util.get_win_option(win, "previewwindow")
		and not vim.w[win].lazyvcs_compare
		and not (session and session.base_win == win)
end

function M.capture(preferred, anchor)
	anchor = anchor or api.nvim_get_current_win()
	local tab = api.nvim_win_get_tabpage(anchor)
	local win = M.eligible(preferred, tab) and preferred or nil
	if not win then
		for _, candidate in ipairs(api.nvim_tabpage_list_wins(tab)) do
			if M.eligible(candidate, tab) then
				if not win or not util.get_win_option(candidate, "diff") then
					win = candidate
				end
				if not util.get_win_option(candidate, "diff") then
					break
				end
			end
		end
	end
	win = win or anchor
	return { winid = win, bufnr = api.nvim_win_get_buf(win), tabid = tab, fallback = not M.eligible(win, tab) }
end

function M.valid(target)
	return util.win_is_valid(target.winid)
		and api.nvim_win_get_tabpage(target.winid) == target.tabid
		and api.nvim_win_get_buf(target.winid) == target.bufnr
		and (target.fallback or M.eligible(target.winid, target.tabid))
end

return M
