return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame, util = t.api, require("lazyvcs.blame"), require("lazyvcs.util")
	local function open(buf)
		assert(blame.blame_split())
		t.wait(function()
			local v = blame._test_blame_views()[buf]
			return v and v.winid
		end, "split absent", 15000)
		return blame._test_blame_views()[buf]
	end
	return t.cases({
		{
			"test_blame_a3_winbar_screen_rows_and_dynamic_changes",
			function()
				local f, buf, win = t.open(false)
				local rows = {}
				for i = 1, 100 do
					rows[i] = "line " .. i
				end
				t.h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				t.h.exec({ "git", "commit", "-am", "rows" }, f.root)
				vim.cmd("edit!")
				local old = vim.wo[win].winbar
				t.cleanups[#t.cleanups + 1] = function()
					if api.nvim_win_is_valid(win) then
						vim.wo[win].winbar = old
					end
				end
				local group = api.nvim_create_augroup("blame_a3_nofile", { clear = true })
				t.cleanups[#t.cleanups + 1] = function()
					api.nvim_del_augroup_by_id(group)
				end
				api.nvim_create_autocmd("BufWinEnter", {
					group = group,
					callback = function()
						if vim.bo.buftype == "nofile" then
							vim.wo.winbar = ""
						end
					end,
				})
				vim.wo[win].winbar = "SOURCE"
				local v = open(buf)
				local function aligned(line)
					t.wait(function()
						vim.cmd.redraw()
						return vim.fn.screenpos(win, line, 1).row == vim.fn.screenpos(v.winid, line, 1).row
					end, "winbar row mismatch")
					assert(vim.fn.screenpos(win, line, 1).row > 0)
				end
				aligned(2)
				vim.cmd("normal! 50Gzt")
				api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
				aligned(51)
				for _, bar in ipairs({ "", "NEW SOURCE", "" }) do
					vim.wo[win].winbar = bar
					api.nvim_exec_autocmds("OptionSet", { pattern = "winbar" })
					aligned(51)
					assert(vim.wo[win].winbar == bar, "source label changed")
				end
				api.nvim_set_current_win(v.winid)
				assert(blame.blame_split())
				assert(not api.nvim_win_is_valid(v.winid))
				assert(#t.notices == 0, table.concat(t.notices, ";"))
			end,
		},
		{
			"test_blame_a3_realign_preserves_binding_overrides_and_conceal",
			function()
				local _, buf, win = t.open(false)
				local old = util.capture_win_options(win, { "conceallevel", "scrollbind", "cursorbind" })
				t.cleanups[#t.cleanups + 1] = function()
					if api.nvim_win_is_valid(win) then
						util.set_win_options(win, old)
					end
				end
				util.set_win_options(win, { conceallevel = 2, scrollbind = true, cursorbind = true })
				local v = open(buf)
				assert(vim.wo[win].conceallevel == 1)
				util.set_win_options(win, { scrollbind = false, cursorbind = false })
				api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
				t.wait(function()
					return vim.wo[win].scrollbind
				end, "alignment absent")
				assert(blame.blame_split())
				assert(not api.nvim_win_is_valid(v.winid))
				assert(not vim.wo[win].scrollbind and not vim.wo[win].cursorbind, "override lost")
				assert(vim.wo[win].conceallevel == 2)
			end,
		},
		{
			"test_blame_a3_resize_keeps_date_without_request",
			function()
				local _, buf = t.open(false)
				local v = open(buf)
				local generation = v.generation
				for _, width in ipairs({ 22, 40, 26 }) do
					api.nvim_win_set_width(v.winid, width)
					api.nvim_exec_autocmds("WinResized", { pattern = tostring(v.winid) })
					local row = api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1]
					assert(vim.fn.strdisplaywidth(row) <= api.nvim_win_get_width(v.winid), row)
					assert(row:match("%d%d%d%d%-%d%d%-%d%d$"), row)
					assert(v.generation == generation, "resize queried VCS")
				end
			end,
		},
		{
			"test_blame_a3_selection_expands_source_tabs",
			function()
				local _, buf = t.open(false)
				vim.bo[buf].tabstop = 4
				vim.bo[buf].vartabstop = "4,8"
				api.nvim_buf_set_lines(buf, 0, 1, false, { "\t\tcode" })
				local report = assert(require("lazyvcs.blame_selection").open(1, 1))
				t.wait(function()
					return report.entries ~= nil
				end, "selection pending", 15000)
				local row = api.nvim_buf_get_lines(report.buf, 2, 3, false)[1]
				assert(row:sub(-19) == " | " .. string.rep(" ", 12) .. "code", row)
				assert(not row:find("\\x09", 1, true), "source tabs escaped")
			end,
		},
	})
end
