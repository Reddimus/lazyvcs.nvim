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
		return s and not s.closing and state.get(s.editable_bufnr) == s
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
	local function prepare(s)
		local p = record(s)
		if p.detached then
			return p
		end
		p.detached = true
		layout.remember_departed(s)
		s.phase = "leaving"
		p.view = vim.api.nvim_win_call(s.editable_win, vim.fn.winsaveview)
		require("lazyvcs.align").clear(s)
		layout.release_derived_diff(s)
		layout.reset_tab_diff(s.editable_win)
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
		if target == s.editable_bufnr then
			if not vim.api.nvim_buf_is_loaded(target) or s.editable_wiping then
				return lifecycle.close(s, { reset_tab_diff = true })
			end
			if s.source_detached then
				s.source_detached = nil
				lifecycle.attach_source(s)
			end
			if p then
				local view, detached = p.view, p.detached
				state.clear_pending_transfer(s.editable_win)
				s.phase = "active"
				if detached then
					if view then
						vim.api.nvim_win_call(s.editable_win, function()
							vim.fn.winrestview(view)
						end)
					end
					layout.rebalance(s)
					layout.refresh(s)
					assert(layout.bind_pair(s, s.editable_win), "could not restore diff pair")
					aerial.refetch_buffer(s.editable_bufnr)
				end
			end
			return
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
		local handle = lifecycle.build(target, function(replacement, err)
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
					local unsupported = not err
						or tostring(err):match("No Git or SVN working copy")
						or tostring(err):match("not tracked")
						or tostring(err):match("only opens on normal file buffers")
					lifecycle.close(s, { reset_tab_diff = true })
					if not unsupported then
						report(err)
					end
					return
				end
				p.phase, s.phase = "committing", "committing"
				replacement.editor_state = p.guards[target] or editor.guard_markdown_buffer(target, p.target_path)
				p.guards[target] = nil
				local ok, commit_err = pcall(function()
					lifecycle.commit(s, replacement)
					state.finish_pending_transfer(s.editable_win, p)
					p.phase = "closed"
					p.dispose()
					replacement.phase = "active"
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
		end)
		if valid() and p.phase == "loading" then
			p.handle = handle
		else
			kill(handle)
		end
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
				and (s.phase == "active" or s.phase == "loading")
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
