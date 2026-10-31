return function(ctx)
	local api, h = vim.api, ctx.helpers
	local compare, actions, state = require("lazyvcs.compare"), require("lazyvcs.actions"), require("lazyvcs.state")
	local work, text = require("lazyvcs.diff_work"), require("lazyvcs.compare_text")
	local comparisons = {}
	local function guard(fn)
		return function()
			local start, options = work.start, vim.o.diffopt
			local ok, err = xpcall(fn, debug.traceback)
			work.start = start
			for _, s in ipairs(comparisons) do
				pcall(compare.close, s, false)
			end
			comparisons = {}
			h.cleanup()
			vim.o.diffopt = options
			assert(ok, err)
		end
	end
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			debounce_ms = 5,
		})
		vim.o.diffopt = "internal,filler,closeoff"
	end
	local function hold_first()
		local original = work.start
		local requests = {}
		---@diagnostic disable-next-line: duplicate-set-field
		work.start = function(left, right, kind, done, options)
			local request = { options = vim.deepcopy(options) }
			requests[#requests + 1] = request
			local first = #requests == 1
			return original(left, right, kind, function(...)
				if first then
					local args = { ... }
					request.release = function()
						done(unpack(args))
					end
				else
					done(...)
				end
			end, options)
		end
		return requests
	end
	local function held(requests)
		ctx.wait_for(function()
			return requests[1] and requests[1].release
		end, "real worker completion not held", 15000)
	end
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function options(value)
		vim.o.diffopt = value
		api.nvim_exec_autocmds("OptionSet", { pattern = "diffopt" })
	end
	local function comparison()
		setup()
		local f = h.make_git_fixture()
		h.write_file(f.file, "one\ntwo\nthree\nfour\nfive\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "worker comparison base" }, f.root)
		h.write_file(f.file, "one\n two\nthree\nfour\nfive\n")
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		comparisons[#comparisons + 1] = s
		ctx.wait_for(function()
			return s.worktree and s.navigation and #s.navigation.saved == 1
		end, "comparison absent", 15000)
		api.nvim_set_current_win(s.rightwin)
		return f, s
	end
	local function live()
		setup()
		local f = h.make_git_fixture()
		local rows = {}
		for i = 1, 4000 do
			rows[i] = "long source row " .. i
		end
		h.write_file(f.file, table.concat(rows, "\n") .. "\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = api.nvim_get_current_buf()
		actions.open()
		ctx.wait_for(function()
			local s = state.get(buf)
			return s and s.hunk_cache
		end, "live comparison absent", 15000)
		return f, buf, assert(state.get(buf))
	end
	local function edit_live(buf, requests)
		api.nvim_buf_set_lines(buf, 1999, 2000, false, { "changed row" })
		held(requests)
	end
	local cases = {
		{
			"test_core_compare_worker_profile_change_rejects_stale_public_hunks",
			guard(function()
				local _, s = comparison()
				local requests = hold_first()
				api.nvim_buf_set_lines(s.right, 1, 2, false, { "   two" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				held(requests)
				options("internal,filler,closeoff,iwhiteall")
				api.nvim_win_call(s.rightwin, vim.cmd.diffupdate)
				assert(#s.navigation.saved == 0 and api.nvim_win_call(s.rightwin, function()
					return vim.fn.diff_hlID(2, 1)
				end) == 0)
				requests[1].release()
				ctx.wait_for(function()
					return s.navigation and not s.navigation.pending and not s.worktree_diff.running
				end, "new option ranges never settled", 15000)
				api.nvim_win_set_cursor(s.rightwin, { 1, 0 })
				keys("]v")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 1, "next hunk used invisible old-option range")
				keys("[v")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 1, "previous hunk used invisible old-option range")
				assert(
					#s.navigation.saved == 0 and requests[#requests].options.ignore_whitespace,
					"worker did not use current diff options"
				)
				assert(api.nvim_buf_get_lines(s.right, 1, 2, false)[1] == "   two", "navigation changed editable text")
			end),
		},
		{
			"test_core_compare_worker_profile_rapid_flags_and_latest_edit",
			guard(function()
				local _, s = comparison()
				local requests = hold_first()
				api.nvim_buf_set_lines(s.right, 1, 2, false, { "   two" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				held(requests)
				options("internal,filler,closeoff,iwhiteall")
				api.nvim_buf_set_lines(s.right, 3, 4, false, { "latest real change" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				ctx.wait_for(function()
					return s.preview_result.right[4] == "latest real change"
				end, "latest edit did not queue", 15000)
				options("internal,filler,closeoff")
				requests[1].release()
				ctx.wait_for(function()
					return s.navigation and not s.navigation.pending and not s.worktree_diff.running
				end, "latest option/edit did not settle", 15000)
				api.nvim_win_set_cursor(s.rightwin, { 1, 0 })
				keys("]v")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 2, "latest edit kept ignored-whitespace coordinates")
				api.nvim_win_set_cursor(s.rightwin, { 5, 0 })
				keys("[v")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 4)
				assert(#s.navigation.saved == 2 and not requests[#requests].options.ignore_whitespace)
				local count = #requests
				vim.wait(100, function()
					return false
				end, 10)
				assert(#requests == count, "option correction kept launching workers")
			end),
		},
		{
			"test_core_compare_worker_profile_close_drops_old_completion",
			guard(function()
				local _, s = comparison()
				local requests = hold_first()
				api.nvim_buf_set_lines(s.right, 1, 2, false, { "   two" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				held(requests)
				options("internal,filler,closeoff,iwhiteall")
				vim.cmd.tabnew()
				local foreign = api.nvim_get_current_win()
				compare.close(s, false)
				requests[1].release()
				vim.wait(100, function()
					return false
				end, 10)
				assert(
					s.closed and #requests == 1 and api.nvim_get_current_win() == foreign,
					"closed comparison restarted or reclaimed focus"
				)
			end),
		},
	}
	for _, change in ipairs({ "save", "latest_save", "profile", "close", "rename" }) do
		cases[#cases + 1] = {
			"test_live_diff_worker_identity_" .. change,
			guard(function()
				local f, buf, s = live()
				local requests = hold_first()
				edit_live(buf, requests)
				if change == "save" or change == "latest_save" then
					if change == "latest_save" then
						api.nvim_buf_set_lines(buf, 2499, 2500, false, { "latest row" })
						ctx.wait_for(function()
							return s.current_text.lines[2500] == "latest row"
						end, "latest edit did not queue", 15000)
					end
					api.nvim_set_current_win(s.editable_win)
					vim.cmd.write()
				elseif change == "profile" then
					vim.bo[buf].bomb = true
					api.nvim_exec_autocmds("OptionSet", { pattern = "bomb" })
				elseif change == "close" then
					actions.close(s)
				else
					api.nvim_buf_set_name(buf, f.root .. "/renamed.txt")
					ctx.wait_for(function()
						return not state.get(buf)
					end, "renamed session did not close", 15000)
				end
				requests[1].release()
				if change == "close" or change == "rename" then
					vim.wait(100, function()
						return false
					end, 10)
					assert(not state.get(buf) and #requests == 1, "old worker resurrected a closed/renamed view")
					return
				end
				ctx.wait_for(function()
					return not s.hunks_pending
						and s.hunk_cache
						and vim.deep_equal(s.hunk_cache.identity, text.identity(buf))
				end, "identity change stranded live hunks", 15000)
				assert(#s.hunks == (change == "latest_save" and 2 or 1))
				if change == "profile" then
					assert(s.base_text.profile_key == assert(text.profile(buf)).key)
				end
				local count = #requests
				vim.wait(100, function()
					return false
				end, 10)
				assert(#requests == count and count <= 3, "identity correction kept launching workers")
			end),
		}
	end
	return cases
end
