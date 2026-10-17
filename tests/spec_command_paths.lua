return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	local function complete(lead)
		return require("lazyvcs.commands")._complete(lead, "LazyVCS sidebar open " .. lead)
	end
	local function directory_case(fn, unix_only)
		return function()
			if unix_only and vim.fn.has("win32") == 1 then
				error({ lazyvcs_skip = "Neovim expands ~user only on Unix" })
			end
			local cwd, ignore = vim.fn.getcwd(), vim.o.wildignore
			local fic, wic = vim.o.fileignorecase, vim.o.wildignorecase
			local dir = h.tempdir()
			vim.fn.mkdir(dir .. "/.git")
			vim.fn.mkdir(dir .. "/visible")
			vim.fn.mkdir(dir .. "/skip")
			vim.cmd.cd(dir)
			vim.o.wildignore = ""
			local ok, err = xpcall(function()
				fn(dir)
			end, debug.traceback)
			vim.cmd.cd(cwd)
			vim.o.wildignore = ignore
			vim.o.fileignorecase, vim.o.wildignorecase = fic, wic
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_directory_completion_hides_dot_names",
			directory_case(function()
				assert(vim.deep_equal(complete(""), { "skip/", "visible/" }), "empty prefix exposed .git")
				assert(vim.deep_equal(complete("."), { ".git/" }), "dot prefix hid .git")
			end),
		},
		{
			"test_core_directory_completion_respects_wildignore",
			directory_case(function(dir)
				for _, lead in ipairs({ "", dir .. "/" }) do
					for _, pattern in ipairs({ "skip/", "*/skip", "*/skip/*", "visible/", "*/visible/", "s*" }) do
						vim.o.wildignore = pattern
						local expected = vim.fn.getcompletion(lead, "dir", true)
						table.sort(expected)
						assert(
							vim.deep_equal(complete(lead), expected),
							pattern .. ": wildignore differs from Vim for " .. lead
						)
					end
				end
			end),
		},
		{
			"test_core_directory_completion_wildignore_uses_fileignorecase",
			directory_case(function(dir)
				vim.fn.mkdir(dir .. "/MiXeD")
				for _, lead in ipairs({ "", dir .. "/" }) do
					for _, pattern in ipairs({ "mixed/", "*/mixed", "*/mixed/", "*/mixed/*" }) do
						vim.o.wildignore = pattern
						for _, fic in ipairs({ false, true }) do
							for _, wic in ipairs({ false, true }) do
								vim.o.fileignorecase, vim.o.wildignorecase = fic, wic
								local expected = vim.fn.getcompletion(lead, "dir", true)
								table.sort(expected)
								assert(
									vim.deep_equal(complete(lead), expected),
									pattern
										.. ": completion differs with fileignorecase="
										.. tostring(fic)
										.. " wildignorecase="
										.. tostring(wic)
								)
							end
						end
					end
				end
			end),
		},
		{
			"test_core_named_home_expansion_ignores_wildignore",
			directory_case(function()
				local user = assert(vim.uv.os_get_passwd()).username
				local home = vim.fn.expand("~" .. user, true)
				assert(home ~= "" and home ~= "~" .. user, "current user home did not resolve")
				vim.o.wildignore = "*"
				assert(vim.fn.expand("~" .. user) == "", "wildignore fixture did not suppress expand")
				assert(
					util.expand_user_path("~" .. user .. "/project") == home:gsub("[/\\]$", "") .. "/project",
					"wildignore rewrote named home to the filesystem root"
				)
			end, true),
		},
		{
			"test_core_named_home_empty_expansion_preserves_argument",
			function()
				local expand = vim.fn.expand
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.expand = function(path, ...)
					if path == "~lazyvcs_missing_user" then
						return ""
					end
					return expand(path, ...)
				end
				local ok, result = pcall(util.expand_user_path, "~lazyvcs_missing_user/project")
				vim.fn.expand = expand
				assert(ok, result)
				assert(result == "~lazyvcs_missing_user/project", "empty home rewrote path")
			end,
		},
		{
			"test_core_directory_completion_expands_named_home",
			directory_case(function(dir)
				local expand = vim.fn.expand
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.expand = function(path, ...)
					if path == "~lazyvcs_test_user" then
						return dir
					end
					return expand(path, ...)
				end
				local ok, result = pcall(complete, "~lazyvcs_test_user/vis")
				vim.fn.expand = expand
				assert(ok, result)
				assert(vim.deep_equal(result, { dir .. "/visible/" }), "named home completion was lost")
			end),
		},
		{
			"test_core_directory_completion_protects_environment_dollars",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local native = require("lazyvcs.source_control.native")
				local saved = vim.env.LAZYVCS_PATH_DEST
				vim.env.LAZYVCS_PATH_DEST = "OTHER"
				local ok, err = xpcall(function()
					local parent, f, other = h.tempdir(), h.make_git_fixture(), h.make_git_fixture()
					local target = parent .. "/cash$LAZYVCS_PATH_DEST"
					assert(vim.uv.fs_rename(f.root, target))
					assert(vim.uv.fs_rename(other.root, parent .. "/cashOTHER"))
					vim.fn.mkdir(target .. "/child space")
					h.write_file(target .. "/literal-only", "selected repository\n")
					local function submit(argument, expected)
						vim.api.nvim_feedkeys(
							vim.api.nvim_replace_termcodes(
								":LazyVCS sidebar open " .. argument .. "<CR>",
								true,
								false,
								true
							),
							"xt",
							false
						)
						local state = assert(native._state())
						assert(state.path == expected, "completion expanded a literal dollar: " .. state.path)
						ctx.wait_for(function()
							return not state.lazyvcs_discovering and state.lazyvcs_repo_specs
						end, "discovery did not finish", 15000)
						assert(state.lazyvcs_repo_specs[1].root == target, "wrong completed repository")
						assert(vim.uv.fs_stat(state.lazyvcs_repo_specs[1].root .. "/literal-only"))
						native.close()
					end
					submit(parent .. "/cas<Tab>", target)
					submit(parent .. "/cas<Tab>chi<Tab>", target .. "/child space")
					vim.api.nvim_create_user_command("LazyVCSPathProbe", function(args)
						assert(#args.fargs == 1)
						_G.lazyvcs_path_probe = util.expand_user_path(args.fargs[1])
					end, { nargs = "*" })
					for _, pair in ipairs({
						{ "$LAZYVCS_PATH_DEST", "OTHER" },
						{ "$$LAZYVCS_PATH_DEST", "$LAZYVCS_PATH_DEST" },
						{ "$$$LAZYVCS_PATH_DEST", "$OTHER" },
						{ [[C:\src\$LAZYVCS_PATH_DEST]], [[C:\src\OTHER]] },
						{ [[C:\src\$$LAZYVCS_PATH_DEST]], [[C:\src\$LAZYVCS_PATH_DEST]] },
					}) do
						vim.cmd("LazyVCSPathProbe " .. pair[1])
						assert(_G.lazyvcs_path_probe == pair[2], "native argument dollar grammar changed")
					end
					vim.env.LAZYVCS_PATH_DEST = "$HOME"
					assert(util.expand_user_path("$LAZYVCS_PATH_DEST") == "$HOME", "substitution was rescanned")
				end, debug.traceback)
				vim.env.LAZYVCS_PATH_DEST = saved
				pcall(vim.api.nvim_del_user_command, "LazyVCSPathProbe")
				_G.lazyvcs_path_probe = nil
				pcall(native.close)
				assert(ok, err)
			end,
		},
	}
end
