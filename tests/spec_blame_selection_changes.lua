return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, selection = t.api, require("lazyvcs.blame_selection")
	local function edits(svn)
		for _, event in ipairs({ "TextChanged", "TextChangedI" }) do
			local _, buf, win = t.open(svn)
			api.nvim_buf_set_lines(buf, 0, 1, false, { "already modified" })
			local callbacks, killed = {}, 0
			---@type table?
			local request
			t.patch(require("lazyvcs.backends.blame_selection"), "load", function(_, _, callback)
				callbacks[#callbacks + 1] = callback
				return {
					kill = function()
						killed = killed + 1
						assert(request and request.handle == nil, "cancellation retained a reentrant handle")
						api.nvim_exec_autocmds(event, { buffer = buf })
					end,
				}
			end)
			request = assert(selection.open(1, 1))
			api.nvim_exec_autocmds(event, { buffer = buf })
			assert(killed == 0 and request.handle, "unchanged event cancelled selection")
			api.nvim_buf_set_lines(buf, 0, 1, false, { "further edit" })
			api.nvim_exec_autocmds(event, { buffer = buf })
			assert(killed == 1 and request.handle == nil, "further unsaved edit did not cancel selection immediately")
			local diagnostic = { "Source changed while loading. Select the lines again." }
			assert(
				vim.deep_equal(api.nvim_buf_get_lines(request.buf, 0, -1, false), diagnostic),
				"source-changed diagnostic missing"
			)
			local entries = { { author = "stale author", revision = "abc", date = "2026-10-16" } }
			callbacks[1](entries)
			assert(
				not request.entries and vim.deep_equal(api.nvim_buf_get_lines(request.buf, 0, -1, false), diagnostic),
				"late completion installed stale attribution"
			)
			api.nvim_set_current_win(win)
			request = assert(selection.open(1, 1))
			callbacks[1](entries)
			assert(request.handle and not request.entries, "old completion changed newer report")
			callbacks[2](entries)
			local completed = api.nvim_buf_get_lines(request.buf, 0, -1, false)
			api.nvim_buf_set_lines(buf, 0, 1, false, { "edit after completion" })
			api.nvim_exec_autocmds(event, { buffer = buf })
			assert(
				killed == 1 and vim.deep_equal(api.nvim_buf_get_lines(request.buf, 0, -1, false), completed),
				"completed capture was changed"
			)
			api.nvim_win_close(request.win, true)
			api.nvim_set_current_win(win)
		end
	end
	return t.cases({
		{
			"test_blame_selection_cancels_further_unsaved_edits",
			function()
				edits(false)
			end,
		},
		{
			"test_svn_blame_selection_cancels_further_unsaved_edits",
			function()
				edits(true)
			end,
		},
	})
end
