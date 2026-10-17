return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native, model, ops, util =
		require("lazyvcs.source_control.native"),
		require("lazyvcs.source_control.model"),
		require("lazyvcs.source_control.ops"),
		require("lazyvcs.util")
	local runtime = require("lazyvcs.state")
	local function settled(s)
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "summary not ready", 15000)
	end
	local function open(root)
		local s = native.open({ path = root })
		settled(s)
		ops.open_repo(s, { type = "repo_changes", path = root, extra = { repo_root = root } }, function() end)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[root].details_loaded
		end, "details not ready", 15000)
		s.lazyvcs_expanded[root .. "::section::untracked"] = true
		s.lazyvcs_expanded[root .. "::section::staged"] = true
		native.render(s)
		return s
	end
	local function overlay()
		local f = h.make_git_fixture()
		local s = open(f.root)
		local cached = s.lazyvcs_repo_cache[f.root]
		cached.error = "local read error"
		cached.sync = { text = "!", status = "error", highlight = "DiagnosticError" }
		local before = vim.deepcopy(cached)
		runtime.set_repo_job(f.root, { status = "running", label = "Stage", sync_text = "Stage" })
		native.render(s)
		assert(vim.deep_equal(cached, before), "job overlay mutated cached repository status")
		local busy = false
		for _, node in ipairs(s.lazyvcs_line_nodes) do
			busy = busy or node.extra and node.extra.sync and node.extra.sync.status == "busy"
		end
		assert(busy, "job badge not rendered")
		runtime.clear_repo_job(f.root)
		native.render(s)
		assert(
			vim.deep_equal(cached, before) and s.lazyvcs_repo_cache[f.root] == cached,
			"clearing job changed repository data"
		)
		for _, node in ipairs(s.lazyvcs_line_nodes) do
			assert(
				not (node.extra and node.extra.sync and node.extra.sync.status == "busy"),
				"completed badge retained"
			)
		end
		runtime.set_repo_job(f.root, { status = "error", error = "mutation failed" })
		native.render(s)
		assert(vim.deep_equal(cached, before), "failed job changed cached error")
		runtime.clear_repo_job(f.root)
	end
	local function mutation()
		local f, other = h.make_git_fixture(), h.make_git_fixture()
		h.write_file(f.root .. "/new.txt", "stage me\n")
		local a = open(f.root)
		vim.cmd.tabnew()
		local b = open(f.root)
		vim.cmd.tabnew()
		local unrelated = open(other.root)
		local retained = unrelated.lazyvcs_repo_cache[other.root]
		api.nvim_set_current_tabpage(b.tabid)
		local summary, detail, start = model.load_repo_summary_async, model.load_repo_details_async, util.system_start
		local old_summary, old_detail, complete
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_summary_async = function(repo, opts, run, done)
			return summary(repo, opts, run, function(value, err)
				old_summary = function()
					done(value, err)
				end
			end)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_details_async = function(repo, opts, run, done)
			return detail(repo, opts, run, function(value, err)
				old_detail = function()
					done(value, err)
				end
			end)
		end
		local ok, err = xpcall(function()
			b.lazyvcs_repo_cache[f.root].summary_loaded = false
			b.lazyvcs_repo_cache[f.root].details_loaded = false
			native.navigate(b)
			ops.open_repo(b, {
				type = "repo_changes",
				extra = { repo_root = f.root },
				is_expanded = function()
					return false
				end,
			}, function() end)
			ctx.wait_for(function()
				return old_summary and old_detail
			end, "old reads not ready", 15000)
			model.load_repo_summary_async, model.load_repo_details_async = summary, detail
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, done)
				return start(args, opts, function(value, load_err, raw)
					if args[1] == "git" and args[2] == "add" then
						complete = function()
							done(value, load_err, raw)
						end
					else
						done(value, load_err, raw)
					end
				end)
			end
			api.nvim_set_current_tabpage(a.tabid)
			ops.stage_file(a, {
				type = "file",
				path = f.root .. "/new.txt",
				extra = { repo_root = f.root, relpath = "new.txt", section = "untracked" },
			})
			ctx.wait_for(function()
				return complete
			end, "git add did not complete", 15000)
			native.render(b)
			assert(h.exec({ "git", "status", "--porcelain", "--", "new.txt" }, f.root):find("A  new.txt", 1, true))
			complete()
			ctx.wait_for(function()
				local current = b.lazyvcs_repo_cache[f.root]
				return current and current.details_loaded and current.counts.staged == 1
			end, "sibling did not reload staged row after settlement", 15000)
			settled(a)
			settled(b)
			local current = b.lazyvcs_repo_cache[f.root]
			old_summary()
			old_detail()
			assert(b.lazyvcs_repo_cache[f.root] == current, "old callback restored sibling rows")
			assert(a.lazyvcs_repo_cache[f.root].counts.staged == 1)
			assert(current.sync.status ~= "busy" and not current.job, "sibling retained completed job")
			assert(unrelated.lazyvcs_repo_cache[other.root] == retained, "unrelated root invalidated")
		end, debug.traceback)
		model.load_repo_summary_async, model.load_repo_details_async, util.system_start = summary, detail, start
		assert(ok, err)
	end
	local function svn_commit()
		local f = h.make_svn_fixture()
		local a = open(f.root)
		local cache = require("lazyvcs.source_control.remote_refresh")
		cache.publish(cache.begin(f.root), {})
		vim.cmd.tabnew()
		local b = open(f.root)
		api.nvim_set_current_tabpage(a.tabid)
		local loader, remote_check = model.load_repo_summary_async, nil
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_summary_async = function(repo, opts, run, done)
			if opts.remote_refresh then
				remote_check = function()
					loader(repo, opts, run, done)
				end
				return
			end
			return loader(repo, opts, run, done)
		end
		local ok, err = xpcall(function()
			a.lazyvcs_commit_drafts[f.root] = "coherence commit"
			ops.commit_repo(a, { extra = { repo_root = f.root } })
			ctx.wait_for(function()
				return remote_check
			end, "commit did not settle", 15000)
			ctx.wait_for(function()
				local status = b.lazyvcs_repo_cache[f.root]
				return status and status.details_loaded and status.counts.local_changes == 0
			end, "SVN sibling retained pre-commit local state", 15000)
			assert(h.exec({ "svn", "status", f.file }, f.root) == "", "commit did not change working copy")
			local status = b.lazyvcs_repo_cache[f.root]
			assert(
				status.remote_unknown and status.sync.status == "unknown",
				"SVN sibling reported synced before remote check"
			)
			assert(remote_check)()
			settled(a)
			assert(
				not b.lazyvcs_repo_cache[f.root].remote_unknown and b.lazyvcs_repo_cache[f.root].sync.status == "synced",
				"remote check did not settle sibling"
			)
		end, debug.traceback)
		model.load_repo_summary_async = loader
		assert(ok, err)
	end
	local function svn_cancel()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "revert", f.file }, f.root)
		local a = open(f.root)
		local cache = require("lazyvcs.source_control.remote_refresh")
		cache.publish(cache.begin(f.root), {})
		vim.cmd.tabnew()
		local b = open(f.root)
		local loader, start = model.load_repo_summary_async, util.system_start
		local delayed, cancel, remote_checks = nil, nil, 0
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_summary_async = function(repo, opts, run, done)
			assert(not opts.remote_refresh)
			return loader(repo, opts, run, function(value, err)
				delayed = function()
					done(value, err)
				end
			end)
		end
		local ok, err = xpcall(function()
			b.lazyvcs_repo_cache[f.root].summary_loaded = false
			native.navigate(b)
			ctx.wait_for(function()
				return delayed
			end, "old local summary not ready", 15000)
			model.load_repo_summary_async = loader
			h.write_file(f.file, "changed after summary\n")
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, done)
				if args[1] == "svn" and args[2] == "update" then
					cancel = function()
						done(nil, "cancelled", { code = 130, cancelled = true })
					end
					return { kill = function() end }
				end
				if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
					remote_checks = remote_checks + 1
				end
				return start(args, opts, done)
			end
			api.nvim_set_current_tabpage(a.tabid)
			ops.run_primary_action(a, { extra = { repo_root = f.root, action = "update" } })
			ctx.wait_for(function()
				return cancel
			end, "SVN mutation not started", 15000)
			assert(cancel)()
			ctx.wait_for(function()
				return not runtime.get_repo_job(f.root)
			end, "cancellation not settled", 15000)
			assert(delayed)()
			ctx.wait_for(function()
				local current = b.lazyvcs_repo_cache[f.root]
				return current.details_loaded and not current.loading_summary and current.counts.local_changes == 1
			end, "cancelled SVN action retained pre-mutation sibling details", 15000)
			local current = b.lazyvcs_repo_cache[f.root]
			assert(current.remote_unknown and current.sync.status ~= "synced", "local recheck cleared remote unknown")
			assert(current.sections[1].items[1].extra.relpath == "sample.txt", "fresh detail row missing")
			assert(remote_checks == 0, "cancellation recheck requested remote status")
		end, debug.traceback)
		model.load_repo_summary_async, util.system_start = loader, start
		assert(ok, err)
	end
	local cases = {
		{ "test_svn_source_control_cancel_rechecks_pending_sibling_summary", svn_cancel },
		{ "test_source_control_job_overlay_preserves_repository_status", overlay },
		{ "test_source_control_mutation_refreshes_sibling_sidebars", mutation },
		{ "test_svn_source_control_commit_refreshes_sibling_with_unknown_remote", svn_commit },
	}
	for _, case in ipairs(cases) do
		local fn = case[2]
		case[2] = function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				source_control = {
					remote_refresh = "manual",
					auto_expand_width = false,
					show_clean = true,
					confirm_mutations = false,
				},
			})
			local ok, err = xpcall(fn, debug.traceback)
			for _, tab in ipairs(api.nvim_list_tabpages()) do
				api.nvim_set_current_tabpage(tab)
				pcall(native.close)
			end
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	return cases
end
