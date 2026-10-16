return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util = require("lazyvcs.util")
	local names = { "diff", "scrollbind", "cursorbind", "wrap", "foldmethod", "foldcolumn", "winbar", "winhighlight" }
	local hooks, original
	local function dispatch(name, tab)
		for _, callback in ipairs(hooks[name] or {}) do
			callback("test", {}, tab)
		end
	end
	local function get(win)
		return util.capture_win_options(win, names)
	end
	local function equal(actual, expected, message)
		assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual))
	end
	local function open(preexisting)
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		util.set_win_option(win, "winbar", " original ' bar | %f")
		if preexisting then
			vim.cmd("diffthis")
		end
		local before = get(win)
		require("lazyvcs").open()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf)
		end, "live diff did not open", 15000)
		return assert(require("lazyvcs.state").get(buf)), before
	end
	local function guarded(fn)
		return function()
			original = package.loaded.resession
			hooks = { pre_save = {}, post_save = {} }
			package.loaded.resession = {
				add_hook = function(name, callback)
					table.insert(hooks[name], callback)
				end,
				remove_hook = function(name, callback)
					for i, cb in ipairs(hooks[name]) do
						if cb == callback then
							table.remove(hooks[name], i)
							break
						end
					end
				end,
			}
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local ok, err = xpcall(fn, debug.traceback)
			if package.loaded["lazyvcs.integrations.resession"] then
				require("lazyvcs.integrations.resession").teardown()
			end
			package.loaded.resession = original
			h.cleanup()
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.cmd("diffoff")
			util.set_win_option(api.nvim_get_current_win(), "winbar", "")
			assert(ok, err)
		end
	end
	local function lazy_open(specs, expected)
		local integration = require("lazyvcs.integrations.resession")
		integration.teardown()
		local stub, preload = package.loaded.resession, package.preload.resession
		local config = package.loaded["lazy.core.config"]
		package.loaded.resession = nil
		package.loaded["lazy.core.config"] = specs and { plugins = specs } or nil
		local loads = 0
		package.preload.resession = function()
			loads = loads + 1
			return stub
		end
		local ok, err = xpcall(function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			assert(loads == 0, "setup loaded lazy Resession")
			local s = open(false)
			assert(loads == expected, "live diff loaded Resession " .. loads .. " times; expected " .. expected)
			assert(#hooks.pre_save == expected and #hooks.post_save == expected, "live diff did not attach hooks")
			if expected == 1 then
				integration.setup()
				assert(loads == 1 and #hooks.pre_save == 1, "repeated setup duplicated load or hooks")
			else
				-- Without a known lazy spec, a later open attaches an externally loaded plugin.
				package.loaded.resession = stub
			end
			require("lazyvcs.actions").close(s.editable_bufnr)
			s = open(false)
			assert(loads == expected and #hooks.pre_save == 1, "next open did not attach exactly once")
			require("lazyvcs.actions").close(s.editable_bufnr)
		end, debug.traceback)
		integration.teardown()
		package.loaded["lazy.core.config"] = config
		package.preload.resession, package.loaded.resession = preload, stub
		assert(ok, err)
	end
	local cases = {
		{
			"test_live_diff_resession_setup_does_not_load_plugin",
			function()
				local integration = require("lazyvcs.integrations.resession")
				integration.teardown()
				local stub, preload = package.loaded.resession, package.preload.resession
				package.loaded.resession = nil
				local loads = 0
				package.preload.resession = function()
					loads = loads + 1
					return stub
				end
				local ok, err = xpcall(function()
					require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
					assert(loads == 0 and package.loaded.resession == nil, "setup loaded lazy Resession")
					package.loaded.resession = stub
					api.nvim_exec_autocmds("User", { pattern = "LazyLoad", data = "neo-tree.nvim" })
					assert(#hooks.pre_save == 1, "LazyLoad did not attach already-loaded Resession")
					api.nvim_exec_autocmds("User", { pattern = "LazyLoad", data = "resession.nvim" })
					assert(#hooks.pre_save == 1, "Resession LazyLoad did not attach")
					integration.teardown()
					open(false)
					assert(#hooks.pre_save == 1, "live diff open did not attach loaded Resession")
				end, debug.traceback)
				package.preload.resession, package.loaded.resession = preload, stub
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_resession_open_loads_known_lazy_spec",
			function()
				for _, spec in ipairs({
					{ name = "resession.nvim" },
					{ name = "renamed", main = "resession" },
					{ name = "renamed", module = "resession" },
				}) do
					lazy_open({ [spec.name] = spec }, 1)
				end
			end,
		},
		{
			"test_live_diff_resession_open_does_not_load_without_lazy_spec",
			function()
				lazy_open(nil, 0)
				lazy_open({}, 0)
				lazy_open({ other = { name = "another.nvim", main = "another" } }, 0)
			end,
		},
		{
			"test_live_diff_resession_fold_restore_makes_progress",
			function()
				open(false)
				dispatch("pre_save")
				local foldclosed, foldend = vim.fn.foldclosed, vim.fn.foldclosedend
				local calls = 0
				-- Simulate zO silently failing to open the first fold.
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.foldclosed = function(line)
					calls = calls + 1
					assert(calls < 500, "fold restoration made no progress")
					return line == 1 and 1 or -1
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.foldclosedend = function(line)
					return line == 1 and 3 or foldend(line)
				end
				local ok, err = pcall(dispatch, "post_save")
				vim.fn.foldclosed, vim.fn.foldclosedend = foldclosed, foldend
				assert(ok, err)
				assert(calls > 0 and calls < 500, "fold restoration made no progress")
			end,
		},
		{
			"test_live_diff_resession_projects_derived_editable_splits",
			function()
				local s, before = open(false)
				api.nvim_set_current_win(s.editable_win)
				vim.cmd("split")
				local derived = api.nvim_get_current_win()
				local live = get(derived)
				local view = api.nvim_win_call(derived, vim.fn.winsaveview)
				dispatch("pre_save")
				equal(get(derived), before, "derived editor serialized transient diff options")
				dispatch("post_save")
				equal(get(derived), live, "derived editor did not resume live options")
				equal(api.nvim_win_call(derived, vim.fn.winsaveview), view, "derived view changed")
			end,
		},
		{
			"test_live_diff_resession_preserves_fold_state",
			function()
				local f = h.make_git_fixture()
				local left, right = {}, {}
				for i = 1, 180 do
					left[i] = "line " .. i
					right[i] = left[i]
				end
				right[40], right[140] = "change one", "change two"
				h.write_file(f.file, table.concat(right, "\n") .. "\n")
				local s = assert(require("lazyvcs.actions").open_target({
					backend = "git",
					root = f.root,
					path = f.file,
					relpath = "sample.txt",
					kind = "git_worktree",
					editable_side = "right",
					left = { label = "HEAD", lines = left },
					right = { label = "WORKTREE", path = f.file, modifiable = true },
				}))
				api.nvim_set_current_win(s.editable_win)
				vim.cmd("split")
				local wins = { s.editable_win, s.base_win, api.nvim_get_current_win() }
				vim.cmd("diffupdate")
				for _, win in ipairs(wins) do
					api.nvim_win_call(win, function()
						vim.cmd("normal! zM")
						assert(vim.fn.foldclosed(80) > 0, "fixture has no middle fold")
						api.nvim_win_set_cursor(win, { 80, 0 })
						vim.cmd("normal! zo")
					end)
				end
				local function folds(win)
					return api.nvim_win_call(win, function()
						local result = {}
						for i = 1, 180 do
							result[i] = vim.fn.foldclosed(i)
						end
						return result
					end)
				end
				local expected = {}
				for _, win in ipairs(wins) do
					expected[win] = folds(win)
				end
				dispatch("pre_save")
				dispatch("post_save")
				vim.wait(30, function()
					return false
				end)
				for _, win in ipairs(wins) do
					equal(folds(win), expected[win], "save changed open/closed folds")
				end
			end,
		},
		{
			"test_live_diff_close_cleans_replaced_base_buffer",
			function()
				for _, custom_bar in ipairs({ false, true }) do
					local s = open(false)
					local base = s.base_win
					api.nvim_set_current_win(base)
					vim.cmd("split")
					local replacement = api.nvim_create_buf(true, false)
					api.nvim_win_set_buf(base, replacement)
					util.set_win_options(base, {
						diff = true,
						scrollbind = true,
						cursorbind = true,
						winfixwidth = true,
						winbar = custom_bar and "user bar" or s.base_label_winbar,
					})
					require("lazyvcs.actions").close(s.editable_bufnr)
					assert(
						api.nvim_win_is_valid(base) and api.nvim_win_get_buf(base) == replacement,
						"replaced base closed"
					)
					for _, option in ipairs({ "diff", "scrollbind", "cursorbind", "winfixwidth" }) do
						assert(not util.get_win_option(base, option), "replaced base kept " .. option)
					end
					assert(
						util.get_win_option(base, "winbar") == (custom_bar and "user bar" or s.base_prev_winbar),
						"replaced base winbar not restored: "
							.. vim.inspect({
								custom_bar,
								util.get_win_option(base, "winbar"),
								s.base_prev_winbar,
								s.base_label_winbar,
							})
					)
					vim.cmd("silent! only!")
				end
			end,
		},

		{
			"test_live_diff_resession_serializes_original_window_options",
			function()
				for _, user_diff in ipairs({ false, true }) do
					local s, before = open(user_diff)
					local live, base = get(s.editable_win), get(s.base_win)
					local snapshot = vim.deepcopy(s.editable_window_options)
					local ns = api.nvim_get_hl_ns({ winid = s.editable_win })
					api.nvim_set_current_win(s.base_win)
					local focused = api.nvim_get_current_win()
					dispatch("pre_save")
					equal(get(s.editable_win), before, "serializer saw transient live diff options")
					assert(not vim.bo[s.base_bufnr].buflisted and vim.bo[s.base_bufnr].buftype == "nofile")
					assert(not require("lazyvcs.layout").bind_pair(s), "projection was rebound")
					dispatch("post_save")
					equal(get(s.editable_win), live, "editable options were not resumed")
					equal(get(s.base_win), base, "base options changed")
					equal(s.editable_window_options, snapshot, "close snapshot changed")
					assert(api.nvim_get_current_win() == focused, "save changed focus")
					vim.wait(20, function()
						return false
					end)
					assert(api.nvim_get_hl_ns({ winid = s.editable_win }) == ns, "highlight namespace changed")
					assert(require("lazyvcs.state").get(s.editable_bufnr) == s and s.phase == "active")
					require("lazyvcs.actions").close(s.editable_bufnr)
					equal(get(s.editable_win), before, "close did not restore original options")
					vim.cmd("diffoff")
				end
			end,
		},
		{
			"test_live_diff_resession_recovers_interrupted_save",
			function()
				local s, before = open(false)
				local live = get(s.editable_win)
				dispatch("pre_save")
				equal(get(s.editable_win), before, "interrupted save did not project editor options")
				dispatch("pre_save")
				ctx.wait_for(function()
					return s.phase == "active"
				end, "interrupted save was not resumed")
				equal(get(s.editable_win), live, "fallback did not restore live options")
				dispatch("post_save")
				local setter, notify = util.set_win_option_noautocmd, util.notify
				local failed, messages = false, {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.set_win_option_noautocmd = function(win, option, value)
					if not failed then
						failed = true
						error("forced projection failure\nsecond line")
					end
					setter(win, option, value)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					messages[#messages + 1] = message
				end
				local projected, err = pcall(dispatch, "pre_save")
				util.set_win_option_noautocmd, util.notify = setter, notify
				assert(projected, err)
				assert(
					#messages == 1 and not messages[1]:find("\n"),
					"projection error was not reported once on one line"
				)
				equal(get(s.editable_win), live, "projection failure did not restore options")
				assert(s.phase == "active", "projection failure left session suspended")
				dispatch("pre_save")
				require("lazyvcs.actions").close(s.editable_bufnr)
				dispatch("post_save")
				assert(#require("lazyvcs.state").list() == 0, "closed session revived")
				equal(get(s.editable_win), before, "closed window regained transient options")
			end,
		},
		{
			"test_live_diff_resession_scopes_projection_and_suppresses_optionset",
			function()
				local first, before = open(false)
				local tab = first.tabpage
				vim.cmd("tabnew")
				local second = open(false)
				local live = get(second.editable_win)
				local events = 0
				local group = api.nvim_create_augroup("LazyVCSIntegrationOptions", { clear = true })
				api.nvim_create_autocmd("OptionSet", {
					group = group,
					pattern = "*",
					callback = function()
						events = events + 1
					end,
				})
				util.set_win_option(second.editable_win, "wrap", not live.wrap)
				assert(events > 0, "OptionSet control did not fire")
				util.set_win_option(second.editable_win, "wrap", live.wrap)
				events = 0
				dispatch("pre_save", tab)
				local projected = get(first.editable_win)
				dispatch("post_save", tab)
				api.nvim_del_augroup_by_id(group)
				equal(projected, before, "tab save did not project its editor")
				equal(get(second.editable_win), live, "tab save changed another tab")
				assert(events == 0, "projection dispatched OptionSet")
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				assert(#hooks.pre_save == 1 and #hooks.post_save == 1, "setup duplicated save hooks")
				util.set_win_option(second.editable_win, "wrap", not live.wrap)
				dispatch("pre_save")
				assert(util.get_win_option(second.editable_win, "wrap") == not live.wrap, "user option overwritten")
				api.nvim_buf_set_lines(second.editable_bufnr, 0, 1, false, { "edited in save hook" })
				dispatch("post_save")
				ctx.wait_for(function()
					return second.current_text and second.current_text.lines[1] == "edited in save hook"
				end, "save hook edit was not refreshed")
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
