return function(ctx)
	local h = ctx.helpers
	local function fixture()
		local dir = h.tempdir()
		local script = dir .. "/echo command.lua"
		h.write_file(
			script,
			[[
local uv = vim.uv
local function field(value)
  assert(uv.fs_write(1, tostring(#value) .. ":" .. value, -1))
end
for _, value in ipairs(arg) do field(value) end
local input = {}
while true do
  local chunk = assert(uv.fs_read(0, 65536, -1))
  if chunk == "" then break end
  input[#input + 1] = chunk
end
field(table.concat(input))
field((assert(uv.fs_realpath(".")):gsub("\\", "/")))
field(vim.uv.os_getenv("LAZYVCS_TRANSPORT_TEST") or "missing")
for name in pairs(vim.uv.os_environ()) do
  assert(not name:match("^LAZYVCS_PROCESS_%d+_%d+_"), "private protocol leaked")
end
assert(uv.fs_write(2, "stderr\0\r\n", -1))
os.exit(7)
]]
		)
		return dir, script
	end
	local function encoded(values)
		local result = {}
		for _, value in ipairs(values) do
			result[#result + 1] = tostring(#value) .. ":" .. value
		end
		return table.concat(result)
	end
	local function run(streaming, clear_env)
		local dir, script = fixture()
		local values = { "space value", "", 'quote"value', "trailing\\", "é漢字", string.rep("long", 2048) }
		local args = { vim.v.progpath, "-ll", script }
		vim.list_extend(args, values)
		local input = "binary\0\r\ninput"
		local opts = {
			cwd = dir,
			env = { LAZYVCS_TRANSPORT_TEST = "override" },
			clear_env = clear_env,
			stdin = streaming and true or input,
			text = false,
		}
		local original_args, original_opts = vim.deepcopy(args), vim.deepcopy(opts)
		local wrapped, wrapped_opts = require("lazyvcs.windows_process").wrap(args, opts)
		assert(vim.deep_equal(args, original_args) and vim.deep_equal(opts, original_opts), "wrapper mutated caller")
		local process = vim.system(wrapped, wrapped_opts)
		if streaming then
			process:write("binary\0")
			vim.wait(30, function()
				return false
			end)
			process:write("\r\ninput")
			process:write(nil)
		end
		local result = process:wait(10000)
		assert(result.code == 7, "command exit code changed: " .. vim.inspect(result))
		local expected = vim.deepcopy(values)
		vim.list_extend(expected, { input, dir, "override" })
		local wanted = encoded(expected)
		local index = 1
		while index <= #wanted and wanted:sub(index, index) == result.stdout:sub(index, index) do
			index = index + 1
		end
		assert(
			result.stdout == wanted,
			string.format(
				"transport differs at byte %d: actual=%q expected=%q",
				index,
				result.stdout:sub(index, index + 50),
				wanted:sub(index, index + 50)
			)
		)
		assert(result.stderr == "stderr\0\r\n", "stderr bytes changed")
	end
	local function cancel_startup()
		if vim.fn.has("win32") ~= 1 then
			error({ lazyvcs_skip = "native Windows process ownership" })
		end
		local p = require("process_helpers")
		for _, delay in ipairs({ 0, 1 }) do
			local dir = h.tempdir()
			h.write_file(
				dir .. "/startup.lua",
				[[
local file = assert(io.open("parent.pid", "w"))
file:write(tostring(vim.uv.os_getpid()))
file:close()
vim.uv.sleep(30000)
]]
			)
			p.guarded(dir, function()
				local completed
				local handle = require("lazyvcs.util").system_start(
					{ vim.v.progpath, "-ll", dir .. "/startup.lua" },
					{ cwd = dir, scope = "mutation", preserve_on_shutdown = true },
					function(_, _, raw)
						completed = raw
					end
				)
				local pid = handle.process.pid
				if delay == 0 then
					handle:cancel("startup")
				else
					vim.defer_fn(function()
						handle:cancel("startup")
					end, delay)
				end
				ctx.wait_for(function()
					return completed ~= nil
				end, "startup cancellation did not complete", 10000)
				assert(completed.cancelled, "startup cancellation lost its result")
				ctx.wait_for(function()
					return not p.alive(pid) and p.dead(dir)
				end, "startup cancellation leaked owned processes", 3000)
			end)
		end
	end

	local function completed_background()
		if vim.fn.has("win32") ~= 1 then
			error({ lazyvcs_skip = "native Windows process ownership" })
		end
		local p, dir = require("process_helpers"), h.tempdir()
		h.write_file(
			dir .. "/leaf.lua",
			[[
local uv = vim.uv
local file = assert(io.open("leaf.pid", "w"))
file:write(tostring(uv.os_getpid()))
file:close()
while not uv.fs_stat("release") do uv.sleep(10) end
local done = assert(io.open("leaf.done", "w")); done:write("done"); done:close()
]]
		)
		h.write_file(
			dir .. "/background.lua",
			[[
local uv = vim.uv
local child = assert(uv.spawn(arg[1], { args = { "-ll", arg[2] }, detached = true, stdio = {} }, function() end))
child:unref()
local deadline = uv.hrtime() + 5000000000
while not uv.fs_stat("leaf.pid") do assert(uv.hrtime() < deadline, "leaf did not start"); uv.sleep(10) end
os.exit(7)
]]
		)
		p.guarded(dir, function()
			local args, opts = require("lazyvcs.windows_process").wrap(
				{ vim.v.progpath, "-ll", dir .. "/background.lua", vim.v.progpath, dir .. "/leaf.lua" },
				{ cwd = dir, detach = true, stdout = false, stderr = false }
			)
			local result = vim.system(args, opts):wait(10000)
			assert(result and result.code == 7, "background command did not settle with exit7: " .. vim.inspect(result))
			assert(p.alive(p.pid(dir .. "/leaf.pid")), "normal completion killed intentional background work")
			h.write_file(dir .. "/release", "finish")
			ctx.wait_for(function()
				return vim.fn.filereadable(dir .. "/leaf.done") == 1 and p.dead(dir)
			end, "background command did not finish", 5000)
		end)
	end

	return {
		{ "test_source_control_windows_helper_completed_background_work", completed_background },
		{ "test_source_control_windows_helper_startup_cancellation", cancel_startup },
		{
			"test_source_control_windows_helper_binary_argument_parity",
			function()
				run(false, false)
			end,
		},
		{
			"test_source_control_windows_helper_streamed_stdin_parity",
			function()
				run(true, true)
			end,
		},
		{
			"test_source_control_windows_helper_missing_executable",
			function()
				local args, opts = require("lazyvcs.windows_process").wrap(
					{ "lazyvcs-command-does-not-exist-987654" },
					{}
				)
				local result = vim.system(args, opts):wait(10000)
				assert(
					result.code == 127 and result.stderr:find("Could not start background command", 1, true),
					vim.inspect(result)
				)
			end,
		},
		{
			"test_source_control_windows_helper_clear_env_inherits_without_overrides",
			function()
				local name = "LAZYVCS_TRANSPORT_TEST"
				local previous = vim.uv.os_getenv(name)
				vim.uv.os_setenv(name, "inherited")
				local dir = h.tempdir()
				local script = dir .. "/environment.lua"
				h.write_file(script, 'io.stdout:write(vim.uv.os_getenv("LAZYVCS_TRANSPORT_TEST") or "missing")')
				local args, opts = require("lazyvcs.windows_process").wrap(
					{ vim.v.progpath, "-ll", script },
					{ clear_env = true }
				)
				if previous then
					vim.uv.os_setenv(name, previous)
				else
					vim.uv.os_unsetenv(name)
				end
				local result = vim.system(args, opts):wait(10000)
				assert(result.code == 0 and result.stdout == "inherited", vim.inspect(result))
			end,
		},
	}
end
