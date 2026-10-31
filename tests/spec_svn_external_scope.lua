return function(ctx)
	local h = ctx.helpers
	local function await(start)
		local value, failure, finished
		start(function(result, err)
			value, failure, finished = result, err, true
		end)
		ctx.wait_for(function()
			return finished
		end, "external discovery did not finish", 15000)
		return value, failure
	end
	local function fixture()
		local parent, external = h.make_svn_fixture(), h.make_svn_fixture()
		h.exec({ "svn", "propset", "svn:global-ignores", "*.parent", parent.root }, parent.root)
		h.exec({ "svn", "propset", "svn:global-ignores", "*.external", external.root }, external.root)
		h.exec({ "svn", "commit", "-m", "external policy", external.root }, external.root)
		h.exec({ "svn", "propset", "svn:externals", h.file_url(external.repo) .. " ext", parent.root }, parent.root)
		h.exec({ "svn", "commit", "-m", "parent policy", parent.root }, parent.root)
		vim.fn.mkdir(parent.root .. "/own", "p")
		h.write_file(parent.root .. "/own/visible.txt", "parent content\n")
		h.write_file(parent.root .. "/own/hidden.parent", "ignored parent\n")
		return parent, external
	end
	local function status(f, ignore_externals)
		local args = { "svn", "status", "--xml" }
		if ignore_externals then
			args[#args + 1] = "--ignore-externals"
		end
		args[#args + 1] = f.root .. "@"
		return require("lazyvcs.backends.xml").parse_status(h.exec(args, f.root))
	end
	local function has_external(entries)
		for _, entry in ipairs(entries) do
			if entry.wc_item == "external" then
				return true
			end
		end
		return false
	end
	local function public_paths(f, comparison)
		local rows, err = await(function(done)
			if comparison then
				local revision = vim.trim(h.exec({ "svn", "info", "--show-item", "revision", f.root }, f.root))
				require("lazyvcs.backends.compare_svn").list(
					{ root = f.root, vcs = "svn", url = h.file_url(f.repo), revision = revision },
					true,
					done
				)
			else
				require("lazyvcs.backends").changed_files_async(f.file, done)
			end
		end)
		assert(rows, err)
		local paths = {}
		for _, row in ipairs(rows) do
			paths[row.relpath or row.path] = true
		end
		assert(paths["own/visible.txt"], "parent file disappeared: " .. vim.inspect(paths))
		assert(not paths["own/hidden.parent"], "parent global ignore was lost")
		return paths
	end
	return {
		{
			"test_svn_external_obstruction_keeps_parent_file_discovery",
			function()
				local f = fixture()
				assert(not has_external(status(f, true)), "never-populated fixture unexpectedly has X")
				public_paths(f, true)
				public_paths(f, false)
				h.exec({ "svn", "update", f.root }, f.root)
				assert(has_external(status(f, true)), "populated external has no X row")
				h.write_file(f.root .. "/ext/visible.parent", "external keeps parent pattern\n")
				h.write_file(f.root .. "/ext/hidden.external", "external policy hides this\n")
				public_paths(f, true)
				local populated = public_paths(f, false)
				assert(populated["ext/visible.parent"] and not populated["ext/hidden.external"])
				vim.fn.delete(f.root .. "/ext", "rf")
				assert(not has_external(status(f, true)), "removed external unexpectedly has X")
				public_paths(f, true)
				public_paths(f, false)
				vim.fn.mkdir(f.root .. "/ext", "p")
				h.write_file(f.root .. "/ext/ordinary.txt", "ordinary obstruction\n")
				h.write_file(f.root .. "/ext/hidden.parent", "parent policy applies here\n")
				assert(has_external(status(f, true)), "obstruction must retain native X classification")
				assert(not vim.uv.fs_lstat(f.root .. "/ext/.svn"), "obstruction retained external metadata")
				public_paths(f, true)
				local obstructed = public_paths(f, false)
				assert(obstructed["ext/ordinary.txt"] and not obstructed["ext/hidden.parent"])
				assert(h.exec({ "svn", "status", "--xml", f.root }, f.root):find('item="external"', 1, true))
				assert(vim.fn.readfile(f.root .. "/ext/ordinary.txt")[1] == "ordinary obstruction")
			end,
		},
		{
			"test_svn_external_link_obstruction_never_reads_target_policy",
			function()
				local f, external = fixture()
				h.exec({ "svn", "update", f.root }, f.root)
				vim.fn.delete(f.root .. "/ext", "rf")
				assert(
					vim.uv.fs_symlink(
						external.root,
						f.root .. "/ext",
						vim.fn.has("win32") == 1 and { junction = true } or nil
					)
				)
				assert(vim.uv.fs_lstat(f.root .. "/ext").type == "link")
				assert(vim.uv.fs_stat(f.root .. "/ext/.svn").type == "directory")
				assert(has_external(status(f, true)), "link obstruction must retain native X classification")
				local common, util = require("lazyvcs.backends.comparison"), require("lazyvcs.util")
				local run, queries = common.command, 0
				local target = util.svn_target(f.root .. "/ext")
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(task, repo, args, done, opts)
					if args[#args] == target then
						queries = queries + 1
					end
					return run(task, repo, args, done, opts)
				end
				local ok, err = pcall(function()
					public_paths(f, true)
					local paths = public_paths(f, false)
					assert(not paths["ext/sample.txt"], "link obstruction was traversed: " .. vim.inspect(paths))
					assert(queries == 0, "obstruction loaded another working copy's ignore policy")
				end)
				common.command = run
				assert(ok, err)
			end,
		},
		{
			"test_svn_external_classification_errors_remain_errors",
			function()
				local f = fixture()
				h.exec({ "svn", "update", f.root }, f.root)
				local entries = status(f, true)
				local common, stat = require("lazyvcs.backends.comparison"), vim.uv.fs_lstat
				for _, path in ipairs({ f.root .. "/ext", f.root .. "/ext/.svn" }) do
					local intercepted = false
					vim.uv.fs_lstat = function(target, callback)
						if target == path then
							intercepted = true
							vim.schedule(function()
								callback("EACCES: external classification denied")
							end)
							return {}
						end
						return stat(target, callback)
					end
					local ok, err = pcall(function()
						local value, why = await(function(done)
							require("lazyvcs.backends.svn_untracked").expand(
								common.task(),
								{ root = f.root },
								entries,
								done
							)
						end)
						assert(
							intercepted and not value and why == "EACCES: external classification denied",
							tostring(why)
						)
					end)
					vim.uv.fs_lstat = stat
					assert(ok, err)
				end
			end,
		},
		{
			"test_svn_external_scope_keeps_property_failures_and_cancellation",
			function()
				local f = fixture()
				h.exec({ "svn", "update", f.root }, f.root)
				local entries = status(f, true)
				local common = require("lazyvcs.backends.comparison")
				local run = common.command
				local target = require("lazyvcs.util").svn_target(f.root .. "/ext")
				for _, failure in ipairs({
					"SVN property access denied",
					"Comparison output was truncated; narrow the comparison",
				}) do
					local intercepted = false
					---@diagnostic disable-next-line: duplicate-set-field
					common.command = function(task, repo, args, done, opts)
						if args[#args] == target then
							intercepted = true
							return done(nil, failure)
						end
						return run(task, repo, args, done, opts)
					end
					local ok, err = pcall(function()
						local value, why = await(function(done)
							require("lazyvcs.backends.svn_untracked").expand(
								common.task(),
								{ root = f.root },
								entries,
								done
							)
						end)
						assert(intercepted and not value and why == failure, tostring(why))
					end)
					common.command = run
					assert(ok, err)
				end
				local stat = vim.uv.fs_lstat
				local held, finished, root_queries = nil, false, 0
				vim.uv.fs_lstat = function(path, callback)
					if path == f.root .. "/ext/.svn" then
						held = callback
						return {}
					end
					return stat(path, callback)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(task, repo, args, done, opts)
					if args[#args] == target then
						root_queries = root_queries + 1
					end
					return run(task, repo, args, done, opts)
				end
				local task = common.task()
				local ok, err = pcall(function()
					require("lazyvcs.backends.svn_untracked").expand(task, { root = f.root }, entries, function()
						finished = true
					end)
					ctx.wait_for(function()
						return held ~= nil
					end, "external classification did not start")
					task:kill()
					assert(held)(nil, { type = "directory" })
					vim.wait(30)
					assert(not finished and root_queries == 0, "cancelled classification continued")
				end)
				vim.uv.fs_lstat, common.command = stat, run
				task:kill()
				assert(ok, err)
			end,
		},
	}
end
