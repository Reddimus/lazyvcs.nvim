return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	-- Read checkout files by absolute path; E2E runs from another directory.
	local checkout =
		vim.fn.fnamemodify(assert(vim.api.nvim_get_runtime_file("lua/lazyvcs/compat.lua", false)[1]), ":p:h:h:h")
	local function checkout_lines(relpath)
		return vim.fn.readfile(checkout .. "/" .. relpath)
	end
	local cases = {
		{
			"test_revert_checks_file_kind_after_index_read",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				local backend = assert(require("lazyvcs.backends").resolve(f.file))
				local start = util.system_start
				local checked, mutated, done, result, failure
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[2] == "ls-files" then
						return start(args, opts, function(...)
							assert(vim.uv.fs_unlink(f.file))
							vim.fn.mkdir(f.file, "p")
							h.write_file(f.file .. "/precious.txt", "unselected work\n")
							checked = true
							cb(...)
						end)
					end
					mutated = mutated or vim.tbl_contains(args, "restore")
					return start(args, opts, cb)
				end
				local ok, err = xpcall(function()
					backend.revert_file_async(f.file, function(value, why)
						done, result, failure = true, value, why
					end)
					ctx.wait_for(function()
						return done
					end, "replacement during preflight did not settle", 15000)
					assert(
						checked and not result and failure and failure:find("obstruction") and not mutated,
						"Discard did not check the current filesystem kind before restore"
					)
					assert(vim.fn.readfile(f.file .. "/precious.txt")[1] == "unselected work")
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end,
		},
		{
			"test_revert_allows_exact_index_file_and_missing_target",
			function()
				for _, async in ipairs({ false, true }) do
					for _, missing in ipairs({ false, true }) do
						local f = h.make_git_fixture()
						h.write_file(f.file, "staged content\n")
						h.exec({ "git", "add", "sample.txt" }, f.root)
						if missing then
							assert(vim.uv.fs_unlink(f.file))
						else
							h.write_file(f.file, "saved edit\n")
						end
						local backend = assert(require("lazyvcs.backends").resolve(f.file))
						local result, failure
						if async then
							local done
							backend.revert_file_async(f.file, function(value, why)
								done, result, failure = true, value, why
							end)
							ctx.wait_for(function()
								return done
							end, "eligible discard did not settle", 15000)
						else
							result, failure = backend.revert_file(f.file)
						end
						assert(result, failure)
						assert(vim.fn.readfile(f.file)[1] == "staged content")
						assert(h.exec({ "git", "show", ":sample.txt" }, f.root) == "staged content\n")
					end
				end
			end,
		},
		{
			"test_revert_refuses_replacement_directory",
			function()
				for _, method in ipairs({ "public", "revert_file", "revert_file_async" }) do
					require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local function replace()
						assert(vim.uv.fs_unlink(f.file))
						vim.fn.mkdir(f.file, "p")
						h.write_file(f.file .. "/child.txt", "staged child\n")
						h.exec({ "git", "add", "-A", "--", "sample.txt" }, f.root)
						h.write_file(f.file .. "/child.txt", "IMPORTANT SAVED CHILD EDIT\n")
					end
					if method == "public" then
						local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
						ctx.wait_for(function()
							return vim.bo.buftype == "nofile"
						end, "discard confirmation did not open", 15000)
						replace()
						vim.fn.maparg("1", "n", false, true).callback()
						ctx.wait_for(function()
							return not owner.active
						end, "discard did not settle", 15000)
					else
						replace()
						local backend = assert(require("lazyvcs.backends").resolve(f.file))
						if method == "revert_file" then
							backend.revert_file(f.file)
						else
							local done
							backend.revert_file_async(f.file, function()
								done = true
							end)
							ctx.wait_for(function()
								return done
							end, "backend discard did not settle", 15000)
						end
					end
					assert(
						vim.fn.readfile(f.file .. "/child.txt")[1] == "IMPORTANT SAVED CHILD EDIT",
						method .. " overwrote an unselected child through a stale file path"
					)
				end
			end,
		},
		{
			"test_revert_help_explains_index_scope",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				h.write_file(f.file, "STAGED content\n")
				h.exec({ "git", "add", "sample.txt" }, f.root)
				h.write_file(f.file, "WORKTREE content\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
				ctx.wait_for(function()
					return vim.bo.buftype == "nofile"
				end, "revert confirmation", 15000)
				vim.fn.maparg("1", "n", false, true).callback()
				ctx.wait_for(function()
					return not owner.active
				end, "revert did not finish", 15000)
				assert(vim.fn.readfile(f.file)[1] == "STAGED content")
				assert(h.exec({ "git", "show", ":sample.txt" }, f.root) == "STAGED content\n")
				local help = table.concat(checkout_lines("doc/lazyvcs.txt"), "\n")
				local command = assert(help:match(":LazyVCS revert%s+(.-)\n\n"))
				assert(
					command:find("index", 1, true) and command:find("staged changes", 1, true),
					"whole-file revert help omits Git's index scope and preserved staged changes"
				)
				assert(command:find("BASE", 1, true), "whole-file revert help omits SVN BASE scope")
			end,
		},
		{
			"test_revert_relocated_missing_entry_preserves_sibling",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local parent = h.tempdir()
				local old, moved = parent .. "/old", parent .. "/moved"
				vim.fn.mkdir(old .. "/sub", "p")
				h.exec({ "git", "init" }, old)
				h.exec({ "git", "config", "core.symlinks", "true" }, old)
				h.exec({ "git", "config", "user.name", "test" }, old)
				h.exec({ "git", "config", "user.email", "test@example.com" }, old)
				h.write_file(old .. "/file.txt", "ROOT BASE\n")
				h.write_file(old .. "/sub/file.txt", "NESTED BASE\n")
				h.exec({ "git", "add", "." }, old)
				h.exec({ "git", "commit", "-m", "base" }, old)
				vim.cmd.edit(vim.fn.fnameescape(old .. "/sub/file.txt"))
				-- BufEnter starts finite Git/SVN probes. Windows holds their cwd
				-- until exit, so await that shared resolution before relocating it.
				local resolved = false
				require("lazyvcs.backends").resolve_async(old .. "/sub/file.txt", function()
					resolved = true
				end, { revalidate = true })
				ctx.wait_for(function()
					return resolved
				end, "BufEnter probes did not finish before relocation", 15000)
				assert(vim.uv.fs_rename(old, moved))
				assert(vim.uv.fs_symlink(moved, old, { dir = true }))
				assert(vim.uv.fs_unlink(moved .. "/sub/file.txt"))
				h.write_file(moved .. "/file.txt", "UNCOMMITTED ROOT EDIT\n")
				local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
				ctx.wait_for(function()
					return vim.bo.buftype == "nofile"
				end, "discard confirmation did not open", 15000)
				local accept = vim.fn.maparg("1", "n", false, true)
				assert(type(accept.callback) == "function", "missing real confirmation mapping")
				accept.callback()
				ctx.wait_for(function()
					return owner.active == false
				end, "discard did not finish", 15000)
				assert(
					vim.deep_equal(vim.fn.readfile(moved .. "/file.txt"), { "UNCOMMITTED ROOT EDIT" }),
					"discard erased the root sibling's uncommitted bytes"
				)
				assert(
					vim.deep_equal(vim.fn.readfile(moved .. "/sub/file.txt"), { "NESTED BASE" }),
					"discard did not restore the selected nested entry"
				)

				-- Whole-file restore must replace a tracked symlink itself, leaving its target alone.
				local target = parent .. "/target.txt"
				h.write_file(target, "TARGET EDIT\n")
				assert(vim.uv.fs_symlink(target, moved .. "/tracked-link"))
				h.exec({ "git", "add", "tracked-link" }, moved)
				h.exec({ "git", "commit", "-m", "track symlink" }, moved)
				assert(vim.uv.fs_unlink(moved .. "/tracked-link"))
				h.write_file(moved .. "/tracked-link", "REPLACEMENT\n")
				local backend = assert(require("lazyvcs.backends").resolve(moved .. "/file.txt"))
				local done, result, restore_err
				backend.revert_file_async(moved .. "/tracked-link", function(value, err)
					result, restore_err, done = value, err, true
				end)
				ctx.wait_for(function()
					return done
				end, "symlink restore did not finish", 15000)
				assert(result, restore_err)
				assert(vim.uv.fs_lstat(moved .. "/tracked-link").type == "link")
				assert(util.normalize_literal_path(assert(vim.uv.fs_readlink(moved .. "/tracked-link"))) == target)
				assert(vim.deep_equal(vim.fn.readfile(target), { "TARGET EDIT" }))

				-- Retarget the checkout alias after tracking validation but before restore.
				local start, completed, rejected, mutation_started = util.system_start, false, nil, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[1] == "git" and args[2] == "ls-files" then
						return start(args, opts, function(...)
							assert(vim.uv.fs_unlink(old))
							assert(vim.uv.fs_symlink(moved .. "/sub", old, { dir = true }))
							cb(...)
						end)
					end
					return start(args, opts, cb)
				end
				local ok, check_err = xpcall(function()
					backend.revert_file_async(old .. "/file.txt", function(value, err)
						assert(not value)
						rejected, completed = err, true
					end, {
						start = function(_, _, cb)
							mutation_started = true
							cb(nil, "unexpected mutation")
							return {}
						end,
					})
					ctx.wait_for(function()
						return completed
					end, "retargeted discard did not finish", 15000)
					assert(
						rejected and not mutation_started,
						"discard must revalidate the exact relative entry at start"
					)
				end, debug.traceback)
				util.system_start = start
				assert(vim.uv.fs_unlink(old))
				assert(vim.uv.fs_symlink(moved, old, { dir = true }))
				if not ok then
					error(check_err, 0)
				end

				assert(util.relpath(moved, old .. "/missing/deep/file.txt") == "missing/deep/file.txt")
				assert(util.relpath(moved, parent .. "/file.txt") == nil)
				assert(util.relpath(moved, moved .. "-other/file.txt") == nil)
				assert(vim.uv.fs_symlink(parent .. "/absent", moved .. "/broken", { dir = true }))
				local rel, err = util.relpath(moved, moved .. "/broken/file.txt")
				assert(rel == nil and err, "an unresolved symlink parent must fail closed")
				assert(vim.uv.fs_symlink(parent .. "/absent-target", moved .. "/link"))
				assert(util.relpath(moved, moved .. "/link") == "link", "preserve the final symlink entry")
				assert(util.relpath(moved, moved .. "/file.txt/child") == nil, "reject non-directory parents")
				local other_case = parent .. "/MOVED"
				vim.fn.mkdir(other_case, "p")
				if vim.uv.fs_realpath(other_case) ~= vim.uv.fs_realpath(moved) then
					local fic = vim.o.fileignorecase
					vim.o.fileignorecase = true
					local relative = util.relpath(moved, other_case .. "/file.txt")
					vim.o.fileignorecase = fic
					assert(relative == nil, "fileignorecase must not authorize a different checkout")
				end

				-- A caller-supplied cached root must not authorize an outside entry.
				for _, invalid in ipairs({
					parent .. "/target.txt",
					moved .. "-other/file.txt",
					moved .. "/broken/file.txt",
				}) do
					for _, method in ipairs({
						"load_async",
						"load_base_async",
						"is_versioned_async",
						"revert_file_async",
					}) do
						local completed, loaded, path_err, spawned = false, nil, nil, false
						backend[method](invalid, function(value, err)
							loaded, path_err, completed = value, err, true
						end, {
							root = moved,
							start = function()
								spawned = true
							end,
						})
						ctx.wait_for(function()
							return completed
						end, "invalid path did not complete", 15000)
						assert(
							not loaded and path_err and not path_err:find("\n"),
							method .. " must reject an unverified entry"
						)
						assert(not spawned, "rejection must precede mutation start")
					end
				end
			end,
		},
	}
	local function symlink_case(svn, live)
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		local target, link = f.root .. "/target.txt", f.root .. "/link.txt"
		h.write_file(target, "TARGET CONTENT\n")
		assert(vim.uv.fs_symlink("target.txt", link))
		if svn then
			h.exec({ "svn", "add", link }, f.root)
			h.exec({ "svn", "commit", "-m", "link", link }, f.root)
		else
			h.exec({ "git", "config", "core.symlinks", "true" }, f.root)
			h.exec({ "git", "add", "link.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "link" }, f.root)
		end
		local backend = require("lazyvcs.backends." .. (svn and "svn" or "git"))
		for _, replace in ipairs({ false, true }) do
			if replace then
				assert(vim.uv.fs_unlink(link))
				h.write_file(link, "REGULAR REPLACEMENT\n")
			end
			for _, method in ipairs({ "load", "load_base" }) do
				local result, err = backend[method](link)
				assert(not result and err, "editable loader accepted a symlink base")
			end
			vim.cmd.edit(vim.fn.fnameescape(link))
			local buf = vim.api.nvim_get_current_buf()
			local done, result, err
			backend.load_async(link, function(value, why)
				result, err, done = value, why, true
			end)
			ctx.wait_for(function()
				return done
			end, "symlink load did not finish", 15000)
			assert(not result and err, "async loader accepted a symlink base")
			if live then
				local task = require("lazyvcs.actions").open({ silent = true })
				ctx.wait_for(function()
					return task and task.done
				end, "ineligible live diff did not finish", 15000)
				assert(not require("lazyvcs.state").get(buf), "symlink opened an editable diff")
			else
				require("lazyvcs.config").get().signs.enabled = true
				done = false
				require("lazyvcs.signs").refresh(buf, true, function(state)
					result, done = state, true
				end)
				ctx.wait_for(function()
					return done
				end, "ineligible signs did not finish", 15000)
				assert(not result, "symlink received native hunks")
			end
			assert(vim.deep_equal(vim.fn.readfile(target), { "TARGET CONTENT" }), "symlink target changed")
		end
		-- A regular index base must also reject a final worktree symlink.
		assert(vim.uv.fs_unlink(f.file))
		assert(vim.uv.fs_symlink("target.txt", f.file))
		local result, err = backend.load(f.file)
		assert(not result and err, "regular base accepted a worktree symlink")
		-- Eligibility must be checked again after the user accepts a hunk.
		assert(vim.uv.fs_unlink(f.file))
		h.write_file(f.file, "one\nchanged\nthree\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = vim.api.nvim_get_current_buf()
		local state, done
		if live then
			require("lazyvcs.actions").open({
				on_open = function(value)
					state, done = value, true
				end,
			})
		else
			require("lazyvcs.config").get().signs.enabled = true
			require("lazyvcs.signs").refresh(buf, true, function(value)
				state, done = value, true
			end)
		end
		ctx.wait_for(function()
			return done
		end, "regular base did not load", 15000)
		assert(state and #state.hunks > 0)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		local action = live and require("lazyvcs.actions") or require("lazyvcs.signs")
		action.revert_hunk()
		assert(vim.bo.buftype == "nofile", "regular hunk did not prompt")
		assert(vim.uv.fs_unlink(f.file))
		assert(vim.uv.fs_symlink("target.txt", f.file))
		vim.fn.maparg("1", "n", false, true).callback()
		ctx.wait_for(function()
			return live and state.base_invalid or not live and not require("lazyvcs.signs").current_state(buf)
		end, "mutation did not reject the changed entry type", 15000)
		assert(
			vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed",
			"symlink eligibility changed after confirmation"
		)
		assert(vim.deep_equal(vim.fn.readfile(target), { "TARGET CONTENT" }))
	end
	cases[#cases + 1] = {
		"test_sign_symlink_base_is_ineligible",
		function()
			symlink_case(false, false)
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_symlink_base_is_ineligible",
		function()
			symlink_case(false, true)
		end,
	}
	cases[#cases + 1] = {
		"test_svn_sign_symlink_base_is_ineligible",
		function()
			symlink_case(true, false)
		end,
	}
	return cases
end
