local state = require("lazyvcs.state")
local util = require("lazyvcs.util")
local M = {}
local generation = 0

local function kill(handle)
	if handle and type(handle.kill) == "function" then
		pcall(handle.kill, handle, 15)
	end
end

local function panes_owned(s, tab)
	return util.win_is_valid(s.editable_win)
		and util.win_is_valid(s.base_win)
		and vim.api.nvim_win_get_tabpage(s.editable_win) == tab
		and vim.api.nvim_win_get_tabpage(s.base_win) == tab
		and vim.api.nvim_win_get_buf(s.base_win) == s.base_bufnr
end

function M.new(lifecycle)
	local layout = require("lazyvcs.layout")
	local aerial = require("lazyvcs.integrations.aerial")
	local editor = require("lazyvcs.integrations.editor")
	local api = {}
	local function current(s)
		return s and not s.closing and state.owns(s)
	end
	local function report(err)
		util.notify(
			"lazyvcs: buffer transfer failed: " .. util.truncate(tostring(err):gsub("%s*\n%s*", " "), 200),
			vim.log.levels.ERROR
		)
	end
	local function guarded(s, fn)
		local ok, err = pcall(fn)
		if not ok then
			if current(s) then
				pcall(lifecycle.close, s, { reset_tab_diff = true })
			end
			report(err)
		end
	end
	local function record(s)
		local p = state.peek_pending_transfer(s.editable_win)
		if p and p.session ~= s then
			state.clear_pending_transfer(s.editable_win)
			p = nil
		end
		if p then
			return p
		end
		generation = generation + 1
		p = {
			session = s,
			session_id = s.id,
			generation = generation,
			phase = "leaving",
			tabpage = vim.api.nvim_win_get_tabpage(s.editable_win),
			editable_win = s.editable_win,
			editable_bufnr = s.editable_bufnr,
			guards = {},
		}
		p.dispose = function()
			local failure
			local function restore(fn, value)
				local ok, err = pcall(fn, value)
				if not ok then
					failure = failure or err
				end
			end
			local guards = p.guards
			p.guards = {}
			for _, snapshot in pairs(guards) do
				restore(editor.restore_buffer, snapshot)
			end
			if p.detached then
				local snapshot = p.aerial_state
				p.detached, p.aerial_state = false, nil
				restore(aerial.restore_buffer, snapshot)
				restore(aerial.resume_win, p.editable_win)
				if snapshot and snapshot.attached_backend then
					restore(aerial.refetch_buffer, snapshot.bufnr)
				end
			end
			if failure then
				error(failure)
			end
		end
		state.set_pending_transfer(s.editable_win, p)
		return p
	end
	-- The view to give back when the window returns to the file it left. Neovim
	-- puts the cursor back where the window left the file; a command that chose
	-- another position on return, such as :cnext or :edit +N, wins.
	local function restore_view(s, view)
		if view then
			vim.api.nvim_win_call(s.editable_win, function()
				local cursor = vim.api.nvim_win_get_cursor(0)
				if cursor[1] == view.lnum and cursor[2] == view.col then
					vim.fn.winrestview(view)
				end
			end)
		end
	end
	local function prepare(s)
		local p = record(s)
		if p.detached then
			-- A retry saved the view when it started; the window leaves the file now.
			if vim.api.nvim_win_get_buf(s.editable_win) == s.editable_bufnr then
				p.view = vim.api.nvim_win_call(s.editable_win, vim.fn.winsaveview)
			end
			return p
		end
		p.detached = true
		p.base_lines, p.base_text, p.base_identity, p.hunks = s.base_lines, s.base_text, s.base_identity, s.hunks
		p.presence, s.presence = s.presence, nil
		layout.remember_departed(s)
		s.phase = "leaving"
		-- BufWinLeave does not fire while another window shows the departing
		-- buffer, so this can run after the window has moved to the next file.
		-- Neovim restores the departing file's own view if the user returns.
		if vim.api.nvim_win_get_buf(s.editable_win) == s.editable_bufnr then
			p.view = vim.api.nvim_win_call(s.editable_win, vim.fn.winsaveview)
		end
		require("lazyvcs.align").clear(s)
		layout.release_derived_diff(s)
		layout.reset_tab_diff(s.editable_win)
		layout.present(s, { "Loading comparison..." })
		s.base_identity, s.base_text, s.hunks = nil, nil, nil
		p.aerial_state = aerial.disable_buffer(s.editable_bufnr, { detach = true })
		aerial.suspend_win(s.editable_win)
		return p
	end
	function api.reconcile(s)
		if not current(s) or s.phase == "saving" or s.phase == "committing" then
			return
		end
		if not panes_owned(s, s.tabpage) then
			return lifecycle.close(s, { reset_tab_diff = true })
		end
		local target = vim.api.nvim_win_get_buf(s.editable_win)
		if s.readonly_comparison then
			if s.source_detached or target ~= s.editable_bufnr then
				return lifecycle.close(s, { reset_tab_diff = true })
			end
			return
		end
		local p = state.peek_pending_transfer(s.editable_win)
		if s.paused and target == s.editable_bufnr and util.buf_path(target) == s.source_path and not s.pause_retry then
			-- Returning before the next file loads cancels that transfer. A transfer
			-- that targets the paused file itself is a retry; let it finish.
			if p and p.target_bufnr ~= target then
				local view, detached = p.view, p.detached
				state.clear_pending_transfer(s.editable_win)
				s.phase = "paused"
				if detached then
					layout.present(s, s.base_lines, "")
					restore_view(s, view)
				end
				require("lazyvcs.window_controls").sync()
			end
			return
		end
		s.pause_retry = nil
		if target == s.editable_bufnr and not s.paused then
			if not vim.api.nvim_buf_is_loaded(target) or s.editable_wiping then
				return lifecycle.close(s, { reset_tab_diff = true })
			end
			if s.source_detached then
				s.source_detached = nil
				lifecycle.attach_source(s)
			end
			if p then
				local view, detached = p.view, p.detached
				s.base_lines, s.base_text, s.base_identity = p.base_lines, p.base_text, p.base_identity
				s.hunks = s.base_invalid and {} or p.hunks
				s.presence = p.presence
				state.clear_pending_transfer(s.editable_win)
				s.phase = "active"
				if detached then
					layout.present(s, s.base_lines or {}, vim.bo[s.editable_bufnr].filetype)
					restore_view(s, view)
					layout.rebalance(s)
					layout.refresh(s)
					assert(layout.bind_pair(s, s.editable_win), "could not restore diff pair")
					aerial.refetch_buffer(s.editable_bufnr)
				end
				if p.refresh_completion then
					p.refresh_completion()
				end
				-- Retained sources can change while their refreshes are suspended.
				lifecycle.refresh(s)
				-- Leaving installed close-only controls; restore the hunk maps.
				require("lazyvcs.window_controls").sync()
			end
			return
		end
		if not util.is_real_file_buffer(target) then
			return lifecycle.close(s, { reset_tab_diff = true })
		end
		p = prepare(s)
		if p.phase == "loading" and p.target_bufnr == target and p.target_path == util.buf_path(target) then
			return
		end
		generation = generation + 1
		p.generation = generation
		local stale_handle = p.handle
		p.handle = nil
		kill(stale_handle)
		for buf, snapshot in pairs(p.guards) do
			if buf ~= target then
				editor.restore_buffer(snapshot)
				p.guards[buf] = nil
			end
		end
		local request_generation = p.generation
		p.target_bufnr, p.target_path, p.phase = target, util.buf_path(target), "loading"
		s.phase = "loading"
		layout.reset_tab_diff(s.editable_win)
		layout.release_buffer_diff(s, s.editable_bufnr)
		local function valid()
			return current(s)
				and s.id == p.session_id
				and state.peek_pending_transfer(s.editable_win) == p
				and not p.cancelled
				and p.generation == request_generation
		end
		local handle = lifecycle.build(target, function(replacement, err, rejection)
			guarded(s, function()
				if not valid() then
					return
				end
				p.handle = nil
				if not panes_owned(s, p.tabpage) then
					return lifecycle.close(s, { reset_tab_diff = true })
				end
				if vim.api.nvim_win_get_buf(s.editable_win) ~= target or util.buf_path(target) ~= p.target_path then
					return api.reconcile(s)
				end
				if not replacement or state.get(target) then
					local conflict = state.get(target) ~= nil
					local expected = conflict or (rejection and rejection.code ~= nil)
					local reason = conflict and "This buffer already has another live diff owner." or err
					lifecycle.pause(s, target, p.target_path, reason)
					state.finish_pending_transfer(s.editable_win, p)
					p.phase = "closed"
					p.dispose()
					if not expected and err then
						report(err)
					end
					return
				end
				p.phase, s.phase = "committing", "committing"
				replacement.editor_state = p.guards[target] or editor.guard_markdown_buffer(target, p.target_path)
				if editor.refresh_guard then
					editor.refresh_guard(replacement.editor_state)
				end
				p.guards[target] = nil
				local ok, commit_err = pcall(function()
					lifecycle.commit(s, replacement)
					state.finish_pending_transfer(s.editable_win, p)
					p.phase = "closed"
					p.dispose()
					replacement.phase = "active"
					require("lazyvcs.window_controls").sync()
					layout.rebalance(replacement)
					assert(layout.bind_pair(replacement, replacement.editable_win), "could not bind replacement")
					aerial.refetch_buffer(target)
				end)
				if not ok then
					editor.restore_buffer(replacement.editor_state)
					replacement.editor_state = nil
					if state.get(target) == replacement then
						lifecycle.close(replacement, { reset_tab_diff = true })
					end
					error(commit_err)
				end
			end)
		end, s.editable_win)
		if valid() and p.phase == "loading" then
			p.handle = handle
		else
			kill(handle)
		end
	end
	function api.retry(s)
		if not current(s) then
			return
		end
		local target = util.win_is_valid(s.editable_win) and vim.api.nvim_win_get_buf(s.editable_win)
			or s.editable_bufnr
		local path = util.buf_path(target)
		if path then
			require("lazyvcs.backends").invalidate(path)
		end
		s.pause_retry = true
		api.reconcile_now(s)
	end
	function api.reconcile_now(s)
		guarded(s, function()
			api.reconcile(s)
		end)
	end
	function api.detached(s)
		s.source_detached = true
		api.schedule(s)
	end
	function api.schedule(s)
		if not current(s) or s.reconcile_pending then
			return
		end
		s.reconcile_pending = true
		local id = s.id
		vim.schedule(function()
			s.reconcile_pending = false
			guarded(s, function()
				if s.id == id then
					api.reconcile(s)
				end
			end)
		end)
	end
	function api.leave(s)
		guarded(s, function()
			if
				current(s)
				and (s.phase == "active" or s.phase == "loading" or s.phase == "paused")
				and vim.api.nvim_get_current_win() == s.editable_win
				and vim.api.nvim_win_get_buf(s.editable_win) == s.editable_bufnr
			then
				prepare(s)
				api.schedule(s)
			end
		end)
	end
	function api.guard(s, bufnr, path)
		guarded(s, function()
			if
				not current(s)
				or s.readonly_comparison
				or s.phase == "committing"
				or s.phase == "saving"
				or bufnr == s.editable_bufnr
				or bufnr == s.base_bufnr
			then
				return
			end
			local p = record(s)
			if not p.guards[bufnr] then
				p.guards[bufnr] = editor.guard_markdown_buffer(bufnr, path)
			end
			api.schedule(s)
		end)
	end
	return api
end
return M
