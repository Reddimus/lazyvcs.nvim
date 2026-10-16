return function(ctx)
	local h, api = ctx.helpers, vim.api
	return {
		{
			"test_source_control_persistence_isolates_project_writers",
			function()
				local persist, json = require("lazyvcs.source_control.persist"), require("lazyvcs.json_file")
				local a, b = h.tempdir(), h.tempdir()
				persist.save(a, { changes_sort = "name" })
				local script = h.tempdir() .. "/writer.lua"
				local function child(code)
					h.write_file(
						script,
						"vim.opt.rtp:prepend("
							.. string.format("%q", vim.fn.getcwd())
							.. ")\n"
							.. code
							.. '\nvim.cmd("qa!")\n'
					)
					local result = vim.system(
						{ vim.v.progpath, "--headless", "-u", "NONE", "-l", script },
						{ text = true }
					)
						:wait()
					assert(result.code == 0, result.stderr)
				end
				child(
					'require("lazyvcs.source_control.persist").save('
						.. string.format("%q", b)
						.. ', { changes_view_mode = "tree" })'
				)
				persist.save(a, { changes_sort = "status" })
				child(
					'assert(require("lazyvcs.source_control.persist").load('
						.. string.format("%q", b)
						.. ').changes_view_mode == "tree", "project B preferences were erased by editor A")'
				)
				assert(persist.load(a).changes_sort == "status")
				local barrier = h.tempdir()
				local workers = {}
				local overlap_ok, overlap_err = xpcall(function()
					for index, root in ipairs({ a, b }) do
						local ready = barrier .. "/ready" .. index
						local writer = barrier .. "/writer" .. index .. ".lua"
						h.write_file(
							writer,
							string.format(
								[[
vim.opt.rtp:prepend(%q)
vim.fn.writefile({ "ready" }, %q)
assert(vim.wait(15000, function() return vim.uv.fs_stat(%q) ~= nil end, 10))
require("lazyvcs.source_control.persist").save(%q, { changes_sort = "path" })
vim.cmd("qa!")
]],
								vim.fn.getcwd(),
								ready,
								barrier .. "/go",
								root
							)
						)
						workers[#workers + 1] = vim.system(
							{ vim.v.progpath, "--headless", "-u", "NONE", "-l", writer },
							{ text = true }
						)
					end
					ctx.wait_for(function()
						return vim.uv.fs_stat(barrier .. "/ready1") and vim.uv.fs_stat(barrier .. "/ready2")
					end, "writers did not reach readiness barrier", 15000)
					h.write_file(barrier .. "/go", "go\n")
					for _, worker in ipairs(workers) do
						local result = worker:wait(20000)
						assert(result.code == 0, result.stderr)
					end
					child(
						'local p = require("lazyvcs.source_control.persist"); assert(p.load('
							.. string.format("%q", a)
							.. ').changes_sort == "path" and p.load('
							.. string.format("%q", b)
							.. ').changes_sort == "path", "overlapping saves lost a project")'
					)
				end, debug.traceback)
				for _, worker in ipairs(workers) do
					pcall(worker.kill, worker, 15)
					worker:wait()
				end
				if not overlap_ok then
					error(overlap_err, 0)
				end

				local path = vim.fn.stdpath("state") .. "/lazyvcs/source_control/" .. vim.fn.sha256(a) .. ".json"
				assert(json.read(path).root == a, "new preference file must identify its root")
				assert(json.write(path, { root = b, preferences = { show_clean = true } }))
				assert(persist.load(a).show_clean == nil, "mismatched root must be rejected")
				persist.save(a, { show_clean = false })
				assert(json.read(path).root == b, "mismatched root must not be overwritten")
			end,
		},
		{
			"test_source_control_persistence_recovers_unreadable_project_files",
			function()
				local persist, json = require("lazyvcs.source_control.persist"), require("lazyvcs.json_file")
				local root = h.tempdir()
				local path = vim.fn.stdpath("state") .. "/lazyvcs/source_control/" .. vim.fn.sha256(root) .. ".json"
				persist.save(root, { changes_sort = "path" })
				local failures = {}
				for _, case in ipairs({
					{ "corrupt", "{bad json" },
					{ "empty", "" },
					{ "unsupported schema", vim.json.encode({ version = 999, data = { root = root } }) },
					{ "missing root", vim.json.encode({ version = 1, data = {} }) },
					{ "nonstring root", vim.json.encode({ version = 1, data = { root = false } }) },
					{ "unreadable", vim.json.encode({ version = 1, data = { root = root } }) },
				}) do
					h.write_file(path, case[2])
					local original = vim.uv.fs_open
					local denied = false
					---@diagnostic disable-next-line: duplicate-set-field
					vim.uv.fs_open = function(file, flags, mode, ...)
						if case[1] == "unreadable" and file == path and flags == "r" then
							denied = true
							return nil, "EACCES: permission denied"
						end
						return original(file, flags, mode, ...)
					end
					local ok, err = pcall(persist.save, root, { changes_sort = "name" })
					vim.uv.fs_open = original
					assert(ok, err)
					assert(case[1] ~= "unreadable" or denied, "unreadable case did not deny the read")
					if persist.load(root).changes_sort ~= "name" or json.read(path).root ~= root then
						failures[#failures + 1] = case[1]
					end
				end
				assert(#failures == 0, "project saves blocked by: " .. table.concat(failures, ", "))
			end,
		},
		{
			"test_source_control_persistence_ignores_malformed_visibility",
			function()
				local persist, json = require("lazyvcs.source_control.persist"), require("lazyvcs.json_file")
				local root = h.make_git_fixture().root
				local legacy = vim.fn.stdpath("state") .. "/lazyvcs/source_control.json"
				local prefs = {
					visible_repos = true,
					hidden_repos = "bad",
					show_clean = "false",
					focused_repo = {},
					selection_mode = "bad",
					changes_sort = false,
					changes_view_mode = 4,
				}
				assert(json.write(legacy, { [root] = prefs }))
				local state = {}
				local ok, err = pcall(persist.apply_state, state, root)
				assert(ok, "malformed visibility must not throw: " .. tostring(err))
				assert(vim.deep_equal(state.lazyvcs_repo_visibility_overrides, {}))
				assert(state.lazyvcs_show_clean == nil and state.lazyvcs_focused_repo == nil)
				assert(
					state.lazyvcs_selection_mode == nil
						and state.lazyvcs_changes_sort == nil
						and state.lazyvcs_changes_view_mode == nil
				)
				local native = require("lazyvcs.source_control.native")
				local opened, open_err = pcall(function()
					require("lazyvcs").setup({
						use_gitsigns = false,
						signs = { enabled = false },
						blame = { persist = false },
						source_control = {
							remote_refresh = "manual",
							changes_sort = "path",
							selection_mode = "multiple",
							changes_view_mode = "list",
							show_clean = false,
						},
					})
					local sidebar = native.open({ path = root })
					assert(
						sidebar.lazyvcs_changes_sort == "path"
							and sidebar.lazyvcs_changes_view_mode == "list"
							and sidebar.lazyvcs_selection_mode == "multiple"
							and sidebar.lazyvcs_show_clean == false,
						"invalid scalar preferences must use configuration"
					)
				end)
				pcall(native.close)
				assert(opened, open_err)
				local legacy_bytes = vim.fn.readfile(legacy, "b")
				prefs.visible_repos = { root, true, 2, {} }
				prefs.hidden_repos = { root }
				prefs.show_clean = false
				persist.save(root, prefs)
				persist.apply_state(state, root)
				assert(state.lazyvcs_repo_visibility_overrides[root] == false and state.lazyvcs_show_clean == false)
				assert(
					vim.deep_equal(vim.fn.readfile(legacy, "b"), legacy_bytes),
					"migration must leave legacy bytes unchanged"
				)
				local another = h.tempdir()
				local unversioned = { [root] = prefs, [another] = { changes_sort = "status" } }
				h.write_file(legacy, vim.json.encode(unversioned))
				assert(persist.load(another).changes_sort == "status", "version-zero legacy state must load")
				persist.save(another, { changes_sort = "name" })
				assert(
					persist.load(another).changes_sort == "name" and json.read(legacy)[another].changes_sort == "status",
					"project file must take precedence without rewriting legacy state"
				)
			end,
		},

		{
			"test_core_json_write_returns_directory_error",
			function()
				local json = require("lazyvcs.json_file")
				local dir = h.tempdir()
				h.write_file(dir .. "/blocked", "file\n")
				local called, saved, err = pcall(json.write, dir .. "/blocked/state.json", {})
				assert(called, "directory creation must return an error instead of throwing: " .. tostring(saved))
				assert(not saved and type(err) == "string")
				assert(json.write(dir .. "/existing/state.json", { value = true }))
				assert(json.write(dir .. "/existing/state.json", { value = false }))
				assert(json.read(dir .. "/existing/state.json").value == false)
			end,
		},
		{
			"test_blame_toggle_survives_state_directory_failure",
			function()
				local store, util = require("lazyvcs.store"), require("lazyvcs.util")
				local old_notify = util.notify
				local warnings = {}
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					local dir = h.tempdir()
					h.write_file(dir .. "/blocked", "file\n")
					store._test_set_dir(dir .. "/blocked/state")
					---@diagnostic disable-next-line: duplicate-set-field
					util.notify = function(msg)
						warnings[#warnings + 1] = msg
					end
					require("lazyvcs").setup({
						use_gitsigns = false,
						signs = { enabled = false },
						blame = { persist = true },
					})
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local blame = require("lazyvcs.blame")
					blame.blame_clear()
					local called, result = pcall(blame.blame)
					assert(
						called and result,
						"blame enable must finish after persistence failure: " .. tostring(result)
					)
					ctx.wait_for(function()
						local state = blame._test_inline_state()
						return #api.nvim_buf_get_extmarks(0, state.namespace, 0, -1, {}) > 0
					end, "blame must render without a recovery event", 15000)
					assert(blame.blame())
					assert(#api.nvim_buf_get_extmarks(0, blame._test_inline_state().namespace, 0, -1, {}) == 0)
					assert(#warnings == 1, "persistence should warn once")
				end, debug.traceback)
				util.notify = old_notify
				store._test_set_dir(h.tempdir())
				if not ok then
					error(err, 0)
				end
			end,
		},
	}
end
