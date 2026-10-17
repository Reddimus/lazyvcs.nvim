return function(ctx)
	local h, config = ctx.helpers, require("lazyvcs.config")
	return {
		{
			"test_core_directory_completion_roundtrips_windows_backslashes",
			function()
				local received
				local path = [[C:\space repo\C#App\100%repo\]]
				vim.api.nvim_create_user_command("LazyVCSCompletionProbe", function(args)
					received = args.fargs
				end, { nargs = "*" })
				local ok, err = pcall(function()
					local candidates = { require("lazyvcs.command_path").escape(path) }
					vim.cmd("LazyVCSCompletionProbe " .. candidates[1])
					assert(vim.deep_equal(received, { path }), "Windows completion did not round-trip through <f-args>")
				end)
				vim.api.nvim_del_user_command("LazyVCSCompletionProbe")
				assert(ok, err)
			end,
		},
		{
			"test_core_profile_displays_multiline_errors",
			function()
				local f = h.make_git_fixture()
				local jobs = require("lazyvcs.source_control.jobs")
				jobs.clear_history()
				local done
				jobs.command(
					{ root = f.root, vcs = "git" },
					"buffer",
					{ "git", "show", "missing-revision" },
					{},
					function()
						done = true
					end
				)
				ctx.wait_for(function()
					return done
				end, "failed job history", 15000)
				local history = jobs.history()
				assert(history[#history].error:find("\n"), "fixture did not produce multiline diagnostics")
				require("lazyvcs.commands").setup()
				local ok, err = pcall(function()
					vim.cmd("LazyVCS profile")
				end)
				assert(ok, "profile failed on multiline error: " .. tostring(err))
				local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
				for _, line in ipairs(require("lazyvcs.util").split_lines(history[#history].error)) do
					assert(rendered:find("  " .. line, 1, true), "profile lost diagnostic line")
				end
				vim.cmd.close()
			end,
		},
		{
			"test_core_mutation_timeout_requires_positive_integer_result",
			function()
				config.setup({ source_control = { background = { mutation_timeout_ms = 123 } } })
				for _, value in ipairs({ 0, -1, 0.5 }) do
					local ok =
						pcall(config.setup, { source_control = { background = { mutation_timeout_ms = value } } })
					assert(not ok, "accepted mutation timeout " .. value)
					assert(
						config.get().source_control.background.mutation_timeout_ms == 123,
						"rejected setup changed config"
					)
				end
				assert(
					config.setup({ source_control = { background = { mutation_timeout_ms = 1.9 } } }).source_control.background.mutation_timeout_ms
						== 1
				)
			end,
		},
		{
			"test_sign_priority_is_clamped_and_rendered",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { sign_priority = 65536 } })
				assert(config.get().signs.sign_priority == 65535, "sign priority exceeded Neovim limit")
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local signs, done, err = require("lazyvcs.signs"), false, nil
				signs.refresh(0, true, function(_, failure)
					err, done = failure, true
				end)
				ctx.wait_for(function()
					return done
				end, "native sign refresh", 15000)
				assert(not err, err)
				local marks = vim.api.nvim_buf_get_extmarks(0, signs._test_state().namespace, 0, -1, { details = true })
				assert(#marks > 0 and marks[1][4].priority == 65535, "native sign was not rendered at clamped priority")
			end,
		},
		{
			"test_sign_glyph_validation_matches_extmark_constraints",
			function()
				for _, name in ipairs({ "add", "change", "delete", "topdelete", "changedelete" }) do
					for _, value in ipairs({ "ADDED", "\n", "\r", "\t", "\1", "界界", string.char(255) }) do
						local ok, err = pcall(config.setup, { signs = { text = { [name] = value } } })
						assert(
							not ok and tostring(err):find(name, 1, true),
							"accepted invalid signs.text." .. name .. "=" .. vim.inspect(value)
						)
					end
				end
				local buf = vim.api.nvim_create_buf(false, true)
				local ns = vim.api.nvim_create_namespace("lazyvcs_glyph_regression")
				local ok, err = pcall(function()
					for _, value in ipairs({ "", " ", "+", "++", "界", "é" }) do
						config.setup({ signs = { text = { change = value } } })
						vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { sign_text = value })
					end
				end)
				vim.api.nvim_buf_delete(buf, { force = true })
				assert(ok, err)
			end,
		},
		{
			"test_core_directory_completion_preserves_fargs_characters",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual" },
				})
				local native = require("lazyvcs.source_control.native")
				local ok, err = pcall(function()
					for _, name in ipairs({
						"space repo",
						"C#App",
						"100%repo",
						"cash$repo",
						"[repo]",
						"quote'repo",
						"bang!repo",
					}) do
						local root, f = h.tempdir(), h.make_git_fixture()
						local target = vim.fs.normalize(root .. "/" .. name)
						assert(vim.uv.fs_rename(f.root, target))
						local prefix = root .. "/" .. name:sub(1, 2)
						local candidates =
							require("lazyvcs.commands")._complete(prefix, "LazyVCS sidebar open " .. prefix)
						assert(#candidates == 1, "missing directory candidate: " .. name)
						for _, argument in ipairs({ prefix .. "<Tab>", candidates[1] }) do
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
							local state = assert(native._state(), "completed command did not open sidebar")
							assert(
								vim.fs.normalize(state.path) == target,
								"completion changed directory: " .. name .. " -> " .. state.path
							)
							ctx.wait_for(function()
								return not state.lazyvcs_discovering and state.lazyvcs_repo_specs ~= nil
							end, "completed repository discovery", 15000)
							assert(
								state.lazyvcs_repo_specs[1]
									and vim.fs.normalize(state.lazyvcs_repo_specs[1].root) == target,
								"completion did not discover selected repository"
							)
							native.close()
						end
					end
				end)
				pcall(native.close)
				assert(ok, err)
			end,
		},
		{
			"test_core_display_truncation_bounds_combining_prefix_work",
			function()
				local util = require("lazyvcs.util")
				local text = "A" .. string.rep("́", 32000) .. "1234567890"
				local part, calls = vim.fn.strcharpart, 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.strcharpart = function(...)
					calls = calls + 1
					assert(calls <= 64, "display truncation rescans growing prefixes")
					return part(...)
				end
				local ok, result = pcall(util.truncate_display, text, 8)
				vim.fn.strcharpart = part
				assert(ok, result)
				assert(
					result == "A" .. string.rep("́", 32000) .. "1234...",
					"display truncation changed combining text or ellipsis budget"
				)
				assert(util.truncate_display("界abc", 1) == "")
				assert(util.truncate_display("界abc", 2) == "界")
			end,
		},
	}
end
