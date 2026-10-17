return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	return {
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
