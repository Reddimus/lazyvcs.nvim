return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local switch = require("lazyvcs.source_control.switch")
	local util = require("lazyvcs.util")
	local function runner(root)
		return function(args, _, done)
			return util.system_start(args, { cwd = root }, done)
		end
	end
	local function collect(repo)
		local finished, result, err
		switch.collect_async(repo, runner(repo.root), function(value, failure)
			finished, result, err = true, value, failure
		end)
		wait(function()
			return finished
		end, "switch collection did not finish", 15000)
		assert(result, err)
		return result
	end
	local function pick(repo, selectors, name)
		local finished, failure, mutations = false, nil, 0
		switch.open_async(repo, {
			select = function(items, _, done)
				local wanted = table.remove(selectors, 1)
				for _, item in ipairs(items) do
					if item.refname == wanted or item.action == wanted or item.target_url == wanted then
						return done(item)
					end
				end
				failure, finished = "Missing picker target: " .. tostring(wanted), true
			end,
			input = function(_, done)
				done(name)
			end,
			after_mutation = function()
				mutations, finished = mutations + 1, true
			end,
			notify = function(message, level)
				finished = true
				if level ~= vim.log.levels.INFO then
					failure = message
				end
			end,
		}, runner(repo.root))
		wait(function()
			return finished
		end, "switch selection did not finish", 15000)
		assert(not failure, failure)
		return mutations
	end
	local function git(root, ...)
		return util.trim(h.exec(vim.list_extend({ "git" }, { ... }), root))
	end
	local function guarded(fn)
		return function()
			local ok, err = xpcall(fn, debug.traceback)
			pcall(require("lazyvcs.source_control.native").close)
			assert(ok, err)
		end
	end
	return {
		{
			"test_source_control_switch_branch_tag_collision",
			guarded(function()
				local f = h.make_git_switch_fixture()
				local repo = { root = f.root, vcs = "git", name = "clone" }
				git(f.root, "branch", "collision")
				git(f.root, "tag", "collision")
				assert(pick(repo, { "refs/heads/collision" }) == 1)
				assert(git(f.root, "branch", "--show-current") == "collision", "canonical branch was not checked out")
				assert(pick(repo, { "refs/heads/collision" }) == 0, "current branch should not mutate")
				local context = collect(repo)
				assert(context.locals_by_name.collision, "canonical local-name lookup missing")
				local notices = {}
				switch.open_async(repo, {
					select = function(items, _, done)
						done(items[1])
					end,
					input = function(_, done)
						done("collision")
					end,
					notify = function(message)
						notices[#notices + 1] = message
					end,
				}, runner(repo.root))
				wait(function()
					return #notices > 0
				end)
				assert(notices[1] == "Local branch already exists: collision")
			end),
		},
		{
			"test_source_control_switch_tracking_branch_tag_collision",
			guarded(function()
				local f = h.make_git_switch_fixture()
				local repo = { root = f.root, vcs = "git", name = "clone" }
				git(f.root, "branch", "--track", "collision", "origin/feature/remote")
				git(f.root, "tag", "collision")
				-- Force upstream shortening to be ambiguity-dependent too.
				git(f.root, "tag", "origin/feature/remote")
				assert(pick(repo, { "refs/remotes/origin/feature/remote" }) == 1)
				assert(
					git(f.root, "branch", "--show-current") == "collision",
					"existing tracking branch was not reused"
				)
				assert(pick(repo, { "refs/remotes/origin/feature/remote" }) == 0)
				assert(collect(repo).locals_by_upstream["refs/remotes/origin/feature/remote"])
			end),
		},
		{
			"test_source_control_switch_keeps_real_head_suffix_refs",
			guarded(function()
				local f = h.make_git_switch_fixture()
				local repo = { root = f.root, vcs = "git", name = "clone" }
				git(f.root, "branch", "feature/HEAD")
				git(f.root, "tag", "release/HEAD")
				git(f.root, "update-ref", "refs/remotes/other/topic/HEAD", "HEAD")
				local context = collect(repo)
				local found = {}
				for _, item in ipairs(context.refs) do
					found[item.refname] = true
				end
				assert(found["refs/heads/feature/HEAD"], "real branch ending in /HEAD hidden")
				assert(found["refs/tags/release/HEAD"], "real tag ending in /HEAD hidden")
				assert(found["refs/remotes/other/topic/HEAD"], "nonsymbolic remote /HEAD hidden")
				assert(not found["refs/remotes/origin/HEAD"], "symbolic remote HEAD alias offered")
				pick(repo, { "refs/heads/feature/HEAD" })
				assert(git(f.root, "branch", "--show-current") == "feature/HEAD")
				pick(repo, { "git_checkout_detached", "refs/tags/release/HEAD" })
				assert(git(f.root, "branch", "--show-current") == "")
				pick(repo, { "git_create_branch_from", "refs/heads/feature/HEAD" }, "from-head")
				assert(git(f.root, "branch", "--show-current") == "from-head")
				assert(git(f.root, "rev-parse", "HEAD") == git(f.root, "rev-parse", "refs/tags/release/HEAD"))
			end),
		},
		{
			"test_source_control_switch_rejects_truncated_refs",
			function()
				local result, err
				switch.collect_async({ root = h.tempdir(), vcs = "git" }, function(args, _, done)
					if args[2] == "branch" then
						done({ stdout = "main\n" })
					else
						done({ stdout = "", stdout_truncated = true })
					end
				end, function(value, failure)
					result, err = value, failure
				end)
				assert(not result and err and err:match("output limit"), "truncated refs accepted as complete")
			end,
		},
		{
			"test_source_control_switch_close_releases_owned_marker",
			guarded(function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				local ops = require("lazyvcs.source_control.ops")
				local jobs = require("lazyvcs.source_control.jobs")
				local session = require("lazyvcs.state")
				local repo = { root = f.root, vcs = "git", name = "repo" }
				local state = {
					lazyvcs_repo_cache = { [f.root] = repo },
					lazyvcs_window_exists = function()
						return false
					end,
				}
				local start = util.system_start
				local killed, enumerations = 0, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _, done)
					if args[2] == "branch" then
						done({ code = 0, stdout = "main\n" })
						return {}
					end
					assert(args[2] == "for-each-ref", "expected in-flight ref enumeration")
					enumerations = enumerations + 1
					return {
						kill = function()
							killed = killed + 1
							done(nil, "cancelled", { code = 130, cancelled = true })
						end,
					}
				end
				local ok, err = xpcall(function()
					ops.switch_repo(state, { path = f.root })
					state.lazyvcs_tearing_down = true
					jobs.cancel_owner(state)
					assert(not session.get_repo_job(f.root), "closed enumeration left repository busy")
					assert(enumerations == 1 and killed == 1, "sidebar close did not stop ref enumeration")
					state.lazyvcs_tearing_down = false
					local task = assert(ops.switch_repo(state, { path = f.root }))
					local newer = { status = "running", action = "newer" }
					session.set_repo_job(f.root, newer)
					newer = session.get_repo_job(f.root)
					task:cancel()
					assert(session.get_repo_job(f.root) == newer, "old enumeration cleared newer marker")
					assert(enumerations == 2 and killed == 2, "task cancellation did not stop ref enumeration")
					assert(jobs.cancel_owner(state) == 0, "cancelled enumeration retained a scheduler job")
				end, debug.traceback)
				util.system_start = start
				jobs.cancel_owner(state)
				session.clear_repo_job(f.root)
				assert(ok, err)
			end),
		},
		{
			"test_svn_switch_literal_at_targets_and_manual_pegs",
			guarded(function()
				local f = h.make_svn_switch_fixture()
				local root = util.normalize_literal_path(f.root .. "@copy")
				assert(vim.uv.fs_rename(f.root, root))
				local repo = { root = root, vcs = "svn", name = "wc" }
				local branch = h.file_url(f.repo) .. "/branches/a@b"
				local tag = h.file_url(f.repo) .. "/tags/a@b"
				for _, url in ipairs({ branch, tag }) do
					h.exec({ "svn", "copy", f.trunk_url, util.svn_target(url), "-m", "copy" }, root)
				end
				local function current()
					return util.trim(h.exec({ "svn", "info", "--show-item", "url", util.svn_target(root) }, root))
				end
				for _, url in ipairs({ branch, tag }) do
					pick(repo, { (url:gsub("@", "%%40")) })
					assert(current() == url, "literal SVN URL was not selected")
				end
				for _, expression in ipairs({ branch .. "@", tag .. "@HEAD" }) do
					pick(repo, { "svn_switch_url" }, expression)
					assert(current() == expression:gsub("@HEAD$", ""):gsub("@$", ""), "manual peg expression changed")
				end
			end),
		},
	}
end
