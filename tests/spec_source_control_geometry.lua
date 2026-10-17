return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native, ops = require("lazyvcs.source_control.native"), require("lazyvcs.source_control.ops")
	local function open()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { width = 30, remote_refresh = "manual", auto_expand_width = false },
		})
		local f = h.make_git_fixture()
		local name = "long_界_filename_that_needs_a_wider_sidebar.txt"
		h.write_file(f.root .. "/" .. name, "new\n")
		local s = native.open({ path = f.root })
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "summary not ready", 15000)
		ops.open_repo(s, { type = "repo_changes", path = f.root, extra = { repo_root = f.root } }, function() end)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[f.root].details_loaded
		end, "details not ready", 15000)
		s.lazyvcs_expanded[f.root .. "::section::untracked"] = true
		native.render(s)
		return s, f, name
	end
	local function key(s, lhs)
		for _, map in ipairs(api.nvim_buf_get_keymap(s.bufnr, "n")) do
			if map.lhs == lhs then
				map.callback()
				return
			end
		end
		error("missing mapping " .. lhs)
	end
	local function guarded(fn)
		return function()
			local columns, levels = vim.o.columns, vim.go.undolevels
			local ok, err = xpcall(fn, debug.traceback)
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.o.columns, vim.go.undolevels = columns, levels
			assert(ok, err)
		end
	end
	local function file_line(s, name)
		for index, node in ipairs(s.lazyvcs_line_nodes) do
			if node.type == "file" and node.extra.relpath == name then
				return api.nvim_buf_get_lines(s.bufnr, index - 1, index, false)[1]
			end
		end
		error("file row missing")
	end
	local cases = {
		{
			"test_source_control_sidebar_resize_reflows_rows",
			function()
				vim.o.columns = 160
				local s, _, name = open()
				native.render(s)
				assert(not file_line(s, name):find(name, 1, true))
				local util = require("lazyvcs.util")
				local start, calls = util.system_start, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(...)
					calls = calls + 1
					return start(...)
				end
				local ok, err = xpcall(function()
					local focus, saved_width = api.nvim_get_current_win(), s.lazyvcs_last_user_width
					api.nvim_win_set_width(s.winid, 90)
					for _ = 1, 3 do
						api.nvim_exec_autocmds("WinResized", {})
					end
					ctx.wait_for(function()
						return file_line(s, name):find(name, 1, true)
					end, "widening did not reflow filename", 1000)
					api.nvim_win_set_width(s.winid, 30)
					api.nvim_exec_autocmds("VimResized", {})
					ctx.wait_for(function()
						return not file_line(s, name):find(name, 1, true)
					end, "shrinking did not reflow filename", 1000)
					assert(vim.fn.strdisplaywidth(file_line(s, name)) <= 30, "metadata exceeds resized width")
					assert(api.nvim_get_current_win() == focus and s.lazyvcs_last_user_width == saved_width)
					vim.o.columns = 90
					key(s, "e")
					local small = api.nvim_win_get_width(s.winid)
					vim.o.columns = 240
					api.nvim_exec_autocmds("VimResized", {})
					ctx.wait_for(function()
						return api.nvim_win_get_width(s.winid) > small
					end, "auto-fit ignored editor columns", 1000)
					key(s, "e")
					vim.cmd.tabnew()
					api.nvim_win_set_width(s.winid, 90)
					api.nvim_set_current_tabpage(s.tabid)
					ctx.wait_for(function()
						return file_line(s, name):find(name, 1, true)
					end, "tab entry did not reflow", 1000)
					api.nvim_win_set_width(s.winid, 35)
					api.nvim_exec_autocmds("WinResized", {})
					local replacement = api.nvim_create_buf(false, true)
					api.nvim_win_set_buf(s.winid, replacement)
					vim.wait(30)
					assert(api.nvim_buf_line_count(replacement) == 1)
					native.open({ path = s.path })
					api.nvim_win_set_width(s.winid, 35)
					api.nvim_exec_autocmds("WinResized", {})
					native.close()
					vim.wait(30)
					assert(calls == 0, "resize started VCS commands")
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end,
		},
		{
			"test_source_control_sidebar_renders_do_not_retain_undo",
			function()
				local levels = vim.go.undolevels
				local s = open()
				assert(vim.bo[s.bufnr].undolevels == -1, "sidebar undo remains enabled")
				for _, lhs in ipairs({ "e", "e", "S", "h", "l", "R" }) do
					key(s, lhs)
					vim.wait(30)
				end
				api.nvim_buf_call(s.bufnr, function()
					assert(#vim.fn.undotree().entries == 0, "generated rows retained undo")
				end)
				assert(vim.go.undolevels == levels, "global undo changed")
				api.nvim_set_current_win(s.editor_winid)
				api.nvim_win_set_buf(s.editor_winid, api.nvim_create_buf(true, false))
				api.nvim_buf_set_lines(0, 0, -1, false, { "editable" })
				vim.cmd("normal! A text")
				local edited = api.nvim_buf_get_lines(0, 0, -1, false)
				vim.cmd.undo()
				assert(
					not vim.deep_equal(edited, api.nvim_buf_get_lines(0, 0, -1, false)),
					"ordinary undo did not restore text"
				)
				assert(vim.bo.undolevels ~= -1 and #vim.fn.undotree().entries > 0, "ordinary buffer lost undo")
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
