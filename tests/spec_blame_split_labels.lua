return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame = t.api, require("lazyvcs.blame")
	return t.cases({
		{
			"test_blame_split_single_word_label_survives_reload",
			function()
				for _, svn in ipairs({ false, true }) do
					for _, label in ipairs({ "WIP", "", "変更", "Work in progress" }) do
						local f, buf, win = t.open(svn, { blame = { uncommitted_text = label } })
						t.h.exec(
							svn and { "svn", "commit", "-m", "clean", f.file } or { "git", "commit", "-am", "clean" },
							f.root
						)
						assert(blame.blame_split())
						t.wait(function()
							local v = blame._test_blame_views()[buf]
							return v and v.winid
						end, "committed split absent", 15000)
						local view = blame._test_blame_views()[buf]
						api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
						api.nvim_exec_autocmds("TextChanged", { buffer = buf })
						t.wait(function()
							return #t.notices > 0
								or not blame._test_blame_views()[buf]
								or api.nvim_buf_get_lines(view.bufnr, 0, 1, false)[1] == label
						end, "split did not reload", 15000)
						assert(
							blame._test_blame_views()[buf] == view and api.nvim_win_is_valid(view.winid),
							"custom label closed split: " .. table.concat(t.notices, "; ")
						)
						assert(api.nvim_buf_get_lines(view.bufnr, 0, 1, false)[1] == label)
						local ns = api.nvim_get_namespaces().lazyvcs_blame_split
						for _, mark in ipairs(api.nvim_buf_get_extmarks(view.bufnr, ns, 0, -1, { details = true })) do
							local row = api.nvim_buf_get_lines(view.bufnr, mark[2], mark[2] + 1, false)[1]
							assert(mark[3] < mark[4].end_col and mark[4].end_col <= #row)
						end
						api.nvim_set_current_win(win)
						blame.blame_split()
						assert(blame.blame_split())
						t.wait(function()
							local v = blame._test_blame_views()[buf]
							return v and v.winid
						end, "initial uncommitted split absent", 15000)
						assert(#t.notices == 0, table.concat(t.notices, "; "))
						blame.blame_split()
					end
				end
			end,
		},
	})
end
