return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	local ops, state_store = require("lazyvcs.source_control.ops"), require("lazyvcs.state")
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false, sync_button_behavior = "direct" },
		})
	end
	local function state_for(root, vcs)
		local repo = { root = root, name = "fixture", vcs = vcs or "git", sync = { status = "outgoing" } }
		return {
			path = root,
			lazyvcs_repo_cache = { [root] = repo },
			lazyvcs_commit_drafts = {},
			lazyvcs_render = function() end,
		},
			repo
	end
	local function action(state, repo, name)
		ops.run_primary_action(state, { type = "action_button", extra = { repo_root = repo.root, action = name } })
	end
	local function finished(root)
		ctx.wait_for(function()
			local job = state_store.get_repo_job(root)
			return not job or job.status ~= "running"
		end, "mutation did not complete", 15000)
		return state_store.get_repo_job(root)
	end
	local function success(root)
		local job = finished(root)
		assert(not job, job and job.error)
	end
	local function git(root, ...)
		return util.trim(h.exec(vim.list_extend({ "git" }, { ... }), root))
	end
	local function node_for(f, section, relpath, vcs)
		local state, repo = state_for(f.root, vcs)
		local loaded, load_err, done
		require("lazyvcs.source_control.model").load_repo_details_async(
			repo,
			{ remote_refresh = false },
			function(args, opts, cb)
				return util.system_start(args, { cwd = opts.cwd or f.root, timeout = opts.timeout_ms }, cb)
			end,
			function(value, err)
				loaded, load_err, done = value, err, true
			end
		)
		ctx.wait_for(function()
			return done
		end, "model did not load", 15000)
		assert(loaded, load_err)
		state.lazyvcs_repo_cache[f.root] = loaded
		for _, group in ipairs(loaded.sections) do
			if group.id == section then
				for _, node in ipairs(group.items) do
					if node.extra.relpath == relpath then
						return state, loaded, node
					end
				end
			end
		end
		error("model node missing: " .. section .. "/" .. relpath)
	end
	local function rename_fixture()
		local f = h.make_git_fixture()
		git(f.root, "restore", "sample.txt")
		git(f.root, "mv", "sample.txt", "new [1].txt")
		return f
	end
	local function delay_mutation(repo, run, delay)
		local jobs, exits = require("lazyvcs.source_control.jobs"), {}
		for _ = 1, require("lazyvcs.config").get().source_control.background.git_workers do
			jobs.command(repo, "blocker", { "git", "status" }, {
				start = function(_, _, cb)
					exits[#exits + 1] = cb
					return {}
				end,
			}, function() end)
		end
		run()
		delay()
		for _, exit in ipairs(exits) do
			exit({ code = 0, stdout = "", stderr = "" })
		end
	end
	local function svn_directory_fixture()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "revert", "sample.txt" }, f.root)
		vim.fn.mkdir(f.root .. "/dir/nested", "p")
		h.write_file(f.root .. "/dir/nested/child.txt", "child base\n")
		h.write_file(f.root .. "/dir-other.txt", "sibling base\n")
		h.exec({ "svn", "add", "dir", "dir-other.txt" }, f.root)
		h.exec({ "svn", "commit", "-m", "directory" }, f.root)
		return f
	end
	local function wait_mutation(root, kind)
		ctx.wait_for(function()
			for _, job in ipairs(require("lazyvcs.source_control.jobs").history()) do
				if job.root == root and job.kind == kind then
					return true
				end
			end
		end, "mutation did not finish: " .. kind, 15000)
	end
	local cases = {
		{
			"test_source_control_switch_protects_selected_ref_arguments",
			function()
				setup()
				local f = h.make_git_fixture()
				git(f.root, "restore", "sample.txt")
				git(f.root, "branch", "-M", "main")
				local expected = git(f.root, "rev-parse", "HEAD")
				for _, tag in ipairs({ "--discard-changes", "ordinary", "collision" }) do
					git(f.root, "update-ref", "refs/tags/" .. tag, "HEAD")
				end
				h.write_file(f.file, "new head\n")
				git(f.root, "commit", "-am", "advance")
				git(f.root, "branch", "collision")
				local switch = require("lazyvcs.source_control.switch")
				for _, tag in ipairs({ "--discard-changes", "ordinary", "collision" }) do
					for _, mode in ipairs({ "direct", "git_checkout_detached", "git_create_branch_from" }) do
						git(f.root, "switch", "main")
						local completed, failure, picked = false, nil, false
						switch.open_async({ root = f.root, name = "fixture", vcs = "git" }, {
							select = function(items, _, cb)
								for _, item in ipairs(items) do
									if
										mode ~= "direct" and not picked and item.action == mode
										or (mode == "direct" or picked) and item.refname == "refs/tags/" .. tag
									then
										picked = true
										return cb(item)
									end
								end
								failure = "selected ref was missing"
							end,
							input = function(_, cb)
								cb("new-" .. tag)
							end,
							after_mutation = function()
								completed = true
							end,
							notify = function(err)
								failure = err
							end,
						}, function(args, opts, cb)
							return util.system_start(args, { cwd = f.root, timeout = opts.timeout_ms }, cb)
						end)
						ctx.wait_for(function()
							return completed or failure
						end, "switch did not finish", 15000)
						assert(not failure, failure)
						assert(
							git(f.root, "rev-parse", "HEAD") == expected,
							mode .. " checked out the wrong commit for " .. tag
						)
						assert(
							git(f.root, "branch", "--show-current")
								== (mode == "git_create_branch_from" and "new-" .. tag or "")
						)
					end
				end
			end,
		},

		{
			"test_source_control_svn_deleted_directory_discard_restores_children",
			function()
				setup()
				local f = svn_directory_fixture()
				h.exec({ "svn", "delete", "dir" }, f.root)
				local state, _, node = node_for(f, "changes", "dir", "svn")
				local sibling = vim.fn.bufadd(f.root .. "/dir-other.txt")
				vim.fn.bufload(sibling)
				vim.api.nvim_buf_set_lines(sibling, 0, -1, false, { "unsaved sibling" })
				local confirm, popup, prompt = require("lazyvcs.source_control.confirm"), nil, nil
				local open = confirm.open
				require("lazyvcs.config").get().source_control.confirm_mutations = true
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.open = function(opts, cb)
					prompt = opts.prompt
					popup = open(opts, cb)
					return popup
				end
				local ok, err = xpcall(function()
					ops.revert_file(state, node)
					ctx.wait_for(function()
						return popup ~= nil
					end, "SVN confirmation did not open", 15000)
					local subtree_prompt = assert(prompt):find("descendants", 1, true) ~= nil
					vim.fn.maparg("1", "n", false, true).callback()
					wait_mutation(f.root, "svn_revert")
					success(f.root)
					assert(
						vim.fn.filereadable(f.root .. "/dir/nested/child.txt") == 1,
						"directory Discard left children deleted"
					)
					assert(vim.deep_equal(vim.fn.readfile(f.root .. "/dir/nested/child.txt"), { "child base" }))
					assert(h.exec({ "svn", "status" }, f.root) == "", "directory Discard left deletion status")
					assert(subtree_prompt, "confirmation must name the directory and descendants")
					assert(vim.bo[sibling].modified, "recursive Discard included a sibling prefix")
				end, debug.traceback)
				confirm.open = open
				vim.api.nvim_buf_delete(sibling, { force = true })
				if popup then
					popup.close()
				end
				assert(ok, err)

				setup()
				for _, variant in ipairs({ "modified", "queued", "reclassified" }) do
					f = svn_directory_fixture()
					h.exec({ "svn", "delete", "dir" }, f.root)
					local repo
					state, repo, node = node_for(f, "changes", "dir", "svn")
					local buf = vim.fn.bufadd(f.root .. "/dir/nested/child.txt")
					vim.fn.bufload(buf)
					vim.bo[buf].buflisted = false
					local function edit()
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved descendant" })
					end
					local command, notify = require("lazyvcs.source_control.jobs").command, util.notify
					local jobs, notified, queued = require("lazyvcs.source_control.jobs"), false, false
					---@diagnostic disable-next-line: duplicate-set-field
					util.notify = function()
						notified = true
					end
					---@diagnostic disable-next-line: duplicate-set-field
					jobs.command = function(target, kind, args, opts, cb)
						if kind == "svn_revert" and variant ~= "modified" then
							local release
							command(repo, "blocker", { "svn", "status" }, {
								start = function(_, _, exit)
									release = exit
									return {}
								end,
							}, function() end)
							local id = command(target, kind, args, opts, cb)
							queued = true
							if variant == "reclassified" then
								h.exec({ "svn", "revert", "--depth", "infinity", "dir" }, f.root)
								h.write_file(f.root .. "/dir/nested/child.txt", "saved after reclassification\n")
							else
								edit()
							end
							release({ code = 0, stdout = "", stderr = "" })
							return id
						end
						return command(target, kind, args, opts, cb)
					end
					ok, err = xpcall(function()
						if variant == "modified" then
							edit()
						end
						ops.revert_file(state, node)
						ctx.wait_for(function()
							return notified
						end, "directory Discard missed a modified descendant or changed classification", 15000)
						if variant ~= "modified" then
							assert(queued, "queued guard was not exercised")
						end
						if variant == "reclassified" then
							assert(
								vim.fn.readfile(f.root .. "/dir/nested/child.txt")[1] == "saved after reclassification"
							)
						else
							assert(vim.bo[buf].modified and vim.fn.filereadable(f.root .. "/dir/nested/child.txt") == 0)
						end
					end, debug.traceback)
					jobs.command, util.notify = command, notify
					vim.api.nvim_buf_delete(buf, { force = true })
					assert(ok, err)
				end

				f = svn_directory_fixture()
				h.exec({ "svn", "propset", "test:property", "value", "dir" }, f.root)
				h.write_file(f.root .. "/dir/nested/child.txt", "saved child edit\n")
				state, _, node = node_for(f, "changes", "dir", "svn")
				local buf = vim.fn.bufadd(f.root .. "/dir-other.txt")
				vim.fn.bufload(buf)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved sibling" })
				ops.revert_file(state, node)
				wait_mutation(f.root, "svn_revert")
				success(f.root)
				assert(h.exec({ "svn", "proplist", "dir" }, f.root) == "", "directory property was not discarded")
				assert(
					vim.fn.readfile(f.root .. "/dir/nested/child.txt")[1] == "saved child edit",
					"property-only Discard recursed"
				)
				assert(vim.bo[buf].modified, "subtree matching included a sibling prefix")
				vim.api.nvim_buf_delete(buf, { force = true })
			end,
		},

		{
			"test_source_control_staged_rename_unstage_covers_both_paths",
			function()
				setup()
				local f = rename_fixture()
				local state, _, node = node_for(f, "staged", "new [1].txt")
				ops.unstage_file(state, node)
				success(f.root)
				assert(git(f.root, "diff", "--cached", "--name-only") == "", "Unstage left the rename source staged")
				assert(vim.deep_equal(vim.fn.readfile(f.root .. "/new [1].txt"), { "one", "two", "three" }))
			end,
		},
		{
			"test_source_control_staged_rename_discard_covers_both_paths",
			function()
				setup()
				local f = rename_fixture()
				local state, _, node = node_for(f, "staged", "new [1].txt")
				ops.revert_file(state, node)
				success(f.root)
				assert(git(f.root, "status", "--porcelain") == "", "Discard left the rename source staged")
				assert(vim.fn.filereadable(f.root .. "/new [1].txt") == 0)
				assert(vim.deep_equal(vim.fn.readfile(f.file), { "one", "two", "three" }))

				f = rename_fixture()
				h.write_file(f.root .. "/new [1].txt", "unstaged rename edit\n")
				state, _, node = node_for(f, "changes", "new [1].txt")
				ops.revert_file(state, node)
				success(f.root)
				assert(
					git(f.root, "diff", "--cached", "--name-status"):find("R100"),
					"unstaged Discard undid the staged rename"
				)
				assert(vim.deep_equal(vim.fn.readfile(f.root .. "/new [1].txt"), { "one", "two", "three" }))

				for _, path in ipairs({ "sample.txt", "new [1].txt" }) do
					for _, queued in ipairs({ false, true }) do
						f = rename_fixture()
						local repo
						state, repo, node = node_for(f, "staged", "new [1].txt")
						local buf = vim.fn.bufadd(f.root .. "/" .. path)
						vim.fn.bufload(buf)
						local function edit()
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved rename buffer" })
						end
						if queued then
							delay_mutation(repo, function()
								ops.revert_file(state, node)
							end, edit)
							local job = finished(f.root)
							assert(job and job.error:find("modified buffers"), "queued Discard missed a rename buffer")
						else
							edit()
							ops.revert_file(state, node)
							assert(not state_store.get_repo_job(f.root), "Discard must refuse before confirmation")
						end
						assert(
							git(f.root, "diff", "--cached", "--name-status"):find("R100"),
							"blocked Discard changed the rename"
						)
						assert(
							vim.bo[buf].modified
								and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved rename buffer"
						)
						vim.api.nvim_buf_delete(buf, { force = true })
					end
				end
			end,
		},
		{
			"test_source_control_unstage_edited_addition_preserves_worktree",
			function()
				setup()
				for _, variant in ipairs({ "committed", "unborn", "unborn_changes" }) do
					local f = h.make_git_fixture()
					git(f.root, "restore", "sample.txt")
					if variant ~= "committed" then
						git(f.root, "checkout", "--orphan", "unborn")
						git(f.root, "rm", "--cached", "sample.txt")
					end
					local path = f.root .. "/new.txt"
					h.write_file(path, "staged\n")
					git(f.root, "add", "new.txt")
					h.write_file(path, "later saved edit\n")
					local state, _, node = node_for(f, variant == "unborn_changes" and "changes" or "staged", "new.txt")
					ops.unstage_file(state, node)
					local job = finished(f.root)
					assert(not job, "edited addition could not be unstaged: " .. tostring(job and job.error))
					assert(git(f.root, "ls-files", "--", "new.txt") == "", "addition remains indexed")
					assert(git(f.root, "status", "--porcelain", "--", "new.txt") == "?? new.txt")
					assert(vim.deep_equal(vim.fn.readfile(path), { "later saved edit" }))
				end
			end,
		},
		{
			"test_source_control_discard_checks_loaded_buffer_timestamps",
			function()
				setup()
				local autoread, start = vim.o.autoread, util.system_start
				local ok, err = xpcall(function()
					vim.o.autoread = true
					for _, edited in ipairs({ false, true }) do
						local f = h.make_git_fixture()
						vim.cmd.edit(vim.fn.fnameescape(f.file))
						local buf = vim.api.nvim_get_current_buf()
						local state, _, node = node_for(f, "changes", "sample.txt")
						local compare = require("lazyvcs.compare")
						local review = assert(compare.open({ editable = false, path = f.root, base = "HEAD" }))
						ctx.wait_for(function()
							return review.preview_result ~= nil
						end, "Compare snapshots did not load", 15000)
						local base = vim.api.nvim_buf_get_lines(review.left, 0, -1, false)
						local saved = vim.api.nvim_buf_get_lines(review.right, 0, -1, false)
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, cb)
							if edited and args[2] == "restore" then
								return start(args, opts, function(...)
									vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved during discard" })
									cb(...)
								end)
							end
							return start(args, opts, cb)
						end
						ops.revert_file(state, node)
						success(f.root)
						assert(vim.deep_equal(vim.fn.readfile(f.file), { "one", "two", "three" }))
						local expected = edited and { "unsaved during discard" } or { "one", "two", "three" }
						assert(
							vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected),
							"Discard left stale buffer contents"
						)
						assert(vim.bo[buf].modified == edited, "Discard changed the modified flag")
						assert(
							vim.deep_equal(vim.api.nvim_buf_get_lines(review.left, 0, -1, false), base),
							"Discard rewrote the base snapshot"
						)
						assert(
							vim.deep_equal(vim.api.nvim_buf_get_lines(review.right, 0, -1, false), saved),
							"Discard rewrote the saved snapshot"
						)
						compare.close(review)
						vim.api.nvim_buf_delete(buf, { force = true })
					end
				end, debug.traceback)
				vim.o.autoread, util.system_start = autoread, start
				assert(ok, err)
			end,
		},

		{
			"test_source_control_sync_rechecks_branch_after_fetch_and_queue",
			function()
				setup()
				local jobs = require("lazyvcs.source_control.jobs")
				for _, operation in ipairs({ "sync", "pull" }) do
					for _, when in
						ipairs(
							operation == "sync" and { "fetch", "queued", "publish_queued", "unchanged" }
								or { "fetch", "queued", "unchanged" }
						)
					do
						local f = h.make_git_remote_fixture()
						git(f.root, "push", "origin", "main")
						local expected = git(f.root, "rev-parse", "HEAD")
						git(f.root, "reset", "--hard", "HEAD~1")
						local before = git(f.root, "rev-parse", "HEAD")
						git(f.root, "branch", "other")
						git(f.root, "branch", "--set-upstream-to=origin/main", "other")
						if when == "publish_queued" then
							git(f.root, "branch", "--unset-upstream", "main")
						end
						local state, repo = state_for(f.root)
						local start, command = util.system_start, jobs.command
						local switched, exits = false, {}
						local function switch()
							git(f.root, "switch", "other")
							switched = true
						end
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, cb)
							if when == "fetch" and args[2] == "fetch" then
								return start(args, opts, function(...)
									switch()
									cb(...)
								end)
							end
							return start(args, opts, cb)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						jobs.command = function(target, kind, args, opts, cb)
							if
								when == "queued" and kind == "git_merge"
								or when == "publish_queued" and kind == "git_publish"
							then
								for _ = 1, require("lazyvcs.config").get().source_control.background.git_workers do
									command(repo, "blocker", { "git", "status" }, {
										owner = exits,
										start = function(_, _, exit)
											exits[#exits + 1] = exit
											return {}
										end,
									}, function() end)
								end
								local id = command(target, kind, args, opts, cb)
								switch()
								for _, exit in ipairs(exits) do
									exit({ code = 0, stdout = "", stderr = "" })
								end
								return id
							end
							return command(target, kind, args, opts, cb)
						end
						local ok, err = xpcall(function()
							action(state, repo, operation)
							local job = finished(f.root)
							if when == "unchanged" then
								assert(not job, job and job.error)
								assert(
									git(f.root, "rev-parse", "main") == expected,
									"unchanged branch did not fast-forward"
								)
							else
								assert(switched, "race was not exercised")
								assert(
									git(f.root, "rev-parse", "main") == before,
									"operation moved the original branch"
								)
								assert(
									git(f.root, "rev-parse", "other") == before,
									"operation moved the newly selected branch"
								)
								assert(
									vim.deep_equal(vim.fn.readfile(f.file), { "one", "two" }),
									"operation changed the other worktree"
								)
								assert(job and job.error:find("retry"), "branch change must report a retry error")
							end
						end, debug.traceback)
						util.system_start, jobs.command = start, command
						assert(ok, err)
					end
				end
			end,
		},

		{
			"test_source_control_push_uses_structured_upstream",
			function()
				setup()
				for _, remote in ipairs({ ".", "team/origin", "origin" }) do
					for _, operation in ipairs({ "push", "publish" }) do
						local f = h.make_git_fixture()
						git(f.root, "restore", "sample.txt")
						git(f.root, "branch", "-M", "topic")
						local before = git(f.root, "rev-parse", "HEAD")
						local destination = h.tempdir()
						git(destination, "init", "--bare")
						if remote == "." then
							git(f.root, "branch", "release/main")
							git(f.root, "branch", "--set-upstream-to=release/main")
							git(f.root, "remote", "add", "release", destination)
						else
							git(f.root, "remote", "add", remote, destination)
							git(f.root, "push", "-u", remote, "HEAD:refs/heads/release/main")
						end
						h.write_file(f.file, "published\n")
						git(f.root, "commit", "-am", "publish")
						local expected = git(f.root, "rev-parse", "HEAD")
						local state, repo = state_for(f.root)
						local start, queried = util.system_start, false
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, cb)
							if operation == "publish" and args[2] == "for-each-ref" and not queried then
								queried = true
								cb({ code = 0, stdout = "", stderr = "" })
								return {}
							end
							return start(args, opts, cb)
						end
						local ok, err = xpcall(function()
							action(state, repo, "push")
							success(f.root)
						end, debug.traceback)
						util.system_start = start
						assert(ok, err)
						local actual = remote == "." and git(f.root, "rev-parse", "refs/heads/release/main")
							or git(destination, "rev-parse", "refs/heads/release/main")
						assert(actual == expected, "Push did not advance the configured " .. remote .. " upstream")
						if remote == "." then
							assert(git(destination, "for-each-ref") == "", "Push published to the decoy remote")
							assert(before ~= actual)
						end
					end
				end

				local f = h.make_git_fixture()
				local state, repo = state_for(f.root)
				git(f.root, "branch", "-M", "main")
				local start, pushed = util.system_start, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[2] == "for-each-ref" then
						cb({ code = 0, stdout = "refs/heads/main\0refs/remotes/origin/main\0origin\0\n", stderr = "" })
						return {}
					end
					pushed = pushed or args[2] == "push"
					return start(args, opts, cb)
				end
				local ok, err = xpcall(function()
					action(state, repo, "push")
					local job = finished(f.root)
					assert(job and job.error and not pushed, "incomplete upstream metadata must stop Push")
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end,
		},
	}
	return cases
end
