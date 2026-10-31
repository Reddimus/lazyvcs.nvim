return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch fill precondition did not settle", 15000)
	end
	for _, mode in ipairs({ "noop", "close", "wipe" }) do
		local close, wipe = mode == "close", mode == "wipe"
		cases[#cases + 1] = {
			"test_patch_fill_precondition_" .. (wipe and "on_cancel_wipe" or "composed_cancel_" .. mode),
			function()
				local handles, errors, notify = {}, {}, vim.notify
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					end
				end
				local function open(path)
					local task = require("lazyvcs").patch({ path = path })
					handles[#handles + 1] = task
					return task
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local original = api.nvim_get_current_buf()
					api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved original bytes" })
					local first = open(f.root)
					local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
					assert(first:is_active(), "initial public request must still be active")
					local fired, replacement = 0, nil
					if wipe then
						first:on_cancel(function()
							fired = fired + 1
							replacement = api.nvim_create_buf(false, true)
							api.nvim_buf_set_lines(replacement, 0, -1, false, { "replacement window bytes" })
							-- The patch's native bufhidden=wipe removes its old buffer.
							api.nvim_win_set_buf(win, replacement)
						end)
					else
						first:add({
							kill = function()
								fired = fired + 1
								if close then
									api.nvim_win_close(win, true)
								end
							end,
						})
					end
					local second = open(f.root)
					assert(first.cancelled and fired == 1, "real cancellation hook did not run once")
					if close or wipe then
						assert(not api.nvim_buf_is_valid(buf))
						if close then
							assert(not api.nvim_win_is_valid(win))
						else
							assert(
								api.nvim_win_is_valid(win) and replacement and api.nvim_win_get_buf(win) == replacement,
								"on_cancel wipe did not retain/rebind its window"
							)
						end
						assert(
							second.cancelled and not second:is_active(),
							"retired reload did not return a cancelled handle"
						)
						local fresh = open(f.root)
						local freshbuf = api.nvim_get_current_buf()
						wait(function()
							return fresh.done
						end)
						assert(
							not fresh.cancelled
								and not vim.bo[freshbuf].modifiable
								and text(freshbuf):find("+changed", 1, true)
						)
					else
						wait(function()
							return second.done
						end)
						assert(
							not second.cancelled and api.nvim_get_current_buf() == buf and not vim.bo[buf].modifiable
						)
						assert(text(buf):find("+changed", 1, true))
					end
					if wipe then
						assert(
							replacement
								and api.nvim_buf_is_valid(replacement)
								and text(replacement) == "replacement window bytes"
						)
					end
					assert(fired == 1, "later reload reran a cancellation hook")
					assert(
						api.nvim_buf_is_valid(original)
							and vim.bo[original].modified
							and text(original) == "unsaved original bytes"
					)
				end, debug.traceback)
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				vim.notify = notify
				assert(ok, err)
				assert(#errors == 0, table.concat(errors, "; "))
			end,
		}
	end
	return cases
end
