-- Async discovery regressions. Factories return { name, fn } cases; prefixes select test groups.
---@class LazyVcsSpecContext
---@field helpers table
---@field wait_for fun(predicate: function, msg: string?, timeout: number?)
---@field wait_for_discovery fun(state: table, msg: string?): table
---@field async_timeout_ms number

---@param ctx LazyVcsSpecContext
---@return table[] cases
return function(ctx)
	local helpers = ctx.helpers
	local wait_for = ctx.wait_for
	local wait_for_discovery = ctx.wait_for_discovery
	local ASYNC_TIMEOUT_MS = ctx.async_timeout_ms

	-- Fail if opening falls back to synchronous discovery on the UI thread.
	local function test_source_control_native_open_never_discovers_synchronously()
		require("lazyvcs").setup({
			source_control = { ui = "native", scan_depth = 1, remote_refresh = "manual" },
		})

		local fixture = helpers.make_git_fixture()
		local model = require("lazyvcs.source_control.model")
		local native = require("lazyvcs.source_control.native")

		-- Discovery has no synchronous runtime entry point to block the open path.
		assert(model.discover == nil, "model.discover must not be part of the runtime API")

		local ok, err = pcall(function()
			require("lazyvcs").source_control_open({ path = fixture.root })
			local state = assert(native._state(), "missing native state")

			-- Open returns before discovery finishes, and the first frame says so.
			local first_frame = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
			assert(
				state.lazyvcs_discovering == true,
				"sidebar open should leave discovery in flight, got discovering=" .. tostring(state.lazyvcs_discovering)
			)
			assert(
				first_frame:match("Discovering repositories"),
				"first frame should show a discovering state:\n" .. first_frame
			)

			-- Render while discovery is pending. Navigation would consume remote-refresh intent
			-- before repositories arrive.
			assert(
				state.lazyvcs_remote_refresh ~= nil,
				"remote-refresh intent must survive the pending-discovery render"
			)

			wait_for_discovery(state)
			assert(state.lazyvcs_repo_specs[1], "discovery should populate repo specs")
			assert(
				state.lazyvcs_remote_refresh == nil,
				"the discovery callback should navigate, consuming the remote-refresh intent"
			)
		end)

		assert(ok, err)
	end

	-- `R` used to re-hydrate without re-discovering, so a repository created
	-- after the sidebar opened stayed invisible until close and reopen -- the
	-- one thing refresh is expected to fix.
	local function test_source_control_native_refresh_rediscovers_new_repositories()
		require("lazyvcs").setup({
			source_control = { ui = "native", scan_depth = 2, remote_refresh = "manual" },
		})

		local function init_repo(dir)
			vim.fn.mkdir(dir, "p")
			helpers.exec({ "git", "init" }, dir)
			helpers.exec({ "git", "config", "user.name", "lazyvcs-test" }, dir)
			helpers.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, dir)
		end

		local workspace = helpers.tempdir()
		init_repo(workspace .. "/first")

		local native = require("lazyvcs.source_control.native")
		require("lazyvcs").source_control_open({ path = workspace })
		local state = wait_for_discovery(assert(native._state(), "missing native state"))
		assert(#state.lazyvcs_repo_specs == 1, "expected one repository before refresh")

		init_repo(workspace .. "/second")

		native.refresh(false)
		wait_for(function()
			return state.lazyvcs_discovering ~= true and #(state.lazyvcs_repo_specs or {}) == 2
		end, "refresh should rediscover a repository created after open", ASYNC_TIMEOUT_MS)
	end

	-- The loading list is empty; normalizing visibility against it would erase the restored
	-- layout.
	local function test_source_control_loading_render_preserves_repo_visibility()
		require("lazyvcs").setup({
			source_control = { ui = "native", scan_depth = 1, remote_refresh = "manual" },
		})

		local model = require("lazyvcs.source_control.model")
		local fixture = helpers.make_git_fixture()

		local state = {
			path = fixture.root,
			bufnr = nil,
			lazyvcs_discovering = true,
			lazyvcs_repo_specs = {},
			lazyvcs_repo_cache = {},
			lazyvcs_commit_drafts = {},
			-- What `persist.apply_state` restores before discovery runs.
			lazyvcs_focused_repo = fixture.root,
			lazyvcs_repo_visibility_overrides = { [fixture.root] = true },
		}

		model.collect(state, { root = fixture.root, scan_depth = 1 })

		assert(
			state.lazyvcs_focused_repo == fixture.root,
			"the loading render must not clear the restored focused repository"
		)
		assert(
			state.lazyvcs_repo_visibility_overrides[fixture.root] == true,
			"the loading render must not drop restored visibility overrides"
		)

		-- Once discovery has finished, normalization runs as usual.
		state.lazyvcs_discovering = false
		state.lazyvcs_repo_specs = helpers.discover(fixture.root, 1)
		model.collect(state, { root = fixture.root, scan_depth = 1 })
		assert(state.lazyvcs_repo_visibility ~= nil, "visibility should be normalized once discovery completes")
	end

	-- `util.trim` ended with an unparenthesised `gsub`, so it returned
	-- (string, count). Both backends' `get_root` return it directly, which
	-- bound the substitution count to callers' `err`.
	local function test_util_trim_returns_exactly_one_value()
		local util = require("lazyvcs.util")
		assert(select("#", util.trim("  padded  ")) == 1, "util.trim must return exactly one value")
		assert(util.trim("  padded  ") == "padded", "util.trim should strip surrounding whitespace")
		local value, extra = util.trim("root\n")
		assert(value == "root" and extra == nil, "util.trim must not leak a gsub count as a second return")
	end

	-- `util.truncate` sliced bytes, so a budget landing inside a multi-byte
	-- sequence produced invalid UTF-8; `blame.max_width` is a column budget and
	-- needs cell measurement, not byte counting.
	local function test_util_truncation_is_utf8_and_cell_safe()
		local util = require("lazyvcs.util")

		-- Inspect UTF-8 bytes directly. Neovim treats stray continuation bytes as codepoints,
		-- so strcharpart cannot detect a split sequence.
		local function is_valid_utf8(s)
			local index = 1
			while index <= #s do
				local byte = s:byte(index)
				local length
				if byte < 0x80 then
					length = 1
				elseif byte >= 0xc2 and byte <= 0xdf then
					length = 2
				elseif byte >= 0xe0 and byte <= 0xef then
					length = 3
				elseif byte >= 0xf0 and byte <= 0xf4 then
					length = 4
				else
					return false -- continuation byte or overlong lead in lead position
				end
				if index + length - 1 > #s then
					return false -- truncated sequence
				end
				for offset = 1, length - 1 do
					local continuation = s:byte(index + offset)
					if not continuation or continuation < 0x80 or continuation > 0xbf then
						return false
					end
				end
				index = index + length
			end
			return true
		end

		local split_sequence = ("é"):sub(1, 1)
		assert(not is_valid_utf8(split_sequence), "the validity helper must reject a split sequence")

		for _, sample in ipairs({ string.rep("é", 10), string.rep("漢", 8), string.rep("👍", 6) }) do
			for budget = 1, #sample do
				local clipped = util.truncate(sample, budget)
				assert(#clipped <= budget, "truncate must respect the byte budget")
				assert(is_valid_utf8(clipped), "truncate emitted invalid UTF-8 at budget " .. budget)
			end
		end

		-- Cell budgets, including the narrow ones where an ellipsis does not fit.
		local wide = string.rep("漢", 10)
		for budget = 1, 20 do
			local clipped = util.truncate_display(wide, budget)
			assert(
				vim.api.nvim_strwidth(clipped) <= budget,
				("truncate_display(%d) returned %d cells"):format(budget, vim.api.nvim_strwidth(clipped))
			)
			assert(is_valid_utf8(clipped), "truncate_display emitted invalid UTF-8 at budget " .. budget)
		end
		assert(util.truncate_display("short", 80) == "short", "truncate_display should pass short text through")
		assert(util.truncate_display("", 10) == "", "truncate_display should handle empty text")
		assert(util.truncate_display("anything", 0) == "", "truncate_display should handle a zero budget")
	end

	return {
		{
			"test_source_control_incomplete_discovery_keeps_repositories_and_saved_visibility",
			function()
				require("lazyvcs").setup({
					source_control = { scan_depth = 2, remote_refresh = "manual", width = 160, show_clean = true },
				})
				local workspace = helpers.tempdir()
				local denied = workspace .. "/denied"
				local hidden = denied .. "/hidden"
				for _, root in ipairs({ workspace .. "/first", workspace .. "/second", hidden }) do
					vim.fn.mkdir(root, "p")
					helpers.exec({ "git", "init" }, root)
				end
				vim.fn.mkdir(workspace .. "/other-denied", "p")
				local native = require("lazyvcs.source_control.native")
				require("lazyvcs").source_control_open({ path = workspace })
				local state = wait_for_discovery(assert(native._state()))
				state.lazyvcs_repo_visibility_overrides[hidden] = false
				local scan = vim.uv.fs_scandir
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_scandir = function(path, cb)
					if path == denied or path == workspace .. "/other-denied" then
						vim.schedule(function()
							cb("EACCES: permission denied", nil)
						end)
						return {}
					end
					return scan(path, cb)
				end
				local ok, err = xpcall(function()
					local function check()
						wait_for_discovery(state)
						assert(#state.lazyvcs_repo_specs == 2, "unreadable sibling hid readable repositories")
						assert(not state.lazyvcs_discovery_error, "unreadable sibling became a hard error")
						assert(#state.lazyvcs_discovery_incomplete == 2, "missing scan problems")
						assert(state.lazyvcs_repo_visibility_overrides[hidden] == false, "lost saved visibility")
						local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
						assert(text:find("Repositories (2)", 1, true), text)
						assert(text:find("first", 1, true) and text:find("second", 1, true), text)
						local _, count = text:gsub("Could not scan 2 directories", "")
						assert(count == 1, "expected one incomplete discovery notice:\n" .. text)
						local notice = assert(state.lazyvcs_line_nodes[2])
						assert(notice.extra.discovery_incomplete and notice.type == "message")
						assert(notice.name:find(denied .. ": EACCES", 1, true), notice.name)
						for _, repo in ipairs(state.lazyvcs_repo_specs) do
							assert(state.lazyvcs_repo_visibility[repo.root], "readable repository changes were hidden")
						end
					end
					native.refresh(false)
					check()
					native.close()
					require("lazyvcs").source_control_open({ path = workspace })
					state = assert(native._state())
					check()
				end, debug.traceback)
				vim.uv.fs_scandir = scan
				assert(ok, err)
				native.refresh(false)
				wait_for_discovery(state)
				assert(not state.lazyvcs_discovery_incomplete, "successful refresh retained incomplete notice")
				assert(#state.lazyvcs_repo_specs == 3)
				assert(state.lazyvcs_repo_visibility_overrides[hidden] == false)
			end,
		},
		{
			"test_source_control_discovery_reports_partial_results_and_root_errors",
			function()
				local workspace = helpers.tempdir()
				local denied = workspace .. "/denied"
				local repo = workspace .. "/repo"
				vim.fn.mkdir(denied, "p")
				vim.fn.mkdir(repo .. "/.git", "p")
				local scan = vim.uv.fs_scandir
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_scandir = function(path, cb)
					if path == denied then
						vim.schedule(function()
							cb("EACCES: permission denied", nil)
						end)
						return {}
					end
					return scan(path, cb)
				end
				local ok, err = xpcall(function()
					local model = require("lazyvcs.source_control.model")
					local function discover(root)
						local done, result
						model.discover_async(root, 1, function(repos, failure, problems)
							result = { repos = repos, failure = failure, problems = problems }
							done = true
						end, { entry_budget = 1 })
						wait_for(function()
							return done
						end, "discovery did not finish")
						return result
					end
					local partial = discover(workspace)
					assert(partial.repos and #partial.repos == 1, "partial results were discarded")
					assert(partial.repos[1].root == repo and not partial.failure)
					assert(partial.problems.incomplete[1] == denied .. ": EACCES: permission denied")
					local failed = discover(denied)
					assert(not failed.repos and not failed.problems, "root failure returned partial success")
					assert(failed.failure:find("Cannot scan " .. denied .. ": EACCES", 1, true))
				end, debug.traceback)
				vim.uv.fs_scandir = scan
				assert(ok, err)
			end,
		},
		{
			"test_source_control_failed_discovery_preserves_saved_visibility",
			function()
				require("lazyvcs").setup({ source_control = { scan_depth = 2, remote_refresh = "manual" } })
				local workspace = helpers.tempdir()
				local parent = workspace .. "/nested"
				local root = parent .. "/repo"
				vim.fn.mkdir(root, "p")
				helpers.exec({ "git", "init" }, root)
				local native = require("lazyvcs.source_control.native")
				require("lazyvcs").source_control_open({ path = workspace })
				local state = wait_for_discovery(assert(native._state()))
				state.lazyvcs_repo_visibility_overrides[root] = false
				local scan = vim.uv.fs_scandir
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_scandir = function(path, cb)
					if path == workspace then
						vim.schedule(function()
							cb("EACCES: permission denied", nil)
						end)
						return {}
					end
					return scan(path, cb)
				end
				local ok, err = xpcall(function()
					native.refresh(false)
					wait_for_discovery(state)
					assert(state.lazyvcs_discovery_error, "failed scan reported success")
					assert(
						state.lazyvcs_repo_visibility_overrides[root] == false,
						"failed scan erased saved visibility"
					)
					native.close()
					require("lazyvcs").source_control_open({ path = workspace })
					state = wait_for_discovery(assert(native._state()))
					assert(state.lazyvcs_repo_visibility_overrides[root] == false, "close persisted lost visibility")
				end, debug.traceback)
				vim.uv.fs_scandir = scan
				assert(ok, err)
				native.refresh(false)
				wait_for_discovery(state)
				assert(not state.lazyvcs_discovery_error)
				assert(state.lazyvcs_repo_visibility_overrides[root] == false)
				native.close()
				vim.fn.delete(parent, "rf")
				require("lazyvcs").source_control_open({ path = workspace })
				state = wait_for_discovery(assert(native._state()))
				assert(
					state.lazyvcs_repo_visibility_overrides[root] == nil,
					"successful scan did not prune removed repo"
				)
			end,
		},
		{
			"test_source_control_native_open_never_discovers_synchronously",
			test_source_control_native_open_never_discovers_synchronously,
		},
		{
			"test_source_control_native_refresh_rediscovers_new_repositories",
			test_source_control_native_refresh_rediscovers_new_repositories,
		},
		{
			"test_source_control_loading_render_preserves_repo_visibility",
			test_source_control_loading_render_preserves_repo_visibility,
		},
		{ "test_util_trim_returns_exactly_one_value", test_util_trim_returns_exactly_one_value },
		{ "test_util_truncation_is_utf8_and_cell_safe", test_util_truncation_is_utf8_and_cell_safe },
	}
end
