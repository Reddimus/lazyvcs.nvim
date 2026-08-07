-- Regression specs for asynchronous repository discovery and the string
-- helpers it leans on.
--
-- These live outside `tests/spec.lua` because LuaJIT caps a function at 200
-- local variables, and `spec.lua` declares every case as a top-level
-- `local function` -- it reached that ceiling exactly. New cases belong in a
-- module like this one: export a factory that takes the shared harness and
-- returns `{ name, fn }` pairs, and `spec.lua` appends them to `cases`. Names
-- still drive group selection through `group_for`, so keep the
-- `test_source_control_*` prefix for anything that must run in the
-- `source_control` group.
--
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

	-- The defect this pins: `native.M.open` used to render BEFORE starting
	-- discovery, so `model.collect`'s `state.lazyvcs_repo_specs or
	-- M.discover(...)` fallback ran the synchronous discoverer on the UI thread
	-- -- a recursive scandir walk plus blocking `git rev-parse` and `svn info`,
	-- 30s cap each -- and then `start_discovery`'s `lazyvcs_repo_specs ~= nil`
	-- guard made the whole async path unreachable. Stubbing `model.discover` to
	-- raise is what makes a regression fail loudly instead of merely getting
	-- slow again.
	local function test_source_control_native_open_never_discovers_synchronously()
		require("lazyvcs").setup({
			source_control = { ui = "native", scan_depth = 1, remote_refresh = "manual" },
		})

		local fixture = helpers.make_git_fixture()
		local model = require("lazyvcs.source_control.model")
		local native = require("lazyvcs.source_control.native")

		local original_discover = model.discover
		---@diagnostic disable-next-line: duplicate-set-field
		model.discover = function()
			error("synchronous model.discover must never run on the sidebar open path", 0)
		end

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

			-- The pending-discovery paint must go through `M.render`, not
			-- `M.navigate`. `navigate` nils `lazyvcs_remote_refresh` and starts
			-- hydration, so navigating against an empty spec list silently drops
			-- the on-open remote refresh. `false` is a legitimate value here, so
			-- this checks for `nil` specifically -- and it is exactly what a
			-- `start_discovery` that forgets to return `true` regresses.
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

		model.discover = original_discover
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

		local multibyte = string.rep("é", 10)
		for budget = 1, #multibyte do
			local clipped = util.truncate(multibyte, budget)
			assert(#clipped <= budget, "truncate must respect the byte budget")
			assert(
				clipped == vim.fn.strcharpart(clipped, 0, vim.fn.strchars(clipped)),
				"truncate must not split a UTF-8 sequence at budget " .. budget
			)
		end

		local wide = string.rep("漢", 10)
		assert(
			vim.api.nvim_strwidth(util.truncate_display(wide, 8)) <= 8,
			"truncate_display must respect a cell budget"
		)
		assert(util.truncate_display("short", 80) == "short", "truncate_display should pass short text through")
		assert(util.truncate_display("", 10) == "", "truncate_display should handle empty text")
		assert(util.truncate_display("anything", 0) == "", "truncate_display should handle a zero budget")
	end

	return {
		{
			"test_source_control_native_open_never_discovers_synchronously",
			test_source_control_native_open_never_discovers_synchronously,
		},
		{
			"test_source_control_native_refresh_rediscovers_new_repositories",
			test_source_control_native_refresh_rediscovers_new_repositories,
		},
		{ "test_util_trim_returns_exactly_one_value", test_util_trim_returns_exactly_one_value },
		{ "test_util_truncation_is_utf8_and_cell_safe", test_util_truncation_is_utf8_and_cell_safe },
	}
end
