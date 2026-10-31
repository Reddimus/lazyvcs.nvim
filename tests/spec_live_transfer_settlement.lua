return function(ctx)
	local h, api = ctx.helpers, vim.api
	local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
	local backends, util = require("lazyvcs.backends"), require("lazyvcs.util")
	local function guard(fn)
		return function()
			local start, load, base = util.system_start, backends.load_async, backends.load_base_async
			local hidden = vim.o.hidden
			local ok, err = xpcall(fn, debug.traceback)
			util.system_start, backends.load_async, backends.load_base_async = start, load, base
			vim.o.hidden = hidden
			h.cleanup()
			assert(ok, err)
		end
	end
	local function fixture()
		actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			source_control = { confirm_mutations = false },
			debounce_ms = 5,
		})
		vim.o.hidden = true
		local f = h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		local buf = api.nvim_get_current_buf()
		actions.open()
		ctx.wait_for(function()
			return state.get(buf) and #state.get(buf).hunks == 1
		end, "source view did not open", 15000)
		return f, buf, assert(state.get(buf))
	end
	local function fresh(s)
		ctx.wait_for(function()
			return s.base_lines[2] == "changed" and not s.base_invalid and not s.refresh_job and #s.hunks == 0
		end, "return retained the obsolete pre-stage base", 15000)
	end
	local function pending_target(f, s)
		local load, held = backends.load_async, nil
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(path, done, opts)
			return load(path, function(...)
				if path == f.file2 then
					local args = { ... }
					held = function()
						done(unpack(args))
					end
				else
					done(...)
				end
			end, opts)
		end
		api.nvim_set_current_win(s.editable_win)
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		local target = api.nvim_get_current_buf()
		ctx.wait_for(function()
			return held and s.phase == "loading"
		end, "target base did not remain pending", 15000)
		return function()
			assert(held)()
			assert(state.get(target) == nil, "late target callback resurrected the canceled transfer")
		end
	end
	local function stage(f, s)
		local start, complete = util.system_start, nil
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, done)
			if args[1] == "git" and args[2] == "add" then
				return start(args, opts, function(...)
					local result = { ... }
					complete = function()
						done(unpack(result))
					end
				end)
			end
			return start(args, opts, done)
		end
		local repo = { root = f.root, name = "fixture", vcs = "git", counts = { staged = 0, local_changes = 2 } }
		require("lazyvcs.source_control.ops").stage_file({
			path = f.root,
			lazyvcs_repo_cache = { [f.root] = repo },
			lazyvcs_commit_drafts = {},
			lazyvcs_render = function() end,
		}, {
			type = "file",
			path = f.file1,
			extra = { repo_root = f.root, relpath = "alpha.txt", section = "unstaged", status = " M" },
		})
		ctx.wait_for(function()
			return complete
		end, "real sidebar stage did not exit", 15000)
		util.system_start = start
		assert(s.base_changing, "sidebar stage did not invalidate the live base")
		assert(h.exec({ "git", "show", ":alpha.txt" }, f.root):find("changed", 1, true))
		return assert(complete)
	end
	local cases = {}
	for _, ordering in ipairs({ "before_leave", "while_away", "during_return", "after_return", "start_away", "overlap" }) do
		cases[#cases + 1] = {
			"test_live_diff_transfer_settlement_" .. ordering,
			guard(function()
				local f, buf, s = fixture()
				local complete, late
				local extra
				if ordering == "start_away" then
					late = pending_target(f, s)
					complete = stage(f, s)
				else
					complete = stage(f, s)
					if ordering == "before_leave" then
						complete()
						fresh(s)
					end
					late = pending_target(f, s)
				end
				if ordering == "overlap" then
					extra = actions.begin_base_change(f.root, { f.file1 })
				end
				if ordering == "during_return" then
					api.nvim_create_autocmd("BufEnter", { buffer = buf, once = true, callback = complete })
				elseif ordering ~= "before_leave" and ordering ~= "after_return" then
					complete()
				end
				local reload, release, loads = backends.load_base_async, nil, 0
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(path, done, opts)
					if path ~= f.file1 then
						return reload(path, done, opts)
					end
					loads = loads + 1
					return reload(path, function(...)
						local args = { ... }
						release = function()
							done(unpack(args))
						end
					end, opts)
				end
				-- Restoring a background pane must not move the user's current window.
				vim.cmd.tabnew()
				local focused = api.nvim_get_current_win()
				api.nvim_win_call(s.editable_win, function()
					vim.cmd.buffer(buf)
				end)
				ctx.wait_for(function()
					return s.phase == "active" and not state.peek_pending_transfer(s.editable_win)
				end, "source transfer did not cancel", 15000)
				assert(api.nvim_get_current_win() == focused, "return moved focus from another editor")
				if ordering == "after_return" or ordering == "overlap" then
					assert(
						s.base_changing and loads == 0,
						"return read an unsettled base: changing=" .. tostring(s.base_changing) .. ", reads=" .. loads
					)
					assert(#s.hunks == 0, "return resurrected obsolete hunks during a mutation")
					if extra then
						actions.finish_base_change(extra)
					else
						complete()
					end
				end
				if ordering ~= "before_leave" then
					ctx.wait_for(function()
						return release
					end, "settled source did not reload after returning", 15000)
					assert(#s.hunks == 0, "obsolete saved transfer hunks were exposed while reloading")
					assert(release)()
				end
				fresh(s)
				assert(loads == (ordering == "before_leave" and 0 or 1), "return duplicated the source refresh")
				late()
				assert(state.get(buf) == s and s.phase == "active" and s.base_lines[2] == "changed")
				assert(api.nvim_get_current_win() == focused, "base completion stole focus")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_transfer_settlement_keeps_deferred_refresh_completion",
		guard(function()
			local f, buf, s = fixture()
			h.exec({ "git", "add", "--", "alpha.txt" }, f.root)
			local load, held, loads = backends.load_base_async, nil, 0
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_base_async = function(path, done, opts)
				if path ~= f.file1 then
					return load(path, done, opts)
				end
				loads = loads + 1
				return load(path, function(...)
					local args = { ... }
					held = function()
						done(unpack(args))
					end
				end, opts)
			end
			actions.refresh_current()
			ctx.wait_for(function()
				return held
			end, "source refresh was not held", 15000)
			local late = pending_target(f, s)
			assert(held)()
			assert(state.peek_pending_transfer(s.editable_win).refresh_completion, "refresh was not deferred")
			vim.cmd.buffer(buf)
			fresh(s)
			assert(loads == 1, "return replaced a completed deferred base read")
			late()
		end),
	}
	for _, change in ipairs({ "edit", "profile" }) do
		cases[#cases + 1] = {
			"test_live_diff_transfer_settlement_retained_source_" .. change,
			guard(function()
				local f, buf, s = fixture()
				local late = pending_target(f, s)
				if change == "edit" then
					api.nvim_buf_set_lines(buf, 0, -1, false, f.base1)
				else
					vim.bo[buf].bomb = true
				end
				-- Let the source observation run while its session is loading B.
				vim.wait(30, function()
					return false
				end, 5)
				vim.cmd.buffer(buf)
				ctx.wait_for(function()
					return s.phase == "active" and not state.peek_pending_transfer(s.editable_win)
				end, "retained source did not return", 15000)
				ctx.wait_for(function()
					if change == "edit" then
						return #s.hunks == 0 and s.current_text.lines[2] == "two"
					end
					return s.base_text.profile_key == require("lazyvcs.compare_text").profile(buf).key
				end, "return kept an obsolete source " .. change, 15000)
				late()
				assert(state.get(buf) == s)
			end),
		}
	end
	return cases
end
