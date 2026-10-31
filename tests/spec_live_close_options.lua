return function(ctx)
	local h, api = ctx.helpers, vim.api
	local names = { "signcolumn", "statuscolumn", "winfixheight", "winfixwidth" }
	local function options(win)
		return require("lazyvcs.util").capture_win_options(win, names)
	end
	local cases = {}
	for _, added in ipairs({ false, true }) do
		for _, edited in ipairs({ false, true }) do
			for _, refresh in ipairs({ false, true }) do
				cases[#cases + 1] = {
					"test_live_diff_close_options_"
						.. (added and "added" or "present")
						.. "_"
						.. tostring(edited)
						.. "_refresh_"
						.. tostring(refresh),
					function()
						require("lazyvcs").setup({
							use_gitsigns = false,
							signs = { enabled = false },
							blame = { persist = false },
						})
						local f = h.make_git_fixture()
						if added then
							f.file = f.root .. "/added.txt"
							h.write_file(f.file, "owned addition bytes\n")
						end
						vim.cmd.edit(vim.fn.fnameescape(f.file))
						vim.cmd("setlocal signcolumn=auto statuscolumn= nowinfixheight nowinfixwidth")
						local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
						local original, before = api.nvim_buf_get_lines(buf, 0, -1, false), options(win)
						local session
						require("lazyvcs").open({
							on_open = function(value)
								session = value
							end,
						})
						ctx.wait_for(function()
							return session ~= nil
						end, "live view did not open", 15000)
						assert(session.editable_win == win)
						if added then
							ctx.wait_for(function()
								return session.rail ~= nil
							end, "added file base did not collapse")
						end
						api.nvim_set_current_win(win)
						if edited then
							vim.cmd("setlocal signcolumn=yes:2 statuscolumn=LATEST winfixheight winfixwidth")
						end
						local wanted = edited and options(win) or before
						if refresh then
							local base = session.base_text
							require("lazyvcs").refresh()
							ctx.wait_for(function()
								return not session.refresh_job
									and session.base_text ~= base
									and session.phase == "active"
							end, "public refresh did not rebind the view", 15000)
						end
						require("lazyvcs").close()
						assert(
							vim.deep_equal(options(win), wanted),
							"close replaced latest preferences: " .. vim.inspect(options(win))
						)
						assert(
							vim.deep_equal(original, api.nvim_buf_get_lines(buf, 0, -1, false)),
							"close changed original bytes"
						)
						assert(not vim.wo[win].diff, "close left native diff active")
						h.cleanup()
					end,
				}
			end
		end
	end
	for _, replace in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_live_diff_close_options_callback_" .. tostring(replace),
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				vim.cmd("setlocal signcolumn=auto statuscolumn= nowinfixheight nowinfixwidth")
				local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				local original = api.nvim_buf_get_lines(buf, 0, -1, false)
				local session
				require("lazyvcs").open({
					on_open = function(value)
						session = value
					end,
				})
				ctx.wait_for(function()
					return session ~= nil
				end, "callback view did not open", 15000)
				local fired, replacement = false, nil
				local id = api.nvim_create_autocmd("OptionSet", {
					pattern = "winbar",
					nested = true,
					callback = function()
						if not fired and api.nvim_get_current_win() == win then
							fired = true
							if replace then
								replacement = api.nvim_create_buf(false, true)
								api.nvim_buf_set_lines(replacement, 0, -1, false, { "new editor owner" })
								api.nvim_win_set_buf(win, replacement)
							end
							vim.cmd("setlocal signcolumn=yes:2 statuscolumn=LATER winfixheight winfixwidth")
						end
					end,
				})
				local ok, err = xpcall(function()
					require("lazyvcs").close()
					assert(fired, "native close callback did not run")
					assert(
						vim.deep_equal(
							options(win),
							{ signcolumn = "yes:2", statuscolumn = "LATER", winfixheight = true, winfixwidth = true }
						)
					)
					assert(vim.deep_equal(original, api.nvim_buf_get_lines(buf, 0, -1, false)))
					if replacement then
						assert(api.nvim_win_get_buf(win) == replacement)
						assert(api.nvim_buf_get_lines(replacement, 0, -1, false)[1] == "new editor owner")
					end
				end, debug.traceback)
				api.nvim_del_autocmd(id)
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	return cases
end
