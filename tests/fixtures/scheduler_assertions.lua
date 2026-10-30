local root, scratch, mode, case = arg[1], arg[2], arg[3], arg[4]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/tests/?.lua;" .. package.path
vim.env.LAZYVCS_TEST_GROUP = mode:match("^process") and "core" or "source_control"
vim.env.LAZYVCS_TEST_CASE = case
vim.env.XDG_STATE_HOME = scratch .. "/state"
vim.env.XDG_CACHE_HOME = scratch .. "/cache"

if mode:match("^process") then
	local util = require("lazyvcs.util")
	local start = util.system_start
	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, opts, done)
		local terminate = opts.on_terminate
		if terminate then
			opts.on_terminate = function(result, err, raw)
				if mode == "process_error" then
					err = nil
				else
					raw = { timed_out = false }
				end
				return terminate(result, err, raw)
			end
		end
		return start(args, opts, done)
	end
else
	local jobs = require("lazyvcs.source_control.jobs")
	local command = jobs.command
	---@diagnostic disable-next-line: duplicate-set-field
	jobs.command = function(repo, kind, args, opts, done)
		if kind == "cancel-delayed" or kind == "timeout-late" then
			local callback = done
			done = function(result, err, raw)
				if mode == "cancel_metadata" then
					raw = { cancelled = false }
				else
					err = nil
				end
				return callback(result, err, raw)
			end
		end
		return command(repo, kind, args, opts, done)
	end
end

dofile(root .. "/tests/run.lua")
