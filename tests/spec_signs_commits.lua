return function(ctx)
	local s = require("signs_helpers")(ctx)
	local ops, store = require("lazyvcs.source_control.ops"), require("lazyvcs.state")
	local util, jobs = require("lazyvcs.util"), require("lazyvcs.source_control.jobs")
	local function sidebar(f, svn)
		return {
			path = f.root,
			lazyvcs_repo_cache = {
				[f.root] = {
					root = f.root,
					name = "fixture",
					vcs = svn and "svn" or "git",
					counts = { staged = svn and 0 or 1, local_changes = 1 },
				},
			},
			lazyvcs_commit_drafts = { [f.root] = "sign base regression café" },
			lazyvcs_render = function() end,
		}
	end
	local function finished(f)
		s.wait(function()
			local job = store.get_repo_job(f.root)
			return not job or job.status ~= "running"
		end, "commit did not settle", 15000)
	end
	-- Observe the real scheduler boundary as well as the base-change token. Restore
	-- every injected dependency even when a regression assertion fails.
	local function lifecycle(fn)
		local begin, finish, command = s.signs.begin_base_change, s.signs.finish_base_change, jobs.command
		local start, system, open = util.system_start, vim.system, vim.uv.fs_open
		local counts, token = { begin = 0, finish = 0, exit = 0, done = 0 }, nil
		---@diagnostic disable-next-line: duplicate-set-field
		s.signs.begin_base_change = function(...)
			counts.begin = counts.begin + 1
			token = begin(...)
			return token
		end
		---@diagnostic disable-next-line: duplicate-set-field
		s.signs.finish_base_change = function(change)
			assert(change == token, "commit finished a different base change")
			counts.finish = counts.finish + 1
			return finish(change)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		jobs.command = function(repo, kind, args, options, on_done)
			if kind == "git_commit" or kind == "svn_commit" then
				local starter = options.start
				options.start = function(command_args, process_opts, on_exit)
					return starter(command_args, process_opts, function(...)
						counts.exit = counts.exit + 1
						assert(counts.finish == 1, "commit called on_exit before releasing its base change")
						return on_exit(...)
					end)
				end
			end
			return command(repo, kind, args, options, function(...)
				if kind == "git_commit" or kind == "svn_commit" then
					counts.done = counts.done + 1
				end
				return on_done(...)
			end)
		end
		local ok, err = xpcall(function()
			fn(counts)
			assert(counts.begin == 1, "commit must begin exactly one base change")
			assert(counts.finish == 1, "commit must finish exactly one base change")
			assert(counts.done == 1, "commit must complete exactly once")
			assert(counts.exit <= 1, "commit must not call on_exit twice")
		end, debug.traceback)
		s.signs.begin_base_change, s.signs.finish_base_change, jobs.command = begin, finish, command
		util.system_start, vim.system, vim.uv.fs_open = start, system, open
		assert(ok, err)
	end
	-- Commit messages live in the private cache directory, or in a tempname when
	-- that directory cannot be protected.
	local function message_file(file)
		file = vim.fs.normalize(file)
		for _, dir in ipairs({
			vim.fn.stdpath("cache") .. "/lazyvcs/commit",
			vim.fn.fnamemodify(vim.fn.tempname(), ":h"),
		}) do
			if vim.startswith(file, vim.fs.normalize(dir) .. "/") then
				return true
			end
		end
		return false
	end
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		local prefix = svn and "test_svn_signs_commit_" or "test_signs_commit_"
		cases[#cases + 1] = {
			prefix .. "private_message_and_base_reload",
			s.guard(function()
				local f, buf = s.fixture(svn)
				if not svn then
					s.h.exec({ "git", "add", "--", "sample.txt" }, f.root)
				end
				local base = assert(s.refresh(buf, true))
				local generation = base.base_generation
				local state, path = sidebar(f, svn), nil
				local message = state.lazyvcs_commit_drafts[f.root]
				lifecycle(function(counts)
					local start = util.system_start
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, options, cb)
						if args[2] == "commit" then
							assert(counts.begin == 1 and counts.finish == 0)
							assert(not s.signs.current_state(buf).loaded, "commit did not invalidate cached base")
							assert(args[3] == "-F" and args[4] ~= "-", "commit bypassed private message file")
							path = args[4]
							assert(table.concat(vim.fn.readfile(path, "b"), "\n") == message)
							assert(vim.fs.normalize(options.cwd) == vim.fs.normalize(f.root))
							if package.config:sub(1, 1) ~= "\\" then
								assert(bit.band(vim.uv.fs_stat(path).mode, 511) == 384, "message file is not private")
							end
						end
						return start(args, options, cb)
					end
					ops.commit_repo(state, { path = f.root })
					finished(f)
					s.wait(function()
						local live = s.signs.current_state(buf)
						return live and live.loaded and live.base_generation > generation and #live.hunks == 0
					end, "commit did not reload signs base after settlement", 15000)
					assert(counts.exit == 1, "commit did not call on_exit")
				end)
				assert(path and not vim.uv.fs_stat(path), "commit message file survived settlement")
				assert(s.signs.current_state(buf).base_lines[2] == "changed")
				assert(#s.marks(buf) == 0)
				assert(state.lazyvcs_commit_drafts[f.root] == "", "successful commit did not clear draft")
				local log = svn and s.h.exec({ "svn", "log", "--xml", "-l", "1", f.file }, f.root)
					or s.h.exec({ "git", "log", "-1", "--format=%B" }, f.root)
				assert(log:find(svn and "<msg>" .. message .. "</msg>" or message, 1, true), "commit lost message")
			end),
		}
		for _, failure in ipairs({ "starter_throw", "spawn_throw", "spawn_report", "exit_failure", "cancel", "timeout" }) do
			cases[#cases + 1] = {
				prefix .. failure .. "_releases_base_and_commands",
				s.guard(function()
					local f, buf = s.fixture(svn)
					s.refresh(buf, true)
					local state, source = sidebar(f, svn), s.api.nvim_get_current_win()
					local message = state.lazyvcs_commit_drafts[f.root]
					local path, exit, process_opts
					lifecycle(function(counts)
						local start, system, open = util.system_start, vim.system, vim.uv.fs_open
						local function pending()
							assert(counts.begin == 1 and counts.finish == 0)
							assert(not s.signs.current_state(buf).loaded)
							vim.cmd("LazyVCS preview")
						end
						vim.uv.fs_open = function(file, ...)
							if failure == "starter_throw" and message_file(file) then
								pending()
								path = file
								error("injected starter error")
							end
							return open(file, ...)
						end
						vim.system = function(args, ...)
							-- SVN commands gain --non-interactive before the subcommand.
							if failure == "spawn_report" and (args[2] == "commit" or args[3] == "commit") then
								error("injected spawn error")
							end
							return system(args, ...)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, options, cb)
							if args[2] ~= "commit" then
								return start(args, options, cb)
							end
							path = args[4]
							pending()
							if failure == "spawn_throw" then
								error("injected spawn error")
							elseif failure == "spawn_report" then
								return start(args, options, cb)
							end
							exit, process_opts = cb, options
							return {
								cancel = function()
									return true
								end,
							}
						end
						ops.commit_repo(state, { path = f.root })
						if exit then
							local raw = { code = 1, stdout = "", stderr = "injected commit failure" }
							if failure == "cancel" or failure == "timeout" then
								raw.code = failure == "cancel" and 130 or 124
								raw.cancelled, raw.timed_out = failure == "cancel", failure == "timeout"
								assert(process_opts).on_terminate(nil, raw.stderr, raw)
								vim.wait(30)
								assert(counts.finish == 0, "logical termination released base before process exit")
								assert(s.api.nvim_get_current_win() == source, "preview consumed unsettled base")
								assert(vim.uv.fs_stat(path), "message removed before process exit")
							end
							exit(nil, raw.stderr, raw)
						end
						finished(f)
						s.wait(function()
							return s.api.nvim_get_current_win() ~= source
						end, failure .. " stranded waiting hunk command", 15000)
						s.api.nvim_win_close(0, true)
						assert(s.refresh(buf, true).loaded, "failure stranded subsequent signs refresh")
						s.api.nvim_win_set_cursor(0, { 1, 0 })
						vim.cmd("LazyVCS hunk next")
						s.wait(function()
							return s.api.nvim_win_get_cursor(0)[1] == 2
						end, "failure stranded subsequent hunk command", 15000)
						assert(counts.exit == (failure == "starter_throw" and 0 or 1), "unexpected on_exit count")
					end)
					assert(path and not vim.uv.fs_stat(path), "failed commit leaked private message file")
					assert(state.lazyvcs_commit_drafts[f.root] == message, "failed commit cleared draft")
				end),
			}
		end
	end
	return cases
end
