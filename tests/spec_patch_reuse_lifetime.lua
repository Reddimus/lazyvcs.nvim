return function(ctx)
	local h, api, util = ctx.helpers, vim.api, require("lazyvcs.util")
	local cases, handles, group = {}, {}, nil
	local function wait(fn)
		ctx.wait_for(fn, "patch reuse lifetime did not settle", 15000)
	end
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function read(path)
		local fd = assert(io.open(path, "rb"))
		local bytes = fd:read("*a")
		assert(fd:close())
		return bytes
	end
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function open(opts)
		local task = require("lazyvcs").patch(opts)
		handles[#handles + 1] = task
		return task
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_reuse_lifetime_" .. name,
			function()
				local start, ignorecase, notify = util.system_start, vim.o.fileignorecase, vim.notify
				local errors = {}
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					end
				end
				handles = {}
				group = api.nvim_create_augroup("lazyvcs_patch_reuse_lifetime", { clear = true })
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				api.nvim_del_augroup_by_id(group)
				util.system_start, vim.o.fileignorecase, vim.notify = start, ignorecase, notify
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				h.cleanup()
				if not ok then
					error(err, 0)
				end
				assert(#errors == 0, table.concat(errors, "; "))
			end,
		}
	end
	local function fixture()
		local f = h.make_git_fixture()
		write(f.root .. "/loose", "untracked old request bytes\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		f.editor, f.original = api.nvim_get_current_win(), api.nvim_get_current_buf()
		api.nvim_buf_set_lines(f.original, 0, -1, false, { "owned unsaved original", "retained bytes" })
		local task = open({ path = f.root })
		f.win, f.buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		wait(function()
			return task.done
		end)
		assert(text(f.buf):find("+untracked old request bytes", 1, true))
		return f
	end
	local function preserved(f)
		assert(api.nvim_buf_is_valid(f.original) and vim.bo[f.original].modified)
		assert(text(f.original) == "owned unsaved original\nretained bytes")
	end
	local function count_starts()
		local start, count = util.system_start, 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(...)
			count = count + 1
			return start(...)
		end
		return function()
			return count
		end
	end
	for _, mode in ipairs({ "normal", "close", "rebind", "rebind_copy", "replace_view", "newer_reload" }) do
		case("WinEnter_" .. mode, function()
			local f = fixture()
			if mode == "rebind_copy" then
				vim.cmd.split()
			end
			api.nvim_set_current_win(f.editor)
			local target = vim.fn.win_findbuf(f.buf)[1]
			local fired, replacement, replacement_buf = 0, nil, nil
			api.nvim_create_autocmd("WinEnter", {
				group = group,
				nested = true,
				callback = function()
					if api.nvim_get_current_win() ~= target or fired > 0 then
						return
					end
					fired = fired + 1
					if mode == "close" or mode == "replace_view" then
						api.nvim_win_close(target, true)
					elseif mode == "rebind" or mode == "rebind_copy" then
						replacement_buf = api.nvim_create_buf(false, true)
						api.nvim_buf_set_lines(replacement_buf, 0, -1, false, { "replacement editor bytes" })
						api.nvim_win_set_buf(target, replacement_buf)
					end
					if mode == "replace_view" or mode == "newer_reload" then
						replacement = open({ path = f.root, include_untracked = false })
					end
				end,
			})
			local starts = count_starts()
			local task = open({ path = f.root })
			assert(fired == 1, "native WinEnter hook did not run once")
			if mode == "normal" then
				wait(function()
					return task.done
				end)
				assert(starts() > 0 and not task.cancelled)
			else
				assert(task.cancelled and not task:is_active(), "retired focus request was revived")
				if replacement then
					wait(function()
						return replacement.done
					end)
					local buf = api.nvim_get_current_buf()
					assert(not replacement.cancelled and text(buf):find("+changed", 1, true))
					assert(
						not text(buf):find("untracked old request bytes", 1, true),
						"old caller replaced newer options"
					)
				else
					assert(starts() == 0, "retired focus request started collection")
				end
			end
			if replacement_buf then
				assert(api.nvim_win_get_buf(target) == replacement_buf)
				assert(text(replacement_buf) == "replacement editor bytes")
			end
			if mode == "rebind_copy" then
				assert(api.nvim_buf_is_valid(f.buf) and text(f.buf):find("+untracked old request bytes", 1, true))
			end
			preserved(f)
		end)
	end
	for _, option in ipairs({
		"modifiable",
		"fileformat",
		"fileencoding",
		"bomb",
		"endofline",
		"fixendofline",
		"modified",
	}) do
		case("fill_close_" .. option, function()
			local f, fired = fixture(), 0
			api.nvim_create_autocmd("OptionSet", {
				group = group,
				pattern = option,
				nested = true,
				callback = function()
					if api.nvim_get_current_buf() == f.buf and fired == 0 then
						fired = fired + 1
						api.nvim_win_close(f.win, true)
					end
				end,
			})
			local starts = count_starts()
			local task = open({ path = f.root })
			assert(fired == 1 and task.cancelled and not task:is_active())
			assert(starts() == 0, "retired render started collection")
			preserved(f)
		end)
	end
	for _, newer in ipairs({ false, true }) do
		case(newer and "fill_newer_reload" or "fill_noop_hook", function()
			local f, fired, replacement = fixture(), 0, nil
			api.nvim_create_autocmd("OptionSet", {
				group = group,
				pattern = "modifiable",
				nested = true,
				callback = function()
					if api.nvim_get_current_buf() == f.buf and fired == 0 then
						fired = fired + 1
						if newer then
							replacement = open({ path = f.root, include_untracked = false })
						end
					end
				end,
			})
			local task = open({ path = f.root })
			assert(fired == 1)
			if newer then
				assert(task.cancelled and replacement and not replacement.cancelled)
				wait(function()
					return replacement.done
				end)
				assert(not text(f.buf):find("untracked old request bytes", 1, true))
			else
				wait(function()
					return task.done
				end)
				assert(not task.cancelled and text(f.buf):find("+untracked old request bytes", 1, true))
			end
			preserved(f)
		end)
	end
	for _, vcs in ipairs({ "git", "svn" }) do
		for _, ignorecase in ipairs({ false, true }) do
			for index, parent in ipairs({ "caf\195\169", "cafe\204\129" }) do
				case("Unicode_parent_" .. vcs .. "_" .. tostring(ignorecase) .. "_" .. index, function()
					vim.o.fileignorecase = ignorecase
					local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
					if vcs == "git" then
						h.exec({ "git", "config", "core.precomposeUnicode", "true" }, f.root)
					end
					local rel, bytes = parent .. "/leaf @.txt", "Unicode parent bytes\nlast"
					vim.fn.mkdir(f.root .. "/" .. parent)
					write(f.root .. "/" .. rel, bytes)
					local out = {}
					open({
						path = f.root .. "/" .. rel,
						on_done = function(value, err)
							out.text, out.err, out.done = value, err, true
						end,
					})
					wait(function()
						return out.done
					end)
					assert(out.text and out.text:find("+Unicode parent bytes", 1, true), out.err)
					assert(not out.text:find("+changed", 1, true), "selected Unicode leaf widened its scope")
					local destination = h.tempdir() .. "/wc"
					if vcs == "git" then
						h.exec({ "git", "clone", f.root, destination }, vim.fs.dirname(destination))
					else
						h.exec({ "svn", "checkout", h.file_url(f.repo), destination }, vim.fs.dirname(destination))
					end
					local patchfile = h.tempdir() .. "/addition.patch"
					write(patchfile, out.text)
					h.exec(vcs == "git" and { "git", "apply", patchfile } or { "svn", "patch", patchfile }, destination)
					assert(read(destination .. "/" .. rel) == bytes, "native apply changed Unicode-parent bytes")
				end)
			end
		end
	end
	return cases
end
