return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, buffers, util =
		require("lazyvcs.compare"), require("lazyvcs.compare_buffers"), require("lazyvcs.util")
	local function guarded(fn)
		return function()
			local opts = {}
			for _, name in ipairs({ "columns", "lines", "winwidth", "winminwidth", "winheight", "winminheight" }) do
				opts[name] = vim.o[name]
			end
			local show, scratch, notify, exec, refresh =
				util.show_win_buffer, buffers.scratch, util.notify, api.nvim_exec2, compare.refresh
			local before = api.nvim_list_bufs()
			local ok, err = xpcall(fn, debug.traceback)
			util.show_win_buffer, buffers.scratch, util.notify, api.nvim_exec2 = show, scratch, notify, exec
			compare.refresh = refresh
			pcall(compare.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			for _, buf in ipairs(api.nvim_list_bufs()) do
				if not vim.tbl_contains(before, buf) then
					pcall(api.nvim_buf_delete, buf, { force = true })
				end
			end
			vim.o.winminwidth, vim.o.winminheight = 0, 0
			vim.o.winwidth, vim.o.winheight = opts.winwidth, opts.winheight
			vim.o.winminwidth, vim.o.winminheight = opts.winminwidth, opts.winminheight
			vim.o.columns, vim.o.lines = opts.columns, opts.lines
			assert(ok, err)
		end
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		return f
	end
	local function loaded(s)
		ctx.wait_for(function()
			return s.preview_result
		end, "constructed comparison did not load", 15000)
		assert(vim.deep_equal(api.nvim_buf_get_lines(s.left, 0, -1, false), { "one", "two", "three" }))
		assert(vim.deep_equal(api.nvim_buf_get_lines(s.right, 0, -1, false), { "one", "changed", "three" }))
	end
	return {
		{
			"test_core_compare_rollback_owns_tab_when_autocmd_switches_tabs",
			guarded(function()
				local f = fixture()
				local origin = api.nvim_get_current_tabpage()
				vim.cmd("tabnew")
				local unrelated = api.nvim_get_current_tabpage()
				api.nvim_set_current_tabpage(origin)
				local tabs, before = api.nvim_list_tabpages(), api.nvim_list_bufs()
				for _, destination in ipairs({ origin, unrelated }) do
					for _, event in ipairs({ "TabNew", "WinEnter" }) do
						local switched, message
						---@diagnostic disable-next-line: duplicate-set-field
						util.notify = function(text)
							message = text
						end
						local autocmd = api.nvim_create_autocmd(event, {
							once = true,
							callback = function()
								local opened = api.nvim_get_current_tabpage()
								api.nvim_set_current_tabpage(destination)
								switched = opened ~= destination and api.nvim_get_current_tabpage() == destination
							end,
						})
						---@diagnostic disable-next-line: duplicate-set-field
						util.show_win_buffer = function()
							error("injected pane failure after tab switch")
						end
						local ok, s = pcall(compare.open, { path = f.root, base = "HEAD" })
						pcall(api.nvim_del_autocmd, autocmd)
						assert(switched, event .. " autocmd did not switch tabs")
						assert(ok and not s, "redirected comparison did not fail safely")
						assert(
							message and message:find("Comparison tab changed while opening", 1, true),
							"redirected comparison did not report the changed tab: " .. tostring(message)
						)
						assert(api.nvim_tabpage_is_valid(unrelated), "rollback closed an unrelated tab")
						assert(vim.deep_equal(api.nvim_list_tabpages(), tabs), "rollback left an orphan comparison tab")
						assert(vim.deep_equal(api.nvim_list_bufs(), before), "rollback left scratch buffers")
						assert(api.nvim_get_current_tabpage() == origin, "rollback lost origin focus")
					end
				end
			end),
		},
		{
			"test_core_compare_opens_stacked_with_large_minimum_width",
			guarded(function()
				local f = fixture()
				vim.o.columns, vim.o.lines = 100, 35
				vim.o.winwidth = 40
				vim.o.winminwidth = 40
				local tabs = #api.nvim_list_tabpages()
				local s = assert(
					compare.open({ editable = false, path = f.root, base = "HEAD" }),
					"feasible stacked comparison did not open"
				)
				loaded(s)
				local left, right = api.nvim_win_get_position(s.leftwin), api.nvim_win_get_position(s.rightwin)
				assert(s.stacked and left[2] == right[2] and left[1] < right[1], "comparison panes were not stacked")
				for _, win in ipairs({ s.sidewin, s.leftwin, s.rightwin }) do
					assert(api.nvim_win_get_width(win) >= 40, "pane violated winminwidth")
				end
				local owned = { s.sidebar, s.message_left, s.message_right, s.left, s.right }
				compare.close(s)
				assert(#api.nvim_list_tabpages() == tabs)
				for _, buf in ipairs(owned) do
					assert(not api.nvim_buf_is_valid(buf), "closed comparison retained scratch buffer")
				end
			end),
		},
		{
			"test_core_compare_failed_construction_rolls_back",
			guarded(function()
				local f = fixture()
				vim.o.columns, vim.o.lines = 160, 40
				local origin, tabs, before = api.nvim_get_current_win(), api.nvim_list_tabpages(), api.nvim_list_bufs()
				local show, scratch, exec, refresh =
					util.show_win_buffer, buffers.scratch, api.nvim_exec2, compare.refresh
				for _, phase in ipairs({ "preview", "allocation", "tab", "initialization", "infeasible", "refresh" }) do
					local calls, messages = 0, {}
					---@diagnostic disable-next-line: duplicate-set-field
					api.nvim_exec2 = function(command, ...)
						local result = exec(command, ...)
						if phase == "tab" and command == "tab split" then
							error("injected tab creation failure")
						end
						return result
					end
					---@diagnostic disable-next-line: duplicate-set-field
					util.notify = function(message)
						messages[#messages + 1] = message
					end
					---@diagnostic disable-next-line: duplicate-set-field
					util.show_win_buffer = function(...)
						calls = calls + 1
						if (phase == "preview" and calls == 3) or (phase == "initialization" and calls == 1) then
							error("injected construction\nfailure")
						end
						return show(...)
					end
					---@diagnostic disable-next-line: duplicate-set-field
					buffers.scratch = function(...)
						if phase == "allocation" then
							calls = calls + 1
							if calls == 3 then
								error("injected partial allocation")
							end
						end
						return scratch(...)
					end
					local group
					---@diagnostic disable-next-line: duplicate-set-field
					compare.refresh = function(s)
						if phase == "refresh" then
							group = s.augroup
							error("injected failure after router setup")
						end
						return refresh(s)
					end
					if phase == "infeasible" then
						vim.o.winwidth = 90
						vim.o.winminwidth = 90
					end
					local ok, s = pcall(compare.open, { path = f.root, base = "HEAD" })
					util.show_win_buffer, buffers.scratch, api.nvim_exec2 = show, scratch, exec
					compare.refresh = refresh
					if group then
						assert(not pcall(api.nvim_get_autocmds, { group = group }), "rollback retained router autocmds")
					end
					vim.o.winminwidth = 1
					vim.o.winwidth = 20
					assert(vim.deep_equal(api.nvim_list_tabpages(), tabs), "failed construction left an orphan tab")
					assert(vim.deep_equal(api.nvim_list_bufs(), before), "failed construction left scratch buffers")
					assert(
						ok and not s and not compare.current(),
						"construction failure escaped or left a registered session"
					)
					assert(api.nvim_get_current_win() == origin, "construction failure lost origin focus")
					assert(
						#messages == 1 and not messages[1]:find("\n"),
						"construction failure did not report one single-line notification"
					)
					for _, buf in ipairs(api.nvim_list_bufs()) do
						assert(not buffers.is_managed(buf), "orphan managed resource")
					end
				end
				local s = assert(compare.open({ editable = false, path = f.root, base = "HEAD" }))
				loaded(s)
				compare.close(s)
			end),
		},
	}
end
