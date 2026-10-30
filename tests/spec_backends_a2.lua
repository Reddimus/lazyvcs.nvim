return function(ctx)
	local h, api = ctx.helpers, vim.api
	local backends = require("lazyvcs.backends")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = { name, fn }
	end
	local function await(start)
		local done, value, failure
		start(function(result, err)
			value, failure, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "backend request did not finish", 15000)
		return assert(value, failure)
	end
	local function bytes(path, value)
		local file = assert(io.open(path, "wb"))
		file:write(value)
		file:close()
	end
	local function setup(opts)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { enabled = false, debounce_ms = 0 },
			blame = { persist = false },
		}, opts or {}))
	end
	local function open(path)
		if api.nvim_buf_get_name(0) ~= path then
			vim.cmd.edit(vim.fn.fnameescape(path))
		end
		vim.cmd("LazyVCS diff open")
		local buf = api.nvim_get_current_buf()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf)
		end, "live diff did not open", 15000)
		return require("lazyvcs.state").get(buf)
	end
	local function snapshot(f, revision)
		return { root = f.root, vcs = "svn", url = h.file_url(f.repo), revision = revision or "1" }
	end
	local function list(f, untracked, revision, recovery)
		local common = require("lazyvcs.backends.comparison")
		local command = common.command
		if recovery then
			---@diagnostic disable-next-line: duplicate-set-field
			common.command = function(task, repo, args, done, opts)
				if vim.tbl_contains(args, "--summarize") and args[#args] == f.root .. "@" then
					vim.schedule(function()
						if task:is_active() then
							done(nil, "svn: E145001: Can only get the pristine contents of files")
						end
					end)
					return
				end
				return command(task, repo, args, done, opts)
			end
		end
		local ok, result = xpcall(function()
			return await(function(done)
				require("lazyvcs.backends.compare_svn").list(snapshot(f, revision), untracked, done)
			end)
		end, debug.traceback)
		common.command = command
		assert(ok, result)
		return result
	end

	add("test_live_diff_git_removed_cached_root_recovers", function()
		setup()
		local f = h.make_git_fixture()
		local inner = f.root .. "/nested"
		vim.fn.mkdir(inner)
		local path = inner .. "/file.txt"
		h.write_file(path, "outer base")
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "outer file" }, f.root)
		h.exec({ "git", "init" }, inner)
		h.exec({ "git", "add", "." }, inner)
		backends.invalidate()
		assert(await(function(done)
			backends.load_base_async(path, done)
		end).root == inner)
		vim.fn.delete(inner, "rf")
		local result = await(function(done)
			backends.load_base_async(path, done)
		end)
		assert(result.root == f.root and result.base_bytes == "outer base\n", "obsolete nested root survived")
		local _, cached = backends.resolve_cached(path)
		assert(cached == f.root)
		assert(open(path).base_lines[1] == "outer base")
	end)

	add("test_svn_incoming_final_newline_documents", function()
		setup()
		local actions = require("lazyvcs.actions")
		for _, pair in ipairs({
			{ "same\n", "same" },
			{ "same", "same\n" },
			{ "", "\n" },
			{ "\n", "" },
			{ "same\r\n", "same\n" },
			{ "one\n", "two\n" },
		}) do
			local f = h.make_svn_fixture()
			bytes(f.file, pair[1])
			h.exec({ "svn", "commit", "-m", "base" }, f.root)
			h.exec({ "svn", "update" }, f.root)
			local other = h.tempdir() .. "/other"
			h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
			bytes(other .. "/sample.txt", pair[2])
			h.exec({ "svn", "commit", "-m", "incoming" }, other)
			local item = await(function(done)
				require("lazyvcs.source_control.model").load_repo_details_async(
					{ root = f.root, vcs = "svn" },
					{ remote_refresh = true },
					function(args, _, cb)
						return require("lazyvcs.util").system_start(args, { cwd = f.root }, cb)
					end,
					function(model, err)
						if not model then
							return done(nil, err)
						end
						for _, section in ipairs(model.sections) do
							if section.id == "remote" then
								for _, row in ipairs(section.items) do
									if row.extra.relpath == "sample.txt" then
										return done(row)
									end
								end
							end
						end
						done(nil, "incoming row missing")
					end
				)
			end)
			local result = await(function(done)
				backends.load_diff_target_async(item, done)
			end)
			local session = assert(actions.open_target(result))
			assert(#session.hunks == 1, "incoming byte change disappeared")
			assert(vim.bo[session.base_bufnr].endofline == (pair[1]:sub(-1) == "\n"))
			assert(vim.bo[session.editable_bufnr].endofline == (pair[2]:sub(-1) == "\n"))
			actions.close(session)
		end
	end)

	add("test_live_diff_svn_deleted_parent_base", function()
		setup()
		local f = h.make_svn_fixture()
		vim.fn.mkdir(f.root .. "/dir/deep", "p")
		local path = f.root .. "/dir/deep/child.txt"
		h.write_file(path, "base")
		h.exec({ "svn", "add", "dir" }, f.root)
		h.exec({ "svn", "commit", "-m", "nested" }, f.root)
		vim.cmd.edit(vim.fn.fnameescape(path))
		api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved" })
		h.exec({ "svn", "delete", "dir" }, f.root)
		local svn = require("lazyvcs.backends.svn")
		backends.invalidate()
		assert(await(function(done)
			backends.load_base_async(path, done)
		end).base_bytes == "base\n")
		for _, opts in ipairs({ {}, { root = f.root } }) do
			assert(await(function(done)
				svn.load_base_async(path, done, opts)
			end).base_bytes == "base\n")
		end
		assert(svn.probe(path).root == f.root)
		assert(assert(svn.load_base(path)).base_bytes == "base\n")
		assert(open(path).base_lines[1] == "base")
	end)

	add("test_svn_replacement_base_ignores_diagnostic_language", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "delete", "--force", f.file }, f.root)
		h.write_file(f.file, "replacement")
		h.exec({ "svn", "add", f.file }, f.root)
		local util, process = require("lazyvcs.util"), require("lazyvcs.backends.process")
		local system, read = util.system, process.bytes
		local translated = "svn: E200009: Datei hat keinen ursprünglichen Dateiinhalt"
		---@diagnostic disable-next-line: duplicate-set-field
		util.system = function(args, opts)
			local result, err, raw = system(args, opts)
			if not result and vim.tbl_contains(args, "cat") then
				err = translated
			end
			return result, err, raw
		end
		---@diagnostic disable-next-line: duplicate-set-field
		process.bytes = function(args, opts, done)
			return read(args, opts, function(result, err, raw)
				if not result and vim.tbl_contains(args, "cat") then
					err = translated
				end
				done(result, err, raw)
			end)
		end
		local ok, err = xpcall(function()
			local svn = require("lazyvcs.backends.svn")
			assert(assert(svn.load_base(f.file)).base_label == "EMPTY")
			assert(await(function(done)
				backends.load_base_async(f.file, done)
			end).base_label == "EMPTY")
			h.exec({ "svn", "revert", f.file }, f.root)
			h.exec({ "svn", "copy", f.file, f.root .. "/copy.txt" }, f.root)
			h.exec({ "svn", "commit", "-m", "copy" }, f.root)
			h.exec({ "svn", "delete", "--force", f.file }, f.root)
			h.exec({ "svn", "copy", f.root .. "/copy.txt", f.file }, f.root)
			assert(assert(svn.load_base(f.file)).base_bytes ~= "")
			assert(await(function(done)
				backends.load_base_async(f.file, done)
			end).base_bytes ~= "")
		end, debug.traceback)
		util.system, process.bytes = system, read
		assert(ok, err)
	end)

	add("test_svn_compare_file_externals_preserve_parent_deletion", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "revert", f.file }, f.root)
		h.exec({ "svn", "propset", "svn:externals", "^/sample.txt ext.txt", "." }, f.root)
		h.exec({ "svn", "commit", "-m", "external" }, f.root)
		h.exec({ "svn", "update" }, f.root)
		h.write_file(f.root .. "/ext.txt", "external edit")
		for _, include in ipairs({ false, true }) do
			for _, recovery in ipairs({ false, true }) do
				assert(#list(f, include, "2", recovery) == 0, "external entered parent comparison")
			end
		end
		local compare = require("lazyvcs.compare")
		setup()
		for _, editable in ipairs({ false, true }) do
			local session =
				assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@2", editable = editable }))
			ctx.wait_for(function()
				return session.snapshot
			end, "external comparison did not resolve", 15000)
			assert(#session.items == 0 and session.message == "No saved changes", "public Compare included external")
			compare.close(session)
		end
		-- A parent file may be deleted and replaced at the same path by an external.
		h.exec({ "svn", "revert", "ext.txt" }, f.root)
		h.exec({ "svn", "propset", "svn:externals", "", "." }, f.root)
		h.exec({ "svn", "update" }, f.root)
		h.write_file(f.root .. "/ext.txt", "parent base")
		h.exec({ "svn", "add", "ext.txt" }, f.root)
		h.exec({ "svn", "commit", "-m", "parent file" }, f.root)
		h.exec({ "svn", "delete", "ext.txt" }, f.root)
		h.exec({ "svn", "propset", "svn:externals", "^/sample.txt ext.txt", "." }, f.root)
		h.exec({ "svn", "commit", "-m", "replace with external" }, f.root)
		h.exec({ "svn", "update" }, f.root)
		h.write_file(f.root .. "/ext.txt", "external edit")
		for _, include in ipairs({ false, true }) do
			for _, recovery in ipairs({ false, true }) do
				local items = list(f, include, "3", recovery)
				local found
				for _, item in ipairs(items) do
					if item.relpath == "ext.txt" then
						found = item
					end
				end
				assert(found and found.status == "D", "parent deletion disappeared or became replacement")
				local result = await(function(done)
					require("lazyvcs.backends.compare_svn").preview(snapshot(f, "3"), found, done)
				end)
				assert(result.left[1] == "parent base" and #result.right == 0)
			end
		end
	end)

	add("test_svn_compare_physically_missing_files", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "revert", f.file }, f.root)
		assert(os.remove(f.file))
		for _, include in ipairs({ false, true }) do
			local items = list(f, include)
			assert(#items == 1 and items[1].status == "!", "missing file reported clean or as scheduled deletion")
			local result = await(function(done)
				require("lazyvcs.backends.compare_svn").preview(snapshot(f), items[1], done)
			end)
			assert(result.left[1] == "one" and #result.right == 0)
			assert(result.right_label:find("MISSING", 1, true), "missing side not labeled")
		end
		setup()
		local compare = require("lazyvcs.compare")
		for _, editable in ipairs({ false, true }) do
			local session =
				assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@1", editable = editable }))
			ctx.wait_for(function()
				return session.preview_result or session.message == "Comparison unavailable"
			end, "missing preview", 15000)
			assert(session.preview_result and session.shown_item.status == "!", "public Compare reported clean")
			assert(session.preview_result.right_label == "MISSING FROM WORKTREE")
			compare.close(session)
		end
		h.exec({ "svn", "revert", f.file }, f.root)
		h.exec({ "svn", "update", "--set-depth", "empty", "." }, f.root)
		assert(#list(f, false) == 0, "sparse exclusion became a missing row")
	end)

	add("test_core_leader_validation_matches_native_mappings", function()
		local leader, localleader = vim.g.mapleader, vim.g.maplocalleader
		local ok, err = xpcall(function()
			for _, key in ipairs({ "Leader", "LocalLeader" }) do
				for _, value in ipairs({ "", "<Space>", " ", "\\" }) do
					vim.g.mapleader, vim.g.maplocalleader = value, value
					local lhs = "<" .. key .. ">x"
					local other = value == "" and "\\x" or "<Space>x"
					local same = api.nvim_replace_termcodes(lhs, true, true, true)
						== api.nvim_replace_termcodes(other, true, true, true)
					local accepted =
						pcall(require("lazyvcs.config").setup, { keymaps = { next_hunk = lhs, prev_hunk = other } })
					assert(
						accepted ~= same,
						"validation differs from native mapping identity for " .. key .. "=" .. vim.inspect(value)
					)
				end
			end
		end, debug.traceback)
		vim.g.mapleader, vim.g.maplocalleader = leader, localleader
		assert(ok, err)
	end)

	add("test_sign_repeated_setup_refreshes_visible_buffers", function()
		setup({ signs = { enabled = true } })
		local f = h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		local first = api.nvim_get_current_buf()
		vim.cmd.vsplit(vim.fn.fnameescape(f.file2))
		local second = api.nvim_get_current_buf()
		local signs = require("lazyvcs.signs")
		for _, buf in ipairs({ first, second }) do
			await(function(done)
				signs.refresh(buf, true, done)
			end)
		end
		local function marks(buf)
			return #api.nvim_buf_get_extmarks(buf, signs._test_state().namespace, 0, -1, {})
		end
		assert(marks(first) > 0 and marks(second) > 0)
		setup({ signs = { enabled = true } })
		ctx.wait_for(function()
			return marks(first) > 0 and marks(second) > 0
		end, "visible signs not restored")
		assert(marks(first) > 0, "setup cleared inactive split signs")
		setup()
		assert(marks(first) == 0 and marks(second) == 0, "disabled signs remained")
	end)

	add("test_core_health_describes_conditional_gitsigns_delegation", function()
		setup({ use_gitsigns = true, signs = { enabled = true } })
		local loaded, health = package.loaded.gitsigns, vim.health
		local messages = {}
		package.loaded.gitsigns = {
			get_hunks = function()
				return nil
			end,
		}
		local report = {}
		for _, name in ipairs({ "start", "ok", "warn", "error" }) do
			report[name] = function(message)
				messages[#messages + 1] = message
			end
		end
		vim.health = report
		package.loaded["lazyvcs.health"] = nil
		local ok, err = pcall(function()
			require("lazyvcs.health").check()
		end)
		vim.health, package.loaded.gitsigns = health, loaded
		package.loaded["lazyvcs.health"] = nil
		assert(ok, err)
		assert(
			table.concat(messages, "\n"):find("unattached buffers use native", 1, true),
			"health claims unconditional delegation"
		)
	end)

	add("test_live_diff_markdown_restores_explicit_parser_language", function()
		setup()
		local f = h.make_git_fixture()
		-- Lua is bundled on both supported Neovim versions. A Markdown filename
		-- exercises the guard with a real highlighter without an optional parser.
		local path = f.root .. "/sample.md"
		h.write_file(path, "local value = 1")
		h.exec({ "git", "add", "." }, f.root)
		for _, variant in ipairs({ "explicit", "matching", "registered", "inactive" }) do
			vim.cmd.edit(vim.fn.fnameescape(path))
			local buf = api.nvim_get_current_buf()
			vim.bo[buf].filetype = variant == "matching" and "lua" or "lazyvcs_a2_mdx"
			if variant == "registered" then
				vim.treesitter.language.register("lua", "lazyvcs_a2_mdx")
			end
			if variant ~= "inactive" then
				vim.treesitter.start(buf, "lua")
			end
			local session = open(path)
			assert(not vim.treesitter.highlighter.active[buf], "guard left highlighter active")
			require("lazyvcs.actions").close(session)
			local active = vim.treesitter.highlighter.active[buf]
			if variant == "inactive" then
				assert(not active)
			else
				assert(active and active.tree:lang() == "lua", "guard lost explicit parser language")
				vim.treesitter.stop(buf)
			end
		end
	end)
	return cases
end
