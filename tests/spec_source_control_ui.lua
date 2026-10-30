return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native = require("lazyvcs.source_control.native")
	local model = require("lazyvcs.source_control.model")
	local input = require("lazyvcs.source_control.input")
	local confirm = require("lazyvcs.source_control.confirm")
	local function key(bufnr, lhs)
		for _, mapping in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
			if mapping.lhs == lhs or (lhs:sub(1, 1) == "<" and mapping.lhs:lower() == lhs:lower()) then
				return mapping.callback()
			end
		end
		error("mapping missing: " .. lhs)
	end
	local function select_node(s, predicate)
		for line, node in ipairs(s.lazyvcs_line_nodes) do
			if predicate(node) then
				api.nvim_win_set_cursor(s.winid, { line, 0 })
				return node
			end
		end
		error("sidebar node missing")
	end
	local function selected(s)
		return s.lazyvcs_line_nodes[api.nvim_win_get_cursor(s.winid)[1]]
	end
	local function settled(s)
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "sidebar did not settle", 15000)
	end
	local function open(root)
		local s = native.open({ path = root })
		settled(s)
		return s
	end
	local function details(s, root)
		select_node(s, function(n)
			return n.type == "repo_changes" and n.path == root
		end)
		key(s.bufnr, "l")
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[root].details_loaded
		end, "details did not load", 15000)
		native.render(s)
	end
	local function guarded(fn)
		return function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				blame = { persist = false },
				source_control = { remote_refresh = "manual", auto_expand_width = false },
			})
			local summary, discover = model.load_repo_summary_async, model.discover_async
			local ok, err = xpcall(fn, debug.traceback)
			model.load_repo_summary_async, model.discover_async = summary, discover
			vim.cmd("stopinsert")
			for _, win in ipairs(api.nvim_list_wins()) do
				if api.nvim_win_get_config(win).relative ~= "" then
					pcall(api.nvim_win_close, win, true)
				end
			end
			vim.wait(20, function()
				return false
			end)
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	local function refresh_selection(vcs, move)
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		for i = 1, 15 do
			h.write_file(f.root .. string.format("/file%02d.txt", i), "new change\n")
		end
		local s = open(f.root)
		details(s, f.root)
		for _, node in ipairs(vim.deepcopy(s.lazyvcs_line_nodes)) do
			if node.type == "section" then
				select_node(s, function(n)
					return n.id == node.id
				end)
				key(s.bufnr, "l")
			end
		end
		local node = select_node(s, function(n)
			return n.type == "file" and n.extra.relpath == "file12.txt"
		end)
		local original = model.discover_async
		local release
		---@diagnostic disable-next-line: duplicate-set-field
		model.discover_async = function(root, depth, done, opts)
			return original(root, depth, function(specs, err)
				release = function()
					done(specs, err)
				end
			end, opts)
		end
		key(s.bufnr, "R")
		ctx.wait_for(function()
			return release ~= nil
		end, "discovery did not finish", 15000)
		local target = node.id
		if move then
			-- User movement during loading overrides the saved file selection.
			api.nvim_win_set_cursor(s.winid, { 1, 0 })
			target = selected(s).id
		end
		assert(release)()
		settled(s)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[f.root].details_loaded
		end, "details not restored", 15000)
		native.render(s)
		assert(selected(s).id == target, "refresh lost the selected node: " .. selected(s).type)
	end
	local cases = {
		{
			"test_source_control_input_preserves_multiline_paste",
			function()
				local result
				local popup = input.open_text({}, function(value)
					result = value
				end)
				api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, { "subject", "", "body" })
				key(popup.bufnr, "<CR>")
				assert(result == "subject\n\nbody", "pasted commit body was discarded")
				popup = input.open_text({ default_value = result }, function(value)
					result = value
				end)
				assert(vim.deep_equal(api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), { "subject", "", "body" }))
				assert(api.nvim_win_get_height(popup.winid) >= 3, "multiline draft must be inspectable")
				key(popup.bufnr, "<CR>")
				assert(result == "subject\n\nbody")
			end,
		},
		{
			"test_source_control_input_preserves_generated_multiline_message",
			function()
				local result
				local popup = input.open_text({
					can_generate = true,
					on_generate = function(done)
						done("subject\n\nbody")
					end,
				}, function(value)
					result = value
				end)
				popup.generate()
				key(popup.bufnr, "<CR>")
				assert(result == "subject\n\nbody", "generated body was discarded")
			end,
		},
		{
			"test_source_control_confirm_disables_inherited_folds",
			function()
				local origin = api.nvim_get_current_win()
				local names = { "foldmethod", "foldexpr", "foldlevel", "foldenable" }
				local util = require("lazyvcs.util")
				local saved = util.capture_win_options(origin, names)
				local defaults = {}
				for _, name in ipairs(names) do
					defaults[name] = api.nvim_get_option_value(name, { scope = "global" })
				end
				local ok, err = xpcall(function()
					vim.wo[origin].foldmethod = "expr"
					vim.wo[origin].foldexpr = "1"
					vim.wo[origin].foldlevel = 0
					vim.wo[origin].foldenable = true
					local result
					local popup = confirm.open({}, function(value)
						result = value
					end)
					api.nvim_win_call(popup.winid, function()
						vim.cmd("redraw!")
						assert(vim.fn.foldclosed(1) == -1, "confirmation choices are folded")
					end)
					key(popup.bufnr, "j")
					key(popup.bufnr, "<CR>")
					assert(result == "confirm_session")
					assert(util.get_win_option(origin, "foldenable"), "origin folding changed")
				end, debug.traceback)
				for name, value in pairs(defaults) do
					api.nvim_set_option_value(name, value, { scope = "global" })
				end
				for name, value in pairs(saved) do
					util.set_win_option(origin, name, value)
				end
				assert(ok, err)
			end,
		},
		{
			"test_source_control_refresh_restores_selected_file",
			function()
				refresh_selection("git")
			end,
		},
		{
			"test_svn_source_control_refresh_restores_selected_file",
			function()
				refresh_selection("svn")
			end,
		},
		{
			"test_source_control_refresh_respects_selection_during_loading",
			function()
				refresh_selection("git", true)
			end,
		},
		{
			"test_source_control_failed_status_never_claims_clean",
			function()
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/.git/index", "broken\n")
				local s = open(f.root)
				assert(s.lazyvcs_repo_cache[f.root].error, "fixture status must fail")
				select_node(s, function(n)
					return n.type == "repo_changes"
				end)
				key(s.bufnr, "l")
				ctx.wait_for(function()
					return not s.lazyvcs_repo_cache[f.root].loading_details
				end, "failure did not settle", 15000)
				native.render(s)
				local text = table.concat(api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n")
				assert(
					not text:find("Working tree clean", 1, true) and not text:find("No changes", 1, true),
					"failed status claims clean"
				)
				local retry = select_node(s, function(n)
					return n.type == "message" and n.extra and n.extra.action ~= nil
				end)
				assert(retry.name:find("failed", 1, true), "failure must offer a visible retry")
				h.exec({ "git", "read-tree", "HEAD" }, f.root)
				key(s.bufnr, "<CR>")
				ctx.wait_for(function()
					return s.lazyvcs_repo_cache[f.root].details_loaded
				end, "retry did not load changes", 15000)
				assert(not s.lazyvcs_repo_cache[f.root].detail_error)
			end,
		},
		{
			"test_source_control_mutation_errors_do_not_offer_status_retry",
			function()
				local f = h.make_git_fixture()
				local s = open(f.root)
				details(s, f.root)
				local runtime = require("lazyvcs.state")
				local ops = require("lazyvcs.source_control.ops")
				local node = { path = f.root, extra = { repo_root = f.root } }
				runtime.set_repo_job(f.root, {
					status = "error",
					action = "commit",
					label = "Committing...",
					error = "commit hook rejected the message",
				})
				local ok, err = xpcall(function()
					-- Successful real status/detail reads cannot resolve a failed commit.
					for _ = 1, 2 do
						ops.retry_repo(s, node)
						settled(s)
						ctx.wait_for(function()
							return s.lazyvcs_repo_cache[f.root].details_loaded
						end, "status reload did not restore details", 15000)
						s.lazyvcs_expanded[f.root .. "::section::changes"] = true
						native.render(s)
						local text = table.concat(api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n")
						assert(not text:find("Status failed:", 1, true), "failed commit was labelled a status failure")
						assert(text:find("sample.txt", 1, true), "mutation error hid loaded changes")
						for _, row in ipairs(s.lazyvcs_line_nodes) do
							assert(
								not (row.extra and row.extra.action == "retry_repo"),
								"mutation error offered a status retry"
							)
							if row.type == "repo_changes" then
								assert(row.extra.sync.status == "error", "mutation failure lost its error badge")
							end
						end
						assert(runtime.get_repo_job(f.root).error == "commit hook rejected the message")
					end
					-- A simultaneous read failure must still offer its own retry.
					for _, field in ipairs({ "error", "detail_error" }) do
						s.lazyvcs_repo_cache[f.root][field] = "status read failed"
						native.render(s)
						local retry = select_node(s, function(n)
							return n.extra and n.extra.action == "retry_repo"
						end)
						assert(retry.name:find("status read failed", 1, true), "mutation error masked the read failure")
						s.lazyvcs_repo_cache[f.root][field] = nil
					end
				end, debug.traceback)
				runtime.clear_repo_job(f.root)
				assert(ok, err)
			end,
		},
		{
			"test_source_control_status_errors_preserve_cached_rows",
			function()
				local f = h.make_git_fixture()
				local s = open(f.root)
				details(s, f.root)
				select_node(s, function(n)
					return n.type == "section"
				end)
				key(s.bufnr, "l")
				local repo = s.lazyvcs_repo_cache[f.root]
				repo.detail_error = "detail failed"
				native.render(s)
				local function text()
					return table.concat(api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n")
				end
				assert(
					text():find("Status failed:", 1, true) and text():find("sample.txt", 1, true),
					"error hid cached changes"
				)
				repo.sections = {}
				repo.counts.local_changes = 0
				for _, field in ipairs({ "error", "detail_error" }) do
					repo.error, repo.detail_error = nil, nil
					repo[field] = "status failed"
					native.render(s)
					assert(not text():find("No changes", 1, true), "failed empty details claimed clean")
					repo.loading_details = true
					native.render(s)
					assert(text():find("Loading repository status...", 1, true), "retry lost loading feedback")
					repo.loading_details = false
				end
				repo.error, repo.detail_error = nil, nil
				repo.remote_error = "remote unavailable"
				native.render(s)
				assert(
					text():find("No changes", 1, true) and not text():find("Status failed:", 1, true),
					"remote-only error invalidated local clean status"
				)
			end,
		},
		{
			"test_source_control_h_collapses_repository",
			function()
				local f = h.make_git_fixture()
				local s = open(f.root)
				details(s, f.root)
				local id = model.repo_changes_id(f.root)
				select_node(s, function(n)
					return n.id == id
				end)
				s.lazyvcs_force_expand = { [id] = true }
				key(s.bufnr, "h")
				assert(not s.lazyvcs_expanded[id], "h did not collapse repository")
				assert(not s.lazyvcs_force_expand[id], "collapse retained pending expansion")
				key(s.bufnr, "h")
				assert(not s.lazyvcs_expanded[id], "h expanded collapsed repository")
				key(s.bufnr, "l")
				assert(s.lazyvcs_expanded[id])
				key(s.bufnr, "l")
				assert(not s.lazyvcs_expanded[id], "documented l toggle changed")
			end,
		},
		{
			"test_source_control_background_modal_preserves_focus",
			function()
				for _, close_buffer in ipairs({ true, false }) do
					local origin = api.nvim_get_current_win()
					api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
					api.nvim_win_set_cursor(origin, { 1, 0 })
					local result, calls = nil, 0
					local popup = confirm.open({}, function(value)
						result, calls = value, calls + 1
					end)
					vim.cmd("tabnew")
					local active = api.nvim_get_current_win()
					api.nvim_win_set_cursor(origin, { 3, 0 })
					if close_buffer then
						api.nvim_buf_delete(popup.bufnr, { force = true })
					else
						api.nvim_win_close(popup.winid, true)
					end
					ctx.wait_for(function()
						return calls > 0
					end, "popup did not cancel")
					assert(result == "cancel" and calls == 1)
					assert(api.nvim_get_current_win() == active, "background cancellation stole focus")
					assert(api.nvim_win_get_cursor(origin)[1] == 3, "background cancellation reset origin cursor")
					vim.cmd("tabclose!")
				end
			end,
		},
		{
			"test_source_control_active_modal_restores_cursor_on_close",
			function()
				api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
				local origin = api.nvim_get_current_win()
				api.nvim_win_set_cursor(origin, { 2, 0 })
				local result
				local popup = confirm.open({}, function(value)
					result = value
				end)
				api.nvim_win_set_cursor(origin, { 3, 0 })
				api.nvim_win_close(popup.winid, true)
				ctx.wait_for(function()
					return result ~= nil
				end, "popup did not cancel")
				assert(
					api.nvim_get_current_win() == origin and api.nvim_win_get_cursor(origin)[1] == 2,
					"focused modal did not restore origin cursor"
				)
			end,
		},
		{
			"test_source_control_cancel_suppresses_initial_summary_retry",
			function()
				local f = h.make_git_fixture()
				local original = model.load_repo_summary_async
				for _, control in ipairs({ "command", "path", "mapping" }) do
					local calls, late = 0, nil
					---@diagnostic disable-next-line: duplicate-set-field
					model.load_repo_summary_async = function(repo, opts, run, done)
						calls = calls + 1
						late = function()
							original(repo, opts, run, done)
						end
					end
					local s = native.open({ path = f.root })
					ctx.wait_for(function()
						return calls > 0
					end, "summary did not start", 15000)
					if control == "mapping" then
						select_node(s, function(n)
							return n.type == "repo_changes"
						end)
						key(s.bufnr, "X")
					else
						native.cancel(control == "path" and f.root or nil)
					end
					native.navigate(s)
					assert(calls == 1, control .. " restarted cancelled summary")
					assert(not s.lazyvcs_hydration_active)
					assert(late)()
					vim.wait(100, function()
						return false
					end)
					assert(not s.lazyvcs_repo_cache[f.root].summary_loaded, "late summary was accepted")
					model.load_repo_summary_async = original
					native.refresh(false)
					settled(s)
					assert(s.lazyvcs_repo_cache[f.root].summary_loaded, "explicit refresh did not retry")
					native.close()
				end
			end,
		},
		{
			"test_source_control_cancelled_refresh_preserves_repository_preferences",
			function()
				local original = model.discover_async
				local persist = require("lazyvcs.source_control.persist")
				for _, mode in ipairs({ "single", "multiple" }) do
					for _, retry in ipairs({ "refresh", "open" }) do
						local f = h.make_git_source_control_fixture()
						local s = open(f.root)
						s.lazyvcs_selection_mode = mode
						s.lazyvcs_repo_visibility_overrides = { [f.git_clean] = true, [f.git_dirty] = false }
						s.lazyvcs_focused_repo = f.git_clean
						native.render(s)
						persist.save_state(s)
						local preferences = persist.load(f.root)
						local specs = vim.deepcopy(s.lazyvcs_repo_specs)
						local visibility = vim.deepcopy(s.lazyvcs_repo_visibility)
						local late
						---@diagnostic disable-next-line: duplicate-set-field
						model.discover_async = function(root, depth, done, opts)
							return original(root, depth, function(found, err)
								late = function()
									done(found, err)
								end
							end, opts)
						end
						native.refresh(false)
						ctx.wait_for(function()
							return late ~= nil
						end, "refresh discovery did not finish", 15000)
						local function check(phase)
							assert(
								vim.deep_equal(s.lazyvcs_repo_specs, specs),
								phase .. " discarded completed repository specs"
							)
							assert(
								vim.deep_equal(s.lazyvcs_repo_visibility, visibility),
								phase .. " changed repository visibility"
							)
							assert(s.lazyvcs_focused_repo == f.git_clean, phase .. " lost focused repository")
							persist.save_state(s)
							assert(
								vim.deep_equal(persist.load(f.root), preferences),
								phase .. " overwrote saved preferences"
							)
						end
						check("pending refresh")
						native.cancel(retry == "open" and f.root or nil)
						native.render(s)
						check("cancelled refresh")
						assert(late)()
						check("late discovery")
						late = nil
						if retry == "open" then
							native.open({ path = f.root })
						else
							native.refresh(false)
						end
						ctx.wait_for(function()
							return late ~= nil
						end, "explicit retry did not rediscover", 15000)
						check("pending retry")
						assert(late)()
						settled(s)
						check("completed retry")
						model.discover_async = original
						native.close()
					end
				end
			end,
		},
		{
			"test_source_control_cancelled_initial_discovery_preserves_saved_preferences",
			function()
				local f = h.make_git_source_control_fixture()
				local persist = require("lazyvcs.source_control.persist")
				persist.save(f.root, {
					visible_repos = { f.git_clean },
					hidden_repos = { f.git_dirty },
					focused_repo = f.git_clean,
					show_clean = true,
					selection_mode = "multiple",
					changes_view_mode = "tree",
					changes_sort = "path",
				})
				local preferences = persist.load(f.root)
				local s = native.open({ path = f.root })
				assert(s.lazyvcs_discovering, "initial discovery must be pending")
				native.cancel()
				native.render(s)
				assert(s.lazyvcs_focused_repo == f.git_clean, "cancelled discovery cleared saved focus")
				assert(
					s.lazyvcs_repo_visibility_overrides[f.git_clean] == true,
					"cancelled discovery cleared visible override"
				)
				assert(
					s.lazyvcs_repo_visibility_overrides[f.git_dirty] == false,
					"cancelled discovery cleared hidden override"
				)
				persist.save_state(s)
				assert(
					vim.deep_equal(persist.load(f.root), preferences),
					"cancelled discovery overwrote saved preferences"
				)
				native.refresh(false)
				settled(s)
				assert(s.lazyvcs_focused_repo == f.git_clean and s.lazyvcs_repo_visibility[f.git_clean])
			end,
		},
		{
			"test_source_control_cancel_stops_discovery_and_late_results",
			function()
				local f = h.make_git_fixture()
				local original = model.discover_async
				for _, scoped in ipairs({ false, true }) do
					local done, killed
					---@diagnostic disable-next-line: duplicate-set-field
					model.discover_async = function(_, _, callback)
						done = callback
						return {
							kill = function()
								killed = true
							end,
						}
					end
					local s = native.open({ path = f.root })
					assert(s.lazyvcs_discovering)
					native.cancel(scoped and f.root or nil)
					assert(killed and not s.lazyvcs_discovering, "cancellation left discovery running")
					assert(s.lazyvcs_discovery_handle == nil and s.lazyvcs_remote_refresh == nil)
					assert(done)({ { root = f.root, vcs = "git", name = "fixture" } })
					assert(
						#s.lazyvcs_repo_specs == 0 and not s.lazyvcs_hydration_active,
						"late discovery restarted hydration"
					)
					model.discover_async = original
					if scoped then
						native.open({ path = f.root })
					else
						native.refresh(false)
					end
					settled(s)
					assert(s.lazyvcs_repo_cache[f.root].summary_loaded, "explicit discovery retry failed")
					native.close()
				end
			end,
		},
		{
			"test_source_control_scoped_cancel_preserves_unrelated_discovery",
			function()
				local workspace = h.tempdir()
				local target = workspace .. "/target"
				local done, killed
				---@diagnostic disable-next-line: duplicate-set-field
				model.discover_async = function(_, _, callback)
					done = callback
					return {
						kill = function()
							killed = true
						end,
					}
				end
				local s = native.open({ path = workspace })
				native.cancel(target)
				assert(
					s.lazyvcs_discovering and not killed,
					"repository cancellation stopped the broader workspace scan"
				)
				local loaded = {}
				---@diagnostic disable-next-line: duplicate-set-field
				model.load_repo_summary_async = function(repo)
					loaded[repo.root] = true
				end
				assert(done)({
					{ root = target, vcs = "git", name = "cancelled" },
					{ root = workspace .. "/other", vcs = "git", name = "other" },
				})
				assert(
					not loaded[target] and loaded[workspace .. "/other"],
					"scoped cancellation restarted its root or blocked another root"
				)
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
