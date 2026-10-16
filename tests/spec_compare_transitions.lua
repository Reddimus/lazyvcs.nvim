return function(ctx)
	local api, h = vim.api, ctx.helpers
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job
		end, "comparison did not load", 15000)
	end
	local function held_preview(s)
		local original, delivery = s.provider.preview, nil
		---@diagnostic disable-next-line: duplicate-set-field
		s.provider.preview = function(snapshot, item, callback)
			return original(snapshot, item, function(result, err)
				delivery = function()
					callback(result, err)
				end
			end)
		end
		api.nvim_set_current_win(s.sidewin)
		-- Refresh the file to force a preview rather than use the current pair.
		compare.refresh(s)
		ctx.wait_for(function()
			return delivery ~= nil
		end, "real Git preview did not complete", 15000)
		s.provider.preview = original
		assert(type(delivery) == "function")
		return delivery
	end
	local function guarded(fn)
		return function()
			local notify, show, hidden = util.notify, util.show_win_buffer, vim.o.hidden
			local provider = require("lazyvcs.backends.compare_git")
			local preview, errors = provider.preview, {}
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(text, level)
				if level == vim.log.levels.ERROR then
					errors[#errors + 1] = text
				end
			end
			local ok, err = xpcall(function()
				fn(errors)
			end, debug.traceback)
			provider.preview, util.show_win_buffer = preview, show
			pcall(compare.close)
			util.notify, vim.o.hidden = notify, hidden
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_compare_picker_preview_completion_routes_latest_selection",
			guarded(function(errors)
				for _, modified in ipairs({ false, true }) do
					local f = h.make_git_fixture()
					h.write_file(f.root .. "/picked.txt", "first\nsecond\nthird\nfourth\n")
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local origin = api.nvim_get_current_win()
					local picked = vim.fn.bufadd(f.root .. "/picked.txt")
					vim.fn.bufload(picked)
					if modified then
						api.nvim_buf_set_lines(picked, 0, 1, false, { "unsaved" })
						vim.bo[picked].bufhidden = "wipe"
					end
					local tick = api.nvim_buf_get_changedtick(picked)
					local s = assert(compare.open({ path = f.root, base = "HEAD" }))
					ready(s)
					local deliver = held_preview(s)
					vim.o.hidden = false
					api.nvim_set_current_win(s.rightwin)
					api.nvim_win_set_buf(s.rightwin, picked)
					api.nvim_win_set_cursor(s.rightwin, { 4, 2 })
					local ok = pcall(deliver)
					vim.wait(100)
					assert(ok, "preview completion escaped while routing a selection")
					assert(
						api.nvim_win_get_buf(origin) == picked,
						"picker selection was swallowed by preview completion"
					)
					assert(vim.deep_equal(api.nvim_win_get_cursor(origin), { 4, 2 }), "picker search position changed")
					assert(api.nvim_buf_get_changedtick(picked) == tick, "selected text changed")
					assert(vim.bo[picked].modified == modified)
					assert(vim.bo[picked].bufhidden == (modified and "wipe" or ""))
					assert(
						api.nvim_win_get_buf(s.leftwin) == s.left and api.nvim_win_get_buf(s.rightwin) == s.right,
						"displayed slots disagree"
					)
					assert(#errors == 0, table.concat(errors, "\n"))
					compare.close(s)
					vim.o.hidden = true
				end
			end),
		},
		{
			"test_core_compare_failed_pane_install_keeps_slots_consistent",
			guarded(function(errors)
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				local deliver = held_preview(s)
				local before = { s.left, s.right, s.mode, s.preview_result, s.shown_item }
				local show, failed = util.show_win_buffer, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.show_win_buffer = function(win, buf)
					if win == s.rightwin and not failed then
						failed = true
						error("forced second pane failure\nsecond line")
					end
					return show(win, buf)
				end
				local ok = pcall(deliver)
				util.show_win_buffer = show
				assert(ok, "pane install escaped instead of rolling back")
				assert(failed, "second replacement was not exercised")
				assert(s.left == before[1] and s.right == before[2], "failed install published new slots")
				assert(
					s.mode == before[3] and s.preview_result == before[4] and s.shown_item == before[5],
					"failed install published display state"
				)
				assert(
					api.nvim_win_get_buf(s.leftwin) == s.left and api.nvim_win_get_buf(s.rightwin) == s.right,
					"rollback did not restore both panes"
				)
				assert((s.swapping or 0) == 0, "transition counter leaked")
				assert(#errors == 1 and not errors[1]:find("\n", 1, true), "expected one single-line transition error")
			end),
		},
		{
			"test_core_compare_read_callback_reports_single_line_error",
			function()
				local common = require("lazyvcs.backends.comparison")
				local path = h.tempdir() .. "/callback.txt"
				h.write_file(path, "contents\n")
				local schedule, notify = vim.schedule, util.notify
				local escaped, messages, deliveries = {}, {}, 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.schedule = function(fn)
					schedule(function()
						local ok, err = pcall(fn)
						if not ok then
							escaped[#escaped + 1] = err
						end
					end)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(text)
					messages[#messages + 1] = text
				end
				local task = common.task(function() end)
				common.read_file(task, path, function()
					deliveries = deliveries + 1
					error("deliberate callback failure\nsecond line")
				end)
				vim.wait(2000, function()
					return deliveries > 0
				end, 10)
				vim.wait(20)
				vim.schedule, util.notify = schedule, notify
				assert(#escaped == 0, "filesystem callback escaped its scheduled boundary")
				assert(deliveries == 1, "callback delivered more than once")
				assert(#messages == 1 and not messages[1]:find("\n", 1, true), "expected one single-line read error")
				assert(not task:is_active(), "throwing callback left its task active")
			end,
		},
		{
			"test_svn_compare_closed_pane_rejects_ready_file_read",
			function()
				local f = h.make_svn_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@1" }))
				ready(s)
				api.nvim_set_current_win(s.sidewin)
				api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
				s.actions.preview()
				ready(s)
				local common = require("lazyvcs.backends.comparison")
				local schedule, read = vim.schedule, common.read_file
				local escaped, closed, invalidated = {}, false, false
				local epoch = s.pane_epoch or 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.schedule = function(fn)
					schedule(function()
						local ok, err = pcall(fn)
						if not ok then
							escaped[#escaped + 1] = err
						end
					end)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				common.read_file = function(task, path, callback)
					return read(task, path, function(data, err)
						if not closed then
							closed = true
							api.nvim_win_close(s.rightwin, true)
							invalidated = (s.pane_epoch or 0) > epoch
						end
						callback(data, err)
					end)
				end
				compare.refresh(s)
				vim.wait(15000, function()
					return s.closed
				end, 10)
				vim.wait(30)
				vim.schedule, common.read_file = schedule, read
				pcall(compare.close, s)
				assert(closed, "real SVN file read did not reach the close race")
				assert(invalidated, "pane close did not synchronously invalidate preview delivery")
				assert(s.closed, "closed pane left its session alive")
				assert(#escaped == 0, "closed-pane completion escaped: " .. vim.inspect(escaped))
			end,
		},
	}
end
