local root, mode = arg[1], arg[2]
vim.env.LAZYVCS_TEST_GROUP = nil
if mode == "cwd" then
	vim.env.LAZYVCS_TEST_GROUP = "core"
	package.preload.spec = function()
		assert(vim.uv.cwd() ~= root, "runner retained checkout cwd")
		assert(vim.env.HOME:find(vim.env.XDG_STATE_HOME, 1, true) == 1, "runner retained real HOME")
		assert(vim.env.APPDATA:find(vim.env.XDG_STATE_HOME, 1, true) == 1, "runner retained real APPDATA")
		return {}
	end
else
	vim.system = function(_, opts)
		local group = opts.env.LAZYVCS_TEST_GROUP
		if mode ~= "incomplete" then
			local emit = mode == "stderr" and opts.stderr or opts.stdout
			emit(nil, "lazyvcs " .. group .. " te")
			emit(nil, "sts: 1 passed, 0 skipped, 0 failed\nlazyvcs tests: ok\n")
		end
		return {
			wait = function(_, timeout)
				if mode == "timeout" then
					assert(timeout and timeout > 0, "runner has no deadline")
				end
				return { code = 0, signal = mode == "signal" and 9 or 0 }
			end,
		}
	end
end
dofile(root .. "/tests/run.lua")
