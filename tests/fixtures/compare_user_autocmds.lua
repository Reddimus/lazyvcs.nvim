-- User autocommands registered before LazyVCS run before its own handlers.
-- scenario: "loadview" (the :help :loadview auto-view autocommands, with the
-- default 'viewoptions') or "bufenter" (an autocommand that sets 'foldignore'
-- in every window it enters). step: "edit" (the edit action from the right
-- pane) or "reopen" (a new tab opens the buffer after Compare moved on).
local root, output, scenario, step = arg[1], arg[2], arg[3], arg[4]
vim.opt.runtimepath:prepend(root)
package.path =
	table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")
vim.env.XDG_STATE_HOME = vim.fn.tempname()
if scenario == "loadview" then
	vim.o.viewdir = vim.fn.tempname()
	vim.cmd([[
		autocmd BufWinLeave * if expand('%') != '' && &buftype == '' | silent! mkview | endif
		autocmd BufWinEnter * if expand('%') != '' && &buftype == '' | silent! loadview | endif
	]])
else
	vim.cmd("autocmd BufEnter * setlocal foldignore=#")
end
local results = {}
local ok, err = xpcall(function()
	local api, h = vim.api, require("helpers")
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	local f = h.make_git_fixture()
	h.write_file(f.root .. "/a.txt", "first\n")
	h.write_file(f.root .. "/b.txt", "second\n")
	-- A listed buffer outlives Compare moving on; no window has shown it yet.
	local listed = vim.fn.bufadd(f.root .. "/a.txt")
	vim.fn.bufload(listed)
	vim.bo[listed].buflisted = true
	vim.cmd.edit(vim.fn.fnameescape(f.file))
	local origin = api.nvim_get_current_win()
	local s = assert(compare.open({ path = f.root, base = "HEAD" }))
	local function ready(message)
		assert(
			vim.wait(15000, function()
				return s.preview_result and not s.preview_job and not s.job
			end, 10),
			message
		)
	end
	ready("Compare did not load")
	-- Revisiting a file gives its pane a saved window-option record.
	for _, direction in ipairs({ "next", "prev" }) do
		compare.navigate_file(direction, 1)
		vim.wait(50)
		ready("Compare did not navigate")
	end
	assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
	local win
	-- Enter the pane from the sidebar, which runs the user's BufEnter there.
	api.nvim_set_current_win(s.sidewin)
	api.nvim_set_current_win(s.rightwin)
	if step == "edit" then
		s.actions.edit()
		win = api.nvim_get_current_win()
		results.origin = win == origin
	else
		compare.navigate_file("next", 1)
		vim.wait(50)
		ready("Compare did not move on")
		vim.cmd("tabnew")
		vim.cmd.buffer(listed)
		win = api.nvim_get_current_win()
	end
	results.window =
		util.capture_win_options(win, { "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "winbar" })
	results.pane = util.capture_win_options(s.rightwin, { "diff", "scrollbind" })
end, debug.traceback)
if not ok then
	results.error = err
end
vim.fn.writefile({ vim.json.encode(results) }, output)
vim.cmd("qa!")
