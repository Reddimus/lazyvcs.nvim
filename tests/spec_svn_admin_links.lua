return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local function link(target, path, directory)
		local ok, err =
			uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and directory and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "administrative symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local function paths(f, comparison)
		local rows, err, finished
		local function done(value, why)
			rows, err, finished = value, why, true
		end
		if comparison then
			require("lazyvcs.backends.compare_svn").list(
				{ root = f.root, vcs = "svn", url = h.file_url(f.repo), revision = "1" },
				true,
				done
			)
		else
			require("lazyvcs.backends").changed_files_async(f.file, done)
		end
		ctx.wait_for(function()
			return finished
		end, "nested-owner discovery did not finish", 15000)
		assert(rows, err)
		local result = {}
		for _, row in ipairs(rows) do
			result[row.relpath or row.path] = true
		end
		return result
	end
	local function excludes_nested(f)
		for _, comparison in ipairs({ false, true }) do
			local found = paths(f, comparison)
			assert(not found["nested/child.txt"], "outer SVN discovery entered a nested repository")
			assert(found["sample.txt"], "parent change disappeared")
		end
	end
	local cases = {}
	for _, kind in ipairs({ "directory", "file", "link_directory", "link_file" }) do
		cases[#cases + 1] = {
			"test_svn_nested_git_admin_marker_" .. kind,
			function()
				local f = h.make_svn_fixture()
				local nested = f.root .. "/nested"
				if kind == "directory" then
					h.exec({ "git", "init", nested }, f.root)
				elseif kind == "link_directory" then
					local admin = h.tempdir() .. "/admin"
					h.exec({ "git", "init", "--separate-git-dir", admin, nested }, f.root)
					assert(uv.fs_unlink(nested .. "/.git"))
					link(admin, nested .. "/.git", true)
				else
					local seed = h.make_git_fixture()
					h.exec({ "git", "worktree", "add", "--detach", nested, "HEAD" }, seed.root)
					if kind == "link_file" then
						local pointer = h.tempdir() .. "/git-pointer"
						assert(uv.fs_rename(nested .. "/.git", pointer))
						link(pointer, nested .. "/.git", false)
					end
				end
				h.write_file(nested .. "/child.txt", "nested Git content\n")
				local native = vim.trim(h.exec({ "git", "rev-parse", "--show-toplevel" }, nested))
				local util = require("lazyvcs.util")
				assert(util.canonical_path(native) == util.canonical_path(nested), "fixture is not a native Git owner")
				excludes_nested(f)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_svn_nested_admin_dangling_and_wrong_kind_links_keep_ordinary_files",
		function()
			for _, marker in ipairs({ ".git", ".svn" }) do
				local f = h.make_svn_fixture()
				local nested = f.root .. "/ordinary"
				vim.fn.mkdir(nested, "p")
				h.write_file(nested .. "/child.txt", "ordinary content\n")
				local target = h.tempdir() .. "/target"
				if marker == ".svn" then
					h.write_file(target, "not a directory working copy\n")
				end
				link(target, nested .. "/" .. marker, false)
				assert(paths(f, false)["ordinary/child.txt"], "inert administrative link hid ordinary content")
			end
		end,
	}
	cases[#cases + 1] = {
		"test_svn_nested_admin_lookup_does_not_follow_ordinary_directory_links",
		function()
			local f = h.make_svn_fixture()
			local outside = h.tempdir()
			h.write_file(outside .. "/foreign.txt", "foreign content\n")
			link(outside, f.root .. "/linked", true)
			local found = paths(f, false)
			assert(found.linked and not found["linked/foreign.txt"], "ordinary directory symlink was traversed")
		end,
	}
	cases[#cases + 1] = {
		"test_svn_nested_admin_lookup_cancel_ignores_late_stat",
		function()
			local f = h.make_svn_fixture()
			local nested = f.root .. "/ordinary"
			vim.fn.mkdir(nested, "p")
			h.write_file(nested .. "/child.txt", "ordinary content\n")
			local stat, scan = uv.fs_stat, uv.fs_scandir
			local held, scans, completed = nil, 0, false
			uv.fs_stat = function(path, callback)
				if path == nested .. "/.git" and callback then
					held = callback
					return {}
				end
				return stat(path, callback)
			end
			uv.fs_scandir = function(path, callback)
				if path == nested then
					scans = scans + 1
				end
				return scan(path, callback)
			end
			local task = require("lazyvcs.backends.comparison").task()
			local ok, err = pcall(function()
				require("lazyvcs.backends.svn_untracked").expand(task, { root = f.root }, {
					{ path = nested, wc_item = "unversioned" },
				}, function()
					completed = true
				end)
				ctx.wait_for(function()
					return held
				end, "administrative marker stat did not start", 15000)
				task:kill()
				assert(held)(nil, { type = "directory" })
				vim.wait(30, function()
					return false
				end, 5)
				assert(not completed and scans == 0, "canceled administrative lookup continued discovery")
			end)
			uv.fs_stat, uv.fs_scandir = stat, scan
			task:kill()
			assert(ok, err)
		end,
	}
	return cases
end
