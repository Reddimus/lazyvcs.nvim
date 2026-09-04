-- Buffer-scoped VCS operations: changed-file picker, diff preview, revert, refresh.
--
-- Replaces the old `svn_ui` module, which hardcoded Subversion and so silently
-- did nothing in a Git repository. Everything here dispatches through
-- `lazyvcs.backends`, so the same commands work in both VCSes.
local backends = require("lazyvcs.backends")
local buffer_guard = require("lazyvcs.source_control.buffer_guard")
local picker = require("lazyvcs.picker")
local signs = require("lazyvcs.signs")
local confirm = require("lazyvcs.source_control.confirm")
local util = require("lazyvcs.util")

local M = {}

local function current_path()
	local bufnr = vim.api.nvim_get_current_buf()
	if util.is_real_file_buffer(bufnr) then
		return util.buf_path(bufnr)
	end
	return vim.fs.normalize(vim.fn.getcwd())
end

function M.files()
	local path = current_path()
	return backends.changed_files_async(path, function(items, err)
		if not items then
			return util.notify(err or "Unable to list changed files", vim.log.levels.WARN)
		end
		if #items == 0 then
			return util.notify("No changed files", vim.log.levels.INFO)
		end

		local backend = backends.resolve_cached(path)
		local backend_name = backend and backend.name or "vcs"
		picker.select(items, {
			prompt = string.format("%s changed files", backend_name:upper()),
			format_item = function(item)
				return string.format("%s %s", item.status, item.path)
			end,
		}, function(item)
			if not item then
				return
			end
			vim.cmd.edit(vim.fn.fnameescape(item.absolute_path))
		end)
	end)
end

local function request_owner()
	local owner = { active = true }
	function owner:set(handle)
		if not self.active and handle and type(handle.kill) == "function" then
			pcall(handle.kill, handle, 15)
			return
		end
		self.handle = handle
	end
	function owner:finish()
		self.active = false
		self.handle = nil
	end
	function owner:kill()
		if not self.active then
			return false
		end
		self.active = false
		if self.handle and type(self.handle.kill) == "function" then
			pcall(self.handle.kill, self.handle, 15)
		end
		self.handle = nil
		return true
	end
	owner.cancel = owner.kill
	return owner
end

function M.preview_diff()
	return signs.preview_diff()
end

function M.revert_hunk()
	return signs.revert_hunk()
end

function M.revert_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = util.is_real_file_buffer(bufnr) and util.buf_path(bufnr)
	if not path then
		return util.notify("Current buffer is not a tracked Git or SVN file", vim.log.levels.WARN)
	end
	local owner = request_owner()
	owner:set(backends.is_versioned_async(path, function(versioned, version_err)
		if not owner.active then
			return
		end
		owner.handle = nil
		if not versioned then
			owner:finish()
			return util.notify(version_err or "Current buffer is not a tracked Git or SVN file", vim.log.levels.WARN)
		end
		local backend, root = backends.resolve_cached(path)
		if not buffer_guard.check(root or util.dir_of(path), { path }) then
			owner:finish()
			return
		end
		local backend_name = backend and backend.name or "VCS"
		confirm.open({
			prompt = string.format("Discard all %s worktree changes in this file?", backend_name:upper()),
		}, function(choice)
			if not owner.active then
				return
			end
			if choice ~= "confirm" and choice ~= "confirm_session" then
				owner:finish()
				return
			end
			if not buffer_guard.check(root or util.dir_of(path), { path }) then
				owner:finish()
				return
			end
			owner:set(backends.revert_file_async(path, function(result, err)
				if not owner.active then
					return
				end
				owner:finish()
				if not result then
					return util.notify(err or "Discard failed", vim.log.levels.ERROR)
				end
				if util.buf_is_valid(bufnr) and util.buf_path(bufnr) == path then
					vim.cmd("checktime " .. bufnr)
					signs.refresh(bufnr, true)
				end
			end, {
				start = function(args, opts, on_exit)
					local guard_err = buffer_guard.error(root or util.dir_of(path), { path })
					if guard_err then
						local raw = {
							code = 1,
							stdout = "",
							stderr = guard_err,
							stdout_truncated = false,
							stderr_truncated = false,
						}
						on_exit(nil, guard_err, raw)
						return {}
					end
					return util.system_start(args, opts, on_exit)
				end,
			}))
		end)
	end))
	return owner
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	require("lazyvcs.blame").refresh(bufnr)
	return signs.refresh(bufnr, true)
end

return M
