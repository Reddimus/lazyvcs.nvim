vim.opt.runtimepath:prepend(arg[1])
vim.env.GIT_TERMINAL_PROMPT = "1"
local util = require("lazyvcs.util")
local done = false
local started = vim.uv.hrtime()
util.system_start({ "git", "-c", "credential.helper=", "-c", "core.askPass=", "credential", "fill" }, {
	stdin = "protocol=https\nhost=example.invalid\n\n",
	timeout_ms = 1200,
	kill_grace_ms = 10,
	env = { GIT_ASKPASS = "", SSH_ASKPASS = "" },
}, function(_, _, raw)
	raw.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
	vim.fn.writefile({ vim.json.encode(raw) }, arg[2])
	done = true
end)
assert(vim.wait(5000, function()
	return done
end, 10))
vim.cmd("qa!")
