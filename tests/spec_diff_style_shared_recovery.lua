return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local compare = require("lazyvcs.compare")
	local function settle()
		vim.wait(100, function()
			return false
		end, 5)
	end
	local function setup()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	end
	local function open(root)
		local s = assert(compare.open({ path = root, base = "HEAD", editable = true }))
		ctx.wait_for(function()
			return s.preview_result and s.worktree and s.shown_item and s.shown_item.relpath == "a_added.txt"
		end, "shared preview", 15000)
		settle()
		assert(s.rail, "initial text rail missing")
		return s
	end
	local function visit(s)
		api.nvim_set_current_tabpage(s.tab)
		api.nvim_set_current_win(s.rightwin)
		settle()
	end
	for _, kind in ipairs({ "binary", "size" }) do
		for _, order in ipairs({ "single", "first", "second" }) do
			cases[#cases + 1] = {
				"test_core_diff_style_shared_recovery_" .. kind .. "_" .. order,
				function()
					setup()
					local f = h.make_git_fixture()
					h.write_file(f.root .. "/a_added.txt", "original\n")
					local first = open(f.root)
					local sessions = { first }
					if order ~= "single" then
						vim.cmd.tabnew()
						vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a_added.txt"))
						sessions[#sessions + 1] = open(f.root)
					end
					local record, owners = first.worktree, {}
					for owner in pairs(record.owners) do
						if not owner.closed and owner.worktree == record then
							owners[#owners + 1] = owner
						end
					end
					assert(#owners == #sessions)
					local current = order == "second" and owners[2] or owners[1]
					for _, s in ipairs(owners) do
						assert(s.right == record.buf and s.worktree == record, "not a shared real buffer")
					end
					visit(current)
					if kind == "binary" then
						vim.bo[record.buf].binary = true
					else
						api.nvim_buf_set_lines(record.buf, 0, -1, false, { string.rep("x", 1024 * 1024 + 1) })
					end
					local lines = api.nvim_buf_get_lines(record.buf, 0, -1, false)
					local undo = api.nvim_buf_call(record.buf, vim.fn.undotree).seq_cur
					ctx.wait_for(function()
						return record.capture_error ~= nil
					end, "shared capture rejection", 15000)
					for _, s in ipairs(owners) do
						visit(s)
						assert(not s.rail, "capture failure did not expand owner")
					end
					visit(current)
					assert(vim.deep_equal(api.nvim_buf_get_lines(record.buf, 0, -1, false), lines))
					assert(api.nvim_buf_call(record.buf, vim.fn.undotree).seq_cur == undo)
					if kind == "binary" then
						vim.bo[record.buf].binary = false
					else
						api.nvim_buf_set_lines(record.buf, 0, -1, false, { "recovered" })
					end
					ctx.wait_for(function()
						if record.capture_error then
							return false
						end
						for _, s in ipairs(owners) do
							if not s.navigation or s.navigation.pending then
								return false
							end
						end
						return true
					end, "shared recovery", 15000)
					settle()
					assert(current.rail, "another shared owner consumed current view recovery")
					for _, s in ipairs(owners) do
						visit(s)
						assert(
							s.rail and s.rail.win == s.leftwin,
							"background owner failed recovery on native TabEnter"
						)
					end
					for _, s in ipairs(sessions) do
						compare.close(s, false)
					end
				end,
			}
		end
	end
	cases[#cases + 1] = {
		"test_core_diff_style_shared_recovery_failed_file_does_not_block_next",
		function()
			setup()
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a_added.txt", "original\n")
			h.write_file(f.root .. "/b_added.txt", "other\n")
			local s = open(f.root)
			visit(s)
			local failed = s.worktree
			vim.bo[failed.buf].binary = true
			ctx.wait_for(function()
				return failed.capture_error ~= nil
			end, "failed source capture", 15000)
			settle()
			assert(not s.rail)
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path["b_added.txt"]), 0 })
			api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b_added.txt" and s.worktree ~= failed and s.preview_result
			end, "next native file", 15000)
			settle()
			assert(s.rail and s.rail.win == s.leftwin, "old file rejection leaked into new file")
			assert(api.nvim_win_get_buf(s.rightwin) == s.worktree.buf and vim.bo[s.worktree.buf].modifiable)
			compare.close(s)
		end,
	}
	return cases
end
