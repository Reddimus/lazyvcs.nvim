return function(ctx)
	local api, h = vim.api, ctx.helpers
	local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = { "test_live_diff_" .. name, fn }
	end
	local function fixture(opts)
		require("lazyvcs").setup(
			vim.tbl_deep_extend(
				"force",
				{ use_gitsigns = false, signs = { enabled = false }, base_window = { cursor_sync = false } },
				opts or {}
			)
		)
		local f = h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		return f, ctx.open_diff()
	end
	local function confirm()
		api.nvim_feedkeys(api.nvim_replace_termcodes("1", true, false, true), "xt", false)
	end
	for _, operation in ipairs({ "revert", "navigate" }) do
		add("inherited_split_" .. operation .. "_uses_invoking_cursor", function()
			local f = h.make_git_transfer_fixture()
			local lines = {}
			for i = 1, 60 do
				lines[i] = "line " .. i
			end
			h.write_file(f.file1, table.concat(lines, "\n") .. "\n")
			h.exec({ "git", "add", "." }, f.root)
			lines[40], lines[44] = "changed forty", "changed forty-four"
			h.write_file(f.file1, table.concat(lines, "\n") .. "\n")
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				base_window = {
					cursor_sync = false,
				},
			})
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local s = ctx.open_diff()
			api.nvim_win_set_cursor(s.editable_win, { 40, 0 })
			vim.cmd.split()
			local split = api.nvim_get_current_win()
			api.nvim_win_set_cursor(split, { 44, 0 })
			if operation == "navigate" then
				actions.prev_hunk()
				assert(
					api.nvim_get_current_win() == split and api.nvim_win_get_cursor(split)[1] == 40,
					"navigation used owner window"
				)
			else
				actions.revert_hunk()
				confirm()
				ctx.wait_for(function()
					return api.nvim_buf_get_lines(s.editable_bufnr, 43, 44, false)[1] == "line 44"
				end, "invoking hunk was not reverted")
				assert(
					api.nvim_buf_get_lines(s.editable_bufnr, 39, 40, false)[1] == "changed forty",
					"owner hunk was reverted"
				)
			end
		end)
	end
	add("refresh_during_transfer_is_retained_on_return", function()
		local f, s = fixture()
		h.write_file(f.file1, "new staged\ntwo\nthree\nfour\nfive\n")
		h.exec({ "git", "add", "alpha.txt" }, f.root)
		local backends = require("lazyvcs.backends")
		local base, load = backends.load_base_async, backends.load_async
		local finish
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_base_async = function(path, done)
			return base(path, function(result, err)
				finish = function()
					done(result, err)
				end
			end)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function()
			return { kill = function() end }
		end
		local ok, err = xpcall(function()
			actions.refresh_current()
			ctx.wait_for(function()
				return finish
			end, "refresh not held")
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			ctx.wait_for(function()
				return s.phase == "loading"
			end, "transfer not loading")
			finish()
			assert(
				api.nvim_buf_get_lines(s.base_bufnr, 0, 1, false)[1] == "Loading comparison...",
				"refresh replaced transfer presentation"
			)
			vim.cmd.buffer(s.editable_bufnr)
			ctx.wait_for(function()
				return s.phase == "active"
			end, "return not active")
			ctx.wait_for(function()
				return s.base_lines[1] == "new staged"
			end, "refresh was lost on return")
		end, debug.traceback)
		backends.load_base_async, backends.load_async = base, load
		assert(ok, err)
	end)
	add("transfer_mirrors_incoming_wrap_options", function()
		local diffopt = vim.o.diffopt
		vim.opt.diffopt:append("followwrap")
		local f, s = fixture()
		for _, w in ipairs({ s.editable_win, s.base_win }) do
			vim.wo[w].wrap = false
			vim.wo[w].linebreak = false
			vim.wo[w].breakindent = false
		end
		local id = api.nvim_create_autocmd("BufWinEnter", {
			pattern = f.file2,
			callback = function()
				vim.wo.wrap = true
				vim.wo.linebreak = true
				vim.wo.breakindent = true
			end,
		})
		local ok, err = xpcall(function()
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			ctx.wait_for(function()
				return state.get(api.nvim_get_current_buf()) ~= nil
			end, "transfer not finished")
			for _, key in ipairs({ "wrap", "linebreak", "breakindent" }) do
				assert(vim.wo[s.base_win][key], "base did not mirror " .. key)
			end
		end, debug.traceback)
		api.nvim_del_autocmd(id)
		vim.o.diffopt = diffopt
		assert(ok, err)
	end)
	for _, mode in ipairs({ "wrong_base", "wrong_revision", "unknown_base", "wrong_hunk", "matching", "eof" }) do
		add("gitsigns_revert_" .. mode, function()
			local _, s = fixture({ use_gitsigns = true })
			local old = package.loaded.gitsigns
			local calls = 0
			vim.b[s.editable_bufnr].gitsigns_status_dict = {}
			local gs_hunk = {
				removed = { start = 2, count = 1, lines = { "two" } },
				added = { start = 2, count = 1, lines = {
					"changed",
				} },
			}
			if mode == "wrong_base" then
				gs_hunk.removed.lines = { "HEAD content" }
			end
			if mode == "wrong_hunk" then
				gs_hunk.removed.start = 1
			end
			if mode == "eof" then
				gs_hunk.removed.no_nl_at_eof = true
			end
			package.loaded.gitsigns = {
				get_hunks = function()
					return { gs_hunk }
				end,
				reset_hunk = function()
					calls = calls + 1
					api.nvim_buf_set_lines(s.editable_bufnr, 1, 2, false, gs_hunk.removed.lines)
				end,
			}
			local cache = package.loaded["gitsigns.cache"]
			package.loaded["gitsigns.cache"] = {
				cache = {
					[s.editable_bufnr] = {
						git_obj = { revision = (mode == "wrong_base" or mode == "wrong_revision") and "HEAD" or nil },
					},
				},
			}
			if mode == "unknown_base" then
				package.loaded["gitsigns.cache"] = nil
			end
			local ok, err = xpcall(function()
				api.nvim_win_set_cursor(s.editable_win, { 2, 0 })
				actions.revert_hunk()
				confirm()
				ctx.wait_for(function()
					return api.nvim_buf_get_lines(s.editable_bufnr, 1, 2, false)[1] == "two"
				end, "revert did not use index")
				assert(calls == 0, "live reset delegated cursor-based hunk selection: " .. calls)
			end, debug.traceback)
			package.loaded.gitsigns = old
			package.loaded["gitsigns.cache"] = cache
			assert(ok, err)
		end)
	end
	return cases
end
