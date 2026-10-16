return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops = require("lazyvcs.source_control.ops")
	local session = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	local function git(root, ...)
		return util.trim(h.exec(vim.list_extend({ "git" }, { ... }), root))
	end
	local function action(f, name)
		local repo = { root = f.root, vcs = "git", name = "repo", counts = {}, sync = {} }
		local state = { path = f.root, lazyvcs_repo_cache = { [f.root] = repo }, lazyvcs_render = function() end }
		ops.run_primary_action(
			state,
			{ type = "action_button", path = f.root, extra = { repo_root = f.root, action = name } }
		)
		wait(function()
			local job = session.get_repo_job(f.root)
			return not job or job.status ~= "running"
		end, "remote operation did not finish", 15000)
		return session.get_repo_job(f.root)
	end
	local cases = {}
	for _, operation in ipairs({ "push", "publish", "sync" }) do
		cases[#cases + 1] = {
			"test_source_control_git_remote_operands_are_literal_" .. operation,
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { confirm_mutations = false },
				})
				local notify = util.notify
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function() end
				local ok, err = xpcall(function()
					for _, remote in ipairs({ "origin", "-origin" }) do
						local f = h.make_git_remote_fixture()
						if remote ~= "origin" then
							git(f.root, "remote", "rename", "--", "origin", remote)
						end
						if operation == "publish" then
							git(f.root, "branch", "--unset-upstream")
						end
						local failure = action(f, operation == "publish" and "push" or operation)
						assert(
							git(f.root, "--git-dir", f.origin, "rev-parse", "refs/heads/main")
								== git(f.root, "rev-parse", "HEAD"),
							operation .. " did not advance " .. remote .. ": " .. vim.inspect(failure)
						)
						assert(not failure, "remote mutation failed")
						assert(git(f.root, "config", "branch.main.remote") == remote, "publish changed upstream remote")
						assert(
							git(f.root, "config", "branch.main.merge") == "refs/heads/main",
							"publish lost destination ref"
						)
						if operation == "sync" then
							local peer = h.tempdir()
							h.exec({ "git", "clone", f.origin, peer }, f.root)
							git(peer, "config", "user.name", "lazyvcs-test")
							git(peer, "config", "user.email", "lazyvcs@example.com")
							h.write_file(peer .. "/sample.txt", "remote update\n")
							git(peer, "commit", "-am", "Remote advance")
							git(peer, "push", "--", "origin", "main")
							assert(not action(f, "pull"), "pull from literal remote failed")
							assert(
								git(f.root, "rev-parse", "HEAD") == git(peer, "rev-parse", "HEAD"),
								"pull did not fast-forward"
							)
						end
						h.cleanup()
					end
				end, debug.traceback)
				util.notify = notify
				assert(ok, err)
			end,
		}
	end
	return cases
end
