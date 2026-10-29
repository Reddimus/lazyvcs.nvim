local util = require("lazyvcs.util")
local buffers = require("lazyvcs.compare_buffers")
local M = {}
local namespaces = {}

local function protected(callback)
	return function(...)
		local ok, err = pcall(require("lazyvcs.absent_rail").internal, callback, ...)
		if not ok then
			util.notify("Could not restore comparison: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end
end

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
	-- Observe native jump keys without replacing user mappings. A picker that
	-- selects the same real buffer must still open it in the original editor.
	local jump_win
	local namespace = table.remove(namespaces) or vim.api.nvim_create_namespace("lazyvcs_compare_jumps_" .. s.buffer_id)
	vim.on_key(
		protected(function(key)
			if (key == "\15" or key == "\9") and vim.fn.mode() == "n" then
				local win = vim.api.nvim_get_current_win()
				if (win == s.leftwin or win == s.rightwin) and slots()[win] == vim.api.nvim_get_current_buf() then
					jump_win = win
					vim.schedule(protected(function()
						jump_win = nil
					end))
				end
			end
		end),
		namespace
	)
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = s.augroup,
		callback = protected(function(args)
			if not valid() or s.resizing or (s.swapping or 0) > 0 then
				return
			end
			local win = vim.api.nvim_get_current_win()
			if not slots()[win] or vim.api.nvim_win_get_buf(win) ~= args.buf then
				return
			end
			if slots()[win] == args.buf then
				actions.remember(s)
				views = {
					vim.api.nvim_win_call(s.leftwin, vim.fn.winsaveview),
					vim.api.nvim_win_call(s.rightwin, vim.fn.winsaveview),
					vim.api.nvim_win_call(s.sidewin, vim.fn.winsaveview),
				}
			end
			if util.get_win_option(win, "diff") then
				util.diff_off(win)
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = s.augroup,
		callback = protected(function(args)
			local win, buf = vim.api.nvim_get_current_win(), args.buf
			local owned = slots()[win]
			if not valid() or s.resizing or (s.swapping or 0) > 0 or not owned then
				return
			end
			if buf == owned then
				if pending[win] then
					pending[win] = nil
					vim.schedule(protected(function()
						if valid() then
							actions.relabel()
							actions.resume()
						end
					end))
				end
				return
			end
			local request = pending[win]
			if not request or request.buf ~= buf then
				request = {
					buf = buf,
					views = views,
					generation = s.generation,
					preview_generation = s.preview_generation,
					native_jump = jump_win == win,
				}
				pending[win] = request
			end
			local saved, generation, preview_generation = request.views, request.generation, request.preview_generation
			vim.schedule(protected(function()
				if pending[win] ~= request then
					return
				end
				if not valid() or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
					pending[win] = nil
					actions.resume()
					return
				end
				if s.worktree and (s.worktree.unloading or s.worktree.deleted) then
					pending[win] = nil
					return
				end
				local expected = slots()[win]
				if
					expected and (not vim.api.nvim_buf_is_valid(expected) or not vim.api.nvim_buf_is_loaded(expected))
				then
					pending[win] = nil
					require("lazyvcs.compare").close(s, false)
					actions.resume()
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
					local current = generation == s.generation and preview_generation == s.preview_generation
					local restored, status = pcall(actions.restore, win, current and saved or nil)
					if vim.api.nvim_buf_is_valid(buf) then
						vim.bo[buf].bufhidden = hidden
					end
					if not restored then
						error(status)
					end
					if status ~= "installed" or not focused then
						return
					end
					if
						s.worktree
						and buf == s.worktree.buf
						and buf == s.right
						and win ~= s.rightwin
						and vim.api.nvim_win_is_valid(s.rightwin)
					then
						vim.api.nvim_set_current_win(s.rightwin)
						vim.cmd("normal! m'")
						local line = math.min(position[1], vim.api.nvim_buf_line_count(buf))
						local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
						vim.api.nvim_win_set_cursor(s.rightwin, { line, math.min(position[2], #text) })
						vim.cmd("normal! zv")
						return
					end
					if buffers.is_presentation(buf) or buf == s.left or buf == s.right then
						return
					end
					if resource and resource.session and not resource.session.closed then
						return actions.snapshot(resource, position)
					end
					if request.native_jump and actions.jump(buf, position) then
						return
					end
					actions.edit(buf, position)
				end)
				actions.resume()
				if not ok then
					util.notify(
						"Could not open selected file: " .. tostring(err):gsub("[\r\n]+", " "),
						vim.log.levels.ERROR
					)
				end
			end))
		end),
	})
	return {
		busy = function()
			for win, buf in pairs(slots()) do
				local current = vim.api.nvim_win_get_buf(win)
				if (pending[win] and current == pending[win].buf) or current ~= buf then
					return true
				end
			end
			return false
		end,
		cancel = function()
			pending, views, jump_win = {}, nil, nil
		end,
		close = function()
			pending, views, jump_win = {}, nil, nil
			if namespace then
				vim.on_key(nil, namespace)
				namespaces[#namespaces + 1] = namespace
				namespace = nil
			end
		end,
	}
end

return M
