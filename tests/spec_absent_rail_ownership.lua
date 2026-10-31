if vim.env.LAZYVCS_RAIL_EARLY_CHILD == "1" then
	local api = vim.api
	local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
	vim.opt.runtimepath:prepend(root)
	package.path = root .. "/tests/?.lua;" .. package.path
	local h = require("helpers")
	local armed, edit, observed, before, delivery, enter_win = false, nil, nil, nil, nil, nil
	assert(not package.loaded["lazyvcs.absent_rail"])
	local function apply_preference(win)
		local preference, original = assert(edit), assert(before)
		local inherited = {}
		for name in pairs(original) do
			inherited[name] = api.nvim_get_option_value(name, { win = win, scope = "local" })
		end
		api.nvim_set_option_value(preference[1], preference[2], { win = win, scope = "local" })
		observed = {
			win = win,
			inherited = inherited,
			value = api.nvim_get_option_value(preference[1], { win = win, scope = "local" }),
		}
	end
	api.nvim_create_autocmd("WinNew", {
		nested = true,
		callback = function()
			if armed then
				local win = api.nvim_get_current_win()
				if delivery == "nested" then
					apply_preference(win)
				elseif delivery == "enter" then
					enter_win = win
				end
			end
		end,
	})
	api.nvim_create_autocmd("WinNew", {
		callback = function()
			if armed and delivery == "scheduled" then
				local win = api.nvim_get_current_win()
				vim.schedule(function()
					apply_preference(win)
				end)
			end
		end,
	})
	api.nvim_create_autocmd("WinEnter", {
		callback = function()
			local win = api.nvim_get_current_win()
			if armed and delivery == "enter" and enter_win == win then
				apply_preference(win)
			end
		end,
	})
	require("lazyvcs").setup({ signs = { enabled = false }, blame = { persist = false } })
	local util = require("lazyvcs.util")
	local passed = 0
	local matrix = {}
	for _, split in ipairs({ false, true }) do
		for _, change in ipairs({ { "number", false }, { "statuscolumn", "CUSTOM" }, { "statuscolumn", "" } }) do
			matrix[#matrix + 1] = { split = split, change = change, delivery = "nested" }
		end
	end
	for _, mode in ipairs({ "enter", "scheduled" }) do
		matrix[#matrix + 1] = { change = { "number", false }, delivery = mode }
	end
	for _, trial in ipairs(matrix) do
		local split, change = trial.split, trial.change
		delivery = trial.delivery
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/untracked.txt", "new bytes\n")
		vim.cmd.edit(vim.fn.fnameescape(f.root .. "/untracked.txt"))
		vim.wo.number, vim.wo.statuscolumn = true, "%l"
		local s
		require("lazyvcs.actions").open({
			on_open = function(value)
				s = value
			end,
		})
		assert(
			vim.wait(15000, function()
				return s and s.rail
			end, 10),
			"live rail did not install"
		)
		assert(s.rail.before.number)
		local original = vim.deepcopy(s.rail.before)
		before = original
		local clone
		edit, observed, armed = change, nil, true
		api.nvim_win_call(s.base_win, function()
			if split then
				vim.cmd.split()
				clone = api.nvim_get_current_win()
			else
				clone = api.nvim_open_win(api.nvim_get_current_buf(), false, {
					relative = "editor",
					row = 1,
					col = 1,
					width = 12,
					height = 2,
				})
			end
		end)
		if delivery == "enter" then
			api.nvim_set_current_win(clone)
		end
		assert(
			vim.wait(2000, function()
				return observed ~= nil
			end, 10),
			"window preference was not applied"
		)
		armed = false
		assert(observed and observed.win == clone and observed.value == change[2], "early user hook did not run")
		local expected = vim.deepcopy(observed.inherited)
		for name, value in pairs(original) do
			if expected[name] == s.rail.written[name] then
				expected[name] = value
			end
		end
		expected[change[1]] = change[2]
		for name, value in pairs(expected) do
			assert(util.get_win_option(clone, name) == value, "early user " .. name .. " was overwritten")
		end
		assert(vim.deep_equal(s.rail.before, original), "clone edit changed origin preferences")
		api.nvim_exec_autocmds("WinEnter", {})
		assert(util.get_win_option(clone, change[1]) == change[2], "later cleanup reinterpreted the user value")
		api.nvim_win_close(clone, true)
		require("lazyvcs.actions").close(s)
		h.cleanup()
		passed = passed + 1
	end
	print("early WinNew rail cases: " .. passed .. " passed")
	vim.cmd("qall!")
	return
end

return function(ctx)
	local api, h = vim.api, ctx.helpers
	local rail, util = require("lazyvcs.absent_rail"), require("lazyvcs.util")
	local names =
		{ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" }
	local owners = {}
	local function capture(win)
		return util.capture_win_options(win, names)
	end
	local function apply(win, before)
		util.set_win_options(win, before)
		local s = {}
		owners[#owners + 1] = s
		rail.apply(s, win, false)
		return s
	end
	local function options(number, status)
		return {
			number = number,
			relativenumber = number,
			signcolumn = number and "yes:1" or "no",
			foldcolumn = number and "2" or "0",
			statuscolumn = status or "",
			winfixwidth = false,
			winfixheight = false,
		}
	end
	local function guarded(fn)
		return function()
			local global, ns = vim.go.statuscolumn, api.nvim_get_hl_ns({})
			vim.cmd.tabnew()
			local tab = api.nvim_get_current_tabpage()
			local ok, err = xpcall(function()
				require("lazyvcs").setup({ signs = { enabled = false }, diff_style = { enabled = false } })
				fn()
			end, debug.traceback)
			for _, owner in ipairs(owners) do
				rail.release(owner)
			end
			owners = {}
			api.nvim_set_hl_ns(ns)
			vim.go.statuscolumn = global
			if api.nvim_tabpage_is_valid(tab) then
				api.nvim_set_current_tabpage(tab)
				vim.cmd.tabclose()
			end
			h.cleanup()
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_absent_rail_early_winnew_user_preferences",
			function()
				local script = debug.getinfo(1, "S").source:sub(2)
				local command = "lua vim.schedule(function() local ok, err = pcall(dofile, "
					.. string.format("%q", script)
					.. "); if not ok then io.stderr:write(tostring(err) .. '\\n'); vim.cmd('cquit 1') end end)"
				local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", command }, {
					text = true,
					env = { LAZYVCS_RAIL_EARLY_CHILD = "1" },
				}):wait(30000)
				assert(result.code == 0 and (result.signal or 0) == 0, (result.stdout or "") .. (result.stderr or ""))
				assert(
					((result.stdout or "") .. (result.stderr or "")):find("8 passed", 1, true),
					"early-hook matrix did not finish"
				)
			end,
		},
		{
			"test_live_diff_absent_rail_released_equal_user_options_survive_focus",
			guarded(function()
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/added.txt", "new\n")
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/added.txt"))
				vim.wo.number = true
				local s = ctx.open_diff()
				ctx.wait_for(function()
					return s.rail
				end, "live rail", 15000)
				api.nvim_set_current_win(s.base_win)
				ctx.wait_for(function()
					return not s.rail
				end, "rail expand", 15000)
				vim.wo[s.base_win].number = false
				api.nvim_set_current_win(s.editable_win)
				api.nvim_set_current_win(s.base_win)
				assert(not vim.wo[s.base_win].number, "released rail resurrected a common write")
				require("lazyvcs.actions").close(s)
			end),
		},
		{
			"test_core_absent_rail_active_equal_edits_and_global_defaults",
			guarded(function()
				local win = api.nvim_get_current_win()
				local s = apply(win, options(true, "%l"))
				vim.cmd.split()
				local focused = api.nvim_get_current_win()
				for name, value in pairs({
					number = false,
					relativenumber = false,
					signcolumn = "no",
					foldcolumn = "0",
					statuscolumn = "",
					winfixwidth = true,
				}) do
					api.nvim_set_option_value(name, value, { win = win, scope = "local" })
				end
				assert(api.nvim_get_current_win() == focused)
				api.nvim_set_option_value("statuscolumn", "%#WarningMsg#GLOBAL%*", { scope = "global" })
				local projected = rail.user_options(s, win, capture(win))
				assert(
					not projected.number and projected.statuscolumn == "" and projected.winfixwidth,
					"equal edit was not recorded"
				)
				api.nvim_win_call(win, function()
					vim.cmd("setlocal nonumber statuscolumn=LOCAL")
				end)
				assert(s.rail.before.statuscolumn == "LOCAL")
				api.nvim_win_call(win, function()
					vim.cmd("set statuscolumn=PLAIN")
				end)
				assert(s.rail.before.statuscolumn == "PLAIN")
				rail.release(s)
				assert(not vim.wo[win].number and vim.wo[win].statuscolumn == "PLAIN" and vim.wo[win].winfixwidth)
			end),
		},
		{
			"test_core_absent_rail_tokens_preserve_both_native_clone_origins",
			guarded(function()
				api.nvim_buf_set_lines(0, 0, -1, false, { "shared text" })
				local first = api.nvim_get_current_win()
				vim.cmd.split()
				local second = api.nvim_get_current_win()
				vim.cmd.split()
				local focus = api.nvim_get_current_win()
				local source = api.nvim_create_namespace("rail-token-source")
				api.nvim_set_hl(source, "Normal", { bg = 0x102030 })
				api.nvim_set_hl_ns(source)
				for _, pair in ipairs({ { first, options(true, "%l") }, { second, options(false, "") } }) do
					api.nvim_win_set_hl_ns(pair[1], -1)
					vim.wo[pair[1]].numberwidth = 20
					apply(pair[1], pair[2])
				end
				for _, pair in ipairs({ { first, options(true, "%l") }, { second, options(false, "") } }) do
					local owner, expected = pair[1], pair[2]
					local ns = api.nvim_get_hl_ns({ winid = owner })
					vim.cmd.redraw()
					assert(vim.fn.getwininfo(owner)[1].textoff == 0, "rail marker reserved columns")
					local evaluated =
						api.nvim_eval_statusline(vim.wo[owner].statuscolumn, { winid = owner, use_statuscol_lnum = 1 })
					assert(evaluated.width == 0 and evaluated.str == "")
					local clone
					api.nvim_win_call(owner, function()
						clone = api.nvim_open_win(
							api.nvim_get_current_buf(),
							false,
							{ relative = "editor", row = 1, col = 1, width = 12, height = 2 }
						)
					end)
					assert(vim.deep_equal(capture(clone), expected), "clone lost its originating raw options")
					assert(api.nvim_get_hl_ns({ winid = owner }) == ns, "token changed owner namespace")
					assert(api.nvim_get_current_win() == focus)
					api.nvim_win_close(clone, true)
					api.nvim_set_current_win(owner)
					vim.cmd.split()
					clone = api.nvim_get_current_win()
					assert(vim.deep_equal(capture(clone), expected), "split lost its originating raw options")
					api.nvim_win_close(clone, true)
					api.nvim_set_current_win(focus)
				end
			end),
		},
		{
			"test_core_absent_rail_closed_and_wiped_origins_clean_saved_options",
			guarded(function()
				local host = api.nvim_get_current_win()
				for _, wipe in ipairs({ false, true }) do
					for _ = 1, 8 do
						local path = h.tempdir() .. "/closed-rail.txt"
						h.write_file(path, "closed rail\n")
						vim.cmd.vsplit(vim.fn.fnameescape(path))
						local owner, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
						vim.bo[buf].bufhidden = "hide"
						local expected = options(true, "%l")
						local s = apply(owner, expected)
						api.nvim_set_current_win(host)
						if wipe then
							api.nvim_buf_delete(buf, { force = true })
						end
						if api.nvim_win_is_valid(owner) then
							api.nvim_win_close(owner, true)
						end
						assert(not s.rail, "closed rail retained its slot")
						if not wipe then
							vim.cmd.tabnew()
							vim.cmd.edit(vim.fn.fnameescape(path))
							assert(vim.deep_equal(capture(0), expected), "closed origin cached its collapsed options")
							vim.cmd.tabclose()
						end
						api.nvim_set_current_win(host)
					end
				end
			end),
		},
		{
			"test_core_absent_rail_hidden_lifetimes_and_bounded_reuse",
			guarded(function()
				local path = h.tempdir() .. "/hidden.txt"
				h.write_file(path, "hidden\n")
				vim.cmd.edit(vim.fn.fnameescape(path))
				vim.bo.bufhidden = "hide"
				local win = api.nvim_get_current_win()
				local function count()
					local n = 0
					for name in pairs(api.nvim_get_hl(0, {})) do
						if name:match("^LazyVcsRailOwner%d+$") then
							n = n + 1
						end
					end
					return n
				end
				local before = count()
				for i = 1, 30 do
					local expected = options(i % 2 == 0, i % 2 == 0 and "%l" or "")
					local s = apply(win, expected)
					api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
					rail.release(s)
					vim.cmd.edit(vim.fn.fnameescape(path))
					assert(vim.deep_equal(capture(win), expected), "hidden record reused another lifetime")
				end
				assert(count() <= before + 1, "rail markers grew after completed lifetimes")
				vim.go.statuscolumn = "GLOBAL"
				local s = apply(win, options(false, ""))
				vim.go.statuscolumn = "LATER"
				rail.release(s)
				assert(api.nvim_get_option_value("statuscolumn", { win = win, scope = "local" }) == "")
			end),
		},
	}
end
