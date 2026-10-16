return function(ctx)
	local h, backends = ctx.helpers, require("lazyvcs.backends")
	local function await(start)
		local value, root, err, done
		start(function(a, b, c)
			value, root, err, done = a, b, c, true
		end)
		ctx.wait_for(function()
			return done
		end, "resolution did not complete", 15000)
		return value, root, err
	end
	local function nested(defer_init)
		local f = h.make_git_fixture()
		vim.fn.mkdir(f.root .. "/inner", "p")
		local path = f.root .. "/inner/file.txt"
		h.write_file(path, "outer base")
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "outer base" }, f.root)
		backends.invalidate()
		assert(select(
			2,
			await(function(cb)
				backends.resolve_async(path, cb)
			end)
		) == f.root)
		local function init()
			h.exec({ "git", "init" }, f.root .. "/inner")
			h.write_file(path, "inner base")
			h.exec({ "git", "add", "." }, f.root .. "/inner")
		end
		if not defer_init then
			init()
		end
		return f, path, init
	end
	return {
		{
			"test_svn_revalidation_keeps_nested_git_after_transient_probe_failure",
			function()
				local f = h.make_svn_fixture()
				local inner = vim.fs.normalize(f.root .. "/inner")
				vim.fn.mkdir(inner, "p")
				h.exec({ "git", "init" }, inner)
				local path = inner .. "/file.txt"
				h.write_file(path, "nested")
				backends.invalidate()
				local function resolve(opts)
					return await(function(cb)
						backends.resolve_async(path, cb, opts)
					end)
				end
				assert(select(2, resolve()) == inner)
				local git, svn = require("lazyvcs.backends.git"), require("lazyvcs.backends.svn")
				local probe, svn_probe = git.probe_async, svn.probe_async
				local function fail(reason)
					return function(_, cb)
						local task = require("lazyvcs.backends.task").new(cb)
						vim.schedule(function()
							task:finish(nil, reason)
						end)
						return task
					end
				end
				local ok, err = pcall(function()
					for _, reason in ipairs({
						"Timed out after 30000ms",
						"spawn failed: EAGAIN",
						"fatal: cannot change to '/repo': Permission denied",
					}) do
						git.probe_async = fail(reason)
						local backend, root = resolve({ revalidate = true })
						assert(backend == git and root == inner, "transient Git probe replaced nested ownership")
						assert(select(2, backends.resolve_cached(path)) == inner)
					end
					svn.probe_async = fail("Timed out after 30000ms")
					assert(
						select(2, resolve({ revalidate = true })) == inner,
						"transient failures erased positive cache"
					)
					git.probe_async = fail("fatal: not a git repository")
					assert(
						resolve({ revalidate = true }) == nil,
						"another backend's timeout kept a definitively rejected Git owner"
					)
					assert(backends.resolve_cached(path) == nil, "rejected Git owner remained cached")
					git.probe_async = probe
					assert(select(2, resolve({ revalidate = true })) == inner)
					svn.probe_async = svn_probe
					git.probe_async = fail("fatal: not a git repository")
					assert(
						select(2, resolve({ revalidate = true })) == f.root,
						"definitive failure kept stale nested owner"
					)
					git.probe_async = fail("fatal: not a git repository")
					svn.probe_async = fail("E155007: not a working copy")
					assert(resolve({ revalidate = true }) == nil, "definitive failures retained a stale repository")
					git.probe_async = probe
					svn.probe_async = fail("Timed out after 30000ms")
					local outer, nested_path = nested()
					backends.invalidate(nested_path)
					assert(select(
						2,
						await(function(cb)
							backends.resolve_async(nested_path, cb)
						end)
					) == outer.root .. "/inner")
					assert(vim.uv.fs_rename(outer.root .. "/inner/.git", outer.root .. "/inner/.held-git"))
					assert(select(
						2,
						await(function(cb)
							backends.resolve_async(nested_path, cb, { revalidate = true })
						end)
					) == outer.root, "successful root change was hidden by another backend's timeout")
				end)
				git.probe_async, svn.probe_async = probe, svn_probe
				assert(ok, err)
			end,
		},
		{
			"test_svn_repository_failure_does_not_classify_path_words",
			function()
				for _, name in ipairs({ "timeout-service", "cancel-service", "truncated-service" }) do
					for _, asynchronous in ipairs({ true, false }) do
						local f, parent = h.make_svn_fixture(), h.tempdir()
						vim.fn.mkdir(parent .. "/srv", "p")
						local root = vim.fs.normalize(parent .. "/srv/" .. name)
						assert(vim.uv.fs_rename(f.root, root))
						local path = root .. "/sample.txt"
						local function load()
							if not asynchronous then
								return backends.load_base(path)
							end
							return await(function(cb)
								backends.load_base_async(path, cb)
							end)
						end
						backends.invalidate()
						assert(load())
						vim.fn.delete(root .. "/.svn", "rf")
						assert(load() == nil)
						assert(backends.resolve_cached(path) == nil, "path word blocked invalidation: /srv/" .. name)
					end
				end
			end,
		},
		{
			"test_live_diff_refresh_redetects_nested_repository",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f, path, init = nested(true)
				vim.cmd.edit(vim.fn.fnameescape(path))
				require("lazyvcs").open()
				ctx.wait_for(function()
					return require("lazyvcs.state").current() ~= nil
				end, "diff did not open", 15000)
				assert(require("lazyvcs.state").current().root == f.root)
				init()
				vim.cmd("LazyVCS diff refresh")
				ctx.wait_for(function()
					local s = require("lazyvcs.state").current()
					return s and not s.refresh_job
				end, "diff refresh did not complete", 15000)
				local s = require("lazyvcs.state").current()
				assert(s.root == f.root .. "/inner", "explicit refresh kept outer repository")
				assert(s.base_lines[1] == "inner base")
				local function cache_outer()
					assert(vim.uv.fs_rename(f.root .. "/inner/.git", f.root .. "/inner/.held-git"))
					backends.invalidate(path)
					assert(select(
						2,
						await(function(cb)
							backends.resolve_async(path, cb)
						end)
					) == f.root)
					assert(vim.uv.fs_rename(f.root .. "/inner/.held-git", f.root .. "/inner/.git"))
				end
				cache_outer()
				vim.cmd("LazyVCS signs refresh")
				ctx.wait_for(function()
					return select(2, backends.resolve_cached(path)) == f.root .. "/inner"
				end, "signs refresh retained outer ownership", 15000)
				cache_outer()
				require("lazyvcs").source_control_open({ path = f.root .. "/inner" })
				vim.cmd("LazyVCS sidebar refresh")
				ctx.wait_for(function()
					return select(2, backends.resolve_cached(path)) == f.root .. "/inner"
				end, "sidebar refresh retained outer ownership", 15000)
				require("lazyvcs.source_control.native").close()
			end,
		},
		{
			"test_core_resolution_revalidates_bufenter_without_cursor_probes",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = true },
					blame = { mode = "inline", persist = false },
				})
				local f, path, init = nested(true)
				init()
				h.write_file(path, "one\ntwo\nthree\nfour\nfive\nsix")
				h.exec({ "git", "add", "." }, f.root .. "/inner")
				vim.cmd.edit(vim.fn.fnameescape(path))
				-- Positive cached lookups remain valid after the revalidation interval.
				vim.wait(5100, function()
					return false
				end, 50)
				assert(select(2, backends.resolve_cached(path)) == f.root, "positive cache expired on elapsed time")
				vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0 })
				ctx.wait_for(function()
					return select(2, backends.resolve_cached(path)) == f.root .. "/inner"
				end, "BufEnter kept stale repository ownership", 15000)
				local blame, signs = require("lazyvcs.blame"), require("lazyvcs.signs")
				blame.blame()
				assert(blame._test_inline_enabled(), "inline blame was not enabled")
				signs.refresh(0, true)
				ctx.wait_for(function()
					local view = blame._test_inline_state().views[vim.api.nvim_get_current_buf()]
					local state = signs._test_state().buffers[vim.api.nvim_get_current_buf()]
					return view and view.entries and state and state.loaded
				end, "inline blame and native signs did not load", 15000)
				local util = require("lazyvcs.util")
				local start, count = util.system_start, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(...)
					count = count + 1
					return start(...)
				end
				local ok, err = pcall(function()
					for line = 2, 6 do
						vim.api.nvim_win_set_cursor(0, { line, 0 })
						backends.resolve_cached(path)
						await(function(cb)
							backends.resolve_async(path, cb)
						end)
						vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
					end
					local config = require("lazyvcs.config").get()
					vim.wait(math.max(config.blame.delay_ms, config.signs.debounce_ms) + 200, function()
						return false
					end, 10)
				end)
				util.system_start = start
				assert(ok, err)
				assert(count == 0, "cached cursor path started a process")
			end,
		},
		{
			"test_core_failed_repository_read_invalidates_resolution",
			function()
				local f = h.make_git_fixture()
				backends.invalidate()
				assert(await(function(cb)
					backends.load_base_async(f.file, cb)
				end))
				vim.fn.delete(f.root .. "/.git", "rf")
				local value = await(function(cb)
					backends.load_base_async(f.file, cb)
				end)
				assert(value == nil)
				assert(backends.resolve_cached(f.file) == nil, "deleted repository remained cached")
				f = h.make_git_fixture()
				assert(await(function(cb)
					backends.load_base_async(f.file, cb)
				end))
				local git, util = require("lazyvcs.backends.git"), require("lazyvcs.util")
				local load, calls, failure = git.load_base_async, 0, "fatal: not a git repository"
				---@diagnostic disable-next-line: duplicate-set-field
				git.load_base_async = function(path, cb, opts)
					calls = calls + 1
					if calls > 1 then
						return load(path, cb, opts)
					end
					vim.schedule(util.safe_callback(function()
						cb(nil, failure)
					end))
					return {}
				end
				local ok, err = pcall(function()
					assert(await(function(cb)
						backends.load_base_async(f.file, cb)
					end))
					assert(calls == 2, "repository read did not retry exactly once")
					for _, reason in ipairs({ "Cancelled", "Timed out after 1ms", "Command output was truncated" }) do
						calls, failure = 0, reason
						assert(await(function(cb)
							backends.load_base_async(f.file, cb)
						end) == nil)
						assert(
							calls == 1 and backends.resolve_cached(f.file),
							"bounded command failure invalidated or retried resolution"
						)
					end
				end)
				git.load_base_async = load
				assert(ok, err)
			end,
		},
		{
			"test_svn_resolution_finds_working_copy_above_unversioned_directory",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/new/deep", "p")
				local path = f.root .. "/new/deep/file.txt"
				h.write_file(path, "new")
				local svn = require("lazyvcs.backends.svn")
				assert(svn.root(path) == f.root, "unversioned descendant hid working copy")
				local info = await(function(cb)
					svn.probe_async(path, cb)
				end)
				assert(info and info.root == f.root)
				backends.invalidate()
				local backend, root = await(function(cb)
					backends.resolve_async(f.root .. "/new/deep", cb)
				end)
				assert(backend and backend.name == "svn" and root == f.root)
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual" },
				})
				local native = require("lazyvcs.source_control.native")
				local ok, failure = pcall(function()
					require("lazyvcs").source_control_open({ path = f.root .. "/new/deep" })
					local state = assert(native._state())
					ctx.wait_for(function()
						return not state.lazyvcs_discovering and state.lazyvcs_repo_specs ~= nil
					end, "unversioned-directory sidebar discovery", 15000)
					assert(
						state.lazyvcs_repo_specs[1] and state.lazyvcs_repo_specs[1].root == f.root,
						"sidebar missed enclosing SVN working copy"
					)
				end)
				pcall(native.close)
				assert(ok, failure)
				local inner = f.root .. "/new/deep/inner"
				h.exec({ "svn", "checkout", h.file_url(f.repo), inner }, f.root)
				assert(svn.root(inner .. "/sample.txt") == inner, "ancestor search skipped nested working copy")
				assert(await(function(cb)
					svn.probe_async(inner .. "/sample.txt", cb)
				end).root == inner)
				local process, util = require("lazyvcs.backends.process"), require("lazyvcs.util")
				local probe, calls = process.root, 0
				---@diagnostic disable-next-line: duplicate-set-field
				process.root = function(_, _, cb)
					calls = calls + 1
					vim.schedule(util.safe_callback(function()
						cb(nil, "permission denied", { code = 1 })
					end))
					return {}
				end
				ok, failure = pcall(function()
					local missing = await(function(cb)
						svn.probe_async(path, cb)
					end)
					assert(missing == nil and calls == 1, "SVN ancestor probing masked an unrelated error")
				end)
				process.root = probe
				assert(ok, failure)
				local called = false
				local task = svn.probe_async(path, function()
					called = true
				end)
				task:kill()
				vim.wait(100, function()
					return false
				end, 10)
				assert(not called, "cancelled SVN root probe delivered a result")
			end,
		},
	}
end
