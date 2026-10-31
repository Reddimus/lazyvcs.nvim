return function(ctx)
	local h, uv, api = ctx.helpers, vim.uv, vim.api
	local patch, reader, util = require("lazyvcs.patch"), require("lazyvcs.backends.patch_svn"), require("lazyvcs.util")
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function wait(fn, msg)
		ctx.wait_for(fn, msg or "patch bundle timed out", 15000)
	end
	local function keys(k)
		api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "xt", false)
	end
	local function get(path)
		local r = {}
		patch.open({
			path = path,
			on_done = function(text, err)
				r.text, r.err, r.done = text, err, true
			end,
		})
		wait(function()
			return r.done
		end)
		return r
	end
	local function ui(path)
		local task = patch.open({ path = path })
		wait(function()
			return task.done
		end)
		return api.nvim_get_current_buf()
	end
	local function link(target, path)
		local ok, err = uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture directory link unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_bundle_" .. name,
			function()
				local lstat, open, realpath = uv.fs_lstat, uv.fs_open, uv.fs_realpath
				local start, read = util.system_start, reader.read
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				uv.fs_lstat, uv.fs_open, uv.fs_realpath = lstat, open, realpath
				util.system_start, reader.read = start, read
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	case("cancel_owns_shared_numeric_ignore_job", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/loose", "new leaf\n")
		local original, started, cancelled = util.system_start, false, 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			if args[1] == "svn" and vim.tbl_contains(args, "propget") then
				started = true
				return {
					cancel = function()
						cancelled = cancelled + 1
						vim.schedule(function()
							cb(nil, "Cancelled", { code = 130, cancelled = true, stdout = "", stderr = "Cancelled" })
						end)
					end,
				}
			end
			return original(args, opts, cb)
		end
		local completed = false
		local request = patch.open({
			path = f.root,
			on_done = function()
				completed = true
			end,
		})
		wait(function()
			return started
		end, "shared ignore job did not start")
		request:cancel()
		vim.wait(30)
		assert(cancelled == 1, "cancelling patch did not stop its numeric shared ignore job")
		assert(not completed, "cancelled result published")
	end)
	case("rerun_keeps_no_generated_undo_history", function()
		local f = h.make_git_fixture()
		local buf = ui(f.root)
		for i = 1, 3 do
			write(f.file, "actual rerun " .. i .. "\n")
			keys("R")
			wait(function()
				return table
					.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
					:find("+actual rerun " .. i, 1, true)
			end)
			assert(#vim.fn.undotree().entries == 0, "old patch retained in undo history")
		end
		assert(vim.bo[buf].undolevels == -1)
	end)
	case("git_untracked_count_rejected_before_first_child", function()
		local f = h.make_git_fixture()
		for i = 1, 10001 do
			write(f.root .. "/loose-" .. i, "")
		end
		local start, started = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			if args[1] == "git" and vim.tbl_contains(args, "--no-index") then
				started = true
				return {
					cancel = function()
						vim.schedule(function()
							cb(nil, "Cancelled", { code = 130, cancelled = true, stdout = "", stderr = "Cancelled" })
						end)
					end,
				}
			end
			return start(args, opts, cb)
		end
		local result = {}
		local request = patch.open({
			path = f.root,
			on_done = function(t, e)
				result.text, result.err, result.done = t, e, true
			end,
		})
		wait(function()
			return result.done or started
		end)
		if started then
			request:cancel()
		end
		assert(not started, "untracked cap checked after starting a file child")
		assert(
			not result.text and result.err and result.err:find("10000", 1, true) and result.err:find("narrow", 1, true)
		)
	end)
	case("git_vanished_noindex_exit1_is_error", function()
		local f = h.make_git_fixture()
		local path = f.root .. "/vanishes"
		write(path, "actual loose bytes\n")
		local start, raw = util.system_start, nil
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			if args[1] == "git" and vim.tbl_contains(args, "--no-index") then
				assert(uv.fs_unlink(path))
				return start(args, opts, function(result, err, record)
					raw = record or result
					cb(result, err, record)
				end)
			end
			return start(args, opts, cb)
		end
		local r = get(f.root)
		assert(
			raw and raw.code == 1 and raw.stderr:find("error:", 1, true),
			"native fixture did not produce error exit1"
		)
		assert(not r.text and r.err, "native error exit1 was published as a complete patch")
	end)
	case("git_legitimate_exit1_text_binary_and_warning", function()
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "core.autocrlf", "true" }, f.root)
		h.exec({ "git", "config", "core.safecrlf", "warn" }, f.root)
		write(f.root .. "/text", "actual warning text\n")
		write(f.root .. "/binary", "actual\0binary")
		local start, warning, differences = util.system_start, false, 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			return start(args, opts, function(result, err, raw)
				local value = result or raw
				if vim.tbl_contains(args, "--no-index") and value and value.code == 1 then
					differences = differences + 1
					warning = warning or value.stderr:find("warning:", 1, true) ~= nil
				end
				cb(result, err, raw)
			end)
		end
		local r = get(f.root)
		assert(
			r.text
				and not r.err
				and r.text:find("+actual warning text", 1, true)
				and r.text:find("Binary files", 1, true)
		)
		assert(differences == 2 and warning, "fixture needs native valid difference and warning")
	end)
	for _, quoted in ipairs({ false, true }) do
		case("git_copy_header_enters_destination_" .. tostring(quoted), function()
			local f = h.make_git_fixture()
			local name = quoted and (vim.fn.has("win32") == 1 and "copy-[x].txt" or 'copy-\t"é.txt') or "copied.txt"
			local original = h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
			write(f.root .. "/" .. name, original)
			h.exec({ "git", "add", "--", name }, f.root)
			h.exec({ "git", "config", "diff.renames", "copies" }, f.root)
			local buf = ui(f.root)
			local found = false
			for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
				if line:match("^copy to ") then
					found = true
					api.nvim_win_set_cursor(0, { row, 0 })
					break
				end
			end
			assert(found, "fixture needs native100percent copy header without +++")
			keys("<CR>")
			assert(
				api.nvim_buf_get_name(0) == f.root .. "/" .. name,
				"copy header opened source instead of destination"
			)
			assert(api.nvim_win_get_cursor(0)[1] == 1)
		end)
	end
	for _, timing in ipairs({ "before_read", "before_open", "before_childstat", "same_inode_link" }) do
		case("svn_parent_swap_" .. timing, function()
			local f = h.make_svn_fixture()
			local loose = f.root .. "/loose"
			vim.fn.mkdir(loose)
			local path = loose .. "/child.txt"
			write(path, "inside original leaf\n")
			local outside = h.tempdir()
			local nonce = "outside real nonce " .. vim.fn.sha256(outside .. uv.hrtime()) .. "\n"
			write(outside .. "/child.txt", nonce)
			local replacement = outside .. "-link"
			link(timing == "same_inode_link" and (loose .. ".old") or outside, replacement)
			local swapped = false
			local function swap()
				assert(not swapped)
				swapped = true
				assert(uv.fs_rename(loose, loose .. ".old"))
				assert(uv.fs_rename(replacement, loose))
			end
			local original, held = reader.read, nil
			---@diagnostic disable-next-line: duplicate-set-field
			reader.read = function(task, file, limit, guard, done, identity)
				if file == path then
					held = function()
						original(task, file, limit, guard, done, identity)
					end
				else
					return original(task, file, limit, guard, done, identity)
				end
			end
			local lstat, open = uv.fs_lstat, uv.fs_open
			if timing == "before_childstat" then
				uv.fs_lstat = function(file, cb)
					if file == path and cb and not swapped then
						swap()
					end
					return lstat(file, cb)
				end
			end
			local result = {}
			patch.open({
				path = f.root,
				on_done = function(t, e)
					result.text, result.err, result.done = t, e, true
				end,
			})
			wait(function()
				return held
			end, "walker did not reach child")
			reader.read = original
			if timing == "before_open" then
				uv.fs_open = function(file, flags, mode, cb)
					if file == path and cb then
						swap()
					end
					return open(file, flags, mode, cb)
				end
			elseif timing ~= "before_childstat" then
				swap()
			end
			assert(held)()
			wait(function()
				return result.done
			end)
			assert(
				swapped and not result.text and result.err,
				"parent-directory link exported a patch: " .. tostring(result.text)
			)
			assert(not (result.text or ""):find(nonce, 1, true))
		end)
	end
	for _, change in ipairs({ "edit", "replace", "vanish" }) do
		case("svn_walked_leaf_" .. change, function()
			local f = h.make_svn_fixture()
			local path = f.root .. "/loose"
			write(path, "original leaf\n")
			local original, held, expected = reader.read, nil, nil
			---@diagnostic disable-next-line: duplicate-set-field
			reader.read = function(task, file, limit, guard, done, identity)
				if file == path then
					expected = identity
					held = function()
						original(task, file, limit, guard, done, identity)
					end
				else
					return original(task, file, limit, guard, done, identity)
				end
			end
			local result = {}
			patch.open({
				path = f.root,
				on_done = function(t, e)
					result.text, result.err, result.done = t, e, true
				end,
			})
			wait(function()
				return held
			end)
			if change == "edit" then
				write(path, "same inode new bytes\n")
			elseif change == "replace" then
				assert(uv.fs_rename(path, path .. ".old"))
				write(path, "different inode bytes\n")
			else
				assert(uv.fs_unlink(path))
			end
			reader.read = original
			assert(held)()
			wait(function()
				return result.done
			end)
			if change == "edit" then
				assert(
					result.text and not result.err and result.text:find("+same inode new bytes", 1, true),
					"same-inode edit must remain supported"
				)
			else
				assert(not result.text and result.err, "changed/vanished walked identity accepted")
			end
			assert(expected and expected.ino and expected.parent, "strict walk identity missing")
		end)
	end
	case("svn_parent_realpath_error_fails_closed", function()
		local f = h.make_svn_fixture()
		local dir = f.root .. "/loose"
		vim.fn.mkdir(dir)
		write(dir .. "/child", "leaf\n")
		local realpath, injected = uv.fs_realpath, false
		uv.fs_realpath = function(path, cb)
			if path == dir and cb then
				injected = true
				---@diagnostic disable-next-line: return-type-mismatch
				return vim.schedule(function()
					cb("EIO parent check")
				end)
			end
			return realpath(path, cb)
		end
		local r = get(f.root)
		assert(injected and not r.text and r.err and r.err:find("EIO", 1, true))
	end)
	case("svn_cancel_held_parent_lookup_never_opens", function()
		local f = h.make_svn_fixture()
		local dir = f.root .. "/loose"
		vim.fn.mkdir(dir)
		local path = dir .. "/child"
		write(path, "leaf\n")
		local realpath, open, held, opened = uv.fs_realpath, uv.fs_open, nil, false
		uv.fs_realpath = function(p, cb)
			if p == dir and cb then
				return realpath(p, function(...)
					local values = { ... }
					held = function()
						cb(unpack(values))
					end
				end)
			end
			return realpath(p, cb)
		end
		uv.fs_open = function(p, ...)
			if p == path then
				opened = true
			end
			---@diagnostic disable-next-line: return-type-mismatch
			return open(p, ...)
		end
		local completed = false
		local request = patch.open({
			path = f.root,
			on_done = function()
				completed = true
			end,
		})
		wait(function()
			return held or completed
		end)
		if held then
			request:cancel()
			assert(held)()
			vim.wait(30)
		end
		assert(held and not opened and not completed, "parent lookup cancellation opened/published a late leaf")
	end)
	case("legacy_walk_returns_no_identity_or_parent_io", function()
		local f = h.make_svn_fixture()
		local dir = f.root .. "/loose"
		vim.fn.mkdir(dir)
		local path = dir .. "/child"
		write(path, "ordinary\n")
		local realpath, called = uv.fs_realpath, false
		uv.fs_realpath = function(candidate, ...)
			if candidate == dir then
				called = true
			end
			---@diagnostic disable-next-line: return-type-mismatch
			return realpath(candidate, ...)
		end
		local task = require("lazyvcs.backends.comparison").task()
		local finished = false
		require("lazyvcs.backends.svn_untracked").expand(
			task,
			{ root = f.root, vcs = "svn" },
			{ { path = "loose/child", wc_item = "unversioned" } },
			function(files, err, identities)
				assert(files and #files == 1 and files[1] == "loose/child" and not err and identities == nil)
				finished = true
				task:finish()
			end
		)
		wait(function()
			return finished
		end)
		assert(not called, "legacy walker added per-file physical lookup")
	end)
	return cases
end
