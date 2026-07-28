-- Public Lua API. Every function here is a supported entry point for user
-- configs and keymaps; `:LazyVCS` is the command-line equivalent.
local config = require("lazyvcs.config")

local M = {}

local function source_control_enabled()
	if config.get().source_control.enabled then
		return true
	end
	require("lazyvcs.util").notify("lazyvcs source control is disabled", vim.log.levels.WARN)
	return false
end

function M.setup(opts)
	local resolved = config.setup(opts)
	require("lazyvcs.commands").setup()
	require("lazyvcs.signs").setup()
	require("lazyvcs.blame").setup()
	return resolved
end

-- Live diff ------------------------------------------------------------------

function M.open(opts)
	return require("lazyvcs.actions").open(opts)
end

function M.close()
	return require("lazyvcs.actions").close()
end

function M.toggle()
	return require("lazyvcs.actions").toggle()
end

function M.refresh()
	return require("lazyvcs.actions").refresh_current()
end

-- Hunks ----------------------------------------------------------------------

function M.revert_hunk()
	return require("lazyvcs.actions").revert_hunk()
end

function M.next_hunk()
	return require("lazyvcs.actions").next_hunk()
end

function M.prev_hunk()
	return require("lazyvcs.actions").prev_hunk()
end

-- Blame ----------------------------------------------------------------------

function M.blame()
	return require("lazyvcs.blame").blame()
end

function M.blame_split()
	return require("lazyvcs.blame").blame_split()
end

function M.blame_clear()
	return require("lazyvcs.blame").blame_clear()
end

function M.line_log()
	return require("lazyvcs.blame").line_log()
end

-- Buffer operations (Git and SVN) --------------------------------------------

function M.preview_diff()
	return require("lazyvcs.buffer_ops").preview_diff()
end

function M.revert_buffer()
	return require("lazyvcs.buffer_ops").revert_buffer()
end

function M.files()
	return require("lazyvcs.buffer_ops").files()
end

-- Source-control sidebar -----------------------------------------------------

function M.source_control_open(opts)
	if not source_control_enabled() then
		return
	end
	return require("lazyvcs.source_control.native").open(opts)
end

function M.source_control_close()
	return require("lazyvcs.source_control.native").close()
end

function M.source_control_toggle(opts)
	if not source_control_enabled() then
		return
	end
	return require("lazyvcs.source_control.native").toggle(opts)
end

function M.source_control_refresh()
	if not source_control_enabled() then
		return
	end
	return require("lazyvcs.source_control.native").refresh(true)
end

---Cancel source-control work.
---@param path? string Repository root. When omitted, cancels all source-control jobs.
---@return integer count Number of queued or running jobs cancelled.
function M.source_control_cancel(path)
	return require("lazyvcs.source_control.native").cancel(path)
end

return M
