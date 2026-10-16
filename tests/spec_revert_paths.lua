return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	return {
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
end
