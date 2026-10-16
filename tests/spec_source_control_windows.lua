return function(ctx)
	local api, h = vim.api, ctx.helpers
	local native = require("lazyvcs.source_control.native")
	local function run(fn)
		return function()
			local win, columns = api.nvim_get_current_win(), vim.o.columns
			local names = { "foldenable", "foldmethod", "foldlevel", "winfixwidth" }
			local saved = require("lazyvcs.util").capture_win_options(win, names)
			local ok, err = xpcall(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = {
						width = 30,
						auto_expand_width = false,
						remote_refresh = "manual",
					},
				})
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				fn(f, win)
			end, debug.traceback)
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.o.columns = columns
			require("lazyvcs.util").set_win_options(api.nvim_get_current_win(), saved)
			assert(ok, err)
		end
	end
	return {
		{
			"test_source_control_sidebar_disables_inherited_folds",
			run(function(f, win)
				require("lazyvcs.util").set_win_options(
					win,
					{ foldenable = true, foldmethod = "indent", foldlevel = 0 }
				)
				local s = native.open({ path = f.root })
				ctx.wait_for(function()
					return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
				end, "sidebar did not load", 15000)
				vim.bo[s.bufnr].shiftwidth = 2
				vim.bo[s.bufnr].tabstop = 2
				vim.wo[s.winid].foldmethod = "indent"
				vim.wo[s.winid].foldlevel = 0
				assert(vim.wo[win].foldenable and vim.wo[win].foldmethod == "indent", "editor folding changed")
				local enter
				for _, map in ipairs(api.nvim_buf_get_keymap(s.bufnr, "n")) do
					if map.lhs == "<CR>" then
						enter = map.callback
					end
				end
				for _ = 1, 2 do
					api.nvim_win_set_cursor(s.winid, { 1, 0 })
					assert(enter)()
					native.render(s)
					api.nvim_win_call(s.winid, function()
						for row = 1, api.nvim_buf_line_count(s.bufnr) do
							assert(vim.fn.foldclosed(row) == -1, "sidebar row hidden by fold")
						end
					end)
				end
				assert(not vim.wo[s.winid].foldenable, "sidebar inherited enabled native folds")
				vim.cmd.only()
				local survivor = s.winid
				native.close()
				assert(vim.wo[survivor].foldenable, "surviving window lost folding")
				local again = native.open({ path = f.root })
				vim.cmd.only()
				vim.wo[again.winid].foldenable = true
				survivor = again.winid
				native.close()
				assert(vim.wo[survivor].foldenable, "user folding override lost")
			end),
		},
		{
			"test_source_control_sidebar_initial_width_with_fixed_split",
			run(function(f, win)
				vim.o.columns = 220
				vim.cmd("topleft 30vsplit")
				local neighbor = api.nvim_get_current_win()
				vim.wo[neighbor].winfixwidth = true
				api.nvim_set_current_win(win)
				local s = native.open({ path = f.root, focus = false })
				assert(
					api.nvim_win_get_width(s.winid) == 30,
					"configured sidebar width ignored: " .. api.nvim_win_get_width(s.winid)
				)
				assert(api.nvim_win_get_width(neighbor) == 30, "fixed neighbor resized")
				assert(api.nvim_get_current_win() == win, "focus=false moved focus")
				api.nvim_win_set_width(s.winid, 42)
				native.render(s)
				native.open({ path = f.root, focus = false })
				assert(api.nvim_win_get_width(s.winid) == 42, "manual sidebar width lost")
			end),
		},
	}
end
