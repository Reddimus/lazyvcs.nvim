return function(ctx)
	local api, h = vim.api, ctx.helpers
	local function normalize(path)
		local absolute = vim.fn.fnamemodify(path, ":p")
		return vim.fs.normalize(vim.uv.fs_realpath(absolute) or absolute)
	end
	local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
	local function guarded(fn)
		return function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local ok, err = xpcall(fn, debug.traceback)
			pcall(require("lazyvcs.source_control.native").close)
			h.cleanup()
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	local function comparison(f)
		return {
			backend = "git",
			root = f.root,
			path = f.file,
			relpath = "sample.txt",
			kind = "git_worktree",
			editable_side = "right",
			left = { label = "HEAD", lines = { "one", "two", "three" } },
			right = { label = "WORKTREE", path = f.file, modifiable = true },
		}
	end
	local cases = {
		{
			"test_source_control_integrations_reuses_readonly_comparison",
			function()
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local editor = api.nvim_get_current_win()
				local readonly = comparison(f)
				readonly.kind, readonly.editable_side = "git_submodule", nil
				readonly.right = { label = "WORKTREE", lines = { "Subproject commit changed" } }
				local first = assert(actions.open_target(readonly))
				local native = require("lazyvcs.source_control.native")
				local sidebar = native.open({ path = f.root })
				sidebar.editor_winid = editor
				sidebar.lazyvcs_repo_cache[f.root] = { root = f.root, vcs = "git" }
				local count = #api.nvim_tabpage_list_wins(0)
				local backends, done = require("lazyvcs.backends"), nil
				local original = backends.load_diff_target_async
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_diff_target_async = function(_, callback)
					done = callback
				end
				local ok, err = pcall(
					require("lazyvcs.source_control.ops").open_change,
					sidebar,
					{ type = "file", path = f.file, extra = { repo_root = f.root } }
				)
				backends.load_diff_target_async = original
				assert(ok, err)
				assert(done, "loader did not run")(comparison(f))
				local second = assert(state.get(vim.fn.bufnr(f.file)))
				assert(second.editable_win == editor, "read-only comparison editor was not reused")
				assert(#api.nvim_tabpage_list_wins(0) == count, "comparison added a window")
				assert(first.closing and #state.list() == 1, "first comparison remained open")
				actions.close(second.editable_bufnr)
				api.nvim_set_current_win(editor)
				first = assert(actions.open_target(readonly))
				sidebar.editor_winid = editor
				api.nvim_set_current_win(sidebar.winid)
				sidebar.lazyvcs_open_file(sidebar, f.file)
				assert(api.nvim_get_current_win() == editor, "native file open did not reuse read-only editor")
				ctx.wait_for(function()
					return #state.list() == 0
				end, "native file open kept comparison")
			end,
		},
		{
			"test_source_control_integrations_invalid_destination_notifies",
			function()
				local f = h.make_git_fixture()
				local target = require("lazyvcs.editor_target").capture()
				api.nvim_win_set_buf(target.winid, api.nvim_create_buf(true, false))
				local util, messages = require("lazyvcs.util"), {}
				local original = util.notify
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					messages[#messages + 1] = message
				end
				local ok, result = pcall(actions.open_target, comparison(f), target)
				util.notify = original
				assert(ok and result == nil)
				assert(#messages == 1, "invalid destination returned nil without notification")
			end,
		},

		{
			"test_source_control_integrations_editor_eligibility",
			function()
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local editor = api.nvim_get_current_win()
				vim.cmd("topleft vsplit")
				local plugin = api.nvim_get_current_win()
				local special = api.nvim_create_buf(false, true)
				vim.bo[special].buftype = "nofile"
				api.nvim_win_set_buf(plugin, special)
				local s = actions.open_target(comparison(f))
				assert(s and s.editable_win == editor, "special plugin window selected instead of ordinary editor")
				assert(api.nvim_win_get_buf(plugin) == special, "plugin buffer replaced")
				local target = require("lazyvcs.editor_target")
				local tab = api.nvim_get_current_tabpage()
				assert(not target.eligible(s.base_win, tab), "live diff base accepted")
				assert(target.capture(s.editable_win).winid == editor, "existing comparison was not reused")
				actions.close(s.editable_bufnr)
				for _, option in ipairs({ "winfixbuf", "previewwindow" }) do
					api.nvim_set_option_value(option, true, { win = editor, scope = "local" })
					assert(not target.eligible(editor, tab), option .. " window accepted")
					api.nvim_set_option_value(option, false, { win = editor, scope = "local" })
				end
				vim.w[editor].lazyvcs_compare = true
				assert(not target.eligible(editor, tab), "Compare window accepted")
				vim.w[editor].lazyvcs_compare = nil
				api.nvim_win_call(editor, function()
					vim.cmd("diffthis")
				end)
				assert(target.capture(plugin).winid == editor, "user diff must remain eligible")
				api.nvim_set_current_win(editor)
				vim.cmd("rightbelow vsplit")
				local ordinary = api.nvim_get_current_win()
				vim.cmd("diffoff")
				assert(target.capture(plugin).winid == ordinary, "user diff preferred over non-diff editor")
				api.nvim_win_close(ordinary, true)
				api.nvim_win_call(editor, function()
					vim.cmd("diffoff")
				end)
				local float = api.nvim_open_win(api.nvim_create_buf(true, false), false, {
					relative = "editor",
					row = 1,
					col = 1,
					width = 20,
					height = 2,
				})
				assert(not target.eligible(float, tab), "floating editor accepted")
				api.nvim_win_close(float, true)
			end,
		},
		{
			"test_source_control_integrations_capture_eligible_editor",
			function()
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local editor = api.nvim_get_current_win()
				vim.cmd("topleft vsplit")
				local plugin, special = api.nvim_get_current_win(), api.nvim_create_buf(false, true)
				vim.bo[special].buftype = "nofile"
				api.nvim_win_set_buf(plugin, special)
				local ops, backends = require("lazyvcs.source_control.ops"), require("lazyvcs.backends")
				local sidebar = {
					path = f.root,
					editor_winid = plugin,
					lazyvcs_repo_cache = { [f.root] = { root = f.root, vcs = "git" } },
					lazyvcs_render = function() end,
				}
				local node = { type = "file", path = f.file, extra = { repo_root = f.root } }
				local original, done = backends.load_diff_target_async, nil
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_diff_target_async = function(_, callback)
					done = callback
				end
				local ok, err = pcall(ops.open_change, sidebar, node)
				backends.load_diff_target_async = original
				assert(ok, err)
				vim.cmd("tabnew")
				local focused = api.nvim_get_current_win()
				assert(done, "target loader callback was not captured")(comparison(f))
				local session = state.get(vim.fn.bufnr(f.file))
				assert(session and session.editable_win == editor, "pending open captured a special plugin window")
				assert(api.nvim_get_current_win() == focused, "pending open stole another tab's focus")
				assert(api.nvim_win_get_buf(plugin) == special, "pending open replaced plugin buffer")
				actions.close(session.editable_bufnr)
				api.nvim_set_current_win(plugin)
				original = backends.load_diff_target_async
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_diff_target_async = function(_, callback)
					done = callback
				end
				ok, err = pcall(ops.open_change, sidebar, node)
				backends.load_diff_target_async = original
				assert(ok, err)
				api.nvim_win_set_buf(editor, api.nvim_create_buf(true, false))
				assert(done, "target loader callback was not captured")(comparison(f))
				assert(#state.list() == 0, "pending open reused a changed destination")
			end,
		},
		{
			"test_source_control_integrations_reject_redirected_placement",
			function()
				local f = h.make_git_fixture()
				local editor = api.nvim_get_current_win()
				local replacement = api.nvim_create_buf(true, false)
				local group = api.nvim_create_augroup("LazyVCSIntegrationRedirect", { clear = true })
				api.nvim_create_autocmd("BufWinEnter", {
					group = group,
					callback = function(event)
						if normalize(api.nvim_buf_get_name(event.buf)) == normalize(f.file) then
							api.nvim_win_set_buf(editor, replacement)
						end
					end,
				})
				local s = actions.open_target(comparison(f))
				api.nvim_del_augroup_by_id(group)
				assert(s == nil and #state.list() == 0, "redirected editor registered a diff session")
				assert(api.nvim_win_get_buf(editor) == replacement, "redirected buffer overwritten by cleanup")
				local redirected
				group = api.nvim_create_augroup("LazyVCSIntegrationRedirect", { clear = true })
				api.nvim_create_autocmd("BufWinEnter", {
					group = group,
					callback = function(event)
						if api.nvim_buf_get_name(event.buf):match("^lazyvcs://") then
							redirected = api.nvim_get_current_win()
							api.nvim_win_set_buf(redirected, replacement)
						end
					end,
				})
				s = actions.open_target(comparison(f))
				api.nvim_del_augroup_by_id(group)
				assert(s == nil and #state.list() == 0, "redirected base registered a diff session")
				assert(redirected and api.nvim_win_is_valid(redirected), "cleanup closed a redirected base window")
				assert(api.nvim_win_get_buf(redirected) == replacement, "cleanup replaced the redirected base buffer")
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
