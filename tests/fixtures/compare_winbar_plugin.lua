-- A statusline plugin registered before LazyVCS replaces each editor window's
-- winbar on BufWinEnter, so a copied Compare label never reaches LazyVCS.
-- scenario: "edit" (the edit action), "peer" (edit beside a user diff pair),
-- "float" (an unfocused float opened from the pane, then another tab opens the
-- buffer), or "minimal" (a focused minimal float that leaves the buffer and
-- returns, then a new window in the same tab opens it).
local root, output, from, scenario = arg[1], arg[2], arg[3], arg[4]
local peer = scenario == "peer"
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
	local peers = {}
	if peer then
		-- An unrelated diff pair in the editor tab.
		local dir = h.tempdir()
		for index, name in ipairs({ "left.txt", "right.txt" }) do
			h.write_file(dir .. "/" .. name, index == 1 and "one\n" or "two\n")
			vim.cmd("botright vsplit " .. vim.fn.fnameescape(dir .. "/" .. name))
			vim.cmd("diffthis")
			peers[#peers + 1] = api.nvim_get_current_win()
		end
		api.nvim_set_current_win(origin)
	end
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
	if scenario == "float" or scenario == "minimal" then
		api.nvim_set_current_win(s.rightwin)
		local float = { relative = "editor", row = 1, col = 1, width = 20, height = 3 }
		if scenario == "float" then
			api.nvim_open_win(api.nvim_create_buf(false, true), false, float)
		else
			float.style = "minimal"
			api.nvim_open_win(buf, true, float)
			-- Leaving and returning gives the float a record that a later window
			-- can copy; Neovim 0.11 copies from minimal windows, 0.12 does not.
			vim.cmd.buffer(api.nvim_create_buf(false, true))
			vim.cmd.buffer(buf)
		end
		if scenario == "float" then
			vim.cmd("tabnew")
		else
			-- A new ordinary window in the same tab, which does not skip the
			-- float's record for diff mode.
			api.nvim_set_current_win(s.sidewin)
			vim.cmd("split")
		end
		vim.cmd.buffer(buf)
		results.target = capture(api.nvim_get_current_win())
		results.pane = capture(s.rightwin)
		compare.close(s)
		h.cleanup()
		return
	end
	api.nvim_set_current_win(from == "right" and s.rightwin or s.sidewin)
	s.actions.edit()
	local editor = api.nvim_get_current_win()
	results.edit = capture(editor)
	results.edit.origin = editor == origin and api.nvim_win_get_buf(editor) == buf
	results.pane = capture(s.rightwin)
	results.peers = {}
	for _, win in ipairs(peers) do
		results.peers[#results.peers + 1] = vim.wo[win].diff
	end
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
