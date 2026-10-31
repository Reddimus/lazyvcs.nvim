return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local util, reader = require("lazyvcs.util"), require("lazyvcs.backends.patch_svn")
	local cases = {}
	local function write(path, text)
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(text))
		assert(fd:close())
	end
	local function read(path)
		local fd = assert(io.open(path, "rb"))
		local text = fd:read("*a")
		assert(fd:close())
		return text
	end
	local function wait(fn)
		ctx.wait_for(fn, "SVN descendant patch did not settle", 15000)
	end
	local function collect(path, include)
		local result = {}
		require("lazyvcs").patch({
			path = path,
			include_untracked = include,
			on_done = function(text, err)
				result.text, result.err, result.done = text, err, true
			end,
		})
		wait(function()
			return result.done
		end)
		return result
	end
	local function fixture(rel, bytes)
		local f = h.make_svn_fixture()
		f.rel, f.selected = rel or "outer/deep/leaf.txt", f.root .. "/" .. (rel or "outer/deep/leaf.txt")
		write(f.selected, bytes or "selected own bytes\n")
		write(f.root .. "/outer/sibling.txt", "SIBLING PRIVATE\n")
		return f
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_svn_descendant_" .. name,
			function()
				local start, scandir, lstat, realpath, open, read_file =
					util.system_start, uv.fs_scandir, uv.fs_lstat, uv.fs_realpath, uv.fs_open, reader.read
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				util.system_start, uv.fs_scandir, uv.fs_lstat, uv.fs_realpath, uv.fs_open, reader.read =
					start, scandir, lstat, realpath, open, read_file
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	case("selected_leaf_never_scans_ancestor_siblings", function()
		local f = fixture()
		local scan, scans = uv.fs_scandir, {}
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_scandir = function(path, ...)
			scans[path] = true
			return scan(path, ...)
		end
		local result = collect(f.selected)
		assert(result.text, result.err)
		assert(result.text:find("Index: " .. f.rel .. "\n", 1, true))
		assert(result.text:find("+selected own bytes", 1, true))
		assert(not result.text:find("SIBLING PRIVATE", 1, true))
		assert(not result.text:find("sample.txt", 1, true))
		assert(not scans[f.root .. "/outer"] and not scans[f.root .. "/outer/deep"], "selected leaf scanned siblings")
	end)
	for _, bytes in ipairs({ "literal bytes\nlast", "" }) do
		case(bytes == "" and "deep_literal_empty_apply" or "deep_literal_text_apply", function()
			local rel = "outer/space @ folder/deep/[x]$HOME@leaf"
			local f = fixture(rel, bytes)
			local result = collect(f.selected)
			assert(result.text, result.err)
			assert(not result.text:find("SIBLING PRIVATE", 1, true))
			local parent = h.tempdir()
			h.exec({ "svn", "checkout", h.file_url(f.repo), parent .. "/wc" }, parent)
			write(parent .. "/addition.diff", result.text)
			h.exec({ "svn", "patch", parent .. "/addition.diff" }, parent .. "/wc")
			assert(read(parent .. "/wc/" .. rel) == bytes, "native SVN patch changed selected bytes")
		end)
	end
	case("selected_directory_prunes_ancestors", function()
		local f = fixture()
		write(f.root .. "/outer/deep/second", "selected second\n")
		local result = collect(f.root .. "/outer/deep")
		assert(result.text, result.err)
		assert(result.text:find("+selected own bytes", 1, true) and result.text:find("+selected second", 1, true))
		assert(not result.text:find("SIBLING PRIVATE", 1, true))
	end)
	case("root_and_native_unversioned_directory_controls", function()
		local f = fixture()
		for _, path in ipairs({ f.root, f.root .. "/outer" }) do
			local result = collect(path)
			assert(result.text, result.err)
			assert(result.text:find("+selected own bytes", 1, true) and result.text:find("+SIBLING PRIVATE", 1, true))
		end
	end)
	case("include_untracked_false", function()
		local f = fixture()
		local result = collect(f.selected, false)
		assert(result.text == "", result.err)
	end)
	for _, kind in ipairs({ "default_leaf", "global_leaf", "local_ancestor", "global_ancestor" }) do
		case("ignored_" .. kind, function()
			local f = fixture(kind == "default_leaf" and "outer/deep/ignored.o" or nil)
			if kind ~= "default_leaf" then
				local property = kind == "local_ancestor" and "svn:ignore" or "svn:global-ignores"
				local pattern = kind == "global_leaf" and "leaf.txt" or "outer"
				h.exec({ "svn", "propset", property, pattern, f.root }, f.root)
			end
			local result = collect(f.selected)
			assert(result.text == "", result.err or "ignored selected content leaked")
		end)
	end
	for _, name in ipairs({ ".git", ".svn" }) do
		case("admin_component_" .. name:sub(2), function()
			local f = fixture("outer/" .. name .. "/private")
			local result = collect(f.selected)
			assert(not result.text or result.text == "", "administrative descendant was exported")
		end)
	end
	case("scoped_walker_keeps_nested_repository_boundary", function()
		local f = fixture()
		local inner = f.root .. "/outer/inner"
		h.exec({ "git", "init", inner }, f.root)
		write(inner .. "/private", "INNER OWNER PRIVATE\n")
		local value, failure, done
		local task = require("lazyvcs.backends.task").new(function(_, err)
			failure, done = err, true
		end)
		local function guard(fn)
			return function(...)
				if task:is_active() then
					fn(...)
				end
			end
		end
		reader.files(task, { root = f.root }, { f.root .. "/outer" }, guard, function(paths)
			value = paths
			task:finish(true)
		end, { selected_path = inner .. "/private" })
		wait(function()
			return done
		end)
		assert(value and #value == 0, failure or "scoped traversal crossed Git boundary")
	end)
	case("file_symlink_is_not_read", function()
		local f = fixture()
		local outside = h.tempdir() .. "/foreign"
		write(outside, "FOREIGN PRIVATE\n")
		assert(uv.fs_unlink(f.selected))
		local ok, err = uv.fs_symlink(outside, f.selected)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "file symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
		local result = collect(f.selected)
		assert(result.text == "", result.err)
	end)
	case("ancestor_status_batches_remain_bounded", function()
		local components = { "outer" }
		for _ = 1, 70 do
			components[#components + 1] = "d"
		end
		components[#components + 1] = "leaf"
		local f = fixture(table.concat(components, "/"))
		local start, batches = util.system_start, 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, callback)
			if args[1] == "svn" and vim.tbl_contains(args, "--depth") then
				batches = batches + 1
				local operands, bytes, after = 0, 0, false
				for _, arg in ipairs(args) do
					if after then
						operands, bytes = operands + 1, bytes + #arg
					elseif arg == "--" then
						after = true
					end
				end
				assert(operands <= 64 and bytes <= 32768, "ancestor query exceeded its argument budget")
			end
			return start(args, opts, callback)
		end
		local result = collect(f.selected)
		assert(result.text and result.text:find("+selected own bytes", 1, true), result.err)
		assert(batches == 2, "deep chain did not use two bounded native batches")
	end)
	for _, kind in ipairs({ "file_replacement", "parent_link" }) do
		case("read_rechecks_" .. kind, function()
			local f = fixture()
			local outside = h.tempdir()
			write(outside .. "/leaf.txt", "FOREIGN REPLACEMENT PRIVATE\n")
			local original, reached, linked = reader.read, false, false
			local link_error
			---@diagnostic disable-next-line: duplicate-set-field
			reader.read = function(task, file, ...)
				if file == f.selected and not reached then
					reached = true
					if kind == "file_replacement" then
						assert(uv.fs_rename(f.selected, f.selected .. ".old"))
						write(f.selected, "FOREIGN REPLACEMENT PRIVATE\n")
					else
						local parent = vim.fs.dirname(f.selected)
						assert(uv.fs_rename(parent, parent .. ".old"))
						local ok, err =
							uv.fs_symlink(outside, parent, vim.fn.has("win32") == 1 and { junction = true } or nil)
						if not ok and vim.fn.has("win32") == 1 then
							link_error = tostring(err)
							error(link_error, 0)
						end
						assert(ok, err)
						linked = true
					end
				end
				return original(task, file, ...)
			end
			local result = collect(f.selected)
			if link_error then
				error({ lazyvcs_skip = "directory link unavailable: " .. link_error }, 0)
			end
			if linked then
				local path = vim.fs.dirname(f.selected)
				assert(uv.fs_unlink(path) or uv.fs_rmdir(path))
			end
			assert(reached and not result.text and result.err, "changed selected identity was exported")
		end)
	end
	case("ancestor_replaced_by_file_never_widens_selection", function()
		local f = fixture()
		local lstat, changed = uv.fs_lstat, false
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_lstat = function(path, callback)
			if path == f.root .. "/outer" and callback and not changed then
				changed = true
				assert(uv.fs_rename(path, path .. ".old"))
				write(path, "ANCESTOR REPLACEMENT PRIVATE\n")
			end
			return lstat(path, callback)
		end
		local result = collect(f.selected)
		assert(changed and not result.text and result.err, "ancestor replacement widened the selected patch")
	end)
	for _, kind in ipairs({ "missing", "error" }) do
		case("chain_lstat_" .. kind, function()
			local f = fixture()
			local lstat, reached = uv.fs_lstat, false
			---@diagnostic disable-next-line: duplicate-set-field
			uv.fs_lstat = function(path, callback)
				if path == f.selected and callback then
					reached = true
					if kind == "missing" then
						assert(uv.fs_unlink(path))
					else
						return lstat(path, function()
							callback("EACCES: controlled selected chain failure")
						end)
					end
				end
				return lstat(path, callback)
			end
			local result = collect(f.selected)
			assert(reached and not result.text and result.err, "selected chain failure did not remain an error")
		end)
	end
	for _, kind in ipairs({ "error", "truncated", "wrong_path", "malformed", "cancel" }) do
		case("ancestor_status_" .. kind, function()
			local f = fixture()
			local start, held, started = util.system_start, nil, false
			local callback, reads = false, 0
			local read_file = reader.read
			---@diagnostic disable-next-line: duplicate-set-field
			reader.read = function(...)
				reads = reads + 1
				return read_file(...)
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, done)
				if args[1] == "svn" and vim.tbl_contains(args, "--depth") then
					started = true
					return start(args, opts, function(value, err, raw)
						if kind == "cancel" then
							held = function()
								done(value, err, raw)
							end
						elseif kind == "wrong_path" or kind == "malformed" then
							assert(value)
							value.stdout = kind == "malformed" and "<status>"
								or '<status><target path="other"><entry path="other"><wc-status item="unversioned" props="none"/></entry></target></status>'
							done(value, nil, value)
						elseif kind == "truncated" then
							assert(value)
							value.stdout_truncated = true
							done(value, nil, value)
						else
							done(
								nil,
								"controlled ancestor status failure",
								{ code = 1, stdout = "", stderr = "failed" }
							)
						end
					end)
				end
				return start(args, opts, done)
			end
			local result = {}
			local task = require("lazyvcs").patch({
				path = f.selected,
				on_done = function(text, err)
					callback, result.text, result.err = true, text, err
				end,
			})
			wait(function()
				return callback or held
			end)
			assert(started, "native ancestor status did not run")
			if kind == "cancel" then
				task:cancel()
				assert(held)()
				vim.wait(30)
				assert(task.cancelled and not callback, "late ancestor status published after cancel")
			else
				assert(not result.text and result.err, "ancestor status failure produced a patch")
			end
			assert(reads == 0, "failed/canceled classification read selected content")
		end)
	end
	return cases
end
