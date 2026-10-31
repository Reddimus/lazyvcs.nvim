return function(ctx)
	local h, api = ctx.helpers, vim.api
	local function setup()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	end
	local function target(f)
		return {
			vcs = "svn",
			root = f.root,
			relpath = "sample.txt",
			section = "changes",
			change_kind = "deleted",
			wc_item = "deleted",
		}
	end
	local function load(f)
		local result, failure, done
		require("lazyvcs.backends").load_diff_target_async(target(f), function(value, err)
			result, failure, done = value, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "typed SVN comparison did not load", 15000)
		return assert(result, failure)
	end
	local function snapshot(comparison, expected)
		assert(comparison.presence.right == expected, "scheduled deletion falsely proves physical absence")
		assert(not comparison.editable_side and comparison.right.source.kind == "empty")
		assert(comparison.right.bytes == "" and #comparison.right.lines == 0, "logical deleted snapshot changed")
	end
	local cases = {
		{
			"test_svn_diff_style_sidebar_kept_delete_native_enter",
			function()
				setup()
				for _, keep in ipairs({ true, false }) do
					local f = h.make_svn_fixture()
					h.exec(
						keep and { "svn", "delete", "--force", "--keep-local", "sample.txt" }
							or { "svn", "delete", "--force", "sample.txt" },
						f.root
					)
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
							if node.type == "file" and node.path == f.file then
								row = n
								return true
							end
						end
					end, "sidebar deleted file", 15000)
					api.nvim_set_current_win(sidebar.winid)
					api.nvim_win_set_cursor(sidebar.winid, { row, 0 })
					api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
					local session
					ctx.wait_for(function()
						for _, s in ipairs(require("lazyvcs.state").list()) do
							if s.source_path == f.file and s.phase == "active" then
								session = s
								return true
							end
						end
					end, "sidebar diff", 15000)
					assert((vim.uv.fs_lstat(f.file) ~= nil) == keep)
					assert(
						session.presence.right == (keep and "unknown" or "absent"),
						"sidebar confused schedule with physical absence"
					)
					assert((session.rail ~= nil) == not keep)
					assert(
						(vim.wo[session.editable_win].winbar:find("no file in worktree", 1, true) ~= nil) == not keep
					)
					assert(session.readonly_comparison and not vim.bo[session.editable_bufnr].modifiable)
					assert(vim.deep_equal(api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), { "" }))
					require("lazyvcs.actions").close(session)
					public.source_control_close()
				end
			end,
		},
		{
			"test_svn_diff_style_typed_delete_pure_resolution_and_disk_evidence",
			function()
				setup()
				local backend = require("lazyvcs.backends.svn")
				for _, keep in ipairs({ true, false }) do
					local f = h.make_svn_fixture()
					h.exec(
						keep and { "svn", "delete", "--force", "--keep-local", "sample.txt" }
							or { "svn", "delete", "--force", "sample.txt" },
						f.root
					)
					assert(
						backend.resolve_diff_target(target(f)).presence.right == "unknown",
						"pure resolver asserted physical absence"
					)
					snapshot(load(f), keep and "unknown" or "absent")
				end
			end,
		},
	}
	for _, keep in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_svn_diff_style_legacy_resolved_delete_" .. (keep and "keep_local" or "missing"),
			function()
				setup()
				local f = h.make_svn_fixture()
				h.exec(
					keep and { "svn", "delete", "--force", "--keep-local", "sample.txt" }
						or { "svn", "delete", "--force", "sample.txt" },
					f.root
				)
				local backend = require("lazyvcs.backends.svn")
				local failures = {}
				for _, loader in ipairs({ require("lazyvcs.backends"), backend }) do
					local resolved = assert(backend.resolve_diff_target(target(f)))
					resolved.presence = nil
					resolved.metadata = { legacy = "retained" }
					local before = vim.deepcopy(resolved)
					local notify, messages, task = vim.notify, {}, nil
					vim.notify = function(message)
						messages[#messages + 1] = tostring(message)
					end
					local ok, err = xpcall(function()
						local result, failure, calls = nil, nil, 0
						task = loader.load_diff_target_async(resolved, function(value, why)
							result, failure, calls = value, why, calls + 1
						end)
						ctx.wait_for(function()
							return calls > 0 or #messages > 0
						end, "legacy target did not settle", 15000)
						assert(
							calls == 1 and task.done and not task.cancelled,
							"legacy target stranded: " .. table.concat(messages, "; ")
						)
						assert(result, failure)
						snapshot(result, keep and "unknown" or "absent")
						assert(result.presence.left == "unknown", "legacy metadata invented left-side presence")
						assert(vim.deep_equal(result.metadata, before.metadata) and result.title == before.title)
						assert(
							vim.deep_equal(resolved, before) and resolved.presence == nil,
							"caller input was mutated"
						)
						assert(#messages == 0, table.concat(messages, "; "))
					end, debug.traceback)
					vim.notify = notify
					if task then
						task:kill()
					end
					if not ok then
						failures[#failures + 1] = err
					end
				end
				assert(#failures == 0, table.concat(failures, "\n"))
			end,
		}
	end

	for _, mode in ipairs({ "error", "cancel", "deadline", "link" }) do
		cases[#cases + 1] = {
			"test_svn_diff_style_typed_delete_existence_" .. mode,
			function()
				setup()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "delete", "--force", "sample.txt" }, f.root)
				if mode == "link" then
					local linked, why = vim.uv.fs_symlink(f.root .. "/missing-target", f.file)
					if not linked then
						error({ lazyvcs_skip = "file symlink unavailable: " .. tostring(why) })
					end
					snapshot(load(f), "unknown")
					return
				end
				local original, held, calls, task = vim.uv.fs_lstat, nil, 0, nil
				vim.uv.fs_lstat = function(path, callback)
					if path == f.file and callback then
						held = callback
						return {}
					end
					return original(path, callback)
				end
				local ok, err = xpcall(function()
					local result, failure
					task = require("lazyvcs.backends").load_diff_target_async(target(f), function(value, why)
						result, failure, calls = value, why, calls + 1
					end, { timeout_ms = 15000 })
					ctx.wait_for(function()
						return held ~= nil
					end, "typed deletion must inspect disk", 15000)
					if mode == "cancel" then
						task:kill()
					elseif mode == "deadline" then
						ctx.wait_for(function()
							return calls == 1
						end, "filesystem deadline failed", 17000)
						assert(not result and failure:lower():find("timed out", 1, true))
					end
					assert(held)(mode == "error" and "EACCES: permission denied" or "ENOENT: missing")
					vim.wait(80, function()
						return false
					end, 10)
					if mode == "error" then
						snapshot(assert(result, failure), "unknown")
					elseif mode == "cancel" then
						assert(calls == 0, "cancelled read published")
					else
						assert(calls == 1 and not result, "late read replaced deadline")
					end
				end, debug.traceback)
				vim.uv.fs_lstat = original
				if task then
					task:kill()
				end
				assert(ok, err)
			end,
		}
	end
	return cases
end
