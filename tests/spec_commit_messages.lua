return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local jobs = require("lazyvcs.source_control.jobs")
	local session = require("lazyvcs.state")
	local picker = require("lazyvcs.picker")
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false },
		})
	end
	local function state_for(root, vcs, message, stage_all)
		return {
			path = root,
			lazyvcs_commit_drafts = { [root] = message },
			lazyvcs_repo_cache = {
				[root] = {
					root = root,
					vcs = vcs,
					name = "repo",
					counts = { staged = stage_all and 0 or 1, local_changes = 1 },
				},
			},
			lazyvcs_render = function() end,
		}, { path = root }
	end
	local function guarded(fn)
		return function()
			setup()
			local select, start, notify, command = picker.select, util.system_start, util.notify, jobs.command
			local notices = {}
			---@diagnostic disable-next-line: duplicate-set-field
			picker.select = function(_, _, done)
				done("Stage all and commit")
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(message)
				notices[#notices + 1] = message
			end
			local ok, err = xpcall(function()
				fn(notices)
			end, debug.traceback)
			picker.select, util.system_start, util.notify = select, start, notify
			jobs.command = command
			assert(ok, err)
		end
	end
	local function finished(root)
		wait(function()
			local job = session.get_repo_job(root)
			return not job or job.status ~= "running"
		end, "commit did not finish", 15000)
	end
	local function long_commit(vcs, stage_all)
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		local message = "Long message\n\n" .. string.rep("x", 140000) .. "\n\nTail"
		if vcs == "git" and not stage_all then
			h.exec({ "git", "add", "sample.txt" }, f.root)
		end
		local state, node = state_for(f.root, vcs, message, stage_all)
		ops.commit_repo(state, node)
		finished(f.root)
		local failed = session.get_repo_job(f.root)
		assert(not failed, "long commit message did not commit")
		local actual
		if vcs == "git" then
			actual = util.trim(h.exec({ "git", "log", "-1", "--format=%B" }, f.root))
		else
			actual = h.exec({ "svn", "log", "-r", "HEAD", "-l", "1", "--xml", util.svn_target(f.root) }, f.root)
				:match("<msg>(.-)</msg>")
		end
		assert(actual == message, "committed message bytes changed")
		assert(state.lazyvcs_commit_drafts[f.root] == "", "successful commit did not clear draft")
	end
	local function utf8_commit(vcs)
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		local message = "café ✓ naïve"
		if vcs == "git" then
			h.exec({ "git", "add", "sample.txt" }, f.root)
		end
		local state, node = state_for(f.root, vcs, message)
		local locale = vim.env.LC_ALL
		vim.env.LC_ALL = "C"
		local ok, err = xpcall(function()
			ops.commit_repo(state, node)
			finished(f.root)
			assert(
				not session.get_repo_job(f.root),
				"UTF-8 commit failed: " .. vim.inspect(session.get_repo_job(f.root))
			)
			if vcs == "git" then
				local object = h.exec({ "git", "cat-file", "commit", "HEAD" }, f.root)
				assert(object:match("\n\n(.*)$") == message .. "\n", "committed message bytes changed")
			else
				local xml = h.exec({ "svn", "log", "-r", "HEAD", "-l", "1", "--xml", util.svn_target(f.root) }, f.root)
				assert(xml:match("<msg>(.-)</msg>") == message, "committed message bytes changed")
			end
		end, debug.traceback)
		vim.env.LC_ALL = locale
		assert(ok, err)
	end
	return {
		{
			"test_source_control_commit_falls_back_when_cache_is_not_private",
			guarded(function()
				local mkdir, chmod, stat, start = vim.fn.mkdir, vim.uv.fs_chmod, vim.uv.fs_stat, util.system_start
				local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
				local ok, err = xpcall(function()
					local failures = { "mkdir", "chmod" }
					if vim.fn.has("win32") ~= 1 then
						failures[#failures + 1] = "mode"
					end
					for _, failure in ipairs(failures) do
						local f = h.make_git_fixture()
						h.exec({ "git", "add", "sample.txt" }, f.root)
						local message = "Fallback " .. failure
						local state, node = state_for(f.root, "git", message)
						---@diagnostic disable-next-line: duplicate-set-field
						vim.fn.mkdir = function(path, ...)
							if path == dir and failure == "mkdir" then
								error("cache unavailable")
							end
							return mkdir(path, ...)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						vim.uv.fs_chmod = function(path, ...)
							if path == dir and failure == "chmod" then
								return nil, "EPERM"
							end
							return chmod(path, ...)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						vim.uv.fs_stat = function(path, ...)
							local value, err, code = stat(path, ...)
							if path == dir and failure == "mode" and value then
								value.mode = 511
							end
							return value, err, code
						end
						local path
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, done)
							path = args[vim.fn.index(args, "-F") + 2]
							assert(path and not vim.startswith(path, dir .. "/"), "commit used unavailable cache")
							assert(opts.preserve_on_shutdown == false, "temporary commit can outlive editor")
							return start(args, opts, done)
						end
						ops.commit_repo(state, node)
						finished(f.root)
						assert(path, "cache failure prevented commit spawn")
						assert(not session.get_repo_job(f.root), "fallback commit failed")
						assert(util.trim(h.exec({ "git", "log", "-1", "--format=%B" }, f.root)) == message)
						assert(not vim.uv.fs_stat(path), "temporary message leaked")
					end
				end, debug.traceback)
				vim.fn.mkdir, vim.uv.fs_chmod, vim.uv.fs_stat, util.system_start = mkdir, chmod, stat, start
				assert(ok, err)
			end),
		},
		{
			"test_source_control_setup_prunes_only_previous_boot_legacy_commit_files_asynchronously",
			guarded(function()
				local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
				vim.fn.mkdir(dir, "p")
				assert(vim.uv.fs_chmod(dir, 448))
				local old, recent = dir .. "/old.txt", dir .. "/recent.txt"
				vim.fn.writefile({ "old" }, old)
				vim.fn.writefile({ "recent" }, recent)
				local expired = os.time() - vim.uv.uptime() - 10
				assert(vim.uv.fs_utime(old, expired, expired))
				vim.fn.mkdir(dir .. "/subdir", "p")
				assert(vim.uv.fs_utime(dir .. "/subdir", expired, expired))
				local scandir_next = vim.uv.fs_scandir_next
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_scandir_next = function(scan)
					local name = scandir_next(scan)
					return name, "unknown"
				end
				local ok, err = xpcall(function()
					setup()
					assert(vim.uv.fs_stat(old), "setup blocked to prune files")
					wait(function()
						return not vim.uv.fs_stat(old)
					end, "stale message was not pruned")
					assert(vim.uv.fs_stat(recent), "recent message was pruned")
					assert(vim.uv.fs_stat(dir .. "/subdir"), "pruning removed a directory")
				end, debug.traceback)
				vim.uv.fs_scandir_next = scandir_next
				assert(ok, err)
			end),
		},
		{ "test_source_control_utf8_git_commit_message_c_locale", guarded(function()
			utf8_commit("git")
		end) },
		{ "test_svn_utf8_commit_message_c_locale", guarded(function()
			utf8_commit("svn")
		end) },
		{
			"test_source_control_commit_message_file_after_reordered_flag",
			guarded(function()
				local root, message = h.tempdir(), "Reordered message"
				local state, node = state_for(root, "svn", message)
				local command, started, path = jobs.command, false, nil
				---@diagnostic disable-next-line: duplicate-set-field
				jobs.command = function(repo, kind, args, opts, done)
					table.insert(args, 3, "--non-interactive")
					return command(repo, kind, args, opts, done)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _, done)
					started = true
					assert(args[3] == "--non-interactive", "inserted argument changed")
					local flag = vim.fn.index(args, "-F") + 1
					assert(flag > 0, "message file flag overwritten")
					path = args[flag + 1]
					assert(path ~= "-", "message path did not follow -F")
					assert(table.concat(vim.fn.readfile(path, "b"), "\n") == message, "message path is wrong")
					done({ code = 0, stdout = "", stderr = "" })
					return {}
				end
				ops.commit_repo(state, node)
				finished(root)
				assert(started and not session.get_repo_job(root), "reordered commit failed")
				assert(path and not vim.uv.fs_stat(path), "reordered commit message file leaked")
			end),
		},
		{
			"test_source_control_commit_rejects_missing_message_file_argument",
			guarded(function()
				local command = jobs.command
				for _, mode in ipairs({ "missing_flag", "missing_path" }) do
					local root, message = h.tempdir(), "Unsubmitted message"
					local state, node = state_for(root, "git", message)
					---@diagnostic disable-next-line: duplicate-set-field
					jobs.command = function(repo, kind, args, opts, done)
						local flag = vim.fn.index(args, "-F") + 1
						assert(flag > 0)
						table.remove(args, flag + 1)
						if mode == "missing_flag" then
							table.remove(args, flag)
						end
						return command(repo, kind, args, opts, done)
					end
					local started = false
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(_, _, done)
						started = true
						done({ code = 0, stdout = "", stderr = "" })
						return {}
					end
					ops.commit_repo(state, node)
					finished(root)
					local job = session.get_repo_job(root)
					assert(not started, "malformed commit reached process start")
					assert(
						job and job.error == "Commit command is missing the -F message file argument",
						"missing argument error changed"
					)
					assert(not job.error:find("[\r\n]"), "commit start error is not a single line")
					assert(state.lazyvcs_commit_drafts[root] == message, "rejected commit lost draft")
					session.clear_repo_job(root)
				end
			end),
		},
		{ "test_source_control_long_git_commit_message", guarded(function()
			long_commit("git", false)
		end) },
		{ "test_source_control_long_stage_all_commit_message", guarded(function()
			long_commit("git", true)
		end) },
		{ "test_svn_long_commit_message", guarded(function()
			long_commit("svn", false)
		end) },
		{
			"test_source_control_commit_private_file_lifecycle",
			guarded(function(notices)
				for _, mode in ipairs({ "success", "failure", "spawn_exception", "cancel" }) do
					local root = h.tempdir()
					local message = "Private subject\n\nPrivate body"
					local state, node = state_for(root, "git", message)
					local path, exit, killed
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, process_opts, done)
						assert(
							process_opts.preserve_on_shutdown and process_opts.on_exit_during_shutdown,
							"shutdown options dropped"
						)
						assert(
							process_opts.cwd == root
								and process_opts.timeout > 0
								and process_opts.output_limit > 0
								and process_opts.kill_grace_ms >= 0
								and type(process_opts.on_terminate) == "function",
							"process options dropped"
						)
						local flag = vim.fn.index(args, "-F") + 1
						assert(flag > 0, "commit message still transported in argv")
						path, exit = args[flag + 1], done
						assert(
							table.concat(vim.fn.readfile(path, "b"), "\n") == message,
							"private message file bytes changed"
						)
						local mode_bits = assert(vim.uv.fs_stat(path)).mode % 512
						if vim.fn.has("win32") == 0 then
							assert(mode_bits == 384, "message file is not private")
							assert(
								vim.fn.fnamemodify(path, ":h") == vim.fn.stdpath("cache") .. "/lazyvcs/commit",
								"message is not in persistent cache"
							)
							assert(
								assert(vim.uv.fs_stat(vim.fn.fnamemodify(path, ":h"))).mode % 512 == 448,
								"message directory is not private"
							)
						end
						if mode == "spawn_exception" then
							error("spawn rejected")
						end
						if mode == "success" then
							done({ code = 0, stdout = "", stderr = "" })
						elseif mode == "failure" then
							done(nil, "commit rejected", { code = 1 })
						end
						return {
							kill = function()
								killed = true
							end,
						}
					end
					ops.commit_repo(state, node)
					local job = session.get_repo_job(root)
					if mode == "success" then
						assert(not job, job and job.error)
					elseif mode == "cancel" then
						assert(job and job.status == "running", job and job.error)
					end
					if mode == "cancel" then
						ops.cancel(root, { all_owners = true })
						assert(killed and vim.uv.fs_stat(path), "message file removed before cancelled process exited")
						exit(nil, "cancelled", { code = 130, cancelled = true })
					end
					finished(root)
					assert(path, "commit message still transported in argv")
					assert(not vim.uv.fs_stat(path), "commit message file leaked")
					assert(
						mode == "success" or state.lazyvcs_commit_drafts[root] == message,
						"failed commit lost draft"
					)
					session.clear_repo_job(root)
				end
				for _, message in ipairs(notices) do
					assert(
						#message < 2048 and not message:find("Private body", 1, true),
						"commit diagnostic exposed message"
					)
				end
				-- Queue cancellation must not create a message file or start a commit.
				local root, exits = h.tempdir(), {}
				local state, node = state_for(root, "git", "Queued message")
				local repo = state.lazyvcs_repo_cache[root]
				for _ = 1, require("lazyvcs.config").get().source_control.background.git_workers do
					jobs.command(repo, "blocker", { "git", "status" }, {
						start = function(_, _, done)
							exits[#exits + 1] = done
							return {}
						end,
					}, function() end)
				end
				local started = false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function()
					started = true
					return {}
				end
				ops.commit_repo(state, node)
				ops.cancel(root, { owner = root })
				for _, exit in ipairs(exits) do
					exit({ code = 0, stdout = "", stderr = "" })
				end
				assert(
					not started and state.lazyvcs_commit_drafts[root] == "Queued message",
					"queued cancellation started commit or lost draft"
				)
			end),
		},
	}
end
