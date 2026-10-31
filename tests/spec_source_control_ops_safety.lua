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

	local function confirmed(run, before)
		require("lazyvcs.config").get().source_control.confirm_mutations = true
		local confirm = require("lazyvcs.source_control.confirm")
		local open = confirm.open
		local popup, prompt
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(opts, cb)
			prompt = opts.prompt
			popup = open(opts, cb)
			return popup
		end
		local ok, err = xpcall(function()
			run()
			ctx.wait_for(function()
				return popup ~= nil
			end, "confirmation did not open", 15000)
			if before then
				before()
			end
			vim.fn.maparg("1", "n", false, true).callback()
		end, debug.traceback)
		confirm.open = open
		if popup then
			popup.close()
		end
		assert(ok, err)
		return prompt
	end
	local function stale_addition(operation)
		for _, queued in ipairs({ false, true }) do
			setup()
			local f = h.make_git_fixture()
			git(f.root, "restore", "sample.txt")
			h.write_file(f.root .. "/added.txt", "committed content\n")
			git(f.root, "add", "added.txt")
			local state, repo, node = node_for(f, "staged", "added.txt")
			local function commit()
				git(f.root, "commit", "-m", "external commit")
			end
			if queued then
				delay_mutation(repo, function()
					ops[operation](state, node)
				end, commit)
			else
				confirmed(function()
					ops[operation](state, node)
				end, commit)
			end
			local job = finished(f.root)
			assert(git(f.root, "diff", "--cached", "--name-only") == "", "stale addition staged a deletion")
			assert(vim.fn.readfile(f.root .. "/added.txt")[1] == "committed content")
			assert(job and job.error:find("retry"), "stale addition must request refresh and retry")
		end
	end

	local function directory_to_file(operation)
		for _, queued in ipairs({ false, true }) do
			setup()
			local f = h.make_git_fixture()
			git(f.root, "restore", "sample.txt")
			local path = "converted [1]"
			vim.fn.mkdir(f.root .. "/" .. path .. "/nested", "p")
			h.write_file(f.root .. "/" .. path .. "/nested/child.txt", "old child\n")
			git(f.root, "add", "--", path)
			git(f.root, "commit", "-m", "tracked directory")
			vim.fn.delete(f.root .. "/" .. path, "rf")
			h.write_file(f.root .. "/" .. path, "replacement file\n")
			git(f.root, "add", "-A", "--", path)
			local state, repo, node = node_for(f, "staged", path)
			assert(node.extra.index_status == "A", "fixture must expose a staged addition")
			if queued then
				delay_mutation(repo, function()
					ops[operation](state, node)
				end, function() end)
			else
				confirmed(function()
					ops[operation](state, node)
				end)
			end
			success(f.root)
			assert(git(f.root, "ls-files", "--", path) == "", "replacement remains indexed")
			assert(
				git(f.root, "diff", "--cached", "--name-only", "--diff-filter=D") == path .. "/nested/child.txt",
				"removing the addition changed the former child deletion"
			)
			if operation == "unstage_file" then
				assert(vim.fn.readfile(f.root .. "/" .. path)[1] == "replacement file")
			else
				assert(not vim.uv.fs_lstat(f.root .. "/" .. path), "Discard left the replacement file")
			end
			assert(vim.fn.readfile(f.file)[1] == "one", "mutation changed an unselected file")
		end
	end

	local function svn_link_obstruction(descendant, junction)
		setup()
		local f = svn_directory_fixture()
		h.exec({ "svn", "delete", "dir" }, f.root)
		local outside = h.tempdir()
		h.write_file(outside .. "/child.txt", "precious outside\n")
		vim.fn.mkdir(outside .. "/nested", "p")
		h.write_file(outside .. "/nested/child.txt", "precious nested\n")
		local target = f.root .. "/dir"
		if descendant then
			vim.fn.mkdir(target, "p")
			target = target .. "/nested"
		end
		local linked, link_err, code =
			vim.uv.fs_symlink(outside, target, junction and { junction = true } or { dir = true })
		if not linked and not junction and vim.fn.has("win32") == 1 then
			if code == "EPERM" or code == "EACCES" or code == "ENOTSUP" or code == "ENOSYS" then
				error({ lazyvcs_skip = "Windows directory symlinks unavailable: " .. tostring(link_err) })
			end
		end
		assert(linked, link_err)
		local state, _, node = node_for(f, "changes", "dir", "svn")
		local lstat, checked, followed = vim.uv.fs_lstat, false, false
		---@diagnostic disable-next-line: duplicate-set-field
		vim.uv.fs_lstat = function(path, cb)
			if cb then
				checked = checked or path == target
				followed = followed or path:sub(1, #target + 1) == target .. "/"
			end
			return lstat(path, cb)
		end
		local ok, err = xpcall(function()
			confirmed(function()
				ops.revert_file(state, node)
			end)
			wait_mutation(f.root, "svn_revert")
			local job = finished(f.root)
			assert(vim.fn.readfile(outside .. "/child.txt")[1] == "precious outside", "revert followed descendant link")
			assert(
				vim.fn.readfile(outside .. "/nested/child.txt")[1] == "precious nested",
				"revert followed selected link"
			)
			assert(job and job.error:find("obstruction"), "directory link must be refused")
			assert(checked and not followed, "directory validation followed a link instead of refusing it")
			assert(vim.uv.fs_lstat(target).type == "link", "Discard replaced link")
		end, debug.traceback)
		vim.uv.fs_lstat = lstat
		assert(ok, err)
	end

	local function replacement_unstage(rename, queued, missing)
		setup()
		local f = rename and rename_fixture() or h.make_git_fixture()
		local path = rename and "new [1].txt" or "sample.txt"
		if not rename then
			git(f.root, "add", path)
		end
		local state, repo, node = node_for(f, "staged", path)
		local operand = rename and "sample.txt" or path
		local function replace()
			vim.fn.delete(f.root .. "/" .. operand, "rf")
			vim.fn.mkdir(f.root .. "/" .. operand, "p")
			h.write_file(f.root .. "/" .. operand .. "/child.txt", "unselected staged snapshot\n")
			git(f.root, "add", "-A", "--", operand)
			if missing then
				vim.fn.delete(f.root .. "/" .. operand, "rf")
			end
		end
		if queued then
			delay_mutation(repo, function()
				ops.unstage_file(state, node)
			end, replace)
		else
			confirmed(function()
				ops.unstage_file(state, node)
			end, replace)
		end
		local job = finished(f.root)
		assert(
			git(f.root, "ls-files", "--", operand .. "/child.txt") == operand .. "/child.txt",
			"Unstage removed an unselected child's staged snapshot"
		)
		assert(job and job.error:find("retry"), "stale file Unstage must request refresh and retry")
	end

	local cases = {
		{
			"test_source_control_unstage_refuses_subtree_replacement",
			function()
				for _, rename in ipairs({ false, true }) do
					for _, queued in ipairs({ false, true }) do
						for _, missing in ipairs({ false, true }) do
							replacement_unstage(rename, queued, missing)
						end
					end
				end
			end,
		},
		{
			"test_source_control_svn_discard_refuses_recorded_file_directory",
			function()
				setup()
				local f = svn_directory_fixture()
				h.exec({ "svn", "delete", "dir" }, f.root)
				vim.fn.mkdir(f.root .. "/dir/nested/child.txt", "p")
				local precious = f.root .. "/dir/nested/child.txt/precious.txt"
				h.write_file(precious, "saved unversioned work\n")
				h.write_file(f.root .. "/dir/sibling.txt", "ordinary unversioned sibling\n")
				local state, _, node = node_for(f, "changes", "dir", "svn")
				confirmed(function()
					ops.revert_file(state, node)
				end)
				wait_mutation(f.root, "svn_revert")
				local job = finished(f.root)
				assert(vim.fn.filereadable(precious) == 1, "recursive Discard deleted the recorded file's obstruction")
				assert(job and job.error:find("obstruction"), "recorded file obstruction must be refused")
				vim.fn.delete(f.root .. "/dir/nested/child.txt", "rf")
				state, _, node = node_for(f, "changes", "dir", "svn")
				confirmed(function()
					ops.revert_file(state, node)
				end)
				success(f.root)
				assert(vim.fn.readfile(f.root .. "/dir/nested/child.txt")[1] == "child base")
				assert(vim.fn.readfile(f.root .. "/dir/sibling.txt")[1] == "ordinary unversioned sibling")
			end,
		},
		{
			"test_source_control_stage_isolates_inherited_index",
			function()
				setup()
				local a, b = h.make_git_fixture(), h.make_git_fixture()
				h.write_file(a.file, "A staged work\n")
				git(a.root, "add", "sample.txt")
				h.write_file(b.file, "B saved work\n")
				local saved = vim.env.GIT_INDEX_FILE
				vim.env.GIT_INDEX_FILE = a.root .. "/.git/index"
				local ok, err = xpcall(function()
					local state, _, node = node_for(b, "changes", "sample.txt")
					ops.stage_file(state, node)
					success(b.root)
					assert(vim.env.GIT_INDEX_FILE == a.root .. "/.git/index", "editor environment changed")
				end, debug.traceback)
				vim.env.GIT_INDEX_FILE = saved
				assert(ok, err)
				assert(git(a.root, "show", ":sample.txt") == "A staged work", "Stage changed another checkout's index")
				assert(
					git(b.root, "show", ":sample.txt") == "B saved work",
					"Stage did not update the selected checkout"
				)
			end,
		},
		{
			"test_source_control_unstage_directory_to_file_replacement",
			function()
				directory_to_file("unstage_file")
			end,
		},
		{
			"test_source_control_discard_directory_to_file_replacement",
			function()
				directory_to_file("revert_file")
			end,
		},
		{
			"test_source_control_stage_edits_after_submodule_to_files_conversion",
			function()
				for _, queued in ipairs({ false, true }) do
					setup()
					local f = h.make_git_fixture()
					git(f.root, "restore", "sample.txt")
					-- A gitlink in HEAD, replaced by ordinary stage-zero index entries.
					local head = git(f.root, "rev-parse", "HEAD")
					git(f.root, "update-index", "--add", "--cacheinfo", "160000," .. head .. ",sub")
					git(f.root, "commit", "-m", "gitlink")
					git(f.root, "update-index", "--force-remove", "--", "sub")
					vim.fn.mkdir(f.root .. "/sub/nested", "p")
					h.write_file(f.root .. "/sub/nested/child.txt", "indexed child\n")
					h.write_file(f.root .. "/sub/sibling.txt", "indexed sibling\n")
					git(f.root, "add", "--", "sub")
					h.write_file(f.root .. "/sub/nested/child.txt", "saved child edit\n")
					local state, repo, node = node_for(f, "changes", "sub/nested/child.txt")
					if queued then
						delay_mutation(repo, function()
							ops.stage_file(state, node)
						end, function() end)
					else
						confirmed(function()
							ops.stage_file(state, node)
						end)
					end
					success(f.root)
					assert(git(f.root, "show", ":sub/nested/child.txt") == "saved child edit")
					assert(git(f.root, "show", ":sub/sibling.txt") == "indexed sibling")
					assert(git(f.root, "ls-tree", "HEAD", "sub"):find("160000 commit", 1, true))
				end
			end,
		},
		{
			"test_source_control_svn_discard_directory_preflight_interruptions",
			function()
				for _, mode in ipairs({ "cancel", "timeout", "error", "truncated" }) do
					setup()
					local f = svn_directory_fixture()
					h.exec({ "svn", "delete", "dir" }, f.root)
					local lstat, start = vim.uv.fs_lstat, util.system_start
					local pending, done, terminated, raw, failure, spawned
					---@diagnostic disable-next-line: duplicate-set-field
					vim.uv.fs_lstat = function(path, cb)
						if cb and path == f.root .. "/dir" then
							pending = cb
							return {}
						end
						return lstat(path, cb)
					end
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, cb)
						spawned = spawned or vim.tbl_contains(args, "revert")
						return start(args, opts, function(result, err, output)
							if mode == "truncated" then
								output = output or result
								output.stdout_truncated = true
							end
							cb(result, err, output)
						end)
					end
					local ok, err = xpcall(function()
						local handle = require("lazyvcs.source_control.mutation_start").start(
							{ root = f.root, vcs = "svn" },
							{ "svn", "revert", "--depth", "infinity", "--", "dir" },
							{
								cwd = f.root,
								timeout = mode == "timeout" and 500 or 10000,
								on_terminate = function()
									terminated = true
								end,
							},
							{ svn_discard = { relpath = "dir", recursive = true, kind = "dir" } },
							function(_, command_err, output)
								done, failure, raw = true, command_err, output
							end
						)
						ctx.wait_for(function()
							return pending or done
						end, "SVN preflight did not reach filesystem", 15000)
						if mode ~= "truncated" then
							assert(pending, "filesystem preflight did not run")
							if mode == "cancel" then
								handle:cancel("test")
							end
							if mode == "timeout" then
								ctx.wait_for(function()
									return terminated
								end, "preflight deadline did not expire", 2000)
							end
							assert(not done, "worker released before pending filesystem callback")
							pending(mode == "error" and "EACCES: test refusal" or nil, { type = "directory" })
						end
						ctx.wait_for(function()
							return done
						end, "interrupted SVN preflight did not settle", 15000)
						assert(failure and not spawned, "unsafe SVN preflight reached revert")
						if mode == "cancel" then
							assert(raw.cancelled)
						end
						if mode == "timeout" then
							assert(raw.timed_out)
						end
						assert(vim.fn.isdirectory(f.root .. "/dir") == 0, "interrupted Discard restored directory")
					end, debug.traceback)
					vim.uv.fs_lstat, util.system_start = lstat, start
					assert(ok, err)
				end
			end,
		},
		{
			"test_source_control_stage_allows_saved_file_and_tracked_submodule",
			function()
				setup()
				local f = h.make_git_fixture()
				local state, _, node = node_for(f, "changes", "sample.txt")
				confirmed(function()
					ops.stage_file(state, node)
				end, function()
					h.write_file(f.file, "saved after confirmation\n")
				end)
				success(f.root)
				assert(git(f.root, "show", ":sample.txt") == "saved after confirmation")
				local child = h.make_git_fixture()
				git(child.root, "restore", "sample.txt")
				git(f.root, "-c", "protocol.file.allow=always", "submodule", "add", child.root, "sub")
				git(f.root, "commit", "-am", "submodule")
				h.write_file(f.root .. "/sub/sample.txt", "new submodule revision\n")
				git(
					f.root .. "/sub",
					"-c",
					"user.name=test",
					"-c",
					"user.email=test@example.com",
					"commit",
					"-am",
					"advance"
				)
				state, _, node = node_for(f, "changes", "sub")
				confirmed(function()
					ops.stage_file(state, node)
				end)
				success(f.root)
				assert(git(f.root, "rev-parse", ":sub") == git(f.root .. "/sub", "rev-parse", "HEAD"))
			end,
		},
		{
			"test_source_control_svn_discard_refuses_selected_directory_link",
			function()
				svn_link_obstruction(false)
			end,
		},
		{
			"test_source_control_svn_discard_refuses_descendant_directory_link",
			function()
				svn_link_obstruction(true)
			end,
		},
		{
			"test_source_control_svn_discard_refuses_selected_directory_junction",
			function()
				if vim.fn.has("win32") ~= 1 then
					error({ lazyvcs_skip = "Directory junctions exist only on Windows" })
				end
				svn_link_obstruction(false, true)
			end,
		},
		{
			"test_source_control_svn_discard_refuses_descendant_directory_junction",
			function()
				if vim.fn.has("win32") ~= 1 then
					error({ lazyvcs_skip = "Directory junctions exist only on Windows" })
				end
				svn_link_obstruction(true, true)
			end,
		},
		{
			"test_source_control_unstage_refuses_committed_addition",
			function()
				stale_addition("unstage_file")
			end,
		},
		{
			"test_source_control_discard_refuses_committed_addition",
			function()
				stale_addition("revert_file")
			end,
		},
		{
			"test_source_control_rename_discard_preserves_untracked_source",
			function()
				for _, ignored in ipairs({ false, true }) do
					setup()
					local f = rename_fixture()
					if ignored then
						h.write_file(f.root .. "/.git/info/exclude", "sample.txt\n")
					end
					h.write_file(f.file, "independent content\n")
					local state, _, node = node_for(f, "staged", "new [1].txt")
					local prompt = confirmed(function()
						ops.revert_file(state, node)
					end)
					local job = finished(f.root)
					assert(
						vim.fn.readfile(f.file)[1] == "independent content",
						"Discard overwrote independent rename source"
					)
					assert(job and job.error:find("sample.txt", 1, true), "refusal must name source")
					assert(
						prompt:find("sample.txt", 1, true) and prompt:find("new [1].txt", 1, true),
						"prompt must name both rename paths"
					)
					assert(git(f.root, "diff", "--cached", "--name-status"):find("R100"))
				end
			end,
		},
		{
			"test_source_control_stage_refuses_replacement_directory",
			function()
				for _, queued in ipairs({ false, true }) do
					setup()
					local f = h.make_git_fixture()
					local state, repo, node = node_for(f, "changes", "sample.txt")
					local function replace()
						assert(vim.uv.fs_unlink(f.file))
						vim.fn.mkdir(f.file, "p")
						h.write_file(f.file .. "/secret.txt", "unselected secret\n")
					end
					if queued then
						delay_mutation(repo, function()
							ops.stage_file(state, node)
						end, replace)
					else
						confirmed(function()
							ops.stage_file(state, node)
						end, replace)
					end
					local job = finished(f.root)
					assert(
						git(f.root, "diff", "--cached", "--name-only") == "",
						"file Stage recursed into replacement directory"
					)
					assert(job and job.error:find("directory"), "directory obstruction must be refused")
				end
			end,
		},
		{
			"test_source_control_discard_merge_conflicts_to_head",
			function()
				for _, deleted in ipairs({ false, true }) do
					setup()
					local f = h.make_git_fixture()
					git(f.root, "restore", "sample.txt")
					git(f.root, "branch", "-M", "main")
					git(f.root, "checkout", "-b", "other")
					h.write_file(f.file, "other branch\n")
					git(f.root, "commit", "-am", "other")
					git(f.root, "checkout", "main")
					if deleted then
						git(f.root, "rm", "sample.txt")
					else
						h.write_file(f.file, "head content\n")
					end
					git(f.root, "commit", "-am", "head")
					local merge = vim.system({ "git", "merge", "other" }, { cwd = f.root }):wait()
					assert(merge.code ~= 0, "fixture must conflict")
					local state, _, node = node_for(f, "merge", "sample.txt")
					local prompt = confirmed(function()
						ops.revert_file(state, node)
					end)
					success(f.root)
					assert(git(f.root, "status", "--porcelain") == "", "Discard left conflict unresolved")
					assert(
						prompt:find("HEAD", 1, true) and prompt:find("index", 1, true),
						"conflict prompt must explain restore source and index replacement"
					)
					if deleted then
						assert(vim.fn.filereadable(f.file) == 0)
					else
						assert(vim.fn.readfile(f.file)[1] == "head content")
					end
				end
			end,
		},
		{
			"test_source_control_publish_branch_with_same_named_tag",
			function()
				setup()
				local f = h.make_git_fixture()
				git(f.root, "restore", "sample.txt")
				git(f.root, "branch", "-M", "main")
				git(f.root, "tag", "main")
				local remote = h.tempdir()
				git(remote, "init", "--bare")
				git(f.root, "remote", "add", "origin", remote)
				local state, repo = state_for(f.root)
				action(state, repo, "push")
				success(f.root)
				assert(git(remote, "rev-parse", "refs/heads/main") == git(f.root, "rev-parse", "HEAD"))
				assert(git(f.root, "rev-parse", "--abbrev-ref", "@{upstream}") == "origin/main")
				assert(git(remote, "tag", "--list") == "", "Publish also pushed tag")
			end,
		},
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
						git(f.root, "config", "push.default", "upstream")
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
