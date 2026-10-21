local root, dir, mode = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p, util = require("process_helpers"), require("lazyvcs.util")
local results = {}
local function start(name, preserved)
	local path = dir .. "/" .. name
	vim.fn.mkdir(path, "p")
	local exited, failure = false, nil
	local handle = util.system_start({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"-i",
		"NONE",
		"-l",
		root .. "/tests/fixtures/process_native_child.lua",
		path,
		"parent",
	}, {
		scope = "mutation",
		preserve_on_shutdown = preserved,
		kill_grace_ms = 50,
		timeout_ms = mode == "timeout" and 10000 or nil,
	}, function(_, err, raw)
		results[name] = raw
		exited, failure = true, tostring(err) .. "\n" .. (raw and raw.stdout or "")
		vim.fn.writefile({ "unexpected" }, path .. "/callback")
	end)
	assert(
		vim.wait(10000, function()
			return p.pid(path .. "/leaf.pid") ~= nil or exited
		end, 10),
		"tree readiness timed out: " .. name
	)
	assert(not exited, "tree exited before readiness (" .. name .. "): " .. tostring(failure))
	return handle, path
end
local mutation, path = start("mutation", true)
local reader, reader_path = start("reader", false)
if vim.fn.has("win32") == 1 then
	local mutation_console = vim.fn.readfile(path .. "/leaf.console")[1]
	local reader_console = vim.fn.readfile(reader_path .. "/leaf.console")[1]
	vim.fn.writefile({ "detached=" .. mutation_console, "attached=" .. reader_console }, dir .. "/console-baseline")
	assert(
		mutation_console == "0" or reader_console == "1",
		"detachment introduced a visible native descendant console"
	)
end
if mode == "timeout" then
	assert(
		vim.wait(15000, function()
			return results.mutation and results.reader and p.dead(path) and p.dead(reader_path)
		end, 10),
		"timeout left descendants"
	)
	assert(results.mutation.timed_out and results.reader.timed_out, "timeout result lost")
elseif mode == "cancel" then
	mutation:cancel("explicit cancellation")
	reader:cancel("explicit cancellation")
	assert(
		vim.wait(5000, function()
			return p.dead(path) and p.dead(dir .. "/reader")
		end, 10),
		"cancel left descendants"
	)
end
vim.cmd("qa!")
