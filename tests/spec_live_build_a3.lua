return function(ctx)
	local api, h = vim.api, ctx.helpers
	local actions, state, backends = require("lazyvcs.actions"), require("lazyvcs.state"), require("lazyvcs.backends")
	local tasks, changes = {}, {}
	local function guard(fn)
		return function()
			local load, resolve = backends.load_async, backends.resolve_async
			local ok, err = xpcall(fn, debug.traceback)
			for _, task in ipairs(tasks) do
				task:kill()
			end
			tasks = {}
			backends.load_async, backends.resolve_async = load, resolve
			for _, change in ipairs(changes) do
				actions.finish_base_change(change)
			end
			changes = {}
			h.cleanup()
			assert(ok, err)
		end
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		return f, api.nvim_get_current_buf()
	end
	local function begin(root, paths)
		local change = actions.begin_base_change(root, paths)
		changes[#changes + 1] = change
		return change
	end
	local function open()
		local task = assert(actions.open())
		tasks[#tasks + 1] = task
		return task
	end
	local function intercept(path)
		local original = backends.load_async
		local reader = { calls = 0 }
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(file, done, opts)
			if file ~= path then
				return original(file, done, opts)
			end
			reader.calls = reader.calls + 1
			local first = reader.calls == 1
			return original(file, function(...)
				if first then
					local args = { ... }
					reader.held = function()
						done(unpack(args))
					end
				else
					done(...)
				end
			end, opts)
		end
		return reader
	end
	local function wait_held(reader)
		ctx.wait_for(function()
			return reader.held
		end, "base read not held", 15000)
	end
	local function stage(f, path, value)
		h.write_file(path, value .. "\n")
		h.exec({ "git", "add", path }, f.root)
	end
	local function fresh(buf, value)
		ctx.wait_for(function()
			local s = state.get(buf)
			return s and s.base_lines[1] == value
		end, "base did not resume fresh", 15000)
		return state.get(buf)
	end
	local function watch_resolve()
		local original = backends.resolve_async
		local marker = {}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.resolve_async = function(path, done, opts)
			return original(path, function(...)
				marker.done = true
				done(...)
			end, opts)
		end
		return marker
	end
	local cases = {
		{
			"test_live_diff_a3_base_read_retries_after_last_overlapping_mutation",
			guard(function()
				local f, buf = fixture()
				local reader = intercept(f.file)
				open()
				wait_held(reader)
				local one, two = begin(f.root, { f.file }), begin(f.root, { f.file })
				stage(f, f.file, "new staged base")
				reader.held()
				assert(not state.get(buf), "overlapped base was exposed during mutation")
				actions.finish_base_change(one)
				assert(reader.calls == 1, "read resumed before last matching mutation")
				actions.finish_base_change(two)
				fresh(buf, "new staged base")
				assert(reader.calls == 2, "stale read was not coalesced into one retry")
				local next_change = begin(f.root, { f.file })
				stage(f, f.file, "second staged base")
				actions.finish_base_change(next_change)
				fresh(buf, "second staged base")
			end),
		},
		{
			"test_live_diff_a3_base_read_waits_before_active_mutation_read",
			guard(function()
				local f, buf = fixture()
				local reader = intercept(f.file)
				local resolved = watch_resolve()
				local change = begin(f.root, { f.file })
				open()
				ctx.wait_for(function()
					return resolved.done
				end, "ownership resolution absent", 15000)
				assert(reader.calls == 0 and not state.get(buf), "active mutation started an initial base read")
				stage(f, f.file, "new staged base")
				actions.finish_base_change(change)
				wait_held(reader)
				reader.held()
				fresh(buf, "new staged base")
				assert(reader.calls == 1, "active mutation caused redundant base reads")
			end),
		},
		{
			"test_live_diff_a3_base_read_retries_transferred_target",
			guard(function()
				local f, source = fixture()
				local path = f.root .. "/target.txt"
				stage(f, path, "old target base")
				open()
				ctx.wait_for(function()
					return state.get(source)
				end, "source session absent", 15000)
				local reader = intercept(path)
				api.nvim_set_current_win(state.get(source).editable_win)
				vim.cmd.edit(vim.fn.fnameescape(path))
				local target = api.nvim_get_current_buf()
				wait_held(reader)
				local change = begin(f.root, { path })
				stage(f, path, "new target base")
				actions.finish_base_change(change)
				reader.held()
				fresh(target, "new target base")
				assert(not state.get(source) and reader.calls == 2, "transfer did not replace old base once")
			end),
		},
	}
	-- The nested-root control uses a real nested Git owner, not only lexical paths.
	cases[#cases + 1] = {
		"test_live_diff_a3_base_read_scopes_unrelated_paths_and_nested_roots",
		guard(function()
			local f, buf = fixture()
			local original = backends.load_async
			local reader = intercept(f.file)
			local change = begin(f.root, { f.root .. "/other.txt" })
			open()
			wait_held(reader)
			reader.held()
			fresh(buf, "one")
			actions.finish_base_change(change)
			assert(reader.calls == 1, "unrelated path restarted a read")
			actions.close(state.get(buf))
			backends.load_async = original
			local nested = f.root .. "/nested"
			h.exec({ "git", "clone", "--quiet", "--no-hardlinks", f.root, nested }, f.root)
			vim.cmd.edit(vim.fn.fnameescape(nested .. "/sample.txt"))
			buf = api.nvim_get_current_buf()
			reader = intercept(nested .. "/sample.txt")
			change = begin(f.root)
			open()
			wait_held(reader)
			reader.held()
			fresh(buf, "one")
			actions.finish_base_change(change)
			assert(reader.calls == 1, "parent repository mutation restarted nested owner read")
		end),
	}
	for _, intent in ipairs({ "close", "rename", "window", "window_close" }) do
		cases[#cases + 1] = {
			"test_live_diff_a3_base_read_waiter_cancel_" .. intent,
			guard(function()
				local f, buf = fixture()
				local reader = intercept(f.file)
				local resolved = watch_resolve()
				local change = begin(f.root, { f.file })
				if intent == "window_close" then
					vim.cmd.split()
				end
				local task = open()
				ctx.wait_for(function()
					return resolved.done
				end, "waiting request not resolved", 15000)
				assert(reader.calls == 0)
				if intent == "close" then
					actions.close(buf)
				elseif intent == "window_close" then
					api.nvim_win_close(0, true)
				elseif intent == "rename" then
					api.nvim_buf_set_name(buf, f.root .. "/renamed.txt")
				else
					vim.cmd.enew()
				end
				ctx.wait_for(function()
					return intent == "rename" and task.done or task.cancelled
				end, "obsolete waiting intent did not settle", 15000)
				actions.finish_base_change(change)
				vim.wait(50, function()
					return false
				end, 10)
				assert(not state.get(buf) and reader.calls == 0, "cancelled waiter resurrected a live view")
				for _, event in ipairs(api.nvim_get_autocmds({})) do
					assert(event.desc ~= "LazyVCS pending base read", "cancelled waiter retained an autocmd")
				end
			end),
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_a3_base_read_same_tick_rename_finish_keeps_multiple_waiters",
		guard(function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_transfer_fixture()
			local renamed, initial = f.root .. "/renamed.txt", f.root .. "/initial.txt"
			h.write_file(renamed, table.concat(vim.fn.readfile(f.file2), "\n") .. "\n")
			h.write_file(initial, "initial base\n")
			h.exec({ "git", "add", "renamed.txt", "initial.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "multiple pending targets" }, f.root)
			vim.cmd.tabnew()
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local source = api.nvim_get_current_buf()
			open()
			ctx.wait_for(function()
				return state.get(source)
			end, "source absent", 15000)
			local first = assert(state.get(source))
			local load, resolve = backends.load_async, backends.resolve_async
			local reads, resolved, during_finish, reentered = {}, 0, false, false
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_async = function(path, done, opts)
				reads[path] = (reads[path] or 0) + 1
				if during_finish and path == renamed then
					reentered = true
				end
				return load(path, done, opts)
			end
			---@diagnostic disable-next-line: duplicate-set-field
			backends.resolve_async = function(path, done, opts)
				return resolve(path, function(...)
					resolved = resolved + 1
					done(...)
				end, opts)
			end
			local change = begin(f.root)
			api.nvim_set_current_win(first.editable_win)
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local target = api.nvim_get_current_buf()
			vim.cmd.tabnew()
			vim.cmd.edit(vim.fn.fnameescape(initial))
			local other = api.nvim_get_current_buf()
			open()
			ctx.wait_for(function()
				return resolved >= 2
			end, "both pending owners did not resolve", 15000)
			assert(next(reads) == nil, "active mutation admitted a content read")
			-- Finish in this same Lua tick, before scheduled rename checks run.
			api.nvim_buf_set_name(target, renamed)
			during_finish = true
			actions.finish_base_change(change)
			during_finish = false
			ctx.wait_for(function()
				local a, b = state.get(target), state.get(other)
				return a and b and a.phase == "active" and b.phase == "active"
			end, "same-tick completion stranded a pending owner", 15000)
			assert(reentered, "fixture did not create a replacement request during finish")
			assert(
				reads[renamed] == 1 and reads[initial] == 1 and not reads[f.file2],
				"pending owners were not resumed exactly once"
			)
			assert(not state.peek_pending_transfer(first.editable_win), "renamed owner retained transfer state")
		end),
	}
	for _, svn in ipairs({ false, true }) do
		for _, change_kind in ipairs({ "profile", "rename" }) do
			for _, waiting in ipairs({ false, true }) do
				cases[#cases + 1] = {
					"test_live_diff_a3_base_read_context_"
						.. (svn and "svn_" or "git_")
						.. change_kind
						.. (waiting and "_waiting" or "_reading"),
					guard(function()
						require("lazyvcs").setup({
							use_gitsigns = false,
							signs = { enabled = false },
							blame = {
								persist = false,
							},
						})
						local f = svn and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
						local renamed = f.root .. "/renamed.txt"
						h.write_file(renamed, table.concat(vim.fn.readfile(f.file2), "\n") .. "\n")
						if svn then
							h.exec({ "svn", "add", renamed }, f.root)
							h.exec({ "svn", "commit", "-m", "rename destination" }, f.root)
						else
							h.exec({ "git", "add", "renamed.txt" }, f.root)
							h.exec({ "git", "commit", "-m", "rename destination" }, f.root)
						end
						vim.cmd.tabnew()
						vim.cmd.edit(vim.fn.fnameescape(f.file1))
						local source = api.nvim_get_current_buf()
						open()
						ctx.wait_for(function()
							return state.get(source)
						end, "source absent", 15000)
						local old = assert(state.get(source))
						local reader = intercept(f.file2)
						local mutation
						local resolved = watch_resolve()
						if waiting then
							mutation = begin(f.root, { f.file2, renamed })
						end
						api.nvim_set_current_win(old.editable_win)
						vim.cmd.edit(vim.fn.fnameescape(f.file2))
						local target = api.nvim_get_current_buf()
						if waiting then
							ctx.wait_for(function()
								return resolved.done
							end, "waiting transfer unresolved", 15000)
							assert(reader.calls == 0)
						else
							wait_held(reader)
						end
						if change_kind == "profile" then
							vim.bo[target].fileformat = "dos"
							api.nvim_exec_autocmds("OptionSet", { pattern = "fileformat" })
						else
							api.nvim_buf_set_name(target, renamed)
						end
						if not waiting then
							reader.held()
						end
						ctx.wait_for(function()
							local current = state.for_window(old.editable_win)
							local pending = state.peek_pending_transfer(old.editable_win)
							return current
								and (
									(current.phase ~= "loading" and current.phase ~= "leaving")
									or (
										change_kind == "rename"
										and pending
										and pending.target_path == renamed
										and pending.handle
										and pending.handle:is_active()
									)
								)
						end, "context change stranded pending transfer", 1000)
						if mutation then
							actions.finish_base_change(mutation)
						end
						local current = assert(state.for_window(old.editable_win))
						api.nvim_set_current_win(current.editable_win)
						actions.open()
						if waiting and change_kind == "profile" then
							wait_held(reader)
							reader.held()
						end
						ctx.wait_for(function()
							local live = state.get(target)
							return live and live.phase == "active"
						end, "same-target retry did not recover", 15000)
						assert(
							not state.peek_pending_transfer(current.editable_win),
							"recovery retained a pending transfer"
						)
					end),
				}
			end
		end
	end
	return cases
end
