return function(ctx)
	local h, api = ctx.helpers, vim.api
	local native, model = require("lazyvcs.source_control.native"), require("lazyvcs.source_control.model")
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			source_control = { remote_refresh = "manual", auto_expand_width = false },
		})
	end
	local function guarded(fn)
		return function()
			setup()
			local ok, err = xpcall(fn, debug.traceback)
			pcall(native.close)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			if not ok then
				error(err, 0)
			end
		end
	end
	local function open(root)
		local s = native.open({ path = root })
		ctx.wait_for(function()
			return not s.lazyvcs_discovering and not s.lazyvcs_hydration_active
		end, "sidebar status did not load", 15000)
		return s
	end
	local function key(s, lhs, predicate)
		if predicate then
			local found = false
			for line, node in ipairs(s.lazyvcs_line_nodes) do
				if predicate(node) then
					api.nvim_win_set_cursor(s.winid, { line, 0 })
					found = true
					break
				end
			end
			assert(found, "sidebar node not found")
		end
		for _, mapping in ipairs(api.nvim_buf_get_keymap(s.bufnr, "n")) do
			if mapping.lhs == lhs then
				return mapping.callback()
			end
		end
		error("sidebar mapping not found: " .. lhs)
	end
	local function details(s, root)
		key(s, "l", function(n)
			return n.type == "repo_changes" and n.path == root
		end)
		ctx.wait_for(function()
			return s.lazyvcs_repo_cache[root].details_loaded
		end, "details did not load", 15000)
		native.render(s)
	end
	local cases = {
		{
			"test_source_control_submodule_rows_open_readonly_patches",
			function()
				local f, child = h.make_git_fixture(), h.make_git_fixture()
				h.exec({ "git", "-c", "protocol.file.allow=always", "submodule", "add", child.root, "sm" }, f.root)
				h.exec({ "git", "commit", "-m", "submodule", "--", ".gitmodules", "sm" }, f.root)
				local old = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root .. "/sm"))
				h.exec({ "git", "commit", "-am", "advance submodule" }, child.root)
				local new = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, child.root))
				h.exec({ "git", "fetch", "origin" }, f.root .. "/sm")
				h.exec({ "git", "checkout", new }, f.root .. "/sm")
				for _, section in ipairs({ "changes", "staged" }) do
					if section == "staged" then
						h.exec({ "git", "add", "sm" }, f.root)
						h.exec({ "git", "submodule", "deinit", "-f", "--", "sm" }, f.root)
					end
					local s = open(f.root)
					details(s, f.root)
					key(s, "l", function(n)
						return n.type == "section" and n.extra.section_id == section and n.extra.repo_root == f.root
					end)
					local row
					for _, node in ipairs(s.lazyvcs_line_nodes) do
						if node.type == "file" and node.extra.relpath == "sm" and node.extra.section == section then
							row = node
						end
					end
					assert(row and row.extra.gitlink, "changed submodule row must retain gitlink identity")
					key(s, "<CR>", function(n)
						return n.id == row.id
					end)
					local session
					ctx.wait_for(function()
						for _, candidate in ipairs(require("lazyvcs.state").list()) do
							if candidate.root == f.root then
								session = candidate
							end
						end
						return session ~= nil
					end, "submodule patch did not open", 15000)
					assert(
						session.readonly_comparison and session.comparison.kind == "git_submodule",
						"submodule opened as editable blob"
					)
					local text = table.concat(api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), "\n")
					assert(
						text:find(old, 1, true) and text:find(new, 1, true),
						"submodule patch must include old and new commit IDs"
					)
					assert(
						vim.bo[session.editable_bufnr].filetype == "diff"
							and not vim.bo[session.editable_bufnr].modifiable
					)
					require("lazyvcs.actions").close(session.editable_bufnr)
					api.nvim_set_current_win(s.winid)
					native.close()
				end
			end,
		},

		{
			"test_source_control_sidebar_reopens_after_buffer_replacement",
			function()
				local f = h.make_git_fixture()
				local s = open(f.root)
				local replaced = s.winid
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				api.nvim_win_set_cursor(replaced, { 2, 1 })
				local ordinary = api.nvim_get_current_buf()
				vim.wo[replaced].number = true
				native.open({ path = f.root, focus = false })
				assert(api.nvim_win_get_buf(s.winid) == s.bufnr, "reopen must display the sidebar buffer")
				assert(
					s.winid ~= replaced and api.nvim_win_get_buf(replaced) == ordinary,
					"reopen replaced the ordinary file"
				)
				assert(
					api.nvim_get_current_win() == replaced and vim.wo[replaced].number,
					"reopen lost focus or user options"
				)
				assert(vim.deep_equal(api.nvim_win_get_cursor(replaced), { 2, 1 }))
				api.nvim_set_current_win(s.winid)
				native.close()
				assert(api.nvim_win_is_valid(replaced) and api.nvim_win_get_buf(replaced) == ordinary)
				s = open(f.root)
				api.nvim_set_current_win(s.winid)
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				replaced = s.winid
				native.toggle({ path = f.root })
				assert(
					native._state() == s and api.nvim_win_get_buf(s.winid) == s.bufnr,
					"toggle must restore a displaced sidebar"
				)
				assert(api.nvim_win_is_valid(replaced))
			end,
		},
		{
			"test_source_control_sidebar_close_cancels_target",
			function()
				local backends = require("lazyvcs.backends")
				local original = backends.load_diff_target_async
				local ok, err = xpcall(function()
					for _, reason in ipairs({ "q", "tab", "path", "buffer", "active" }) do
						local f = h.make_git_fixture()
						vim.cmd.tabnew()
						local s = open(f.root)
						details(s, f.root)
						key(s, "l", function(n)
							return n.type == "section" and n.extra.section_id == "changes"
						end)
						local deliver, cancelled
						---@diagnostic disable-next-line: duplicate-set-field
						backends.load_diff_target_async = function(target, done, opts)
							local task = original(target, function(loaded, load_err)
								deliver = function()
									done(loaded, load_err)
								end
							end, opts)
							return {
								cancel = function()
									cancelled = true
									task:kill()
								end,
							}
						end
						key(s, "<CR>", function(n)
							return n.type == "file"
						end)
						ctx.wait_for(function()
							return deliver ~= nil
						end, "target not loaded", 15000)
						if reason == "q" then
							key(s, "q")
						elseif reason == "tab" then
							vim.cmd.tabclose()
						elseif reason == "path" then
							native.open({ path = h.make_git_fixture().root })
						elseif reason == "buffer" then
							vim.cmd.edit(vim.fn.fnameescape(f.file))
						end
						vim.wait(20)
						local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
						deliver()
						if reason == "active" then
							assert(#require("lazyvcs.state").list() > 0, "active owner must open its comparison")
							require("lazyvcs.actions").close()
						else
							assert(cancelled, "sidebar " .. reason .. " must cancel its target loader")
							assert(s.lazyvcs_diff_target_task == nil and s.lazyvcs_diff_target_root == nil)
							assert(
								api.nvim_get_current_win() == win and api.nvim_get_current_buf() == buf,
								"late target changed editor contents or focus"
							)
							for _, session in ipairs(require("lazyvcs.state").list()) do
								assert(session.root ~= f.root, "closed owner opened a session")
							end
						end
						native.close()
						vim.cmd("silent! tabonly!")
					end
				end, debug.traceback)
				backends.load_diff_target_async = original
				if not ok then
					error(err, 0)
				end
			end,
		},
		{
			"test_source_control_pending_target_preserves_originating_tab",
			function()
				local backends = require("lazyvcs.backends")
				local original = backends.load_diff_target_async
				local ok, err = xpcall(function()
					for _, repurpose in ipairs({ false, true }) do
						local f = h.make_git_fixture()
						local s = open(f.root)
						details(s, f.root)
						key(s, "l", function(n)
							return n.type == "section" and n.extra.section_id == "changes"
						end)
						local editor, origin = s.editor_winid, s.tabid
						local deliver
						---@diagnostic disable-next-line: duplicate-set-field
						backends.load_diff_target_async = function(target, done, opts)
							return original(target, function(loaded, load_err)
								deliver = function()
									done(loaded, load_err)
								end
							end, opts)
						end
						key(s, "<CR>", function(n)
							return n.type == "file"
						end)
						ctx.wait_for(function()
							return deliver ~= nil
						end, "target not loaded", 15000)
						if repurpose then
							api.nvim_win_set_buf(editor, api.nvim_create_buf(true, false))
						end
						vim.cmd.tabnew()
						local other, win, buf =
							api.nvim_get_current_tabpage(), api.nvim_get_current_win(), api.nvim_get_current_buf()
						deliver()
						assert(
							api.nvim_get_current_tabpage() == other
								and api.nvim_get_current_win() == win
								and api.nvim_get_current_buf() == buf,
							"pending target must not replace another tab or steal focus"
						)
						local found
						for _, session in ipairs(require("lazyvcs.state").list()) do
							if session.root == f.root then
								found = session
							end
						end
						if repurpose then
							assert(not found, "repurposed destination must reject pending open")
						else
							assert(
								found
									and api.nvim_win_get_tabpage(found.editable_win) == origin
									and found.editable_win == editor,
								"comparison must use captured editor"
							)
						end
						if found then
							require("lazyvcs.actions").close(found.editable_bufnr)
						end
						api.nvim_set_current_tabpage(origin)
						native.close()
						vim.cmd("silent! tabonly!")
					end
				end, debug.traceback)
				backends.load_diff_target_async = original
				if not ok then
					error(err, 0)
				end
			end,
		},

		{
			"test_source_control_discovery_includes_enclosing_repository",
			function()
				local f, child = h.make_git_fixture(), h.make_git_fixture()
				h.exec(
					{ "git", "-c", "protocol.file.allow=always", "submodule", "add", child.root, "src/vendor" },
					f.root
				)
				h.write_file(f.root .. "/src/ordinary.txt", "enclosing\n")
				local function check(repos)
					local roots = {}
					for _, repo in ipairs(repos) do
						roots[repo.root] = (roots[repo.root] or 0) + 1
					end
					assert(
						roots[f.root] == 1 and roots[f.root .. "/src/vendor"] == 1 and #repos == 2,
						"discovery must include enclosing and nested roots exactly once: " .. vim.inspect(roots)
					)
				end
				check(model.discover(f.root .. "/src", 3))
				local done
				model.discover_async(f.root .. "/src", 3, function(repos)
					done = repos
				end, { entry_budget = 1 })
				ctx.wait_for(function()
					return done ~= nil
				end, "discovery did not finish", 15000)
				check(done)
				check(open(f.root .. "/src").lazyvcs_repo_specs)
				native.close()
				check(open(f.root).lazyvcs_repo_specs)
				local called = false
				local task = model.discover_async(f.root, 3, function()
					called = true
				end, { entry_budget = 1 })
				task:kill()
				vim.wait(20)
				assert(not called, "cancelled discovery published results")
			end,
		},
		{
			"test_svn_source_control_discovery_includes_enclosing_repository",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/src", "p")
				h.exec({ "svn", "add", f.root .. "/src" }, f.root)
				h.exec({ "svn", "commit", "-m", "directory", f.root .. "/src" }, f.root)
				vim.fn.mkdir(f.root .. "/src/vendor", "p")
				h.exec({ "git", "init", "-q", f.root .. "/src/vendor" }, f.root)
				local function check(repos)
					local roots = {}
					for _, repo in ipairs(repos) do
						roots[repo.root] = repo.vcs
					end
					assert(
						#repos == 2 and roots[f.root] == "svn" and roots[f.root .. "/src/vendor"] == "git",
						"SVN discovery omitted enclosing working copy"
					)
				end
				check(model.discover(f.root .. "/src", 3))
				local done
				model.discover_async(f.root .. "/src", 3, function(repos)
					done = repos
				end)
				ctx.wait_for(function()
					return done ~= nil
				end, "discovery did not finish", 15000)
				check(done)
				check(open(f.root .. "/src").lazyvcs_repo_specs)
			end,
		},

		{
			"test_source_control_sidebar_escapes_control_filenames",
			function()
				local f = h.make_git_fixture()
				local names =
					{ "a\nb.txt", "a\rb.txt", "a\tb.txt", "a\\nb.txt", "utf8-é.txt", "a\1b.txt", "a\127b.txt" }
				if vim.fn.has("win32") == 0 then
					for _, name in ipairs(names) do
						h.write_file(f.root .. "/" .. name, "raw\n")
					end
				end
				local s = open(f.root)
				details(s, f.root)
				if vim.fn.has("win32") == 1 then
					model.load_repo_details_async({ root = f.root, vcs = "git" }, {}, function(args, _, done)
						done({
							stdout = vim.tbl_contains(args, "-z") and ("?? " .. table.concat(names, "\0?? ") .. "\0")
								or "## main\n",
						})
					end, function(result)
						s.lazyvcs_repo_cache[f.root] = result
					end)
					native.render(s)
				end
				local ok, err = pcall(key, s, "l", function(n)
					return n.type == "section" and n.extra.section_id == "untracked"
				end)
				assert(ok, "control filenames must render without throwing: " .. tostring(err))
				local lines = api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
				local text = table.concat(lines, "\n")
				for _, label in ipairs({
					"a\\nb.txt",
					"a\\rb.txt",
					"a\\tb.txt",
					"utf8-é.txt",
					"a\\x01b.txt",
					"a\\x7fb.txt",
				}) do
					assert(text:find(label, 1, true), "escaped label missing: " .. label)
				end
				local paths = {}
				local escaped_newline_rows = 0
				for line, node in ipairs(s.lazyvcs_line_nodes) do
					if node.type == "file" then
						paths[node.extra.relpath] = node.path
						if node.extra.relpath == "a\nb.txt" or node.extra.relpath == "a\\nb.txt" then
							assert(lines[line]:find("a\\nb.txt", 1, true), "filename must occupy one escaped row")
							assert(
								not lines[line]:find("a\\\\nb.txt", 1, true),
								"literal backslash must remain unchanged"
							)
							escaped_newline_rows = escaped_newline_rows + 1
						end
					end
				end
				assert(escaped_newline_rows == 2, "newline and literal-backslash filenames must keep separate rows")
				for _, name in ipairs(names) do
					assert(paths[name] == f.root .. "/" .. name, "raw action path changed")
				end
				assert(
					require("lazyvcs.source_control.display").label("C:\\work\\sample.txt") == "C:\\work\\sample.txt"
				)
				assert(not vim.bo[s.bufnr].modifiable)
			end,
		},
		{
			"test_source_control_sidebar_render_failure_preserves_rows",
			function()
				local s = open(h.make_git_fixture().root)
				local old_write, util = api.nvim_buf_set_lines, require("lazyvcs.util")
				local old_notify, notices = util.notify, {}
				local nodes, text = s.lazyvcs_line_nodes, api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
				---@diagnostic disable-next-line: duplicate-set-field
				api.nvim_buf_set_lines = function(buf, ...)
					if buf == s.bufnr then
						error("forced\nrender failure")
					end
					return old_write(buf, ...)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(msg)
					notices[#notices + 1] = msg
				end
				local ok, err = pcall(native.render, s)
				api.nvim_buf_set_lines, util.notify = old_write, old_notify
				assert(ok, "render failure must be contained: " .. tostring(err))
				assert(
					not vim.bo[s.bufnr].modifiable and s.lazyvcs_line_nodes == nodes,
					"failed render changed row ownership"
				)
				assert(vim.deep_equal(text, api.nvim_buf_get_lines(s.bufnr, 0, -1, false)))
				assert(
					#notices == 1 and not notices[1]:find("\n", 1, true),
					"render failure must notify once on one line"
				)
			end,
		},
		{
			"test_source_control_tree_leaves_show_basenames_and_keep_targets",
			function()
				local f = h.make_git_fixture()
				local dir = "long_directory_name/nested_directory_name"
				vim.fn.mkdir(f.root .. "/" .. dir, "p")
				for _, name in ipairs({ "alpha.txt", "beta.txt" }) do
					h.write_file(f.root .. "/" .. dir .. "/" .. name, "leaf\n")
				end
				h.exec({ "git", "restore", "--", "sample.txt" }, f.root)
				h.exec({ "git", "mv", "sample.txt", dir .. "/renamed.txt" }, f.root)
				h.write_file(f.root .. "/root.txt", "root leaf\n")
				local s = open(f.root)
				details(s, f.root)
				key(s, "l", function(n)
					return n.type == "section" and n.extra.section_id == "untracked"
				end)
				key(s, "l", function(n)
					return n.type == "section" and n.extra.section_id == "staged"
				end)
				local list = {}
				for _, n in ipairs(s.lazyvcs_line_nodes) do
					if n.type == "file" then
						list[n.id] = { n.name, n.path, vim.deepcopy(n.extra) }
					end
				end
				key(s, "v")
				api.nvim_win_set_width(s.winid, 38)
				for _, compact in ipairs({ true, false }) do
					require("lazyvcs.config").get().source_control.compact_folders = compact
					for _ = 1, 3 do
						for _, n in ipairs(s.lazyvcs_line_nodes) do
							if n.type == "folder" then
								s.lazyvcs_expanded[n.id] = true
							end
						end
						native.render(s)
					end
					local text = table.concat(api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n")
					assert(
						text:find("alpha.txt", 1, true) and text:find("beta.txt", 1, true),
						"tree must show distinct basenames at width 38"
					)
					for _, n in ipairs(s.lazyvcs_line_nodes) do
						if n.type == "file" and list[n.id] then
							assert(
								n.name
									== (
										vim.fs.basename(n.extra.relpath)
										.. (n.extra.renamed_from and " <- " .. n.extra.renamed_from or "")
									),
								"tree leaf repeats directory prefix"
							)
							assert(
								n.path == list[n.id][2] and vim.deep_equal(n.extra, list[n.id][3]),
								"tree changed action metadata"
							)
						end
					end
				end
				key(s, "v")
				for _, n in ipairs(s.lazyvcs_line_nodes) do
					if list[n.id] then
						assert(n.name == list[n.id][1], "list labels changed after tree rendering")
					end
				end
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
