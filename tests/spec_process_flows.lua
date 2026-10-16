return function(ctx)
	local h = ctx.helpers
	local jobs = require("lazyvcs.source_control.jobs")
	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session = require("lazyvcs.state")
	local native = require("lazyvcs.source_control.native")
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false, remote_refresh = "manual", sync_button_behavior = "direct" },
		})
	end
	local function cancel_flow(command)
		setup()
		local original = util.system_start
		local pending, root
		local ok, err = xpcall(function()
			for _, action in ipairs({ "pull", "sync" }) do
				for _, step in ipairs({ "fetch", "status" }) do
					root = h.tempdir()
					local repo = { root = root, name = "flow", vcs = "git", counts = { local_changes = 0 } }
					local state = { path = root, lazyvcs_repo_cache = { [root] = repo } }
					local cancelled, mutations = false, 0
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						local kind = args[2]
						if kind == step then
							assert(not opts.preserve_on_shutdown, "read-only step classified as mutation")
							pending = done
							return {
								cancel = function()
									cancelled = true
								end,
							}
						end
						if kind == "merge" or kind == "push" then
							mutations = mutations + 1
						end
						local stdout = kind == "branch" and "main\n"
							or kind == "for-each-ref" and "refs/heads/main\0refs/remotes/origin/main\0origin\0refs/heads/main\n"
							or ""
						done({ code = 0, stdout = stdout, stderr = "" })
						return {}
					end
					ops.run_primary_action(
						state,
						{ type = "action_button", extra = { repo_root = root, action = action } }
					)
					assert(pending, "flow did not reach " .. step)
					if command then
						vim.cmd("LazyVCS sidebar cancel " .. vim.fn.fnameescape(root))
					else
						assert(ops.cancel_repo(state, { path = root }) == 1, "cancel_repo missed read-only flow step")
					end
					assert(cancelled, "cancellation missed " .. action .. " " .. step)
					-- A late successful exit must not restart the cancelled chain.
					pending({
						code = 0,
						stdout = action == "sync" and "## main...origin/main [ahead 1]\n"
							or "## main...origin/main [behind 1]\n",
						stderr = "",
					})
					pending = nil
					assert(mutations == 0, "cancelled flow advanced to merge or push")
					assert(not session.get_repo_job(root), "cancelled flow remained busy")
				end
			end
		end, debug.traceback)
		if pending then
			jobs.cancel_repo(root)
			pending({ code = 130, stdout = "", stderr = "cancelled" })
		end
		util.system_start = original
		assert(ok, err)
	end
	return {
		{
			"test_source_control_cancel_repo_stops_pull_sync_read_only_steps",
			function()
				cancel_flow(false)
			end,
		},
		{
			"test_source_control_sidebar_cancel_stops_pull_sync_read_only_steps",
			function()
				cancel_flow(true)
			end,
		},
		{
			"test_source_control_sidebar_teardown_cancels_owned_flow_scopes",
			function()
				setup()
				local f = h.make_git_fixture()
				local state = native.open({ path = f.root })
				local exits, cancelled, continued = {}, 0, 0
				for _, scope in ipairs({ "mutation", "git_fetch", "git_status" }) do
					jobs.command({ root = f.root, vcs = "git" }, scope, { "held" }, {
						owner = state,
						scope = scope,
						start = function(_, _, done)
							exits[#exits + 1] = done
							return {
								cancel = function()
									cancelled = cancelled + 1
								end,
							}
						end,
					}, function(_, failure)
						if not failure then
							continued = continued + 1
						end
					end)
				end
				native.close()
				for _, done in ipairs(exits) do
					done({ code = 0, stdout = "", stderr = "" })
				end
				assert(cancelled == 3 and continued == 0, "teardown missed mutation or read-only flow scope")
			end,
		},
	}
end
