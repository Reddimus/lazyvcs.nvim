return function(ctx)
	local h = ctx.helpers
	local backends = require("lazyvcs.backends")
	local function await(start)
		local done, value, failure
		start(function(result, err)
			value, failure, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "backend regression request", 15000)
		return assert(value, failure)
	end
	local function bytes(path, value)
		local file = assert(io.open(path, "wb"))
		file:write(value)
		file:close()
	end
	local function list(f, root)
		return await(function(done)
			require("lazyvcs.backends.compare_svn").list({
				root = root or f.root,
				vcs = "svn",
				url = h.file_url(f.repo),
				revision = "1",
			}, true, done)
		end)
	end
	local function paths(items, key)
		local result = {}
		for _, item in ipairs(items) do
			result[item[key or "relpath"]] = true
		end
		return result
	end
	local function completion(keys)
		require("lazyvcs.commands").setup()
		local result
		vim.api.nvim_create_autocmd("CmdlineLeave", {
			once = true,
			callback = function()
				result = vim.fn.getcmdline()
			end,
		})
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(":" .. keys .. "<Esc>", true, false, true), "xt", false)
		return result
	end
	local function svn_target(f, relpath, section)
		return await(function(done)
			require("lazyvcs.source_control.model").load_repo_details_async(
				{ root = f.root, vcs = "svn" },
				{ remote_refresh = section == "remote" },
				function(args, _, cb)
					return require("lazyvcs.util").system_start(args, { cwd = f.root }, cb)
				end,
				function(model, err)
					if not model then
						return done(nil, err)
					end
					for _, group in ipairs(model.sections) do
						for _, item in ipairs(group.items) do
							if group.id == section and item.extra.relpath == relpath then
								return done(item)
							end
						end
					end
					done(nil, "SVN status row missing: " .. relpath)
				end
			)
		end)
	end

	return {
		{
			"test_svn_local_previews_open_without_repository_access",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "properties", "removed-dir" }, f.root)
				h.exec({ "svn", "propset", "custom", "old directory value", "removed-dir" }, f.root)
				for _, name in ipairs({ "deleted.txt", "missing.txt" }) do
					h.write_file(f.root .. "/" .. name, "pristine " .. name)
					h.exec({ "svn", "add", name }, f.root)
				end
				h.exec({ "svn", "commit", "-m", "offline preview bases" }, f.root)
				h.write_file(f.file, "local edit")
				h.exec({ "svn", "delete", "deleted.txt", "removed-dir" }, f.root)
				vim.fn.delete(f.root .. "/missing.txt")
				h.write_file(f.root .. "/added.txt", "local addition")
				h.exec({ "svn", "add", "added.txt" }, f.root)
				h.write_file(f.root .. "/untracked.txt", "local untracked")
				h.exec({ "svn", "propset", "custom", "local directory value", "properties" }, f.root)
				h.exec({ "svn", "mkdir", "newdir" }, f.root)
				h.exec({ "svn", "propset", "custom", "added directory value", "newdir" }, f.root)
				local targets = {}
				for _, name in ipairs({
					"sample.txt",
					"deleted.txt",
					"missing.txt",
					"added.txt",
					"untracked.txt",
					"properties",
					"removed-dir",
					"newdir",
				}) do
					targets[#targets + 1] = svn_target(f, name, name == "untracked.txt" and "untracked" or "changes")
				end
				-- The checkout retains its original file:// URL, which no longer exists.
				assert(vim.uv.fs_rename(f.repo, h.tempdir() .. "/offline-repo"))
				assert(not vim.uv.fs_stat(f.repo))
				local actions = require("lazyvcs.actions")
				for _, target in ipairs(targets) do
					local value = await(function(done)
						backends.load_diff_target_async(target, done)
					end)
					local session = assert(actions.open_target(value))
					assert(vim.api.nvim_win_is_valid(session.editable_win), "local preview did not open")
					if target.relpath == "sample.txt" then
						assert(vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false)[2] == "changed")
						assert(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false)[1] == "local edit")
					elseif target.relpath == "deleted.txt" or target.relpath == "missing.txt" then
						assert(value.left.lines[1] == "pristine " .. target.relpath)
					elseif
						target.relpath == "properties"
						or target.relpath == "removed-dir"
						or target.relpath == "newdir"
					then
						assert(value.property_only and #value.property_patch.lines > 0)
					end
					actions.close(session)
				end
			end,
		},
		{
			"test_live_diff_git_async_ancestor_discovery_never_walks_synchronously",
			function()
				local f = h.make_git_fixture()
				local path = f.root .. "/gone/deep/more/file.txt"
				local git, process = require("lazyvcs.backends.git"), require("lazyvcs.backends.process")
				local uv = vim.uv
				local stat, lstat, root = uv.fs_stat, uv.fs_lstat, process.root
				local walking, sync_calls, async_calls = false, 0, 0
				for name, original in pairs({ fs_stat = stat, fs_lstat = lstat }) do
					uv[name] = function(candidate, cb)
						if walking then
							if cb then
								async_calls = async_calls + 1
							else
								sync_calls = sync_calls + 1
							end
						end
						return original(candidate, cb)
					end
				end
				---@diagnostic disable-next-line: duplicate-set-field
				process.root = function(...)
					walking = false
					return root(...)
				end
				local ok, err = pcall(function()
					for _, start in ipairs({ git.probe_async, git.load_async, git.load_base_async }) do
						walking = true
						local value = await(function(done)
							start(path, done)
						end)
						assert(value.root == f.root)
					end
					assert(sync_calls == 0, "async discovery made " .. sync_calls .. " synchronous filesystem calls")
					assert(async_calls >= 12, "missing ancestors were not discovered asynchronously")
				end)
				uv.fs_stat, uv.fs_lstat, process.root = stat, lstat, root
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_git_async_ancestor_discovery_cancellation",
			function()
				local f = h.make_git_fixture()
				local path = f.root .. "/gone/deep/file.txt"
				local git, process = require("lazyvcs.backends.git"), require("lazyvcs.backends.process")
				local uv = vim.uv
				local stat, lstat, root = uv.fs_stat, uv.fs_lstat, process.root
				local ok, err = pcall(function()
					for _, held in ipairs({ "fs_stat", "fs_lstat" }) do
						local pending, calls, published, spawned = nil, 0, false, false
						for name, original in pairs({ fs_stat = stat, fs_lstat = lstat }) do
							uv[name] = function(candidate, cb)
								calls = calls + 1
								if name == held and cb then
									pending = cb
									return
								end
								return original(candidate, cb)
							end
						end
						---@diagnostic disable-next-line: duplicate-set-field
						process.root = function(...)
							spawned = true
							return root(...)
						end
						local task = git.probe_async(path, function()
							published = true
						end)
						ctx.wait_for(function()
							return pending
						end, "async ancestor request was not issued")
						task:kill()
						local before = calls
						assert(pending)("ENOENT: missing path")
						vim.wait(50, function()
							return false
						end)
						assert(calls == before and not spawned and not published, "cancelled discovery continued")
					end
				end)
				uv.fs_stat, uv.fs_lstat, process.root = stat, lstat, root
				assert(ok, err)
			end,
		},
		{
			"test_core_completion_abbreviated_commands_keep_argument_context",
			function()
				local dir = h.tempdir()
				vim.fn.mkdir(dir .. "/open space")
				local escape = require("lazyvcs.command_path").escape
				for _, command in ipairs({ "L", "Lazy", "LazyV", "LazyVC", "LazyVCS" }) do
					for _, prefix in ipairs({ "", "silent ", "vertical silent ", "1,2", "'L ", "'L,'M " }) do
						local line = prefix .. command
						assert(
							completion(line .. " blame sp<Tab>") == line .. " blame split",
							"abbreviated blame: " .. line
						)
						assert(
							completion(line .. " sidebar op<Tab>") == line .. " sidebar open",
							"abbreviated sidebar: " .. line
						)
						assert(
							completion(line .. " sidebar " .. dir .. "/op<Tab>")
								== line .. " sidebar " .. escape(dir .. "/open space/")
						)
					end
				end
			end,
		},
		{
			"test_core_completion_sidebar_shorthand_directories",
			function()
				local dir = h.tempdir()
				vim.fn.mkdir(dir .. "/open space")
				local lead = dir .. "/op"
				local expected = require("lazyvcs.command_path").escape(dir .. "/open space/")
				local found = require("lazyvcs.commands")._complete(lead, "LazyVCS sidebar " .. lead)
				assert(vim.tbl_contains(found, expected), "shorthand directory candidate missing")
				assert(vim.tbl_contains(require("lazyvcs.commands")._complete("op", "LazyVCS sidebar op"), "open"))
				assert(completion("LazyVCS sidebar " .. lead .. "<Tab>") == "LazyVCS sidebar " .. expected)
			end,
		},
		{
			"test_core_completion_earlier_argument_preserves_suffix",
			function()
				assert(
					completion(
						"LazyVCS bl split<Home><Right><Right><Right><Right><Right><Right><Right><Right><Right><Right><Tab>"
					) == "LazyVCS blame split",
					"earlier argument did not complete"
				)
				local dir = h.tempdir()
				vim.fn.mkdir(dir .. "/space dir")
				local path = require("lazyvcs.command_path").escape(dir .. "/space dir/")
				assert(
					completion("LazyVCS sidebar op " .. path .. "<Home>" .. string.rep("<Right>", 18) .. "<Tab>")
						== "LazyVCS sidebar open " .. path,
					"verb completion changed escaped path suffix"
				)
			end,
		},
		{
			"test_core_completion_command_modifiers_and_ranges",
			function()
				for _, prefix in ipairs({ "silent ", "tab ", "vertical silent ", "1,2" }) do
					assert(
						completion(prefix .. "LazyVCS sid<Tab>") == prefix .. "LazyVCS sidebar",
						"completion lost command context: " .. prefix
					)
				end
			end,
		},
		{
			"test_core_completion_unicode_case_folding",
			function()
				local fic, wic, ignore = vim.o.fileignorecase, vim.o.wildignorecase, vim.o.wildignore
				local ok, err = pcall(function()
					local dir = h.tempdir()
					vim.fn.mkdir(dir .. "/Éclair")
					vim.fn.mkdir(dir .. "/Kelvin")
					vim.o.wildignore = ""
					for _, options in ipairs({ { true, false }, { false, true }, { false, false } }) do
						vim.o.fileignorecase, vim.o.wildignorecase = unpack(options)
						for _, pair in ipairs({ { "é", "Éclair" }, { "k", "Kelvin" } }) do
							local found = require("lazyvcs.commands")._complete(
								dir .. "/" .. pair[1],
								"LazyVCS sidebar open " .. dir .. "/" .. pair[1]
							)
							local expected = options[1] or options[2]
							assert((#found == 1) == expected, "Unicode case matching failed: " .. pair[2])
							if expected then
								assert(found[1] == dir .. "/" .. pair[2] .. "/")
							end
						end
					end
				end)
				vim.o.fileignorecase, vim.o.wildignorecase, vim.o.wildignore = fic, wic, ignore
				assert(ok, err)
			end,
		},
		{
			"test_core_keymap_literal_less_than_alias_collision",
			function()
				for _, pair in ipairs({ { "<lt>", "<" }, { "<", "<lt>" } }) do
					local ok = pcall(
						require("lazyvcs.config").setup,
						{ keymaps = { next_hunk = pair[1], prev_hunk = pair[2] } }
					)
					assert(not ok, "accepted duplicate <lt> and < mappings")
				end
			end,
		},
		{
			"test_core_profile_escapes_repository_control_characters",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "Windows filenames exclude newlines" })
				end
				local f, parent = h.make_git_fixture(), h.tempdir()
				local root = parent .. "/repo\nline\ttab"
				assert(vim.uv.fs_rename(f.root, root))
				local jobs = require("lazyvcs.source_control.jobs")
				jobs.clear_history()
				await(function(done)
					jobs.command({ root = root, vcs = "git" }, "buffer", { "git", "status", "--short" }, {}, done)
				end)
				require("lazyvcs.commands").setup()
				vim.cmd("LazyVCS profile")
				local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
				vim.cmd.close()
				assert(
					rendered:find(require("lazyvcs.source_control.display").label(root), 1, true),
					"escaped root missing"
				)
				assert(jobs.history()[1].root == root, "profile changed raw history root")
			end,
		},
		{
			"test_core_preview_skips_unloaded_encoding_candidates",
			function()
				local f, bufs = h.make_git_fixture(), {}
				for i = 1, 32 do
					bufs[#bufs + 1] = vim.fn.bufadd(f.root .. "/unloaded-" .. i)
				end
				local util = require("lazyvcs.util")
				local canonical, calls = util.canonical_path, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.canonical_path = function(path)
					if path and path:find("/unloaded-", 1, true) then
						calls = calls + 1
					end
					return canonical(path)
				end
				local ok, err = pcall(function()
					local revision = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
					local value = await(function(done)
						require("lazyvcs.backends.compare_git").preview(
							{ root = f.root, vcs = "git", base = "HEAD", revision = revision },
							{ relpath = "sample.txt", status = "M" },
							done
						)
					end)
					assert(value.right[2] == "changed")
					assert(calls == 0, "canonicalized unloaded buffers " .. calls .. " times")
				end)
				util.canonical_path = canonical
				for _, buf in ipairs(bufs) do
					vim.api.nvim_buf_delete(buf, { force = true })
				end
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_git_deleted_parent_directories_resolve",
			function()
				local f = h.make_git_fixture()
				vim.fn.mkdir(f.root .. "/nested/deep", "p")
				local path = f.root .. "/nested/deep/file.txt"
				h.write_file(path, "original")
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "nested" }, f.root)
				vim.fn.delete(f.root .. "/nested", "rf")
				backends.invalidate()
				local payload = await(function(done)
					backends.load_base_async(path, done)
				end)
				assert(payload.base_bytes == "original\n")
				local git = require("lazyvcs.backends.git")
				assert(git.probe(path).root == f.root, "sync discovery lost deleted entry")
				assert(await(function(done)
					git.load_base_async(path, done)
				end).base_bytes == "original\n", "unhinted loader lost deleted entry")
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				vim.cmd.edit(vim.fn.fnameescape(path))
				vim.cmd("LazyVCS diff open")
				ctx.wait_for(function()
					return require("lazyvcs.state").get(vim.fn.bufnr(path))
				end, "deleted file live diff", 15000)
			end,
		},
		{
			"test_live_diff_staged_final_newlines_and_refresh",
			function()
				local f = h.make_git_fixture()
				local actions = require("lazyvcs.actions")
				for _, pair in ipairs({
					{ "same\n", "same" },
					{ "same", "same\n" },
					{ "", "\n" },
					{ "same\r\n", "same\n" },
					{ "same\n", "\239\187\191same\n" },
				}) do
					bytes(f.file, pair[1])
					h.exec({ "git", "add", "." }, f.root)
					h.exec({ "git", "commit", "--allow-empty", "-m", "newline base" }, f.root)
					bytes(f.file, pair[2])
					h.exec({ "git", "add", "." }, f.root)
					local target =
						{ vcs = "git", root = f.root, relpath = "sample.txt", section = "staged", status = "M" }
					local result = await(function(done)
						backends.load_diff_target_async(target, done)
					end)
					local session = assert(actions.open_target(result))
					assert(#session.hunks == 1, "staged byte change disappeared from hunks")
					assert(vim.bo[session.base_bufnr].endofline == (pair[1]:sub(-1) == "\n"))
					assert(vim.bo[session.editable_bufnr].endofline == (pair[2]:sub(-1) == "\n"))
					if pair[1] == "same\n" and pair[2] == "same" then
						local marks =
							vim.api.nvim_buf_get_extmarks(session.editable_bufnr, -1, 0, -1, { details = true })
						assert(vim.inspect(marks):find("No newline", 1, true), "missing visible EOF indication")
						bytes(f.file, pair[1])
						h.exec({ "git", "add", "." }, f.root)
						actions.refresh_current()
						ctx.wait_for(function()
							return not session.refresh_job and #session.hunks == 0
						end, "staged EOF refresh", 15000)
						assert(vim.bo[session.editable_bufnr].endofline, "refresh lost EOF options")
					end
					actions.close(session)
				end
			end,
		},
		{
			"test_svn_compare_excludes_directory_external_untracked_files",
			function()
				local f, external = h.make_svn_fixture(), h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:externals", h.file_url(external.repo) .. " ext", "." }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.write_file(f.root .. "/ext/local.txt", "external")
				h.write_file(f.root .. "/ext/sample.txt", "changed external")
				h.write_file(f.root .. "/local.txt", "parent")
				local found = paths(list(f))
				assert(not found["ext/local.txt"], "parent Compare included external untracked file")
				assert(not found["ext/sample.txt"] and found["sample.txt"] and found["local.txt"])
				local own = paths(list(external, f.root .. "/ext"))
				assert(own["local.txt"] and own["sample.txt"], "external cannot review its own changes")
			end,
		},
		{
			"test_svn_ignore_property_preserves_pattern_whitespace",
			function()
				local f = h.make_svn_fixture()
				h.exec({
					"svn",
					"propset",
					"svn:global-ignores",
					" leading\nmiddle space\ntrailing \n\ttab\nordinary*\n",
					".",
				}, f.root)
				vim.fn.mkdir(f.root .. "/new")
				for _, name in ipairs({
					" leading",
					"leading",
					"middle space",
					"middlespace",
					"trailing",
					"tab",
					"ordinary.txt",
				}) do
					h.write_file(f.root .. "/new/" .. name, "new")
				end
				local found = paths(list(f))
				assert(
					found["new/leading"] and found["new/middlespace"] and found["new/trailing"] and found["new/tab"],
					"significant whitespace hid visible files"
				)
				assert(not found["new/ leading"] and not found["new/middle space"] and not found["new/ordinary.txt"])
			end,
		},
		{
			"test_svn_ignore_base64_local_inherited_and_switched_properties",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "sub", "branch", "branch/sub" }, f.root)
				local prop = h.tempdir() .. "/property"
				bytes(prop, "control\1pattern\n*.encoded\n")
				h.exec({ "svn", "propset", "svn:global-ignores", "-F", prop, "." }, f.root)
				h.exec({ "svn", "propset", "svn:global-ignores", "-F", prop, "branch" }, f.root)
				h.exec({ "svn", "commit", "-m", "encoded ignore properties" }, f.root)
				h.exec({ "svn", "switch", h.file_url(f.repo) .. "/branch/sub", "sub", "--ignore-ancestry" }, f.root)
				for _, dir in ipairs({ "new", "sub/new" }) do
					vim.fn.mkdir(f.root .. "/" .. dir, "p")
					h.write_file(f.root .. "/" .. dir .. "/hidden.encoded", "hidden")
					h.write_file(f.root .. "/" .. dir .. "/visible.txt", "visible")
				end
				local found = paths(list(f))
				assert(
					not found["new/hidden.encoded"] and not found["sub/new/hidden.encoded"],
					"base64 ignore rules were lost"
				)
				assert(found["new/visible.txt"] and found["sub/new/visible.txt"])
				local inherited = paths(list(f, f.root .. "/sub"))
				assert(
					not inherited["new/hidden.encoded"] and inherited["new/visible.txt"],
					"inherited base64 ignore rules were lost"
				)
			end,
		},
		{
			"test_svn_ignore_undefined_configuration_references_are_literal",
			function()
				local f, config_dir = h.make_svn_fixture(), h.tempdir()
				---@type table
				local uv = vim.uv
				local realpath, start = uv.fs_realpath, require("lazyvcs.util").system_start
				bytes(
					config_dir .. "/config",
					"[miscellany]\nknown = *.known\nglobal-ignores = %(known)s %(missing)s\n"
				)
				vim.fn.mkdir(f.root .. "/new")
				for _, name in ipairs({ "%(missing)s", "hidden.known", "visible.txt" }) do
					h.write_file(f.root .. "/new/" .. name, "new")
				end
				local normalize = require("lazyvcs.util").normalize_literal_path
				local config_paths = {}
				for _, path in ipairs({
					"/etc/subversion/config",
					vim.fn.expand("~/.subversion/config"),
					(vim.env.PROGRAMDATA or "C:/ProgramData") .. "/Subversion/config",
					(vim.env.APPDATA or vim.fn.expand("~")) .. "/Subversion/config",
				}) do
					config_paths[normalize(path):lower()] = true
				end
				---@diagnostic disable-next-line: duplicate-set-field
				uv.fs_realpath = function(path, cb)
					if cb and config_paths[normalize(path):lower()] then
						return realpath(config_dir .. "/config", cb)
					end
					return realpath(path, cb)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				require("lazyvcs.util").system_start = function(args, ...)
					if args[1] == "svn" then
						args = vim.deepcopy(args)
						table.insert(args, 2, "--config-dir")
						table.insert(args, 3, config_dir)
					end
					return start(args, ...)
				end
				local ok, err = pcall(function()
					for _, configured in ipairs({ "%(missing)s", "%(known)s %(missing)s" }) do
						bytes(
							config_dir .. "/config",
							"[miscellany]\nknown = *.known\nglobal-ignores = " .. configured .. "\n"
						)
						local found = paths(list(f))
						assert(found["new/visible.txt"] and not found["new/%(missing)s"])
						assert((found["new/hidden.known"] == true) == (configured == "%(missing)s"))
					end
				end)
				uv.fs_realpath, require("lazyvcs.util").system_start = realpath, start
				assert(ok, err)
			end,
		},
		{
			"test_svn_files_picker_expands_unversioned_directories",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:global-ignores", "*.hidden", "." }, f.root)
				h.exec({ "svn", "mkdir", "properties" }, f.root)
				h.exec({ "svn", "propset", "custom", "value", "properties" }, f.root)
				vim.fn.mkdir(f.root .. "/new/deep", "p")
				for _, path in ipairs({ "new/one.txt", "new/deep/two.txt", "new/skip.hidden" }) do
					h.write_file(f.root .. "/" .. path, "new")
				end
				local found = paths(
					await(function(done)
						backends.changed_files_async(f.root, done)
					end),
					"path"
				)
				assert(found["new/one.txt"] and found["new/deep/two.txt"], "picker omitted unversioned descendants")
				assert(
					not found.new and not found["new/skip.hidden"] and found.properties,
					"picker lost ignore or versioned directory semantics"
				)
			end,
		},
		{
			"test_svn_sidebar_added_directory_property_previews",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "newdir" }, f.root)
				h.exec({ "svn", "propset", "custom", "directory value", "newdir" }, f.root)
				local target = svn_target(f, "newdir", "changes")
				local value = await(function(done)
					backends.load_diff_target_async(assert(target), done)
				end)
				assert(value.property_only and not value.editable_side)
				assert(table.concat(value.property_patch.lines, "\n"):find("+directory value", 1, true))
			end,
		},
		{
			"test_svn_sidebar_incoming_directory_property_previews",
			function()
				local f = h.make_svn_update_fixture()
				h.exec({ "svn", "mkdir", "incoming" }, f.peer)
				h.exec({ "svn", "propset", "custom", "incoming value", "incoming" }, f.peer)
				h.exec({ "svn", "commit", "-m", "incoming directory", "incoming" }, f.peer)
				local target = svn_target(f, "incoming", "remote")
				local value = await(function(done)
					backends.load_diff_target_async(assert(target), done)
				end)
				assert(value.property_only and not value.editable_side)
				assert(table.concat(value.property_patch.lines, "\n"):find("+incoming value", 1, true))
			end,
		},
		{
			"test_live_diff_git_discovery_rejects_obstructed_ancestors",
			function()
				local f = h.make_git_fixture()
				local util = require("lazyvcs.util")
				local path = f.root .. "/blocked/deep/file.txt"
				h.write_file(f.root .. "/blocked", "file obstruction")
				local function rejected(cwd, err)
					-- Windows can report ENOENT for blocked descendants, then find
					-- the obstructing file itself. The error spelling is platform-specific.
					assert(not cwd and err, "discovery skipped non-directory obstruction")
				end
				rejected(util.existing_directory(path))
				local done
				util.existing_directory_async(path, function(cwd, err)
					rejected(cwd, err)
					done = true
				end)
				ctx.wait_for(function()
					return done
				end, "async obstruction check")
			end,
		},
		{
			"test_live_diff_git_discovery_rejects_dangling_symlink_ancestors",
			function()
				local f = h.make_git_fixture()
				local linked, link_err = vim.uv.fs_symlink(f.root .. "/absent", f.root .. "/blocked", { dir = true })
				if not linked then
					error({ lazyvcs_skip = "Directory symlinks unavailable: " .. tostring(link_err) })
				end
				local util = require("lazyvcs.util")
				local path = f.root .. "/blocked/deep/file.txt"
				local cwd, err = util.existing_directory(path)
				assert(not cwd and err, "discovery skipped dangling directory symlink")
				local done
				util.existing_directory_async(path, function(dir, failure)
					assert(not dir and failure, "async discovery skipped dangling directory symlink")
					done = true
				end)
				ctx.wait_for(function()
					return done
				end, "async symlink obstruction check")
			end,
		},
		{
			"test_svn_sidebar_directory_deletion_and_kind_replacements",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "removed", "tofile" }, f.root)
				h.exec({ "svn", "propset", "custom", "old directory value", "removed" }, f.root)
				h.write_file(f.root .. "/todir", "old file content")
				h.exec({ "svn", "add", "todir" }, f.root)
				h.exec({ "svn", "commit", "-m", "replacement bases" }, f.root)
				h.exec({ "svn", "delete", "removed", "tofile", "todir" }, f.root)
				h.write_file(f.root .. "/tofile", "new file content")
				h.exec({ "svn", "mkdir", "todir" }, f.root)
				h.exec({ "svn", "add", "tofile" }, f.root)
				for _, path in ipairs({ "removed", "tofile", "todir" }) do
					local target = svn_target(f, path, "changes")
					local value = await(function(done)
						backends.load_diff_target_async(target, done)
					end)
					if path == "removed" then
						assert(
							value.property_only
								and table.concat(value.property_patch.lines, "\n"):find("-old directory value", 1, true)
						)
					elseif path == "tofile" then
						assert(
							value.right.lines and value.right.lines[1] == "new file content",
							"directory replacement lost new file contents: " .. vim.inspect(value)
						)
					else
						assert(value.left.lines[1] == "old file content", "file replacement lost base contents")
					end
				end
			end,
		},
		{
			"test_svn_untracked_traversal_cancellation",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/new/deep", "p")
				h.write_file(f.root .. "/new/deep/file.txt", "new")

				local common = require("lazyvcs.backends.comparison")
				local called = false
				local task = common.task()
				require("lazyvcs.backends.svn_untracked").expand(task, { root = f.root, vcs = "svn" }, {
					{ path = "new", wc_item = "unversioned" },
				}, function()
					called = true
				end)
				task:kill()
				vim.wait(100, function()
					return false
				end)
				assert(not called, "cancelled traversal published a result")
			end,
		},
		{
			"test_svn_untracked_traversal_does_not_follow_symlinks",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/new/deep", "p")
				h.write_file(f.root .. "/new/deep/file.txt", "new")
				local linked, link_err = vim.uv.fs_symlink(f.root .. "/new", f.root .. "/new/deep/loop", { dir = true })
				if not linked then
					error({ lazyvcs_skip = "Directory symlinks unavailable: " .. tostring(link_err) })
				end
				local found = paths(
					await(function(done)
						backends.changed_files_async(f.root, done)
					end),
					"path"
				)
				assert(
					found["new/deep/loop"] and not found["new/deep/loop/deep/file.txt"],
					"traversal followed directory symlink"
				)
			end,
		},
		{
			"test_svn_sidebar_incoming_directory_deletion_properties",
			function()
				local f = h.make_svn_update_fixture()
				h.exec({ "svn", "mkdir", "removed" }, f.peer)
				h.exec({ "svn", "propset", "custom", "removed value", "removed" }, f.peer)
				h.exec({ "svn", "commit", "-m", "directory base", "removed" }, f.peer)
				h.exec({ "svn", "update" }, f.root)
				h.exec({ "svn", "delete", "removed" }, f.peer)
				h.exec({ "svn", "commit", "-m", "directory deletion", "removed" }, f.peer)
				local target = svn_target(f, "removed", "remote")
				local value = await(function(done)
					backends.load_diff_target_async(target, done)
				end)
				assert(value.property_only and not value.editable_side)
				assert(table.concat(value.property_patch.lines, "\n"):find("-removed value", 1, true))
			end,
		},
	}
end
