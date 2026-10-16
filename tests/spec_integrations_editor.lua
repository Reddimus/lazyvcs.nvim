return function(ctx)
	local api, h = vim.api, ctx.helpers
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
				actions.close(s.editable_bufnr)
				local target = require("lazyvcs.editor_target")
				local tab = api.nvim_get_current_tabpage()
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
						if vim.fs.normalize(api.nvim_buf_get_name(event.buf)) == f.file then
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
