return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local native, model, util =
		require("lazyvcs.source_control.native"), require("lazyvcs.source_control.model"), require("lazyvcs.util")
	local function settled(s)
		wait(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "SVN summary did not finish", 15000)
	end
	return {
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
					assert(not cache.read(f.root), "project change retained incoming snapshot")
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
