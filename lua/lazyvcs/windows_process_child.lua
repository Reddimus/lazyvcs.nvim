-- Standalone -ll helper: no editor initialization, stdin watcher, or user config.
local uv = vim.uv
local prefix = assert(arg[1], "missing command prefix")
-- Older luv getenv uses a fixed buffer on Windows. Enumeration preserves full
-- values without that limit, including long and Unicode command arguments.
local environment = uv.os_environ()
local count = assert(tonumber(environment[prefix .. 0]), "missing command arguments")
uv.os_unsetenv(prefix .. 0)
local command = {}
for i = 1, count do
	local name = prefix .. i
	command[i] = assert(environment[name], "missing command argument " .. i):sub(2)
	uv.os_unsetenv(name)
end

local argv = {}
for i = 2, #command do
	argv[#argv + 1] = command[i]
end
-- Establish ownership before spawning: even native shell descendants that
-- break away from libuv's inner job remain in this restrictive ancestor job.
local job
local windows = package.config:sub(1, 1) == "\\"
if windows then
	local job_path = arg[0]:gsub("windows_process_child.lua$", "windows_process_job.lua")
	local ok, result = pcall(dofile, job_path)
	if not ok then
		io.stderr:write("Could not own background command: " .. tostring(result) .. "\n")
		os.exit(127)
	end
	job = result
end
local exit_code
local handle
local err
handle, err = uv.spawn(command[1], {
	args = argv,
	-- Inherited descriptors avoid CREATE_NO_WINDOW. SW_HIDE still applies,
	-- giving the command a hidden console inherited by native descendants.
	hide = true,
	stdio = { 0, 1, 2 },
}, function(code)
	exit_code = code
	assert(handle):close()
end)
if not handle then
	io.stderr:write("Could not start background command: " .. tostring(err) .. "\n")
	os.exit(127)
end
uv.run()
-- A normally completed command may have intentional background descendants.
-- Release kill-on-close before teardown, preserving the actual exit status.
if job then
	local ok, release_err = pcall(job)
	if not ok then
		io.stderr:write(tostring(release_err) .. "\n")
		os.exit(127)
	end
end
os.exit(exit_code or 127)
