return function(ctx)
	local h = ctx.helpers
	local function list(f)
		local value, err, done
		local snapshot = { root = f.root, vcs = "svn", url = h.file_url(f.repo), revision = "1", base = "BASE" }
		require("lazyvcs.backends.compare_svn").list(snapshot, true, function(items, failure)
			value, err, done = items, failure, true
		end)
		ctx.wait_for(function()
			return done
		end, "SVN comparison discovery", 15000)
		return assert(value, err)
	end
	return {
		{
			"test_svn_windows_switched_ignores_stay_in_their_subtree",
			function()
				local common = require("lazyvcs.backends.comparison")
				local command, has, realpath = common.command, vim.fn.has, vim.uv.fs_realpath
				local result, failure, done, boundaries = nil, nil, false, 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(feature)
					return feature == "win32" and 1 or has(feature)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_realpath = function(_, cb)
					cb("ENOENT: missing test config", nil)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(_, _, args, cb)
					if args[1] == "reg" then
						cb(nil, "no test registry value", { code = 1 })
					elseif vim.tbl_contains(args, "-R") then
						cb([[<properties>
<target path="https://example.test/root"><inherited_property name="svn:global-ignores">*.root</inherited_property></target>
<target path="C:\wc\ordinary"><property name="svn:global-ignores">*.ordinary</property></target>
</properties>]])
					else
						boundaries = boundaries + 1
						assert(args[#args] == "C:/wc/sub/nested@", "Windows switch boundary was not normalized")
						cb([[<properties>
<target path="https://example.test/branch"><inherited_property name="svn:global-ignores">*.branch</inherited_property></target>
<target path="C:\wc\sub\nested"><property name="svn:global-ignores">*.local</property></target>
</properties>]])
					end
				end
				local ok, err = pcall(function()
					require("lazyvcs.backends.svn_ignore").load(common.task(), { root = "C:/wc" }, function(value, why)
						result, failure, done = value, why, true
					end, { [[C:\wc\sub\nested]] })
					ctx.wait_for(function()
						return done
					end, "Windows ignore properties did not load")
					local ignored = assert(result, failure)
					assert(boundaries == 1)
					assert(ignored("C:/wc/sub/nested/new/hidden.branch", "hidden.branch"))
					assert(ignored("C:/wc/sub/nested/new/hidden.local", "hidden.local"))
					assert(not ignored("C:/wc/sub/nested/new/visible.root", "visible.root"))
					assert(not ignored("C:/wc/sub/nested-other/visible.branch", "visible.branch"))
					assert(not ignored("C:/wc/outside/visible.branch", "visible.branch"))
					assert(ignored("C:/wc/outside/hidden.root", "hidden.root"))
					assert(ignored("C:/wc/ordinary/new/hidden.ordinary", "hidden.ordinary"))
					assert(not ignored("C:/wc/outside/visible.ordinary", "visible.ordinary"))
				end)
				common.command, vim.fn.has, vim.uv.fs_realpath = command, has, realpath
				assert(ok, err)
			end,
		},
		{
			"test_svn_untracked_discovery_reuses_status_switch_boundaries",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "c++", "trunk", "trunk/sub", "trunk/sub/nested" }, f.root)
				for index = 1, 40 do
					h.write_file(f.root .. "/c++/tracked" .. index, "tracked")
				end
				h.exec({ "svn", "add", "--force", "c++" }, f.root)
				h.exec({ "svn", "propset", "svn:global-ignores", "*.trunk", "trunk/sub" }, f.root)
				h.exec({ "svn", "commit", "-m", "ordinary plus directory and trunk" }, f.root)
				local url = h.file_url(f.repo)
				h.exec({ "svn", "copy", url .. "/trunk", url .. "/branch", "-m", "copy branch" }, f.root)
				local branch = h.tempdir() .. "/branch"
				h.exec({ "svn", "checkout", url .. "/branch", branch }, f.root)
				h.exec({ "svn", "propset", "svn:global-ignores", "*.branch", "sub" }, branch)
				h.exec({ "svn", "commit", "-m", "branch subdirectory ignores" }, branch)
				vim.fn.mkdir(f.root .. "/c++/new", "p")
				h.write_file(f.root .. "/c++/new/visible.txt", "new")
				local util = require("lazyvcs.util")
				local start, infos, inherited_queries = util.system_start, {}, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, ...)
					if args[1] == "svn" then
						if vim.tbl_contains(args, "info") then
							infos[#infos + 1] = args
						elseif
							vim.tbl_contains(args, "propget")
							and vim.tbl_contains(args, "--show-inherited-props")
							and not vim.tbl_contains(args, "-R")
						then
							inherited_queries = inherited_queries + 1
						end
					end
					return start(args, ...)
				end
				local ok, err = pcall(function()
					local paths = {}
					for _, item in ipairs(list(f)) do
						paths[item.relpath] = true
					end
					assert(paths["c++/new/visible.txt"], "untracked descendant missing")
					assert(
						#infos == 0 and inherited_queries == 0,
						"discovery queries: info=" .. #infos .. ", ordinary c++ inherited=" .. inherited_queries
					)
					h.exec({ "svn", "switch", url .. "/branch/sub/nested", "trunk/sub/nested" }, f.root)
					for _, dir in ipairs({ "trunk/sub/nested/new", "trunk/sub/outside" }) do
						vim.fn.mkdir(f.root .. "/" .. dir, "p")
						h.write_file(f.root .. "/" .. dir .. "/visible.txt", "visible")
						h.write_file(f.root .. "/" .. dir .. "/pattern.branch", "branch pattern")
						h.write_file(f.root .. "/" .. dir .. "/pattern.trunk", "trunk pattern")
					end
					paths = {}
					for _, item in ipairs(list(f)) do
						paths[item.relpath] = true
					end
					assert(#infos == 0 and inherited_queries == 1, "switched discovery must query inheritance once")
					assert(
						not paths["trunk/sub/nested/new/pattern.branch"],
						"branch pattern did not apply inside switch"
					)
					assert(paths["trunk/sub/nested/new/pattern.trunk"], "switch retained trunk inheritance")
					assert(paths["trunk/sub/outside/pattern.branch"], "branch pattern escaped switched subtree")
					assert(not paths["trunk/sub/outside/pattern.trunk"], "outside lost trunk inheritance")
					assert(paths["trunk/sub/nested/new/visible.txt"] and paths["trunk/sub/outside/visible.txt"])
					assert(paths["c++/new/visible.txt"], "ordinary directory lost its untracked descendant")
				end)
				util.system_start = start
				assert(ok, err)
			end,
		},
		{
			"test_svn_untracked_traversal_matches_ignore_semantics",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "oracle" }, f.root)
				h.exec({ "svn", "commit", "-m", "create oracle directory" }, f.root)
				h.exec({
					"svn",
					"propset",
					"svn:global-ignores",
					"file[!a].txt\nrange[0-4].txt\npositive[ab].txt\nescaped\\?.txt\n[broken\n?.unicode\ncaret[^a].txt\nbracket[]a].txt\nstar*tail\nquestion?.txt",
					".",
				}, f.root)
				vim.fn.mkdir(f.root .. "/new", "p")
				local names = {
					"filea.txt",
					"fileb.txt",
					"range3.txt",
					"range8.txt",
					"positivea.txt",
					"positivec.txt",
					"escaped?.txt",
					"escapedQ.txt",
					"[broken",
					"é.unicode",
					"x.unicode",
					"careta.txt",
					"caretb.txt",
					"bracket].txt",
					"bracketa.txt",
					"bracketb.txt",
					"startail",
					"starXtail",
					"questionX.txt",
					"questionXX.txt",
				}
				if vim.fn.has("win32") == 1 then
					table.remove(names, 7)
				end
				for _, name in ipairs(names) do
					h.write_file(f.root .. "/oracle/" .. name, "oracle")
					h.write_file(f.root .. "/new/" .. name, "traversal")
				end
				local raw = h.exec({ "svn", "status", "--xml", "--no-ignore", "oracle" }, f.root)
				local expected = {}
				for _, entry in ipairs(require("lazyvcs.backends.xml").parse_status(raw)) do
					if entry.wc_item == "unversioned" then
						expected[#expected + 1] = vim.fs.basename(entry.path)
					end
				end
				local actual = {}
				for _, item in ipairs(list(f)) do
					if item.relpath:sub(1, 4) == "new/" then
						actual[#actual + 1] = item.relpath:sub(5)
					end
				end
				table.sort(actual)
				table.sort(expected)
				assert(
					vim.deep_equal(actual, expected),
					"SVN ignore mismatch: " .. vim.inspect({ actual = actual, expected = expected })
				)
			end,
		},
		{
			"test_svn_switched_subtree_inherits_its_branch_ignores",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "sub", "branch", "branch/sub" }, f.root)
				h.exec({ "svn", "propset", "svn:global-ignores", "*.branch", "branch" }, f.root)
				h.exec({ "svn", "commit", "-m", "branch ignores" }, f.root)
				h.exec({ "svn", "switch", h.file_url(f.repo) .. "/branch/sub", "sub", "--ignore-ancestry" }, f.root)
				vim.fn.mkdir(f.root .. "/sub/new", "p")
				vim.fn.mkdir(f.root .. "/outside", "p")
				h.write_file(f.root .. "/sub/new/hidden.branch", "hidden")
				h.write_file(f.root .. "/sub/new/visible.txt", "visible")
				h.write_file(f.root .. "/outside/visible.branch", "outside")
				local paths = {}
				for _, item in ipairs(list(f)) do
					paths[item.relpath] = true
				end
				assert(not paths["sub/new/hidden.branch"], "switched traversal ignored branch inheritance")
				assert(
					paths["sub/new/visible.txt"] and paths["outside/visible.branch"],
					"switched ignores escaped their subtree"
				)
			end,
		},
	}
end
