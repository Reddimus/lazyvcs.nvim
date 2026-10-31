return function(ctx)
	local h, api = ctx.helpers, vim.api
	local cases = {}
	local function write(path, text)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(text))
		assert(fd:close())
	end
	local function keys(k)
		api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "xt", false)
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch reload owner did not settle", 15000)
	end
	local function settled(win)
		wait(function()
			return api.nvim_win_is_valid(win)
				and not api.nvim_get_option_value("winbar", { win = win }):find("LOADING", 1, true)
		end)
	end
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local handles, hooks
	local function open(opts)
		local task = require("lazyvcs").patch(opts)
		handles[#handles + 1] = task
		return task
	end
	local function ui(path)
		local task = open({ path = path })
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		wait(function()
			return task.done
		end)
		return win, buf
	end
	local function anchor(buf)
		for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if line == "+changed" then
				return row
			end
		end
		error("missing native hunk anchor")
	end
	local function title_hook(fn)
		hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", { pattern = "winbar", nested = true, callback = fn })
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_reload_owners_" .. name,
			function()
				handles, hooks = {}, {}
				local notify, cwd = vim.notify, vim.fn.getcwd()
				local ok, err = xpcall(fn, debug.traceback)
				for _, id in ipairs(hooks) do
					pcall(api.nvim_del_autocmd, id)
				end
				vim.notify = notify
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				vim.cmd.cd(cwd)
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	case("native_R_revalidates_original_path_owner", function()
		local f = h.make_git_fixture()
		local child = f.root .. "/nested"
		vim.fn.mkdir(child)
		write(child .. "/loose.txt", "NESTED STAGED OWN BYTES\n")
		local win, buf = ui(child)
		assert(text(buf):find("+NESTED STAGED OWN BYTES", 1, true))
		h.exec({ "git", "init", child }, f.root)
		h.exec({ "git", "add", "loose.txt" }, child)
		assert(
			require("lazyvcs.util").canonical_path(
				h.exec({ "git", "rev-parse", "--show-toplevel" }, child):gsub("\r?\n$", "")
			) == child
		)
		assert(h.exec({ "git", "diff", "--cached" }, child):find("+NESTED STAGED OWN BYTES", 1, true))
		-- Reload remains scoped to its original path even when the window cwd changes.
		api.nvim_set_current_win(win)
		vim.cmd.lcd(h.tempdir())
		keys("R")
		settled(win)
		assert(text(buf):find("+NESTED STAGED OWN BYTES", 1, true), "R retained the cached outer repository owner")
		assert(not text(buf):find("+changed", 1, true), "R changed its captured scope to the cwd")
	end)
	case("negative_cache_then_new_repository", function()
		local root = h.tempdir()
		local first = {}
		open({
			path = root,
			on_done = function(value, err)
				first.text, first.err, first.done = value, err, true
			end,
		})
		wait(function()
			return first.done
		end)
		assert(not first.text and first.err)
		h.exec({ "git", "init", root }, root)
		write(root .. "/added", "new repository bytes\n")
		h.exec({ "git", "add", "added" }, root)
		local second = {}
		open({
			path = root,
			on_done = function(value, err)
				second.text, second.err, second.done = value, err, true
			end,
		})
		wait(function()
			return second.done
		end)
		assert(second.text and second.text:find("+new repository bytes", 1, true), second.err)
	end)
	for _, invoking in ipairs({ 1, 2 }) do
		case("native_R_cursor_split_" .. invoking, function()
			local f = h.make_git_fixture()
			local _, buf = ui(f.root)
			vim.cmd.vsplit()
			local wins, row = vim.fn.win_findbuf(buf), anchor(buf)
			assert(#wins == 2)
			for _, win in ipairs(wins) do
				api.nvim_win_set_cursor(win, { 2, 0 })
			end
			api.nvim_set_current_win(wins[invoking])
			api.nvim_win_set_cursor(wins[invoking], { row, 0 })
			keys("R")
			settled(wins[invoking])
			assert(api.nvim_win_get_cursor(wins[invoking])[1] == row, "R restored the anchor into another patch copy")
		end)
	end
	for _, mode in ipairs({ "close", "retarget" }) do
		case("departed_invoker_" .. mode, function()
			local f = h.make_git_fixture()
			local _, buf = ui(f.root)
			vim.cmd.vsplit()
			local wins, row = vim.fn.win_findbuf(buf), anchor(buf)
			local other, invoking = wins[1], wins[2]
			api.nvim_set_current_win(invoking)
			api.nvim_win_set_cursor(invoking, { row, 0 })
			local fired, replacement = false, nil
			title_hook(function()
				if not fired and tostring(vim.v.option_new):find("LOADING", 1, true) then
					fired = true
					if mode == "close" then
						api.nvim_win_close(invoking, true)
					else
						replacement = api.nvim_create_buf(false, true)
						api.nvim_buf_set_lines(replacement, 0, -1, false, { "unrelated", "retained cursor" })
						api.nvim_win_set_buf(invoking, replacement)
						api.nvim_win_set_cursor(invoking, { 2, 0 })
					end
				end
			end)
			keys("R")
			settled(other)
			assert(fired and api.nvim_win_get_buf(other) == buf)
			assert(api.nvim_win_get_cursor(other)[1] ~= row, "departed invoker's anchor was stolen into another copy")
			if replacement then
				assert(api.nvim_win_get_buf(invoking) == replacement and api.nvim_win_get_cursor(invoking)[1] == 2)
			end
		end)
	end
	case("latest_request_after_final_title_wins", function()
		local f = h.make_git_fixture()
		write(f.root .. "/loose", "superseded untracked content\n")
		local win, buf = ui(f.root)
		api.nvim_win_set_cursor(win, { anchor(buf), 0 })
		local errors, requested = {}, false
		---@type table?
		local replacement
		vim.notify = function(message, level)
			if level == vim.log.levels.ERROR then
				errors[#errors + 1] = tostring(message)
			end
		end
		title_hook(function()
			local value = tostring(vim.v.option_new)
			if not requested and value:find("PATCH | ", 1, true) and not value:find("LOADING", 1, true) then
				requested = true
				replacement = open({ path = f.root, include_untracked = false })
			end
		end)
		keys("R")
		wait(function()
			return type(replacement) == "table" and replacement.done
		end)
		assert(replacement and not replacement.cancelled and text(buf):find("+changed", 1, true))
		assert(not text(buf):find("superseded untracked content", 1, true))
		assert(#errors == 0, "old final-title callback restored a stale cursor: " .. table.concat(errors, ";"))
	end)
	for _, when in ipairs({ "loading", "complete" }) do
		case("other_editor_focus_" .. when, function()
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local editor = api.nvim_get_current_win()
			api.nvim_win_set_cursor(editor, { 2, 0 })
			local win, buf = ui(f.root)
			local row, fired = anchor(buf), false
			api.nvim_win_set_cursor(win, { row, 0 })
			title_hook(function()
				local value = tostring(vim.v.option_new)
				local loading = value:find("LOADING", 1, true) ~= nil
				if not fired and value:find("PATCH | ", 1, true) and loading == (when == "loading") then
					fired = true
					api.nvim_set_current_win(editor)
				end
			end)
			keys("R")
			settled(win)
			assert(fired and api.nvim_win_get_cursor(editor)[1] == 2)
			assert(api.nvim_win_get_cursor(win)[1] == row, "callback focus moved the patch anchor into another editor")
		end)
	end
	return cases
end
