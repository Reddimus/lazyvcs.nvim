return function(ctx)
	local h, api = ctx.helpers, vim.api
	local S = { signs = require("lazyvcs.signs"), h = h, api = api, wait = ctx.wait_for }
	function S.fixture(svn, options)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { debounce_ms = 5 },
			source_control = { confirm_mutations = false },
		}, options or {}))
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		return f, api.nvim_get_current_buf()
	end
	function S.refresh(buf, reload)
		local done, state, err
		S.signs.refresh(buf, reload, function(value, why)
			done, state, err = true, value, why
		end)
		ctx.wait_for(function()
			return done
		end, "sign refresh did not complete", 15000)
		return state, err
	end
	function S.marks(buf)
		return api.nvim_buf_get_extmarks(buf, S.signs._test_state().namespace, 0, -1, { details = true })
	end
	function S.edit(buf, lines)
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	end
	function S.guard(fn)
		return function()
			local backends = require("lazyvcs.backends")
			local config = require("lazyvcs.config")
			local settings = vim.deepcopy(config.get())
			local load, resolve = backends.load_base_async, backends.resolve_async
			local timer, notify, open, work = vim.uv.new_timer, vim.notify, api.nvim_open_win, vim.uv.new_work
			local errmsg = vim.v.errmsg
			local gs, hidden, rows = package.loaded.gitsigns, vim.o.hidden, vim.o.lines
			local preload = package.preload.gitsigns
			local ok, err = xpcall(fn, debug.traceback)
			backends.load_base_async, backends.resolve_async = load, resolve
			vim.uv.new_timer, vim.notify, api.nvim_open_win, vim.uv.new_work = timer, notify, open, work
			package.loaded.gitsigns, vim.o.hidden, vim.o.lines = gs, hidden, rows
			package.preload.gitsigns = preload
			config.setup(settings)
			pcall(h.cleanup)
			vim.cmd("silent! only!")
			vim.v.errmsg = errmsg
			assert(ok, err)
		end
	end
	return S
end
