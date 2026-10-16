return function(ctx)
	local h = ctx.helpers
	local function await(start)
		local result, err, done
		start(function(value, failure)
			result, err, done = value, failure, true
		end)
		ctx.wait_for(function()
			return done
		end, "backend read did not complete", 15000)
		return assert(result, err)
	end
	local function load(f, path, extra)
		return await(function(cb)
			require("lazyvcs.backends").load_diff_target_async(
				vim.tbl_extend("force", {
					vcs = "svn",
					root = f.root,
					relpath = path,
					section = "changes",
				}, extra or {}),
				cb
			)
		end)
	end
	local function rendered(target)
		local actions = require("lazyvcs.actions")
		local session = assert(actions.open_target(target), "comparison did not open")
		local lines = vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false)
		actions.close(session.editable_bufnr)
		return table.concat(lines, "\n")
	end
	return {
		{
			"test_svn_revert_root_dash_path",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_svn_fixture()
				for _, name in ipairs({ "-notes.txt", "-notes@draft.txt" }) do
					local path = f.root .. "/" .. name
					h.write_file(path, "committed")
					h.exec({ "svn", "add", "--", name .. "@" }, f.root)
					h.exec({ "svn", "commit", "-m", "dash path", "--", name .. "@" }, f.root)
					h.write_file(path, "edited")
					assert(
						await(function(cb)
							require("lazyvcs.backends.svn").is_versioned_async(path, cb)
						end),
						"leading-dash path was not tracked"
					)
					vim.cmd.edit(vim.fn.fnameescape(path))
					local buf = vim.api.nvim_get_current_buf()
					local owner = assert(require("lazyvcs").revert_buffer())
					ctx.wait_for(function()
						return vim.bo.buftype == "nofile"
					end, "discard confirmation did not open", 15000)
					vim.fn.maparg("1", "n", false, true).callback()
					ctx.wait_for(function()
						return owner.active == false
					end, "discard did not finish", 15000)
					assert(vim.deep_equal(vim.fn.readfile(path), { "committed" }), "discard did not restore disk")
					assert(
						vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "committed" }),
						"discard did not reload buffer"
					)
				end
			end,
		},
		{
			"test_svn_source_control_remote_addition_collision",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "on_open" },
				})
				local f = h.make_svn_update_fixture()
				for _, name in ipairs({ "collision", "incoming" }) do
					h.write_file(f.peer .. "/" .. name, "REMOTE ONLY")
					h.exec({ "svn", "add", name }, f.peer)
				end
				h.exec({ "svn", "commit", "-m", "incoming additions" }, f.peer)
				h.write_file(f.root .. "/collision", "LOCAL ONLY")
				local native = require("lazyvcs.source_control.native")
				local s = native.open({ path = f.root })
				local ok, err = xpcall(function()
					ctx.wait_for(function()
						local status = s.lazyvcs_repo_cache[f.root]
						return status and not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
					end, "incoming rows did not load", 15000)
					local remote
					for _, section in ipairs(s.lazyvcs_repo_cache[f.root].sections) do
						if section.id == "remote" then
							remote = section
						end
					end
					local additions = 0
					for _, row in ipairs(assert(remote).items) do
						if row.extra.repos_item == "added" then
							additions = additions + 1
							local target =
								load(f, row.extra.relpath, vim.tbl_extend("force", row.extra, { section = "remote" }))
							assert(
								target.kind == "svn_remote" and not target.editable_side,
								"incoming collision opened as editable local content"
							)
							assert(#target.left.lines == 0 and table.concat(target.right.lines, "\n") == "REMOTE ONLY")
							assert(rendered(target) == "REMOTE ONLY")
						end
					end
					assert(additions == 2)
					local local_target = load(f, "collision", { section = "untracked", wc_item = "unversioned" })
					assert(local_target.kind == "svn_untracked" and local_target.editable_side == "right")
					assert(vim.deep_equal(vim.fn.readfile(f.root .. "/collision"), { "LOCAL ONLY" }))
				end, debug.traceback)
				native.close()
				assert(ok, err)
			end,
		},
		{
			"test_svn_windows_remote_url_uses_path_segments",
			function()
				local has = vim.fn.has
				local common = require("lazyvcs.backends.comparison")
				local command = common.command
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(feature)
					return feature == "win32" and 1 or has(feature)
				end
				local ok, err = pcall(function()
					local append = require("lazyvcs.backends.svn_url").append_path
					assert(
						append("file:///C:/escaped%20root", [[sub\a%20b\café#%.txt]])
							== "file:///C:/escaped%20root/sub/a%2520b/caf%C3%A9%23%25.txt",
						"Windows path separators were percent-encoded into a URL"
					)
					local called = false
					---@diagnostic disable-next-line: duplicate-set-field
					common.command = function(_, _, args, cb, opts)
						called = true
						assert(vim.tbl_contains(args, "--properties-only"))
						assert(
							args[#args - 2] == "file:///C:/escaped%20root/sub/a%2520b/caf%C3%A9%23%25.txt@1",
							"property loader bypassed normalized URL encoding"
						)
						assert(opts.output_limit_bytes == 2 * 1024 * 1024, "property patch lost its 1 MiB bound")
						cb("property patch\n")
					end
					local result = await(function(cb)
						require("lazyvcs.backends.compare_svn").preview(
							{ root = "C:/wc", url = "file:///C:/escaped%20root", revision = "1" },
							{ relpath = [[sub\a%20b\café#%.txt]], kind = "file", property_only = true },
							cb
						)
					end)
					assert(called and result.right[1] == "property patch")
				end)
				vim.fn.has, common.command = has, command
				assert(ok, err)
			end,
		},
		{
			"test_core_git_index_stage_zero_is_unambiguous",
			function()
				local f = h.make_git_fixture()
				local names = vim.fn.has("win32") == 1 and { "0-notes.txt", "2-notes.txt" }
					or { "0:notes.txt", "2:notes.txt" }
				for _, name in ipairs(vim.list_extend({ "notes.txt" }, names)) do
					h.write_file(f.root .. "/" .. name, name)
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "literal names" }, f.root)
				local git = require("lazyvcs.backends.git")
				-- Keep the ambiguous revision syntax covered even on NTFS.
				for _, name in ipairs({ "0:notes.txt", "2:notes.txt" }) do
					local target =
						assert(git.resolve_diff_target({ root = f.root, relpath = name, section = "staged" }))
					assert(target.right.source.object == ":0:" .. name)
				end
				for _, name in ipairs(names) do
					-- Ordinary bases already use immutable OIDs after revert-integrity.
					assert(git.load_base(f.root .. "/" .. name).base_bytes == name .. "\n")
					local base = await(function(cb)
						git.load_base_async(f.root .. "/" .. name, cb)
					end)
					assert(base.base_bytes == name .. "\n")
					local target = await(function(cb)
						git.load_diff_target_async({ root = f.root, relpath = name, section = "staged" }, cb)
					end)
					assert(table.concat(target.right.lines, "\n") == name, "staged preview read a different index path")
				end
			end,
		},
		{
			"test_svn_remote_preview_encodes_literal_paths",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)

				local names = {
					"a%20b.txt",
					"a b.txt",
					"%20.txt",
					" .txt",
					"café#%.txt",
					"nested/a%20b.txt",
					"nested/café#%.txt",
				}
				vim.fn.mkdir(f.root .. "/nested", "p")
				h.exec({ "svn", "add", "nested" }, f.root)
				for _, name in ipairs(names) do
					h.write_file(f.root .. "/" .. name, "base " .. name)
					h.exec({ "svn", "add", f.root .. "/" .. name }, f.root)
				end
				h.exec({ "svn", "commit", "-m", "add literal names" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				local other = h.tempdir() .. "/other"
				h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
				for _, name in ipairs(names) do
					h.write_file(other .. "/" .. name, "HEAD " .. name)
					-- Custom properties are opaque bytes. A file avoids svn.exe's
					-- native command-line encoding for non-ASCII property values.
					local property_file = h.tempdir() .. "/property"
					h.write_file(property_file, "property " .. name)
					h.exec({ "svn", "propset", "custom", "--file", property_file, other .. "/" .. name .. "@" }, other)
					assert(
						h.exec({ "svn", "propget", "--strict", "custom", other .. "/" .. name .. "@" }, other)
							== "property " .. name .. "\n",
						"fixture property bytes changed"
					)
				end
				h.exec({ "svn", "commit", "-m", "incoming content" }, other)
				h.write_file(other .. "/nested/new%20entry.txt", "incoming addition")
				h.exec({ "svn", "add", "nested/new%20entry.txt" }, other)
				h.exec({ "svn", "commit", "-m", "incoming addition" }, other)
				local raw = h.exec({ "svn", "status", "--xml", "-u" }, f.root)
				local entries = require("lazyvcs.backends.xml").parse_status(raw)
				local modified, added = 0, 0
				for _, entry in ipairs(entries) do
					if entry.repos_item == "added" then
						added = added + 1
						local target = load(f, entry.path, { section = "remote", repos_item = "added" })
						assert(
							table.concat(target.right.lines, "\n") == "incoming addition",
							"incoming addition URL fallback failed"
						)
					end
					if entry.repos_item == "modified" and vim.tbl_contains(names, entry.path) then
						modified = modified + 1
						local target = load(
							f,
							entry.path,
							{ section = "remote", repos_item = "modified", base_revision = entry.revision }
						)
						assert(
							table.concat(target.right.lines, "\n") == "HEAD " .. entry.path,
							"incoming URL selected another filename"
						)
						assert(rendered(target):find("HEAD " .. entry.path, 1, true))
						local props = load(f, entry.path, {
							section = "remote",
							repos_item = "modified",
							property_only = true,
							base_revision = entry.revision,
						})
						assert(
							table.concat(props.property_patch.lines, "\n"):find("property " .. entry.path, 1, true),
							"remote property URL selected another filename"
						)
					end
				end
				assert(modified == #names and added == 1, "remote paths were silently omitted")
				local append = require("lazyvcs.backends.svn_url").append_path
				assert(
					append("file:///escaped%20root", "a%20b/café#%.txt")
						== "file:///escaped%20root/a%2520b/caf%C3%A9%23%25.txt"
				)
				assert(
					append("file:///root", "a\\123")
						== (vim.fn.has("win32") == 1 and "file:///root/a/123" or "file:///root/a%5C123")
				)
			end,
		},
		{
			"test_svn_remote_preview_uses_switched_entry_url",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "sub", "branch" }, f.root)
				h.write_file(f.root .. "/sub/sample.txt", "trunk")
				h.write_file(f.root .. "/branch/sample.txt", "branch")
				h.exec({ "svn", "add", "sub/sample.txt", "branch/sample.txt" }, f.root)
				h.exec({ "svn", "commit", "-m", "create branches" }, f.root)
				local branch_url = h.file_url(f.repo) .. "/branch"
				h.exec({ "svn", "switch", branch_url, f.root .. "/sub", "--ignore-ancestry" }, f.root)
				local other = h.tempdir() .. "/branch"
				h.exec({ "svn", "checkout", branch_url, other }, f.root)
				h.write_file(other .. "/sample.txt", "branch HEAD")
				h.exec({ "svn", "commit", "-m", "branch edit" }, other)
				local target = load(f, "sub/sample.txt", { section = "remote", repos_item = "modified" })
				assert(table.concat(target.right.lines, "\n") == "branch HEAD", "incoming preview used trunk URL")
			end,
		},
		{
			"test_svn_replacement_without_pristine_uses_empty_side",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "delete", "--force", f.file }, f.root)
				h.write_file(f.file, "replacement")
				h.exec({ "svn", "add", f.file }, f.root)
				local target = load(f, "sample.txt", { wc_item = "replaced" })
				assert(
					target.left.label == "EMPTY" and target.left.source.kind == "empty",
					"replacement retained BASE descriptor"
				)
				assert(target.title == "EMPTY ↔ WORKTREE")
				assert(rendered(target) == "replacement")
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "copy", f.file, f.root .. "/copy.txt" }, f.root)
				h.exec({ "svn", "commit", "-m", "copy history" }, f.root)
				h.exec({ "svn", "delete", "--force", f.file }, f.root)
				h.exec({ "svn", "copy", f.root .. "/copy.txt", f.file }, f.root)
				local readable = load(f, "sample.txt", { wc_item = "replaced" })
				assert(
					readable.left.label == "BASE" and readable.left.bytes ~= "",
					"readable replacement pristine was discarded"
				)
			end,
		},
		{
			"test_svn_local_property_patch_uses_literal_filename",
			function()
				local f = h.make_svn_fixture()
				for _, name in ipairs({ "sample.txt", "email@host.txt" }) do
					if name ~= "sample.txt" then
						h.write_file(f.root .. "/" .. name, "mail")
						h.exec({ "svn", "add", f.root .. "/" .. name .. "@" }, f.root)
						h.exec({ "svn", "commit", "-m", "add mail" }, f.root)
					end
					h.exec({ "svn", "propset", "custom", "literal value", f.root .. "/" .. name .. "@" }, f.root)
					local target = load(f, name, { property_only = true })
					assert(table.concat(target.property_patch.lines, "\n"):find("literal value", 1, true))
					assert(rendered(target):find("literal value", 1, true))
				end
			end,
		},
		{
			"test_svn_directory_property_preview_skips_text_sides",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:ignore", "*.tmp", "." }, f.root)
				local process = require("lazyvcs.backends.process")
				local start, cats = process.bytes, 0
				---@diagnostic disable-next-line: duplicate-set-field
				process.bytes = function(args, ...)
					if vim.tbl_contains(args, "cat") then
						cats = cats + 1
					end
					return start(args, ...)
				end
				local ok, target = pcall(load, f, ".", { property_only = true })
				process.bytes = start
				assert(cats == 0, "directory property preview tried svn cat")
				assert(ok, target)
				assert(rendered(target):find("*.tmp", 1, true))
			end,
		},
		{
			"test_blame_git_revision_log_disables_forced_color",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "color.ui", "always" }, f.root)
				local git = require("lazyvcs.backends.git")
				assert(
					not table.concat(assert(git.revision_log(f.file, "HEAD")), "\n"):find("\27", 1, true),
					"revision log contains ANSI escapes"
				)
				local lines = await(function(cb)
					git.revision_log_async(f.file, "HEAD", cb)
				end)
				assert(not table.concat(lines, "\n"):find("\27", 1, true))
			end,
		},
		{
			"test_core_git_root_preserves_whitespace",
			function()
				if vim.fn.has("win32") == 1 then
					return
				end
				local f = h.make_git_fixture()
				for _, suffix in ipairs({ " space\t ", " newline\n" }) do
					local root = f.root .. suffix
					assert(vim.uv.fs_rename(f.root, root))
					local git = require("lazyvcs.backends.git")
					assert(git.root(root .. "/sample.txt") == root, "Git root lost trailing whitespace")
					assert(git.load_base(root .. "/sample.txt").root == root)
					assert(await(function(cb)
						git.load_base_async(root .. "/sample.txt", cb)
					end).root == root)
					assert(await(function(cb)
						git.load_base_async(root .. "/sample.txt", cb, { root = root })
					end).root == root)
					assert(vim.uv.fs_rename(root, f.root))
				end
			end,
		},
		{
			"test_svn_root_preserves_whitespace",
			function()
				if vim.fn.has("win32") == 1 then
					return
				end
				local f = h.make_svn_fixture()
				for _, suffix in ipairs({ " space\t ", " newline\n" }) do
					local root = f.root .. suffix
					assert(vim.uv.fs_rename(f.root, root))
					local svn = require("lazyvcs.backends.svn")
					assert(svn.root(root .. "/sample.txt") == root, "SVN root lost trailing whitespace")
					assert(svn.load_base(root .. "/sample.txt").root == root)
					assert(await(function(cb)
						svn.load_base_async(root .. "/sample.txt", cb)
					end).root == root)
					assert(await(function(cb)
						svn.load_base_async(root .. "/sample.txt", cb, { root = root })
					end).root == root)
					assert(vim.uv.fs_rename(root, f.root))
				end
			end,
		},
	}
end
