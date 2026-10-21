-- Windows tree commands need a hidden console and reliable descendant cleanup.
-- A Neovim helper owns that lifetime; only preserved commands detach.
local M = {}
local sequence = 0
local child = vim.fn
	.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
	:gsub("windows_process.lua$", "windows_process_child.lua")

function M.wrap(args, opts)
	sequence = sequence + 1
	local prefix = "LAZYVCS_PROCESS_" .. vim.fn.getpid() .. "_" .. sequence .. "_"
	local function occupied()
		for _, values in ipairs({ vim.fn.environ(), opts.env or {} }) do
			for name in pairs(values) do
				if name:upper():sub(1, #prefix) == prefix then
					return true
				end
			end
		end
		return false
	end
	while occupied() do
		sequence = sequence + 1
		prefix = "LAZYVCS_PROCESS_" .. vim.fn.getpid() .. "_" .. sequence .. "_"
	end
	local source_env = opts.env or (opts.clear_env and vim.fn.environ()) or {}
	local env = vim.tbl_extend("force", source_env, { [prefix .. 0] = tostring(#args) })
	local executable = vim.fn.exepath(args[1])
	for i, arg in ipairs(args) do
		local value = i == 1 and executable ~= "" and executable or arg
		-- A nonempty sentinel preserves empty arguments on Windows too.
		env[prefix .. i] = "x" .. value
	end
	-- Neovim before 0.11.3 passed clear_env directly to libuv, which expects
	-- an array rather than the map accepted by newer vim.system versions.
	if opts.clear_env and vim.fn.has("nvim-0.11.3") == 0 then
		local entries = {}
		for name, value in pairs(env) do
			entries[#entries + 1] = name .. "=" .. tostring(value)
		end
		env = entries
	end
	local wrapped = vim.tbl_extend("force", opts, { env = env })
	return { vim.v.progpath, "-ll", child, prefix }, wrapped
end

return M
