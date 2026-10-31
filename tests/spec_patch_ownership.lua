return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local diagnostics = require("patch_windows_diagnostics")
	local function guard(fn)
		return function()
			local stat, lstat, scandir = uv.fs_stat, uv.fs_lstat, uv.fs_scandir
			diagnostics.capability(h)
			local stop_diagnostics = diagnostics.trace()
			local ok, err = xpcall(fn, function(value)
				return type(value) == "table" and value or debug.traceback(value, 2)
			end)
			uv.fs_stat, uv.fs_lstat, uv.fs_scandir = stat, lstat, scandir
			local captured, value = pcall(stop_diagnostics)
			if not ok and not (type(err) == "table" and err.lazyvcs_skip) then
				local record = captured and value or { kind = "trace-error", error = tostring(value) }
				record.module = "patch-ownership"
				record.case_line = debug.getinfo(fn, "S").linedefined
				diagnostics.emit(record)
			end
			h.cleanup()
			if not ok then
				error(err, 0)
			end
		end
	end
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function link(target, path, directory)
		local ok, err =
			uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and directory and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local function get(path)
		local text, failure, done
		require("lazyvcs").patch({
			path = path,
			on_done = function(value, err)
				text, failure, done = value, err, true
			end,
		})
		ctx.wait_for(function()
			return done
		end, "patch did not finish", 15000)
		assert(text, failure)
		return text
	end
	local function fixture()
		local f = h.make_svn_fixture()
		vim.fn.mkdir(f.root .. "/vendor", "p")
		write(f.root .. "/vendor/ordinary.txt", "ordinary outer content\n")
		return f
	end
	local cases = {}
	for _, kind in ipairs({ "directory", "worktree", "linked_directory", "linked_file" }) do
		cases[#cases + 1] = {
			"test_patch_ownership_nested_git_" .. kind,
			guard(function()
				local f = fixture()
				local nested = f.root .. "/vendor/inner"
				if kind == "directory" then
					h.exec({ "git", "init", nested }, f.root)
				elseif kind == "linked_directory" then
					local admin = h.tempdir() .. "/admin"
					h.exec({ "git", "init", "--separate-git-dir", admin, nested }, f.root)
					assert(uv.fs_unlink(nested .. "/.git"))
					link(admin, nested .. "/.git", true)
				else
					local seed = h.make_git_fixture()
					h.exec({ "git", "worktree", "add", "--detach", nested, "HEAD" }, seed.root)
					if kind == "linked_file" then
						local pointer = h.tempdir() .. "/pointer"
						assert(uv.fs_rename(nested .. "/.git", pointer))
						link(pointer, nested .. "/.git", false)
					end
				end
				write(nested .. "/private.txt", "INNER OWNER PRIVATE\n")
				local owner = vim.trim(h.exec({ "git", "rev-parse", "--show-toplevel" }, nested))
				local util = require("lazyvcs.util")
				assert(util.canonical_path(owner) == util.canonical_path(nested), "fixture needs native Git ownership")
				local text = get(f.root)
				assert(not text:find("INNER OWNER PRIVATE", 1, true), "outer SVN patch exported a nested Git file")
				assert(text:find("+ordinary outer content", 1, true), "ordinary outer leaf disappeared")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_patch_ownership_nested_svn_and_external_are_not_parent_additions",
		guard(function()
			local f, inner = fixture(), h.make_svn_fixture()
			local nested = f.root .. "/vendor/inner"
			h.exec({ "svn", "checkout", h.file_url(inner.repo), nested }, f.root)
			write(nested .. "/private.txt", "INNER SVN PRIVATE\n")
			local owner = vim.trim(h.exec({ "svn", "info", "--show-item", "wc-root", nested .. "@" }, f.root))
			assert(require("lazyvcs.util").canonical_path(owner) == require("lazyvcs.util").canonical_path(nested))
			h.exec({ "svn", "propset", "svn:externals", "external " .. h.file_url(inner.repo), f.root }, f.root)
			h.exec({ "svn", "update", f.root }, f.root)
			write(f.root .. "/external/private.txt", "EXTERNAL SVN PRIVATE\n")
			local text = get(f.root)
			assert(not text:find("INNER SVN PRIVATE", 1, true), "nested SVN owner leaked")
			assert(not text:find("EXTERNAL SVN PRIVATE", 1, true), "external owner leaked")
			assert(text:find("+ordinary outer content", 1, true))
		end),
	}
	cases[#cases + 1] = {
		"test_patch_ownership_regular_only_ignores_inert_markers_and_applies",
		guard(function()
			local f = fixture()
			local outside = h.tempdir()
			write(outside .. "/secret.txt", "OUTSIDE PRIVATE\n")
			link(outside, f.root .. "/vendor/directory-link", true)
			link(outside .. "/secret.txt", f.root .. "/vendor/file-link", false)
			link(outside .. "/missing-admin", f.root .. "/vendor/.git", false)
			write(f.root .. "/vendor/ignored.o", "ignored object\n")
			h.exec({ "svn", "propset", "svn:global-ignores", "*.o", f.root }, f.root)
			local text = get(f.root)
			assert(text:find("+ordinary outer content", 1, true), "dangling marker hid an ordinary leaf")
			assert(not text:find("ignored object", 1, true))
			assert(not text:find("OUTSIDE PRIVATE", 1, true))
			assert(not text:find("Index: vendor/file-link", 1, true), "patch must keep its regular-file-only policy")
			local dir = h.tempdir()
			h.exec({ "svn", "checkout", h.file_url(f.repo), dir .. "/wc" }, dir)
			write(dir .. "/patch.diff", text)
			h.exec({ "svn", "patch", dir .. "/patch.diff" }, dir .. "/wc")
			assert(uv.fs_stat(dir .. "/wc/vendor/ordinary.txt"), "ordinary addition did not apply")
		end),
	}
	cases[#cases + 1] = {
		"test_patch_ownership_cancel_during_admin_lookup_suppresses_callback",
		guard(function()
			local f = fixture()
			local original, held = uv.fs_stat, nil
			uv.fs_stat = function(path, done)
				if path == f.root .. "/vendor/.git" and done then
					held = done
					return {}
				end
				return original(path, done)
			end
			local called = false
			local task = require("lazyvcs").patch({
				path = f.root,
				on_done = function()
					called = true
				end,
			})
			ctx.wait_for(function()
				return held
			end, "shared admin lookup was not reached", 15000)
			task:cancel()
			assert(held)(nil, nil)
			vim.wait(50)
			assert(task.cancelled and not called, "canceled patch published a late traversal result")
		end),
	}
	cases[#cases + 1] = {
		"test_patch_ownership_missing_errors_and_flat_path_budget_remain_strict",
		guard(function()
			local f = fixture()
			local function collect(paths)
				local result, failure, done
				local task = require("lazyvcs.backends.task").new(function(value, err)
					result, failure, done = value, err, true
				end)
				require("lazyvcs.backends.patch_svn").files(task, { root = f.root }, paths, function(fn)
					return function(...)
						if task:is_active() then
							fn(...)
						end
					end
				end, function(files)
					task:finish(files)
				end)
				ctx.wait_for(function()
					return done
				end, "patch walker did not settle", 15000)
				return result, failure
			end
			local result, err = collect({ f.root .. "/missing" })
			assert(not result and tostring(err):find("ENOENT", 1, true), "missing patch leaf silently disappeared")
			local lstat = uv.fs_lstat
			uv.fs_lstat = function(path, done)
				if path == f.root .. "/unreadable" and done then
					vim.schedule(function()
						done("EACCES: denied", nil)
					end)
					return {}
				end
				return lstat(path, done)
			end
			result, err = collect({ f.root .. "/unreadable" })
			assert(not result and tostring(err):find("EACCES", 1, true), "unreadable leaf silently disappeared")
			uv.fs_lstat = lstat
			local many = {}
			for index = 1, 10001 do
				many[index] = f.root .. "/missing-" .. index
			end
			result, err = collect(many)
			assert(not result and tostring(err):find("Too many unversioned paths", 1, true), "flat path cap was lost")
			local done, original = false, require("lazyvcs.backends.task").new()
			require("lazyvcs.backends.svn_untracked").expand(original, { root = f.root }, {
				{ path = f.root .. "/missing", wc_item = "unversioned" },
			}, function(files, why)
				assert(files and #files == 0 and not why, "default SVN missing-leaf policy changed")
				done = true
			end)
			ctx.wait_for(function()
				return done
			end, "default walker did not settle", 15000)
		end),
	}
	cases[#cases + 1] = {
		"test_patch_ownership_missing_scan_is_strict_without_changing_legacy_skip",
		guard(function()
			local f = fixture()
			local scan = uv.fs_scandir
			uv.fs_scandir = function(path, done)
				if path == f.root .. "/vendor" and done then
					vim.schedule(function()
						done("ENOENT: vanished directory", nil)
					end)
					return {}
				end
				return scan(path, done)
			end
			local text, failure, finished
			require("lazyvcs").patch({
				path = f.root,
				on_done = function(value, err)
					text, failure, finished = value, err, true
				end,
			})
			ctx.wait_for(function()
				return finished
			end, "missing patch scan did not settle", 15000)
			assert(not text and tostring(failure):find("ENOENT", 1, true), "missing scan was silently skipped")
			local done, task = false, require("lazyvcs.backends.task").new()
			require("lazyvcs.backends.svn_untracked").expand(task, { root = f.root }, {
				{ path = f.root .. "/vendor", wc_item = "unversioned" },
			}, function(files, err)
				assert(files and #files == 0 and not err, "legacy missing-directory skip changed")
				done = true
			end)
			ctx.wait_for(function()
				return done
			end, "legacy missing scan did not settle", 15000)
		end),
	}
	return cases
end
