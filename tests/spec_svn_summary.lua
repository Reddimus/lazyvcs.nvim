return function(ctx)
	local h = ctx.helpers
	local function load(f, revision, base)
		local common = require("lazyvcs.backends.comparison")
		local original, requests = common.command, 0
		---@diagnostic disable-next-line: duplicate-set-field
		common.command = function(task, repo, args, callback, opts)
			if vim.tbl_contains(args, "--summarize") and args[#args] == f.root .. "@" then
				requests = requests + 1
				vim.schedule(function()
					if task:is_active() then
						callback(nil, "svn: E145001: Can only get the pristine contents of files")
					end
				end)
				return
			end
			return original(task, repo, args, callback, opts)
		end
		local ok, value = xpcall(function()
			local done, result, failure
			require("lazyvcs.backends.compare_svn").list(
				{
					root = f.root,
					url = base or h.file_url(f.repo),
					revision = revision,
				},
				false,
				function(items, err)
					result, failure, done = items, err, true
				end
			)
			ctx.wait_for(function()
				return done
			end, "SVN replacement summary", 15000)
			assert(result, failure)
			local paths = {}
			for _, item in ipairs(result) do
				paths[item.relpath] = item
			end
			return paths
		end, debug.traceback)
		common.command = original
		assert(ok, value)
		assert(requests == 1, "fallback retried the failing working-copy summary")
		return value
	end
	return {
		{
			"test_svn_summary_fallback_bounds_paths_and_combined_output",
			function()
				for _, scenario in ipairs({
					{ count = 10001, root = "/fixture", limit = "path limit" },
					{ count = 5000, root = "/" .. string.rep("r", 900), limit = "output limit" },
				}) do
					local completed, result, failure, requests = false, nil, nil, 0
					local task = require("lazyvcs.backends.task").new(function(value, err)
						result, failure, completed = value, err, true
					end)
					local stat = vim.uv.fs_lstat
					---@diagnostic disable-next-line: duplicate-set-field
					vim.uv.fs_lstat = function(_, callback)
						vim.schedule(function()
							callback(nil, { type = "file", size = 1 })
						end)
					end
					local ok, err = xpcall(function()
						local paths = {}
						for index = 1, scenario.count do
							paths[index] = ('<path kind="file" item="added" props="none">file:///fixture/p%d</path>'):format(
								index
							)
						end
						require("lazyvcs.backends.svn_summary").load(
							task,
							{ root = scenario.root, url = "file:///fixture", revision = "1" },
							function(_, _, args, callback)
								requests = requests + 1
								callback(
									args[1] == "diff" and "<diff><paths>" .. table.concat(paths) .. "</paths></diff>"
										or "<status/>"
								)
							end,
							function(value, why)
								task:finish(value, why)
							end,
							function(value)
								return value
							end
						)
						ctx.wait_for(function()
							return completed
						end, "bounded summary", 15000)
						assert(result == nil and failure and failure:find(scenario.limit, 1, true), tostring(failure))
						assert(requests <= 2, "limit check dispatched more repository commands")
					end, debug.traceback)
					vim.uv.fs_lstat = stat
					task:kill()
					assert(ok, err)
				end
			end,
		},
		{
			"test_svn_summary_fallback_cancellation_ignores_late_transport_completion",
			function()
				local calls, stopped, transport = 0, 0, nil
				local task = require("lazyvcs.backends.task").new(function()
					calls = calls + 1
				end)
				require("lazyvcs.backends.svn_summary").load(
					task,
					{ root = "/fixture", url = "file:///fixture", revision = "1" },
					function(owner, _, _, callback)
						transport = callback
						owner:add({
							cancel = function()
								stopped = stopped + 1
							end,
						})
					end,
					function(value, err)
						task:finish(value, err)
					end,
					function(value)
						return value
					end
				)
				assert(transport)
				task:kill()
				transport("<diff><paths/></diff>")
				vim.wait(20, function()
					return false
				end, 5)
				assert(calls == 0 and stopped == 1)
			end,
		},
		{
			"test_svn_summary_owner_deadline_cancels_stalled_jobs_once",
			function()
				local task, calls, stopped, failure
				calls, stopped = 0, 0
				task = require("lazyvcs.backends.task").new(function(_, err)
					calls = calls + 1
					failure = err
				end)
				task:add({
					cancel = function()
						stopped = stopped + 1
						task:finish("late")
					end,
				})
				task:set_deadline(10, "summary deadline")
				ctx.wait_for(function()
					return calls == 1
				end, "owner deadline", 1000)
				assert(failure == "summary deadline" and stopped == 1 and not task:is_active())
				assert(not task:finish("later"))
				local finished = require("lazyvcs.backends.task").new(function()
					calls = calls + 1
				end)
				finished:set_deadline(10, "late timeout")
				finished:finish("done")
				local cancelled = require("lazyvcs.backends.task").new(function()
					calls = calls + 1
				end)
				cancelled:set_deadline(10, "late timeout")
				cancelled:kill()
				vim.wait(40, function()
					return false
				end, 10)
				assert(calls == 2, "a finished or cancelled owner delivered a late deadline")
			end,
		},
		{
			"test_svn_summary_fallback_ignores_edited_external_working_copies",
			function()
				local f, external = h.make_svn_fixture(), h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:externals", h.file_url(external.repo) .. "@1 ext", f.root }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.write_file(f.root .. "/ext/sample.txt", "external edit\n")
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "rm", "sample.txt" }, f.root)
				h.exec({ "svn", "mkdir", "sample.txt" }, f.root)
				local paths = load(f, "1")
				assert(paths["sample.txt"] and paths["sample.txt"].status == "R")
				assert(not paths["ext/sample.txt"], "external edits leaked into parent comparison")
			end,
		},
		{
			"test_svn_summary_fallback_deleted_children_do_not_claim_property_edits",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "node" }, f.root)
				h.write_file(f.root .. "/node/child", "before\n")
				h.exec({ "svn", "add", "node/child" }, f.root)
				h.exec({ "svn", "commit", "-m", "directory base" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.exec({ "svn", "rm", "node" }, f.root)
				h.write_file(f.root .. "/node", "after\n")
				h.exec({ "svn", "add", "node" }, f.root)
				local paths = load(f, "2")
				assert(paths.node and paths.node.status == "R")
				assert(paths["node/child"] and paths["node/child"].status == "D")
				assert(not paths["node/child"].properties, "deleted child incorrectly requests a working property diff")
			end,
		},
		{
			"test_svn_summary_fallback_reconciles_pinned_base_and_net_clean_working_changes",
			function()
				local f = h.make_svn_fixture()
				h.write_file(f.file, "committed later\n")
				h.write_file(f.root .. "/gone.txt", "gone\n")
				h.write_file(f.root .. "/node", "before\n")
				h.exec({ "svn", "add", "gone.txt", "node" }, f.root)
				h.exec({ "svn", "commit", "-m", "later base" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.write_file(f.file, "one\ntwo\nthree\n")
				h.exec({ "svn", "rm", "gone.txt", "node" }, f.root)
				h.exec({ "svn", "mkdir", "node" }, f.root)
				h.write_file(f.root .. "/node/child", "new child\n")
				h.exec({ "svn", "add", "node/child" }, f.root)
				local paths = load(f, "1")
				assert(not paths["sample.txt"], "BASE and local text changes did not cancel")
				assert(not paths["gone.txt"], "a later addition deleted locally has no net change")
				assert(paths.node and paths.node.status == "A" and paths.node.kind == "dir")
				assert(paths["node/child"] and paths["node/child"].status == "A")
			end,
		},
		{
			"test_svn_summary_fallback_respects_an_alternate_repository_base",
			function()
				local f = h.make_svn_fixture()
				local url = h.file_url(f.repo)
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "copy", url .. "@1", url .. "/branch", "-m", "branch" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.exec({ "svn", "rm", "sample.txt" }, f.root)
				h.exec({ "svn", "mkdir", "sample.txt" }, f.root)
				h.write_file(f.root .. "/sample.txt/child", "new child\n")
				h.exec({ "svn", "add", "sample.txt/child" }, f.root)
				local paths = load(f, "2", url .. "/branch")
				assert(paths["sample.txt"] and paths["sample.txt"].status == "R")
				assert(paths["sample.txt"].kind_before == "file" and paths["sample.txt"].kind_after == "dir")
				assert(paths["sample.txt/child"] and paths["sample.txt/child"].status == "A")
				assert(paths.branch and paths.branch.status == "A")
				assert(paths["branch/sample.txt"] and paths["branch/sample.txt"].status == "A")
			end,
		},
	}
end
