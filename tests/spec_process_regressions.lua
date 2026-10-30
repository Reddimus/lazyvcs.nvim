return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local ai = require("lazyvcs.source_control.ai")
	local function guarded(fn)
		return function()
			local system, start, rtp = vim.system, util.system_start, vim.o.runtimepath
			local chat, lazy = package.loaded.CopilotChat, package.loaded["lazy.core.config"]
			local ok, err = xpcall(fn, debug.traceback)
			vim.system, util.system_start, vim.o.runtimepath = system, start, rtp
			package.loaded.CopilotChat, package.loaded["lazy.core.config"] = chat, lazy
			ai._test_reset_privacy()
			assert(ok, err)
		end
	end
	local function setup(context)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false, remote_refresh = "manual" },
			ai = { commit_message = { provider = "codex", confirm_privacy = false, context = context } },
		})
		ai._test_set_executable_checker(function()
			return true
		end)
	end
	local function with_environment(overrides, fn)
		local saved = {}
		for key, value in pairs(overrides) do
			saved[key], vim.env[key] = vim.env[key], value or nil
		end
		local ok, err = xpcall(fn, debug.traceback)
		for key in pairs(overrides) do
			vim.env[key] = saved[key]
		end
		assert(ok, err)
	end
	local function dotfiles_fixture()
		local source, parent = h.make_git_fixture(), h.tempdir()
		local root, git_dir = parent .. "/home", parent .. "/dotfiles.git"
		vim.fn.mkdir(root .. "/config", "p")
		h.exec({ "git", "clone", "--bare", source.root, git_dir }, parent)
		h.exec({ "git", "--git-dir=" .. git_dir, "--work-tree=" .. root, "read-tree", "HEAD" }, parent)
		h.write_file(root .. "/sample.txt", "dotfiles work\n")
		local file = root .. "/config/settings.txt"
		h.write_file(file, "settings\n")
		return { root = root, git_dir = git_dir, file = file, source = source, parent = parent }
	end
	return {
		{
			"test_core_git_work_tree_environment_selection",
			guarded(function()
				local f = dotfiles_fixture()
				local raw_tree, cwd = f.root .. "/config/..", f.root .. "/config"
				local canonical, has = util.canonical_path, vim.fn.has
				local resolutions = {}
				---@type table<string, string>[]
				local child_envs = {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.canonical_path = function(path)
					if path then
						resolutions[path] = (resolutions[path] or 0) + 1
					end
					return canonical(path)
				end
				vim.system = function(_, opts)
					local env = opts.env
					if vim.islist(env) then
						env = {}
						for _, entry in ipairs(opts.env) do
							local key, value = entry:match("^([^=]+)=(.*)$")
							env[key] = value
						end
					end
					child_envs[#child_envs + 1] = env
					return {
						wait = function()
							return { code = 0, stdout = "", stderr = "" }
						end,
					}
				end
				local ok, err = xpcall(function()
					with_environment({ GIT_DIR = f.git_dir, GIT_WORK_TREE = raw_tree }, function()
						local function probe(opts, keep)
							local started = #child_envs
							util.system_result({ "git", "status" }, opts)
							assert(#child_envs == started + 1, "git command did not start exactly once")
							local env = child_envs[#child_envs]
							assert((env.GIT_DIR ~= nil) == keep, "incorrect GIT_DIR selection")
							assert((env.GIT_WORK_TREE ~= nil) == keep, "incorrect GIT_WORK_TREE selection")
						end
						probe({ cwd = cwd }, true)
						probe({ cwd = cwd, env = { CUSTOM = "changed" } }, true)
						assert(resolutions[raw_tree] == 1, "work tree was canonicalized per command")
						probe({ cwd = cwd, env = { GIT_DIR = f.git_dir .. "/." } }, true)
						assert(resolutions[raw_tree] == 2, "GIT_DIR change did not invalidate the cache")
						probe({ cwd = cwd, env = { GIT_WORK_TREE = f.parent } }, true)
						assert(resolutions[f.parent] == 1, "GIT_WORK_TREE change did not invalidate the cache")
						probe({ cwd = cwd }, true)
						probe({}, false)
						probe({ cwd = "" }, false)
						probe({ cwd = cwd, clear_env = true }, false)
						probe({ cwd = cwd, env = { GIT_WORK_TREE = "" } }, false)
						probe({ cwd = cwd, env = { GIT_DIR = "" } }, false)
						with_environment({ GIT_WORK_TREE = false }, function()
							probe({ cwd = cwd }, false)
						end)
						with_environment({ GIT_DIR = false }, function()
							probe({ cwd = cwd }, false)
						end)
						vim.fn.has = function(name)
							return name == "win32" and 1 or has(name)
						end
						probe({ cwd = cwd:upper() }, true)
					end)
				end, debug.traceback)
				util.canonical_path, vim.fn.has = canonical, has
				assert(ok, err)
			end),
		},
		{
			"test_core_git_dotfiles_environment_discovery_and_status",
			guarded(function()
				local f = dotfiles_fixture()
				h.write_file(f.source.file, "poisoned inherited index\n")
				h.exec({ "git", "add", "sample.txt" }, f.source.root)
				with_environment({
					GIT_DIR = f.git_dir,
					GIT_WORK_TREE = f.root,
					GIT_INDEX_FILE = f.source.root .. "/.git/index",
					GIT_COMMON_DIR = f.parent .. "/absent",
				}, function()
					local git = require("lazyvcs.backends.git")
					local root, err = git.root(f.file)
					assert(root == f.root, "dotfiles root resolution failed: " .. tostring(err))
					local done, info, failure
					git.probe_async(f.file, function(value, e)
						done, info, failure = true, value, e
					end)
					wait(function()
						return done
					end)
					assert(info and info.root == f.root, failure or "asynchronous dotfiles discovery failed")
					local result = assert(util.system({ "git", "status", "--porcelain", "--", "sample.txt" }, {
						cwd = root,
					}))
					assert(result.stdout == " M sample.txt\n", "dotfiles status used the inherited index")
					done, info, failure = false, nil, nil
					util.system_start({ "git", "status", "--porcelain", "--", "settings.txt" }, {
						cwd = root .. "/config",
					}, function(value, e)
						done, info, failure = true, value, e
					end)
					wait(function()
						return done
					end)
					assert(info, failure)
					assert(info.stdout == "?? config/settings.txt\n", "nested dotfiles status failed")
				end)
			end),
		},
		{
			"test_core_git_dotfiles_environment_nested_repository",
			guarded(function()
				local f = dotfiles_fixture()
				local nested = f.root .. "/projects/nested"
				vim.fn.mkdir(nested .. "/src", "p")
				h.exec({ "git", "init" }, nested)
				h.exec({ "git", "config", "user.name", "lazyvcs-test" }, nested)
				h.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, nested)
				local nested_file = nested .. "/src/nested.txt"
				h.write_file(nested_file, "nested\n")
				h.exec({ "git", "add", "src/nested.txt" }, nested)
				h.exec({ "git", "commit", "-m", "nested" }, nested)
				h.write_file(nested_file, "nested change\n")
				with_environment({ GIT_DIR = f.git_dir, GIT_WORK_TREE = f.root }, function()
					local git = require("lazyvcs.backends.git")
					local function changes(path)
						local done, items, failure
						git.changed_files_async(path, function(value, e)
							done, items, failure = true, value, e
						end)
						wait(function()
							return done
						end, "status did not settle", 15000)
						assert(items, failure)
						local statuses = {}
						for _, item in ipairs(items) do
							statuses[item.path] = item.status
						end
						return statuses
					end
					local root, err = git.root(nested_file)
					assert(root == nested, "nested repository resolved to " .. tostring(root or err))
					local nested_changes = changes(nested_file)
					assert(nested_changes["src/nested.txt"] == "M", "nested status did not use the nested repository")
					assert(not nested_changes["sample.txt"], "nested status listed dotfiles changes")
					local statuses = {}
					for _, item in ipairs(assert(git.changed_files(nested))) do
						statuses[item.path] = item.status
					end
					assert(statuses["src/nested.txt"] == "M", "synchronous nested status used another repository")
					for _, path in ipairs({ f.root .. "/sample.txt", f.file }) do
						root, err = git.root(path)
						assert(root == f.root, "dotfiles file resolved to " .. tostring(root or err))
					end
					local dotfiles_changes = changes(f.root .. "/sample.txt")
					assert(dotfiles_changes["sample.txt"] == "M", "dotfiles status lost the dotfiles repository")
					assert(
						not dotfiles_changes["projects/nested/src/nested.txt"],
						"dotfiles status entered the nested repository"
					)
				end)
			end),
		},
		{
			"test_core_git_work_tree_nested_entry_cache",
			guarded(function()
				local f = dotfiles_fixture()
				local nested = f.root .. "/config/nested"
				local marker, deep = nested .. "/.git", nested .. "/deep"
				vim.fn.mkdir(deep, "p")
				-- A .git file, as used by linked worktrees and submodules, also marks a repository.
				h.write_file(marker, "gitdir: " .. f.parent .. "/absent\n")
				local fs_stat, now = vim.uv.fs_stat, vim.uv.now
				local stats, clock, kept = {}, now(), nil
				local function checked(suffix)
					local total = 0
					for path, count in pairs(stats) do
						if path:lower():sub(-#suffix) == suffix:lower() then
							total = total + count
						end
					end
					return total
				end
				vim.system = function(_, opts)
					local env = opts.env
					if vim.islist(env) then
						env = {}
						for _, entry in ipairs(opts.env) do
							local key, value = entry:match("^([^=]+)=(.*)$")
							env[key] = value
						end
					end
					kept = env.GIT_DIR ~= nil and env.GIT_WORK_TREE ~= nil
					return {
						wait = function()
							return { code = 0, stdout = "", stderr = "" }
						end,
					}
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_stat = function(path, ...)
					if type(path) == "string" and path:sub(-5) == "/.git" then
						stats[path] = (stats[path] or 0) + 1
					end
					return fs_stat(path, ...)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.now = function()
					return clock
				end
				local ok, err = xpcall(function()
					with_environment({ GIT_DIR = f.git_dir, GIT_WORK_TREE = f.root }, function()
						local function probe(cwd)
							kept = nil
							util.system_result({ "git", "status" }, { cwd = cwd })
							return kept
						end
						assert(probe(deep) == false, "a closer .git file kept the inherited repository")
						assert(checked("/nested/deep/.git") == 1 and checked("/config/nested/.git") == 1)
						assert(
							probe(f.root .. "/config") == true,
							"dotfiles subdirectory lost the inherited repository"
						)
						assert(probe(f.root) == true, "dotfiles root lost the inherited repository")
						assert(checked("/home/.git") == 0, "walk checked the work tree root")
						assert(probe(deep) == false)
						assert(checked("/nested/deep/.git") == 1 and checked("/config/nested/.git") == 1, "no cache")
						assert(vim.uv.fs_unlink(marker))
						assert(probe(deep) == false, "cached entry expired early")
						clock = clock + 5000
						assert(probe(deep) == true, "removed nested repository stayed cached")
						h.write_file(marker, "gitdir: " .. f.parent .. "/absent\n")
						require("lazyvcs.backends").invalidate()
						assert(probe(deep) == false, "backend invalidation kept a stale entry")
					end)
				end, debug.traceback)
				vim.uv.fs_stat, vim.uv.now = fs_stat, now
				assert(ok, err)
			end),
		},
		{
			"test_core_git_dotfiles_environment_unrelated_repository",
			guarded(function()
				local f = dotfiles_fixture()
				-- A sibling with the same path prefix must not count as membership.
				local other = f.root .. "-other"
				h.exec({ "git", "clone", f.source.root, other }, f.parent)
				with_environment({ GIT_DIR = f.git_dir, GIT_WORK_TREE = f.root }, function()
					local result = assert(util.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = other }))
					assert(
						util.canonical_path(util.trim(result.stdout)) == other,
						"dotfiles redirected another repository"
					)
					local done, result_async, failure
					util.system_start({ "git", "rev-parse", "--show-toplevel" }, { cwd = other }, function(value, e)
						done, result_async, failure = true, value, e
					end)
					wait(function()
						return done
					end)
					assert(result_async, failure)
					assert(util.canonical_path(util.trim(result_async.stdout)) == other)
				end)
			end),
		},
		{
			"test_core_git_environment_fast_event",
			guarded(function()
				local f = dotfiles_fixture()
				with_environment({ GIT_DIR = f.git_dir, GIT_WORK_TREE = f.root }, function()
					local done, result, failure, launch_error
					local timer = assert(vim.uv.new_timer())
					timer:start(0, 0, function()
						timer:close()
						local ok, err = pcall(function()
							assert(vim.in_fast_event(), "probe must run in a libuv callback")
							util.system_start({ "git", "rev-parse", "--show-toplevel" }, {
								cwd = f.root .. "/config",
							}, function(value, e)
								done, result, failure = true, value, e
							end)
						end)
						if not ok then
							done, launch_error = true, err
						end
					end)
					wait(function()
						return done
					end)
					assert(not launch_error, launch_error)
					assert(result, failure)
					assert(util.canonical_path(util.trim(result.stdout)) == f.root)
				end)
			end),
		},
		{
			"test_core_git_repository_environment_isolation",
			guarded(function()
				local a, b = h.make_git_fixture(), h.make_git_fixture()
				local overrides = {
					GIT_DIR = a.root .. "/.git",
					GIT_WORK_TREE = a.root,
					GIT_COMMON_DIR = a.root .. "/.git",
					GIT_INDEX_FILE = a.root .. "/.git/index",
					GIT_OBJECT_DIRECTORY = a.root .. "/.git/objects",
					GIT_ALTERNATE_OBJECT_DIRECTORIES = a.root .. "/.git/objects",
					GIT_NAMESPACE = "other",
					GIT_PREFIX = "other/",
					GIT_SHALLOW_FILE = a.root .. "/absent",
					GIT_GRAFT_FILE = a.root .. "/absent",
					GIT_IMPLICIT_WORK_TREE = "0",
				}
				local saved = {}
				for key, value in pairs(overrides) do
					saved[key], vim.env[key] = vim.env[key], value
				end
				local ok, err = xpcall(function()
					for _, supplied in ipairs({ false, true }) do
						local opts = { cwd = b.root, env = supplied and overrides or nil }
						local args = { "git", "rev-parse", "--show-toplevel" }
						local result, failure = util.system(args, opts)
						assert(result, failure)
						assert(
							util.canonical_path(util.trim(result.stdout)) == b.root,
							"synchronous Git escaped its cwd"
						)
						local done, value, command_err
						util.system_start(args, opts, function(v, e)
							done, value, command_err = true, v, e
						end)
						wait(function()
							return done
						end, "environment probe did not settle", 15000)
						assert(value, command_err)
						assert(
							util.canonical_path(util.trim(value.stdout)) == b.root,
							"asynchronous Git escaped its cwd"
						)
					end
					for key, value in pairs(overrides) do
						assert(vim.env[key] == value, "editor environment changed")
					end
					local args = { "git", "config", "user.name" }
					local result = assert(util.system(args, {
						cwd = b.root,
						env = {
							GIT_CONFIG_COUNT = "1",
							GIT_CONFIG_KEY_0 = "user.name",
							GIT_CONFIG_VALUE_0 = "ordinary configuration",
						},
					}))
					assert(util.trim(result.stdout) == "ordinary configuration", "ordinary configuration was lost")
				end, debug.traceback)
				for key in pairs(overrides) do
					vim.env[key] = saved[key]
				end
				assert(ok, err)
			end),
		},
		{
			"test_core_process_termination_is_failure",
			guarded(function()
				local system = vim.system
				for _, signal in ipairs({ 0, 15, 9 }) do
					vim.system = function(_, _, cb)
						local raw = { code = 0, signal = signal, stdout = "partial", stderr = "" }
						if cb then
							vim.schedule(function()
								cb(raw)
							end)
						end
						return {
							wait = function()
								return raw
							end,
						}
					end
					local result, err = util.system({ "fixture" })
					assert((result ~= nil) == (signal == 0), "synchronous signal counted as success")
					if signal ~= 0 then
						assert(err and err:find(tostring(signal), 1, true))
					end
					local done, value, failure, raw
					util.system_start({ "fixture" }, {}, function(v, e, r)
						done, value, failure, raw = true, v, e, r
					end)
					wait(function()
						return done
					end)
					assert((value ~= nil) == (signal == 0), "asynchronous signal counted as success")
					assert(raw.signal == signal and raw.code == 0)
					if signal ~= 0 then
						assert(failure and failure:find(tostring(signal), 1, true))
					end
				end
				vim.system = system
			end),
		},
		{
			"test_source_control_termination_custom_starter_is_failure",
			guarded(function()
				setup("staged")
				local jobs = require("lazyvcs.source_control.jobs")
				local repo = { root = h.tempdir(), vcs = "git" }
				local done, value, failure, raw
				jobs.command(repo, "signal_probe", { "fixture" }, {
					start = function(_, _, cb)
						cb({ code = 0, signal = 15, stdout = "", stderr = "" }, "")
						return {}
					end,
				}, function(v, e, r)
					done, value, failure, raw = true, v, e, r
				end)
				wait(function()
					return done
				end)
				assert(not value and failure and failure:find("15", 1, true), "scheduler accepted signalled result")
				assert(raw.signal == 15)
				local failed = false
				for _, job in ipairs(jobs.history()) do
					if job.root == repo.root and job.kind == "signal_probe" then
						failed = job.status == "error"
					end
				end
				assert(failed, "scheduler did not record signal error")
			end),
		},
		{
			"test_source_control_termination_commit_preserves_draft",
			guarded(function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX signal hook" }, 0)
				end
				setup("staged")
				for _, signal in ipairs({ "TERM", "KILL" }) do
					local f = h.make_git_fixture()
					h.exec({ "git", "add", "sample.txt" }, f.root)
					local head = h.exec({ "git", "rev-parse", "HEAD" }, f.root)
					h.write_file(f.root .. "/.git/hooks/pre-commit", "#!/bin/sh\nkill -" .. signal .. ' "$PPID"\n')
					assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 448))
					local state = {
						path = f.root,
						lazyvcs_commit_drafts = { [f.root] = "Keep my draft" },
						lazyvcs_repo_cache = {
							[f.root] = {
								root = f.root,
								vcs = "git",
								name = "fixture",
								counts = { staged = 1, local_changes = 1 },
							},
						},
						lazyvcs_render = function() end,
					}
					require("lazyvcs.source_control.ops").commit_repo(state, { path = f.root })
					wait(function()
						local history = require("lazyvcs.source_control.jobs").history()
						for _, job in ipairs(history) do
							if job.kind == "git_commit" and job.root == f.root then
								return true
							end
						end
					end, "commit did not settle", 15000)
					assert(state.lazyvcs_commit_drafts[f.root] == "Keep my draft", "signal cleared uncommitted draft")
					assert(h.exec({ "git", "rev-parse", "HEAD" }, f.root) == head)
					assert(h.exec({ "git", "diff", "--cached", "--name-only" }, f.root) == "sample.txt\n")
				end
			end),
		},
		{
			"test_core_ai_termination_rejects_partial_provider_output",
			guarded(function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX signal child" }, 0)
				end
				setup("staged")
				local system = vim.system
				vim.system = function(args, opts, cb)
					if args[1] == "codex" then
						return system({ "sh", "-c", "printf 'Incomplete subject'; kill -TERM $$" }, opts, cb)
					end
					return system(args, opts, cb)
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "add", "sample.txt" }, f.root)
				local done, message, failure
				ai.generate({ root = f.root, vcs = "git" }, function(m, e)
					done, message, failure = true, m, e
				end)
				wait(function()
					return done
				end, "provider did not settle", 15000)
				assert(not message and failure and failure:find("15", 1, true), "provider accepted partial output")
			end),
		},
		{
			"test_core_git_pathspec_environment_is_literal",
			guarded(function()
				local f = h.make_git_fixture()
				local saved = {}
				local keys = { "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS" }
				for _, key in ipairs(keys) do
					saved[key] = vim.env[key]
				end
				local ok, err = xpcall(function()
					for _, key in ipairs(keys) do
						vim.env[key] = "1"
						local args = { "git", "ls-files", "--", "sample.txt" }
						local value, failure = util.system(args, { cwd = f.root })
						assert(value and value.stdout == "sample.txt\n", failure)
						local done, result, error_message
						util.system_start(args, { cwd = f.root }, function(v, e)
							done, result, error_message = true, v, e
						end)
						wait(function()
							return done
						end)
						assert(result and result.stdout == "sample.txt\n", error_message)
						assert(vim.env[key] == "1", "editor environment changed")
						vim.env[key] = nil
					end
				end, debug.traceback)
				for _, key in ipairs(keys) do
					vim.env[key] = saved[key]
				end
				assert(ok, err)
			end),
		},
		{
			"test_core_ai_discovers_native_copilotchat_without_loading",
			guarded(function()
				setup("staged")
				require("lazyvcs.config").get().ai.commit_message.provider = "copilotchat"
				package.loaded.CopilotChat = nil
				package.loaded["lazy.core.config"] = { plugins = {} }
				for _, name in ipairs({ "CopilotChat.lua", "CopilotChat/init.lua" }) do
					local dir = h.tempdir()
					vim.fn.mkdir(dir .. "/lua/CopilotChat", "p")
					h.write_file(dir .. "/lua/" .. name, "error('discovery must not load the module')")
					vim.opt.runtimepath:prepend(dir)
					assert(ai.available(), "runtimepath provider not discovered: " .. name)
					assert(not package.loaded.CopilotChat)
					vim.opt.runtimepath:remove(dir)
				end
			end),
		},
		{
			"test_core_ai_context_ignores_external_diff_and_color",
			guarded(function()
				local start = util.system_start
				for _, context in ipairs({ "staged", "unstaged", "staged_first" }) do
					setup(context)
					local f = h.make_git_fixture()
					local helper = h.tempdir() .. "/empty-diff.lua"
					h.write_file(helper, "vim.cmd('qa!')")
					h.exec({
						"git",
						"config",
						"diff.external",
						'"' .. vim.v.progpath:gsub("\\", "/") .. '" --headless -u NONE -i NONE -l "' .. helper .. '"',
					}, f.root)
					h.exec({ "git", "config", "color.ui", "always" }, f.root)
					if context ~= "unstaged" then
						h.exec({ "git", "add", "sample.txt" }, f.root)
					end
					local prompt, done, failure
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, cb)
						if args[1] == "git" then
							return start(args, opts, cb)
						end
						prompt = opts.stdin
						cb({ code = 0, stdout = "Subject" })
						return {}
					end
					ai.generate({ root = f.root, vcs = "git" }, function(_, e)
						done, failure = true, e
					end)
					wait(function()
						return done
					end, "context did not settle", 15000)
					assert(not failure, failure)
					assert(prompt and prompt:find("+changed", 1, true), "patch missing for " .. context)
					assert(not prompt:find("\27", 1, true), "ANSI color in context")
				end
			end),
		},
	}
end
