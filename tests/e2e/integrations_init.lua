-- Source the installed AstroNvim config, with startup installation disabled.
-- Unlike normal startup, `nvim -l` needs an explicit -u initializer.
local ok, err = xpcall(function()
	local path = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
	assert(vim.fn.filereadable(path .. "/lua/lazy/init.lua") == 1, "missing preinstalled lazy.nvim: " .. path)
	vim.opt.runtimepath:prepend(path)
	local available, lazy = pcall(require, "lazy")
	assert(available, "unable to load preinstalled lazy.nvim: " .. path)
	local setup = lazy.setup
	lazy.setup = function(spec, opts)
		lazy.setup = setup
		-- Support both lazy.setup(spec, opts) and lazy.setup({ spec = ... }).
		if type(spec) == "table" and spec.spec then
			opts, spec = spec, spec.spec
		end
		opts = vim.tbl_deep_extend("force", opts or {}, {
			install = { missing = false },
			checker = { enabled = false },
			change_detection = { enabled = false },
			pkg = { enabled = false },
			rocks = { enabled = false },
		})
		-- Keep the installed AstroNvim configuration, but exclude tool installers
		-- from this test. They can access the network on startup or FileType even
		-- when lazy.nvim's own installation and update checks are disabled.
		local offline = {}
		for _, name in ipairs({
			"nvim-treesitter",
			"mason.nvim",
			"mason-tool-installer.nvim",
			"mason-lspconfig.nvim",
			"mason-null-ls.nvim",
			"mason-nvim-dap.nvim",
		}) do
			offline[#offline + 1] = {
				name,
				optional = true,
				enabled = false,
			}
		end
		return setup({ spec, offline }, opts)
	end
	local init = vim.fn.stdpath("config") .. "/init.lua"
	assert(vim.fn.filereadable(init) == 1, "missing AstroNvim config: " .. init)
	dofile(init)
	assert(vim.g.lazy_did_setup, "AstroNvim config did not initialize lazy.nvim")
end, debug.traceback)

if not ok then
	io.stderr:write("integration startup failed: " .. tostring(err) .. "\n")
	vim.cmd("cquit 1")
end
