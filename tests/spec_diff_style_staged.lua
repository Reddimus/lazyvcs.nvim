return function(ctx)
	local h, api = ctx.helpers, vim.api
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function load(target)
		local value, failure, done
		require("lazyvcs.backends").load_diff_target_async(target, function(result, err)
			value, failure, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "staged target did not settle", 15000)
		return assert(value, failure)
	end
	local function target(f, relpath, kind, status)
		return { vcs = "git", root = f.root, relpath = relpath, section = "staged", change_kind = kind, status = status }
	end
	local cases = {}
	for _, scenario in ipairs({
		"added",
		"deleted",
		"unborn",
		"empty",
		"renamed",
		"stale_added",
		"stale_deleted",
		"empty_head",
		"empty_added",
		"copied",
		"intent",
	}) do
		cases[#cases + 1] = {
			"test_core_diff_style_staged_" .. scenario,
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
				local t, left, right, lp, rp
				if scenario == "added" or scenario == "unborn" or scenario == "empty_added" then
					if scenario == "unborn" then
						f.root = h.tempdir()
						h.exec({ "git", "init" }, f.root)
					end
					write(f.root .. "/new-[x].txt", scenario == "empty_added" and "" or "added\n")
					h.exec({ "git", "add", "--", "new-[x].txt" }, f.root)
					t, left, right, lp, rp =
						target(f, "new-[x].txt", "added", "A "),
						"",
						scenario == "empty_added" and "" or "added\n",
						"absent",
						"present"
				elseif scenario == "deleted" then
					left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					h.exec({ "git", "rm", "--cached", "sample.txt" }, f.root)
					t, right, lp, rp = target(f, "sample.txt", "deleted", "D "), "", "present", "absent"
				elseif scenario == "empty" then
					write(f.file, "")
					h.exec({ "git", "add", "sample.txt" }, f.root)
					t, left, right, lp, rp =
						target(f, "sample.txt", "modified", "M "),
						h.exec({ "git", "show", "HEAD:sample.txt" }, f.root),
						"",
						"present",
						"present"
				elseif scenario == "empty_head" then
					write(f.file, "")
					h.exec({ "git", "add", "sample.txt" }, f.root)
					h.exec({ "git", "commit", "-m", "empty base" }, f.root)
					write(f.file, "new content\n")
					h.exec({ "git", "add", "sample.txt" }, f.root)
					t, left, right, lp, rp =
						target(f, "sample.txt", "modified", "M "), "", "new content\n", "present", "present"
				elseif scenario == "intent" then
					left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					h.exec({ "git", "rm", "--cached", "sample.txt" }, f.root)
					h.exec({ "git", "add", "-N", "sample.txt" }, f.root)
					h.exec({ "git", "update-index", "--assume-unchanged", "sample.txt" }, f.root)
					t, right, lp, rp = target(f, "sample.txt", "deleted", "D "), "", "present", "absent"
				elseif scenario == "copied" then
					left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					write(f.root .. "/new-[x].txt", left)
					h.exec({ "git", "add", "--", "new-[x].txt" }, f.root)
					t, right, lp, rp = target(f, "new-[x].txt", "copied", "C "), left, "present", "present"
					t.renamed_from = "sample.txt"
				elseif scenario == "renamed" then
					left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					h.exec({ "git", "mv", "sample.txt", "new-[x].txt" }, f.root)
					t, right, lp, rp = target(f, "new-[x].txt", "renamed", "R "), left, "present", "present"
					t.renamed_from = "sample.txt"
				else
					left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					write(f.file, "current index\n")
					h.exec({ "git", "add", "sample.txt" }, f.root)
					t = target(
						f,
						"sample.txt",
						scenario == "stale_added" and "added" or "deleted",
						scenario == "stale_added" and "A " or "D "
					)
					right, lp, rp = "current index\n", "present", "present"
				end
				local comparison = load(t)
				assert(
					comparison.presence and comparison.presence.left == lp and comparison.presence.right == rp,
					"missing/incorrect staged entry evidence"
				)
				assert(
					comparison.left.bytes == left and comparison.right.bytes == right,
					"staged snapshots differ from actual endpoints"
				)
				local node = {
					type = "file",
					path = f.root .. "/" .. t.relpath,
					extra = vim.tbl_extend("force", t, { repo_root = f.root }),
				}
				local state = {
					path = f.root,
					editor_winid = api.nvim_get_current_win(),
					lazyvcs_repo_cache = { [f.root] = { root = f.root, vcs = "git", name = "fixture" } },
				}
				require("lazyvcs.source_control.ops").open_change(state, node)
				local s
				ctx.wait_for(function()
					s = require("lazyvcs.state").current()
					return s and s.phase == "active"
				end, "staged sidebar view did not open", 15000)
				ctx.wait_for(function()
					return (s.rail ~= nil) == (lp == "absent" or rp == "absent")
				end, "staged rail missing")
				assert(not vim.bo[s.editable_bufnr].modifiable and s.readonly_comparison)
				assert(s.presence.left == lp and s.presence.right == rp)
				if rp == "absent" then
					assert(api.nvim_get_current_win() == s.base_win, "deleted index keeps focus on absent side")
					assert(
						vim.wo[s.editable_win].winbar:lower():find("no file at index", 1, true),
						"index absence mislabeled worktree"
					)
				elseif lp == "absent" then
					assert(
						vim.wo[s.base_win].winbar:lower():find("no file at head", 1, true),
						"HEAD absence mislabeled index"
					)
				else
					assert(not s.rail, "present empty snapshot collapsed")
				end
				require("lazyvcs.actions").close(s)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_diff_style_staged_conflict_metadata_is_not_absence",
		function()
			local f = h.make_git_fixture()
			local object = h.exec({ "git", "rev-parse", "HEAD:sample.txt" }, f.root):gsub("%s+$", "")
			h.exec({ "git", "update-index", "--force-remove", "sample.txt" }, f.root)
			local input = "100644 " .. object .. " 1\tsample.txt\n100644 " .. object .. " 2\tsample.txt\n"
			local result = vim.system({ "git", "update-index", "--index-info" }, { cwd = f.root, stdin = input }):wait()
			assert(result.code == 0, result.stderr)
			local value, failure, done
			require("lazyvcs.backends").load_diff_target_async(
				target(f, "sample.txt", "deleted", "D "),
				function(v, err)
					value, failure, done = v, err, true
				end
			)
			ctx.wait_for(function()
				return done
			end, "conflict stages did not settle")
			assert(not value and failure:find("index entry", 1, true), "conflict-only index falsely became absent")
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_captured_blobs_survive_ref_index_change",
		function()
			local f = h.make_git_fixture()
			local left = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
			write(f.file, "captured index\n")
			h.exec({ "git", "add", "sample.txt" }, f.root)
			local util, start, changed = require("lazyvcs.util"), require("lazyvcs.util").system_start, false
			local ok, err = xpcall(function()
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[2] == "show" and not changed then
						changed = true
						write(f.file, "later index and HEAD\n")
						h.exec({ "git", "add", "sample.txt" }, f.root)
						h.exec({ "git", "commit", "-m", "later" }, f.root)
					end
					return start(args, opts, done)
				end
				local value = load(target(f, "sample.txt", "modified", "M "))
				assert(
					changed and value.left.bytes == left and value.right.bytes == "captured index\n",
					"snapshot read mutable refs after metadata"
				)
			end, debug.traceback)
			util.system_start = start
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_metadata_cancel_stops_late_result",
		function()
			local f = h.make_git_fixture()
			local util, start = require("lazyvcs.util"), require("lazyvcs.util").system_start
			local held, captured, following, finished, killed = nil, nil, 0, false, false
			local task
			local ok, err = xpcall(function()
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[2] == "ls-files" then
						return start(args, opts, function(result, why)
							captured = { result, why }
							held = done
						end)
					end
					if held then
						following = following + 1
					end
					return start(args, opts, done)
				end
				task = require("lazyvcs.backends").load_diff_target_async(
					target(f, "sample.txt", "modified", "M "),
					function()
						finished = true
					end
				)
				ctx.wait_for(function()
					return held ~= nil
				end, "index metadata was not held")
				killed = task:kill()
				assert(held)(unpack(assert(captured)))
				vim.wait(50, function()
					return false
				end)
				assert(killed and not finished and following == 0, "cancelled metadata started blob reads or completed")
			end, debug.traceback)
			if task then
				task:kill()
			end
			util.system_start = start
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_refresh_rechecks_loaded_endpoints",
		function()
			local f = h.make_git_fixture()
			write(f.root .. "/added.txt", "first\n")
			h.exec({ "git", "add", "added.txt" }, f.root)
			local value = load(target(f, "added.txt", "added", "A "))
			assert(value.presence.left == "absent")
			h.exec({ "git", "commit", "-m", "add file" }, f.root)
			write(f.root .. "/added.txt", "second\n")
			h.exec({ "git", "add", "added.txt" }, f.root)
			local updated = load(value)
			assert(updated.presence.left == "present" and updated.presence.right == "present")
			assert(
				updated.left.bytes == "first\n" and updated.right.bytes == "second\n",
				"refresh reused prior entry capture"
			)
		end,
	}
	for _, failure in ipairs({ "error", "truncated", "malformed" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_staged_metadata_" .. failure,
			function()
				local f = h.make_git_fixture()
				local util, start = require("lazyvcs.util"), require("lazyvcs.util").system_start
				local done, value, why
				local ok, err = xpcall(function()
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, callback)
						if args[2] == "ls-files" then
							return start(args, opts, function(raw)
								assert(raw and raw.code == 0)
								if failure == "error" then
									raw.code, raw.stderr = 128, "metadata unavailable"
								elseif failure == "truncated" then
									raw.stdout_truncated = true
								else
									raw.stdout = "malformed\0"
								end
								callback(raw)
							end)
						end
						return start(args, opts, callback)
					end
					require("lazyvcs.backends").load_diff_target_async(
						target(f, "sample.txt", "deleted", "D "),
						function(v, e)
							value, why, done = v, e, true
						end
					)
					ctx.wait_for(function()
						return done
					end, "metadata error did not settle")
					assert(not value and why, "unverifiable metadata invented absent snapshot")
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_diff_style_staged_native_sidebar_enter",
		function()
			for _, added in ipairs({ true, false }) do
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				local relpath = added and "added.txt" or "sample.txt"
				if added then
					write(f.root .. "/added.txt", "new\n")
					h.exec({ "git", "add", "added.txt" }, f.root)
				else
					h.exec({ "git", "rm", "--cached", "sample.txt" }, f.root)
				end
				local public = require("lazyvcs")
				local sidebar = public.source_control_open({ path = f.root })
				ctx.wait_for(function()
					return sidebar.lazyvcs_repo_cache
						and sidebar.lazyvcs_repo_cache[f.root]
						and not sidebar.lazyvcs_discovering
				end, "sidebar discovery", 15000)
				require("lazyvcs.source_control.ops").load_repo_details(sidebar, f.root)
				sidebar.lazyvcs_force_expand = sidebar.lazyvcs_force_expand or {}
				sidebar.lazyvcs_force_expand[require("lazyvcs.source_control.model").repo_changes_id(f.root)] = true
				require("lazyvcs.source_control.native").navigate(sidebar)
				local row
				ctx.wait_for(function()
					for n, node in pairs(sidebar.lazyvcs_line_nodes or {}) do
						if
							node.type == "file"
							and node.path == f.root .. "/" .. relpath
							and node.extra.section == "staged"
						then
							row = n
							return true
						end
					end
				end, "staged sidebar row", 15000)
				api.nvim_set_current_win(sidebar.winid)
				api.nvim_win_set_cursor(sidebar.winid, { row, 0 })
				api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
				local session
				ctx.wait_for(function()
					for _, value in ipairs(require("lazyvcs.state").list()) do
						if value.source_path == f.root .. "/" .. relpath and value.phase == "active" then
							session = value
							return true
						end
					end
				end, "staged Enter view", 15000)
				ctx.wait_for(function()
					return session.rail ~= nil
				end, "staged Enter rail")
				assert(session.presence[added and "left" or "right"] == "absent")
				assert(api.nvim_get_current_win() == (added and session.editable_win or session.base_win))
				require("lazyvcs.actions").close(session)
				public.source_control_close()
			end
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_legacy_resolved_rename",
		function()
			local f = h.make_git_fixture()
			local expected = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
			h.exec({ "git", "mv", "sample.txt", "renamed.txt" }, f.root)
			local t = target(f, "renamed.txt", "renamed", "R ")
			t.renamed_from = "sample.txt"
			local resolved = assert(require("lazyvcs.backends.git").resolve_diff_target(t))
			resolved.renamed_from = nil
			resolved.presence = nil
			local before = vim.deepcopy(resolved)
			local value = load(resolved)
			assert(value.left.bytes == expected and value.right.bytes == expected)
			assert(value.presence.left == "present" and value.presence.right == "present")
			assert(vim.deep_equal(resolved, before), "legacy caller target mutated")
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_binary_and_size_limits",
		function()
			local f = h.make_git_fixture()
			local bytes = "native binary\0payload\n"
			write(f.root .. "/binary.dat", bytes)
			h.exec({ "git", "add", "binary.dat" }, f.root)
			local value = load(target(f, "binary.dat", "added", "A "))
			assert(value.right.bytes == bytes and value.presence.right == "present", "raw binary identity changed")
			write(f.root .. "/large.txt", string.rep("x", 1024 * 1024 + 1))
			h.exec({ "git", "add", "large.txt" }, f.root)
			local result, failure, done
			require("lazyvcs.backends").load_diff_target_async(target(f, "large.txt", "added", "A "), function(v, err)
				result, failure, done = v, err, true
			end)
			ctx.wait_for(function()
				return done
			end, "large snapshot limit did not settle")
			assert(not result and failure:find("1 MiB", 1, true), "staged preview size limit bypassed")
		end,
	}
	cases[#cases + 1] = {
		"test_core_diff_style_staged_pure_resolution_keeps_unknown",
		function()
			local resolved = assert(require("lazyvcs.backends.git").resolve_diff_target({
				root = "/not-probed",
				relpath = "file.txt",
				section = "staged",
				change_kind = "added",
				status = "A ",
			}))
			assert(resolved.presence.left == "unknown" and resolved.presence.right == "unknown")
			assert(resolved.left.source.object == "HEAD:file.txt" and resolved.right.source.object == ":0:file.txt")
		end,
	}
	return cases
end
