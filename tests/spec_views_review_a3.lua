return function(ctx)
	local api, h = vim.api, ctx.helpers
	local signs = require("signs_helpers")(ctx)
	local compare = require("lazyvcs.compare")
	local comparisons = {}
	local function guard(fn)
		return signs.guard(function()
			local diffopt, ignorecase = vim.o.diffopt, vim.o.fileignorecase
			local confirm = require("lazyvcs.source_control.confirm")
			local mutation = confirm.mutation
			local ok, err = xpcall(fn, debug.traceback)
			confirm.mutation = mutation
			vim.o.diffopt, vim.o.fileignorecase = diffopt, ignorecase
			for _, s in ipairs(comparisons) do
				pcall(compare.close, s)
			end
			comparisons = {}
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			h.cleanup()
			assert(ok, err)
		end)
	end
	local function link(target, path, flags)
		local ok, err = vim.uv.fs_symlink(target, path, flags and { dir = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "symlink creation unavailable: " .. tostring(err) })
		end
		assert(ok, err)
	end
	local function live(path)
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(path))
		local buf = api.nvim_get_current_buf()
		require("lazyvcs.actions").open()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf)
		end, "live absent", 15000)
		return assert(require("lazyvcs.state").get(buf))
	end
	return {
		{
			"test_signs_a3_review_icase_keeps_standalone_native_commands",
			guard(function()
				local _, buf = signs.fixture(false)
				api.nvim_buf_set_lines(buf, 1, 2, false, { "TWO" })
				vim.opt.diffopt:append("icase")
				assert(signs.refresh(buf, true))
				api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk next")
				ctx.wait_for(function()
					return api.nvim_win_get_cursor(0)[1] == 2
				end, "icase blocked standalone signs navigation", 1000)
				local confirm = require("lazyvcs.source_control.confirm")
				local entered = false
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(opts, apply)
					entered = true
					assert(opts.before_confirm())
					return apply()
				end
				vim.cmd("LazyVCS hunk revert")
				ctx.wait_for(function()
					return api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two"
				end, "icase blocked standalone signs revert", 15000)
				assert(entered, "confirmation seam was skipped")
			end),
		},
		{
			"test_signs_a3_review_icase_keeps_gitsigns_delegation",
			guard(function()
				local _, buf = signs.fixture(false, { use_gitsigns = true })
				local delegated = 0
				package.loaded.gitsigns = {
					get_hunks = function()
						return {}
					end,
					nav_hunk = function(direction)
						assert(direction == "next")
						delegated = delegated + 1
					end,
				}
				vim.b[buf].gitsigns_status_dict = { changed = 1 }
				vim.opt.diffopt:append("icase")
				vim.cmd("LazyVCS hunk next")
				ctx.wait_for(function()
					return delegated == 1
				end, "icase blocked gitsigns navigation", 1000)
			end),
		},
		{
			"test_signs_a3_review_icase_keeps_large_gitsigns_revert",
			guard(function()
				local f, buf = signs.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
				assert(require("lazyvcs.backends").resolve(f.file))
				signs.signs.refresh(buf, false)
				package.loaded.gitsigns = {
					get_hunks = function()
						return {
							{
								removed = { start = 2, count = 1, lines = { "two" } },
								added = {
									start = 2,
									count = 1,
									lines = { "changed" },
								},
							},
						}
					end,
				}
				vim.b[buf].gitsigns_status_dict = { changed = 1 }
				vim.opt.diffopt:append("icase")
				local entered = false
				---@diagnostic disable-next-line: duplicate-set-field
				require("lazyvcs.source_control.confirm").mutation = function(opts, apply)
					entered = true
					assert(opts.before_confirm())
					return apply()
				end
				api.nvim_win_set_cursor(0, { 2, 0 })
				vim.cmd("LazyVCS hunk revert")
				ctx.wait_for(function()
					return api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two"
				end, "icase blocked large delegated revert", 15000)
				assert(entered, "large delegated confirmation seam skipped")
			end),
		},
		{
			"test_live_diff_a3_review_base_change_matches_symlink_ancestor",
			guard(function()
				local f = h.make_git_fixture()
				local alias = h.tempdir() .. "/repo"
				link(f.root, alias, "dir")
				local s = live(alias .. "/sample.txt")
				local actions = require("lazyvcs.actions")
				local change = actions.begin_base_change(f.root, { alias .. "/sample.txt" })
				local matched = s.base_changing
				h.write_file(f.file, "fresh staged base\n")
				h.exec({ "git", "add", "sample.txt" }, f.root)
				actions.finish_base_change(change)
				assert(matched, "symlink ancestor bypassed mutation invalidation")
				ctx.wait_for(function()
					return s.base_lines[1] == "fresh staged base"
				end, "aliased session did not reload", 15000)
				vim.o.fileignorecase = true
				change = actions.begin_base_change(f.root:upper(), { f.root .. "/SAMPLE.TXT" })
				matched = s.base_changing
				actions.finish_base_change(change)
				assert(matched, "filename case convention bypassed mutation invalidation")
			end),
		},
		{
			"test_live_diff_a3_review_base_change_keeps_final_link_entry",
			guard(function()
				local f = h.make_git_fixture()
				local path = f.root .. "/linked.txt"
				link("sample.txt", path)
				h.exec({ "git", "add", "linked.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "link entry" }, f.root)
				local s = live(f.file)
				local actions = require("lazyvcs.actions")
				local change = actions.begin_base_change(f.root, { path })
				assert(not s.base_changing, "symlink entry mutation invalidated its distinct target")
				actions.finish_base_change(change)
				change = actions.begin_base_change(f.root, { f.file })
				local matched = s.base_changing
				actions.finish_base_change(change)
				assert(matched, "target entry mutation was not recognized")
			end),
		},
		{
			"test_blame_a3_review_split_attributes_resolved_target",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				h.exec({ "git", "commit", "-am", "target contents" }, f.root)
				local revision = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				local path = f.root .. "/linked.txt"
				link("sample.txt", path)
				h.exec({ "git", "add", "linked.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "link entry" }, f.root)
				vim.cmd.edit(vim.fn.fnameescape(path))
				local buf = api.nvim_get_current_buf()
				local blame = require("lazyvcs.blame")
				assert(blame.blame_split())
				ctx.wait_for(function()
					local v = blame._test_blame_views()[buf]
					return v and v.entries
				end, "symlink split absent", 15000)
				local v = blame._test_blame_views()[buf]
				assert(
					v.entries[2].full_revision == revision and not v.entries[2].uncommitted,
					"split attributed link entry instead of target text"
				)
			end),
		},
		{
			"test_core_compare_a3_review_capture_failure_preserves_percent_label",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				local path = f.root .. "/a%file.txt"
				h.write_file(path, "base\n")
				h.exec({ "git", "add", "a%file.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "percent file" }, f.root)
				h.write_file(path, "changed\n")
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				comparisons[#comparisons + 1] = s
				ctx.wait_for(function()
					return s.worktree and s.navigation and not s.navigation.pending
				end, "percent preview absent", 15000)
				assert(s.shown_item.relpath == "a%file.txt")
				local label, winbar = s.left_label, vim.wo[s.leftwin].winbar
				api.nvim_buf_set_lines(s.right, 0, 1, false, { "bad\0text" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				ctx.wait_for(function()
					return s.worktree.capture_error ~= nil
				end, "capture failure absent", 15000)
				assert(
					s.left_label == label and vim.wo[s.leftwin].winbar == winbar,
					"capture failure double-escaped percent left label"
				)
			end),
		},
	}
end
