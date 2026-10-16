return function(ctx)
	local api, h = vim.api, ctx.helpers
	local align, state = require("lazyvcs.align"), require("lazyvcs.state")
	local function padding(s)
		local count = 0
		for _, buf in ipairs({ s.base_bufnr, s.editable_bufnr }) do
			for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, align.namespace(), 0, -1, { details = true })) do
				count = count + #(mark[4].virt_lines or {})
			end
		end
		return count
	end
	local function guarded(fn)
		return function()
			local diffopt, columns, lines = vim.o.diffopt, vim.o.columns, vim.o.lines
			local schedule = align.schedule
			local ok, err = xpcall(fn, debug.traceback)
			align.schedule = schedule
			h.cleanup()
			vim.cmd("silent! only!")
			vim.o.diffopt, vim.o.columns, vim.o.lines = diffopt, columns, lines
			assert(ok, err)
		end
	end
	local function open(wrap)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			base_window = { align_wrapped = "auto" },
		})
		vim.opt.diffopt:append("followwrap")
		vim.o.columns, vim.o.lines = 100, 30
		local f = h.make_git_fixture()
		h.write_file(f.file, string.rep("\t", 40) .. "base\nnext\nlast\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "wrapped base" }, f.root)
		h.write_file(f.file, string.rep("x", 100) .. "\nnext\nlast\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		require("lazyvcs.util").editor_window(api.nvim_get_current_win())
		vim.bo.tabstop, vim.bo.vartabstop = 8, ""
		vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = wrap, false, false
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		ctx.wait_for(function()
			return state.get(buf) ~= nil
		end, "alignment session did not open", 15000)
		local s = assert(state.get(buf))
		-- Drain initial resize and alignment work before changing geometry.
		vim.wait(100, function()
			return false
		end)
		return s
	end
	local function set(win, command)
		api.nvim_win_call(win, function()
			vim.cmd("setlocal " .. command)
		end)
	end
	local cases = {
		{
			"test_live_diff_nowrap_clears_alignment_padding",
			function()
				local s = open(true)
				assert(padding(s) > 0, "fixture has no wrapped padding")
				local text, modified = {}, {}
				for _, buf in ipairs({ s.base_bufnr, s.editable_bufnr }) do
					text[buf], modified[buf] = api.nvim_buf_get_lines(buf, 0, -1, false), vim.bo[buf].modified
				end
				set(s.base_win, "nowrap")
				set(s.editable_win, "nowrap")
				ctx.wait_for(function()
					return padding(s) == 0
				end, "nowrap left virtual alignment rows")
				for _, win in ipairs({ s.base_win, s.editable_win }) do
					local buf = api.nvim_win_get_buf(win)
					assert(#api.nvim_buf_get_extmarks(buf, align.namespace(), 0, -1, {}) == 0)
					assert(
						api.nvim_win_text_height(win, { start_row = 0, end_row = 2 }).all == 3,
						"nowrap retained padded text height"
					)
					assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), text[buf]))
					assert(vim.bo[buf].modified == modified[buf] and vim.wo[win].diff)
				end
				assert(state.get(s.editable_bufnr) == s and s.phase == "active")
			end,
		},
		{
			"test_live_diff_wrap_options_refresh_owned_alignment",
			function()
				local s = open(false)
				assert(padding(s) == 0)
				set(s.base_win, "wrap")
				ctx.wait_for(function()
					return padding(s) > 0
				end, "enabling base wrap did not add padding")
				local before = padding(s)
				set(s.editable_win, "wrap")
				ctx.wait_for(function()
					return padding(s) ~= before
				end, "editable wrap did not update padding")
				before = padding(s)
				set(s.base_win, "tabstop=16")
				ctx.wait_for(function()
					return padding(s) ~= before
				end, "base tabstop did not update padding")
				before = padding(s)
				set(s.base_win, "vartabstop=2")
				ctx.wait_for(function()
					return padding(s) ~= before
				end, "base vartabstop did not update padding")
				api.nvim_set_current_win(s.editable_win)
				vim.cmd("belowright new")
				vim.wait(100, function()
					return false
				end)
				local schedule, calls = align.schedule, 0
				---@diagnostic disable-next-line: duplicate-set-field
				align.schedule = function(live)
					calls = calls + 1
					schedule(live)
				end
				vim.cmd("setlocal wrap! linebreak! breakindent!")
				assert(calls == 0, "unrelated window scheduled owned alignment")
				align.schedule = schedule
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
