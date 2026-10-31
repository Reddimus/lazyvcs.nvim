return function()
	local cases = {}
	cases[#cases + 1] = {
		"test_config_a3_markdown_guard_ownership",
		function()
			local editor = require("lazyvcs.integrations.editor")
			local b = vim.api.nvim_create_buf(false, true)
			vim.bo[b].filetype = "markdown"
			vim.b[b].snacks_scope = true
			local a, c = editor.guard_markdown_buffer(b), editor.guard_markdown_buffer(b)
			editor.restore_buffer(a)
			assert(vim.b[b].snacks_scope == false, "surviving guard lost protection")
			editor.restore_buffer(a)
			editor.restore_buffer(c)
			assert(vim.b[b].snacks_scope == true, "last release lost original value")
			assert(vim.b[b].snacks_indent == nil, "last release invented a variable")
			vim.api.nvim_buf_delete(b, { force = true })
		end,
	}
	cases[#cases + 1] = {
		"test_config_a3_reserved_generation_keys",
		function()
			local config = require("lazyvcs.config")
			local original = config.get()
			for _, keys in ipairs({
				{ generate_key = "<CR>" },
				{ generate_key = "<C-M>" },
				{ generate_key = "q" },
				{ insert_generate_key = "<Esc>" },
				{ insert_generate_key = "<C-[>" },
			}) do
				assert(not pcall(config.setup, { ai = { commit_message = keys } }), "reserved popup control accepted")
				assert(config.get() == original, "failed validation replaced configuration")
			end
		end,
	}
	cases[#cases + 1] = {
		"test_config_a3_ex_search_completion",
		function()
			local complete = require("lazyvcs.commands")._complete
			for _, prefix in ipairs({
				"/LazyVCS/",
				"?Lazy?",
				"g/Lazy/",
				"edit Lazy.txt | ",
				"edit src/x.lua | ",
				"cd ~/proj | ",
				"s/a/b/ | ",
				"/a/,/Lazy/",
				"keepalt silent /Lazy/",
				"noautocmd keepjumps silent /Lazy/",
			}) do
				local line = prefix .. "LazyVCS bl"
				assert(vim.tbl_contains(complete("bl", line, #line), "blame"), line)
				line = prefix .. "LazyVCS blame se"
				assert(vim.tbl_contains(complete("se", line, #line), "selection"), line)
			end
		end,
	}
	cases[#cases + 1] = {
		"test_config_a3_cli_detection_does_not_require_plugin",
		function()
			local old = vim.fn.executable
			local original = package.preload.copilot
			local loaded = false
			package.preload.copilot = function()
				loaded = true
				return {}
			end
			---@diagnostic disable-next-line: duplicate-set-field
			vim.fn.executable = function()
				return 0
			end
			local ok, result = pcall(require("lazyvcs.integrations.optional").status)
			vim.fn.executable = old
			package.preload.copilot = original
			assert(ok, result)
			assert(not loaded, "CLI fallback required unrelated plugin")
			for _, item in ipairs(result.items) do
				if item.executable then
					assert(not item.available, item.key)
				end
			end
		end,
	}
	cases[#cases + 1] = {
		"test_config_a3_markdown_guard_restores_parser_after_last_owner",
		function()
			local editor = require("lazyvcs.integrations.editor")
			local b = vim.api.nvim_create_buf(false, true)
			vim.bo[b].filetype = "markdown"
			local start, stop = vim.treesitter.start, vim.treesitter.stop
			local active = vim.treesitter.highlighter.active
			local original = active[b]
			local starts, language = 0, nil
			---@type any
			local fake_highlighter = { tree = {
				lang = function()
					return "markdown"
				end,
			} }
			active[b] = fake_highlighter
			---@diagnostic disable-next-line: duplicate-set-field
			vim.treesitter.stop = function(buf)
				active[buf] = nil
			end
			---@diagnostic disable-next-line: duplicate-set-field
			vim.treesitter.start = function(_, lang)
				starts = starts + 1
				language = lang
			end
			local ok, err = xpcall(function()
				local a, c = editor.guard_markdown_buffer(b), editor.guard_markdown_buffer(b)
				assert(active[b] == nil)
				editor.restore_buffer(c)
				assert(starts == 0)
				editor.restore_buffer(a)
				assert(starts == 1 and language == "markdown")
				editor.restore_buffer(a)
				assert(starts == 1)
			end, debug.traceback)
			vim.treesitter.start, vim.treesitter.stop = start, stop
			active[b] = original
			vim.api.nvim_buf_delete(b, { force = true })
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_config_a3_sidebar_path_shorthand_opens",
		function()
			local api = require("lazyvcs")
			local open, toggle = api.source_control_open, api.source_control_toggle
			local util = require("lazyvcs.util")
			local path = util.normalize_literal_path(vim.fn.tempname())
			vim.fn.mkdir(path, "p")
			local opens, toggles = 0, 0
			---@diagnostic disable-next-line: duplicate-set-field
			api.source_control_open = function(opts)
				assert(opts.path == path)
				opens = opens + 1
			end
			---@diagnostic disable-next-line: duplicate-set-field
			api.source_control_toggle = function()
				toggles = toggles + 1
			end
			local ok, err = pcall(function()
				require("lazyvcs.commands").setup()
				for _ = 1, 2 do
					vim.cmd("LazyVCS sidebar " .. vim.fn.fnameescape(path))
				end
			end)
			api.source_control_open, api.source_control_toggle = open, toggle
			vim.fn.delete(path, "rf")
			assert(ok, err)
			assert(opens == 2 and toggles == 0, "path shorthand toggled sidebar closed")
		end,
	}
	return cases
end
