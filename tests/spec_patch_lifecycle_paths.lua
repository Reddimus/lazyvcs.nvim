return function(ctx)
	local h, api = ctx.helpers, vim.api
	local util = require("lazyvcs.util")
	local cases = {}
	local function write(path, text)
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
		ctx.wait_for(fn, "patch lifecycle/path regression did not settle", 15000)
	end
	local function keys(text)
		api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local group, handles
	local function open(opts)
		local task = require("lazyvcs").patch(opts)
		handles[#handles + 1] = task
		return task
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_lifecycle_paths_" .. name,
			function()
				local start = util.system_start
				group = api.nvim_create_augroup("lazyvcs_patch_lifecycle_paths", { clear = true })
				handles = {}
				local ok, err = xpcall(fn, debug.traceback)
				api.nvim_del_augroup_by_id(group)
				util.system_start = start
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				assert(ok, err)
			end,
		}
	end
	for _, close in ipairs({ false, true }) do
		case(close and "filetype_close_constructor" or "filetype_constructor_normal", function()
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local original = api.nvim_get_current_buf()
			api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved constructor control" })
			local fired, starts = false, 0
			local start = util.system_start
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, callback)
				starts = starts + 1
				return start(args, opts, callback)
			end
			api.nvim_create_autocmd("FileType", {
				group = group,
				pattern = "diff",
				once = true,
				callback = function()
					fired = true
					if close then
						api.nvim_win_close(api.nvim_get_current_win(), true)
					end
				end,
			})
			local task = open({ path = f.root })
			assert(fired, "native FileType hook did not run")
			if close then
				assert(starts == 0, "constructor collected after FileType closed the view")
				assert(task.cancelled and not task:is_active(), "constructor did not return a canceled handle")
			else
				wait(function()
					return task.done
				end)
				assert(starts > 0 and not task.cancelled, "normal FileType hook blocked collection")
			end
			assert(api.nvim_buf_is_valid(original) and vim.bo[original].modified)
			assert(api.nvim_buf_get_lines(original, 0, -1, false)[1] == "unsaved constructor control")
		end)
	end
	for _, reload in ipairs({ false, true }) do
		case(reload and "reload_close_before_collection" or "initial_close_before_collection", function()
			local f = h.make_git_fixture()
			if reload then
				local initial = open({ path = f.root })
				wait(function()
					return initial.done
				end)
			end
			local closed, hidden, starts = false, 0, 0
			local original = util.system_start
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, callback)
				if closed then
					starts = starts + 1
				end
				return original(args, opts, callback)
			end
			api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
				group = group,
				callback = function(event)
					if api.nvim_buf_get_name(event.buf):match("^lazyvcs://patch/") then
						hidden = hidden + 1
					end
				end,
			})
			api.nvim_create_autocmd("OptionSet", {
				group = group,
				pattern = "winbar",
				nested = true,
				callback = function()
					if
						not closed
						and api.nvim_buf_get_name(0):match("^lazyvcs://patch/")
						and vim.wo.winbar:find("LOADING", 1, true)
					then
						closed = true
						api.nvim_win_close(api.nvim_get_current_win(), true)
					end
				end,
			})
			local task = open({ path = f.root })
			vim.wait(100, function()
				return false
			end, 10)
			assert(
				closed and hidden > 0,
				"native close callback/BufHidden did not run: " .. vim.inspect({ closed = closed, hidden = hidden })
			)
			assert(starts == 0, "VCS commands started after the loading view was closed: " .. starts)
			assert(task.cancelled and not task:is_active(), "closed view returned an unsettled task")
		end)
	end
	case("loading_rerun_keeps_new_request", function()
		local f = h.make_git_fixture()
		write(f.root .. "/loose", "new request must exclude this\n")
		local replacement
		api.nvim_create_autocmd("OptionSet", {
			group = group,
			pattern = "winbar",
			nested = true,
			callback = function()
				if not replacement and vim.wo.winbar:find("LOADING", 1, true) then
					replacement = true
					replacement = open({ path = f.root, include_untracked = false })
				end
			end,
		})
		local superseded = open({ path = f.root, include_untracked = true })
		assert(type(replacement) == "table", "native reload callback did not run")
		wait(function()
			return replacement.done
		end)
		assert(superseded ~= replacement and superseded.cancelled, "superseded rerun returned the newer task")
		assert(not replacement.cancelled, "old rerun canceled the replacement request")
		local text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
		assert(text:find("+changed", 1, true))
		assert(not text:find("new request must exclude this", 1, true), "old request replaced newer options")
	end)
	for _, close in ipairs({ false, true }) do
		case(close and "loading_closes_later_window" or "loading_multiple_windows_normal", function()
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local original = api.nvim_get_current_buf()
			api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved multiple-window control" })
			local initial = open({ path = f.root })
			wait(function()
				return initial.done
			end)
			local buf = api.nvim_get_current_buf()
			vim.cmd.vsplit()
			local wins = vim.fn.win_findbuf(buf)
			assert(#wins == 2, "native split did not clone the patch buffer")
			api.nvim_set_current_win(wins[1])
			local fired = false
			api.nvim_create_autocmd("OptionSet", {
				group = group,
				pattern = "winbar",
				nested = true,
				callback = function()
					if not fired and vim.wo.winbar:find("LOADING", 1, true) then
						fired = true
						if close then
							api.nvim_win_close(wins[2], true)
						end
					end
				end,
			})
			local task = open({ path = f.root })
			wait(function()
				return task.done
			end)
			assert(fired, "native title callback did not run")
			assert(not task.cancelled and api.nvim_buf_is_valid(buf))
			assert(api.nvim_win_is_valid(wins[2]) ~= close, "callback did not close the later captured window")
			local title = util.get_win_option(wins[1], "winbar")
			assert(type(title) == "string" and not title:find("LOADING", 1, true))
			assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("+changed", 1, true))
			assert(vim.bo[original].modified)
			assert(api.nvim_buf_get_lines(original, 0, -1, false)[1] == "unsaved multiple-window control")
			if api.nvim_win_is_valid(wins[2]) then
				api.nvim_win_close(wins[2], true)
			end
		end)
	end
	for _, staged in ipairs({ false, true }) do
		case(staged and "staged_index_bytes_unchanged" or "clean_index_bytes_unchanged", function()
			local f = h.make_git_fixture()
			h.exec({ "git", "config", "diff.autoRefreshIndex", "true" }, f.root)
			if staged then
				write(f.file, "staged exact bytes\n")
				h.exec({ "git", "add", "--", "sample.txt" }, f.root)
				write(f.file, "different working bytes\n")
			else
				h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
			end
			assert(vim.uv.fs_utime(f.file, 1700000000, 1700000000))
			local blob = h.exec({ "git", "show", ":sample.txt" }, f.root)
			local index = read(f.root .. "/.git/index")
			local done, text, failure
			open({
				path = f.root,
				include_untracked = false,
				on_done = function(value, err)
					text, failure, done = value, err, true
				end,
			})
			wait(function()
				return done
			end)
			assert(text, failure)
			assert(read(f.root .. "/.git/index") == index, "read-only patch refreshed index bytes")
			assert(h.exec({ "git", "show", ":sample.txt" }, f.root) == blob, "patch changed the staged object")
			if staged then
				assert(text:find("+different working bytes", 1, true))
			else
				assert(text == "", "clean content unexpectedly produced a patch")
			end
		end)
	end
	for _, kind in ipairs({ "tracked_ordinary", "tracked_ambiguous", "untracked_ambiguous", "rename" }) do
		case("binary_navigation_" .. kind, function()
			local f = h.make_git_fixture()
			local rel = kind == "tracked_ordinary" and "ordinary.bin" or "folder and b/leaf.bin"
			vim.fn.mkdir(f.root .. "/folder and b", "p")
			local original = kind == "rename" and "original.bin" or rel
			write(f.root .. "/" .. original, "original\0binary")
			if kind ~= "untracked_ambiguous" then
				h.exec({ "git", "add", "--", original }, f.root)
				h.exec({ "git", "commit", "-m", "binary fixture" }, f.root)
			end
			if kind == "rename" then
				h.exec({ "git", "mv", "--", original, rel }, f.root)
			else
				write(f.root .. "/" .. rel, "changed\0binary")
			end
			local task = open({ path = f.root })
			wait(function()
				return task.done
			end)
			local found
			for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
				if (kind == "rename" and line:match("^rename to ")) or line:match("^Binary files ") then
					api.nvim_win_set_cursor(0, { row, 0 })
					found = true
					break
				end
			end
			assert(found, "native binary/rename fixture did not produce its header")
			keys("gf")
			assert(api.nvim_buf_get_name(0) == f.root .. "/" .. rel, "binary navigation selected the wrong entry")
		end)
	end
	return cases
end
