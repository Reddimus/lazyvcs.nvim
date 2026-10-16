local root, dir, mode = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
local util = require("lazyvcs.util")
local runtime = require("lazyvcs.process_runtime")
local jobs = require("lazyvcs.source_control.jobs")
if mode ~= "handles" then
	local ai = require("lazyvcs.source_control.ai")
	require("lazyvcs.config").setup({
		ai = {
			commit_message = {
				provider = "auto",
				provider_order = { "copilot_cli", "claude" },
				confirm_privacy = false,
			},
		},
	})
	ai._test_set_executable_checker(function()
		return true
	end)
	local original = vim.system
	local attachment, launched, callbacks = nil, 0, 0
	vim.system = function(args, opts, cb)
		if args[1] ~= "git" then
			launched = launched + 1
			assert(args[1] == "copilot", "provider fallback ran during shutdown")
			attachment = args[vim.fn.index(args, "--attachment") + 2]
			return original({ "sh", "-c", "exec sleep 60" }, opts, cb)
		end
		return original(args, opts, cb)
	end
	ai.generate({ root = dir, vcs = "git" }, function()
		callbacks = callbacks + 1
	end)
	assert(
		vim.wait(4000, function()
			return attachment ~= nil
		end, 10),
		"private attachment not created"
	)
	assert(vim.uv.fs_stat(assert(attachment)), "attachment missing before shutdown")
	runtime.shutdown()
	vim.system = original
	assert(not vim.uv.fs_stat(assert(attachment)), "private attachment survived shutdown")
	assert(launched == 1 and callbacks == 0, "shutdown advanced AI generation")
end
runtime.shutdown()
local called = false
local handle = util.system_start({ "sh", "-c", 'echo late > "$1/queued"', "sh", dir }, {}, function()
	called = true
end)
assert(type(handle) == "table" and handle.done, "shutdown must return a finished process handle")
for _, method in ipairs({ "cancel", "kill", "force", "shutdown" }) do
	assert(handle[method](handle) == false, "shutdown handle method must be inert")
end
local cleaned = false
util.system_start({ "never-started" }, { on_exit_during_shutdown = true }, function(_, _, raw)
	cleaned = raw.cancelled == true
end)
local first = jobs.command({ root = dir }, "status", { "never-started" })
local second = jobs.command({ root = dir }, "status", { "never-started" })
assert(type(first) == "number" and second > first, "shutdown must return unique numeric job ids")
assert(({ [first] = true })[first], "job id cannot be used as a table key")
assert(
	vim.wait(1000, function()
		return cleaned
	end, 10),
	"rejected command skipped required exit cleanup"
)
assert(not called and vim.fn.filereadable(dir .. "/queued") == 0, "shutdown launched work or an application callback")
vim.cmd("qa!")
