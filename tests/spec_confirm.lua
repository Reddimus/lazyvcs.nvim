return function(ctx)
	local api = vim.api
	local function feed(keys)
		api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	end
	return {
		{
			"test_core_confirm_uses_highlighted_cursor_row",
			function()
				local confirm = require("lazyvcs.source_control.confirm")
				for _, case in ipairs({
					{ "G<CR>", "cancel" },
					{ "jG<CR>", "cancel" },
					{ "Gk<CR>", "confirm_session" },
					{ "Ggg<CR>", "confirm" },
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
				api.nvim_win_set_cursor(popup.winid, { 3, 0 })
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
