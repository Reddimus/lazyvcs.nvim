return function(ctx)
	local h, api = ctx.helpers, vim.api
	local cases = {}
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes))
		assert(file:close())
	end
	local function setup(collapse)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			base_window = { collapse_absent = collapse },
			compare = { collapse_absent = collapse },
		})
	end
	local function settle()
		vim.wait(100, function()
			return false
		end, 5)
	end
	local function staged(f)
		local result, failure, done
		require("lazyvcs.backends").load_diff_target_async({
			vcs = "git",
			root = f.root,
			relpath = "added.txt",
			section = "staged",
			status = "A ",
			change_kind = "added",
		}, function(value, err)
			result, failure, done = value, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "eligibility staged target", 15000)
		return assert(result, failure)
	end
	for _, collapse in ipairs({ true, false }) do
		cases[#cases + 1] = {
			"test_core_diff_style_readonly_refresh_eligibility_" .. tostring(collapse),
			function()
				setup(collapse)
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
				local path = f.root .. "/added.txt"
				write(path, "text\n")
				h.exec({ "git", "add", "added.txt" }, f.root)
				local actions = require("lazyvcs.actions")
				local s = assert(actions.open_target(staged(f)))
				settle()
				assert((s.rail ~= nil) == collapse)
				write(path, "binary\0payload\n")
				h.exec({ "git", "add", "added.txt" }, f.root)
				actions.refresh_current()
				ctx.wait_for(function()
					return not s.refresh_job and s.comparison.right.bytes == "binary\0payload\n"
				end, "binary snapshot refresh", 15000)
				settle()
				assert(not s.rail and not s.rail_text, "readonly refresh retained old text eligibility")
				assert(s.readonly_comparison and not vim.bo[s.editable_bufnr].modifiable)
				actions.close(s)
				s = assert(actions.open_target(staged(f)))
				settle()
				assert(not s.rail and not s.rail_text, "fresh binary snapshot collapsed")
				write(path, "recovered text\n")
				h.exec({ "git", "add", "added.txt" }, f.root)
				actions.refresh_current()
				ctx.wait_for(function()
					return not s.refresh_job and s.comparison.right.bytes == "recovered text\n"
				end, "snapshot text recovery", 15000)
				settle()
				assert(s.rail_text and (s.rail ~= nil) == collapse, "readonly recovery kept old binary eligibility")
				actions.close(s)
			end,
		}
		for _, mode in ipairs({ "binary", "size" }) do
			cases[#cases + 1] = {
				"test_core_diff_style_editable_capture_eligibility_" .. mode .. "_" .. tostring(collapse),
				function()
					setup(collapse)
					local f = h.make_git_fixture()
					h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
					write(f.root .. "/a_added.txt", "original\n")
					local compare = require("lazyvcs.compare")
					local s = assert(compare.open({ path = f.root, base = "HEAD", editable = true }))
					ctx.wait_for(function()
						return s.preview_result
							and s.shown_item
							and s.shown_item.relpath == "a_added.txt"
							and s.worktree
					end, "editable added preview", 15000)
					settle()
					assert((s.rail ~= nil) == collapse)
					api.nvim_set_current_win(s.rightwin)
					local buf = s.right
					if mode == "binary" then
						vim.bo[buf].binary = true
					else
						api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 1024 * 1024 + 1) })
					end
					local bytes = api.nvim_buf_get_lines(buf, 0, -1, false)
					local history = api.nvim_buf_call(buf, vim.fn.undotree).seq_cur
					ctx.wait_for(function()
						return s.worktree.capture_error ~= nil
					end, "capture rejection", 15000)
					settle()
					assert(not s.rail, "capture failure left an installed rail")
					assert(s.navigation.pending and #s.navigation.base == 0 and not s.worktree_diff)
					assert(s.right_label:find("hunks unavailable", 1, true))
					compare.action("width")
					settle()
					assert(not s.rail, "resize reused stale preview documents")
					assert(s.right == buf and api.nvim_win_get_buf(s.rightwin) == buf)
					assert(
						vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), bytes),
						"eligibility check changed source text"
					)
					assert(
						api.nvim_buf_call(buf, vim.fn.undotree).seq_cur == history,
						"eligibility check changed undo history"
					)
					if mode == "binary" then
						vim.bo[buf].binary = false
					else
						api.nvim_buf_set_lines(buf, 0, -1, false, { "recovered" })
					end
					ctx.wait_for(function()
						return s.worktree.capture_error == nil and s.navigation and not s.navigation.pending
					end, "editable text recovery", 15000)
					settle()
					assert((s.rail ~= nil) == collapse, "recovered editable text did not regain eligibility")
					assert(not s.right_label:find("hunks unavailable", 1, true))
					compare.close(s)
				end,
			}
		end
	end
	for _, mode in ipairs({ "binary", "size" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_fresh_unsupported_eligibility_" .. mode,
			function()
				setup(true)
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
				local path = f.root .. "/a_added.txt"
				write(path, mode == "binary" and "binary\0payload\n" or string.rep("x", 1024 * 1024 + 1))
				local compare = require("lazyvcs.compare")
				local s = assert(compare.open({ path = f.root, base = "HEAD", editable = true }))
				ctx.wait_for(function()
					return not s.preview_job and s.shown_item and s.shown_item.relpath == "a_added.txt"
				end, "fresh unsupported preview", 15000)
				settle()
				assert(not s.rail and s.mode ~= "text", "fresh unsupported preview collapsed")
				write(path, "recovered text\n")
				compare.refresh(s)
				ctx.wait_for(function()
					return s.preview_result and not s.preview_job and s.mode == "text"
				end, "fresh preview recovery", 15000)
				settle()
				assert(s.rail, "fresh recovered text did not regain eligibility")
				compare.close(s)
			end,
		}
	end
	return cases
end
