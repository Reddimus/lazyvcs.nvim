-- A statusline plugin registered before LazyVCS replaces each editor window's
-- winbar on BufWinEnter, so a copied Compare label never reaches LazyVCS.
local root, output, from = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
package.path =
	table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.api.nvim_create_autocmd("BufWinEnter", {
	callback = function()
		if not vim.w.lazyvcs_compare then
			vim.opt_local.winbar = "%f"
		end
	end,
})
local results = {}
local ok, err = xpcall(function()
	local api, h = vim.api, require("helpers")
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	local f = h.make_git_fixture()
	h.write_file(f.root .. "/a.txt", "first\n")
	h.write_file(f.root .. "/b.txt", "second\n")
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
	local function capture(win)
		return util.capture_win_options(
			win,
			{ "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "winbar" }
		)
	end
	ready("Compare did not load")
	for _, direction in ipairs({ "next", "prev" }) do
		compare.navigate_file(direction, 1)
		vim.wait(50)
		ready("Compare did not navigate")
	end
	assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
	local buf = s.right
	api.nvim_set_current_win(from == "right" and s.rightwin or s.sidewin)
	s.actions.edit()
	local editor = api.nvim_get_current_win()
	results.edit = capture(editor)
	results.edit.origin = editor == origin and api.nvim_win_get_buf(editor) == buf
	results.pane = capture(s.rightwin)
	compare.close(s)
	results.closed = capture(editor)
	vim.cmd("vsplit")
	vim.cmd.buffer(buf)
	results.split = capture(api.nvim_get_current_win())
	h.cleanup()
end, debug.traceback)
results.error = not ok and err or nil
vim.fn.writefile({ vim.json.encode(results) }, output)
vim.cmd("qa!")
