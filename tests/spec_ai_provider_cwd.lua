return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local ai = require("lazyvcs.source_control.ai")
	local cli_providers = { "claude", "codex", "gemini", "copilot_cli" }
	local diff = { code = 0, stdout = "diff --git a/app.lua b/app.lua\n+return true\n", stderr = "" }

	local function guarded(fn)
		return function()
			local start = util.system_start
			ai._test_reset_privacy()
			ai._test_set_executable_checker(function()
				return true
			end)
			local ok, err = xpcall(fn, debug.traceback)
			util.system_start = start
			ai._test_reset_privacy()
			assert(ok, err)
		end
	end

	local function setup(provider, overrides)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			ai = {
				commit_message = vim.tbl_extend("force", {
					provider = provider,
					provider_order = cli_providers,
					confirm_privacy = false,
				}, overrides or {}),
			},
		})
	end

	local function real(path)
		local normalized = vim.fs.normalize(path)
		return vim.fs.normalize(vim.uv.fs_realpath(normalized) or normalized)
	end

	local function inside(root, path)
		root, path = real(root), real(path)
		if vim.fn.has("win32") == 1 then
			root, path = root:lower(), path:lower()
		end
		return path == root or vim.startswith(path, root .. "/")
	end

	-- A repository that supplies agent settings a provider would load from its
	-- working directory.
	local function hostile_repo()
		local root = h.tempdir()
		for _, dir in ipairs({ ".claude", ".gemini", ".codex", ".github" }) do
			vim.fn.mkdir(root .. "/" .. dir, "p")
		end
		h.write_file(root .. "/.claude/settings.json", "{}\n")
		h.write_file(root .. "/.gemini/settings.json", "{}\n")
		h.write_file(root .. "/.env", "GEMINI_API_KEY=repository\n")
		return { root = root, vcs = "git", name = "hostile" }
	end

	local function provider_name(args)
		return args[1] == "copilot" and "copilot_cli" or args[1]
	end

	-- Describe a provider start, or return why its working directory is unsafe.
	local function inspect_start(repo, args, opts)
		local provider = provider_name(args)
		local cwd = opts.cwd
		if type(cwd) ~= "string" or cwd == "" then
			return provider .. " started without a working directory, inheriting the editor's"
		end
		if inside(repo.root, cwd) then
			return provider .. " started inside the repository (cwd " .. cwd .. ")"
		end
		local stat = vim.uv.fs_lstat(cwd)
		if not stat or stat.type ~= "directory" then
			return provider .. " working directory is not an existing directory: " .. cwd
		end
		if #vim.fn.readdir(cwd) > 0 then
			return provider .. " working directory is not empty: " .. cwd
		end
		if vim.fn.has("win32") == 0 and bit.band(stat.mode, 511) ~= 448 then
			return provider
				.. string.format(" working directory mode is %o, not 700: %s", bit.band(stat.mode, 511), cwd)
		end
		return nil
	end

	local function generate(repo)
		local outcome = {}
		local request = assert(ai.generate(repo, function(message, err, provider)
			outcome.done, outcome.message, outcome.err, outcome.provider = true, message, err, provider
		end))
		return request, outcome
	end

	return {
		{
			"test_source_control_ai_cli_providers_start_outside_repository",
			guarded(function()
				local problems, started = {}, {}
				local repo = hostile_repo()
				local fail_until
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" then
						done(diff, nil, diff)
						return {}
					end
					local provider = provider_name(args)
					started[#started + 1] = { provider = provider, cwd = opts.cwd }
					problems[#problems + 1] = inspect_start(repo, args, opts)
					if fail_until and provider ~= fail_until then
						done(nil, provider .. " failed")
					else
						done({ code = 0, stdout = "Add generated subject\n", stderr = "" })
					end
					return {}
				end

				for _, provider in ipairs(cli_providers) do
					setup(provider)
					local _, outcome = generate(repo)
					wait(function()
						return outcome.done
					end, provider .. " generation did not finish")
					assert(outcome.message == "Add generated subject", provider .. ": " .. tostring(outcome.err))
				end
				assert(#started == #cli_providers, "a CLI provider did not start: " .. vim.inspect(started))

				-- Automatic fallback gives every attempt its own neutral directory.
				setup("auto")
				fail_until = "copilot_cli"
				local _, outcome = generate(repo)
				wait(function()
					return outcome.done
				end, "automatic fallback did not finish")
				assert(outcome.provider == "copilot_cli", "fallback order changed: " .. vim.inspect(outcome))
				assert(#started == 2 * #cli_providers, "fallback skipped a CLI provider: " .. vim.inspect(started))

				assert(
					#problems == 0,
					"CLI providers must start in a private empty directory outside the repository:\n  "
						.. table.concat(problems, "\n  ")
				)
				for _, start in ipairs(started) do
					assert(
						inside(vim.fn.stdpath("cache"), vim.fs.dirname(start.cwd)),
						start.provider .. " working directory is not under the cache directory: " .. start.cwd
					)
					assert(
						not vim.uv.fs_lstat(start.cwd),
						start.provider .. " working directory was not removed: " .. start.cwd
					)
				end
			end),
		},
		{
			"test_source_control_ai_provider_cwd_never_inside_repository",
			guarded(function()
				local cache_home = vim.env.XDG_CACHE_HOME
				local repo
				local starts = {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" then
						done(diff, nil, diff)
						return {}
					end
					starts[#starts + 1] = provider_name(args) .. " (cwd " .. tostring(opts.cwd) .. ")"
					done({ code = 0, stdout = "Add generated subject\n", stderr = "" })
					return {}
				end
				-- No CLI provider may start, and no other directory may stand in.
				local function assert_refused(label)
					starts = {}
					local _, outcome = generate(repo)
					wait(function()
						return outcome.done
					end, label .. ": generation did not finish")
					assert(#starts == 0, label .. ": providers started: " .. table.concat(starts, ", "))
					assert(
						not outcome.message and tostring(outcome.err):find("working directory", 1, true),
						label .. ": expected a working directory error: " .. vim.inspect(outcome)
					)
				end
				local ok, err = xpcall(function()
					setup("auto")

					repo = hostile_repo()
					vim.env.XDG_CACHE_HOME = repo.root .. "/.cache"
					assert_refused("cache directory inside the repository")
					assert(not vim.uv.fs_lstat(repo.root .. "/.cache"), "created a directory inside the repository")

					if vim.fn.has("win32") == 0 then
						repo = hostile_repo()
						vim.env.XDG_CACHE_HOME = h.tempdir()
						vim.fn.mkdir(repo.root .. "/linked", "p")
						vim.fn.mkdir(vim.fn.stdpath("cache") .. "/lazyvcs", "p")
						assert(vim.uv.fs_symlink(repo.root .. "/linked", vim.fn.stdpath("cache") .. "/lazyvcs/ai-cwd"))
						assert_refused("cache directory linked into the repository")
						assert(#vim.fn.readdir(repo.root .. "/linked") == 0, "created a directory through the link")
					end

					repo = hostile_repo()
					local blocked = h.tempdir() .. "/file"
					h.write_file(blocked, "not a directory\n")
					vim.env.XDG_CACHE_HOME = blocked
					assert_refused("cache directory cannot be created")
				end, debug.traceback)
				vim.env.XDG_CACHE_HOME = cache_home
				assert(ok, err)
			end),
		},
		{
			"test_source_control_ai_provider_cwd_removed_after_cancel_and_failures",
			guarded(function()
				local repo = hostile_repo()
				local real_start = util.system_start
				local dir = h.tempdir()
				local script = dir .. "/provider.lua"
				h.write_file(script, table.concat({
					"local out = assert(io.open(arg[1], 'w'))",
					"out:write(vim.json.encode({ cwd = vim.uv.cwd(), entries = vim.fn.readdir(vim.uv.cwd()) }))",
					"out:close()",
					"if arg[2] == 'hang' then",
					"  vim.wait(60000)",
					"end",
					"io.stdout:write('Add generated subject\\n')",
				}, "\n") .. "\n")
				local mode, seen, held, killed, problem
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" then
						done(diff, nil, diff)
						return {}
					end
					seen = opts.cwd
					problem = inspect_start(repo, args, opts)
					if mode == "cancel" then
						held = done
						return {
							kill = function()
								killed = true
							end,
						}
					elseif mode == "spawn" then
						return h.failed_system_spawn(real_start, args, opts, done)
					end
					-- Run a real child with the provider's options to observe the
					-- directory the process itself starts in.
					local child = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }
					child[#child + 1] = dir .. "/" .. mode .. ".json"
					child[#child + 1] = mode
					return real_start(child, opts, done)
				end

				local function run(provider, next_mode, overrides)
					setup(provider, overrides)
					mode, seen, held, killed, problem = next_mode, nil, nil, false, nil
					local request, outcome = generate(repo)
					return request, outcome
				end
				local function assert_removed(label)
					assert(seen, label .. ": provider did not start")
					assert(not problem, label .. ": " .. tostring(problem))
					assert(not vim.uv.fs_lstat(seen), label .. ": working directory was not removed: " .. seen)
				end

				local request, outcome = run("claude", "cancel")
				wait(function()
					return held ~= nil
				end, "provider did not start before cancellation")
				request:cancel("test")
				assert(killed and not outcome.done, "cancellation did not stop the provider quietly")
				assert_removed("cancellation")
				-- The process is still exiting and may write again before it stops.
				vim.fn.mkdir(seen, "p")
				h.write_file(seen .. "/late.txt", "late\n")
				held(nil, "cancelled", { code = 130, cancelled = true })
				assert(not outcome.done, "cancelled provider delivered a result")
				assert_removed("exit after cancellation")

				_, outcome = run("gemini", "spawn")
				wait(function()
					return outcome.done
				end, "spawn failure did not finish", 15000)
				assert(outcome.err and not outcome.message, "spawn failure reported success")
				assert_removed("spawn failure")

				_, outcome = run("codex", "hang", { timeout_ms = 500 })
				wait(function()
					return outcome.done
				end, "provider timeout did not finish", 15000)
				assert(
					tostring(outcome.err):find("Timed out", 1, true),
					"expected a timeout: " .. tostring(outcome.err)
				)
				assert_removed("timeout")

				_, outcome = run("copilot_cli", "exit", { timeout_ms = 15000 })
				wait(function()
					return outcome.done
				end, "provider process did not finish", 15000)
				assert(outcome.message == "Add generated subject", "provider process failed: " .. tostring(outcome.err))
				assert_removed("completion")
				local observed = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/exit.json"), "\n"))
				assert(
					not inside(repo.root, observed.cwd),
					"provider process ran inside the repository: " .. observed.cwd
				)
				assert(
					inside(seen, observed.cwd) and inside(observed.cwd, seen),
					"provider process started in " .. observed.cwd .. ", not " .. seen
				)
				assert(#observed.entries == 0, "provider process saw files in its working directory")
			end),
		},
	}
end
