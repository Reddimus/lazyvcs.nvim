local M = {}

local wrapped = false
local original_is_ignored_win
local suspended_wins = {}

local function get_aerial()
	local ok, aerial = pcall(require, "aerial")
	if ok then
		return aerial
	end
end

local function get_aerial_util()
	local ok, util = pcall(require, "aerial.util")
	if ok then
		return util
	end
end

local function get_aerial_backends()
	local ok, backends = pcall(require, "aerial.backends")
	if ok then
		return backends
	end
end

function M.ensure_wrapped()
	if wrapped then
		return true
	end

	local aerial_util = get_aerial_util()
	if not aerial_util or type(aerial_util.is_ignored_win) ~= "function" then
		return false
	end

	original_is_ignored_win = aerial_util.is_ignored_win
	aerial_util.is_ignored_win = function(winid)
		if not winid or winid == 0 then
			winid = vim.api.nvim_get_current_win()
		end
		if suspended_wins[winid] then
			return true, "lazyvcs suspended Aerial for diff transfer"
		end
		return original_is_ignored_win(winid)
	end
	wrapped = true
	return true
end

function M.suspend_win(winid)
	if not winid or winid == 0 or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	if M.ensure_wrapped() then
		suspended_wins[winid] = true
	end
end

function M.resume_win(winid)
	if not winid or winid == 0 then
		return
	end
	suspended_wins[winid] = nil
end

function M.disable_buffer(bufnr, opts)
	if not bufnr or bufnr == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	opts = opts or {}
	local state = {
		bufnr = bufnr,
	}
	local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, "aerial_backends")
	state.had_backends = ok
	state.backends = value

	if opts.detach then
		local backends = get_aerial_backends()
		if backends then
			local attached = backends.get_attached_backend(bufnr)
			state.attached_backend = attached
			if attached then
				local backend = backends.get_backend_by_name(attached)
				if backend and type(backend.detach) == "function" then
					pcall(backend.detach, bufnr)
				end
				pcall(vim.api.nvim_buf_del_var, bufnr, "aerial_backend")
			end
		end
	end

	pcall(vim.api.nvim_buf_set_var, bufnr, "aerial_backends", {})
	return state
end

function M.restore_buffer(state)
	if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	if state.had_backends then
		pcall(vim.api.nvim_buf_set_var, state.bufnr, "aerial_backends", state.backends)
	else
		pcall(vim.api.nvim_buf_del_var, state.bufnr, "aerial_backends")
	end
end

function M.refetch_buffer(bufnr)
	local aerial = get_aerial()
	if not aerial or type(aerial.refetch_symbols) ~= "function" then
		return
	end

	vim.schedule(function()
		if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
			pcall(aerial.refetch_symbols, bufnr)
		end
	end)
end

return M
