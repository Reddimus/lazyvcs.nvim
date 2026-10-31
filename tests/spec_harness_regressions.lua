return function(ctx)
	local h = ctx.helpers
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local function read(path)
		return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
	end
	return {
		{
			"test_core_headless_smoke_checks_propagate_errors",
			function()
				if vim.fn.executable("python3") == 0 then
					error({ lazyvcs_skip = "Python unavailable" }, 0)
				end
				local result = vim.system(
					{ "python3", root .. "/tests/fixtures/headless_checks.py", root, vim.v.progpath },
					{ text = true }
				):wait()
				assert(result.code == 0, result.stderr)
			end,
		},
		{
			"test_core_compare_terminal_checks_reject_false_invariants",
			function()
				if vim.fn.executable("python3") == 0 or vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX Python terminal driver" }, 0)
				end
				if vim.fn.executable("svn") ~= 1 or vim.fn.executable("svnadmin") ~= 1 then
					error({ lazyvcs_skip = "terminal driver requires SVN tools" }, 0)
				end
				local available = vim.system({ "python3", "-c", "import pexpect" }):wait()
				if available.code ~= 0 then
					error({ lazyvcs_skip = "pexpect unavailable" }, 0)
				end
				for _, mode in ipairs({ "listed", "diff", "normal" }) do
					local result = vim.system({
						"python3",
						root .. "/tests/fixtures/compare_invariants.py",
						root,
						vim.v.progpath,
						h.tempdir(),
						mode,
					}, { text = true }):wait(120000)
					assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
				end
			end,
		},
		{
			"test_core_fixtures_ignore_inherited_git_repository",
			function()
				for _, worktree in ipairs({ false, true }) do
					for _, sample in ipairs({ false, true }) do
						local decoy = h.make_git_fixture()
						h.exec({ "git", "add", "." }, decoy.root)
						if not sample then
							assert(vim.uv.fs_unlink(decoy.file))
						end
						local head = h.exec({ "git", "rev-parse", "HEAD" }, decoy.root)
						local index = vim.fn.readfile(decoy.root .. "/.git/index", "b")
						local config = vim.fn.readfile(decoy.root .. "/.git/config", "b")
						local script = h.tempdir() .. "/fixture.lua"
						h.write_file(
							script,
							"package.path="
								.. string.format("%q", root .. "/tests/?.lua;" .. root .. "/lua/?.lua;")
								.. "..package.path\n"
								.. "local h=require('helpers');local f=h.make_git_fixture();assert(require('lazyvcs.util').system({'git','rev-parse','--show-toplevel'},{cwd=f.root}).stdout==f.root..'\\n');h.cleanup()\n"
						)
						local env = vim.tbl_extend("force", vim.fn.environ(), {
							GIT_DIR = decoy.root .. "/.git",
							GIT_CONFIG_COUNT = "1",
							GIT_CONFIG_KEY_0 = "user.name",
							GIT_CONFIG_VALUE_0 = "inherited",
						})
						env.GIT_WORK_TREE = worktree and decoy.root or nil
						if worktree then
							env.GIT_COMMON_DIR = decoy.root .. "/.git"
							env.GIT_INDEX_FILE = decoy.root .. "/.git/index"
							env.GIT_OBJECT_DIRECTORY = decoy.root .. "/.git/objects"
							env.GIT_ALTERNATE_OBJECT_DIRECTORIES = decoy.root .. "/.git/objects"
						end
						local result = vim.system(
							{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script },
							{
								text = true,
								env = env,
								clear_env = true,
							}
						)
							:wait()
						assert(
							h.exec({ "git", "rev-parse", "HEAD" }, decoy.root) == head,
							"fixture committed developer work"
						)
						assert(
							vim.deep_equal(index, vim.fn.readfile(decoy.root .. "/.git/index", "b")),
							"fixture changed developer index"
						)
						assert(
							vim.deep_equal(config, vim.fn.readfile(decoy.root .. "/.git/config", "b")),
							"fixture changed developer config"
						)
						assert(result.code == 0, result.stderr)
					end
				end
			end,
		},
		{
			"test_core_release_uses_immutable_event_commit",
			function()
				local workflow = read(".github/workflows/release.yml")
				assert(not workflow:find("ref: ${{ github.ref }}", 1, true), "release resolves mutable tag twice")
				local _, count = workflow:gsub("ref: %${{ github.sha }}", "")
				assert(count == 2, "verification and publication must pin github.sha")
				assert(workflow:find("EVENT_SHA: ${{ github.sha }}", 1, true))
				assert(
					workflow:find('test "$(git rev-parse "${TAG}^{commit}")" = "${EVENT_SHA}"', 1, true),
					"signed tag is not bound to event commit"
				)
			end,
		},
		{
			"test_core_cancelled_subscriber_assertion_is_enforced",
			function()
				local backends = require("lazyvcs.backends")
				local resolve = backends.resolve_async
				local first = true
				---@diagnostic disable-next-line: duplicate-set-field
				backends.resolve_async = function(...)
					local handle = resolve(...)
					if first then
						first = false
						handle.kill = function() end
					end
					return handle
				end
				local ok, err = pcall(function()
					for _, case in ipairs(require("spec_audit")(ctx)) do
						if case[1] == "test_backend_probe_shared_cancellation_preserves_other_subscriber" then
							return case[2]()
						end
					end
					error("missing cancellation regression")
				end)
				backends.resolve_async = resolve
				assert(
					not ok and tostring(err):find("cancelled subscriber ran", 1, true),
					"broken cancellation still passes regression"
				)
			end,
		},
		{
			"test_svn_literal_path_fixture_skips_missing_tools",
			function()
				local executable, exec = vim.fn.executable, h.exec
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.executable = function(name)
					return (name == "svn" or name == "svnadmin") and 0 or executable(name)
				end
				h.exec = function(args, cwd)
					if args[1] == "svn" or args[1] == "svnadmin" then
						error("unavailable SVN invoked")
					end
					return exec(args, cwd)
				end
				local ok, err = pcall(function()
					for _, case in ipairs(require("spec_literal_paths")(ctx)) do
						if
							case[1] == "test_source_control_literal_paths_open_selected_file"
							or case[1] == "test_svn_source_control_literal_paths_open_selected_file"
						then
							local passed, reason = pcall(case[2])
							if case[1]:find("svn", 1, true) then
								assert(
									not passed and type(reason) == "table" and reason.lazyvcs_skip,
									"missing SVN did not skip"
								)
							else
								assert(passed, reason)
							end
						end
					end
				end)
				vim.fn.executable, h.exec = executable, exec
				assert(ok, err)
			end,
		},
		{
			"test_core_security_supports_current_plugin_minor",
			function()
				local minor = assert(read("CHANGELOG.md"):match("\n## %[(%d+%.%d+)%.%d+%]"), "no release heading")
				assert(
					read("SECURITY.md"):match("|%s*" .. vim.pesc(minor) .. "%.x%s*|%s*Yes%s*|"),
					"security table omits current minor"
				)
				assert(
					read("SECURITY.md"):match("|%s*<%s*" .. vim.pesc(minor) .. "%s*|%s*No%s*|"),
					"security table retains old range"
				)
			end,
		},
		{
			"test_core_picker_preview_limit_matches_cleanup",
			function()
				assert(
					not read("README.md"):find("leaves that diff", 1, true),
					"README retains obsolete preview limitation"
				)
				assert(
					not read("doc/lazyvcs.txt"):find("leaves that diff", 1, true),
					"help retains obsolete preview limitation"
				)
			end,
		},
		{
			"test_core_bash_syntax_checks_every_script",
			function()
				if vim.fn.executable("bash") == 0 then
					error({ lazyvcs_skip = "bash unavailable" }, 0)
				end
				for _, file in ipairs({ "CONTRIBUTING.md", ".github/workflows/verify.yml" }) do
					local source = read(file)
					local command = source:match("(for script in tests/minitest.sh.-done)")
						or source:match("(bash %-n tests/minitest.sh[^\n]+)")
					assert(command, "missing syntax check")
					local dir = h.tempdir()
					vim.fn.mkdir(dir .. "/tests/ci", "p")
					vim.fn.mkdir(dir .. "/tests/e2e", "p")
					h.write_file(dir .. "/tests/minitest.sh", "true\n")
					h.write_file(dir .. "/tests/ci/install-neovim.sh", "then\n")
					h.write_file(dir .. "/tests/e2e/example.sh", "true\n")
					local result = vim.system({ "bash", "-c", command }, { cwd = dir, text = true }):wait()
					assert(result.code ~= 0, file .. " skipped invalid second script")
				end
			end,
		},
	}
end
