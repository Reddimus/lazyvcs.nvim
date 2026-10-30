return function(ctx)
	local api = vim.api
	local function feed(keys)
		api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	end
	return {
		{
			"test_core_confirm_displays_complete_long_prompt",
			function()
				local confirm = require("lazyvcs.source_control.confirm")
				local prompt = "Discard "
					.. string.rep("same-prefix-", 10)
					.. "important"
					.. string.rep("-suffix", 20)
					.. "?"
				local result
				local popup = confirm.open({ prompt = prompt }, function(value)
					result = value
				end)
				local text = table.concat(api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
				local visible = text:gsub("\n", "")
				local complete = visible:find(prompt, 1, true)
				api.nvim_win_set_cursor(popup.winid, { 1, 0 })
				feed("<CR>")
				popup.close()
				assert(complete, "complete target prompt is absent from scrollable popup content")
				assert(result == "cancel", "prompt row selected a destructive action")
				popup = confirm.open({ prompt = prompt }, function(value)
					result = value
				end)
				feed("2")
				assert(result == "confirm_session", "numeric choices changed after adding prompt rows")
			end,
		},
		{
			"test_core_confirm_uses_highlighted_cursor_row",
			function()
				local confirm = require("lazyvcs.source_control.confirm")
				for _, case in ipairs({
					{ "G<CR>", "cancel" },
					{ "jG<CR>", "cancel" },
					{ "Gk<CR>", "confirm_session" },
					{ "Gggjj<CR>", "confirm" },
					{ "1", "confirm" },
					{ "2", "confirm_session" },
					{ "3", "cancel" },
				}) do
					local result, calls = nil, 0
					local popup = confirm.open({}, function(choice)
						result, calls = choice, calls + 1
					end)
					feed(case[1])
					popup.close()
					assert(result == case[2], case[1] .. " chose " .. tostring(result) .. " instead of " .. case[2])
					assert(calls == 1, "confirmation completed more than once")
				end
				local result
				local popup = confirm.open({}, function(choice)
					result = choice
				end)
				api.nvim_win_set_cursor(popup.winid, { api.nvim_buf_line_count(popup.bufnr), 0 })
				feed("<CR>")
				assert(result == "cancel", "mouse-style cursor selection must control Enter")

				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = ctx.helpers.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				vim.cmd("LazyVCS revert")
				ctx.wait_for(function()
					return vim.bo.buftype == "nofile"
				end, "revert confirmation did not open", 15000)
				feed("G<CR>")
				assert(
					vim.deep_equal(vim.fn.readfile(f.file), { "one", "changed", "three" }),
					"highlighted Cancel discarded saved work"
				)
			end,
		},
	}
end
