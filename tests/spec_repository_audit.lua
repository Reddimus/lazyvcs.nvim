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
	-- List the key paths where two option tables differ.
	local function drift(a, b, prefix, out)
		out = out or {}
		if type(a) ~= "table" or type(b) ~= "table" or vim.islist(a) or vim.islist(b) then
			if not vim.deep_equal(a, b) then
				out[#out + 1] = string.format("%s: doc %s, config %s", prefix, vim.inspect(a), vim.inspect(b))
			end
			return out
		end
		local keys = vim.tbl_keys(vim.tbl_extend("force", {}, a, b))
		table.sort(keys)
		for _, key in ipairs(keys) do
			drift(a[key], b[key], prefix == "" and key or prefix .. "." .. key, out)
		end
		return out
	end
	return {
		{
			"test_core_documented_defaults_match_config",
			function()
				local doc = read("doc/lazyvcs.txt")
				local tag = assert(doc:find("*lazyvcs-defaults*", 1, true), "doc has no *lazyvcs-defaults* block")
				local _, open = assert(doc:find("\n>lua\n", tag, true))
				local close = assert(doc:find("\n<\n", open, true))
				local block = doc:sub(open + 1, close)
				local chunk, count = block:gsub('require%("lazyvcs"%)%.setup%(', "return (", 1)
				assert(count == 1, 'defaults block must be a require("lazyvcs").setup({ ... }) call')
				local documented = assert(load(chunk, "=lazyvcs-defaults"))()
				-- A fresh module instance holds the untouched defaults.
				local defaults = assert(loadfile(root .. "/lua/lazyvcs/config.lua"))().get()
				local differences = drift(documented, defaults, "")
				assert(#differences == 0, "doc defaults drifted:\n" .. table.concat(differences, "\n"))
			end,
		},
		{
			"test_core_readme_and_help_install_specs_match",
			function()
				local readme, doc = read("README.md"), read("doc/lazyvcs.txt")
				local _, intro = readme:find("With lazy.nvim:\n\n```lua\n", 1, true)
				assert(intro, "README install spec not found")
				local readme_spec = readme:sub(intro + 1, assert(readme:find("\n```", intro, true)))
				local _, start = doc:find("Minimal lazy.nvim or AstroNvim spec", 1, true)
				assert(start, "help install spec not found")
				local _, open = assert(doc:find("\n>lua\n", start, true))
				local doc_spec = doc:sub(open + 1, assert(doc:find("\n<\n", open, true)))
				local function evaluate(text, name)
					return assert(load("return " .. text, "=" .. name))()
				end
				assert(
					vim.deep_equal(evaluate(readme_spec, "README"), evaluate(doc_spec, "lazyvcs.txt")),
					"README.md and doc/lazyvcs.txt install specs differ"
				)
			end,
		},
		{
			"test_core_changelog_versions_have_link_references",
			function()
				local changelog = read("CHANGELOG.md")
				local base = "https://github.com/Reddimus/lazyvcs.nvim/"
				local versions, refs, problems = {}, {}, {}
				for line in vim.gsplit(changelog, "\n", { plain = true }) do
					local version = line:match("^## %[(%d+%.%d+%.%d+)%] %- %d%d%d%d%-%d%d%-%d%d$")
					if version then
						versions[#versions + 1] = version
					elseif line:match("^## %[") and not line:match("^## %[Unreleased%]$") then
						problems[#problems + 1] = "malformed heading: " .. line
					end
					local name, url = line:match("^%[([^%]]+)%]: (%S+)$")
					if name then
						refs[name] = url
					end
				end
				assert(#versions > 0, "no release headings found")
				local function expect(name, url)
					if refs[name] ~= url then
						problems[#problems + 1] =
							string.format("[%s] should link to %s, found %s", name, url, tostring(refs[name]))
					end
				end
				expect("Unreleased", base .. "compare/v" .. versions[1] .. "...HEAD")
				for index, version in ipairs(versions) do
					local older = versions[index + 1]
					expect(
						version,
						older and string.format("%scompare/v%s...v%s", base, older, version)
							or base .. "releases/tag/v" .. version
					)
				end
				assert(#problems == 0, table.concat(problems, "\n"))
			end,
		},
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
