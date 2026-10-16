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
					local cancelled, starts_after_cancel = false, 0
					local status = action == "sync" and "## main...origin/main [ahead 1]\n"
						or "## main...origin/main [behind 1]\n"
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if cancelled then
							starts_after_cancel = starts_after_cancel + 1
						end
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
						local stdout = kind == "branch" and "main\n"
							or kind == "for-each-ref" and "refs/heads/main\0refs/remotes/origin/main\0origin\0refs/heads/main\n"
							or kind == "status" and status
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
						stdout = step == "status" and status or "",
						stderr = "",
					})
					pending = nil
					assert(starts_after_cancel == 0, "cancelled flow started another command")
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
			"test_source_control_cancel_matches_literal_root_aliases",
			function()
				setup()
				local f = h.make_git_fixture()
				vim.fn.mkdir(f.root .. "/a", "p")
				local paths = { f.root .. "/", f.root .. "/a/.." }
				if vim.fn.has("win32") ~= 1 then
					local other = h.make_git_fixture()
					assert(vim.uv.fs_symlink(f.root .. "/a", other.root .. "/link", { dir = true }))
					paths[#paths + 1] = other.root .. "/link/.."
				end
				local ok, err = xpcall(function()
					for _, path in ipairs(paths) do
						local s = native.open({ path = path })
						ctx.wait_for(function()
							return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
						end, "alias sidebar discovery did not finish", 15000)
						assert(s.path == f.root and s.lazyvcs_repo_specs[1].root == f.root)
						for _, route in ipairs({ "api", "command", "ops", "jobs" }) do
							local started, cancelled, exit
							jobs.command({ root = path, vcs = "git" }, "alias_probe", { "held" }, {
								owner = s,
								start = function(_, _, done)
									started, exit = true, done
									return {
										cancel = function()
											cancelled = true
										end,
									}
								end,
							}, function() end)
							ctx.wait_for(function()
								return started
							end, "alias job did not start")
							if route == "api" then
								assert(require("lazyvcs").source_control_cancel(path) == 1)
							elseif route == "command" then
								vim.cmd("LazyVCS sidebar cancel " .. vim.fn.fnameescape(path))
							elseif route == "ops" then
								assert(ops.cancel(path, { owner = s }) == 1)
							else
								assert(jobs.cancel_repo(path) == 1)
							end
							assert(cancelled, route .. " did not cancel the canonical root for " .. path)
							exit({ code = 130, stdout = "", stderr = "cancelled" })
						end
						native.close()
					end
				end, debug.traceback)
				native.close()
				assert(ok, err)
			end,
		},
		{
			"test_core_editor_restore_cancel_terminates_filter_tree",
			function()
				local p = require("process_helpers")
				local windows = vim.fn.has("win32") == 1
				for _, emulate in ipairs(windows and { false } or { true, false }) do
					require("lazyvcs").setup({
						use_gitsigns = false,
						signs = { enabled = false },
					})
					local f = h.make_git_fixture()
					local dir = h.tempdir()
					local filter, child = dir .. "/filter.lua", dir .. "/child.lua"
					vim.fn.writefile({
						"local dir = arg[1]",
						'vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, dir .. "/filter.pid")',
						'vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", dir .. "/child.lua", dir })',
						"vim.wait(60000, function() return false end, 50)",
					}, filter)
					vim.fn.writefile({
						'vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, arg[1] .. "/child.pid")',
						"vim.wait(60000, function() return false end, 50)",
					}, child)
					h.write_file(f.root .. "/.gitattributes", "sample.txt filter=cancel-test")
					h.exec({
						"git",
						"config",
						"filter.cancel-test.smudge",
						'"'
							.. vim.v.progpath:gsub("\\", "/")
							.. '" --headless -u NONE -i NONE -l "'
							.. filter
							.. '" "'
							.. dir
							.. '"',
					}, f.root)
					local start, system, has = util.system_start, vim.system, vim.fn.has
					local captured, handle, owner, tree_kills, restore_completed
					tree_kills = 0
					local ok, err = xpcall(function()
						---@diagnostic disable-next-line: duplicate-set-field
						vim.system = function(args, opts, done)
							if args[1] == "taskkill" then
								tree_kills = tree_kills + 1
								assert(
									vim.tbl_contains(args, "/T") and vim.tbl_contains(args, "/F"),
									"cancellation omitted tree termination"
								)
								if emulate then
									for _, pid in ipairs(p.pids(dir)) do
										if p.alive(pid) then
											vim.uv.kill(pid, 9)
										end
									end
									vim.schedule(function()
										done({ code = 0 })
									end)
									return { kill = function() end }
								end
							end
							return system(args, opts, done)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, done)
							if args[1] ~= "git" or args[2] ~= "restore" then
								return start(args, opts, done)
							end
							captured = vim.deepcopy(opts)
							if emulate then
								---@diagnostic disable-next-line: duplicate-set-field
								vim.fn.has = function(feature)
									return feature == "win32" and 1 or has(feature)
								end
							end
							local started, result = pcall(start, args, opts, function(...)
								done(...)
								restore_completed = true
							end)
							vim.fn.has = has
							assert(started, result)
							handle = result
							return result
						end
						vim.cmd.edit(vim.fn.fnameescape(f.file))
						owner = assert(require("lazyvcs").revert_buffer())
						ctx.wait_for(function()
							return vim.bo.buftype == "nofile"
						end, "restore confirmation did not open", 15000)
						vim.fn.maparg("1", "n", false, true).callback()
						ctx.wait_for(function()
							return p.pid(dir .. "/child.pid")
						end, "restore filter child did not start", 15000)
						assert(p.alive(p.pid(dir .. "/filter.pid")) and p.alive(p.pid(dir .. "/child.pid")))
						assert(
							captured and captured.preserve_on_shutdown == true,
							"editor restore lost shutdown preservation"
						)
						handle:shutdown()
						assert(
							p.alive(p.pid(dir .. "/filter.pid"))
								and p.alive(p.pid(dir .. "/child.pid"))
								and tree_kills == 0,
							"shutdown cancelled a preserved mutation"
						)
						owner:cancel()
						assert(captured.scope == "mutation", "editor restore omitted mutation scope")
						ctx.wait_for(function()
							return p.dead(dir)
						end, "cancelled restore left filter descendants alive", 5000)
						ctx.wait_for(function()
							return owner.active == false and restore_completed
						end, "cancelled restore owner or git wrapper did not complete", 5000)
						assert(
							not (windows or emulate) or tree_kills > 0,
							"Windows cancellation did not request taskkill /T"
						)
					end, debug.traceback)
					vim.system, vim.fn.has, util.system_start = system, has, start
					if owner then
						owner:cancel()
					end
					for _, pid in ipairs(p.pids(dir)) do
						if p.alive(pid) then
							pcall(vim.uv.kill, pid, 9)
						end
					end
					if handle then
						handle:force()
					end
					if handle then
						ctx.wait_for(function()
							return owner.active == false and restore_completed
						end, "restore cleanup did not complete", 5000)
					end
					assert(ok, err)
				end
			end,
		},
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
