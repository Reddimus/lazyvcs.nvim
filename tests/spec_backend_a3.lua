return function(ctx)
	local h = ctx.helpers
	local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
	local function await(start)
		local value, failure, extra, finished
		start(function(result, err, details)
			value, failure, extra, finished = result, err, details, true
		end)
		ctx.wait_for(function()
			return finished
		end, "audit backend operation did not complete", 15000)
		return value, failure, extra
	end
	return {
		{
			"test_core_runner_rejects_crashed_and_incomplete_groups",
			function()
				for _, mode in ipairs({ "signal", "incomplete", "timeout", "cwd", "success", "stderr" }) do
					local result = vim.system({
						vim.v.progpath,
						"--headless",
						"-u",
						"NONE",
						"-i",
						"NONE",
						"-l",
						root .. "/tests/fixtures/runner_a3.lua",
						root,
						mode,
					}, { text = true, cwd = root }):wait(10000)
					local failure = mode == "signal" or mode == "incomplete"
					assert(
						(result.code ~= 0 or (result.signal or 0) ~= 0) == failure,
						mode .. ": " .. (result.stdout or "") .. (result.stderr or "")
					)
				end
			end,
		},
		{
			"test_core_git_hooks_keep_globs_and_character_locale",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX hook fixture" }, 0)
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "core.hooksPath", f.root .. "/.git/hooks" }, f.root)
				h.write_file(f.root .. "/check.js", "reject\n")
				h.exec({ "git", "add", "check.js" }, f.root)
				h.write_file(
					f.root .. "/.git/hooks/pre-commit",
					'#!/bin/sh\nlocale charmap > hook-locale\nprintf "%s" "$LC_MESSAGES" > hook-messages\nif git diff --cached --name-only -- "*.js" | grep -q .; then echo rejected-js >&2; exit 1; fi\n'
				)
				assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493))
				local util = require("lazyvcs.util")
				local before = h.exec({ "git", "rev-parse", "HEAD" }, f.root)
				for _, inherited in ipairs({
					"GIT_LITERAL_PATHSPECS",
					"GIT_GLOB_PATHSPECS",
					"GIT_NOGLOB_PATHSPECS",
					"GIT_ICASE_PATHSPECS",
				}) do
					local result = util.system_result(
						{ "git", "commit", "-m", "café" },
						{ cwd = f.root, env = { [inherited] = "1", LC_ALL = "C.UTF-8" } }
					)
					assert(
						result.code ~= 0 and result.stderr:find("rejected-js", 1, true),
						"hook lost glob: " .. result.stderr
					)
					assert(h.exec({ "git", "rev-parse", "HEAD" }, f.root) == before)
					assert(vim.fn.readfile(f.root .. "/hook-locale")[1] == "UTF-8", "hook lost UTF-8")
					assert(vim.fn.readfile(f.root .. "/hook-messages")[1] == "C")
				end
				-- A filename named after a pathspec command is still a literal blame target.
				h.write_file(f.root .. "/--literal-pathspecs", "literal flag filename\n")
				assert(util.system({ "git", "add", "--", "--literal-pathspecs" }, { cwd = f.root }))
				h.write_file(f.root .. "/diff", "content\n")
				assert(util.system({ "git", "add", "--", "diff" }, { cwd = f.root }))
				assert(util.system({ "git", "blame", "--", "diff" }, { cwd = f.root }))
			end,
		},
		{
			"test_core_git_ignored_files_have_no_editable_base",
			function()
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/.gitignore", "*.log\ncache/\n")
				h.write_file(f.root .. "/.git/info/exclude", "private.txt\n")
				local git = require("lazyvcs.backends.git")
				for _, rel in ipairs({ "output.log", "cache/item.txt", "private.txt" }) do
					vim.fn.mkdir(vim.fs.dirname(f.root .. "/" .. rel), "p")
					h.write_file(f.root .. "/" .. rel, "keep\n")
					local value, err = git.load_base(f.root .. "/" .. rel)
					assert(not value and err and err:find("ignored", 1, true))
					local rejected
					value, err, rejected = await(function(done)
						git.load_base_async(f.root .. "/" .. rel, done, { root = f.root })
					end)
					assert(not value and err and err:find("ignored", 1, true) and rejected.code == "untracked")
				end
				h.exec({ "git", "add", "-f", "output.log" }, f.root)
				assert(git.load_base(f.root .. "/output.log").base_label == "INDEX")
			end,
		},
		{
			"test_core_git_ignore_checks_treat_leading_colons_as_literal_filenames",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "colon filenames require POSIX" }, 0)
				end
				local git = require("lazyvcs.backends.git")
				for _, rel in ipairs({ ":notes", ":(literal)notes", ":(glob)*", ":!notes" }) do
					for _, ignored in ipairs({ false, true }) do
						local f = h.make_git_fixture()
						-- Anchored wildcard rules avoid giving Git's ignore parser
						-- the literal filename's separate pattern syntax.
						h.write_file(f.root .. "/.gitignore", ignored and "/:*\n" or "other.txt\n")
						local path = f.root .. "/" .. rel
						h.write_file(path, "private bytes\n")
						for _, async in ipairs({ false, true }) do
							local value, err
							if async then
								value, err = await(function(done)
									git.load_base_async(path, done, { root = f.root })
								end)
							else
								value, err = git.load_base(path)
							end
							if ignored then
								assert(not value and err and err:find("ignored", 1, true), rel .. ": " .. tostring(err))
							else
								assert(value and value.base_label == "EMPTY", rel .. ": " .. tostring(err))
							end
						end
					end
				end
			end,
		},
		{
			"test_core_git_intent_to_add_discard_preserves_bytes",
			function()
				local f = h.make_git_fixture()
				local path = f.root .. "/intent.txt"
				h.write_file(path, "valuable bytes\n")
				h.exec({ "git", "add", "-N", "intent.txt" }, f.root)
				local git = require("lazyvcs.backends.git")
				local result, err = git.revert_file(path)
				assert(not result and err and err:find("Intent-to-add", 1, true))
				result, err = await(function(done)
					git.revert_file_async(path, done, { root = f.root })
				end)
				assert(not result and err and err:find("Intent-to-add", 1, true))
				assert(vim.fn.readfile(path)[1] == "valuable bytes")
			end,
		},
		{
			"test_core_git_deleted_file_replaced_by_directory_preview",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
				assert(vim.uv.fs_unlink(f.file))
				vim.fn.mkdir(f.file, "p")
				h.write_file(f.file .. "/nested.txt", "unrelated\n")
				local snapshot = {
					root = f.root,
					revision = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root)),
					base = "HEAD",
				}
				local result, err = await(function(done)
					require("lazyvcs.backends.compare_git").preview(
						snapshot,
						{ relpath = "sample.txt", status = "D" },
						done
					)
				end)
				assert(result, err)
				assert(result.left_kind == "regular" and result.right_label ~= "SUBMODULE / DIRECTORY")
				assert(#result.left > 0 and #result.right == 0)
			end,
		},
		{
			"test_core_git_symlink_preview_ignores_regular_encoding",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "symbolic links require privileges" }, 0)
				end
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/.gitattributes", "*.txt working-tree-encoding=UTF-16LE\n")
				local link = f.root .. "/target.txt"
				assert(vim.uv.fs_symlink("café", link))
				h.exec({ "git", "add", ".gitattributes", "target.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "symlink" }, f.root)
				assert(vim.uv.fs_unlink(link))
				assert(vim.uv.fs_symlink("résumé", link))
				local result, err = await(function(done)
					require("lazyvcs.backends.compare_git").preview({
						root = f.root,
						revision = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root)),
						base = "HEAD",
					}, { relpath = "target.txt", status = "M" }, done)
				end)
				assert(result, err)
				assert(result.left[1] == "café" and result.right[1] == "résumé", vim.inspect(result))
			end,
		},
		{
			"test_core_report_windows_disable_inherited_folds",
			function()
				local util = require("lazyvcs.util")
				local source = vim.api.nvim_get_current_win()
				local previous = util.capture_win_options(source, { "foldmethod", "foldenable", "foldlevel" })
				local ok, err = pcall(function()
					util.set_win_options(source, { foldmethod = "indent", foldenable = true, foldlevel = 0 })
					util.show_text("report", { "  first", "    nested", "  second" })
					assert(not vim.wo.foldenable and vim.fn.foldclosed(1) == -1)
					assert(vim.wo[source].foldenable)
					vim.api.nvim_win_close(0, true)
				end)
				util.set_win_options(source, previous)
				assert(ok, err)
			end,
		},
		{
			"test_source_control_json_writes_preserve_relative_file_links",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "symbolic links require privileges" }, 0)
				end
				local dir = h.tempdir()
				h.write_file(dir .. "/target.json", "{}")
				assert(vim.uv.fs_symlink("target.json", dir .. "/state.json"))
				local json = require("lazyvcs.json_file")
				assert(json.write(dir .. "/state.json", { value = 42 }))
				assert(vim.uv.fs_lstat(dir .. "/state.json").type == "link")
				assert(json.read(dir .. "/target.json").value == 42)
			end,
		},
		{
			"test_blame_git_compact_porcelain_large_file_keeps_metadata",
			function()
				local f = h.make_git_fixture()
				local lines = {}
				for i = 1, 12000 do
					lines[i] = "row " .. i
				end
				h.write_file(f.file, table.concat(lines, "\n") .. "\n")
				h.exec({ "git", "commit", "-am", "many lines" }, f.root)
				local git = require("lazyvcs.backends.git")
				local raw, err = await(function(done)
					git.blame_lines_async(f.file, done, { root = f.root })
				end)
				assert(raw, err)
				local entries = git.parse_blame_entries(raw)
				assert(#entries == #lines)
				for _, i in ipairs({ 1, 6000, 12000 }) do
					assert(
						entries[i].author == "lazyvcs-test"
							and entries[i].summary == "many lines"
							and entries[i].date ~= "-"
					)
				end
				local full = git.parse_blame_entries(assert(git.blame_lines(f.file)))
				assert(full[12000].author == "lazyvcs-test")
			end,
		},
		{
			"test_blame_git_equal_count_mac_rows_are_rejected",
			function()
				local format = require("lazyvcs.backends.blame_format")
				local sha = string.rep("a", 40)
				local result, err = format.select(
					{ sha .. " 1 1 2", "\tx1", sha .. " 2 2", "\tY2\rz1" },
					{ profile = { fileencoding = "utf-8", fileformat = "mac" }, text = { lines = { "x1\rY2", "z1" } } },
					format.git_policy({ profile = { fileencoding = "utf-8", fileformat = "mac" } }, {})
				)
				assert(not result and err and err:find("Unsupported blame", 1, true))
			end,
		},
		{
			"test_svn_copied_added_replaced_and_binary_blame_use_metadata",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				local svn = require("lazyvcs.backends.svn")
				local original = vim.fn.readfile(f.file)
				h.exec({ "svn", "copy", f.file, f.root .. "/copy.txt" }, f.root)
				local base, err = svn.load_base(f.root .. "/copy.txt")
				assert(base and base.base_label == "BASE" and base.base_bytes ~= "", err)
				base, err = await(function(done)
					svn.load_base_async(f.root .. "/copy.txt", done, { root = f.root })
				end)
				assert(base and base.base_label == "BASE", err)
				local rows
				rows, err = await(function(done)
					svn.blame_lines_async(f.root .. "/copy.txt", done, { root = f.root })
				end)
				assert(rows and #rows == #original and not svn.parse_blame_entries(rows)[1].uncommitted, err)
				assert(not svn.parse_blame_entries(assert(svn.blame_lines(f.root .. "/copy.txt")))[1].uncommitted)
				h.exec({ "svn", "propset", "svn:mime-type", "application/octet-stream", f.file }, f.root)
				h.exec({ "svn", "commit", "-m", "binary mime", f.file }, f.root)
				rows, err = await(function(done)
					svn.blame_lines_async(f.file, done, { root = f.root })
				end)
				assert(rows and #rows == #original, err)
				h.exec({ "svn", "delete", f.file }, f.root)
				h.write_file(f.file, "replacement\n")
				h.exec({ "svn", "add", f.file }, f.root)
				h.exec({ "svn", "changelist", "local", f.file }, f.root)
				local previous = vim.env.LANGUAGE
				vim.env.LANGUAGE = "de"
				local ok, failure = pcall(function()
					assert(svn.load_base(f.file).base_label == "EMPTY")
					assert(svn.parse_blame_entries(assert(svn.blame_lines(f.file)))[1].uncommitted)
					local value, why = await(function(done)
						svn.blame_lines_async(f.file, done, { root = f.root })
					end)
					assert(value and svn.parse_blame_entries(value)[1].uncommitted, why)
				end)
				vim.env.LANGUAGE = previous
				assert(ok, failure)
			end,
		},
		{
			"test_svn_blame_cache_uses_local_identity_and_one_pinned_revision",
			function()
				local f = h.make_svn_fixture()
				local svn, process = require("lazyvcs.backends.svn"), require("lazyvcs.backends.process")
				local run = process.lines
				local requests = 0
				---@diagnostic disable-next-line: duplicate-set-field
				process.lines = function(args, opts, done)
					if args[1] == "svn" and args[2] == "blame" then
						requests = requests + 1
						assert(not vim.tbl_contains(args, "BASE"), "symbolic BASE can race the cat")
					end
					return run(args, opts, done)
				end
				local ok, failure = pcall(function()
					assert(await(function(done)
						svn.blame_lines_async(f.file, done, { root = f.root })
					end))
					h.write_file(f.file, "saved edit\n")
					assert(await(function(done)
						svn.blame_lines_async(f.file, done, { root = f.root })
					end))
					assert(requests == 1, "edits refetched repository blame")
					h.exec({ "svn", "commit", "-m", "new base", f.file }, f.root)
					assert(await(function(done)
						svn.blame_lines_async(f.file, done, { root = f.root })
					end))
					assert(requests == 2, "external commit failed to invalidate immutable cache")
				end)
				process.lines = run
				assert(ok, failure)
			end,
		},
		{
			"test_svn_untracked_expansion_stops_at_nested_repositories",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/vendor/nested/.git", "p")
				vim.fn.mkdir(f.root .. "/vendor/worktree", "p")
				h.write_file(f.root .. "/vendor/worktree/.git", "gitdir: nowhere\n")
				h.write_file(f.root .. "/vendor/nested/private.txt", "not parent\n")
				h.write_file(f.root .. "/vendor/worktree/private.txt", "not parent\n")
				h.write_file(f.root .. "/vendor/top.txt", "parent\n")
				local common = require("lazyvcs.backends.comparison")
				local value, err = await(function(done)
					require("lazyvcs.backends.svn_untracked").expand(
						common.task(),
						{ root = f.root },
						{ { wc_item = "unversioned", path = "vendor" } },
						done
					)
				end)
				assert(value, err)
				assert(vim.deep_equal(value, { "vendor/top.txt" }), vim.inspect(value))
			end,
		},
		{
			"test_svn_compare_obstructions_are_visible_and_expand_untracked",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				assert(vim.uv.fs_unlink(f.file))
				vim.fn.mkdir(f.file, "p")
				h.write_file(f.file .. "/new.conf", "untracked\n")
				local provider = require("lazyvcs.backends.compare_svn")
				local snapshot = { root = f.root, url = h.file_url(f.repo), revision = "1" }
				local rows, err = await(function(done)
					provider.list(snapshot, true, done)
				end)
				assert(rows, err)
				local missing, untracked
				for _, row in ipairs(rows) do
					if row.relpath == "sample.txt" then
						missing = row
					elseif row.relpath == "sample.txt/new.conf" then
						untracked = row
					end
				end
				assert(missing and missing.status == "!" and missing.obstructed and untracked, vim.inspect(rows))
				local preview = assert(await(function(done)
					provider.preview(snapshot, missing, done)
				end))
				assert(preview.right_label == "OBSTRUCTED WORKTREE")
			end,
		},
		{
			"test_core_git_relative_work_tree_environment_uses_process_cwd",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
				vim.fn.mkdir(f.root .. "/sub", "p")
				h.write_file(f.root .. "/sub/clean.txt", "clean\n")
				h.exec({ "git", "add", "sub/clean.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "subfile" }, f.root)
				local cwd, old_dir, old_tree = assert(vim.uv.cwd()), vim.env.GIT_DIR, vim.env.GIT_WORK_TREE
				local ok, err = pcall(function()
					vim.fn.chdir(f.root)
					for _, gitdir in ipairs({ f.root .. "/.git", ".git" }) do
						vim.env.GIT_DIR, vim.env.GIT_WORK_TREE = gitdir, "."
						local payload, why = await(function(done)
							require("lazyvcs.backends.git").load_base_async(f.root .. "/sub/clean.txt", done)
						end)
						assert(
							payload
								and payload.root == f.root
								and payload.base_label == "INDEX"
								and payload.base_bytes == "clean\n",
							why
						)
					end
					vim.fn.mkdir(f.root .. "/sub/nested", "p")
					h.exec({ "git", "init" }, f.root .. "/sub/nested")
					local info, why = await(function(done)
						require("lazyvcs.backends.git").probe_async(f.root .. "/sub/nested", done)
					end)
					assert(info and info.root == f.root .. "/sub/nested", why)
				end)
				vim.env.GIT_DIR, vim.env.GIT_WORK_TREE = old_dir, old_tree
				vim.fn.chdir(cwd)
				assert(ok, err)
			end,
		},
		{
			"test_core_git_staged_snapshots_decode_legacy_bytes_and_keep_raw_identity",
			function()
				local f = h.make_git_fixture()
				h.write_file(f.file, "caf\233\n")
				h.exec({ "git", "commit", "-am", "latin1" }, f.root)
				h.write_file(f.file, "caf\233 staged\n")
				h.exec({ "git", "add", "sample.txt" }, f.root)
				local result, err = await(function(done)
					require("lazyvcs.backends.git").load_diff_target_async(
						{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
						done
					)
				end)
				assert(result, err)
				assert(result.left.lines[1] == "café" and result.right.lines[1] == "café staged", vim.inspect(result))
				assert(result.left.bytes == "caf\233\n" and result.right.bytes == "caf\233 staged\n")
			end,
		},
		{
			"test_svn_equal_root_resolution_prefers_git_even_after_svn_finishes_first",
			function()
				local backends, git, svn =
					require("lazyvcs.backends"), require("lazyvcs.backends.git"), require("lazyvcs.backends.svn")
				local f = h.make_svn_fixture()
				h.exec({ "git", "init" }, f.root)
				backends.invalidate()
				local original = git.probe_async
				---@diagnostic disable-next-line: duplicate-set-field
				git.probe_async = function(path, done, opts)
					local task = require("lazyvcs.backends.task").new(done)
					vim.defer_fn(function()
						if task:is_active() then
							task:add(original(path, function(...)
								task:finish(...)
							end, opts))
						end
					end, 30)
					return task
				end
				local ok, err = pcall(function()
					for _, opts in ipairs({ {}, { revalidate = true } }) do
						local backend, resolved, failure = await(function(done)
							backends.resolve_async(f.file, done, opts)
						end)
						assert(backend == git and resolved == f.root, failure)
						assert(backends.resolve_cached(f.file) == git)
					end
				end)
				git.probe_async = original
				assert(ok, err)
				assert(svn.probe(f.file), "fixture did not share roots")
			end,
		},
		{
			"test_svn_probe_does_not_wait_for_busy_editor_read_worker",
			function()
				local f = h.make_git_fixture()
				local jobs = require("lazyvcs.source_control.jobs")
				local release, started
				local id = jobs.command({ root = f.root, vcs = "svn" }, "buffer", { "svn", "delayed-read" }, {
					start = function(_, _, done)
						release = done
						started = true
						return { kill = function() end }
					end,
				})
				assert(started)
				local ok, err = pcall(function()
					require("lazyvcs.backends").invalidate()
					local backend, _, failure = await(function(done)
						require("lazyvcs.backends").resolve_async(f.file, done)
					end)
					assert(backend and backend.name == "git", failure)
				end)
				if release then
					release({ code = 0, stdout = "", stderr = "" })
				else
					jobs.cancel(function(job)
						return job.id == id
					end)
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_nonfile_uri_buffers_never_receive_backend_file_semantics",
			function()
				for _, name in ipairs({
					"zipfile:///tmp/archive.zip::sample.txt",
					"scp://host/path",
					"https://example.test/file",
				}) do
					local buf = vim.api.nvim_create_buf(true, false)
					vim.api.nvim_buf_set_name(buf, name)
					assert(not require("lazyvcs.util").is_real_file_buffer(buf), name)
					vim.api.nvim_buf_delete(buf, { force = true })
				end
				local buf = vim.api.nvim_create_buf(true, false)
				vim.api.nvim_buf_set_name(buf, h.tempdir() .. "/archive.tar::member")
				vim.b[buf].tarfile = "archive.tar"
				assert(not require("lazyvcs.util").is_real_file_buffer(buf))
				vim.api.nvim_buf_delete(buf, { force = true })
			end,
		},
		{
			"test_core_resolution_absence_is_concise_and_real_errors_survive",
			function()
				local backends, git, svn =
					require("lazyvcs.backends"), require("lazyvcs.backends.git"), require("lazyvcs.backends.svn")
				local gp, sp = git.probe_async, svn.probe_async
				local dir = h.tempdir()
				local git_error = "fatal: not a git repository (or any parent): .git"
				---@diagnostic disable-next-line: duplicate-set-field
				git.probe_async = function(_, done)
					done(nil, git_error)
					return {}
				end
				---@diagnostic disable-next-line: duplicate-set-field
				svn.probe_async = function(_, done)
					done(nil, "svn executable not found")
					return {}
				end
				local ok, err = pcall(function()
					backends.invalidate()
					local backend, _, failure = await(function(done)
						backends.resolve_async(dir, done)
					end)
					assert(not backend and failure == "No Git or SVN working copy found for " .. dir, failure)
					git_error = "fatal: detected dubious ownership in repository"
					backends.invalidate()
					_, _, failure = await(function(done)
						backends.resolve_async(dir, done)
					end)
					assert(failure:find("dubious ownership", 1, true), failure)
				end)
				git.probe_async, svn.probe_async = gp, sp
				backends.invalidate()
				assert(ok, err)
			end,
		},
		{
			"test_svn_compare_repeated_deletions_collapse_before_replacement",
			function()
				local common = require("lazyvcs.backends.comparison")
				local original = common.command
				local dir = h.tempdir()
				local url = "file:///comparison"
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(_, _, args, done)
					if vim.tbl_contains(args, "--summarize") then
						local record = '<path kind="file" item="deleted" props="none">' .. url .. "/node</path>"
						done(
							"<diff><paths>"
								.. record
								.. record
								.. '<path kind="dir" item="added" props="none">'
								.. url
								.. "/node</path></paths></diff>"
						)
					elseif vim.tbl_contains(args, "status") then
						done("<status/>")
					else
						error("unexpected command")
					end
				end
				local ok, err = pcall(function()
					local items, failure = await(function(done)
						require("lazyvcs.backends.compare_svn").list(
							{ root = dir, url = url, revision = "1" },
							false,
							done
						)
					end)
					assert(items and #items == 1 and items[1].status == "R", failure)
				end)
				common.command = original
				assert(ok, err)
			end,
		},
		{
			"test_source_control_copilotchat_deadline_sweep_removes_owned_and_releasing_files",
			function()
				local files = require("lazyvcs.source_control.copilotchat_files")
				local path = h.tempdir() .. "/private-body"
				h.write_file(path, "PRIVATE")
				local registry = files.new()
				registry:record(path)
				registry:adopt({ body = path })
				registry:abandon()
				assert(not vim.uv.fs_lstat(path))
				path = h.tempdir() .. "/pending-body"
				h.write_file(path, "PRIVATE")
				registry = files.new()
				registry:record(path)
				registry:adopt({ body = path })
				local lstat = vim.uv.fs_lstat
				local pending
				vim.uv.fs_lstat = function(name, done)
					if done then
						pending = done
						return {}
					end
					return lstat(name)
				end
				local finished
				local ok, err = pcall(function()
					registry:release(function()
						finished = true
					end)
					assert(pending)
					registry:abandon()
					assert(not lstat(path))
					pending("ENOENT: swept")
					assert(finished)
				end)
				vim.uv.fs_lstat = lstat
				assert(ok, err)
			end,
		},
		{
			"test_core_compare_preview_size_errors_name_the_oversized_side",
			function()
				for _, vcs in ipairs({ "git", "svn" }) do
					if vcs == "svn" and vim.fn.executable("svn") ~= 1 then
						break
					end
					local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
					h.write_file(f.file, string.rep("x", 2 * 1024 * 1024 + 1) .. "\n")
					h.exec(
						vcs == "git" and { "git", "commit", "-am", "oversized" }
							or { "svn", "commit", "-m", "oversized", f.file },
						f.root
					)
					local provider = require("lazyvcs.backends.compare_" .. vcs)
					local snapshot = vcs == "git"
							and {
								root = f.root,
								revision = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root)),
								base = "HEAD",
							}
						or { root = f.root, url = h.file_url(f.repo), revision = "2" }
					local result, err = await(function(done)
						provider.preview(snapshot, { relpath = "sample.txt", status = "M" }, done)
					end)
					assert(not result and err == "Base preview: File exceeds the 1 MiB preview limit", err)
					h.write_file(f.root .. "/untracked.txt", string.rep("y", 1024 * 1024 + 1))
					result, err = await(function(done)
						provider.preview(snapshot, { relpath = "untracked.txt", status = "?", untracked = true }, done)
					end)
					assert(not result and err == "Saved preview: File exceeds the 1 MiB preview limit", err)
				end
			end,
		},
		{
			"test_core_minitest_direct_entry_preserves_inherited_decoy_repository",
			function()
				local mini = vim.env.MINI_TEST_PATH or root .. "/deps/mini.nvim-v0.18.0"
				if vim.fn.filereadable(mini .. "/lua/mini/test.lua") ~= 1 then
					error({ lazyvcs_skip = "pinned mini.nvim unavailable" }, 0)
				end
				for _, bare in ipairs({ false, true }) do
					local f = h.make_git_fixture()
					local directory = f.root .. "/.git"
					if bare then
						directory = h.tempdir() .. "/bare.git"
						h.exec({ "git", "clone", "--bare", f.root, directory }, f.root)
					end
					local config = vim.fn.readfile(directory .. "/config", "b")
					local head = vim.fn.readfile(directory .. "/HEAD", "b")
					local index = not bare and vim.fn.readfile(directory .. "/index", "b")
					local result = vim.system({
						vim.v.progpath,
						"--headless",
						"-u",
						"NONE",
						"-i",
						"NONE",
						"-l",
						root .. "/tests/minitest.lua",
					}, {
						text = true,
						cwd = root,
						env = {
							MINI_TEST_PATH = mini,
							GIT_DIR = directory,
							GIT_WORK_TREE = f.root,
							GIT_INDEX_FILE = directory .. "/index",
							GIT_CONFIG_COUNT = "1",
							GIT_CONFIG_KEY_0 = "user.name",
							GIT_CONFIG_VALUE_0 = "inherited",
						},
					}):wait(120000)
					assert(
						vim.deep_equal(config, vim.fn.readfile(directory .. "/config", "b")),
						"MiniTest changed decoy config"
					)
					assert(
						vim.deep_equal(head, vim.fn.readfile(directory .. "/HEAD", "b")),
						"MiniTest changed decoy HEAD"
					)
					if index then
						assert(
							vim.deep_equal(index, vim.fn.readfile(directory .. "/index", "b")),
							"MiniTest changed decoy index"
						)
					end
					assert(
						result.code == 0 and (result.signal or 0) == 0,
						(result.stdout or "") .. (result.stderr or "")
					)
				end
			end,
		},
		{
			"test_svn_untracked_external_ignore_rules_stop_at_external_root",
			function()
				local parent, external = h.make_svn_fixture(), h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:global-ignores", "parent-only", parent.root }, parent.root)
				h.exec({ "svn", "propset", "svn:global-ignores", "external-only", external.root }, external.root)
				h.exec({ "svn", "commit", "-m", "ignore properties", external.root }, external.root)
				local external_url = h.file_url(external.repo)
				h.exec({ "svn", "propset", "svn:externals", "ext " .. external_url, parent.root }, parent.root)
				h.exec({ "svn", "update", parent.root }, parent.root)
				h.write_file(parent.root .. "/ext/external-only", "hidden\n")
				h.write_file(parent.root .. "/ext/parent-only", "visible\n")
				local status = h.exec({ "svn", "status", "--xml", parent.root }, parent.root)
				local entries = require("lazyvcs.backends.xml").parse_status(status)
				local common = require("lazyvcs.backends.comparison")
				local value, err = await(function(done)
					require("lazyvcs.backends.svn_untracked").expand(
						common.task(),
						{ root = parent.root },
						entries,
						done
					)
				end)
				assert(value, err)
				assert(
					vim.tbl_contains(value, "ext/parent-only"),
					"parent ignore leaked into external: " .. vim.inspect(value)
				)
				assert(
					not vim.tbl_contains(value, "ext/external-only"),
					"external ignore missing: " .. vim.inspect(value)
				)
			end,
		},
		{
			"test_blame_mapping_keeps_attribution_exact_with_ignored_whitespace",
			function()
				local previous = vim.o.diffopt
				vim.o.diffopt = previous .. ",iwhiteall,icase"
				local ok, err = pcall(function()
					local mapping = require("lazyvcs.backends.blame_mapping")
					local mapped = mapping.map({ "committed" }, { "original" }, { " ORIGINAL " }, "uncommitted")
					assert(mapped[1] == "uncommitted")
					mapped = mapping.map(
						{ "committed" },
						{ lines = { "original" }, eol = true, empty = false },
						{ lines = { " ORIGINAL " }, eol = true, empty = false },
						"uncommitted"
					)
					assert(mapped[1] == "uncommitted")
				end)
				vim.o.diffopt = previous
				assert(ok, err)
			end,
		},
		{
			"test_core_git_successful_hook_pipe_holder_survives_output_deadline",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX background hook" }, 0)
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "core.hooksPath", f.root .. "/.git/hooks" }, f.root)
				h.exec({ "git", "add", "sample.txt" }, f.root)
				h.write_file(
					f.root .. "/.git/hooks/post-commit",
					'#!/bin/sh\nsleep 60 &\necho $! > "' .. f.root .. '/helper.pid"\n'
				)
				assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/post-commit", 493))
				local process = require("process_helpers")
				process.guarded(f.root, function()
					local result, err = await(function(done)
						require("lazyvcs.util").system_start(
							{ "git", "commit", "-m", "quiet background" },
							{ cwd = f.root, scope = "mutation", timeout_ms = 400, kill_grace_ms = 30 },
							done
						)
					end)
					assert(result and result.code == 0, err)
					assert(process.alive(process.pid(f.root .. "/helper.pid")), "successful hook helper was killed")
				end)
			end,
		},
		{
			"test_core_absolute_resolution_cache_survives_directory_changes",
			function()
				local backends, git, svn =
					require("lazyvcs.backends"), require("lazyvcs.backends.git"), require("lazyvcs.backends.svn")
				local f = h.make_git_fixture()
				local gp, sp, cwd, calls = git.probe_async, svn.probe_async, assert(vim.uv.cwd()), 0
				---@diagnostic disable-next-line: duplicate-set-field
				git.probe_async = function(_, done)
					calls = calls + 1
					done({ root = f.root })
					return {}
				end
				---@diagnostic disable-next-line: duplicate-set-field
				svn.probe_async = function(_, done)
					done(nil, "svn executable not found")
					return {}
				end
				local ok, err = pcall(function()
					backends.invalidate()
					assert(await(function(done)
						backends.resolve_async(f.file, done)
					end) == git)
					vim.fn.chdir(h.tempdir())
					assert(await(function(done)
						backends.resolve_async(f.file, done)
					end) == git)
					assert(calls == 1, "DirChanged discarded a positive absolute resolution")
				end)
				git.probe_async, svn.probe_async = gp, sp
				vim.fn.chdir(cwd)
				backends.invalidate()
				assert(ok, err)
			end,
		},
		{
			"test_core_git_no_index_diff_keeps_literal_filename_arguments",
			function()
				local dir = h.tempdir()
				h.write_file(dir .. "/left file.txt", "left\n")
				h.write_file(dir .. "/right file.txt", "right\n")
				local result = require("lazyvcs.util").system_result(
					{ "git", "diff", "--no-index", "--", dir .. "/left file.txt", dir .. "/right file.txt" },
					{ cwd = dir }
				)
				assert(
					result.code == 1 and result.stdout:find("-left", 1, true) and result.stdout:find("+right", 1, true),
					result.stderr
				)
			end,
		},
		{
			"test_core_windows_git_mutation_cancel_keeps_and_reports_lock",
			function()
				local util, platform = require("lazyvcs.util"), require("lazyvcs.windows_process")
				local directory = h.tempdir()
				local lock = directory .. "/index.lock"
				h.write_file(lock, "foreign lock")
				local system, has, wrap = vim.system, vim.fn.has, platform.wrap
				local exited, closing, completed, logical, final_error, calls = nil, false, false, nil, nil, 0
				local handle
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				platform.wrap = function(args, opts)
					return args, opts
				end
				vim.system = function(args, opts, callback)
					if args[2] == "rev-parse" then
						opts.stdout(nil, lock .. "\n")
						vim.schedule(function()
							callback({ code = 0, stdout = "", stderr = "" })
						end)
						return {
							pid = 20,
							is_closing = function()
								return true
							end,
							kill = function() end,
						}
					end
					assert(args[2] == "commit")
					exited = callback
					return {
						pid = 10,
						is_closing = function()
							return closing
						end,
						kill = function() end,
					}
				end
				local ok, err = pcall(function()
					handle = util.system_start({ "git", "commit", "-m", "fixture" }, {
						cwd = directory,
						scope = "mutation",
						kill_grace_ms = 0,
						on_terminate = function(_, why)
							logical = why
						end,
					}, function(_, why)
						completed, final_error, calls = true, why, calls + 1
					end)
					assert(handle:cancel("test"))
					assert(logical and logical:find("locks", 1, true), "immediate cancellation omitted recovery advice")
					closing = true
					assert(exited)({ code = 137, signal = 9, stdout = "", stderr = "" })
					handle:force()
					ctx.wait_for(function()
						return completed
					end, "lock probe did not complete")
					assert(calls == 1 and tostring(final_error):find(lock, 1, true), final_error)
					assert(vim.uv.fs_lstat(lock), "cancellation deleted a foreign Git lock")
				end)
				vim.system, vim.fn.has, platform.wrap = system, has, wrap
				if handle then
					handle:close_timers()
				end
				assert(ok, err)
			end,
		},
	}
end
