return function(ctx)
	local fs, identity = require("lazyvcs.backends.patch_io"), require("lazyvcs.backends.patch_path")
	local function metadata(path)
		local value, failure, done
		fs.fs_lstat(path, function(err, entry)
			failure, value, done = err, entry, true
		end)
		ctx.wait_for(function()
			return done
		end, "Git entry fixture metadata did not settle", 15000)
		assert(value, failure)
		return value
	end
	local h, uv, util = ctx.helpers, vim.uv, require("lazyvcs.util")
	local patch = require("lazyvcs.patch")
	local cases = {}
	local function write(path, bytes)
		local f = assert(io.open(path, "wb"))
		assert(f:write(bytes))
		assert(f:close())
	end
	local function wait(fn, message)
		ctx.wait_for(fn, message or "Git patch entry did not settle", 10000)
	end
	local function link(target, path, directory)
		local ok, err =
			uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and directory and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_patch_git_entry_" .. name,
			function()
				local start, realpath = util.system_start, uv.fs_realpath
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				util.system_start, uv.fs_realpath = start, realpath
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	local function fixture()
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
		h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
		vim.fn.mkdir(f.root .. "/loose")
		f.leaf = f.root .. "/loose/child.txt"
		f.original = "original owned entry\n"
		write(f.leaf, f.original)
		return f
	end
	local function collect(path)
		local out = {}
		local request = patch.open({
			path = path,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		return out, request
	end
	local function child(args)
		return args[1] == "git" and vim.tbl_contains(args, "--no-index")
	end
	for _, bytes in ipairs({ "dash filename bytes\nlast", "" }) do
		for _, selected in ipairs({ false, true }) do
			add("dash_filename_" .. tostring(selected) .. (bytes == "" and "_empty" or ""), function()
				local f = fixture()
				write(f.root .. "/-", bytes)
				local out = collect(selected and f.root .. "/-" or f.root)
				wait(function()
					return out.done
				end)
				assert(out.text and out.text:find("diff --git ./- ./-", 1, true), out.err or "dash file omitted")
				if bytes ~= "" then
					assert(out.text:find("+dash filename bytes", 1, true), "dash file content omitted")
				end
				if selected then
					assert(not out.text:find("+original owned entry", 1, true), "selected dash file widened scope")
				end
				local destination = h.tempdir() .. "/wc"
				h.exec({ "git", "clone", f.root, destination }, vim.fs.dirname(destination))
				local patchfile = h.tempdir() .. "/dash.patch"
				write(patchfile, out.text)
				h.exec({ "git", "apply", "--check", patchfile }, destination)
				h.exec({ "git", "apply", patchfile }, destination)
				local file = assert(io.open(destination .. "/-", "rb"))
				assert(file:read("*a") == bytes, "native apply changed the dash file")
				assert(file:close())
				if selected then
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local task = patch.open({ path = f.root .. "/-" })
					wait(function()
						return task.done
					end)
					local api = vim.api
					local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
					local ok, err = xpcall(function()
						local row
						for index, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
							if line == "diff --git ./- ./-" then
								row = index
								break
							end
						end
						api.nvim_win_set_cursor(win, { assert(row), 0 })
						local opened = false
						for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
							if map.lhs == "<CR>" then
								map.callback()
								opened = true
								break
							end
						end
						assert(
							opened and api.nvim_buf_get_name(0) == f.root .. "/-",
							"dash header navigation lost its file"
						)
						assert(vim.bo.buftype == "" and vim.bo.modifiable, "dash jump did not use a normal buffer")
					end, debug.traceback)
					if api.nvim_win_is_valid(win) then
						api.nvim_win_close(win, true)
					end
					assert(ok, err)
				end
			end)
		end
	end
	for _, timing in ipairs({ "before_check", "before_child", "after_child" }) do
		for _, kind in ipairs({ "parent", "file" }) do
			add(kind .. "_replacement_" .. timing, function()
				local f, foreign = fixture(), h.tempdir()
				local bytes = "replacement fixture " .. vim.fn.sha256(foreign .. uv.hrtime()) .. "\n"
				write(foreign .. "/child.txt", bytes)
				local swapped, started, native = false, 0, nil
				local function swap()
					assert(not swapped)
					swapped = true
					if kind == "parent" then
						assert(uv.fs_rename(f.root .. "/loose", f.root .. "/loose.saved"))
						link(foreign, f.root .. "/loose", true)
					else
						assert(uv.fs_rename(f.leaf, f.leaf .. ".saved"))
						write(f.leaf, bytes)
					end
				end
				local start = util.system_start
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, callback)
					if child(args) then
						started = started + 1
						if timing == "before_child" then
							swap()
						end
						return start(args, opts, function(result, err, raw)
							native = result or raw
							if timing == "after_child" then
								swap()
							end
							callback(result, err, raw)
						end)
					elseif timing == "before_check" and vim.tbl_contains(args, "ls-files") then
						return start(args, opts, function(result, err, raw)
							swap()
							callback(result, err, raw)
						end)
					end
					return start(args, opts, callback)
				end
				local out = collect(f.root)
				wait(function()
					return out.done
				end)
				if timing == "before_check" and kind == "file" then
					assert(swapped and out.text and out.text:find(bytes, 1, true), out.err)
				else
					assert(swapped and not out.text and out.err, "changed entry was published")
				end
				if timing == "before_check" and kind == "parent" then
					assert(started == 0, "changed parent reached native child")
				elseif timing ~= "before_check" then
					assert(native and native.code == 1, "expected actual native difference")
					assert(native.stdout:find(timing == "before_child" and bytes or f.original, 1, true))
				end
			end)
		end
	end
	add("missing_after_native_child_is_not_published", function()
		local f, start, called = fixture(), util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			return start(args, opts, function(result, err, raw)
				if child(args) then
					called = true
					assert(uv.fs_unlink(f.leaf))
				end
				callback(result, err, raw)
			end)
		end
		local out = collect(f.root)
		wait(function()
			return out.done
		end)
		assert(called and not out.text and out.err, "vanished entry was published")
	end)
	add("same_inode_edit_before_child_remains_native", function()
		local f, start = fixture(), util.system_start
		local before = metadata(f.leaf)
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			if child(args) then
				write(f.leaf, "updated same entry\n")
			end
			return start(args, opts, callback)
		end
		local out = collect(f.root)
		wait(function()
			return out.done
		end)
		local after = metadata(f.leaf)
		assert(identity.same(before, after))
		assert(out.text and out.text:find("+updated same entry", 1, true), out.err)
	end)
	add("cancel_after_child_before_metadata_drops_late_callback", function()
		local f, start, realpath = fixture(), util.system_start, uv.fs_realpath
		local completed, held = false, nil
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			return start(args, opts, function(result, err, raw)
				if child(args) then
					completed = true
				end
				callback(result, err, raw)
			end)
		end
		uv.fs_realpath = function(path, callback)
			if callback and path == f.root .. "/loose" and completed then
				return realpath(path, function(err, physical)
					held = function()
						callback(err, physical)
					end
				end)
			end
			return realpath(path, callback)
		end
		local out, request = collect(f.root)
		wait(function()
			return held or out.done
		end)
		assert(held, "native child output bypassed metadata validation")
		request:cancel()
		held()
		vim.wait(30)
		assert(not out.done, "cancelled late metadata published a patch")
	end)
	add("cancel_before_child_drops_late_parent_metadata", function()
		local f, start, realpath = fixture(), util.system_start, uv.fs_realpath
		local held, started = nil, 0
		uv.fs_realpath = function(path, callback)
			if callback and path == f.root .. "/loose" then
				return realpath(path, function(err, physical)
					held = function()
						callback(err, physical)
					end
				end)
			end
			return realpath(path, callback)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			if child(args) then
				started = started + 1
			end
			return start(args, opts, callback)
		end
		local out, request = collect(f.root)
		wait(function()
			return held or out.done
		end)
		assert(held and not out.done, "precheck did not hold native child")
		request:cancel()
		held()
		vim.wait(30)
		assert(started == 0 and not out.done, "cancelled metadata started a native child")
	end)
	add("file_becoming_link_after_precheck_is_not_published", function()
		local f, start = fixture(), util.system_start
		local foreign = h.tempdir() .. "/target"
		write(foreign, "fixture target bytes\n")
		local native
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			if child(args) then
				assert(uv.fs_rename(f.leaf, f.leaf .. ".saved"))
				link(foreign, f.leaf, false)
				return start(args, opts, function(result, err, raw)
					native = result or raw
					callback(result, err, raw)
				end)
			end
			return start(args, opts, callback)
		end
		local out = collect(f.root)
		wait(function()
			return out.done
		end)
		assert(native and native.stdout:find("120000", 1, true), "native link patch missing")
		assert(not out.text and out.err, "changed entry type was published")
	end)
	add("literal_native_attributes_modes_and_directory_alias", function()
		local f = fixture()
		local name = vim.fn.has("win32") == 1 and "literal-[x].txt" or "literal-[?]*.txt"
		write(f.root .. "/loose/" .. name, "literal raw\r\nlast")
		write(f.root .. "/.gitattributes", "loose/child.txt -diff\n")
		h.exec({ "git", "add", ".gitattributes" }, f.root)
		h.exec({ "git", "commit", "-m", "native attributes" }, f.root)
		if vim.fn.has("win32") == 0 then
			assert(uv.fs_chmod(f.leaf, 493))
		end
		local alias = h.tempdir() .. "/context"
		link(f.root, alias, true)
		local out = collect(alias)
		wait(function()
			return out.done
		end)
		assert(out.text, out.err)
		for _, file in ipairs({ "loose/child.txt", "loose/" .. name }) do
			local native = vim.system({
				"git",
				"-c",
				"core.quotepath=false",
				"-c",
				"diff.suppressBlankEmpty=false",
				"diff",
				"--no-ext-diff",
				"--no-color",
				"--no-textconv",
				"--src-prefix=a/",
				"--dst-prefix=b/",
				"--no-index",
				"--",
				"/dev/null",
				file,
			}, { cwd = f.root, text = false }):wait()
			assert(native.code == 1 and out.text:find(native.stdout, 1, true), "native patch bytes changed")
		end
		assert(out.text:find("Binary files", 1, true))
		if vim.fn.has("win32") == 0 then
			assert(out.text:find("100755", 1, true))
		end
	end)
	add("stable_file_link_keeps_native_link_patch", function()
		local f, foreign = fixture(), h.tempdir() .. "/target"
		write(foreign, "fixture target contents stay outside patch\n")
		assert(uv.fs_unlink(f.leaf))
		link(foreign, f.leaf, false)
		local out = collect(f.root)
		wait(function()
			return out.done
		end)
		assert(out.text and out.text:find("120000", 1, true), out.err)
		assert(out.text:find("+" .. foreign, 1, true))
		assert(not out.text:find("fixture target contents", 1, true))
	end)
	return cases
end
