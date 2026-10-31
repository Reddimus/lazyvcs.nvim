return function(ctx)
	local h, api = ctx.helpers, vim.api
	local cases = {}
	local function settle()
		vim.wait(100, function()
			return false
		end, 5)
	end
	local function visit(s)
		api.nvim_set_current_tabpage(s.tab)
		api.nvim_set_current_win(s.rightwin)
		settle()
	end
	for _, mode in ipairs({ "normal", "binary_recovered", "size_recovered", "binary_unsupported", "size_unsupported" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_reacquire_" .. mode,
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/a_added.txt", "original\n")
				local compare = require("lazyvcs.compare")
				local function open()
					local s = assert(compare.open({ path = f.root, base = "HEAD", editable = true }))
					ctx.wait_for(function()
						return s.preview_result
							and s.worktree
							and s.shown_item
							and s.shown_item.relpath == "a_added.txt"
					end, "reacquisition initial preview", 15000)
					settle()
					assert(s.rail)
					return s
				end
				local a = open()
				vim.cmd.tabnew()
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a_added.txt"))
				local b = open()
				local record = a.worktree
				assert(record == b.worktree and a.right == b.right, "not a shared record")
				local binary, failed = mode:find("binary", 1, true) ~= nil, mode ~= "normal"
				local unsupported = mode:find("unsupported", 1, true) ~= nil
				local function recover()
					if binary then
						vim.bo[record.buf].binary = false
					else
						api.nvim_buf_set_lines(record.buf, 0, -1, false, { "recovered" })
					end
					ctx.wait_for(function()
						return not record.capture_error and b.navigation and not b.navigation.pending
					end, "remaining owner recovery", 15000)
					settle()
					assert(b.rail)
				end
				visit(a)
				if failed then
					if binary then
						vim.bo[record.buf].binary = true
					else
						api.nvim_buf_set_lines(record.buf, 0, -1, false, { string.rep("x", 1024 * 1024 + 1) })
					end
					ctx.wait_for(function()
						return record.capture_error ~= nil
					end, "capture rejection", 15000)
					visit(b)
					visit(a)
					assert(not a.rail and not b.rail)
				end
				compare.action("metadata")
				ctx.wait_for(function()
					return a.mode == "metadata" and not a.worktree
				end, "metadata releases ownership", 15000)
				assert(record.owners[a] == nil and record.owners[b] ~= nil)
				visit(b)
				if failed and not unsupported then
					recover()
				end
				visit(a)
				compare.action("metadata")
				if unsupported then
					settle()
					assert(a.mode == "text" and not a.worktree, "unsupported buffer was acquired")
					assert(a.capture_failed_record == record, "failed capture cleared rejection")
					assert(a.right ~= record.buf and not vim.bo[a.right].modifiable, "saved snapshot fallback changed")
					assert(not require("lazyvcs.compare_worktree").capture(record))
					assert(record.owners[a] == nil and record.owners[b] ~= nil)
					compare.action("metadata")
					assert(a.mode == "metadata" and not a.worktree)
					visit(b)
					recover()
					visit(a)
					compare.action("metadata")
				end
				ctx.wait_for(function()
					return a.mode == "text"
						and a.worktree == record
						and a.preview_result
						and a.preview_result.right_document
				end, "same-record text reacquisition", 15000)
				settle()
				assert(api.nvim_win_get_buf(a.rightwin) == record.buf and a.right == b.right)
				assert(require("lazyvcs.compare_worktree").capture(record), "fresh capture unexpectedly failed")
				assert(a.rail and a.rail.win == a.leftwin, "successful fresh capture retained stale rejection")
				visit(b)
				assert(b.rail, "other view eligibility changed")
				compare.close(a, false)
				compare.close(b, false)
			end,
		}
	end
	return cases
end
