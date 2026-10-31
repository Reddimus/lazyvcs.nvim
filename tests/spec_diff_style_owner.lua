return function(ctx)
	local api, h = vim.api, ctx.helpers
	local highlighting = require("lazyvcs.highlighting")
	local function raw(win)
		return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
	end
	local function guarded(fn)
		return function()
			local global = vim.go.fillchars
			local global_mapping = vim.go.winhighlight
			vim.cmd.tabnew()
			local tab = api.nvim_get_current_tabpage()
			local ok, err = xpcall(function()
				require("lazyvcs").setup({ signs = { enabled = false } })
				vim.go.fillchars = "eob:~"
				fn()
			end, debug.traceback)
			if api.nvim_tabpage_is_valid(tab) then
				for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
					highlighting.release(win)
				end
				api.nvim_set_current_tabpage(tab)
				vim.cmd.tabclose()
			end
			vim.go.fillchars = global
			vim.go.winhighlight = global_mapping
			h.cleanup()
			assert(ok, err)
		end
	end
	local function file()
		local path = h.tempdir() .. "/shared.txt"
		h.write_file(path, "shared contents\n")
		vim.cmd.edit(vim.fn.fnameescape(path))
		vim.bo.bufhidden = "hide"
		return path
	end
	local function apply(win, value, mappings)
		vim.wo[win].fillchars = value
		vim.wo[win].winhighlight = mappings or ""
		highlighting.apply(win, "syntax", "old")
		assert(raw(win):find("diff:╱", 1, true))
	end
	local function marker(value)
		return value:match("LazyVcsDiffOwner:LazyVcsDiffOwner%d+")
	end
	return {
		{
			"test_core_diff_style_deliberate_user_owner_mapping_survives_owned_lifetime",
			guarded(function()
				local path = file()
				local win = api.nvim_get_current_win()
				local user = "Normal:WarningMsg,LazyVcsUserOwner:LazyVcsUserOwner1"
				apply(win, "", user)
				assert(highlighting.user_winhighlight(win) == user)
				vim.cmd.split()
				local clone = api.nvim_get_current_win()
				assert(raw(clone) == "" and vim.wo[clone].winhighlight == user)
				api.nvim_exec_autocmds("WinEnter", {})
				assert(vim.wo[clone].winhighlight == user, "saved user marker was mistaken for an owned copy")
				vim.go.winhighlight = user
				api.nvim_exec_autocmds("OptionSet", { pattern = "winhighlight" })
				assert(vim.go.winhighlight == user, "global user marker was stripped without provenance")
				highlighting.release(win)
				assert(vim.wo[win].winhighlight == user and vim.wo[clone].winhighlight == user)
				api.nvim_win_set_buf(clone, api.nvim_create_buf(false, true))
				vim.cmd.edit(vim.fn.fnameescape(path))
				assert(vim.wo.winhighlight == user and raw(0) == "")
			end),
		},
		{
			"test_core_diff_style_same_write_raw_ownership_hidden_and_return",
			guarded(function()
				local path = file()
				local first = api.nvim_get_current_win()
				apply(first, "")
				local written = raw(first)
				api.nvim_win_set_buf(first, api.nvim_create_buf(false, true))
				highlighting.release(first)
				vim.cmd.split()
				local second = api.nvim_get_current_win()
				vim.cmd.edit(vim.fn.fnameescape(path))
				apply(second, "eob:~")
				assert(raw(second) == written, "fixture writes must collide")
				api.nvim_win_set_buf(second, api.nvim_create_buf(false, true))
				highlighting.release(second)
				for _, owner in ipairs({ { first, "" }, { second, "eob:~" } }) do
					api.nvim_set_current_win(owner[1])
					vim.cmd.edit(vim.fn.fnameescape(path))
					assert(raw(owner[1]) == owner[2], "another window replaced the raw fillchars origin")
				end
				vim.go.fillchars = "eob:!"
				api.nvim_exec_autocmds("OptionSet", { pattern = "fillchars" })
				assert(api.nvim_get_option_value("fillchars", { win = first }) == "eob:!")
				assert(api.nvim_get_option_value("fillchars", { win = second }) == "eob:~")
			end),
		},
		{
			"test_core_diff_style_same_write_clone_provenance_and_user_mapping",
			guarded(function()
				file()
				local first = api.nvim_get_current_win()
				vim.cmd.split()
				local second = api.nvim_get_current_win()
				vim.cmd.split()
				local focused = api.nvim_get_current_win()
				local user = "Normal:NormalNC,DiffDelete:ErrorMsg,LazyVcsDiffOwner:WarningMsg"
				apply(first, "", user)
				apply(second, "eob:~", user)
				for _, owner in ipairs({ { first, "" }, { second, "eob:~" } }) do
					local clone
					api.nvim_win_call(owner[1], function()
						clone = api.nvim_open_win(api.nvim_get_current_buf(), false, {
							relative = "editor",
							row = 1,
							col = 1,
							width = 12,
							height = 2,
						})
					end)
					assert(raw(clone) == owner[2], "API clone inherited another owner's raw value")
					assert(vim.wo[clone].winhighlight == user, "clone changed an explicit user mapping")
					assert(not marker(vim.wo[clone].winhighlight))
					api.nvim_win_close(clone, true)
					assert(api.nvim_get_current_win() == focused)
				end
				for _, owner in ipairs({ { first, "" }, { second, "eob:~" } }) do
					api.nvim_set_current_win(owner[1])
					vim.cmd.split()
					local clone = api.nvim_get_current_win()
					assert(raw(clone) == owner[2], "split clone lost its raw origin")
					assert(vim.wo[clone].winhighlight == user)
					api.nvim_win_close(clone, true)
				end
			end),
		},
		{
			"test_core_diff_style_owner_window_and_buffer_lifetimes",
			guarded(function()
				local first = api.nvim_get_current_win()
				for _, mode in ipairs({ "close", "wipe" }) do
					for _ = 1, 8 do
						local path = h.tempdir() .. "/closed-owner.txt"
						h.write_file(path, "retained buffer\n")
						vim.cmd.vsplit(vim.fn.fnameescape(path))
						local owner, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
						vim.bo[buf].bufhidden = "hide"
						api.nvim_set_current_win(first)
						apply(owner, "")
						if mode == "wipe" then
							api.nvim_buf_delete(buf, { force = true })
						end
						if api.nvim_win_is_valid(owner) then
							api.nvim_win_close(owner, true)
						end
						vim.cmd.tabnew()
						vim.cmd.edit(vim.fn.fnameescape(path))
						assert(raw(0) == "", "closed origin retained its owned filler")
						assert(not marker(vim.wo.winhighlight), "closed lifetime retained an owner marker")
						vim.cmd.tabclose()
						api.nvim_set_current_win(first)
					end
				end
			end),
		},
		{
			"test_core_diff_style_owner_reuse_preserves_edits_and_bounds_slots",
			guarded(function()
				local path = file()
				local win = api.nvim_get_current_win()
				local function groups()
					local count = 0
					for name in pairs(api.nvim_get_hl(0, {})) do
						if name:match("^LazyVcsDiffOwner%d+$") then
							count = count + 1
						end
					end
					return count
				end
				local before = groups()
				for i = 1, 30 do
					apply(win, i % 2 == 0 and "eob:~" or "")
					vim.cmd.split()
					local clone = api.nvim_get_current_win()
					assert(not marker(vim.wo[clone].winhighlight))
					highlighting.release(win)
					api.nvim_win_close(clone, true)
					api.nvim_set_current_win(win)
				end
				assert(groups() <= before + 1, "owner slot names grew with completed lifetimes")
				apply(win, "")
				vim.wo[win].fillchars = "eob:?,diff:z"
				vim.wo[win].winhighlight = "Normal:ErrorMsg,DiffDelete:WarningMsg"
				api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
				highlighting.release(win)
				vim.cmd.edit(vim.fn.fnameescape(path))
				assert(raw(win) == "eob:?,diff:z")
				assert(vim.wo[win].winhighlight == "Normal:ErrorMsg,DiffDelete:WarningMsg")
			end),
		},
	}
end
