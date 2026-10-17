return function(ctx)
	local api, h = vim.api, ctx.helpers
	return {
		{
			"test_core_config_fractional_absolute_width_preserves_units",
			function()
				for _, width in ipairs({ 1.01, 1.5, 1.99, 40.9 }) do
					require("lazyvcs").setup({ base_window = { width = width }, signs = { enabled = false } })
					assert(
						require("lazyvcs.config").get().base_window.width == width,
						"absolute width lost its units: " .. width
					)
				end
			end,
		},
		{
			"test_live_diff_fractional_absolute_width_uses_columns",
			function()
				local columns = vim.o.columns
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local buf = api.nvim_get_current_buf()
					for _, pair in ipairs({
						{ 1.01, 30 },
						{ 1.5, 30 },
						{ 1.99, 30 },
						{ 1, 149 },
						{ 0.5, 89 },
						{ 2, 30 },
						{ 40.9, 40 },
					}) do
						vim.o.columns = 180
						vim.cmd("vsplit | only")
						require("lazyvcs").setup({
							use_gitsigns = false,
							signs = { enabled = false },
							base_window = { width = pair[1] },
						})
						require("lazyvcs").open()
						local state = require("lazyvcs.state")
						ctx.wait_for(function()
							return state.get(buf) ~= nil
						end, "width diff did not open", 15000)
						local s = assert(state.get(buf))
						for _, size in ipairs({ 180, 200, 180 }) do
							vim.o.columns = size
							vim.cmd("wincmd =")
							require("lazyvcs.layout").rebalance(s)
							local expected = size == 180 and pair[2]
								or math.max(
									30,
									math.min(size - 31, math.floor(pair[1] <= 1 and (size - 1) * pair[1] or pair[1]))
								)
							assert(
								api.nvim_win_get_width(s.base_win) == expected,
								"wrong base columns for width " .. pair[1] .. ": " .. api.nvim_win_get_width(s.base_win)
							)
							assert(
								api.nvim_win_get_width(s.editable_win) == size - 1 - expected,
								"wrong editable columns: "
									.. vim.inspect({
										size,
										api.nvim_win_get_width(s.base_win),
										api.nvim_win_get_width(s.editable_win),
									})
							)
						end
						require("lazyvcs").close()
					end
				end, debug.traceback)
				h.cleanup()
				vim.o.columns = columns
				assert(ok, err)
			end,
		},
	}
end
