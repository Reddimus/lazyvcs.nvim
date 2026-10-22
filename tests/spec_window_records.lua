-- Check the window record model against the options Neovim actually copies.
return function()
	local api, util = vim.api, require("lazyvcs.util")
	local records = require("lazyvcs.window_records")
	return {
		{
			"test_core_window_records_predict_neovim_option_copies",
			function()
				records.setup()
				local watched, expected, mismatches, kinds = {}, {}, {}, {}
				local remove = records.on_enter(function(win, buf, _, kind, from)
					if watched[buf] then
						expected[win] = { kind = kind, from = from }
					end
				end)
				-- Each window labels the options it holds for a buffer with its own id,
				-- so a copied value names the window it came from.
				local group = api.nvim_create_augroup("lazyvcs_test_window_records", { clear = true })
				api.nvim_create_autocmd("BufWinEnter", {
					group = group,
					callback = function(args)
						local win = api.nvim_get_current_win()
						local want = expected[win]
						expected[win] = nil
						if watched[args.buf] and want then
							kinds[want.kind] = true
							local value = util.get_win_option(win, "colorcolumn")
							local wanted = want.kind == "none" and ""
								or tostring(want.kind == "own" and win or want.from)
							if value ~= wanted then
								mismatches[#mismatches + 1] = string.format(
									"win %d buf %d: predicted %s from %s (%s), Neovim gave %s",
									win,
									args.buf,
									want.kind,
									tostring(want.from),
									wanted,
									value
								)
							end
						end
						util.set_win_option(win, "colorcolumn", tostring(win))
					end,
				})
				local ok, err = xpcall(function()
					vim.cmd("tabnew")
					local a, b = api.nvim_create_buf(true, false), api.nvim_create_buf(true, false)
					watched[a], watched[b] = true, true
					local function label()
						util.set_win_option(0, "colorcolumn", tostring(api.nvim_get_current_win()))
					end
					local first = api.nvim_get_current_win()
					vim.cmd.buffer(a) -- no record yet
					vim.cmd("split") -- copies options without entering a buffer
					label()
					-- Let the split finish its command; a later buffer change saves a record.
					vim.wait(20, function()
						return false
					end)
					local second = api.nvim_get_current_win()
					vim.cmd.buffer(b) -- second saves its record for a
					vim.cmd("new") -- :new saves no record for the buffer it split from
					vim.cmd.buffer(b)
					vim.cmd.buffer(a) -- copies second's saved record
					vim.cmd.buffer(b)
					vim.cmd.buffer(a) -- own record
					local third = api.nvim_get_current_win()
					api.nvim_set_current_win(second)
					vim.cmd.buffer(a) -- own record; second shows a again
					vim.cmd("new")
					vim.cmd.buffer(a) -- copies second's live options
					vim.cmd.close()
					api.nvim_set_current_win(third)
					vim.cmd.close() -- a closed window keeps one record
					vim.cmd("new")
					vim.cmd.buffer(a)
					vim.cmd("tabnew")
					vim.cmd.buffer(a)
					vim.cmd("diffthis")
					vim.cmd.buffer(b) -- a diff record from another tab is skipped
					vim.cmd("diffoff!")
					vim.cmd("tabprevious")
					vim.cmd("new")
					vim.cmd.buffer(a)
					api.nvim_set_current_win(first)
					vim.cmd.buffer(b)
					vim.cmd.buffer(a)
				end, debug.traceback)
				remove()
				api.nvim_del_augroup_by_id(group)
				vim.cmd("silent! tabonly")
				vim.cmd("silent! only")
				assert(ok, err)
				assert(#mismatches == 0, table.concat(mismatches, "\n"))
				for _, kind in ipairs({ "own", "saved", "live", "none" }) do
					assert(kinds[kind], "scenario did not exercise " .. kind .. " records")
				end
			end,
		},
	}
end
