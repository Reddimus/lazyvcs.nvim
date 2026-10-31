return function(ctx)
	local h, api = ctx.helpers, vim.api
	local function target(f, path, added)
		return {
			vcs = "git",
			root = f.root,
			relpath = path,
			section = "staged",
			status = added and "A " or "D ",
			change_kind = added and "added" or "deleted",
		}
	end
	local function fixture(path, added, count)
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
		h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
		local full = f.root .. "/" .. path
		if added then
			vim.fn.mkdir(full, "p")
			h.write_file(full .. "/child.txt", "old child\n")
		else
			h.write_file(full, "old file\n")
		end
		h.exec({ "git", "--literal-pathspecs", "add", "--", path }, f.root)
		h.exec({ "git", "commit", "-m", "original entry" }, f.root)
		if added then
			assert(vim.fn.delete(full, "rf") == 0)
			h.write_file(full, "replacement file\n")
		else
			assert(vim.uv.fs_unlink(full))
			vim.fn.mkdir(full, "p")
			for n = 1, count or 1 do
				h.write_file(full .. "/child-" .. n .. ".txt", "new child\n")
			end
		end
		h.exec({ "git", "--literal-pathspecs", "add", "-A", "--", path }, f.root)
		return f, full
	end
	local function load(f, path, added)
		local result, failure, done
		require("lazyvcs.backends").load_diff_target_async(target(f, path, added), function(value, err)
			result, failure, done = value, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "staged replacement loader did not settle", 15000)
		result = assert(result, failure)
		assert(result.presence.left == (added and "absent" or "present"))
		assert(result.presence.right == (added and "present" or "absent"))
		assert(result.left.bytes == (added and "" or "old file\n"))
		assert(result.right.bytes == (added and "replacement file\n" or ""))
		return result
	end
	local function enter(f, full, added)
		local public = require("lazyvcs")
		local sidebar = public.source_control_open({ path = f.root })
		ctx.wait_for(function()
			return sidebar.lazyvcs_repo_cache and sidebar.lazyvcs_repo_cache[f.root] and not sidebar.lazyvcs_discovering
		end, "replacement sidebar discovery", 15000)
		require("lazyvcs.source_control.ops").load_repo_details(sidebar, f.root)
		sidebar.lazyvcs_force_expand = sidebar.lazyvcs_force_expand or {}
		sidebar.lazyvcs_force_expand[require("lazyvcs.source_control.model").repo_changes_id(f.root)] = true
		require("lazyvcs.source_control.native").navigate(sidebar)
		local row
		ctx.wait_for(function()
			for n, node in pairs(sidebar.lazyvcs_line_nodes or {}) do
				if node.type == "file" and node.path == full and node.extra.section == "staged" then
					assert(
						node.extra.status:sub(1, 1) == (added and "A" or "D"),
						"not the actual replacement status row"
					)
					row = n
					return true
				end
			end
		end, "actual staged replacement row", 15000)
		api.nvim_set_current_win(sidebar.winid)
		api.nvim_win_set_cursor(sidebar.winid, { row, 0 })
		api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
		local s
		ctx.wait_for(function()
			for _, value in ipairs(require("lazyvcs.state").list()) do
				if value.source_path == full and value.phase == "active" then
					s = value
					return true
				end
			end
		end, "staged replacement Enter view", 15000)
		assert(s.readonly_comparison and not vim.bo[s.editable_bufnr].modifiable)
		assert(
			s.presence.left == (added and "absent" or "present")
				and s.presence.right == (added and "present" or "absent")
		)
		assert(api.nvim_get_current_win() == (added and s.editable_win or s.base_win))
		require("lazyvcs.actions").close(s)
		public.source_control_close()
	end
	local cases = {}
	for _, added in ipairs({ true, false }) do
		cases[#cases + 1] = {
			"test_core_diff_style_staged_replacement_" .. (added and "directory_to_file" or "file_to_directory"),
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f, full = fixture("literal-[x]", added)
				load(f, "literal-[x]", added)
				enter(f, full, added)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_diff_style_staged_replacement_large_subtree_bounded",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f, full = fixture("large-[x]", false, 100)
			local result = vim.system(
				{ "git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", "large-[x]" },
				{ cwd = f.root, text = false }
			):wait()
			assert(
				result.code == 0 and #result.stdout > 2 * (2 * #"large-[x]" + 2048),
				"fixture does not exceed previous metadata limit"
			)
			load(f, "large-[x]", false)
			enter(f, full, false)
		end,
	}
	for _, extended in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_core_diff_style_staged_replacement_literal_" .. (extended and "posix" or "portable"),
			function()
				if extended and vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX-only filename bytes; portable D/F matrix still runs" })
				end
				local paths = extended and { "literal*", ":(glob)*", "control\npath", "tab\tpath" }
					or { "[x]", "unicode-é", "-leading" }
				for _, path in ipairs(paths) do
					for _, added in ipairs({ true, false }) do
						local f = fixture(path, added)
						local before = vim.env.GIT_GLOB_PATHSPECS
						vim.env.GIT_GLOB_PATHSPECS = "1"
						local ok, err = xpcall(function()
							load(f, path, added)
						end, debug.traceback)
						local unchanged = vim.env.GIT_GLOB_PATHSPECS == "1"
						vim.env.GIT_GLOB_PATHSPECS = before
						assert(ok, err)
						assert(unchanged, "entry query changed inherited Git settings")
						h.cleanup()
					end
				end
			end,
		}
	end
	return cases
end
