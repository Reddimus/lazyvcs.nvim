return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local native, model, util =
		require("lazyvcs.source_control.native"), require("lazyvcs.source_control.model"), require("lazyvcs.util")
	local function settled(s)
		wait(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "SVN summary did not finish", 15000)
	end
	local cache = require("lazyvcs.source_control.remote_refresh")
	local function guard(fn)
		return function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				source_control = {
					remote_refresh = "manual",
					width = 64,
					show_action_button = true,
					show_clean = false,
					auto_expand_width = false,
					confirm_mutations = false,
				},
			})
			local f = h.make_svn_fixture()
			h.exec({ "svn", "revert", f.file }, f.root)
			local loader, original_start = model.load_repo_summary_async, util.system_start
			local signs = require("lazyvcs.signs")
			local begin_base = signs.begin_base_change
			local ok, err = xpcall(function()
				fn(f)
			end, debug.traceback)
			model.load_repo_summary_async, signs.begin_base_change = loader, begin_base
			util.system_start = original_start
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			pcall(native.close)
			assert(ok, err)
		end
	end
	local function open(root)
		local state = native.open({ path = root })
		settled(state)
		return state
	end
	local function incoming_items(f)
		return {
			{
				id = f.root .. "::incoming",
				type = "file",
				name = "sample.txt",
				path = f.file,
				extra = { repo_root = f.root, relpath = "sample.txt", section = "remote", status = "M" },
			},
		}
	end
	local function displayed(state, root, sync, label)
		state.lazyvcs_expanded[model.repo_changes_id(root)] = true
		native.render(state)
		local found_badge, found_action = false, false
		for row, node in pairs(state.lazyvcs_line_nodes) do
			if node.extra and node.extra.repo_root == root then
				if node.extra.sync then
					assert(node.extra.sync.status == sync, "displayed wrong sync status: " .. node.extra.sync.status)
					found_badge = true
					assert(
						vim.api
							.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1]
							:find(node.extra.sync.text, 1, true)
					)
				end
				if node.type == "commit_input" then
					assert(
						node.extra.primary_label == label,
						"displayed wrong primary action: " .. node.extra.primary_label
					)
				end
				if node.type == "action_button" then
					assert(
						vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1]:find(label, 1, true),
						"primary action missing from sidebar buffer"
					)
					found_action = true
				end
			end
		end
		assert(found_badge and found_action, "repository status or primary action hidden")
	end
	return {
		{
			"test_svn_source_control_oversized_publish_keeps_incoming_action",
			guard(function(f)
				local state = open(f.root)
				local loader = model.load_repo_summary_async
				local items, published_version
				for version = 1, 2 do
					items = incoming_items(f)
					items[1].id = items[1].id .. "-" .. version
					items[1].padding = string.rep("x", 4 * 1024 * 1024)
					---@diagnostic disable-next-line: duplicate-set-field
					model.load_repo_summary_async = function(_, opts, _, done)
						done(model.with_remote_snapshot(opts.previous, { items = items, version = version }))
					end
					native.refresh(true)
					settled(state)
					assert(not cache.read(f.root), "oversized snapshot retained")
					displayed(state, f.root, "incoming", "Update")
					local remote_version = state.lazyvcs_repo_cache[f.root].remote_version
					assert(remote_version and remote_version ~= published_version, "remote version did not advance")
					published_version = remote_version
				end
				model.load_repo_summary_async = loader
				state.lazyvcs_expanded[model.repo_changes_id(f.root)] = false
				require("lazyvcs.source_control.ops").open_repo(state, {
					type = "repo",
					path = f.root,
					extra = { repo_root = f.root },
				})
				wait(function()
					return state.lazyvcs_repo_cache[f.root].details_loaded
						and not state.lazyvcs_repo_cache[f.root].loading_summary
						and not state.lazyvcs_repo_cache[f.root].loading_details
				end, "oversized snapshot details did not load", 15000)
				displayed(state, f.root, "incoming", "Update")
				assert(
					state.lazyvcs_repo_cache[f.root].remote_snapshot[1].id == items[1].id,
					"details restored the first oversized incoming row"
				)
				assert(
					state.lazyvcs_repo_cache[f.root].remote_version == published_version,
					"details restored the first remote version"
				)
				native.refresh(false)
				settled(state)
				displayed(state, f.root, "incoming", "Update")
				assert(state.lazyvcs_repo_cache[f.root].remote_snapshot[1].id == items[1].id)
				vim.cmd.tabnew()
				local second = open(f.root)
				displayed(second, f.root, "unknown", "Commit")
				cache.invalidate(f.root)
				displayed(state, f.root, "unknown", "Commit")
				assert(not state.lazyvcs_repo_cache[f.root].remote_local, "invalidation retained private snapshot")
			end),
		},
		{
			"test_svn_source_control_eviction_notifies_and_stays_unknown",
			guard(function(f)
				local state = open(f.root)
				cache.publish(cache.begin(f.root), incoming_items(f))
				displayed(state, f.root, "incoming", "Update")
				for index = 1, 513 do
					cache.publish(cache.begin(f.root .. "/evict-" .. index), {})
				end
				assert(state.lazyvcs_repo_cache[f.root].sync.status == "unknown", "eviction did not notify live tab")
				displayed(state, f.root, "unknown", "Commit")
				native.refresh(false)
				settled(state)
				displayed(state, f.root, "unknown", "Commit")
				native.close()
				state = open(f.root)
				displayed(state, f.root, "unknown", "Commit")
				-- Tombstones are bounded too: enough newer drops forget this root.
				for index = 1, 513 do
					cache.publish(cache.begin(f.root .. "/drop-" .. index), {})
				end
				assert(not cache.is_dropped(f.root), "dropped-root metadata exceeded its bound")
			end),
		},
		{
			"test_svn_source_control_manual_clean_tab_stays_clean_after_mutation",
			guard(function(f)
				local clean = open(f.root)
				vim.cmd.tabnew()
				local checked = open(f.root)
				-- Keep the manual tab unchecked while the other tab has checked status.
				checked.lazyvcs_repo_cache[f.root] =
					model.with_remote_snapshot(checked.lazyvcs_repo_cache[f.root], { items = {}, version = 1 })
				local clean_unknown, checked_unknown
				local start = util.system_start
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "update" then
						clean_unknown = clean.lazyvcs_repo_cache[f.root].remote_unknown == true
						checked_unknown = checked.lazyvcs_repo_cache[f.root].remote_unknown == true
					end
					return start(args, opts, done)
				end
				local node = { type = "repo", path = f.root, extra = { repo_root = f.root, action = "update" } }
				require("lazyvcs.source_control.ops").run_primary_action(checked, node)
				wait(function()
					local job = require("lazyvcs.state").get_repo_job(f.root)
					return not job or job.status ~= "running"
				end, "SVN update did not finish", 15000)
				assert(clean_unknown == false, "unchecked manual tab became unknown")
				assert(checked_unknown == true, "checked tab did not become unknown")
				settled(checked)
				native.render(clean)
				assert(clean.lazyvcs_repo_cache[f.root].sync.status == "synced", "manual tab did not settle cleanly")
				assert(not clean.lazyvcs_repo_visibility[f.root], "clean manual repository became visible")
			end),
		},
		{
			"test_svn_source_control_delayed_local_summary_preserves_mutation_unknown",
			guard(function(f)
				local first = open(f.root)
				cache.publish(cache.begin(f.root), incoming_items(f))
				vim.cmd.tabnew()
				local second = open(f.root)
				local loader = model.load_repo_summary_async
				local delayed, summary
				---@diagnostic disable-next-line: duplicate-set-field
				model.load_repo_summary_async = function(repo, opts, run, done)
					assert(not opts.remote_refresh, "local refresh requested a remote check")
					loader(repo, opts, run, function(result)
						summary, delayed = result, done
					end)
				end
				native.refresh(false)
				wait(function()
					return delayed ~= nil
				end, "local summary did not reach completion", 15000)
				model.load_repo_summary_async = loader
				assert(summary.remote_unknown == false, "summary was already unknown before mutation")
				vim.api.nvim_set_current_tabpage(first.tabid)
				local start, mutation_done, remote_checks = util.system_start, nil, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "update" then
						mutation_done = done
						return { kill = function() end }
					end
					if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
						remote_checks = remote_checks + 1
					end
					return start(args, opts, done)
				end
				local node = { type = "repo", path = f.root, extra = { repo_root = f.root, action = "update" } }
				require("lazyvcs.source_control.ops").run_primary_action(first, node)
				wait(function()
					return mutation_done ~= nil
				end, "SVN mutation did not start", 15000)
				assert(second.lazyvcs_repo_cache[f.root].remote_unknown, "mutation did not mark other tab unknown")
				assert(not cache.read(f.root) and not cache.is_dropped(f.root), "mutation retained remote metadata")
				-- Settle without a remote refresh so only the delayed local result can change tab B.
				assert(mutation_done)(nil, "cancelled", { code = 130, cancelled = true })
				wait(function()
					local job = require("lazyvcs.state").get_repo_job(f.root)
					return not job or job.status ~= "running"
				end, "SVN mutation did not settle", 15000)
				settled(first)
				vim.api.nvim_set_current_tabpage(second.tabid)
				delayed(summary)
				settled(second)
				assert(second.lazyvcs_repo_cache[f.root].remote_unknown, "delayed local summary cleared unknown")
				displayed(second, f.root, "unknown", "Commit")
				assert(second.lazyvcs_repo_visibility[f.root], "unknown repository hidden with show_clean=false")
				assert(remote_checks == 0, "local summary or cancellation ran a new remote check")
				cache.publish(cache.begin(f.root), {})
				native.render(second)
				assert(not second.lazyvcs_repo_cache[f.root].remote_unknown, "new snapshot did not clear unknown")
				assert(second.lazyvcs_repo_cache[f.root].sync.status == "synced", "new empty snapshot did not sync")
				assert(not second.lazyvcs_repo_visibility[f.root], "checked clean repository remained visible")
			end),
		},
		{
			"test_svn_source_control_revert_preserves_incoming_and_signs_base",
			guard(function(f)
				local state = open(f.root)
				cache.publish(cache.begin(f.root), incoming_items(f))
				vim.cmd.tabnew()
				local second = open(f.root)
				h.write_file(f.file, "local edit\n")
				local signs, base_changes = require("lazyvcs.signs"), 0
				local begin_base = signs.begin_base_change
				---@diagnostic disable-next-line: duplicate-set-field
				signs.begin_base_change = function(...)
					base_changes = base_changes + 1
					return begin_base(...)
				end
				require("lazyvcs.source_control.ops").revert_file(second, {
					type = "file",
					path = f.file,
					extra = { repo_root = f.root, relpath = "sample.txt", section = "changes", status = "M" },
				})
				wait(function()
					local job = require("lazyvcs.state").get_repo_job(f.root)
					return vim.fn.readfile(f.file)[1] == "one" and (not job or job.status ~= "running")
				end, "SVN revert did not finish", 15000)
				assert(base_changes == 0, "SVN revert started a whole-repository signs base change")
				assert(cache.read(f.root), "SVN revert invalidated incoming snapshot")
				displayed(state, f.root, "incoming", "Update")
			end),
		},
		{
			"test_svn_source_control_incoming_survives_reopen_and_tabs",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = {
						remote_refresh = "on_open",
						remote_refresh_interval_ms = 60000,
						show_clean = false,
						auto_expand_width = false,
					},
				})
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				local other = h.tempdir() .. "/other"
				h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
				h.write_file(other .. "/sample.txt", "incoming\n")
				h.exec({ "svn", "commit", "-m", "incoming", other }, other)
				local start, loader = util.system_start, model.load_repo_summary_async
				local admission = require("lazyvcs.source_control.remote_refresh")
				local original_invalidate = admission.invalidate
				local calls, states = 0, {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
						calls = calls + 1
					end
					return start(args, opts, done)
				end
				local ok, err = xpcall(function()
					local function open()
						local s = native.open({ path = f.root })
						states[#states + 1] = s
						settled(s)
						return s
					end
					local first = open().lazyvcs_repo_cache[f.root]
					assert(first.counts.remote == 1)
					local id = first.remote_snapshot[1].id
					native.close()
					local s = open()
					local function incoming(state)
						local status = state.lazyvcs_repo_cache[f.root]
						assert(status.counts.remote == 1, "reopened sidebar lost known incoming change")
						assert(
							status.remote_snapshot[1].id == id and status.sync.status == "incoming",
							"incoming identity or badge lost"
						)
						assert(state.lazyvcs_repo_visibility[f.root], "known incoming repository hidden")
					end
					incoming(s)
					vim.cmd.tabnew()
					local second = open()
					incoming(second)
					assert(calls == 1, "throttled open started remote work")
					---@diagnostic disable-next-line: duplicate-set-field
					model.load_repo_summary_async = function(repo, opts, run, done)
						if opts.remote_refresh then
							done(nil, "offline")
						else
							loader(repo, opts, run, done)
						end
					end
					native.refresh(true)
					settled(second)
					assert(second.lazyvcs_repo_cache[f.root].counts.remote == 1, "failed refresh discarded snapshot")
					model.load_repo_summary_async = loader
					local cache = require("lazyvcs.source_control.remote_refresh")
					local stale = cache.begin(f.root)
					cache.invalidate(f.root)
					assert(
						not cache.publish(stale, first.remote_snapshot),
						"invalidated completion republished snapshot"
					)
					assert(
						s.lazyvcs_repo_cache[f.root].counts.remote == 0
							and second.lazyvcs_repo_cache[f.root].counts.remote == 0,
						"invalidation missed another tab"
					)
					local delayed
					---@diagnostic disable-next-line: duplicate-set-field
					model.load_repo_summary_async = function(_, _, _, done)
						delayed = done
					end
					native.refresh(false)
					wait(function()
						return delayed ~= nil
					end, "local summary did not start", 15000)
					cache.invalidate(f.root)
					delayed(first)
					assert(
						second.lazyvcs_repo_cache[f.root].counts.remote == 0,
						"old local summary restored incoming rows"
					)
					model.load_repo_summary_async = loader
					local a, b = cache.begin(f.root), cache.begin(f.root)
					assert(not cache.publish(a, first.remote_snapshot), "superseded refresh accepted")
					assert(cache.publish(b, first.remote_snapshot))
					local isolated = cache.read(f.root)
					isolated.items[1].id = "changed"
					assert(cache.read(f.root).items[1].id == id, "cache exposed mutable rows")
					local mutation_done
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if args[1] == "svn" and args[2] == "update" then
							assert(not cache.read(f.root), "SVN mutation started with retained snapshot")
							assert(
								s.lazyvcs_repo_cache[f.root].counts.remote == 0,
								"mutation startup missed another tab"
							)
							mutation_done = done
							return { kill = function() end }
						end
						return start(args, opts, done)
					end
					local config = require("lazyvcs.config").get().source_control
					config.confirm_mutations, config.sync_button_behavior = false, "direct"
					local node = { type = "repo", path = f.root, extra = { repo_root = f.root } }
					require("lazyvcs.source_control.ops").sync_repo(second, node)
					wait(function()
						return mutation_done ~= nil
					end, "SVN mutation did not start", 15000)
					cache.publish(cache.begin(f.root), first.remote_snapshot)
					local invalidate = cache.invalidate
					local invalidated = false
					---@diagnostic disable-next-line: duplicate-set-field
					cache.invalidate = function(root)
						invalidate(root)
						invalidated = true
					end
					mutation_done(nil, "cancelled", { code = 130, cancelled = true })
					wait(function()
						return invalidated
					end, "SVN mutation settlement retained snapshot", 15000)
					cache.invalidate = invalidate
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if args[1] == "svn" and args[2] == "status" and vim.tbl_contains(args, "-u") then
							calls = calls + 1
						end
						return start(args, opts, done)
					end
					settled(second)
					h.exec({ "svn", "update", f.root }, f.root)
					native.refresh(true)
					settled(second)
					assert(calls == 2, "explicit refresh did not bypass admission")
					assert(
						#cache.read(f.root).items == 0 and s.lazyvcs_repo_cache[f.root].counts.remote == 0,
						"empty refresh retained incoming rows"
					)
					for index = 1, 513 do
						cache.publish(cache.begin(f.root .. "/cache-" .. index), {})
					end
					assert(not cache.read(f.root), "snapshot root bound not enforced")
					native.close()
					local evicted = open().lazyvcs_repo_cache[f.root]
					assert(
						evicted.sync.status == "unknown" and calls == 2,
						"eviction reported synced or reset admission"
					)
					cache.publish(cache.begin(f.root), { { path = string.rep("x", 4 * 1024 * 1024) } })
					assert(not cache.read(f.root), "oversized snapshot retained")
					cache.publish(cache.begin(f.root .. "/large-a"), { { path = string.rep("a", 3 * 1024 * 1024) } })
					cache.publish(cache.begin(f.root .. "/large-b"), { { path = string.rep("b", 3 * 1024 * 1024) } })
					assert(
						not cache.read(f.root .. "/large-a") and cache.read(f.root .. "/large-b"),
						"aggregate snapshot byte bound not enforced"
					)
					cache.invalidate(f.root .. "/large-b")
					local flags = vim.tbl_extend("force", first, { loading_summary = true, loading_details = true })
					local composed = model.with_remote_snapshot(flags, nil)
					assert(
						composed.loading_summary and composed.loading_details and composed.counts.remote == 0,
						"remote merge changed local loading flags"
					)
					cache.publish(cache.begin(f.root), first.remote_snapshot)
					native.open({ path = h.tempdir() })
					assert(cache.read(f.root), "project change erased shared incoming snapshot")
					incoming(s)
					local manual = h.make_svn_fixture()
					h.exec({ "svn", "revert", manual.file }, manual.root)
					require("lazyvcs.config").get().source_control.remote_refresh = "manual"
					local clean = native.open({ path = manual.root })
					settled(clean)
					assert(
						clean.lazyvcs_repo_cache[manual.root].sync.status == "synced",
						"manual local status changed to unknown"
					)
				end, debug.traceback)
				util.system_start, model.load_repo_summary_async = start, loader
				admission.invalidate = original_invalidate
				for _, state in ipairs(states) do
					if state.tabid and vim.api.nvim_tabpage_is_valid(state.tabid) then
						vim.api.nvim_set_current_tabpage(state.tabid)
						pcall(native.close)
					end
				end
				vim.cmd("silent! tabonly!")
				assert(ok, err)
			end,
		},
	}
end
