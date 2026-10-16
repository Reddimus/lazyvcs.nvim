local root, dir, mode, sidebar = arg[1], arg[2], arg[3], arg[4]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p = require("process_helpers")
local leaving, began = false, nil
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		began = vim.uv.hrtime()
	end,
})
local util = require("lazyvcs.util")
local jobs = require("lazyvcs.source_control.jobs")
require("lazyvcs.config").setup({ source_control = { background = { git_workers = 1, svn_workers = 1 } } })
if sidebar == "yes" then
	require("lazyvcs.source_control.native")
end
local function callback()
	if leaving then
		vim.fn.writefile({ "unexpected callback" }, dir .. "/callback")
	end
end
local ids = {}
local function start(vcs, kind, index)
	local work = dir .. "/" .. index
	vim.fn.mkdir(work, "p")
	ids[#ids + 1] = jobs.command({ root = dir, vcs = vcs }, kind, p.tree(work), {
		timeout_ms = 60000,
		kill_grace_ms = 10000,
	}, callback)
	assert(
		vim.wait(4000, function()
			return p.ready(work)
		end, 10),
		"tree not ready"
	)
end
start("git", "status", "git")
if mode == "cancelled" then
	jobs.cancel(function(job)
		return job.id == ids[1]
	end, "test")
	assert(p.alive(p.pid(dir .. "/git/child.pid")), "cancelled descendant not alive before exit")
else
	start("svn", "status", "svn")
	start("git", "buffer", "editor-git-1")
	start("git", "buffer", "editor-git-2")
	start("svn", "buffer", "editor-svn")
	local work = dir .. "/direct"
	vim.fn.mkdir(work, "p")
	util.system_start(p.tree(work), { kill_grace_ms = 10000 }, callback)
	assert(
		vim.wait(4000, function()
			return p.ready(work)
		end, 10),
		"direct tree not ready"
	)
	for _, vcs in ipairs({ "git", "svn" }) do
		for _, kind in ipairs({ "status", "buffer" }) do
			jobs.command(
				{ root = dir, vcs = vcs },
				kind,
				{ "sh", "-c", 'echo started > "$1/queued"', "sh", dir },
				{},
				callback
			)
		end
	end
end

-- Deliver a completed preflight only after shutdown begins.
local preflight_settled = mode == "cancelled"
if mode ~= "cancelled" then
	local original, exited = vim.system, nil
	vim.system = function(_, _, cb)
		exited = cb
		return { kill = function() end }
	end
	require("lazyvcs.source_control.mutation_start").start(
		{ root = dir, vcs = "git" },
		{ "sh", "-c", 'echo mutation > "$1/queued"', "sh", dir },
		{ cwd = dir, on_exit_during_shutdown = true },
		{ branch_ref = "refs/heads/main" },
		function(_, _, raw)
			preflight_settled = raw and raw.cancelled == true
		end
	)
	vim.system = original
	assert(exited)({ code = 0, stdout = "refs/heads/main\n", stderr = "" })
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = util.safe_callback(function()
		local runtime = package.loaded["lazyvcs.process_runtime"]
		local state = {
			elapsed_ms = (vim.uv.hrtime() - began) / 1e6,
			history = jobs.history(),
			preflight_settled = preflight_settled,
		}
		if runtime then
			state.closed = runtime.is_shutting_down()
			runtime.shutdown()
			state.rejected = jobs.command(
				{ root = dir, vcs = "git" },
				"status",
				{ "sh", "-c", 'echo late > "$1/queued"', "sh", dir },
				{},
				callback
			) ~= nil
			util.system_start({ "sh", "-c", 'echo late > "$1/queued"', "sh", dir }, {}, callback)
		end
		vim.fn.writefile({ vim.json.encode(state) }, dir .. "/shutdown.json")
	end),
})
leaving = true
vim.cmd("qa!")
