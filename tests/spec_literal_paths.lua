return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	local function find(node, path)
		if node.type == "file" and node.extra.relpath == path then
			return node
		end
		for _, child in ipairs(node.children or {}) do
			local found = find(child, path)
			if found then
				return found
			end
		end
	end
	local function scenario(vcs, root_segment, entry)
		local parent = h.tempdir()
		local root = parent .. "/" .. root_segment
		vim.fn.mkdir(root .. "/" .. entry, "p")
		vim.fn.mkdir(root .. "/expanded", "p")
		local path = root .. "/" .. entry .. "/file.txt"
		local decoy = root .. "/expanded/file.txt"
		h.write_file(path, "SELECTED BASE\n")
		h.write_file(decoy, "OTHER FILE\n")
		if vcs == "git" then
			h.exec({ "git", "init" }, root)
			h.exec({ "git", "config", "user.name", "test" }, root)
			h.exec({ "git", "config", "user.email", "test@example.com" }, root)
			h.exec({ "git", "add", "." }, root)
			h.exec({ "git", "commit", "-m", "base" }, root)
		else
			local repo, seed = parent .. "/repo", parent .. "/seed"
			assert(vim.uv.fs_rename(root, seed))
			h.exec({ "svnadmin", "create", repo }, parent)
			h.exec({ "svn", "import", seed, h.file_url(repo), "-m", "base" }, parent)
			h.exec({ "svn", "checkout", h.file_url(repo), root }, parent)
		end
		h.write_file(path, "SELECTED EDIT\n")
		local model = require("lazyvcs.source_control.model")
		local specs = model.discover(root, 0)
		assert(specs[1] and specs[1].root == root, "literal repository root changed")
		local loaded, load_err, done
		model.load_repo_details_async(specs[1], {}, function(args, opts, cb)
			return util.system_start(args, { cwd = opts.cwd or root, timeout = opts.timeout_ms }, cb)
		end, function(result, err)
			loaded, load_err, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "details did not load", 15000)
		assert(loaded, load_err)
		local state = {
			path = root,
			lazyvcs_repo_specs = specs,
			lazyvcs_repo_cache = { [root] = loaded },
			lazyvcs_commit_drafts = {},
			lazyvcs_changes_sort = "path",
			lazyvcs_force_expand = { [model.repo_changes_id(root)] = true },
			lazyvcs_render = function() end,
		}
		local node = assert(find(model.collect(state, { root = root, scan_depth = 0 }), entry .. "/file.txt"))
		assert(node.path == path, "model expanded the selected literal path: " .. node.path)
		local target = assert(require("lazyvcs.backends").resolve_diff_target(vim.tbl_extend("force", node.extra, {
			root = root,
			vcs = vcs,
			path = node.path,
		})))
		assert(target.path == path, "backend changed the selected path")
		local fallback = assert(require("lazyvcs.backends").resolve_diff_target({
			root = root,
			vcs = vcs,
			relpath = entry .. "/file.txt",
			section = "changes",
		}))
		assert(fallback.path == path, "backend fallback expanded the literal path")

		require("lazyvcs.source_control.ops").open_change(state, node)
		ctx.wait_for(function()
			return require("lazyvcs.state").get(vim.api.nvim_get_current_buf()) ~= nil
		end, "editable comparison did not open", 15000)
		assert(vim.api.nvim_buf_get_name(0) == path, "editable buffer changed identity")
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "SELECTED EDIT" }))
		assert(vim.bo.modifiable and not vim.bo.readonly)
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SAVED SELECTION" })
		vim.cmd.write()
		assert(vim.deep_equal(vim.fn.readfile(path), { "SAVED SELECTION" }))
		assert(vim.deep_equal(vim.fn.readfile(decoy), { "OTHER FILE" }), "saving selection overwrote the decoy")
		require("lazyvcs.actions").close()
		assert(util.canonical_path(path) == path)
		assert(util.canonical_entry_path(path) == path)
		assert(util.relative_literal_path(root, path) == entry .. "/file.txt")
		assert(util.relpath(root, path) == entry .. "/file.txt")
		local persist = require("lazyvcs.source_control.persist")
		persist.save(root, { focused_repo = path })
		assert(persist.load(root).focused_repo == path)
		assert(persist.load(parent .. "/expanded").focused_repo == nil)
		local backend = assert(require("lazyvcs.backends").resolve(path))
		for _, method in ipairs({ "load_async", "load_base_async", "is_versioned_async", "revert_file_async" }) do
			local completed, loaded_value, path_err, spawned = false, nil, nil, false
			backend[method](parent .. "/outside.txt", function(value, err)
				loaded_value, path_err, completed = value, err, true
			end, {
				root = root,
				start = function()
					spawned = true
				end,
			})
			ctx.wait_for(function()
				return completed
			end, "outside entry did not finish", 15000)
			assert(
				not loaded_value and path_err and not spawned,
				vcs .. " " .. method .. " must reject outside entries"
			)
		end
	end
	return {
		{
			"test_core_literal_path_helpers_in_fast_context",
			function()
				local f = h.make_git_fixture()
				local timer = assert(vim.uv.new_timer())
				local done, ok, err
				local cwd = util.canonical_path(vim.uv.cwd())
				timer:start(0, 0, function()
					timer:close()
					ok, err = pcall(function()
						assert(vim.in_fast_event(), "probe did not run in a fast context")
						assert(util.canonical_path(f.root) == f.root)
						assert(util.canonical_path(".") == cwd)
						assert(util.canonical_entry_path(f.file, true) == f.file)
						assert(util.relpath(f.root, f.file) == "sample.txt")
					end)
					done = true
				end)
				ctx.wait_for(function()
					return done
				end, "fast-context path probe did not finish")
				assert(ok, err)
			end,
		},
		{
			"test_core_sidebar_symlink_parent_selects_filesystem_repository",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual" },
				})
				local first, second = h.make_git_fixture(), h.make_git_fixture()
				local windows = vim.fn.has("win32") == 1
				vim.fn.mkdir(second.root .. "/child", "p")
				assert(
					vim.uv.fs_symlink(
						second.root .. "/child",
						first.root .. "/link",
						windows and { junction = true } or { dir = true }
					)
				)
				local requested = first.root .. "/link/.."
				local native = require("lazyvcs.source_control.native")
				local previous, cwd = vim.env.LAZYVCS_CANONICAL_ROOT, vim.fn.getcwd()
				vim.env.LAZYVCS_CANONICAL_ROOT = first.root
				local ok, err = xpcall(function()
					assert(util.canonical_path(first.root .. "/link") == second.root .. "/child")
					if not windows then
						for _, command in ipairs({ false, true }) do
							local state
							if command then
								vim.cmd("LazyVCS sidebar open " .. "$LAZYVCS_CANONICAL_ROOT/link/..")
								state = native._state()
							else
								state = require("lazyvcs").source_control_open({ path = requested })
							end
							ctx.wait_for(function()
								return not state.lazyvcs_discovering and state.lazyvcs_repo_specs
							end, "symlink sidebar discovery did not finish", 15000)
							assert(
								state.path == second.root and state.lazyvcs_repo_specs[1].root == second.root,
								"sidebar selected the lexical repository instead of the filesystem repository"
							)
							native.close()
						end
						assert(util.canonical_path(requested) == second.root)
						assert(util.canonical_entry_path(requested .. "/sample.txt", true) == second.file)
						assert(util.relpath(requested, requested .. "/sample.txt") == "sample.txt")
						assert(util.relpath(first.root, requested .. "/sample.txt") == nil)
						assert(util.relpath(second.root, requested .. "/missing/..") == nil)
						assert(util.relpath(second.root, requested .. "/missing/deep/file") == "missing/deep/file")
						assert(
							util.relpath(second.root, requested .. "/missing/../sample.txt") == nil,
							"unresolved traversal authorized an entry"
						)
						assert(vim.uv.fs_symlink(first.file, second.root .. "/final-link"))
						assert(
							util.canonical_entry_path(requested .. "/final-link", true) == second.root .. "/final-link"
						)
						assert(util.relpath(second.root, requested .. "/final-link") == "final-link")
						assert(vim.uv.fs_symlink(second.root .. "/absent", second.root .. "/dangling", { dir = true }))
						assert(util.relpath(second.root, requested .. "/dangling/file") == nil)
					end
					vim.fn.mkdir(second.root .. "/~literal/$LAZYVCS_CANONICAL_ROOT", "p")
					vim.cmd.cd(vim.fn.fnameescape(second.root))
					assert(
						util.canonical_path("~literal/$LAZYVCS_CANONICAL_ROOT")
							== second.root .. "/~literal/$LAZYVCS_CANONICAL_ROOT",
						"Lua paths expanded literal tilde or dollar bytes"
					)
					assert(util.expand_user_path("$LAZYVCS_CANONICAL_ROOT/link/..") == requested)
					assert(util.expand_user_path("~/link/..") == vim.uv.os_homedir() .. "/link/..")
					assert(util.expand_user_path("%/#/*.txt") == "%/#/*.txt")
					if windows then
						local drive = second.root:sub(1, 2)
						assert(
							util.canonical_path(drive .. "child/..") == second.root,
							"drive-relative traversal changed roots"
						)
						assert(util.canonical_path((second.root .. "/child/.."):gsub("/", "\\")) == second.root)
					end
				end, debug.traceback)
				vim.env.LAZYVCS_CANONICAL_ROOT = previous
				vim.cmd.cd(vim.fn.fnameescape(cwd))
				native.close()
				assert(ok, err)
			end,
		},
		{
			"test_source_control_literal_paths_open_selected_file",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local previous, unset = vim.env.LAZYVCS_PATH_SEG, vim.env.LAZYVCS_UNSET_PATH
				vim.env.LAZYVCS_PATH_SEG, vim.env.LAZYVCS_UNSET_PATH = "expanded", nil
				local ok, err = xpcall(function()
					for _, vcs in ipairs({ "git", "svn" }) do
						scenario(vcs, "checkout", "$LAZYVCS_PATH_SEG")
						scenario(vcs, "$LAZYVCS_PATH_SEG", "$LAZYVCS_UNSET_PATH")
					end
				end, debug.traceback)
				vim.env.LAZYVCS_PATH_SEG, vim.env.LAZYVCS_UNSET_PATH = previous, unset
				if not ok then
					error(err, 0)
				end
				assert(util.normalize_literal_path("~literal/$LAZYVCS_PATH_SEG") == "~literal/$LAZYVCS_PATH_SEG")
				assert(util.relative_literal_path("/repo", "/repo") == ".")
				assert(util.relative_literal_path("/repo/", "/repo/sub/../file") == "file")
				assert(util.relative_literal_path("/repo", "/repo-other/file") == nil)
				assert(util.relative_literal_path("/repo", "/repo/../file") == nil)
				assert(util.relative_literal_path("/", "/file") == "file")
				assert(util.relative_literal_path("C:/", "C:/file") == "file")
				assert(util.relative_literal_path("C:/repo", "D:/repo/file") == nil)
				assert(util.relative_literal_path("//server/share", "//server/share/file") == "file")
				assert(util.relative_literal_path("//server/share", "//server/share-other/file") == nil)
				if vim.fn.has("win32") == 1 then
					assert(util.relative_literal_path([[c:\repo]], [[C:\repo\sub\file]]) == "sub/file")
					assert(util.relative_literal_path([[\\server\share]], [[\\server\share\sub\file]]) == "sub/file")
				else
					assert(
						util.normalize_literal_path([[a\b]]) == [[a\b]],
						"a POSIX backslash is a literal filename byte"
					)
				end
				assert(util.relative_literal_path("/repo", "/REPO/file") == (vim.o.fileignorecase and "file" or nil))
			end,
		},
	}
end
