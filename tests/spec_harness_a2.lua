return function(ctx)
	local h = ctx.helpers
	local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
	local function fixture(name, scratch, ...)
		return vim.system({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			root .. "/tests/fixtures/" .. name .. ".lua",
			root,
			scratch,
			...,
		}, {
			text = true,
			env = {
				NVIM_LOG_FILE = scratch .. "/nvim.log",
				XDG_STATE_HOME = scratch .. "/state",
				XDG_CACHE_HOME = scratch .. "/cache",
			},
		}):wait(30000)
	end
	local function rejects_callback(mode, case, message)
		local result = fixture("scheduler_assertions", h.tempdir(), mode, case)
		local output = (result.stdout or "") .. (result.stderr or "")
		assert(result.code ~= 0 and output:find("FAIL  " .. case, 1, true), "invalid callback passed: " .. output)
		assert(output:find(message, 1, true), output)
	end
	return {
		{
			"test_core_minitest_bootstrap_isolates_git_environment",
			function()
				if vim.fn.has("win32") == 1 or vim.fn.executable("bash") ~= 1 then
					error({ lazyvcs_skip = "POSIX shell bootstrap; Windows uses tests/minitest.lua directly" }, 0)
				end
				local scratch = h.tempdir()
				local bin = scratch .. "/bin"
				vim.fn.mkdir(bin, "p")
				h.write_file(
					bin .. "/git",
					"#!/usr/bin/env bash\n"
						.. 'if [ "${3-}" = fetch ]; then env > "$BOOTSTRAP_ENV"; exit 91; fi\n'
						.. "exec "
						.. vim.fn.shellescape(vim.fn.exepath("git"))
						.. ' "$@"\n'
				)
				h.write_file(bin .. "/nvim", '#!/usr/bin/env bash\nenv > "$BOOTSTRAP_ENV"\n')
				h.write_file(
					scratch .. "/bootstrap-env.sh",
					'git() { "$BOOTSTRAP_GIT" "$@"; }\nnvim() { "$BOOTSTRAP_NVIM" "$@"; }\n'
				)
				assert(vim.uv.fs_chmod(bin .. "/git", 448))
				assert(vim.uv.fs_chmod(bin .. "/nvim", 448))
				for _, contaminated in ipairs({ false, true }) do
					local decoy = h.make_git_fixture()
					local config = vim.fn.readfile(decoy.root .. "/.git/config", "b")
					local index = vim.fn.readfile(decoy.root .. "/.git/index", "b")
					local head = h.exec({ "git", "rev-parse", "HEAD" }, decoy.root)
					local checkout = h.make_git_fixture()
					local pin = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, checkout.root))
					for _, missing in ipairs({ true, false }) do
						local env = vim.fn.environ()
						for key in pairs(env) do
							if vim.startswith(key, "GIT_") then
								env[key] = nil
							end
						end
						env.PATH = bin .. ":" .. env.PATH
						env.BOOTSTRAP_ENV = scratch .. "/environment.txt"
						env.BOOTSTRAP_GIT = bin .. "/git"
						env.BOOTSTRAP_NVIM = bin .. "/nvim"
						env.BASH_ENV = scratch .. "/bootstrap-env.sh"
						env.MINI_TEST_PATH = missing and (h.tempdir() .. "/mini") or checkout.root
						env.MINI_TEST_COMMIT = pin
						if contaminated then
							env.GIT_DIR = decoy.root .. "/.git"
							env.GIT_WORK_TREE = decoy.root
							env.GIT_COMMON_DIR = decoy.root .. "/.git"
							env.GIT_INDEX_FILE = decoy.root .. "/.git/index"
							env.GIT_CONFIG_COUNT = "1"
							env.GIT_CONFIG_KEY_0 = "user.name"
							env.GIT_CONFIG_VALUE_0 = "inherited"
							env.GIT_CONFIG_PARAMETERS = "'user.email=inherited@example.com'"
						end
						-- Neovim 0.11 expects a different clear_env representation.
						local command = { "env", "-i" }
						for key, value in pairs(env) do
							command[#command + 1] = key .. "=" .. value
						end
						vim.list_extend(command, { "bash", root .. "/tests/minitest.sh" })
						local result = vim.system(command, { text = true }):wait(10000)
						assert(
							vim.deep_equal(config, vim.fn.readfile(decoy.root .. "/.git/config", "b")),
							"MiniTest bootstrap changed the inherited repository config"
						)
						assert(vim.deep_equal(index, vim.fn.readfile(decoy.root .. "/.git/index", "b")))
						assert(head == h.exec({ "git", "rev-parse", "HEAD" }, decoy.root))
						assert(result.code == (missing and 91 or 0), result.stderr)
						for _, line in ipairs(vim.fn.readfile(env.BOOTSTRAP_ENV)) do
							assert(
								not line:match("^GIT_"),
								"inherited Git environment reached fetch or Neovim: " .. line
							)
						end
						if missing then
							assert(vim.fn.isdirectory(env.MINI_TEST_PATH .. "/.git") == 1)
							assert(
								h.exec({ "git", "remote", "get-url", "origin" }, env.MINI_TEST_PATH)
									== "https://github.com/nvim-mini/mini.nvim\n"
							)
						end
					end
				end
			end,
		},
		{
			"test_source_control_scheduler_callback_assertions_are_enforced",
			function()
				local case = "test_source_control_jobs_cancel_holds_worker_until_delayed_exit"
				rejects_callback("cancel_error", case, "cancel should report its logical result immediately")
				rejects_callback(
					"cancel_metadata",
					case,
					"cancel callback should receive the forced cancellation result"
				)
				rejects_callback(
					"timeout_error",
					"test_source_control_jobs_timeout_racing_late_exit_completes_once",
					"timeout should report immediately"
				)
			end,
		},
		{
			"test_core_process_callback_assertions_are_enforced",
			function()
				local case = "test_async_system_owns_timeout_escalation_and_bounded_output"
				rejects_callback("process_error", case, "logical timeout should report an error")
				rejects_callback(
					"process_metadata",
					case,
					"the logical timeout should be reported by the process owner"
				)
			end,
		},
		{
			"test_core_terminal_width_checks_reject_stale_artifacts",
			function()
				if vim.fn.has("win32") == 1 or vim.fn.executable("python3") ~= 1 then
					error({ lazyvcs_skip = "POSIX Python terminal driver" }, 0)
				end
				if vim.system({ "python3", "-c", "import pexpect" }):wait().code ~= 0 then
					error({ lazyvcs_skip = "pexpect unavailable" }, 0)
				end
				local result = vim.system({
					"python3",
					root .. "/tests/fixtures/width_artifacts.py",
					root,
					vim.v.progpath,
					h.tempdir(),
				}, { text = true }):wait(60000)
				assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
			end,
		},
		{
			"test_source_control_minitest_children_isolate_persistent_state",
			function()
				local scratch = h.tempdir()
				local previous
				for _ = 1, 2 do
					local result = fixture("minitest_state", scratch)
					assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
					local report = vim.json.decode(table.concat(vim.fn.readfile(scratch .. "/report.json"), "\n"))
					assert(report.state ~= report.inherited_state, "MiniTest child used inherited state storage")
					assert(report.cache ~= report.inherited_cache, "MiniTest child used inherited cache storage")
					assert(report.preferences > 0, "MiniTest child disabled preference persistence")
					assert(report.show_clean, "MiniTest child read inherited project preferences")
					assert(vim.fn.isdirectory(report.state) == 0, "MiniTest child left private state after exit")
					assert(vim.fn.isdirectory(report.cache) == 0, "MiniTest child left private cache after exit")
					assert(report.state ~= previous, "restarted MiniTest child reused private storage")
					assert(
						vim.fn.glob(scratch .. "/inherited-state/**/source_control/*.json")
							== report.inherited_preferences,
						"MiniTest child left fixture preferences in inherited storage"
					)
					previous = report.state
				end
			end,
		},
	}
end
