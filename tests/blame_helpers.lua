local M = {}
function M.new(ctx)
	local api, h = vim.api, ctx.helpers
	local t = { api = api, h = h, wait = ctx.wait_for, patches = {}, notices = {}, cleanups = {} }
	function t.patch(object, key, value)
		t.patches[#t.patches + 1] = { object, key, object[key] }
		object[key] = value
	end
	function t.guard(fn)
		return function()
			local cwd = vim.fn.getcwd()
			t.notices = {}
			t.patch(require("lazyvcs.util"), "notify", function(message)
				t.notices[#t.notices + 1] = message
			end)
			local ok, err = xpcall(fn, debug.traceback)
			for _, cleanup in ipairs(t.cleanups) do
				pcall(cleanup)
			end
			t.cleanups = {}
			for i = #t.patches, 1, -1 do
				local p = t.patches[i]
				p[1][p[2]] = p[3]
			end
			t.patches = {}
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.cmd.cd(vim.fn.fnameescape(cwd))
			h.cleanup()
			vim.v.errmsg = ""
			assert(ok, err)
		end
	end
	function t.open(svn, opts)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false, delay_ms = 20, loading_delay_ms = 5, max_width = 200 },
		}, opts or {}))
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local backend = assert(require("lazyvcs.backends").resolve(f.file))
		return f, api.nvim_get_current_buf(), api.nvim_get_current_win(), backend
	end
	function t.inline(buf)
		local state = require("lazyvcs.blame")._test_inline_state()
		local marks = api.nvim_buf_get_extmarks(buf, state.namespace, 0, -1, { details = true })
		return marks[1], state.views[buf]
	end
	function t.loaded(buf)
		t.wait(function()
			local _, view = t.inline(buf)
			return view and view.entries ~= nil
		end, "inline blame did not load", 15000)
		return t.inline(buf)
	end
	function t.cases(cases)
		for _, case in ipairs(cases) do
			case[2] = t.guard(case[2])
		end
		return cases
	end
	return t
end
return M
