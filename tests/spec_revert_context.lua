return function(ctx)
	local h, api = ctx.helpers, vim.api
	local backends, signs = require("lazyvcs.backends"), require("lazyvcs.signs")
	local function guarded(fn)
		return function()
			local load, versioned = backends.load_base_async, backends.is_versioned_async
			local ok, err = xpcall(fn, debug.traceback)
			backends.load_base_async, backends.is_versioned_async = load, versioned
			pcall(h.cleanup)
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	local function fixture(svn)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false },
		})
		local f = svn and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		-- Explicit refresh still uses the native signs state with rendering enabled.
		require("lazyvcs.config").get().signs.enabled = true
		return f, api.nvim_get_current_buf()
	end
	local function pending()
		local requests = {}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_base_async = function(path, cb)
			requests[#requests + 1] = { path = path, cb = cb }
			return { kill = function() end }
		end
		return requests
	end
	local function deliver(request, f, base)
		request.cb({
			root = f.root,
			relpath = vim.fn.fnamemodify(request.path, ":t"),
			base_label = "BASE",
			base_lines = base,
		})
	end
	local function wait_requests(requests, n)
		ctx.wait_for(function()
			return #requests >= n
		end, "base request did not start", 15000)
	end
	local function discard(svn)
		local f = fixture(svn)
		local done
		---@diagnostic disable-next-line: duplicate-set-field
		backends.is_versioned_async = function(_, cb)
			done = cb
			return {}
		end
		local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		local original = api.nvim_get_current_win()
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		done(true)
		assert(vim.bo.buftype ~= "nofile", "stale discard opened a confirmation over another file")
		assert(not owner.active, "cancelled discard retained ownership")
		assert(vim.fn.readfile(f.file1)[2] == "changed" and vim.fn.readfile(f.file2)[4] == "amber")
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		done(true)
		local popup = api.nvim_get_current_win()
		local title = api.nvim_win_get_config(popup).title
		assert(vim.inspect(title):find(f.file1, 1, true), "discard prompt must identify the exact target")
		local accept = vim.fn.maparg("1", "n", false, true).callback
		api.nvim_win_set_buf(original, vim.fn.bufnr(f.file2))
		accept()
		assert(not owner.active, "changed origin was accepted by confirmation")
		assert(vim.fn.readfile(f.file1)[2] == "changed", "confirmation restored a changed origin")
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		done(true)
		vim.fn.maparg("1", "n", false, true).callback()
		ctx.wait_for(function()
			return not owner.active
		end, "discard did not finish", 15000)
		assert(vim.fn.readfile(f.file1)[2] == "two", "unchanged origin did not restore")
		assert(vim.fn.readfile(f.file2)[4] == "amber", "discard changed the sibling")
	end
	local cases = {
		{
			"test_sign_pending_revert_preserves_invocation_context",
			guarded(function()
				for _, confirmation in ipairs({ false, true, "suppressed" }) do
					for _, change in ipairs({ "cursor", "window", "buffer", "rename", "edit", "eof", "unchanged" }) do
						local f, buf = fixture(false)
						require("lazyvcs.config").get().source_control.confirm_mutations = confirmation ~= false
						if confirmation == "suppressed" then
							require("lazyvcs.source_control.confirm").mutation({}, function() end)
							vim.fn.maparg("2", "n", false, true).callback()
						end
						api.nvim_buf_set_lines(buf, 0, -1, false, { "FIRST", "two", "three", "four", "LAST" })
						api.nvim_win_set_cursor(0, { 1, 0 })
						local requests = pending()
						signs.revert_hunk()
						wait_requests(requests, 1)
						if change == "cursor" then
							api.nvim_win_set_cursor(0, { 5, 0 })
						elseif change == "window" then
							vim.cmd("split")
						elseif change == "buffer" then
							vim.cmd.enew()
						elseif change == "rename" then
							api.nvim_buf_set_name(buf, f.root .. "/renamed.txt")
						elseif change == "edit" then
							api.nvim_buf_set_lines(buf, 1, 2, false, { "EDIT" })
						elseif change == "eof" then
							vim.bo[buf].endofline = false
						end
						deliver(requests[1], f, f.base1)
						if change == "unchanged" and confirmation == true then
							vim.fn.maparg("1", "n", false, true).callback()
						end
						assert(
							api.nvim_buf_get_lines(buf, 4, 5, false)[1] == "LAST",
							"pending revert followed the later cursor"
						)
						assert(
							api.nvim_buf_get_lines(buf, 0, 1, false)[1] == (change == "unchanged" and "one" or "FIRST"),
							"pending revert accepted changed " .. change
						)
						assert(vim.bo.buftype ~= "nofile", "stale hunk opened a prompt")
						h.cleanup()
						vim.cmd("silent! only!")
					end
				end
			end),
		},
		{
			"test_sign_rename_invalidates_cached_and_pending_base",
			guarded(function()
				for _, loaded in ipairs({ true, false }) do
					local f, buf = fixture(false)
					local requests = pending()
					signs.refresh(buf, true)
					wait_requests(requests, 1)
					if loaded then
						deliver(requests[1], f, f.base1)
					end
					api.nvim_buf_set_name(buf, f.file2)
					api.nvim_buf_set_lines(buf, 0, -1, false, { "EDIT", "blue", "green", "yellow", "orange" })
					signs.revert_hunk()
					wait_requests(requests, 2)
					deliver(requests[2], f, f.base2)
					if not loaded then
						deliver(requests[1], f, f.base1)
					end
					api.nvim_win_set_cursor(0, { 1, 0 })
					signs.revert_hunk()
					assert(
						api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "red",
						"renamed buffer accepted the previous entry's base"
					)
					h.cleanup()
				end
			end),
		},
		{ "test_revert_cancels_after_origin_context_changes", guarded(function()
			discard(false)
		end) },
		{ "test_svn_revert_cancels_after_origin_context_changes", guarded(function()
			discard(true)
		end) },
	}
	do
		local h, api = ctx.helpers, vim.api
		local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
		local backends, util = require("lazyvcs.backends"), require("lazyvcs.util")
		local function setup()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, debounce_ms = 0 })
			local f = h.make_git_transfer_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local task = actions.open({ silent = true })
			ctx.wait_for(function()
				return task.done
			end, "open")
			return f, assert(state.current())
		end
		cases[#cases + 1] = {
			"test_live_diff_invalid_base_recovers_specific_session",
			function()
				local f, s = setup()
				api.nvim_win_set_cursor(s.editable_win, { 2, 0 })
				api.nvim_buf_set_lines(s.editable_bufnr, 1, 2, false, { "LATER" })
				actions.revert_hunk()
				h.write_file(f.file1, "one\nINDEX\nthree\nfour\nfive\n")
				h.exec({ "git", "add", "alpha.txt" }, f.root)
				vim.fn.maparg("1", "n", false, true).callback()
				ctx.wait_for(function()
					return s.base_invalid or s.base_lines[2] == "INDEX"
				end, "validation")
				actions.next_hunk()
				ctx.wait_for(function()
					return not s.refresh_job
				end, "reload")
				assert(
					not s.base_invalid and s.base_lines[2] == "INDEX" and #s.hunks > 0,
					"base_invalid="
						.. tostring(s.base_invalid)
						.. " base="
						.. tostring(s.base_lines[2])
						.. " hunks="
						.. #s.hunks
				)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_failed_profile_warns_once_and_recovers",
			function()
				local _, s = setup()
				local original, load = util.notify, backends.load_base_async
				local warnings, loads = 0, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function()
					warnings = warnings + 1
				end
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(...)
					loads = loads + 1
					return load(...)
				end
				local ok, err = xpcall(function()
					vim.bo[s.editable_bufnr].binary = true
					for i = 1, 3 do
						api.nvim_buf_set_lines(s.editable_bufnr, 1, 2, false, { "EDIT " .. i })
						api.nvim_exec_autocmds("TextChanged", { buffer = s.editable_bufnr })
						ctx.wait_for(function()
							return loads >= 1
						end, "profile reload started")
						vim.wait(20, function()
							return false
						end)
						ctx.wait_for(function()
							return not s.refresh_job
						end, "profile reload")
					end
					assert(loads == 1 and warnings == 1, "loads=" .. loads .. " notifications=" .. warnings)
					vim.bo[s.editable_bufnr].binary = false
					actions.next_hunk()
					ctx.wait_for(function()
						return not s.refresh_job
					end, "profile recovery")
					assert(not s.base_invalid and #s.hunks > 0, "restored profile stayed invalid")
				end, debug.traceback)
				util.notify, backends.load_base_async = original, load
				assert(ok, err)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_rejects_unsupported_target_before_open_and_transfer",
			function()
				for _, input in ipairs({
					{ string.rep("x", 1024 * 1024 + 1), "Buffer exceeds the editable content limit" },
					{ "a\0b\n", "Buffer is oversized or contains unsupported text" },
					{ "\192\175\n", "Buffer is oversized or contains unsupported text" },
				}) do
					local value, expected_message = input[1], input[2]
					local f, s = setup()
					local path = f.root .. "/unsupported.txt"
					local out = assert(io.open(path, "wb"))
					out:write(value)
					out:close()
					local original = util.notify
					local messages = {}
					---@diagnostic disable-next-line: duplicate-set-field
					util.notify = function(msg)
						messages[#messages + 1] = msg
					end
					vim.cmd.edit(vim.fn.fnameescape(path))
					ctx.wait_for(function()
						return #messages > 0
					end, "transfer rejection")
					local buf = api.nvim_get_current_buf()
					local transfer_message = messages[1]
					messages = {}
					local transfer_clean = state.get(buf) == nil and state.get(s.editable_bufnr) == nil
					local task = actions.open({ silent = true })
					if task then
						ctx.wait_for(function()
							return task.done
						end, "fresh open")
					end
					local opened = state.get(buf)
					util.notify = original
					assert(
						transfer_message and transfer_message:find(expected_message, 1, true),
						tostring(transfer_message)
					)
					assert(
						transfer_clean and not opened,
						"transfer_clean="
							.. tostring(transfer_clean)
							.. " fresh_open="
							.. tostring(opened ~= nil)
							.. " message="
							.. tostring(messages[1])
					)
					h.cleanup()
				end
			end,
		}
		cases[#cases + 1] = {
			"test_revert_cursor_movement_does_not_cancel_discard",
			function()
				local f, s = setup()
				actions.close(s.editable_bufnr)
				local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
				ctx.wait_for(function()
					return vim.bo.buftype == "nofile"
				end, "prompt")
				local original = util.system_start
				local release
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[1] == "git" and args[2] == "ls-files" then
						return original(args, opts, function(...)
							local values = { ... }
							release = function()
								cb(unpack(values))
							end
						end)
					end
					return original(args, opts, cb)
				end
				local ok, err = xpcall(function()
					vim.fn.maparg("1", "n", false, true).callback()
					ctx.wait_for(function()
						return release ~= nil
					end, "discard ls-files")
					api.nvim_win_set_cursor(0, { 4, 0 })
					release()
					ctx.wait_for(function()
						return not owner.active
					end, "discard")
					assert(vim.fn.readfile(f.file1)[2] == "two", "disk line=" .. vim.fn.readfile(f.file1)[2])
				end, debug.traceback)
				util.system_start = original
				assert(ok, err)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_background_reload_targets_owner",
			function()
				local f, s = setup()
				vim.cmd("vsplit " .. vim.fn.fnameescape(f.file2))
				local task = actions.open({ silent = true })
				ctx.wait_for(function()
					return task.done
				end, "second open")
				local other = assert(state.current())
				assert(other ~= s)
				local original = backends.load_base_async
				local paths = {}
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(path)
					paths[#paths + 1] = path
					return { kill = function() end }
				end
				local ok, err = xpcall(function()
					vim.bo[s.editable_bufnr].fileformat = "dos"
					api.nvim_exec_autocmds("TextChanged", { buffer = s.editable_bufnr })
					ctx.wait_for(function()
						return #paths > 0
					end, "background reload")
					assert(paths[1] == f.file1, "background reloaded " .. paths[1])
				end, debug.traceback)
				backends.load_base_async = original
				assert(ok, err)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_reload_retries_failure_and_reverted_profile",
			function()
				local f, s = setup()
				local original = backends.load_base_async
				local requests = {}
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(_, cb)
					requests[#requests + 1] = cb
					return { kill = function() end }
				end
				local ok, err = xpcall(function()
					actions.refresh_current()
					requests[1](nil, "temporary timeout")
					actions.refresh_current()
					assert(#requests == 2, "failed reload retry requests=" .. #requests)
					requests[2]({
						base_bytes = "one\ntwo\nthree\nfour\nfive\n",
						root = f.root,
						relpath = "alpha.txt",
						base_label = "INDEX",
					})
					vim.bo[s.editable_bufnr].fileformat = "dos"
					actions.next_hunk()
					vim.bo[s.editable_bufnr].fileformat = "unix"
					requests[3]({ base_bytes = "unused", root = f.root, relpath = "alpha.txt", base_label = "INDEX" })
					actions.next_hunk()
					assert(#requests == 4, "reverted profile left invalid base; requests=" .. #requests)
				end, debug.traceback)
				backends.load_base_async = original
				assert(ok, err)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_late_validation_ignores_closed_session",
			function()
				local _, s = setup()
				api.nvim_win_set_cursor(s.editable_win, { 2, 0 })
				local original = backends.validate_editable_base_async
				local deliver
				---@diagnostic disable-next-line: duplicate-set-field
				backends.validate_editable_base_async = function(_, _, cb)
					deliver = cb
					return {}
				end
				local ok, err = xpcall(function()
					actions.revert_hunk()
					vim.fn.maparg("1", "n", false, true).callback()
					assert(deliver)
					actions.close(s.editable_bufnr)
					deliver(false, "late failure")
					assert(not s.base_invalid, "closed session mutated by late validation")
				end, debug.traceback)
				backends.validate_editable_base_async = original
				assert(ok, err)
			end,
		}
		cases[#cases + 1] = {
			"test_live_diff_transfer_handles_capture_failure_after_switch",
			function()
				local f, s = setup()
				local text = require("lazyvcs.compare_text")
				local capture, notify = text.capture, util.notify
				local warnings = 0
				---@diagnostic disable-next-line: duplicate-set-field
				text.capture = function(buf, limit)
					local live = state.get(buf)
					if live and live ~= s then
						return nil, "late unsupported text"
					end
					return capture(buf, limit)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(msg)
					if msg:find("late unsupported text", 1, true) then
						warnings = warnings + 1
					end
				end
				local ok, err = xpcall(function()
					vim.cmd.edit(vim.fn.fnameescape(f.file2))
					ctx.wait_for(function()
						return warnings > 0
					end, "late capture")
					local live = state.get(api.nvim_get_current_buf())
					assert(live and live.phase == "active" and #live.hunks == 0, "capture failure closed replacement")
					actions.next_hunk()
					actions.next_hunk()
					assert(warnings == 1, "late capture warnings=" .. warnings)
				end, debug.traceback)
				text.capture, util.notify = capture, notify
				assert(ok, err)
			end,
		}
	end
	return cases
end
