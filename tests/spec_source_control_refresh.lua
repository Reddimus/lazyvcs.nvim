return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native, model, ops =
		require("lazyvcs.source_control.native"),
		require("lazyvcs.source_control.model"),
		require("lazyvcs.source_control.ops")
	local function setup(source)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			source_control = vim.tbl_extend(
				"force",
				{ remote_refresh = "manual", auto_expand_width = false },
				source or {}
			),
		})
	end
	local function guarded(fn)
		return function()
			setup()
			local ok, err = xpcall(fn, debug.traceback)
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			if not ok then
				error(err, 0)
			end
		end
	end
	local function settled(s)
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "summary did not finish", 15000)
	end
	local function open(root)
		local s = native.open({ path = root })
		settled(s)
		return s
	end
	local function key(s, lhs)
		for _, map in ipairs(api.nvim_buf_get_keymap(s.bufnr, "n")) do
			if map.lhs == lhs then
				return map.callback()
			end
		end
		error("mapping missing: " .. lhs)
	end
	local function details(s, root)
		s.lazyvcs_expanded[model.repo_changes_id(root)] = false
		ops.open_repo(s, { type = "repo_changes", path = root, extra = { repo_root = root } }, function() end)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[root].details_loaded
		end, "details did not finish", 15000)
	end
	local function load(loader, repo, opts)
		local done, result, err
		loader(repo, opts or {}, function(args, command_opts, callback)
			return require("lazyvcs.util").system_start(
				args,
				{ cwd = repo.root, timeout = command_opts.timeout_ms },
				callback
			)
		end, function(value, load_err)
			result, err, done = value, load_err, true
		end)
		ctx.wait_for(function()
			return done
		end, "loader did not finish", 15000)
		return assert(result, err)
	end
	local function remote_section(status)
		for _, section in ipairs(status.sections) do
			if section.id == "remote" then
				return section
			end
		end
	end
	local function incoming()
		local f = h.make_svn_fixture()
		local other = h.tempdir() .. "/other"
		h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
		h.write_file(other .. "/sample.txt", "incoming\ncontents\n")
		h.exec({ "svn", "commit", "-m", "incoming", other }, other)
		return f
	end
	local cases = {
		{
			"test_svn_source_control_directory_externals_own_their_changes",
			function()
				local f, external = h.make_svn_fixture(), h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "propset", "svn:externals", h.file_url(external.repo) .. " ext", f.root }, f.root)
				h.exec({ "svn", "commit", "-m", "external", f.root }, f.root)
				h.exec({ "svn", "update", f.root }, f.root)
				h.write_file(f.root .. "/ext/sample.txt", "external edit\n")
				local parent = { root = f.root, name = "parent", vcs = "svn" }
				local child = { root = f.root .. "/ext", name = "external", vcs = "svn" }
				for _, remote in ipairs({ false, true }) do
					local summary = load(model.load_repo_summary_async, parent, { remote_refresh = remote })
					local detail = load(model.load_repo_details_async, parent, { remote_refresh = remote })
					assert(
						summary.counts.local_changes == 0 and detail.counts.local_changes == 0 and #detail.sections == 0,
						"parent status must exclude directory-external descendants"
					)
					local owned = load(model.load_repo_details_async, child, { remote_refresh = remote })
					assert(owned.counts.local_changes == 1 and owned.sections[1].items[1].extra.repo_root == child.root)
				end
				local s = open(f.root)
				local roots = {}
				for _, repo in ipairs(s.lazyvcs_repo_specs) do
					roots[repo.root] = true
				end
				assert(roots[parent.root] and roots[child.root], "external working copy must be discovered separately")
				s.lazyvcs_commit_drafts[f.root] = "keep parent draft"
				setup({ confirm_mutations = false })
				ops.commit_repo(s, { path = f.root })
				ctx.wait_for(function()
					return not require("lazyvcs.state").get_repo_job(f.root)
				end, "parent commit preflight did not finish", 15000)
				assert(
					s.lazyvcs_commit_drafts[f.root] == "keep parent draft"
						and not require("lazyvcs.state").get_repo_job(f.root),
					"external edit must not admit an empty parent commit"
				)
			end,
		},
		{
			"test_svn_source_control_noop_commit_preserves_draft",
			function()
				local f = h.make_svn_fixture()
				setup({ confirm_mutations = false })
				local repo = { root = f.root, name = "noop", vcs = "svn" }
				local status = load(model.load_repo_details_async, repo, {})
				h.exec({ "svn", "revert", f.file }, f.root)
				h.write_file(f.root .. "/unversioned", "not scheduled\n")
				local state = {
					path = f.root,
					lazyvcs_repo_cache = { [f.root] = status },
					lazyvcs_commit_drafts = { [f.root] = "keep after no-op" },
					lazyvcs_render = function() end,
				}
				ops.commit_repo(state, { path = f.root })
				ctx.wait_for(function()
					return state.lazyvcs_repo_cache[f.root] == nil
				end, "no-op commit did not finish", 15000)
				assert(
					state.lazyvcs_commit_drafts[f.root] == "keep after no-op",
					"SVN no-op commit must preserve the draft"
				)
				assert(h.exec({ "svn", "log", "-l", "1", h.file_url(f.repo) }, f.root):find("init", 1, true))
				h.write_file(f.root .. "/café.txt", "Unicode path\n")
				h.exec({ "svn", "add", f.root .. "/café.txt" }, f.root)
				state.lazyvcs_repo_cache[f.root] = load(model.load_repo_details_async, repo, {})
				state.lazyvcs_commit_drafts[f.root] = "Unicode café commit"
				ops.commit_repo(state, { path = f.root })
				ctx.wait_for(function()
					return state.lazyvcs_repo_cache[f.root] == nil
				end, "Unicode commit did not finish", 15000)
				assert(state.lazyvcs_commit_drafts[f.root] == "", "successful Unicode commit must clear the draft")
				-- svn log text uses the console code page on Windows; --xml is always UTF-8.
				assert(
					h.exec({ "svn", "log", "--xml", "-l", "1", h.file_url(f.repo) }, f.root)
						:find("Unicode café commit", 1, true)
				)
			end,
		},

		{
			"test_svn_source_control_translated_commit_clears_draft",
			function()
				local f = h.make_svn_fixture()
				setup({ confirm_mutations = false })
				local repo = { root = f.root, name = "translated", vcs = "svn" }
				local state = {
					path = f.root,
					lazyvcs_repo_cache = { [f.root] = load(model.load_repo_details_async, repo, {}) },
					lazyvcs_commit_drafts = { [f.root] = "translated commit" },
					lazyvcs_render = function() end,
				}
				local util, original = require("lazyvcs.util"), require("lazyvcs.util").system_start
				local commits = 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "commit" then
						commits = commits + 1
						done({ code = 0, stdout = "Enviando        sample.txt\nRevisión 7 confirmada.\n", stderr = "" })
						return {}
					end
					return original(args, opts, done)
				end
				local ok, err = xpcall(function()
					ops.commit_repo(state, { path = f.root })
					ctx.wait_for(function()
						return state.lazyvcs_repo_cache[f.root] == nil
					end, "translated commit did not finish", 15000)
					assert(commits == 1, "translated SVN commit result was not exercised")
					assert(
						state.lazyvcs_commit_drafts[f.root] == "",
						"successful translated SVN commit must clear the draft"
					)
				end, debug.traceback)
				util.system_start = original
				assert(ok, err)
			end,
		},
		{
			"test_source_control_gone_upstream_remains_visible",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "restore", "--", "sample.txt" }, f.root)
				local branch = vim.trim(h.exec({ "git", "branch", "--show-current" }, f.root))
				local bare = h.tempdir() .. "/origin.git"
				h.exec({ "git", "init", "--bare", bare }, f.root)
				h.exec({ "git", "remote", "add", "origin", bare }, f.root)
				h.exec({ "git", "push", "-u", "origin", "HEAD" }, f.root)
				h.exec({ "git", "push", "origin", "HEAD:refs/heads/keep" }, f.root)
				h.exec({ "git", "--git-dir", bare, "update-ref", "-d", "refs/heads/" .. branch }, f.root)
				setup({ remote_refresh = "on_open", show_clean = false })
				local s = open(f.root)
				local function check()
					local status = s.lazyvcs_repo_cache[f.root]
					assert(
						status.upstream_gone == true and status.sync.status == "upstream_gone",
						"pruned upstream must show a missing-upstream warning"
					)
					assert(
						status.sync.highlight == "DiagnosticWarn" and s.lazyvcs_repo_visibility[f.root],
						"missing upstream must remain visible"
					)
					assert(status.upstream == "origin/" .. branch)
					native.render(s)
					local marks = api.nvim_buf_get_extmarks(
						s.bufnr,
						api.nvim_get_namespaces().lazyvcs_native,
						0,
						-1,
						{ details = true }
					)
					local warning
					for _, mark in ipairs(marks) do
						if mark[4].hl_group == "DiagnosticWarn" then
							warning = mark
						end
					end
					assert(warning, "missing-upstream badge must use DiagnosticWarn")
					local cell = warning[3]
					assert(warning[4].end_col > cell, "warning must cover a badge cell")
					for _, mark in ipairs(marks) do
						if mark ~= warning and mark[2] == warning[2] and mark[3] <= cell then
							assert(
								warning[4].priority > mark[4].priority,
								"DiagnosticWarn must outrank the row highlight at the badge cell"
							)
						end
					end
				end
				check()
				details(s, f.root)
				check()
				for _, lhs in ipairs({ "S", "H", "H" }) do
					key(s, lhs)
					check()
				end
				assert(
					vim.trim(h.exec({ "git", "config", "branch." .. branch .. ".merge" }, f.root))
						== "refs/heads/" .. branch
				)
				assert(
					h.exec({ "git", "ls-remote", "origin", "refs/heads/" .. branch }, f.root) == "",
					"warning must not republish upstream"
				)
				native.close()
				h.exec({ "git", "push", "origin", "HEAD:refs/heads/" .. branch }, f.root)
				local repo = { root = f.root, name = "control", vcs = "git" }
				local control = load(model.load_repo_summary_async, repo, { remote_refresh = true })
				assert(
					not control.upstream_gone and control.sync.status == "synced",
					"valid upstream must remain synchronized"
				)
			end,
		},

		{
			"test_source_control_auto_refresh_survives_sidebar_lifetimes",
			function()
				local f = h.make_git_fixture()
				local bare = h.tempdir() .. "/origin.git"
				h.exec({ "git", "init", "--bare", bare }, f.root)
				h.exec({ "git", "remote", "add", "origin", bare }, f.root)
				h.exec({ "git", "push", "-u", "origin", "HEAD" }, f.root)
				local util, original = require("lazyvcs.util"), require("lazyvcs.util").system_start
				local calls = 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" and args[2] == "fetch" then
						calls = calls + 1
					end
					return original(args, opts, done)
				end
				local ok, err = xpcall(function()
					setup({ remote_refresh = "on_open", remote_refresh_interval_ms = 60000 })
					open(f.root)
					native.close()
					local s = open(f.root)
					assert(calls == 1, "reopening must not bypass automatic fetch interval")
					native.toggle()
					s = open(f.root)
					assert(calls == 1)
					vim.cmd.tabnew()
					open(f.root .. "/.")
					assert(calls == 1, "tabs must share automatic refresh admission")
					native.close()
					api.nvim_set_current_tabpage(s.tabid)
					native.refresh(true)
					settled(s)
					assert(calls == 2, "explicit refresh must bypass automatic admission")
					native.close()
					setup({ remote_refresh = "manual" })
					open(f.root)
					assert(calls == 2, "manual mode must not fetch automatically")
				end, debug.traceback)
				util.system_start = original
				if not ok then
					error(err, 0)
				end
			end,
		},
		{
			"test_svn_source_control_auto_refresh_survives_sidebar_lifetimes",
			function()
				local f = h.make_svn_fixture()
				local util, original = require("lazyvcs.util"), require("lazyvcs.util").system_start
				local calls = 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
						calls = calls + 1
					end
					return original(args, opts, done)
				end
				local ok, err = xpcall(function()
					setup({ remote_refresh = "on_open", remote_refresh_interval_ms = 60000 })
					open(f.root)
					native.close()
					local s = open(f.root)
					assert(calls == 1, "reopening must not bypass automatic SVN refresh interval")
					vim.cmd.tabnew()
					open(f.root .. "/.")
					assert(calls == 1)
					native.close()
					api.nvim_set_current_tabpage(s.tabid)
					native.refresh(true)
					settled(s)
					assert(calls == 2)
					native.close()
					setup({ remote_refresh = "manual" })
					open(f.root)
					assert(calls == 2)
				end, debug.traceback)
				util.system_start = original
				if not ok then
					error(err, 0)
				end
			end,
		},

		{
			"test_svn_source_control_presentation_preserves_incoming",
			function()
				local f = incoming()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.write_file(f.root .. "/z.txt", "z\n")
				vim.fn.mkdir(f.root .. "/nested", "p")
				h.exec({ "svn", "add", "--depth", "empty", f.root .. "/nested" }, f.root)
				h.write_file(f.root .. "/nested/zz.txt", "a\n")
				setup({ show_clean = false })
				local s = open(f.root)
				native.refresh(true)
				settled(s)
				details(s, f.root)
				local status = s.lazyvcs_repo_cache[f.root]
				s.lazyvcs_expanded[f.root .. "::section::untracked"] = true
				native.render(s)
				local expanded = vim.deepcopy(s.lazyvcs_expanded)
				local overrides = vim.deepcopy(s.lazyvcs_repo_visibility_overrides)
				local generation = s.lazyvcs_repo_generations[f.root]
				local util, original = require("lazyvcs.util"), require("lazyvcs.util").system_start
				local calls = 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(...)
					calls = calls + 1
					return original(...)
				end
				local ok, err = xpcall(function()
					for _, lhs in ipairs({ "S", "S", "S", "H", "H" }) do
						key(s, lhs)
						local paths = {}
						for _, node in ipairs(s.lazyvcs_line_nodes) do
							if node.type == "file" and node.extra.section == "untracked" then
								paths[#paths + 1] = node.extra.relpath
							end
						end
						assert(
							vim.deep_equal(
								paths,
								s.lazyvcs_changes_sort == "name" and { "z.txt", "nested/zz.txt" }
									or { "nested/zz.txt", "z.txt" }
							),
							"sort did not update rendered order"
						)
						assert(
							s.lazyvcs_repo_cache[f.root] == status and status.counts.remote == 1,
							"presentation changes must retain SVN incoming status"
						)
						assert(
							s.lazyvcs_repo_visibility[f.root] and remote_section(status),
							"presentation hid incoming repository"
						)
						assert(
							s.lazyvcs_repo_generations[f.root] == generation
								and vim.deep_equal(s.lazyvcs_expanded, expanded)
								and vim.deep_equal(s.lazyvcs_repo_visibility_overrides, overrides),
							"presentation invalidated repository state"
						)
					end
					vim.wait(30)
					assert(calls == 0, "presentation must not start VCS commands")
				end, debug.traceback)
				util.system_start = original
				if not ok then
					error(err, 0)
				end
			end,
		},

		{
			"test_source_control_details_survive_later_summary_refresh",
			function()
				local summary_loader, detail_loader = model.load_repo_summary_async, model.load_repo_details_async
				local ok, err = xpcall(function()
					for _, first in ipairs({ "detail", "summary" }) do
						local f = h.make_git_source_control_fixture()
						local s = open(f.root)
						local summary_done, detail_done
						---@diagnostic disable-next-line: duplicate-set-field
						model.load_repo_details_async = function(repo, opts, run, done)
							return detail_loader(repo, opts, run, function(value, load_err)
								detail_done = function()
									done(value, load_err)
								end
							end)
						end
						ops.open_repo(s, {
							type = "repo_changes",
							path = f.git_dirty,
							extra = { repo_root = f.git_dirty },
						}, function() end)
						ctx.wait_for(function()
							return detail_done ~= nil
						end, "B detail status not ready", 15000)
						assert(s.lazyvcs_repo_cache[f.git_dirty].loading_details)
						---@diagnostic disable-next-line: duplicate-set-field
						model.load_repo_summary_async = function(repo, opts, run, done)
							return summary_loader(repo, opts, run, function(value, load_err)
								if repo.root == f.git_dirty then
									summary_done = function()
										done(value, load_err)
									end
								else
									done(value, load_err)
								end
							end)
						end
						-- This is the same action dispatched by A's Refresh picker entry.
						ops.run_primary_action(s, {
							path = f.git_clean,
							extra = { repo_root = f.git_clean, action = "refresh" },
						})
						ctx.wait_for(function()
							return summary_done ~= nil
						end, "B refresh summary not ready", 15000)
						if first == "detail" then
							detail_done()
							summary_done()
						else
							summary_done()
							detail_done()
						end
						local status = s.lazyvcs_repo_cache[f.git_dirty]
						assert(
							not status.loading_details and not s.lazyvcs_loading_details[f.git_dirty],
							"B stayed at Loading changes after A refreshed (" .. first .. " completed first)"
						)
						assert(status.details_loaded and #status.sections > 0 and status.counts.local_changes == 1)
						native.render(s)
						local text = table.concat(api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n")
						assert(not text:find("Loading changes", 1, true), "B still renders Loading changes")
						model.load_repo_summary_async, model.load_repo_details_async = summary_loader, detail_loader
						native.close()
					end
				end, debug.traceback)
				model.load_repo_summary_async, model.load_repo_details_async = summary_loader, detail_loader
				if not ok then
					error(err, 0)
				end
			end,
		},
		{
			"test_source_control_summary_preserves_completed_and_pending_details",
			function()
				local summary_loader, detail_loader = model.load_repo_summary_async, model.load_repo_details_async
				local ok, err = xpcall(function()
					for _, first in ipairs({ "detail", "summary" }) do
						local f = h.make_git_fixture()
						local s = open(f.root)
						local summary_done, detail_done
						---@diagnostic disable-next-line: duplicate-set-field
						model.load_repo_summary_async = function(repo, opts, run, done)
							return summary_loader(repo, opts, run, function(value, load_err)
								summary_done = function()
									done(value, load_err)
								end
							end)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						model.load_repo_details_async = function(repo, opts, run, done)
							return detail_loader(repo, opts, run, function(value, load_err)
								detail_done = function()
									done(value, load_err)
								end
							end)
						end
						native.refresh(true)
						ctx.wait_for(function()
							return summary_done ~= nil
						end, "summary not ready", 15000)
						ops.open_repo(
							s,
							{ type = "repo_changes", path = f.root, extra = { repo_root = f.root } },
							function() end
						)
						ctx.wait_for(function()
							return detail_done ~= nil
						end, "details not ready", 15000)
						if first == "detail" then
							detail_done()
							assert(
								s.lazyvcs_repo_cache[f.root].loading_summary,
								"details must preserve pending summary flag"
							)
							summary_done()
						else
							summary_done()
							assert(
								s.lazyvcs_repo_cache[f.root].loading_details,
								"summary must preserve pending detail flag"
							)
							detail_done()
						end
						local status = s.lazyvcs_repo_cache[f.root]
						assert(
							status.details_loaded and #status.sections > 0 and status.counts.local_changes == 1,
							"summary discarded completed details"
						)
						assert(not status.loading_summary and not status.loading_details)
						local failure = model.merge_details(status, model.make_error(status, status, "detail failure"))
						assert(failure.detail_error == "detail failure" and failure.sync.status == "error")
						local recovered = model.merge_details(failure, status)
						assert(
							not recovered.error and not recovered.detail_error and recovered.sync.status ~= "error",
							"successful local details must clear only their own error"
						)

						native._test_invalidate_hydration(s, f.root)
						summary_done()
						detail_done()
						assert(s.lazyvcs_repo_cache[f.root] == status, "invalidated callbacks replaced current cache")
						model.load_repo_summary_async, model.load_repo_details_async = summary_loader, detail_loader
						native.close()
					end
				end, debug.traceback)
				model.load_repo_summary_async, model.load_repo_details_async = summary_loader, detail_loader
				if not ok then
					error(err, 0)
				end
			end,
		},
		{
			"test_svn_source_control_remote_rows_survive_local_details",
			function()
				local f = incoming()
				for _, mode in ipairs({ "on_open", "manual" }) do
					setup({ remote_refresh = mode })
					local s = open(f.root)
					if mode == "manual" then
						native.refresh(true)
						settled(s)
					end
					assert(s.lazyvcs_repo_cache[f.root].counts.remote == 1)
					local util, original = require("lazyvcs.util"), require("lazyvcs.util").system_start
					local remote_calls = 0
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
							remote_calls = remote_calls + 1
						end
						return original(args, opts, done)
					end
					local ok, err = xpcall(function()
						details(s, f.root)
					end, debug.traceback)
					util.system_start = original
					if not ok then
						error(err, 0)
					end
					local status = s.lazyvcs_repo_cache[f.root]
					local remote = remote_section(status)
					assert(remote and #remote.items == 1, "local detail loading must retain SVN incoming rows")
					assert(status.counts.local_changes == 1 and status.counts.remote == 1 and remote_calls == 0)
					local loader = model.load_repo_summary_async
					---@diagnostic disable-next-line: duplicate-set-field
					model.load_repo_summary_async = function(_, _, _, callback)
						callback(nil, "offline")
					end
					local refreshed, refresh_err = pcall(function()
						native.refresh(true)
						settled(s)
						details(s, f.root)
						local retained = s.lazyvcs_repo_cache[f.root]
						assert(
							remote_section(retained)
								and retained.counts.remote == 1
								and retained.remote_error == "offline",
							"failed manual refresh must retain remote rows"
						)
					end)
					model.load_repo_summary_async = loader
					assert(refreshed, refresh_err)
					native.refresh(true)
					settled(s)
					details(s, f.root)
					status = s.lazyvcs_repo_cache[f.root]
					remote = remote_section(status)
					local item = remote.items[1]
					assert(
						item.extra.relpath == "sample.txt"
							and item.extra.base_revision
							and item.extra.repos_item == "modified"
					)
					local comparison, load_err, done
					require("lazyvcs.backends").load_diff_target_async(
						vim.tbl_extend("force", item.extra, { path = item.path, root = f.root }),
						function(value, err2)
							comparison, load_err, done = value, err2, true
						end
					)
					ctx.wait_for(function()
						return done
					end, "remote preview not loaded", 15000)
					assert(comparison, load_err)
					assert(
						vim.deep_equal(
							comparison.right.lines,
							mode == "on_open" and { "incoming", "contents" } or { "incoming", "contents", "again" }
						),
						"remote preview contents changed"
					)
					local repo = s.lazyvcs_repo_specs[1]
					local summary = load(model.load_repo_summary_async, repo, { remote_refresh = true })
					local local_detail = load(model.load_repo_details_async, repo, {})
					for _, combined in ipairs({
						model.merge_summary(local_detail, summary),
						model.merge_details(summary, local_detail),
					}) do
						assert(
							remote_section(combined)
								and combined.counts.local_changes == 1
								and combined.counts.remote == 1,
							"completion order lost SVN rows"
						)
					end
					local failed = model.merge_summary(
						status,
						model.make_error(repo, status, "offline", { remote_refresh = true })
					)
					assert(
						remote_section(failed) and failed.remote_error == "offline" and failed.sync.status == "error"
					)
					local detail = load(model.load_repo_details_async, repo, { previous = summary })
					assert(remote_section(detail), "direct local reload must retain remote rows")
					h.exec({ "svn", "revert", f.file }, f.root)
					h.exec({ "svn", "update", f.root }, f.root)
					local empty =
						load(model.load_repo_summary_async, repo, { remote_refresh = true, previous = status })
					local merged = model.merge_summary(status, empty)
					assert(
						merged.counts.remote == 0 and not remote_section(merged),
						"successful empty refresh must remove remote snapshot"
					)
					native.close()
					-- Restore a local modification and create another incoming revision for the next mode.
					if mode == "on_open" then
						h.write_file(f.file, "local\n")
						local other = h.tempdir() .. "/next"
						h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
						h.write_file(other .. "/sample.txt", "incoming\ncontents\nagain\n")
						h.exec({ "svn", "commit", "-m", "next", other }, other)
					end
				end
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
