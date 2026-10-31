return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local util = require("lazyvcs.util")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_patch_git_boundaries_" .. name,
			function()
				local stat, start = uv.fs_stat, util.system_start
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				uv.fs_stat, util.system_start = stat, start
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	local function collect(path)
		local out = {}
		out.task = require("lazyvcs").patch({
			path = path,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		return out
	end
	local function wait(out)
		ctx.wait_for(function()
			return out.done
		end, "Git boundary collection did not finish", 15000)
	end
	local function fixture()
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
		h.write_file(f.root .. "/ordinary.txt", "OUTER_ORDINARY\n")
		vim.fn.mkdir(f.root .. "/ordinary-dir")
		h.write_file(f.root .. "/ordinary-dir/literal [x].txt", "OUTER_DIRECTORY\n")
		return f
	end
	local function link(target, path, directory)
		local ok, err =
			uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and directory and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local function svn(f)
		local inner = h.make_svn_fixture()
		h.exec({ "svn", "checkout", h.file_url(inner.repo), f.root .. "/nested" }, f.root)
		h.write_file(f.root .. "/nested/private.txt", "NESTED_PRIVATE_NONCE\n")
		return inner
	end
	add("native_svn_excludes_private_and_admin_preserves_apply", function()
		local f = fixture()
		svn(f)
		local out = collect(f.root)
		wait(out)
		assert(out.text, out.err)
		assert(out.text:find("OUTER_ORDINARY", 1, true) and out.text:find("OUTER_DIRECTORY", 1, true))
		assert(not out.text:find("NESTED_PRIVATE_NONCE", 1, true), "nested SVN private bytes exported")
		assert(not out.text:find("nested/.svn/", 1, true), "nested SVN administration exported")
		local dest = h.tempdir() .. "/wc"
		h.exec({ "git", "clone", f.root, dest }, vim.fs.dirname(dest))
		local patchfile = h.tempdir() .. "/outer.patch"
		h.write_file(patchfile, out.text)
		h.exec({ "git", "apply", "--check", patchfile }, dest)
		h.exec({ "git", "apply", patchfile }, dest)
		assert(table.concat(vim.fn.readfile(dest .. "/ordinary.txt"), "\n") == "OUTER_ORDINARY")
	end)
	add("native_nested_git_and_direct_inner_selection", function()
		local f = fixture()
		vim.fn.mkdir(f.root .. "/inner")
		h.exec({ "git", "init" }, f.root .. "/inner")
		h.write_file(f.root .. "/inner/secret.txt", "INNER_GIT_NONCE\n")
		local out = collect(f.root)
		wait(out)
		assert(out.text and out.text:find("OUTER_ORDINARY", 1, true), out.err)
		assert(not out.text:find("INNER_GIT_NONCE", 1, true))
		local selected = collect(f.root .. "/inner/secret.txt")
		wait(selected)
		assert(selected.text and selected.text:find("INNER_GIT_NONCE", 1, true), selected.err)
		assert(not selected.text:find("OUTER_ORDINARY", 1, true))
	end)
	add("native_direct_svn_selection_keeps_inner_scope", function()
		local f = fixture()
		svn(f)
		local out = collect(f.root .. "/nested/private.txt")
		wait(out)
		assert(out.text and out.text:find("NESTED_PRIVATE_NONCE", 1, true), out.err)
		assert(not out.text:find("OUTER_ORDINARY", 1, true))
	end)
	add("native_tracked_inside_svn_keeps_git_diff", function()
		local f = fixture()
		svn(f)
		h.write_file(f.root .. "/nested/git-owned.txt", "tracked before\n")
		h.exec({ "git", "add", "--", "nested/git-owned.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "Track explicit inner file" }, f.root)
		h.write_file(f.root .. "/nested/git-owned.txt", "GIT_TRACKED_INSIDE_SVN\n")
		local out = collect(f.root)
		wait(out)
		assert(out.text and out.text:find("+GIT_TRACKED_INSIDE_SVN", 1, true), out.err)
		assert(not out.text:find("NESTED_PRIVATE_NONCE", 1, true))
	end)
	add("native_linked_svn_marker_stops_boundary", function()
		local f = fixture()
		local inner = h.make_svn_fixture()
		vim.fn.mkdir(f.root .. "/linked")
		link(inner.root .. "/.svn", f.root .. "/linked/.svn", true)
		h.write_file(f.root .. "/linked/private.txt", "LINKED_PRIVATE_NONCE\n")
		local out = collect(f.root)
		wait(out)
		assert(out.text and out.text:find("OUTER_ORDINARY", 1, true), out.err)
		assert(not out.text:find("LINKED_PRIVATE_NONCE", 1, true))
	end)
	add("explicit_git_root_keeps_ordinary_files_with_svn_admin", function()
		local f = fixture()
		local inner = h.make_svn_fixture()
		h.exec({ "svn", "checkout", "--force", h.file_url(inner.repo), f.root }, f.root)
		local out, chunks = {}, {}
		require("lazyvcs.backends.patch").collect({ root = f.root, vcs = "git" }, f.root, {
			include_untracked = true,
			remaining = function()
				return 16 * 1024 * 1024
			end,
			append = function(text)
				chunks[#chunks + 1] = text
				return true
			end,
		}, function(ok, err)
			out.ok, out.err, out.done = ok, err, true
		end)
		wait(out)
		local text = table.concat(chunks)
		assert(out.ok and text:find("OUTER_ORDINARY", 1, true), out.err)
		assert(not text:find(".svn/", 1, true), "root SVN administration was exported")
	end)
	add("explicit_git_root_linked_admin_leaf_is_excluded", function()
		local f, inner = fixture(), h.make_svn_fixture()
		link(inner.root .. "/.svn", f.root .. "/.svn", true)
		local out, chunks = {}, {}
		require("lazyvcs.backends.patch").collect({ root = f.root, vcs = "git" }, f.root, {
			include_untracked = true,
			remaining = function()
				return 16 * 1024 * 1024
			end,
			append = function(text)
				chunks[#chunks + 1] = text
				return true
			end,
		}, function(ok, err)
			out.ok, out.err, out.done = ok, err, true
		end)
		wait(out)
		local text = table.concat(chunks)
		assert(out.ok and text:find("OUTER_ORDINARY", 1, true), out.err)
		assert(not text:find(".svn", 1, true), "root linked administration was exported")
	end)
	add("ordinary_leaf_symlink_is_native_entry", function()
		local f = fixture()
		link("ordinary.txt", f.root .. "/leaf-link", false)
		local out = collect(f.root .. "/leaf-link")
		wait(out)
		assert(out.text and out.text:find("+ordinary.txt", 1, true), out.err)
		assert(not out.text:find("OUTER_ORDINARY", 1, true))
	end)
	add("plain_svn_leaf_and_wrong_kind_marker_are_kept", function()
		local f = fixture()
		h.write_file(f.root .. "/ordinary-dir/.svn", "PLAIN_SVN_FILENAME\n")
		h.write_file(f.root .. "/.svn", "ROOT_PLAIN_SVN_FILENAME\n")
		local out = collect(f.root)
		wait(out)
		assert(out.text and out.text:find("+PLAIN_SVN_FILENAME", 1, true), out.err)
		assert(out.text:find("OUTER_DIRECTORY", 1, true), "plain file became an SVN boundary")
		assert(out.text:find("+ROOT_PLAIN_SVN_FILENAME", 1, true), "root plain .svn file omitted")
	end)
	add("dangling_svn_marker_link_remains_native_entry", function()
		local f = fixture()
		link("missing-target", f.root .. "/ordinary-dir/.svn", false)
		local out = collect(f.root)
		wait(out)
		assert(out.text and out.text:find("+missing-target", 1, true), out.err)
		assert(out.text:find("OUTER_DIRECTORY", 1, true), "dangling marker became an SVN boundary")
	end)
	add("unique_ancestor_marker_queries_are_cached", function()
		local f, counts, stat = fixture(), {}, uv.fs_stat
		for i = 1, 30 do
			h.write_file(f.root .. "/ordinary-dir/file" .. i, "same directory\n")
		end
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_stat = function(path, cb)
			if path:match("/ordinary%-dir/%.git$") or path:match("/ordinary%-dir/%.svn$") then
				counts[path] = (counts[path] or 0) + 1
			end
			return stat(path, cb)
		end
		local out = collect(f.root)
		wait(out)
		assert(out.text, out.err)
		assert(
			counts[f.root .. "/ordinary-dir/.git"] == 1 and counts[f.root .. "/ordinary-dir/.svn"] == 1,
			"ancestor marker checks were not cached"
		)
	end)
	add("marker_error_fails_closed", function()
		local f, stat = fixture(), uv.fs_stat
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_stat = function(path, cb)
			if path == f.root .. "/ordinary-dir/.svn" then
				vim.schedule(function()
					cb("EACCES: denied", nil)
				end)
				---@diagnostic disable-next-line: return-type-mismatch
				return nil
			end
			return stat(path, cb)
		end
		local out = collect(f.root)
		wait(out)
		assert(not out.text and out.err and out.err:find("EACCES", 1, true), "marker error published a patch")
	end)
	add("marker_error_path_contains_ENOENT", function()
		local f, stat = fixture(), uv.fs_stat
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_stat = function(path, cb)
			if path == f.root .. "/ordinary-dir/.svn" then
				vim.schedule(function()
					cb("EACCES: denied '/repo/ENOENT/.svn'", nil)
				end)
				---@diagnostic disable-next-line: return-type-mismatch
				return nil
			end
			return stat(path, cb)
		end
		local out = collect(f.root)
		wait(out)
		assert(not out.text and out.err and out.err:find("EACCES", 1, true), "marker error published a patch")
	end)
	add("cancelled_marker_callback_never_resumes_children", function()
		local f, stat, start, held, children = fixture(), uv.fs_stat, util.system_start, nil, 0
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_stat = function(path, cb)
			if path == f.root .. "/ordinary-dir/.svn" then
				held = cb
				---@diagnostic disable-next-line: return-type-mismatch
				return nil
			end
			return stat(path, cb)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			if vim.tbl_contains(args, "--no-index") then
				children = children + 1
			end
			return start(args, opts, cb)
		end
		local out = collect(f.root)
		ctx.wait_for(function()
			return held ~= nil
		end, "marker callback was not reached", 15000)
		local before = children
		out.task:cancel()
		assert(held)("ENOENT: missing", nil)
		vim.wait(100, function()
			return false
		end, 5)
		assert(out.task.cancelled and not out.done and children == before, "late callback restarted collection")
	end)
	for _, count in ipairs({ 10000, 10001 }) do
		add("synthetic_list_bound_" .. count, function()
			local f, start, children = fixture(), util.system_start, 0
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, cb)
				if vim.tbl_contains(args, "--no-index") then
					children = children + 1
				end
				return start(args, opts, function(result, err, raw)
					if result and vim.tbl_contains(args, "ls-files") then
						local names = {}
						for i = 1, count do
							names[i] = "nested/.svn/private" .. i
						end
						result.stdout = table.concat(names, "\0") .. "\0"
					end
					cb(result, err, raw)
				end)
			end
			local out = collect(f.root)
			wait(out)
			assert(children == 0, "administrative list reached native readers")
			if count > 10000 then
				assert(not out.text and out.err and out.err:find("10000", 1, true), "file cap was bypassed")
			else
				assert(out.text, out.err)
			end
		end)
	end
	return cases
end
