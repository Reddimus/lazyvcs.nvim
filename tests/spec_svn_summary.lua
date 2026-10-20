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
