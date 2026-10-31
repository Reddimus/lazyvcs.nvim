local run_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo_root = vim.fn.fnamemodify(run_file, ":h:h")

local groups = {
	"core",
	"source_control",
	"blame_signs",
	"live_diff",
	"svn",
}

-- Run each subsystem in a fresh Neovim process. This prevents monkeypatches,
-- skipped external-tool tests, timers, buffers, and module state from leaking
-- into unrelated coverage while remaining portable across Unix and Windows.
if not vim.env.LAZYVCS_TEST_GROUP or vim.env.LAZYVCS_TEST_GROUP == "" then
	local failures = {}
	local function forward(output, captured)
		return function(err, data)
			assert(not err, err)
			if data then
				if captured then
					captured[#captured + 1] = data
				end
				output:write(data)
				output:flush()
			end
		end
	end
	for _, group in ipairs(groups) do
		print(string.format("\n===== lazyvcs test group: %s =====", group))
		local captured, captured_error = {}, {}
		local result = vim.system({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			-- Preserve the parent settings when exercising Windows-style defaults.
			"--cmd",
			"set fileformats=" .. vim.o.fileformats,
			"--cmd",
			vim.o.shellslash and "set shellslash" or "set noshellslash",
			"-l",
			run_file,
		}, {
			text = true,
			stdout = forward(io.stdout, captured),
			stderr = forward(io.stderr, captured_error),
			env = {
				LAZYVCS_TEST_GROUP = group,
			},
		}):wait(600000)
		local output = table.concat(captured) .. table.concat(captured_error)
		if
			result.code ~= 0
			or (result.signal or 0) ~= 0
			or not output:find("lazyvcs " .. group .. " tests:", 1, true)
			or not output:find("lazyvcs tests: ok", 1, true)
		then
			failures[#failures + 1] = group .. string.format(" (exit %s, signal %s)", result.code, result.signal or 0)
		end
	end

	if #failures > 0 then
		print("FAILED GROUPS: " .. table.concat(failures, ", "))
		vim.cmd("cquit 1")
	else
		print("\nlazyvcs isolated test groups: ok")
		vim.cmd("qa!")
	end
	return
end

vim.opt.runtimepath:prepend(repo_root)
local test_state_dir = vim.fs.normalize(vim.fn.tempname())
vim.env.XDG_STATE_HOME = test_state_dir
vim.env.XDG_CACHE_HOME = test_state_dir .. "/cache"
vim.env.HOME = test_state_dir .. "/home"
vim.env.APPDATA = test_state_dir .. "/home/AppData"
vim.fn.mkdir(vim.env.APPDATA, "p")
local case_cwd = test_state_dir .. "/cwd"
vim.fn.mkdir(case_cwd, "p")
vim.fn.chdir(case_cwd)
vim.api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.chdir(repo_root)
		vim.fn.delete(test_state_dir, "rf")
	end,
})
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	repo_root .. "/tests/?.lua",
	package.path,
}, ";")

require("spec")

if _G.LAZYVCS_TEST_FAILED then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
