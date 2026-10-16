return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, util, blame = t.api, require("lazyvcs.util"), require("lazyvcs.blame")
	local function source()
		local f, buf, win = t.open(false)
		local options = util.capture_win_options(
			win,
			{ "wrap", "foldenable", "scrolloff", "foldmethod", "scrollbind", "cursorbind" }
		)
		t.cleanups[#t.cleanups + 1] = function()
			if api.nvim_win_is_valid(win) then
				util.set_win_options(win, options)
			end
		end
		local rows = {}
		for i = 1, 500 do
			rows[i] = "source line " .. i
		end
		rows[1] = string.rep("long source ", 20)
		t.h.write_file(f.file, table.concat(rows, "\n") .. "\n")
		t.h.exec({ "git", "commit", "-am", "long file" }, f.root)
		vim.cmd("edit!")
		util.set_win_options(win, { scrolloff = 0, wrap = false, foldenable = false })
		return buf, win
	end
	local function open(buf)
		assert(blame.blame_split())
		t.wait(function()
			local v = blame._test_blame_views()[buf]
			return v and v.winid
		end, "blame split did not open", 15000)
		return blame._test_blame_views()[buf]
	end
	local function view(win)
		return api.nvim_win_call(win, vim.fn.winsaveview)
	end
	local function aligned(source_win, blame_win)
		vim.cmd.redraw()
		local s, b = view(source_win), view(blame_win)
		assert(s.topline == b.topline, "source topline " .. s.topline .. " differs from blame " .. b.topline)
		assert(s.lnum == b.lnum, "split cursor lines differ")
		local sr, br = vim.fn.screenpos(source_win, s.lnum, 1).row, vim.fn.screenpos(blame_win, b.lnum, 1).row
		assert(sr > 0 and sr == br, "source and attribution occupy different screen rows")
	end
	return t.cases({
		{
			"test_blame_split_initial_viewport_matches_source",
			function()
				local buf, win = source()
				vim.cmd("normal! 300Gzt")
				local v = open(buf)
				aligned(win, v.winid)
				assert(view(win).topline == 300, "split moved the source viewport")
				vim.wait(50)
				aligned(win, v.winid)
				vim.cmd("normal! j")
				api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				aligned(win, v.winid)
				vim.cmd("normal! \5")
				aligned(win, v.winid)
				api.nvim_buf_set_lines(buf, 10, 10, false, { "inserted" })
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				t.wait(function()
					return api.nvim_buf_line_count(v.bufnr) == 501
				end, "split did not reload insertion", 15000)
				aligned(win, v.winid)
				api.nvim_buf_set_lines(buf, 100, -1, false, {})
				vim.cmd("normal! 98Gzt")
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				t.wait(function()
					return api.nvim_buf_line_count(v.bufnr) == 100
				end, "split did not reload deletion", 15000)
				aligned(win, v.winid)
			end,
		},
		{
			"test_blame_split_alignment_does_not_move_unrelated_window",
			function()
				local buf, win = source()
				vim.cmd.vsplit()
				local other = api.nvim_get_current_win()
				util.show_win_buffer(other, api.nvim_create_buf(false, true))
				api.nvim_buf_set_lines(
					api.nvim_win_get_buf(other),
					0,
					-1,
					false,
					vim.tbl_map(tostring, vim.fn.range(1, 500))
				)
				vim.cmd("normal! 100Gzt")
				util.set_win_options(other, { scrollbind = true, cursorbind = true })
				api.nvim_set_current_win(win)
				vim.cmd("normal! 300Gzt")
				local before = view(other)
				local v = open(buf)
				aligned(win, v.winid)
				assert(vim.deep_equal(before, view(other)), "blame initialization moved an unrelated bound window")
			end,
		},
		{
			"test_blame_split_normalizes_and_restores_source_row_heights",
			function()
				for _, cleanup in ipairs({ "close", "unload", "replace" }) do
					local buf, win = source()
					util.set_win_options(win, { wrap = true, foldenable = true, foldmethod = "manual" })
					vim.cmd("3,5fold")
					vim.cmd("normal! ggzt")
					local options = util.capture_win_options(win, { "wrap", "foldenable", "scrollbind", "cursorbind" })
					local globals = {}
					for name in pairs(options) do
						globals[name] = api.nvim_get_option_value(name, { win = win, scope = "global" })
					end
					local v = open(buf)
					assert(
						not vim.wo[win].wrap and not vim.wo[win].foldenable,
						"source row heights were not normalized"
					)
					assert(not vim.wo[v.winid].wrap and not vim.wo[v.winid].foldenable)
					vim.cmd.redraw()
					for _, line in ipairs({ 2, 6 }) do
						assert(
							vim.fn.screenpos(win, line, 1).row == vim.fn.screenpos(v.winid, line, 1).row,
							"wrapped or folded source shifted attribution"
						)
					end
					if cleanup == "close" then
						blame.blame_split()
					elseif cleanup == "unload" then
						util.show_win_buffer(win, api.nvim_create_buf(false, true))
						api.nvim_buf_delete(buf, { unload = true })
					else
						util.show_win_buffer(win, api.nvim_create_buf(false, true))
					end
					t.wait(function()
						return not blame._test_blame_views()[buf]
					end, "split cleanup did not finish")
					assert(
						vim.deep_equal(options, util.capture_win_options(win, vim.tbl_keys(options))),
						"source options were not restored on " .. cleanup
					)
					for name, value in pairs(globals) do
						assert(
							value == api.nvim_get_option_value(name, { win = win, scope = "global" }),
							name .. " global changed"
						)
					end
					if cleanup == "close" then
						assert(vim.fn.foldclosed(3) == 3, "fold definition was lost")
					end
				end
			end,
		},
		{
			"test_blame_split_open_failure_restores_source_options",
			function()
				local buf, win = source()
				util.set_win_options(win, { wrap = true, foldenable = true })
				local options = util.capture_win_options(win, { "wrap", "foldenable", "scrollbind", "cursorbind" })
				local set, installed = util.set_win_options, false
				t.patch(util, "set_win_options", function(id, values)
					set(id, values)
					if id == win and values.wrap == false then
						installed = true
						error("forced row-height\nfailure")
					end
				end)
				-- Reload captures the patched helper at module scope.
				package.loaded["lazyvcs.blame"] = nil
				local module = require("lazyvcs.blame")
				t.cleanups[#t.cleanups + 1] = function()
					package.loaded["lazyvcs.blame"] = blame
				end
				assert(module.blame_split())
				t.wait(function()
					return #t.notices > 0 or module._test_blame_views()[buf] and module._test_blame_views()[buf].winid
				end, "injected open did not complete", 15000)
				assert(installed, "temporary source row-height override was never installed")
				assert(
					not module._test_blame_views()[buf] and #api.nvim_list_wins() == 1,
					"failed open retained its pane"
				)
				assert(
					vim.deep_equal(options, util.capture_win_options(win, vim.tbl_keys(options))),
					"failed open did not restore source options"
				)
				assert(#t.notices == 1 and not t.notices[1]:find("\n"), "failure escaped or notified more than once")
			end,
		},
	})
end
