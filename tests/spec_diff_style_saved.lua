-- Neovim keeps per-buffer window options even after a view releases its windows.
return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util = require("lazyvcs.util")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = { "test_" .. name, fn }
	end
	local function setup()
		vim.cmd.tabnew()
		api.nvim_win_set_hl_ns(0, -1)
		require("lazyvcs").setup({
			signs = { enabled = false },
			blame = { persist = false },
			debounce_ms = 10,
			compare = { collapse_absent = false },
			base_window = { collapse_absent = false },
		})
	end
	local function edit(path)
		vim.cmd.edit(vim.fn.fnameescape(path))
	end
	local function set_style(fill, mappings)
		util.set_win_option(0, "fillchars", fill)
		util.set_win_option(0, "winhighlight", mappings)
	end
	local function check_style(win, fill, mappings)
		assert(util.get_win_option(win, "fillchars") == fill, "fillchars: " .. util.get_win_option(win, "fillchars"))
		assert(
			util.get_win_option(win, "winhighlight") == mappings,
			"winhighlight: " .. util.get_win_option(win, "winhighlight")
		)
	end
	for _, original in ipairs({ { "", "" }, { "eob:!", "Normal:NormalNC" } }) do
		local suffix = original[1] == "" and "fallback" or "raw"
		add("live_diff_style_hidden_transfer_close_reopen_" .. suffix, function()
			setup()
			local f = h.make_git_fixture()
			local other = f.root .. "/b.txt"
			h.write_file(other, "base\n")
			h.exec({ "git", "add", "b.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "second file" }, f.root)
			h.write_file(other, "changed\n")
			edit(f.file)
			set_style(original[1], original[2])
			local s = ctx.open_diff()
			local win = s.editable_win
			assert(tostring(util.get_win_option(win, "fillchars")):find("diff:╱", 1, true))
			edit(other)
			local transferred
			ctx.wait_for(function()
				transferred = require("lazyvcs.state").for_window(win)
				return transferred and transferred ~= s and transferred.phase == "active"
			end, "saved style transfer", 15000)
			require("lazyvcs.actions").close(transferred)
			edit(f.file)
			check_style(win, original[1], original[2])
			vim.cmd.tabclose()
		end)
		add("core_diff_style_hidden_compare_close_reopen_" .. suffix, function()
			setup()
			local f = h.make_git_fixture()
			local first, second = f.root .. "/a.txt", f.root .. "/b.txt"
			h.write_file(first, "first\n")
			h.write_file(second, "second\n")
			h.exec({ "git", "add", "a.txt", "b.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "review files" }, f.root)
			h.write_file(first, "first changed\n")
			h.write_file(second, "second changed\n")
			-- Load without displaying: only the review pane will have a saved record.
			local reviewed = vim.fn.bufadd(first)
			vim.fn.bufload(reviewed)
			vim.bo[reviewed].buflisted = true
			vim.bo[reviewed].bufhidden = "hide"
			api.nvim_create_autocmd("BufWinEnter", {
				buffer = reviewed,
				once = true,
				callback = function()
					set_style(original[1], original[2])
				end,
			})
			edit(f.file)
			set_style(original[1], original[2])
			local compare = require("lazyvcs.compare")
			local s = assert(compare.open({ path = f.root, base = "HEAD", editable = true }))
			ctx.wait_for(function()
				return s.preview_result and not s.preview_job and s.shown_item.relpath == "a.txt"
			end, "first reviewed file", 15000)
			api.nvim_set_current_win(s.rightwin)
			assert(tostring(util.get_win_option(s.rightwin, "fillchars")):find("diff:╱", 1, true))
			api.nvim_feedkeys(api.nvim_replace_termcodes("]b", true, false, true), "xt", false)
			ctx.wait_for(function()
				return s.preview_result and not s.preview_job and s.shown_item.relpath == "b.txt"
			end, "next reviewed file", 15000)
			compare.close(s)
			edit(first)
			check_style(0, original[1], original[2])
			vim.cmd.tabclose()
		end)
	end

	for _, stacked in ipairs({ false, true }) do
		add("core_absent_rail_hidden_transfer_close_reopen_" .. (stacked and "stacked" or "side"), function()
			setup()
			local rail = require("lazyvcs.absent_rail")
			local f = h.make_git_fixture()
			edit(f.file)
			local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
			local original = {
				number = true,
				relativenumber = true,
				signcolumn = "yes:2",
				foldcolumn = "2",
				statuscolumn = "%l",
				winfixwidth = false,
				winfixheight = false,
			}
			for name, value in pairs(original) do
				util.set_win_option(win, name, value)
			end
			local s = {}
			rail.apply(s, win, stacked)
			-- Transfer hides the owned buffer before the session can release it.
			api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
			rail.release(s)
			api.nvim_win_close(win, true)
			vim.cmd.tabnew()
			edit(f.file)
			assert(api.nvim_get_current_buf() == buf)
			local actual = util.capture_win_options(0, vim.tbl_keys(original))
			assert(vim.deep_equal(actual, original), vim.inspect(actual))
			vim.cmd.tabclose()
		end)
	end

	add("core_diff_style_hidden_reopen_preserves_user_changes", function()
		setup()
		local guard = require("lazyvcs.highlighting")
		local f = h.make_git_fixture()
		edit(f.file)
		set_style("eob:!", "Normal:NormalNC")
		local win = api.nvim_get_current_win()
		guard.apply(win, "syntax", "old")
		-- A partial edit keeps DiffAdd owned but replaces DiffDelete explicitly.
		set_style("eob:?,diff:z", "Normal:ErrorMsg,DiffDelete:WarningMsg,DiffAdd:LazyVcsDiffRemoved")
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
		guard.release(win)
		edit(f.file)
		check_style(win, "eob:?,diff:z", "Normal:ErrorMsg,DiffDelete:WarningMsg")
		vim.cmd.tabclose()
	end)
	add("core_diff_style_hidden_records_survive_later_owner", function()
		setup()
		local guard = require("lazyvcs.highlighting")
		local f = h.make_git_fixture()
		edit(f.file)
		set_style("", "")
		local first = api.nvim_get_current_win()
		guard.apply(first, "syntax", "old", { enabled = true, filler = "/", removed = true })
		api.nvim_win_set_buf(first, api.nvim_create_buf(false, true))
		guard.release(first)
		vim.cmd.tabnew()
		edit(f.file)
		set_style("eob:!", "Normal:NormalNC")
		local second = api.nvim_get_current_win()
		guard.apply(second, "syntax", "new", { enabled = true, filler = "x", removed = true })
		api.nvim_win_set_buf(second, api.nvim_create_buf(false, true))
		guard.release(second)
		vim.cmd.tabclose()
		api.nvim_set_current_win(first)
		edit(f.file)
		check_style(first, "", "")
		vim.cmd.tabclose()
	end)
	add("core_absent_rail_hidden_reopen_preserves_user_changes", function()
		setup()
		local rail = require("lazyvcs.absent_rail")
		local f = h.make_git_fixture()
		edit(f.file)
		util.set_win_option(0, "signcolumn", "yes:2")
		util.set_win_option(0, "foldcolumn", "2")
		util.set_win_option(0, "statuscolumn", "%l")
		local s, win = {}, api.nvim_get_current_win()
		rail.apply(s, win, false)
		local changed = {
			number = true,
			relativenumber = true,
			signcolumn = "yes:3",
			foldcolumn = "3",
			statuscolumn = "%r%l",
			winfixwidth = false,
		}
		for name, value in pairs(changed) do
			util.set_win_option(win, name, value)
		end
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
		rail.release(s)
		api.nvim_win_close(win, true)
		vim.cmd.tabnew()
		edit(f.file)
		local actual = util.capture_win_options(0, vim.tbl_keys(changed))
		assert(vim.deep_equal(actual, changed), vim.inspect(actual))
		vim.cmd.tabclose()
	end)
	return cases
end
