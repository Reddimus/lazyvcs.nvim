return function(ctx)
	local h, api = ctx.helpers, vim.api
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function await(start)
		local value, failure, done
		start(function(result, err)
			value, failure, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "presence edge did not settle", 15000)
		return assert(value, failure)
	end
	local function setup()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	end
	local function settle()
		vim.wait(80, function()
			return false
		end, 10)
	end
	local cases = {
		{
			"test_core_diff_style_readonly_binary_deletion_keeps_normal_width",
			function()
				setup()
				for _, pair in ipairs({
					{ "binary.dat", "hello\0world\n", false },
					{ "utf16.txt", "\255\254h\0i\0\n\0", true },
				}) do
					local f = h.make_git_fixture()
					write(f.root .. "/" .. pair[1], pair[2])
					h.exec({ "git", "add", pair[1] }, f.root)
					h.exec({ "git", "commit", "-m", "deletion base" }, f.root)
					assert(vim.uv.fs_unlink(f.root .. "/" .. pair[1]))
					local comparison = await(function(done)
						return require("lazyvcs.backends").load_diff_target_async({
							vcs = "git",
							root = f.root,
							relpath = pair[1],
							section = "changes",
							status = " D",
							change_kind = "deleted",
						}, done)
					end)
					local s = assert(require("lazyvcs.actions").open_target(comparison))
					settle()
					assert((s.rail ~= nil) == pair[3], "readonly rail ignored decoded text eligibility")
					assert(s.readonly_comparison and not vim.bo[s.editable_bufnr].modifiable)
					require("lazyvcs.actions").close(s)
				end
			end,
		},
		{
			"test_core_diff_style_conflict_absence_differs_from_empty_stage_two",
			function()
				setup()
				for _, deleted in ipairs({ true, false }) do
					local f = h.make_git_fixture()
					local branch = vim.trim(h.exec({ "git", "symbolic-ref", "--short", "HEAD" }, f.root))
					h.exec({ "git", "checkout", "-b", "theirs" }, f.root)
					write(f.file, "theirs changed\n")
					h.exec({ "git", "add", "sample.txt" }, f.root)
					h.exec({ "git", "commit", "-m", "theirs" }, f.root)
					h.exec({ "git", "checkout", branch }, f.root)
					if deleted then
						h.exec({ "git", "rm", "-f", "sample.txt" }, f.root)
					else
						write(f.file, "")
						h.exec({ "git", "add", "sample.txt" }, f.root)
					end
					h.exec({ "git", "commit", "-m", "ours" }, f.root)
					assert(vim.system({ "git", "merge", "theirs" }, { cwd = f.root }):wait().code == 1)
					local comparison = await(function(done)
						return require("lazyvcs.backends").load_diff_target_async({
							vcs = "git",
							root = f.root,
							relpath = "sample.txt",
							section = "merge",
							change_kind = "conflict",
							status = deleted and "DU" or "UU",
						}, done)
					end)
					assert(
						comparison.presence.left == (deleted and "absent" or "present"),
						"conflict stage presence was guessed"
					)
					local s = assert(require("lazyvcs.actions").open_target(comparison))
					settle()
					assert((vim.wo[s.base_win].winbar:find("empty", 1, true) ~= nil) == not deleted)
					require("lazyvcs.actions").close(s)
				end
			end,
		},
		{
			"test_svn_diff_style_missing_and_retained_deletion_presence",
			function()
				setup()
				local f = h.make_svn_fixture()
				write(f.root .. "/kept.txt", "kept bytes\n")
				h.exec({ "svn", "add", "kept.txt" }, f.root)
				h.exec({ "svn", "commit", "-m", "kept base" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				write(f.root .. "/added.txt", "added bytes\n")
				h.exec({ "svn", "add", "added.txt" }, f.root)
				assert(vim.uv.fs_unlink(f.root .. "/added.txt"))
				assert(vim.uv.fs_unlink(f.file))
				h.exec({ "svn", "delete", "--keep-local", "kept.txt" }, f.root)
				local provider = require("lazyvcs.backends.compare_svn")
				local snapshot = await(function(done)
					return provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@HEAD", done)
				end)
				local items = await(function(done)
					return provider.list(snapshot, true, done)
				end)
				local expected = { ["sample.txt"] = "absent", ["added.txt"] = "absent", ["kept.txt"] = "unknown" }
				for _, item in ipairs(items) do
					if expected[item.relpath] then
						local result = await(function(done)
							return provider.preview(snapshot, item, done)
						end)
						assert(
							result.presence.right == expected[item.relpath],
							item.relpath .. ": false worktree presence"
						)
						local _, right = require("lazyvcs.diff_labels").labels(
							result.left_label,
							result.right_label,
							result.left_label,
							result.presence,
							result.left_document,
							result.right_document
						)
						assert(not right:find("Empty", 1, true))
						if item.relpath == "kept.txt" then
							assert(
								not right:find("No file", 1, true) and #result.right == 0,
								"retained deletion changed content semantics"
							)
						end
						expected[item.relpath] = nil
					end
				end
				assert(not next(expected), "native SVN rows missing")
			end,
		},
		{
			"test_svn_diff_style_cancelled_existence_check_ignores_late_completion",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "delete", "--force", "sample.txt" }, f.root)
				local provider = require("lazyvcs.backends.compare_svn")
				local snapshot = await(function(done)
					return provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@HEAD", done)
				end)
				local original, held, completed = vim.uv.fs_lstat, nil, false
				vim.uv.fs_lstat = function(path, callback)
					if path == f.file and callback then
						held = callback
						return {}
					end
					return original(path, callback)
				end
				local task
				local ok, err = xpcall(function()
					task = provider.preview(
						snapshot,
						{ status = "D", relpath = "sample.txt", kind = "file" },
						function()
							completed = true
						end
					)
					ctx.wait_for(function()
						return held
					end, "existence check was not held", 15000)
					task:kill()
					assert(held)("ENOENT: no such file")
					settle()
					assert(not completed, "cancelled endpoint read published a late result")
				end, debug.traceback)
				if task then
					task:kill()
				end
				vim.uv.fs_lstat = original
				assert(ok, err)
			end,
		},
		{
			"test_svn_diff_style_failed_existence_check_keeps_unknown_presence",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "delete", "--force", "sample.txt" }, f.root)
				local provider = require("lazyvcs.backends.compare_svn")
				local snapshot = await(function(done)
					return provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@HEAD", done)
				end)
				local original, inspected = vim.uv.fs_lstat, false
				vim.uv.fs_lstat = function(path, callback)
					if path == f.file and callback then
						inspected = true
						vim.schedule(function()
							callback("EACCES: permission denied")
						end)
						return {}
					end
					return original(path, callback)
				end
				local ok, err = xpcall(function()
					local result = await(function(done)
						return provider.preview(snapshot, { status = "D", relpath = "sample.txt", kind = "file" }, done)
					end)
					assert(inspected and result.presence.right == "unknown", "failed evidence claimed absence")
				end, debug.traceback)
				vim.uv.fs_lstat = original
				assert(ok, err)
			end,
		},
	}
	for _, mode in ipairs({ "syntax", "editor" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_clone_inherits_source_namespace_and_rendered_color_" .. mode,
			function()
				local ns = api.nvim_create_namespace("lazyvcs-presence-clone-" .. mode)
				api.nvim_set_hl(ns, "Normal", { bg = 0x102030, fg = 0xd0d0d0 })
				local previous = api.nvim_get_hl_ns({})
				api.nvim_set_hl_ns(ns)
				local ok, err = xpcall(function()
					setup()
					local f = h.make_git_fixture()
					write(f.root .. "/added.txt", "added text\n")
					vim.cmd.tabnew()
					vim.cmd.edit(vim.fn.fnameescape(f.root .. "/added.txt"))
					local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
					api.nvim_win_set_hl_ns(win, -1)
					require("lazyvcs.highlighting").apply(win, mode, "new")
					vim.cmd.split()
					local copy = api.nvim_get_current_win()
					assert(api.nvim_get_hl_ns({ winid = copy }) == -1, "clone lost inherited namespace")
					api.nvim_buf_set_extmark(
						buf,
						api.nvim_create_namespace("presence-normal-" .. mode),
						0,
						0,
						{ end_col = 1, hl_group = "Normal", priority = 10000 }
					)
					vim.cmd.redraw()
					local pos = vim.fn.screenpos(copy, 1, 1)
					assert(
						api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].background == 0x102030,
						"clone lost rendered source background"
					)
					local unrelated = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
						relative = "editor",
						row = 1,
						col = 1,
						width = 12,
						height = 2,
					})
					api.nvim_win_set_hl_ns(unrelated, 0)
					api.nvim_win_call(unrelated, function()
						api.nvim_exec_autocmds("WinEnter", {})
					end)
					assert(api.nvim_get_hl_ns({ winid = unrelated }) == 0, "unrelated namespace zero was changed")
					api.nvim_win_close(unrelated, true)
					require("lazyvcs.highlighting").release(win)
					api.nvim_win_close(copy, true)
					vim.cmd.tabclose()
				end, debug.traceback)
				api.nvim_set_hl_ns(previous)
				assert(ok, err)
			end,
		}
	end
	return cases
end
