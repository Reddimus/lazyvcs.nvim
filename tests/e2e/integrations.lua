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
		"resession.nvim",
		"astrocore",
		"AstroNvim",
	}) do
		local path = plugins .. "/" .. name
		assert(vim.fn.isdirectory(path) == 1, "missing preinstalled integration plugin: " .. name)
		vim.opt.runtimepath:append(path)
	end
	if package.loaded.lazy then
		require("lazy").load({ plugins = { "neo-tree.nvim", "resession.nvim", "lazyvcs.nvim" } })
	end
	local h = require("helpers")
	local util, state = require("lazyvcs.util"), require("lazyvcs.state")
	---@type table
	---@diagnostic disable-next-line: different-requires
	local resession = require("resession")
	local options = dofile(plugins .. "/AstroNvim/lua/astronvim/plugins/resession.lua").opts
	options.dir = "lazyvcs-integration"
	options.options = { "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "wrap", "winbar" }
	resession.setup(options)
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
		resession.load(name, { reset = true })
		assert(#state.list() == 0, "load recreated a live diff session")
		local found = 0
		for _, win in ipairs(api.nvim_list_wins()) do
			local buf = api.nvim_win_get_buf(win)
			assert(not api.nvim_buf_get_name(buf):match("^lazyvcs://"), "temporary base was restored")
			if vim.fs.normalize(api.nvim_buf_get_name(buf)) == saved.file then
				found = found + 1
				assert(vim.deep_equal(snapshot(win), saved.options), "restored editor has transient diff options")
				assert(
					vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), saved.lines),
					"restored contents changed"
				)
			end
		end
		assert(found == 1, "expected one restored file window")
		print("PASS integration " .. backend .. " Resession fresh-process load")
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
	api.nvim_set_current_win(editor)
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
	assert(s.editable_win == editor, "sidebar selected Neo-tree instead of recorded editor")
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
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
