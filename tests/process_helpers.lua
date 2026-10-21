local M = {}

function M.alive(pid)
	if not pid or not vim.uv.kill(pid, 0) then
		return false
	end
	if vim.fn.has("linux") == 1 then
		local file = io.open("/proc/" .. pid .. "/stat", "r")
		if file then
			local stat = file:read("*a")
			file:close()
			local state = stat and stat:match("%) (%a)")
			return state ~= nil and state ~= "Z"
		end
	end
	return true
end

-- Unlike alive(), this rejects zombies on every platform.
function M.reaped(pid)
	if not pid then
		return false
	end
	local ok, _, code = vim.uv.kill(pid, 0)
	return not ok and code == "ESRCH"
end

function M.pid(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local value = tonumber(file:read("*a"))
	file:close()
	return value
end

function M.pids(dir)
	local pids = {}
	for _, path in ipairs(vim.fn.glob(dir .. "/**/*.pid", false, true)) do
		pids[#pids + 1] = M.pid(path)
	end
	return pids
end

function M.guarded(dir, fn)
	local ok, err = xpcall(fn, debug.traceback)
	for _, pid in ipairs(M.pids(dir)) do
		if M.alive(pid) then
			pcall(vim.uv.kill, pid, 9)
		end
	end
	assert(ok, err)
end

function M.tree(dir, redirected)
	local script = dir .. "/tree.sh"
	vim.fn.writefile({
		"#!/bin/sh",
		'echo $$ > "$1/parent.pid"',
		'sh -c \'trap "" TERM; echo $$ > "$1/child.pid"; sleep 60 & echo $! > "$1/leaf.pid"; wait\' sh "$1"'
			.. (redirected and " >/dev/null 2>&1 &" or " &"),
		"wait",
	}, script)
	vim.uv.fs_chmod(script, 493)
	return { "sh", script, dir }
end

function M.ready(dir)
	return M.pid(dir .. "/leaf.pid") ~= nil
end

function M.dead(dir)
	for _, pid in ipairs(M.pids(dir)) do
		if M.alive(pid) then
			return false
		end
	end
	return true
end

-- File-backed stdio prevents inherited pipes from holding the outer test open.
function M.editor(script, dir, args, timeout_ms)
	local stdout = assert(vim.uv.fs_open(dir .. "/editor.out", "w", 384))
	local stderr = assert(vim.uv.fs_open(dir .. "/editor.err", "w", 384))
	local code
	local argv = { "--headless", "-u", "NONE", "-i", "NONE", "-l", script }
	vim.list_extend(argv, args or {})
	local handle = assert(vim.uv.spawn(vim.v.progpath, {
		args = argv,
		stdio = { nil, stdout, stderr },
	}, function(status)
		code = status
	end))
	vim.uv.fs_close(stdout)
	vim.uv.fs_close(stderr)
	local exited = vim.wait(timeout_ms or 10000, function()
		return code ~= nil
	end, 10)
	if not exited then
		handle:kill(9)
	end
	handle:close()
	assert(
		exited,
		"nested editor did not exit: "
			.. table.concat(args or {}, " ")
			.. "\n"
			.. table.concat(vim.fn.readfile(dir .. "/editor.err"), "\n")
	)
	assert(code == 0, "nested editor failed: " .. table.concat(vim.fn.readfile(dir .. "/editor.err"), "\n"))
end

return M
