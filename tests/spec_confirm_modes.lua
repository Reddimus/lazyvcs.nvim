return function(ctx)
	return {
		{
			"test_source_control_confirmation_c_o_controls",
			function()
				local h, wait = ctx.helpers, ctx.wait_for
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				local errors = {}
				local child = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE" }, {
					rpc = true,
					on_stderr = function(_, lines)
						vim.list_extend(errors, lines)
					end,
				})
				assert(child > 0)
				local function exec(code, args)
					return vim.rpcrequest(child, "nvim_exec_lua", code, args or {})
				end
				local function input(keys)
					vim.rpcrequest(child, "nvim_input", keys)
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					exec(
						[[
						local root, file = ...
						vim.opt.runtimepath:prepend(root)
						vim.o.swapfile = false
						require('lazyvcs').setup({use_gitsigns=false, blame={mode='off',persist=false}})
						vim.cmd.edit(vim.fn.fnameescape(file))
						_G.source = vim.api.nvim_get_current_win()
						-- Record the delivered choice so cancelled cases need no timing window.
						local confirm = require('lazyvcs.source_control.confirm')
						local mutation = confirm.mutation
						confirm.mutation = function(opts, on_confirm, on_cancel)
							return mutation(opts, function(...)
								_G.choices[#_G.choices + 1] = 'confirm'
								if on_confirm then return on_confirm(...) end
							end, function(...)
								_G.choices[#_G.choices + 1] = 'cancel'
								if on_cancel then return on_cancel(...) end
							end)
						end
					]],
						{ root, f.file }
					)
					for _, case in ipairs({ { false, "<Esc>", false }, { true, "1", true }, { true, "<Esc>", false } }) do
						exec([[
							vim.api.nvim_buf_set_lines(0,0,-1,false,{'one','changed','three'})
							vim.api.nvim_win_set_cursor(0,{2,0})
							_G.ready=false
							_G.choices={}
							require('lazyvcs.signs').refresh(vim.api.nvim_get_current_buf(),true,function() _G.ready=true end)
						]])
						wait(function()
							return exec("return _G.ready")
						end, "child signs did not load", 15000)
						if case[1] then
							input("i")
							wait(function()
								return exec("return vim.api.nvim_get_mode().mode") == "i"
							end)
						end
						input((case[1] and "<C-o>" or "") .. ":LazyVCS hunk revert<CR>")
						wait(function()
							return exec("return vim.bo.buftype") == "nofile"
						end, "confirmation did not open", 15000)
						assert(
							exec("return vim.api.nvim_get_mode().mode") == "n",
							"C-o confirmation retained Insert mode"
						)
						local popup = exec("return vim.api.nvim_get_current_win()")
						input(case[2])
						wait(function()
							return not exec("return vim.api.nvim_win_is_valid(...)", { popup })
						end, "first confirmation key did not close popup")
						assert(
							exec("return vim.api.nvim_get_current_win() == _G.source"),
							"confirmation did not restore focus"
						)
						-- A confirmed revert applies after the base identity is checked again.
						local expected = { "one", case[3] and "two" or "changed", "three" }
						local function current()
							return exec("return vim.api.nvim_buf_get_lines(0,0,-1,false)")
						end
						local choice = case[3] and "confirm" or "cancel"
						wait(function()
							return exec("return _G.choices[1]") == choice
						end, "confirmation did not deliver " .. choice, 15000)
						assert(
							vim.deep_equal(exec("return _G.choices"), { choice }),
							"confirmation delivered more than one choice"
						)
						if case[3] then
							wait(function()
								return vim.deep_equal(current(), expected)
							end, "confirmed hunk revert was not applied", 15000)
						end
						assert(vim.deep_equal(current(), expected), "confirmation applied wrong hunk action")
					end
					local messages = exec("return vim.api.nvim_exec2('messages',{output=true}).output")
					assert(not (messages .. table.concat(errors, "\n")):find("E21", 1, true), "confirmation raised E21")
				end, debug.traceback)
				pcall(exec, "vim.cmd('qa!')")
				vim.fn.jobstop(child)
				assert(ok, err)
			end,
		},
	}
end
