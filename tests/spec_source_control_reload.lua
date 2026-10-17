return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native, model, ops =
		require("lazyvcs.source_control.native"),
		require("lazyvcs.source_control.model"),
		require("lazyvcs.source_control.ops")
	local function settled(s)
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "summary not ready", 15000)
	end
	local function open(svn)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { remote_refresh = "manual", auto_expand_width = false },
		})
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		h.write_file(f.root .. "/new.txt", "new\n")
		local s = native.open({ path = f.root })
		settled(s)
		return s, f
	end
	local function details(s, root)
		ops.open_repo(s, { type = "repo_changes", path = root, extra = { repo_root = root } }, function() end)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[root].details_loaded
		end, "details not ready", 15000)
		s.lazyvcs_expanded[root .. "::section::changes"] = true
		native.render(s)
	end
	local function key(s, lhs)
		for _, map in ipairs(api.nvim_buf_get_keymap(s.bufnr, "n")) do
			if map.lhs:lower() == lhs:lower() then
				return map.callback()
			end
		end
		error("missing mapping " .. lhs)
	end
	local function select(s, predicate)
		for i, node in ipairs(s.lazyvcs_line_nodes) do
			if predicate(node) then
				api.nvim_win_set_cursor(s.winid, { i, 0 })
				return
			end
		end
		error("node missing")
	end
	local function refresh(svn)
		local s, f = open(svn)
		details(s, f.root)
		s.lazyvcs_expanded[f.root .. "::section::untracked"] = false
		local expanded = vim.deepcopy(s.lazyvcs_expanded)
		local summary, detail = model.load_repo_summary_async, model.load_repo_details_async
		local old_summary, old_detail
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_summary_async = function(repo, opts, run, done)
			return summary(repo, opts, run, function(value, err)
				old_summary = function()
					done(value, err)
				end
			end)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_details_async = function(repo, opts, run, done)
			return detail(repo, opts, run, function(value, err)
				old_detail = function()
					done(value, err)
				end
			end)
		end
		local ok, err = xpcall(function()
			s.lazyvcs_repo_cache[f.root].summary_loaded = false
			s.lazyvcs_repo_cache[f.root].details_loaded = false
			native.navigate(s)
			ops.open_repo(s, {
				type = "repo_changes",
				path = f.root,
				extra = { repo_root = f.root },
				is_expanded = function()
					return false
				end,
			}, function() end)
			ctx.wait_for(function()
				return old_summary and old_detail
			end, "obsolete reads not ready", 15000)
			model.load_repo_summary_async, model.load_repo_details_async = summary, detail
			s.lazyvcs_expanded = vim.deepcopy(expanded)
			h.write_file(f.file, "refreshed contents\n")
			key(s, "R")
			settled(s)
			ctx.wait_for(function()
				return s.lazyvcs_repo_cache[f.root].details_loaded
			end, "refresh did not restore expanded details", 15000)
			local current = s.lazyvcs_repo_cache[f.root]
			old_summary()
			old_detail()
			assert(s.lazyvcs_repo_cache[f.root] == current, "obsolete callback replaced refreshed cache")
			assert(vim.deep_equal(expanded, s.lazyvcs_expanded), "refresh changed section expansion")
			select(s, function(node)
				return node.type == "file" and node.extra.relpath == "sample.txt"
			end)
		end, debug.traceback)
		model.load_repo_summary_async, model.load_repo_details_async = summary, detail
		assert(ok, err)
	end
	local function prompt(svn)
		local s, f = open(svn)
		s.lazyvcs_expanded[model.repo_changes_id(f.root)] = true
		native.render(s)
		select(s, function(node)
			return node.name == "Press <CR> to load changes"
		end)
		local loader, calls = model.load_repo_details_async, 0
		local deliver
		---@diagnostic disable-next-line: duplicate-set-field
		model.load_repo_details_async = function(repo, opts, run, done)
			calls = calls + 1
			return loader(repo, opts, run, function(value, err)
				deliver = function()
					done(value, err)
				end
			end)
		end
		local ok, err = xpcall(function()
			key(s, "<CR>")
			assert(calls == 1, "Enter on load prompt did not request details")
			assert(s.lazyvcs_expanded[model.repo_changes_id(f.root)], "load prompt collapsed repository")
			ops.open_repo(s, { type = "repo_changes", path = f.root, extra = { repo_root = f.root } }, function() end)
			assert(
				calls == 1 and s.lazyvcs_expanded[model.repo_changes_id(f.root)],
				"pending load was duplicated or collapsed"
			)
			ctx.wait_for(function()
				return deliver
			end, "details not delivered", 15000)
			deliver()
			assert(s.lazyvcs_repo_cache[f.root].details_loaded)
			local node = s.lazyvcs_line_nodes[1]
			s.lazyvcs_line_nodes[1] = { type = "message", name = "Informational", extra = { repo_root = f.root } }
			api.nvim_win_set_cursor(s.winid, { 1, 0 })
			key(s, "<CR>")
			s.lazyvcs_line_nodes[1] = node
			assert(calls == 1, "informational message requested details")
			-- Enter on the repository also loads missing details without collapsing it.
			s.lazyvcs_repo_cache[f.root].details_loaded = false
			deliver = nil
			ops.open_repo(s, { type = "repo_changes", path = f.root, extra = { repo_root = f.root } }, function() end)
			assert(
				calls == 2 and s.lazyvcs_expanded[model.repo_changes_id(f.root)],
				"repository Enter collapsed missing details"
			)
			ctx.wait_for(function()
				return deliver
			end, "second details not delivered", 15000)
			api.nvim_win_set_buf(s.winid, api.nvim_create_buf(false, true))
			assert(deliver)()
			assert(not s.lazyvcs_repo_cache[f.root].loading_details, "displaced sidebar retained pending details")
			deliver = nil
			native.open({ path = f.root })
			assert(calls == 3, "reopened sidebar did not resume displaced details")
			ctx.wait_for(function()
				return deliver
			end, "resumed details not delivered", 15000)
			assert(deliver)()
			assert(s.lazyvcs_repo_cache[f.root].details_loaded)
		end, debug.traceback)
		model.load_repo_details_async = loader
		assert(ok, err)
	end
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		local prefix = svn and "test_svn_source_control_" or "test_source_control_"
		cases[#cases + 1] = {
			prefix .. "refresh_restores_expanded_details",
			function()
				refresh(svn)
			end,
		}
		cases[#cases + 1] = {
			prefix .. "load_prompt_loads_without_collapsing",
			function()
				prompt(svn)
			end,
		}
	end
	for _, case in ipairs(cases) do
		local fn = case[2]
		case[2] = function()
			local ok, err = xpcall(fn, debug.traceback)
			pcall(native.close)
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	return cases
end
