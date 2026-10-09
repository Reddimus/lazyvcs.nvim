local util = require("lazyvcs.util")
local buffers = require("lazyvcs.compare_buffers")
local M = {}

-- File pickers finish setting their search position after BufEnter. Restore the
-- owned window on the next turn, then route only its latest file selection.
function M.setup(s, actions)
	local slots = function()
		return { [s.sidewin] = s.sidebar, [s.leftwin] = s.left, [s.rightwin] = s.right }
	end
	local function valid()
		return not s.closed
			and vim.api.nvim_tabpage_is_valid(s.tab)
			and vim.api.nvim_win_is_valid(s.sidewin)
			and vim.api.nvim_win_is_valid(s.leftwin)
			and vim.api.nvim_win_is_valid(s.rightwin)
	end
	local views, pending = nil, {}
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = s.augroup,
		callback = function(args)
			if not valid() or s.resizing or (s.swapping or 0) > 0 then
				return
			end
			local win = vim.api.nvim_get_current_win()
			if slots()[win] ~= args.buf then
				return
			end
			actions.remember(s)
			views = {
				vim.api.nvim_win_call(s.leftwin, vim.fn.winsaveview),
				vim.api.nvim_win_call(s.rightwin, vim.fn.winsaveview),
				vim.api.nvim_win_call(s.sidewin, vim.fn.winsaveview),
			}
		end,
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = s.augroup,
		callback = function(args)
			local win, buf = vim.api.nvim_get_current_win(), args.buf
			local owned = slots()[win]
			if not valid() or s.resizing or (s.swapping or 0) > 0 or not owned or buf == owned then
				return
			end
			local request = pending[win]
			if not request or request.buf ~= buf then
				request =
					{ buf = buf, views = views, generation = s.generation, preview_generation = s.preview_generation }
				pending[win] = request
			end
			local saved, generation, preview_generation = request.views, request.generation, request.preview_generation
			vim.schedule(function()
				if not valid() or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
					return
				end
				local focused = vim.api.nvim_get_current_win() == win
				-- Do not fight a picker using an unfocused owned window as its preview.
				if not focused and vim.api.nvim_get_current_tabpage() == s.tab then
					return
				end
				pending[win] = nil
				local position = vim.api.nvim_win_get_cursor(win)
				local resource = buffers.resource(buf)
				local ok, err = pcall(function()
					-- A picker may select an existing unsaved buffer with 'nohidden'.
					-- Keep it loaded while restoring the preview, without discarding it.
					local hidden = vim.bo[buf].bufhidden
					vim.bo[buf].bufhidden = "hide"
					s.swapping = (s.swapping or 0) + 1
					local restored, restore_error = pcall(vim.api.nvim_win_call, win, function()
						vim.cmd("keepjumps buffer " .. owned)
					end)
					s.swapping = s.swapping - 1
					if vim.api.nvim_buf_is_valid(buf) then
						vim.bo[buf].bufhidden = hidden
					end
					if not restored then
						error(restore_error)
					end
					local current = generation == s.generation and preview_generation == s.preview_generation
					actions.restore(current and saved or nil)
					if not focused or generation ~= s.generation or preview_generation ~= s.preview_generation then
						return
					end
					if buf == s.sidebar or buf == s.left or buf == s.right then
						return
					end
					if resource and resource.session and not resource.session.closed then
						return actions.snapshot(resource, position)
					end
					actions.edit(buf, position)
				end)
				if not ok then
					util.notify(
						"Could not open selected file: " .. tostring(err):gsub("[\r\n]+", " "),
						vim.log.levels.ERROR
					)
				end
			end)
		end,
	})
end

return M
