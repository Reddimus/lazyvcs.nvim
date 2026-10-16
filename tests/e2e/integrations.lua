local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fn.fnamemodify(script, ":h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local function run()
	local api = vim.api
	local plugins = vim.env.LAZYVCS_INTEGRATION_PLUGINS or (vim.fn.stdpath("data") .. "/lazy")
	for _, name in ipairs({
		"plenary.nvim",
		"nui.nvim",
		"neo-tree.nvim",
		"astrocore",
		"AstroNvim",
	}) do
		local path = plugins .. "/" .. name
		assert(vim.fn.isdirectory(path) == 1, "missing preinstalled integration plugin: " .. name)
		vim.opt.runtimepath:append(path)
	end
	assert(
		package.loaded.lazy and vim.g.lazy_did_setup,
		"lazy.nvim is unavailable; start with -u tests/e2e/integrations_init.lua"
	)
	local available, lazy_config = pcall(require, "lazy.core.config")
	assert(available, "lazy.nvim configuration is unavailable; AstroNvim startup failed")
	assert(lazy_config.plugins.AstroNvim and lazy_config.plugins.AstroNvim._.loaded, "AstroNvim did not finish startup")
	assert(
		not lazy_config.options.install.missing
			and not lazy_config.options.checker.enabled
			and not lazy_config.options.change_detection.enabled,
		"integration startup must disable plugin installation and update checks"
	)
	require("lazy").load({ plugins = { "neo-tree.nvim", "lazyvcs.nvim" } })
	local h = require("helpers")
	local util, state = require("lazyvcs.util"), require("lazyvcs.state")
	local options = dofile(plugins .. "/AstroNvim/lua/astronvim/plugins/resession.lua").opts
	options.dir = "lazyvcs-integration"
	options.options =
		{ "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "wrap", "winbar", "winhighlight" }
	-- Let lazy.nvim configure Resession on its first require, as AstroNvim does.
	local spec = assert(lazy_config.plugins["resession.nvim"], "missing lazy Resession spec")
	assert(spec._.installed, "missing preinstalled integration plugin: resession.nvim")
	assert(spec.lazy, "AstroNvim Resession spec must be lazy")
	assert(not package.loaded.resession, "Resession loaded before the live diff test")
	spec.opts = options
	spec.config = true
	require("lazyvcs").setup({
		use_gitsigns = false,
		signs = { enabled = false },
		source_control = { remote_refresh = "manual" },
	})
	local manifest = assert(vim.env.LAZYVCS_INTEGRATION_STATE, "integration state path is required")
	local backend = assert(vim.env.LAZYVCS_INTEGRATION_BACKEND, "integration backend is required")
	local mode = assert(vim.env.LAZYVCS_INTEGRATION_MODE, "integration mode is required")
	local name = "lazyvcs-" .. backend
	local function wait(predicate, message)
		assert(vim.wait(15000, predicate, 10), message)
	end
	local function snapshot(win)
		return util.capture_win_options(win, options.options)
	end
	if mode == "load" then
		local saved = vim.json.decode(table.concat(vim.fn.readfile(manifest), "\n"))
		for _, session_name in ipairs({ name .. "-first", name }) do
			---@diagnostic disable-next-line: different-requires
			require("resession").load(session_name, { reset = true })
			assert(#state.list() == 0, "load recreated a live diff session")
			local found = 0
			for _, win in ipairs(api.nvim_list_wins()) do
				local buf = api.nvim_win_get_buf(win)
				assert(not api.nvim_buf_get_name(buf):match("^lazyvcs://"), "temporary base was restored")
				if vim.fs.normalize(api.nvim_buf_get_name(buf)) == saved.file then
					found = found + 1
					assert(
						not vim.wo[win].diff and not vim.wo[win].scrollbind,
						session_name .. ": restored editor has diff or scrollbind enabled"
					)
					assert(vim.deep_equal(snapshot(win), saved.options), "restored editor has transient diff options")
					assert(
						vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), saved.lines),
						"restored contents changed"
					)
				end
			end
			assert(found == 1, "expected one restored file window")
			print("PASS integration " .. backend .. " Resession fresh-process load " .. session_name)
		end
		return
	end
	assert(mode == "save", "invalid integration mode")
	local f = backend == "svn" and h.make_svn_fixture() or h.make_git_fixture()
	local function copy_tree(source, destination)
		vim.fn.mkdir(destination, "p")
		for entry, kind in vim.fs.dir(source) do
			local from, to = source .. "/" .. entry, destination .. "/" .. entry
			if kind == "directory" then
				copy_tree(from, to)
			else
				assert(vim.uv.fs_copyfile(from, to))
			end
		end
	end
	local stable = vim.fs.normalize(manifest .. ".fixture")
	vim.fn.delete(stable, "rf")
	copy_tree(f.root, stable)
	f.file, f.root = stable .. "/" .. vim.fs.basename(f.file), stable

	vim.cmd.edit(vim.fn.fnameescape(f.file))
	local editor = api.nvim_get_current_win()
	api.nvim_set_hl(0, "@lsp.type.lazyvcs_resession", { fg = 0xff0000 })
	util.set_win_option(editor, "winhighlight", "Normal:ErrorMsg,@lsp.type.lazyvcs_resession:Comment")
	local before = snapshot(editor)
	require("neo-tree").setup({
		enable_git_status = false,
		enable_diagnostics = false,
		filesystem = { use_libuv_file_watcher = false },
	})
	require("neo-tree.command").execute({ action = "show", source = "filesystem", position = "left", dir = f.root })
	local neo, neo_buf
	for _, win in ipairs(api.nvim_list_wins()) do
		local buf = api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "neo-tree" then
			neo, neo_buf = win, buf
		end
	end
	assert(neo, "Neo-tree did not open")
	api.nvim_set_current_win(neo)
	local native = require("lazyvcs.source_control.native")
	local sidebar = native.open({ path = f.root })
	wait(function()
		return sidebar.lazyvcs_repo_cache[f.root] and sidebar.lazyvcs_repo_cache[f.root].summary_loaded
	end, "sidebar summary did not load")
	local function activate(predicate)
		for line, node in ipairs(sidebar.lazyvcs_line_nodes) do
			if predicate(node) then
				api.nvim_set_current_win(sidebar.winid)
				api.nvim_win_set_cursor(sidebar.winid, { line, 0 })
				local mapping = vim.fn.maparg("<CR>", "n", false, true)
				assert(mapping.callback, "missing sidebar Enter mapping")()
				return
			end
		end
		error("sidebar row was not rendered")
	end
	activate(function(node)
		return node.type == "repo_changes"
	end)
	wait(function()
		return sidebar.lazyvcs_repo_cache[f.root].details_loaded
	end, "sidebar details did not load")
	for _, node in ipairs(sidebar.lazyvcs_line_nodes) do
		if node.type == "section" then
			sidebar.lazyvcs_expanded[node.id] = true
		end
	end
	native.render(sidebar)
	assert(not package.loaded.resession, "Resession loaded before opening the live diff")
	activate(function(node)
		return node.type == "file"
	end)
	wait(function()
		return #state.list() == 1
	end, "sidebar diff did not open")
	vim.wait(100, function()
		return false
	end)
	local s = state.list()[1]
	assert(s.editable_win == editor, "sidebar selected Neo-tree instead of eligible editor")
	assert(
		api.nvim_win_get_buf(neo) == neo_buf and api.nvim_win_get_buf(sidebar.winid) == sidebar.bufnr,
		"sidebar buffers changed"
	)
	assert(
		api.nvim_win_get_buf(s.editable_win) == s.editable_bufnr and api.nvim_win_get_buf(s.base_win) == s.base_bufnr,
		"diff pane identity changed"
	)
	print("PASS integration " .. backend .. " real Neo-tree sidebar open")
	local lines = api.nvim_buf_get_lines(s.editable_bufnr, 0, -1, false)
	native.close()
	require("neo-tree.command").execute({ action = "close" })
	for _, tab in ipairs(api.nvim_list_tabpages()) do
		vim.t[tab].bufs = { s.editable_bufnr }
	end
	local live = snapshot(editor)
	assert(tostring(live.winhighlight):find("LazyVcsSemanticHidden", 1, true), "fixture has no active semantic overlay")
	assert(spec._.loaded, "lazy.nvim did not load Resession for the live diff")
	-- This is the user's first require: save immediately, before LazyLoad can run.
	---@diagnostic disable-next-line: different-requires
	require("resession").save(name .. "-first", { notify = false })
	assert(vim.deep_equal(snapshot(editor), live), "first-require save changed live diff options")
	print("PASS integration " .. backend .. " real Resession first-require save")
	---@diagnostic disable-next-line: different-requires
	local resession = require("resession")
	local save, save_tab, save_all = resession.save, resession.save_tab, resession.save_all
	for _, base_focus in ipairs({ false, true }) do
		api.nvim_set_current_win(base_focus and s.base_win or editor)
		resession.save(name, { notify = false })
		assert(vim.deep_equal(snapshot(editor), live), "save changed live diff options")
		assert(state.get(s.editable_bufnr) == s and s.phase == "active", "save replaced live diff session")
	end
	resession.save_tab(name .. "-tab", { notify = false })
	resession.save_all({ notify = false })
	assert(vim.deep_equal(snapshot(editor), live), "tab saves changed live diff options")
	assert(
		resession.save == save and resession.save_tab == save_tab and resession.save_all == save_all,
		"Resession public API was replaced"
	)
	h.write_file(manifest, vim.json.encode({ file = vim.fs.normalize(f.file), options = before, lines = lines }))
	print("PASS integration " .. backend .. " real Resession save from both panes")
	local files = require("resession.files")
	for _, session_name in ipairs({ name .. "-first", name, name .. "-tab" }) do
		local path = require("resession.util").get_session_file(session_name)
		local serialized = assert(files.read_file(path), "session file was not written")
		assert(not serialized:find("LazyVcsSemanticHidden", 1, true), "session file contains semantic overlay")
		assert(serialized:find("Normal:ErrorMsg", 1, true), "session file lost user winhighlight mapping")
	end
	print("PASS integration " .. backend .. " real Resession serialized user winhighlight without overlay")
	local write = files.write_json_file
	files.write_json_file = function()
		error("forced integration write failure")
	end
	local saved = pcall(resession.save, name .. "-failed", { notify = false })
	files.write_json_file = write
	assert(not saved, "write failure did not propagate")
	wait(function()
		return s.phase == "active"
	end, "failed save left options projected")
	assert(vim.deep_equal(snapshot(editor), live), "failed save did not restore live diff options")
	print("PASS integration " .. backend .. " real Resession write-failure recovery")
	-- Readonly targets always use scratch buffers, even with a real source path.
	require("lazyvcs.actions").close(s.editable_bufnr)
	local readonly = assert(require("lazyvcs.actions").open_target({
		backend = backend,
		root = f.root,
		path = f.file,
		relpath = vim.fs.basename(f.file),
		kind = backend .. "_revision",
		left = { label = "BEFORE", lines = { "before" } },
		right = { label = "AFTER", lines = { "after" } },
	}))
	assert(readonly.readonly_comparison, "fixture is not a readonly comparison")
	assert(
		tostring(snapshot(readonly.editable_win).winhighlight):find("LazyVcsSemanticHidden", 1, true),
		"readonly fixture has no semantic overlay"
	)
	for _, win in ipairs({ readonly.editable_win, readonly.base_win }) do
		local buf = api.nvim_win_get_buf(win)
		assert(vim.bo[buf].buftype == "nofile" and not vim.bo[buf].buflisted, "readonly pane is not scratch")
		assert(not resession.default_buf_filter(buf), "default Resession filter accepts readonly pane")
	end
	print("PASS integration " .. backend .. " readonly overlay panes rejected by default Resession filter")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
