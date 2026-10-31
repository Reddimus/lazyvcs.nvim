return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops, util, store = require("lazyvcs.source_control.ops"), require("lazyvcs.util"), require("lazyvcs.state")
	local confirm = require("lazyvcs.source_control.confirm")
	local function setup(ask)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = ask, sync_button_behavior = "direct" },
		})
	end
	local function state_for(f, vcs)
		return {
			path = f.root,
			lazyvcs_repo_cache = {
				[f.root] = {
					root = f.root,
					vcs = vcs or "git",
					name = "repo",
					counts = {},
					sync = { status = "outgoing" },
				},
			},
			lazyvcs_render = function() end,
		}
	end
	local function action(state, root, name)
		ops.run_primary_action(state, { type = "action_button", extra = { repo_root = root, action = name } })
	end
	local function settled(root)
		wait(function()
			local job = store.get_repo_job(root)
			return not job or job.status ~= "running"
		end, "action did not settle", 15000)
		return store.get_repo_job(root)
	end
	local function git(root, ...)
		return util.trim(h.exec(vim.list_extend({ "git" }, { ... }), root))
	end
	local function guarded(fn)
		return function()
			local mutation, start, notify = confirm.mutation, util.system_start, util.notify
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			local ok, err = xpcall(fn, debug.traceback)
			confirm.mutation, util.system_start, util.notify = mutation, start, notify
			assert(ok, err)
		end
	end
	local function behind()
		local f = h.make_git_remote_fixture()
		git(f.root, "push", "origin", "HEAD:refs/heads/develop")
		git(f.root, "branch", "-M", "dev")
		git(f.root, "config", "branch.dev.merge", "refs/heads/develop")
		f.before = git(f.root, "rev-parse", "HEAD")
		local seed = vim.fs.dirname(f.origin) .. "/seed"
		git(seed, "fetch", "origin")
		git(seed, "merge", "--ff-only", "origin/develop")
		h.write_file(seed .. "/sample.txt", "incoming contents\n")
		git(seed, "commit", "-am", "incoming")
		git(seed, "push", "origin", "HEAD:refs/heads/develop")
		f.target = git(seed, "rev-parse", "HEAD")
		return f
	end
	local cases = {
		{
			"test_source_control_a3_svn_direct_sync_keeps_confirmation",
			guarded(function()
				setup(true)
				local f = h.make_svn_fixture()
				local state = state_for(f, "svn")
				local pending, spawned
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(_, done)
					pending = done
				end
				local start = util.system_start
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and args[2] == "update" then
						spawned = true
					end
					return start(args, opts, done)
				end
				action(state, f.root, "sync")
				assert(pending and not spawned, "SVN direct Sync bypassed confirmation")
				pending()
				assert(not settled(f.root))
				assert(spawned)
			end),
		},
		{
			"test_source_control_a3_same_name_push_ignores_push_default_policy",
			guarded(function()
				setup(false)
				for _, policy in ipairs({ "current", "matching", "nothing" }) do
					for _, operation in ipairs({ "push", "sync", "publish" }) do
						local f = h.make_git_remote_fixture()
						git(f.root, "config", "push.default", policy)
						if operation == "publish" then
							git(f.root, "switch", "--no-track", "-c", "published")
						end
						local state = state_for(f)
						if operation == "publish" then
							state.lazyvcs_repo_cache[f.root].sync.status = "publish"
						end
						action(state, f.root, operation == "publish" and "push" or operation)
						local job = settled(f.root)
						assert(not job, job and job.error)
						local target = operation == "publish" and "published" or "main"
						assert(
							git(f.root, "--git-dir", f.origin, "rev-parse", "refs/heads/" .. target)
								== git(f.root, "rev-parse", "HEAD"),
							policy .. " refused same-name " .. operation
						)
					end
				end
			end),
		},
		{
			"test_source_control_a3_pull_only_sync_mismatch_does_not_read_push_policy",
			guarded(function()
				setup(true)
				local f = behind()
				local state = state_for(f)
				local policy_read, prompt
				local start = util.system_start
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if vim.tbl_contains(args, "push.default") then
						policy_read = true
					end
					return start(args, opts, done)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(opts, done)
					prompt = opts.prompt
					done()
				end
				action(state, f.root, "sync")
				local job = settled(f.root)
				assert(not job, job and job.error)
				assert(not policy_read, "pull-only Sync consulted push policy")
				assert(git(f.root, "rev-parse", "HEAD") == f.target, "behind mismatched upstream did not fast-forward")
				assert(
					prompt
						and prompt:find("refs/heads/dev", 1, true)
						and prompt:find("origin refs/heads/develop", 1, true),
					"fast-forward confirmation hid actual target"
				)
			end),
		},
	}
	vim.list_extend(cases, {
		{
			"test_source_control_a3_sync_ff_confirmation_rechecks_upstream_and_fetched_ref",
			guarded(function()
				for _, change in ipairs({ "accept", "cancel", "upstream", "ref", "branch" }) do
					setup(true)
					local f = behind()
					git(f.root, "config", "push.default", "nothing")
					local state = state_for(f)
					local pending, merged, policy_read
					local start = util.system_start
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if vim.tbl_contains(args, "push.default") then
							policy_read = true
						end
						if args[2] == "merge" then
							merged = args[#args]
						end
						return start(args, opts, done)
					end
					---@diagnostic disable-next-line: duplicate-set-field
					confirm.mutation = function(opts, done, cancel)
						pending = { prompt = opts.prompt, done = done, cancel = cancel }
					end
					action(state, f.root, "sync")
					wait(function()
						return pending ~= nil
					end, "ff confirmation not reached", 15000)
					assert(
						git(f.root, "rev-parse", "HEAD") == f.before and not merged,
						"ff started before confirmation"
					)
					assert(
						pending.prompt:find(f.target:sub(1, 12), 1, true),
						"confirmation omitted captured fetched OID"
					)
					if change == "upstream" then
						git(f.root, "config", "branch.dev.merge", "refs/heads/other")
					elseif change == "ref" then
						git(f.root, "update-ref", "refs/remotes/origin/develop", f.before)
					elseif change == "branch" then
						git(f.root, "switch", "--no-track", "-c", "other")
					end
					if change == "cancel" then
						pending.cancel()
						pending.done()
					else
						pending.done()
					end
					local job = settled(f.root)
					util.system_start = start
					assert(not policy_read, "ff leg read push policy")
					if change == "accept" then
						assert(
							not job and merged == f.target and git(f.root, "rev-parse", "HEAD") == f.target,
							"ff did not merge captured immutable OID"
						)
					else
						assert(
							not merged and git(f.root, "rev-parse", "HEAD") == f.before,
							"changed ff intent mutated working copy"
						)
						if change ~= "cancel" then
							assert(job and job.error, "changed ff intent did not report refusal")
						end
					end
				end
			end),
		},
		{
			"test_source_control_a3_push_confirmation_rechecks_destination_and_policy",
			guarded(function()
				for _, change in ipairs({ "upstream", "policy", "cancel" }) do
					setup(true)
					local f = h.make_git_remote_fixture()
					local state = state_for(f)
					local pending, pushed
					local before = git(f.root, "--git-dir", f.origin, "rev-parse", "refs/heads/main")
					local start = util.system_start
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if args[2] == "push" then
							pushed = true
						end
						return start(args, opts, done)
					end
					---@diagnostic disable-next-line: duplicate-set-field
					confirm.mutation = function(opts, done, cancel)
						pending = { prompt = opts.prompt, done = done, cancel = cancel }
					end
					action(state, f.root, "push")
					wait(function()
						return pending ~= nil
					end, "push confirmation not reached", 15000)
					assert(pending.prompt:find("refs/heads/main -> origin refs/heads/main", 1, true))
					if change == "upstream" then
						git(f.root, "config", "branch.main.merge", "refs/heads/other")
					elseif change == "policy" then
						git(f.root, "config", "push.default", "nothing")
					end
					if change == "cancel" then
						pending.cancel()
						pending.done()
					else
						pending.done()
					end
					local job = settled(f.root)
					util.system_start = start
					assert(
						not pushed and git(f.root, "--git-dir", f.origin, "rev-parse", "refs/heads/main") == before,
						"changed confirmation destination pushed"
					)
					if change ~= "cancel" then
						assert(job and job.error)
					end
				end
			end),
		},
		{
			"test_source_control_a3_noop_sync_skips_confirmation_and_divergence_refuses",
			guarded(function()
				setup(true)
				local called = 0
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(_, done)
					called = called + 1
					done()
				end
				local clean = h.make_git_remote_fixture()
				git(clean.root, "push", "origin", "main")
				local state = state_for(clean)
				action(state, clean.root, "sync")
				assert(not settled(clean.root) and called == 0, "no-op Sync asked mutation confirmation")
				local f = behind()
				h.write_file(f.file, "local diverged\n")
				git(f.root, "commit", "-am", "local")
				local before = git(f.root, "rev-parse", "HEAD")
				state = state_for(f)
				action(state, f.root, "sync")
				local job = settled(f.root)
				assert(
					job and job.error:find("diverged", 1, true) and called == 0,
					"post-fetch divergence did not refuse before mutation"
				)
				assert(git(f.root, "rev-parse", "HEAD") == before)
			end),
		},
	})
	return cases
end
