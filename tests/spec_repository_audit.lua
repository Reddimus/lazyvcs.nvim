-- Static checks over the checkout: runtime conventions and documentation.
return function()
	local compat = assert(vim.api.nvim_get_runtime_file("lua/lazyvcs/compat.lua", false)[1])
	local root = vim.fs.normalize(vim.fn.fnamemodify(compat, ":p:h:h:h"))
	local function read(relpath)
		local handle = assert(io.open(root .. "/" .. relpath, "rb"))
		local text = handle:read("*a")
		handle:close()
		return (text:gsub("\r\n", "\n"))
	end
	-- Return the argument text of each call to `name`, balancing parentheses.
	local function calls(text, name)
		local out, init = {}, 1
		while true do
			local start, finish = text:find(name .. "(", init, true)
			if not start then
				return out
			end
			local depth, index = 1, finish + 1
			while depth > 0 and index <= #text do
				local char = text:sub(index, index)
				depth = depth + (char == "(" and 1 or char == ")" and -1 or 0)
				index = index + 1
			end
			out[#out + 1] = text:sub(finish + 1, index - 2)
			init = index
		end
	end
	return {
		{
			"test_core_buffer_mappings_use_compat_helper",
			function()
				local offenders = {}
				local files = vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)
				assert(#files > 20, "runtime Lua files not found under " .. root)
				for _, path in ipairs(files) do
					path = vim.fs.normalize(path)
					local relpath = path:sub(#root + 2)
					if relpath ~= "lua/lazyvcs/compat.lua" then
						local text = read(relpath)
						for _, name in ipairs({ "vim.keymap.set", "vim.keymap.del" }) do
							for _, args in ipairs(calls(text, name)) do
								if args:find("buffer%s*=") then
									offenders[#offenders + 1] = relpath .. ": " .. name
								end
							end
						end
					end
				end
				assert(#offenders == 0, "use compat.keymap_set/keymap_del: " .. table.concat(offenders, ", "))
			end,
		},
	}
end
