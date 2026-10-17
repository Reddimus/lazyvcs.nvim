return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util = require("lazyvcs.util")
	local hooks
	local function dispatch(name)
		for _, callback in ipairs(hooks[name]) do
			callback("nested", {})
		end
	end
	local function guarded(fn)
		return function()
			local integration = require("lazyvcs.integrations.resession")
			integration.teardown()
			local original, setter, notify = package.loaded.resession, util.set_win_option_noautocmd, util.notify
			hooks = { pre_save = {}, post_save = {} }
			package.loaded.resession = {
				add_hook = function(name, callback)
					table.insert(hooks[name], callback)
				end,
				remove_hook = function() end,
			}
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local ok, err = xpcall(fn, debug.traceback)
			util.set_win_option_noautocmd, util.notify = setter, notify
			integration.teardown()
			package.loaded.resession = original
			h.cleanup()
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	local function fixture()
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf) ~= nil
		end, "nested fold diff did not open", 15000)
		local s = assert(require("lazyvcs.state").get(buf))
		vim.cmd("belowright new")
		local win = api.nvim_get_current_win()
		local lines = {}
		for i = 1, 20 do
			lines[i] = "line " .. i
		end
		api.nvim_buf_set_lines(0, 0, -1, false, lines)
		vim.cmd.diffthis()
		util.set_win_options(
			win,
			{ foldmethod = "manual", foldenable = true, foldminlines = 0, foldtext = "", foldcolumn = "0" }
		)
		return s, win
	end
	local function folds(win, ranges, outer_only)
		api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
			for _, range in ipairs(ranges) do
				vim.cmd(range[1] .. "," .. range[2] .. "fold")
				vim.cmd("normal! zR")
			end
			if outer_only then
				api.nvim_win_set_cursor(win, { ranges[1][1], 0 })
				vim.cmd("normal! zc")
			else
				vim.cmd("normal! zM")
			end
		end)
	end
	local function reveal(win, expected)
		api.nvim_win_call(win, function()
			for _, range in ipairs(expected) do
				assert(
					vim.fn.foldclosed(range[1]) == range[1] and vim.fn.foldclosedend(range[1]) == range[2],
					"nested fold lost: " .. vim.inspect(range)
				)
				api.nvim_win_set_cursor(win, { range[1], 0 })
				vim.cmd("normal! zo")
			end
		end)
	end
	local function levels(win)
		return api.nvim_win_call(win, function()
			local result = {}
			for line = 1, api.nvim_buf_line_count(0) do
				result[line] = vim.fn.foldlevel(line)
			end
			return result
		end)
	end

	local function tiled(win, three)
		api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
			local ranges = three and { { 1, 2 }, { 3, 5 }, { 1, 5 }, { 6, 7 }, { 8, 10 }, { 6, 10 } }
				or { { 1, 5 }, { 6, 10 } }
			for _, range in ipairs(ranges) do
				vim.cmd(range[1] .. "," .. range[2] .. "fold")
				vim.cmd(range[1] .. "normal! zo")
			end
			vim.cmd("1,10fold")
		end)
	end
	local function check_tiled(win)
		reveal(win, { { 1, 10 } })
		api.nvim_win_call(win, function()
			for line = 1, 10 do
				assert(vim.fn.foldclosed(line) == -1, "open tiled descendant became closed at " .. line)
			end
		end)
	end

	local cases = {
		{
			"test_live_diff_resession_preserves_two_child_tiling",
			function()
				local s, win = fixture()
				tiled(win, false)
				local before = levels(win)
				dispatch("pre_save")
				assert(s.phase == "saving", "fold capture prevented option projection")
				assert(not util.get_win_option(s.editable_win, "diff"), "save sees live diff options")
				dispatch("post_save")
				assert(vim.deep_equal(levels(win), before), "save changed tiled fold levels")
				check_tiled(win)
			end,
		},
		{
			"test_live_diff_resession_preserves_three_level_tiling",
			function()
				local _, win = fixture()
				tiled(win, true)
				local before = levels(win)
				dispatch("pre_save")
				dispatch("post_save")
				assert(vim.deep_equal(levels(win), before), "save changed tiled fold levels")
				check_tiled(win)
				api.nvim_win_call(win, function()
					vim.cmd("normal! zE")
					for _, range in ipairs({
						{ 1, 2, true },
						{ 3, 5 },
						{ 1, 5, true },
						{ 6, 7 },
						{ 8, 10, true },
						{ 6, 10 },
						{ 1, 10, true },
					}) do
						vim.cmd(range[1] .. "," .. range[2] .. "fold")
						if not range[3] then
							vim.cmd(range[1] .. "normal! zo")
						end
					end
				end)
				dispatch("pre_save")
				dispatch("post_save")
				reveal(win, { { 1, 10 }, { 1, 5 }, { 1, 2 }, { 8, 10 } })
				assert(
					api.nvim_win_call(win, function()
						return vim.fn.foldclosed(3) == -1 and vim.fn.foldclosed(6) == -1
					end),
					"mixed tiled children changed state"
				)
			end,
		},
		{
			"test_live_diff_resession_preserves_hidden_nested_folds",
			function()
				local _, win = fixture()
				folds(win, { { 1, 10 }, { 2, 5 } })
				dispatch("pre_save")
				dispatch("post_save")
				reveal(win, { { 1, 10 }, { 2, 5 } })
			end,
		},
		{
			"test_live_diff_resession_preserves_nested_fold_boundaries",
			function()
				local _, win = fixture()
				for _, ranges in ipairs({
					{ { 1, 10 }, { 2, 5 } },
					{ { 1, 10 }, { 1, 5 } },
					{ { 1, 10 }, { 5, 10 } },
					{ { 1, 10 }, { 1, 10 } },
					{ { 1, 15 }, { 2, 12 }, { 3, 8 }, { 4, 6 } },
				}) do
					folds(win, ranges)
					dispatch("pre_save")
					dispatch("post_save")
					reveal(win, ranges)
				end
				folds(win, { { 1, 10 }, { 2, 5 } }, true)
				dispatch("pre_save")
				dispatch("post_save")
				reveal(win, { { 1, 10 } })
				assert(api.nvim_win_call(win, function()
					return vim.fn.foldclosed(2)
				end) == -1, "hidden open child became closed")
				-- Marker and expression folds must also remain untouched.
				for _, method in ipairs({ "marker", "expr" }) do
					util.set_win_option(win, "foldmethod", "manual")
					api.nvim_win_call(win, function()
						vim.cmd("normal! zE")
					end)
					local lines = {
						"outer {{{",
						"child {{{",
						"three",
						"four",
						"child }}}",
						"six",
						"seven",
						"eight",
						"nine",
						"outer }}}",
					}
					api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, -1, false, lines)
					util.set_win_options(win, {
						foldmarker = "{{{,}}}",
						foldexpr = "v:lnum == 1 ? '>1' : v:lnum == 2 ? '>2' : v:lnum <= 5 ? 2 : 1",
						foldmethod = method,
					})
					api.nvim_win_call(win, function()
						vim.cmd("normal! zM")
					end)
					dispatch("pre_save")
					dispatch("post_save")
					reveal(win, { { 1, 10 }, { 2, 5 } })
				end
			end,
		},
		{
			"test_live_diff_resession_nested_folds_rollback",
			function()
				local s, win = fixture()
				for _, failure in ipairs({ false, true }) do
					folds(win, { { 1, 10 }, { 2, 5 } })
					api.nvim_win_set_cursor(win, { 15, 0 })
					local buf, focus = api.nvim_win_get_buf(win), api.nvim_get_current_win()
					local view = api.nvim_win_call(win, vim.fn.winsaveview)
					local options = util.capture_win_options(
						win,
						{ "diff", "foldmethod", "foldenable", "foldminlines", "foldtext" }
					)
					local text, tick = api.nvim_buf_get_lines(buf, 0, -1, false), api.nvim_buf_get_changedtick(buf)
					local setter, notify, messages = util.set_win_option_noautocmd, util.notify, {}
					if failure then
						local injected = false
						---@diagnostic disable-next-line: duplicate-set-field
						util.set_win_option_noautocmd = function(target, name, value)
							if target == s.editable_win and s.phase == "saving" and not injected then
								injected = true
								error("partial nested projection\nsecond line")
							end
							return setter(target, name, value)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						util.notify = function(message)
							messages[#messages + 1] = message
						end
					end
					dispatch("pre_save")
					ctx.wait_for(function()
						return s.phase == "active"
					end, "nested fold rollback did not resume")
					util.set_win_option_noautocmd, util.notify = setter, notify
					assert(
						not failure or (#messages == 1 and not messages[1]:find("\n")),
						"rollback did not report a single line"
					)
					assert(
						api.nvim_get_current_win() == focus
							and vim.deep_equal(api.nvim_win_call(win, vim.fn.winsaveview), view),
						"rollback changed focus or view"
					)
					assert(
						vim.deep_equal(util.capture_win_options(win, vim.tbl_keys(options)), options),
						"rollback changed raw fold options"
					)
					assert(
						api.nvim_buf_get_changedtick(buf) == tick
							and vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), text),
						"rollback changed contents"
					)
					reveal(win, { { 1, 10 }, { 2, 5 } })
				end
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
