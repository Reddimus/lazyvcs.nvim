return function(ctx)
	local h, p = ctx.helpers, require("process_helpers")
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local fixture = root .. "/tests/fixtures/process_preserved_exit.lua"
	local function read(path)
		return vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or nil
	end
	local function assert_prompt_exit(dir)
		local elapsed = tonumber(read(dir .. "/exit-ms"))
		assert(elapsed and elapsed < 500, "preserved command delayed editor exit: " .. tostring(elapsed) .. " ms")
	end
	local function wait_for_command(dir)
		local pid = p.pid(dir .. "/command.pid")
		ctx.wait_for(function()
			return not p.alive(pid)
		end, "preserved command did not exit", 10000)
	end
	return {
		{
			"test_source_control_preserved_command_writes_after_editor_exit",
			function()
				local dir = h.tempdir()
				-- Default SIGPIPE handling, like Git: a write without a reader kills it.
				h.write_file(
					dir .. "/writer.lua",
					[[
local uv, dir = vim.uv, arg[1]
local function mark(name, text)
  local file = assert(io.open(dir .. "/" .. name, "w"))
  file:write(text or name)
  file:close()
end
mark("writer.pid", tostring(uv.os_getpid()))
mark("ready")
while not uv.fs_stat(dir .. "/release") do uv.sleep(10) end
mark("released")
-- More than a pipe buffer on each stream, so the output must be read.
local chunk, failure = string.rep("x", 1023) .. "\n", nil
for _ = 1, 256 do
  for _, stream in ipairs({ io.stdout, io.stderr }) do
    local ok, err = stream:write(chunk)
    if ok then ok, err = stream:flush() end
    failure = failure or (not ok and tostring(err)) or nil
  end
end
mark("done", failure and ("write failed: " .. failure) or "ok")
]]
				)
				p.guarded(dir, function()
					p.editor(fixture, dir, { root, dir, "writer" })
					assert_prompt_exit(dir)
					h.write_file(dir .. "/release", "go")
					vim.wait(10000, function()
						return read(dir .. "/done") ~= nil
					end, 10)
					assert(
						read(dir .. "/done") == "ok",
						"preserved command could not write after editor exit: "
							.. (
								read(dir .. "/done")
								or ("no completion; released=" .. tostring(read(dir .. "/released")))
							)
					)
					wait_for_command(dir)
				end)
			end,
		},
		{
			"test_source_control_preserved_push_sets_upstream_after_editor_exit",
			function()
				local dir = h.tempdir()
				local work = dir .. "/work"
				h.exec({ "git", "init", "--bare", dir .. "/remote.git" }, dir)
				vim.fn.mkdir(work, "p")
				h.exec({ "git", "init" }, work)
				h.exec({ "git", "symbolic-ref", "HEAD", "refs/heads/feature" }, work)
				h.exec({
					"git",
					"-c",
					"user.name=lazyvcs-test",
					"-c",
					"user.email=lazyvcs@example.com",
					"commit",
					"--allow-empty",
					"-m",
					"init",
				}, work)
				h.exec({ "git", "remote", "add", "origin", dir .. "/remote.git" }, work)
				-- Git prints the push summary and then records the upstream.
				h.write_file(
					work .. "/.git/hooks/pre-push",
					"#!/bin/sh\n: > ready\nwhile [ ! -f release ]; do sleep 0.05; done\n"
				)
				vim.uv.fs_chmod(work .. "/.git/hooks/pre-push", 493)
				p.guarded(dir, function()
					p.editor(fixture, dir, { root, dir, "push" })
					assert_prompt_exit(dir)
					h.write_file(work .. "/release", "go")
					local upstream
					vim.wait(10000, function()
						upstream = vim.system(
							{ "git", "rev-parse", "--abbrev-ref", "feature@{upstream}" },
							{ cwd = work, text = true }
						):wait()
						return upstream.code == 0
					end, 50)
					local remote = vim.system(
						{ "git", "branch", "--list", "feature" },
						{ cwd = dir .. "/remote.git", text = true }
					):wait()
					assert(
						upstream.code == 0 and vim.trim(upstream.stdout) == "origin/feature",
						"push did not finish after editor exit: remote="
							.. vim.trim(remote.stdout or "")
							.. " upstream="
							.. vim.trim((upstream.stdout or "") .. (upstream.stderr or ""))
					)
					wait_for_command(dir)
				end)
			end,
		},
	}
end
