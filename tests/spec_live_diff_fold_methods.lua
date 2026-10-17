return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util, fs = require("lazyvcs.util"), require("lazyvcs.fold_state")
	local function state(win)
		return api.nvim_win_call(win, function()
			local values = {}
			for line = 1, api.nvim_buf_line_count(0) do
				values[line] = { vim.fn.foldlevel(line), vim.fn.foldclosed(line), vim.fn.foldclosedend(line) }
			end
			return values
		end)
	end
	local function save(s)
		local tx = {}
		require("lazyvcs.layout").prepare_sessions_save({ s }, tx)
		assert(s.phase == "saving")
		vim.cmd("mksession! " .. vim.fn.fnameescape(h.tempdir() .. "/session.vim"))
		local _, errors = require("lazyvcs.layout").finish_sessions_save(tx)
		assert(#errors == 0, vim.inspect(errors))
		assert(s.phase == "active")
		return tx
	end
	local function intact(s, win)
		local before = state(win)
		save(s)
		assert(vim.deep_equal(before, state(win)), "save changed per-line fold levels or closures")
	end
	local function guarded(fn)
		return function()
			vim.cmd("silent! only!")
			vim.cmd("diffoff!")
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local closed, cursor, setter = vim.fn.foldclosed, api.nvim_win_set_cursor, util.set_win_option_noautocmd
			local ok, err = xpcall(fn, debug.traceback)
			vim.fn.foldclosed, api.nvim_win_set_cursor, util.set_win_option_noautocmd = closed, cursor, setter
			h.cleanup()
			vim.cmd("silent! only!")
			vim.cmd.diffoff()
			assert(ok, err)
		end
	end
	local function fixture()
		local f = h.make_git_fixture()
		local lines = {}
		for i = 1, 180 do
			lines[i] = "line " .. i
		end
		h.write_file(f.file, table.concat(lines, "\n") .. "\n")
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "fold probe" }, f.root)
		lines[40] = "change one"
		lines[140] = "change two"
		h.write_file(f.file, table.concat(lines, "\n") .. "\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		assert(vim.wait(15000, function()
			return require("lazyvcs.state").get(buf) ~= nil
		end))
		return assert(require("lazyvcs.state").get(buf)), lines
	end
	local cases = {}
	for _, method in ipairs({ "manual", "indent", "marker", "expr", "syntax" }) do
		for _, owned in ipairs({ false, true }) do
			cases[#cases + 1] = {
				"test_live_diff_resession_untouched_" .. method .. "_" .. (owned and "owned" or "neighbour"),
				guarded(function()
					for _, shape in ipairs({ "closed-child", "open-child", "coincident" }) do
						local s = fixture()
						local win = s.editable_win
						if not owned then
							vim.cmd("belowright new")
							win = api.nvim_get_current_win()
							vim.cmd.diffthis()
						end
						api.nvim_win_call(win, function()
							vim.wo.foldmethod = "manual"
							vim.cmd("normal! zE")
							local lines = {}
							for i = 1, 20 do
								lines[i] = "plain " .. i
							end
							for i = 1, 3 do
								lines[i] = "  Q " .. i
							end
							for i = 5, 14 do
								lines[i] = "  P " .. i
							end
							for i = 6, 13 do
								lines[i] = "    C " .. i
							end
							if method == "marker" or method == "syntax" then
								lines[1] = "Q {{{"
								lines[3] = "q }}}"
								lines[5] = "P {{{"
								lines[6] = "C {{{"
								lines[13] = "c }}}"
								lines[14] = "p }}}"
							end
							api.nvim_buf_set_lines(0, 0, -1, false, lines)
							vim.wo.foldenable = true
							vim.wo.foldminlines = 0
							vim.wo.foldlevel = 99
							vim.bo.shiftwidth = 2
							vim.wo.foldignore = ""
							vim.wo.foldmarker = "{{{,}}}"
							vim.wo.foldexpr = "indent(v:lnum) / 2"
							if method == "syntax" then
								vim.cmd("syntax clear")
								vim.cmd("syntax region ProbeQ start=/Q {{{/ end=/q }}}/ fold")
								vim.cmd("syntax region ProbeP start=/P {{{/ end=/p }}}/ fold contains=ProbeC")
								vim.cmd("syntax region ProbeC start=/C {{{/ end=/c }}}/ fold contained")
								vim.cmd("syntax sync fromstart")
							end
							vim.wo.foldmethod = method
							if method == "manual" then
								for _, r in ipairs({ { 1, 3 }, { 5, 14 }, { 6, 13 } }) do
									vim.cmd(r[1] .. "," .. r[2] .. "fold")
									vim.cmd("normal! zR")
								end
							else
								vim.cmd("normal! zx")
								vim.cmd("normal! zR")
							end
							assert(vim.fn.foldlevel(6) == 2, method .. " missing nested folds")
							vim.cmd("1normal! zc")
							if shape == "closed-child" then
								vim.cmd("6normal! zc")
							else
								vim.cmd("5normal! zc")
							end
							if shape == "coincident" then
								if method == "marker" or method == "syntax" then
									api.nvim_buf_set_lines(0, 12, 14, true, { "c }}} p }}}" })
									api.nvim_buf_set_lines(0, 4, 6, true, { "P {{{ C {{{" })
								else
									api.nvim_buf_set_lines(0, 13, 14, true, {})
									api.nvim_buf_set_lines(0, 4, 5, true, {})
								end
								assert(vim.fn.foldlevel(5) == 2, method .. " missing coincident depth")
							end
							api.nvim_win_set_cursor(win, { 18, 0 })
						end)

						local before = state(win)
						local original, calls = vim.fn.foldclosed, 0
						vim.fn.foldclosed = function(line)
							if api.nvim_get_current_win() == win then
								calls = calls + 1
							end
							return original(line)
						end
						local tx = save(s)
						vim.fn.foldclosed = original
						assert(calls == 0, method .. " folds were scanned " .. calls .. " times")
						assert(tx.windows[win].folds == nil, "non-diff method captured")
						assert(
							vim.deep_equal(before, state(win)),
							method .. " " .. shape .. " changed levels or closures"
						)
						h.cleanup()
						vim.cmd("silent! only!")
						vim.cmd.diffoff()
					end
				end),
			}
		end
	end
	cases[#cases + 1] = {
		"test_live_diff_resession_preserves_coincident_open_child",
		guarded(function()
			local s, lines = fixture()
			vim.cmd("belowright new")
			local win = api.nvim_get_current_win()
			api.nvim_buf_set_lines(0, 0, -1, false, lines)
			vim.cmd.diffthis()
			api.nvim_win_call(win, function()
				vim.wo.foldmethod = "manual"
				vim.wo.foldenable = true
				vim.wo.foldminlines = 0
				vim.cmd("normal! zE")
				vim.cmd("1,3fold")
				vim.cmd("5,14fold")
				vim.cmd("5normal! zo")
				vim.cmd("6,14fold")
				vim.cmd("6normal! zo")
				vim.cmd("5normal! zc")
				api.nvim_buf_set_lines(0, 4, 5, true, {})
				api.nvim_win_set_cursor(win, { 18, 0 })
			end)
			intact(s, win)
			api.nvim_win_call(win, function()
				assert(vim.fn.foldclosed(1) == 1 and vim.fn.foldclosedend(1) == 3, "earlier fold was opened")
				assert(vim.fn.foldlevel(5) == 2, "coincident levels lost")
				vim.cmd("5normal! zo")
				assert(vim.fn.foldclosed(5) == -1, "coincident open child became closed")
			end)
		end),
	}
	local function diff_window(owned)
		local s, lines = fixture()
		local win = s.editable_win
		if not owned then
			vim.cmd("belowright new")
			win = api.nvim_get_current_win()
			api.nvim_buf_set_lines(0, 0, -1, false, lines)
			vim.cmd.diffthis()
		end
		api.nvim_win_call(win, function()
			vim.wo.foldmethod = "diff"
			vim.wo.foldenable = true
			vim.wo.foldminlines = 0
			vim.cmd.diffupdate()
			vim.cmd("normal! zM")
			assert(vim.fn.foldclosed(1) == 1, "missing diff fold")
			vim.cmd("1normal! zo")
			assert(vim.fn.foldclosed(80) > 0, "missing closed diff fold")
			for line = 1, api.nvim_buf_line_count(0) do
				assert(vim.fn.foldlevel(line) <= 1, "nested diff fold")
			end
			api.nvim_win_set_cursor(win, { 40, 0 })
		end)
		return s, win
	end
	for _, owned in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_live_diff_resession_diff_folds_" .. (owned and "owned" or "neighbour"),
			guarded(function()
				local s, win = diff_window(owned)
				local level = util.get_win_option(win, "foldlevel")
				intact(s, win)
				assert(util.get_win_option(win, "foldlevel") == level, "restore changed foldlevel option")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_resession_fold_capture_failure_is_atomic",
		guarded(function()
			local s, win = diff_window(true)
			local original = vim.fn.foldclosed
			local before, view = state(win), api.nvim_win_call(win, vim.fn.winsaveview)
			local options =
				util.capture_win_options(win, { "foldmethod", "foldtext", "foldminlines", "scrollbind", "cursorbind" })
			for _, fail_at in ipairs({ 1, 10 }) do
				local calls = 0
				vim.fn.foldclosed = function(line)
					if api.nvim_get_current_win() == win then
						calls = calls + 1
						if calls == fail_at then
							error("forced capture read failure")
						end
					end
					return original(line)
				end
				local ok, value = pcall(fs.capture, win)
				vim.fn.foldclosed = original
				assert(ok and value == nil and calls == fail_at, "capture failure escaped or was not injected")
				assert(vim.deep_equal(state(win), before), "failed capture changed closures")
				assert(vim.deep_equal(api.nvim_win_call(win, vim.fn.winsaveview), view), "capture failure changed view")
				assert(
					vim.deep_equal(util.capture_win_options(win, vim.tbl_keys(options)), options),
					"capture failure changed options"
				)
			end
			local calls = 0
			vim.fn.foldclosed = function(line)
				if api.nvim_get_current_win() == win then
					calls = calls + 1
					error("forced save capture failure")
				end
				return original(line)
			end
			local tx = {}
			require("lazyvcs.layout").prepare_sessions_save({ s }, tx)
			vim.fn.foldclosed = original
			assert(calls > 0 and not tx.windows[win].folds and s.phase == "saving", "failure blocked save projection")
			assert(not util.get_win_option(s.editable_win, "diff"), "capture failure leaked live diff options")
			local _, errors = require("lazyvcs.layout").finish_sessions_save(tx)
			assert(#errors == 0 and s.phase == "active", "save did not resume")
			-- Restore errors are contained; later ranges still close and cleanup still runs.
			local snapshot = assert(fs.capture(win))
			view = api.nvim_win_call(win, vim.fn.winsaveview)
			local cursor, writes = api.nvim_win_set_cursor, 0
			---@diagnostic disable-next-line: duplicate-set-field
			api.nvim_win_set_cursor = function(...)
				writes = writes + 1
				if writes == 1 then
					error("forced restore cursor failure")
				end
				return cursor(...)
			end
			local ok, value = pcall(fs.restore, win, snapshot)
			api.nvim_win_set_cursor = cursor
			assert(
				ok and value == false and writes == #snapshot.closed,
				"restore failure escaped or stopped later ranges"
			)
			assert(
				vim.deep_equal(util.capture_win_options(win, vim.tbl_keys(options)), options),
				"failure changed raw options"
			)
			assert(vim.deep_equal(api.nvim_win_call(win, vim.fn.winsaveview), view), "failure changed view")
			assert(fs.capture(-1) == nil and not fs.restore(-1, snapshot), "invalid window failure escaped")
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_resession_diff_fold_mismatch_is_skipped",
		guarded(function()
			local _, win = diff_window(true)
			local snapshot = assert(fs.capture(win))
			assert(#snapshot.closed >= 2, "missing later fold")
			local first = snapshot.closed[1].first
			snapshot.closed[1].last = snapshot.closed[1].last + 1
			assert(fs.restore(win, snapshot), "range mismatch raised a restore failure")
			api.nvim_win_call(win, function()
				assert(vim.fn.foldclosed(first) == -1, "mismatched fold remained closed")
				local later = snapshot.closed[2]
				assert(
					vim.fn.foldclosed(later.first) == later.first and vim.fn.foldclosedend(later.first) == later.last,
					"mismatch stopped later range"
				)
			end)
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_resession_preexisting_diff_marker_folds_untouched",
		guarded(function()
			-- A window already in diff mode keeps its own foldmethod when the live diff opens.
			local f = h.make_git_fixture()
			local lines = {}
			for i = 1, 60 do
				lines[i] = "plain " .. i
			end
			lines[1], lines[3], lines[5], lines[6], lines[13], lines[14] =
				"Q {{{", "q }}}", "P {{{", "C {{{", "c }}}", "p }}}"
			h.write_file(f.file, table.concat(lines, "\n") .. "\n")
			h.exec({ "git", "add", "." }, f.root)
			h.exec({ "git", "commit", "-m", "markers" }, f.root)
			lines[40] = "changed"
			h.write_file(f.file, table.concat(lines, "\n") .. "\n")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
			vim.cmd.diffthis()
			vim.wo[win].foldminlines, vim.wo[win].foldmarker = 0, "{{{,}}}"
			vim.wo[win].foldmethod = "marker"
			vim.cmd("normal! zR")
			vim.cmd("1normal! zc")
			vim.cmd("5normal! zc")
			-- Merge the parent and child markers so a closed parent shares its range with an open child.
			api.nvim_buf_set_lines(0, 12, 14, true, { "c }}} p }}}" })
			api.nvim_buf_set_lines(0, 4, 6, true, { "P {{{ C {{{" })
			assert(vim.fn.foldlevel(5) == 2 and vim.fn.foldclosed(5) == 5, "coincident marker fixture")
			require("lazyvcs").open()
			assert(vim.wait(15000, function()
				return require("lazyvcs.state").get(buf) ~= nil
			end))
			local s = assert(require("lazyvcs.state").get(buf))
			assert(s.editable_win == win and util.get_win_option(win, "foldmethod") == "marker")
			intact(s, win)
		end),
	}
	return cases
end
