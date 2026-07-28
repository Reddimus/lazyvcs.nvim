-- Single `:LazyVCS` entry point.
--
-- Every handler `require`s its module lazily so that registering the command at
-- startup (plugin/lazyvcs.lua) does not pull in actions/blame/signs/backends.
local M = {}

local function actions()
	return require("lazyvcs.actions")
end

local function blame()
	return require("lazyvcs.blame")
end

local function buffer_ops()
	return require("lazyvcs.buffer_ops")
end

local function sidebar()
	return require("lazyvcs")
end

local function path_arg(args)
	local path = args[1]
	return (path and path ~= "") and path or nil
end

local function show_profile(args)
	local jobs = require("lazyvcs.source_control.jobs")
	if args[1] == "clear" then
		jobs.clear_history()
		return require("lazyvcs.util").notify("Cleared source-control job history")
	end

	local lines = {}
	for _, item in ipairs(jobs.history()) do
		lines[#lines + 1] = string.format(
			"%6dms %-9s %-7s %s %s",
			item.duration_ms or 0,
			item.status or "",
			item.vcs or "",
			item.kind or "",
			item.root or ""
		)
		if item.error and item.error ~= "" then
			lines[#lines + 1] = "  " .. item.error
		end
	end
	if #lines == 0 then
		lines[1] = "No lazyvcs source-control jobs recorded."
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "lazyvcs source control profile" })
end

-- Each entry is either a leaf (`run`) or a group of verbs (`verbs` + `default`).
---@type table<string, table>
local spec = {
	sidebar = {
		desc = "Source-control sidebar",
		default = "toggle",
		verbs = {
			open = {
				run = function(a)
					sidebar().source_control_open({ path = path_arg(a) })
				end,
				complete = "dir",
			},
			close = {
				run = function()
					sidebar().source_control_close()
				end,
			},
			toggle = {
				run = function(a)
					sidebar().source_control_toggle({ path = path_arg(a) })
				end,
				complete = "dir",
			},
			refresh = {
				run = function()
					sidebar().source_control_refresh()
				end,
			},
			cancel = {
				run = function(a)
					local count = sidebar().source_control_cancel(path_arg(a))
					require("lazyvcs.util").notify(
						count == 1 and "Cancelled one source-control job"
							or string.format("Cancelled %d source-control jobs", count),
						count > 0 and vim.log.levels.INFO or vim.log.levels.WARN
					)
				end,
				complete = "dir",
			},
		},
	},
	diff = {
		desc = "Live diff view",
		default = "toggle",
		verbs = {
			open = {
				run = function()
					actions().open()
				end,
			},
			close = {
				run = function()
					actions().close()
				end,
			},
			toggle = {
				run = function()
					actions().toggle()
				end,
			},
			refresh = {
				run = function()
					actions().refresh_current()
				end,
			},
		},
	},
	hunk = {
		desc = "Hunk navigation and revert",
		default = "next",
		verbs = {
			next = {
				run = function()
					actions().next_hunk()
				end,
			},
			prev = {
				run = function()
					actions().prev_hunk()
				end,
			},
			revert = {
				run = function()
					actions().revert_hunk()
				end,
			},
		},
	},
	blame = {
		desc = "Inline and split blame",
		default = "toggle",
		verbs = {
			toggle = {
				run = function()
					blame().blame()
				end,
			},
			split = {
				run = function()
					blame().blame_split()
				end,
			},
			clear = {
				run = function()
					blame().blame_clear()
				end,
			},
			log = {
				run = function()
					blame().line_log()
				end,
			},
		},
	},
	signs = {
		desc = "Gutter signs",
		default = "refresh",
		verbs = {
			refresh = {
				run = function()
					buffer_ops().refresh()
				end,
			},
		},
	},
	profile = {
		desc = "Source-control job timings",
		default = "show",
		verbs = {
			show = { run = show_profile },
			clear = {
				run = function()
					show_profile({ "clear" })
				end,
			},
		},
	},
	files = {
		desc = "Browse changed files",
		run = function()
			buffer_ops().files()
		end,
	},
	preview = {
		desc = "Preview the current buffer diff",
		run = function()
			buffer_ops().preview_diff()
		end,
	},
	revert = {
		desc = "Revert the current buffer",
		run = function()
			buffer_ops().revert_buffer()
		end,
	},
	health = {
		desc = "Run :checkhealth lazyvcs",
		run = function()
			vim.cmd.checkhealth("lazyvcs")
		end,
	},
}

-- Deterministic ordering for completion and error messages.
local function sorted_keys(tbl)
	local keys = vim.tbl_keys(tbl)
	table.sort(keys)
	return keys
end

local function fail(msg)
	require("lazyvcs.util").notify(msg, vim.log.levels.ERROR)
end

local function dispatch(opts)
	local args = opts.fargs

	-- Bare `:LazyVCS` toggles the sidebar, the most common entry point.
	if #args == 0 then
		return spec.sidebar.verbs.toggle.run({})
	end

	local name = args[1]
	local entry = spec[name]
	if not entry then
		return fail(
			string.format("Unknown subcommand '%s'. Expected one of: %s", name, table.concat(sorted_keys(spec), ", "))
		)
	end

	local rest = vim.list_slice(args, 2)

	if entry.run then
		return entry.run(rest)
	end

	local verb = rest[1]
	if not verb then
		return entry.verbs[entry.default].run({})
	end

	local action = entry.verbs[verb]
	if not action then
		-- A path-taking group (`:LazyVCS sidebar ~/code`) should treat an unknown
		-- first token as the argument to its default verb rather than an error.
		local default = entry.verbs[entry.default]
		if default.complete == "dir" then
			return default.run(rest)
		end
		return fail(
			string.format(
				"Unknown '%s' action '%s'. Expected one of: %s",
				name,
				verb,
				table.concat(sorted_keys(entry.verbs), ", ")
			)
		)
	end

	return action.run(vim.list_slice(rest, 2))
end

local function complete(arg_lead, cmd_line)
	-- Split what has been typed so far, ignoring the command name itself.
	local typed = vim.split(vim.trim(cmd_line), "%s+")
	table.remove(typed, 1)
	-- A trailing space means the user is starting a new token.
	local completing_new = cmd_line:sub(-1) == " "
	local depth = #typed + (completing_new and 1 or 0)

	local function matching(candidates)
		return vim.tbl_filter(function(item)
			return item:find(arg_lead, 1, true) == 1
		end, candidates)
	end

	if depth <= 1 then
		return matching(sorted_keys(spec))
	end

	local entry = spec[typed[1]]
	if not entry or not entry.verbs then
		return {}
	end

	if depth == 2 then
		return matching(sorted_keys(entry.verbs))
	end

	-- Third token: only directory-taking verbs accept an argument.
	local action = entry.verbs[typed[2]] or entry.verbs[entry.default]
	if action and action.complete == "dir" then
		return vim.fn.getcompletion(arg_lead, "dir")
	end
	return {}
end

function M.setup()
	pcall(vim.api.nvim_del_user_command, "LazyVCS")
	vim.api.nvim_create_user_command("LazyVCS", dispatch, {
		desc = "lazyvcs: Git/SVN source control, diff, hunks, blame",
		nargs = "*",
		complete = complete,
	})
end

-- Exposed for tests.
M._spec = spec
M._complete = complete

return M
