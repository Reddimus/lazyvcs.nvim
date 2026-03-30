local config = require("lazyvcs.config")

local M = {}

function M.setup(opts)
	return config.setup(opts)
end

function M.open()
	return require("lazyvcs.actions").open()
end

function M.close()
	return require("lazyvcs.actions").close()
end

function M.toggle()
	return require("lazyvcs.actions").toggle()
end

function M.revert_hunk()
	return require("lazyvcs.actions").revert_hunk()
end

function M.next_hunk()
	return require("lazyvcs.actions").next_hunk()
end

function M.prev_hunk()
	return require("lazyvcs.actions").prev_hunk()
end

function M.refresh()
	return require("lazyvcs.actions").refresh_current()
end

return M
