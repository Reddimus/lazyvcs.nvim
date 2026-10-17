return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local ops, model = require("lazyvcs.source_control.ops"), require("lazyvcs.source_control.model")
	local jobs, session = require("lazyvcs.source_control.jobs"), require("lazyvcs.state")
	local function setup()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false, background = { git_workers = 1 } },
		})
	end
	local function row(f, vcs, path, section)
		local repo, failure
		model.load_repo_details_async({ root = f.root, vcs = vcs, name = "repo" }, {}, function(args, _, done)
			return util.system_start(args, { cwd = f.root }, done)
		end, function(value, err)
			repo, failure = value, err
		end)
		wait(function()
			return repo or failure
		end, "details did not finish", 15000)
		assert(repo, failure)
		local state = {
			path = f.root,
			lazyvcs_repo_cache = { [f.root] = repo },
			lazyvcs_repo_specs = { { root = f.root, vcs = vcs, name = "repo" } },
			lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true },
			lazyvcs_render = function() end,
		}
		local function find(node)
			if node.type == "file" and node.path == path and (not section or node.extra.section == section) then
				return node
			end
			for _, child in ipairs(node.children or {}) do
				local found = find(child)
				if found then
					return found
				end
			end
		end
		return state, assert(find(model.collect(state, { root = f.root, scan_depth = 1 })), "tracked row missing")
	end
	local function finished(root)
		wait(function()
			for _, job in ipairs(jobs.history()) do
				if
					job.root == root
					and (job.kind == "discard_unstaged" or job.kind == "discard_staged" or job.kind == "svn_revert")
				then
					return true
				end
			end
		end, "discard did not settle", 15000)
	end
	local function directory(path)
		vim.fn.mkdir(path, "p")
		h.write_file(path .. "/child", "precious\n")
	end
	local function guarded(fn)
		return function()
			setup()
			local start, lstat, notify, confirm =
				util.system_start, vim.uv.fs_lstat, util.notify, require("lazyvcs.source_control.confirm").open
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			local ok, err = xpcall(fn, debug.traceback)
			util.system_start, vim.uv.fs_lstat, util.notify = start, lstat, notify
			require("lazyvcs.source_control.confirm").open = confirm
			assert(ok, err)
		end
	end
	local function symlinks(vcs)
		local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
		local target = h.tempdir()
		directory(target)
		local state, node = row(f, vcs, f.file)
		assert(vim.uv.fs_unlink(f.file))
		assert(vim.uv.fs_symlink(target, f.file, { dir = true }))
		ops.revert_file(state, node)
		finished(f.root)
		assert(not session.get_repo_job(f.root), "file replaced by symlink could not be discarded")
		assert(vim.uv.fs_lstat(f.file).type == "file")
		assert(vim.fn.readfile(target .. "/child")[1] == "precious", "symlink target was changed")
		assert(vim.uv.fs_unlink(f.file))
		assert(vim.uv.fs_symlink(target, f.file, { dir = true }))
		if vcs == "git" then
			h.exec({ "git", "config", "core.symlinks", "true" }, f.root)
			h.exec({ "git", "add", "sample.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "tracked symlink" }, f.root)
		else
			h.exec({ "svn", "propset", "svn:special", "*", "sample.txt" }, f.root)
			h.exec({ "svn", "commit", "-m", "tracked symlink" }, f.root)
		end
		assert(vim.uv.fs_unlink(f.file))
		h.write_file(f.file, "replacement\n")
		state, node = row(f, vcs, f.file)
		jobs.clear_history()
		ops.revert_file(state, node)
		finished(f.root)
		assert(not session.get_repo_job(f.root), "tracked symlink could not be discarded")
		assert(vim.uv.fs_lstat(f.file).type == "link")
		assert(vim.fn.readfile(target .. "/child")[1] == "precious", "tracked symlink target was changed")
		if vim.fn.has("win32") == 1 then
			assert(vim.uv.fs_unlink(f.file))
			assert(vim.uv.fs_symlink(target, f.file, { junction = true }))
			jobs.clear_history()
			ops.revert_file(state, node)
			finished(f.root)
			assert(session.get_repo_job(f.root), "Windows junction was accepted")
			assert(vim.fn.readfile(target .. "/child")[1] == "precious")
		end
	end
	local function interrupted()
		local starter = require("lazyvcs.source_control.mutation_start")
		for _, mode in ipairs({ "cancel", "timeout", "modified" }) do
			local f = h.make_git_fixture()
			local lstat, start = vim.uv.fs_lstat, util.system_start
			local complete, done, raw, failure
			vim.uv.fs_lstat = function(path, cb)
				if path == f.file and cb then
					complete = cb
					return {}
				end
				return lstat(path, cb)
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function()
				error("interrupted tracked preflight spawned a mutation")
			end
			local ok, err = xpcall(function()
				local handle = starter.start(
					{ root = f.root, vcs = "git" },
					{ "git", "restore", "--", "sample.txt" },
					{ cwd = f.root, timeout = mode == "timeout" and 10 or 5000 },
					{
						tracked_discard = { { path = f.file, relpath = "sample.txt" } },
						guard_modified_buffers = true,
						guard_paths = { f.file },
						guard_relpaths = { "sample.txt" },
					},
					function(_, e, result)
						done, failure, raw = true, e, result
					end
				)
				assert(complete, "tracked lstat was not submitted")
				local buf
				if mode == "cancel" then
					handle:cancel("test")
				elseif mode == "timeout" then
					vim.wait(30)
				else
					buf = vim.fn.bufadd(f.file)
					vim.fn.bufload(buf)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "late edit" })
				end
				assert(not done, "worker released before tracked filesystem completion")
				complete(nil, { type = "file" })
				wait(function()
					return done
				end, "tracked preflight did not settle")
				assert(
					mode == "modified" and failure:find("modified")
						or mode == "timeout" and raw.timed_out
						or mode == "cancel" and raw.cancelled,
					"tracked preflight lost its guard result"
				)
				if buf then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end, debug.traceback)
			vim.uv.fs_lstat, util.system_start = lstat, start
			assert(ok, err)
		end
	end

	local function windows_links(link_name)
		local has, lstat, start = vim.fn.has, vim.uv.fs_lstat, util.system_start
		local ok, err = xpcall(function()
			local cases = {
				{ "Junction", "it's a link" },
				{ "unknown", "it's a link" },
				{ "SymbolicLink", "it's a link" },
			}
			if link_name then
				cases = { { "SymbolicLink", link_name } }
			end
			for _, case in ipairs(cases) do
				local kind, path = case[1], "C:/repo/" .. case[2]
				local checked, mutated, done, failure = false, false, false, nil
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.uv.fs_lstat = function(_, cb)
					vim.schedule(function()
						cb(nil, { type = "link" })
					end)
					return {}
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[1] == "powershell.exe" then
						checked = true
						assert(
							args[#args]:find("-LiteralPath $env:LAZYVCS_LINK", 1, true)
								and not args[#args]:find(path, 1, true)
								and opts.env.LAZYVCS_LINK == path
								and opts.env.LAZYVCS_TEST == "inherited",
							"PowerShell path must travel only through the child environment"
						)
						cb({ code = 0, stdout = kind .. "\n", stderr = "" })
					else
						mutated = true
						cb({ code = 0, stdout = "", stderr = "" })
					end
					return {}
				end
				require("lazyvcs.source_control.mutation_start").start(
					{ root = "C:/repo", vcs = "git" },
					{ "git", "restore" },
					{ timeout = 5000, env = { LAZYVCS_TEST = "inherited" } },
					{ tracked_discard = { { path = path, relpath = case[2] } } },
					function(_, e)
						done, failure = true, e
					end
				)
				wait(function()
					return done
				end, "Windows link check did not finish")
				assert(checked and mutated == (kind == "SymbolicLink"), kind .. ": wrong Windows link classification")
				assert((failure == nil) == mutated)
			end
		end, debug.traceback)
		vim.fn.has, vim.uv.fs_lstat, util.system_start = has, lstat, start
		assert(ok, err)
	end

	local function submodule_discard(staged)
		local source, f = h.make_git_fixture(), h.make_git_fixture()
		h.exec({ "git", "restore", "sample.txt" }, source.root)
		h.exec(
			{ "git", "-c", "protocol.file.allow=always", "submodule", "add", "file://" .. source.root, "sub" },
			f.root
		)
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "add submodule" }, f.root)
		local original = util.trim(h.exec({ "git", "rev-parse", "HEAD:sub" }, f.root))
		h.exec({ "git", "config", "submodule.recurse", "true" }, f.root)
		h.write_file(source.file, "next submodule commit\n")
		h.exec({ "git", "commit", "-am", "advance" }, source.root)
		h.exec({ "git", "-c", "protocol.file.allow=always", "fetch" }, f.root .. "/sub")
		local next_commit = util.trim(h.exec({ "git", "rev-parse", "HEAD" }, source.root))
		h.exec({ "git", "checkout", next_commit }, f.root .. "/sub")
		h.write_file(f.root .. "/sub/sample.txt", "dirty submodule work\n")
		jobs.clear_history()
		if staged then
			h.exec({ "git", "add", "sub" }, f.root)
		end
		local state, node = row(f, "git", f.root .. "/sub", staged and "staged" or "changes")
		local start, ran = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, ...)
			if args[2] == "restore" then
				ran = true
			end
			return start(args, ...)
		end
		ops.revert_file(state, node)
		finished(f.root)
		util.system_start = start
		assert(ran, "submodule discard did not run restore")
		assert(not session.get_repo_job(f.root), "tracked submodule discard was refused")
		assert(
			vim.fn.readfile(f.root .. "/sub/sample.txt")[1] == "dirty submodule work",
			"recursive restore overwrote dirty submodule file"
		)
		assert(util.trim(h.exec({ "git", "rev-parse", ":sub" }, f.root)) == original, "staged pointer was not restored")
		assert(
			util.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root .. "/sub")) == next_commit,
			"submodule checkout changed"
		)
	end

	local function embedded_replacement(kind)
		local f, nested = h.make_git_fixture(), h.make_git_fixture()
		local target = f.file
		if kind == "tree" then
			assert(vim.uv.fs_unlink(target))
			vim.fn.mkdir(target)
			h.write_file(target .. "/sample.txt", "committed outer child\n")
			h.exec({ "git", "add", "-A" }, f.root)
			h.exec({ "git", "commit", "-m", "tree" }, f.root)
			h.exec({ "git", "rm", "-r", "--cached", "--", "sample.txt" }, f.root)
			assert(vim.fn.delete(target, "rf") == 0)
		else
			assert(vim.uv.fs_unlink(target))
		end
		assert(vim.uv.fs_rename(nested.root, target))
		h.write_file(target .. "/untracked", "untracked private work\n")
		h.exec({ "git", "add", "-A", "--", "sample.txt" }, f.root)
		local commit = h.exec({ "git", "rev-parse", "HEAD" }, target)
		local before = h.exec({ "git", "status", "--porcelain" }, f.root)
		local selected = kind == "tree" and (target .. "/sample.txt") or target
		local state, node = row(f, "git", selected, "staged")
		if kind == "tree" then
			assert(node.extra.status:sub(1, 1) == "D", "fixture did not select the real staged delete row")
			assert(util.relpath(f.root, selected) == "sample.txt/sample.txt", "entry guard rejected nested path")
			assert(not require("lazyvcs.source_control.buffer_guard").error(f.root, { selected }))
		end
		local start, ran = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, ...)
			if args[2] == "restore" then
				ran = true
			end
			return start(args, ...)
		end
		ops.revert_file(state, node)
		finished(f.root)
		util.system_start = start
		assert(vim.uv.fs_stat(target .. "/.git"), "staged Discard deleted embedded .git")
		assert(h.exec({ "git", "rev-parse", "HEAD" }, target) == commit, "embedded commit lost")
		assert(vim.fn.readfile(target .. "/sample.txt")[2] == "changed", "embedded tracked file overwritten")
		assert(vim.fn.readfile(target .. "/untracked")[1] == "untracked private work", "untracked work lost")
		assert(not ran, "HEAD obstruction reached restore")
		assert(h.exec({ "git", "status", "--porcelain" }, f.root) == before, "outer index changed")
	end

	local function ancestor_obstruction(kind)
		local f = h.make_git_fixture()
		local parent, relative = "outer/inner", "outer/inner/sample.txt"
		vim.fn.mkdir(f.root .. "/" .. parent, "p")
		h.exec({ "git", "mv", "sample.txt", relative }, f.root)
		h.exec({ "git", "commit", "-m", "nested ordinary file" }, f.root)
		local path = f.root .. "/" .. relative
		h.write_file(path, "private work\n")
		local state, node = row(f, "git", path)
		local marker = f.root .. "/" .. parent .. "/.git"
		if kind == "directory_marker" then
			vim.fn.mkdir(marker)
		elseif kind == "file_marker" then
			h.write_file(marker, "gitdir: private metadata\n")
		else
			local oid = util.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
			h.exec({ "git", "update-index", "--force-remove", "--", relative }, f.root)
			h.exec({ "git", "update-index", "--add", "--cacheinfo", "160000", oid, parent }, f.root)
			if kind == "head_gitlink" then
				h.exec({ "git", "commit", "-m", "gitlink ancestor" }, f.root)
				-- A stale row must also be safe when only HEAD retains the gitlink.
				h.exec({ "git", "update-index", "--force-remove", "--", parent }, f.root)
				h.exec({ "git", "add", "--", relative }, f.root)
			end
		end
		local before = h.exec({ "git", "ls-files", "--stage" }, f.root)
		local start, ran = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, ...)
			if args[2] == "restore" then
				ran = true
			end
			return start(args, ...)
		end
		ops.revert_file(state, node)
		finished(f.root)
		assert(not ran, kind .. ": ancestor obstruction reached restore")
		assert(vim.fn.readfile(path)[1] == "private work", "nested file overwritten")
		assert(h.exec({ "git", "ls-files", "--stage" }, f.root) == before, "ancestor index changed")
		if kind:find("marker", 1, true) then
			assert(vim.uv.fs_lstat(marker), "repository marker removed")
		end
	end

	local function rename_ancestor_obstruction(source)
		local f = h.make_git_fixture()
		vim.fn.mkdir(f.root .. "/outer/inner", "p")
		h.exec({ "git", "mv", "sample.txt", "outer/inner/sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "nested file" }, f.root)
		vim.fn.mkdir(f.root .. "/destination", "p")
		h.exec({ "git", "mv", "outer/inner/sample.txt", "destination/renamed.txt" }, f.root)
		local state, node = row(f, "git", f.root .. "/destination/renamed.txt", "staged")
		assert(node.extra.status:sub(1, 1) == "R", "fixture did not select rename")
		local marker = f.root .. (source and "/outer/.git" or "/destination/.git")
		h.write_file(marker, "gitdir: private metadata\n")
		local start, ran = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, ...)
			if args[2] == "restore" then
				ran = true
			end
			return start(args, ...)
		end
		ops.revert_file(state, node)
		finished(f.root)
		assert(not ran, "rename ancestor obstruction reached restore")
		assert(vim.uv.fs_lstat(marker), "rename ancestor marker removed")
		assert(vim.uv.fs_stat(f.root .. "/destination/renamed.txt"), "rename destination removed")
	end

	local function rename_source_replacement()
		local f, nested = h.make_git_fixture(), h.make_git_fixture()
		h.exec({ "git", "restore", "sample.txt" }, f.root)
		h.exec({ "git", "mv", "sample.txt", "renamed.txt" }, f.root)
		local state, node = row(f, "git", f.root .. "/renamed.txt", "staged")
		assert(vim.uv.fs_rename(nested.root, f.file))
		h.write_file(f.file .. "/untracked", "private work\n")
		-- A queued row can outlive an external index change at its rename source.
		h.exec({ "git", "add", "--", "sample.txt" }, f.root)
		local commit = h.exec({ "git", "rev-parse", "HEAD" }, f.file)
		local before = h.exec({ "git", "status", "--porcelain" }, f.root)
		ops.revert_file(state, node)
		finished(f.root)
		assert(vim.uv.fs_stat(f.file .. "/.git"), "rename source embedded repository deleted")
		assert(h.exec({ "git", "rev-parse", "HEAD" }, f.file) == commit, "rename source commit lost")
		assert(vim.fn.readfile(f.file .. "/sample.txt")[2] == "changed")
		assert(vim.fn.readfile(f.file .. "/untracked")[1] == "private work")
		assert(h.exec({ "git", "status", "--porcelain" }, f.root) == before, "rename source index changed")
	end

	local extra = {}
	for _, kind in ipairs({ "directory_marker", "file_marker", "index_gitlink", "head_gitlink" }) do
		extra[#extra + 1] = {
			"test_source_control_tracked_discard_refuses_ancestor_" .. kind,
			guarded(function()
				ancestor_obstruction(kind)
			end),
		}
	end
	for _, source in ipairs({ false, true }) do
		extra[#extra + 1] = {
			"test_source_control_rename_discard_refuses_ancestor_" .. (source and "source" or "destination"),
			guarded(function()
				rename_ancestor_obstruction(source)
			end),
		}
	end

	local cases = {
		{
			"test_source_control_staged_discard_preserves_embedded_rename_source",
			guarded(rename_source_replacement),
		},
		{
			"test_source_control_staged_discard_preserves_embedded_repo_over_blob",
			guarded(function()
				embedded_replacement("blob")
			end),
		},
		{
			"test_source_control_staged_delete_discard_preserves_nested_repository_file",
			guarded(function()
				embedded_replacement("tree")
			end),
		},
		{ "test_source_control_windows_link_paths_use_environment", guarded(windows_links) },
		{
			"test_source_control_windows_link_typographic_quote_uses_environment",
			guarded(function()
				windows_links("Dave’s link")
			end),
		},
		{
			"test_source_control_windows_link_injection_text_uses_environment",
			guarded(function()
				windows_links("');Start-Process calc;#")
			end),
		},
		{
			"test_source_control_tracked_discard_allows_submodules",
			guarded(function()
				submodule_discard(false)
			end),
		},
		{
			"test_source_control_staged_discard_preserves_dirty_submodule",
			guarded(function()
				submodule_discard(true)
			end),
		},
		{
			"test_source_control_tracked_discard_refuses_obstructions",
			guarded(function()
				for _, mode in ipairs({
					"directory",
					"modified",
					"nested",
					"fifo",
					"socket",
					"char",
					"block",
					"EACCES",
					"EIO",
				}) do
					local f = h.make_git_fixture()
					assert(vim.uv.fs_unlink(f.file))
					local state, node = row(f, "git", f.file)
					directory(f.file)
					if mode == "nested" then
						h.exec({ "git", "init", "-q", f.file }, f.root)
					end
					local buf
					if mode == "modified" then
						buf = vim.fn.bufadd(f.file .. "/child")
						vim.fn.bufload(buf)
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved child" })
					end
					local before = h.exec({ "git", "status", "--porcelain" }, f.root)
					local start, lstat, spawned = util.system_start, vim.uv.fs_lstat, false
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, ...)
						if vim.tbl_contains(args, "restore") then
							spawned = true
						end
						return start(args, ...)
					end
					vim.uv.fs_lstat = function(path, callback)
						if
							path == f.file
							and callback
							and mode ~= "directory"
							and mode ~= "modified"
							and mode ~= "nested"
						then
							vim.schedule(function()
								if mode:sub(1, 1) == "E" then
									callback(mode .. ": denied")
								else
									callback(nil, { type = mode })
								end
							end)
							return {}
						end
						return lstat(path, callback)
					end
					require("lazyvcs.config").get().source_control.confirm_mutations = true
					---@diagnostic disable-next-line: duplicate-set-field
					require("lazyvcs.source_control.confirm").open = function(_, done)
						done("confirm")
						return {}
					end
					ops.revert_file(state, node)
					finished(f.root)
					util.system_start, vim.uv.fs_lstat = start, lstat
					assert(vim.uv.fs_stat(f.file .. "/child"), mode .. ": tracked discard deleted directory child")
					assert(not spawned, mode .. ": obstruction reached git restore")
					assert(vim.fn.readfile(f.file .. "/child")[1] == "precious")
					assert(h.exec({ "git", "status", "--porcelain" }, f.root) == before)
					if buf then
						assert(vim.bo[buf].modified)
						vim.api.nvim_buf_delete(buf, { force = true })
					end
					h.cleanup()
				end
				for _, missing in ipairs({ false, true }) do
					local f = h.make_git_fixture()
					local state, node = row(f, "git", f.file)
					if missing then
						assert(vim.uv.fs_unlink(f.file))
					end
					ops.revert_file(state, node)
					finished(f.root)
					assert(not session.get_repo_job(f.root), "ordinary tracked discard rejected")
					assert(vim.fn.readfile(f.file)[2] == "two")
				end
				symlinks("git")
				interrupted()
			end),
		},
		{
			"test_source_control_tracked_discard_rechecks_queued_rename_sources",
			guarded(function()
				for _, obstruct in ipairs({ "sample.txt", "renamed.txt" }) do
					local f = h.make_git_fixture()
					h.exec({ "git", "restore", "sample.txt" }, f.root)
					h.exec({ "git", "mv", "sample.txt", "renamed.txt" }, f.root)
					local state, node = row(f, "git", f.root .. "/renamed.txt", "staged")
					local release
					jobs.command({ root = f.root, vcs = "git" }, "hold", { "git", "status" }, {
						start = function(_, _, done)
							release = done
							return {}
						end,
					}, function() end)
					ops.revert_file(state, node)
					local path = f.root .. "/" .. obstruct
					if vim.uv.fs_lstat(path) then
						assert(vim.uv.fs_unlink(path))
					end
					directory(path)
					release({ code = 0, stdout = "", stderr = "" })
					finished(f.root)
					assert(vim.uv.fs_stat(path .. "/child"), "queued rename discard deleted " .. obstruct .. " child")
					assert(session.get_repo_job(f.root), "queued rename obstruction was accepted")
				end
			end),
		},
		{
			"test_source_control_svn_file_discard_refuses_obstructions",
			guarded(function()
				local f = h.make_svn_fixture()
				local state, node = row(f, "svn", f.file)
				assert(vim.uv.fs_unlink(f.file))
				directory(f.file)
				local start, spawned = util.system_start, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, ...)
					if args[2] == "revert" then
						spawned = true
					end
					return start(args, ...)
				end
				ops.revert_file(state, node)
				finished(f.root)
				assert(not spawned, "SVN file obstruction reached svn revert")
				assert(vim.fn.readfile(f.file .. "/child")[1] == "precious")
				util.system_start = start
				for _, missing in ipairs({ false, true }) do
					f = h.make_svn_fixture()
					state, node = row(f, "svn", f.file)
					if missing then
						assert(vim.uv.fs_unlink(f.file))
					end
					ops.revert_file(state, node)
					finished(f.root)
					assert(not session.get_repo_job(f.root), "ordinary SVN file discard rejected")
					assert(vim.fn.readfile(f.file)[2] == "two")
				end
				f = h.make_svn_fixture()
				state, node = row(f, "svn", f.file)
				local infos = 0
				spawned = false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[2] == "info" then
						infos = infos + 1
						return start(args, opts, function(result, err, raw)
							if result and infos == 2 then
								result.stdout = result.stdout:gsub('kind="file"', 'kind="dir"')
							end
							cb(result, err, raw)
						end)
					end
					if args[2] == "revert" then
						spawned = true
					end
					return start(args, opts, cb)
				end
				ops.revert_file(state, node)
				finished(f.root)
				assert(infos == 2 and not spawned, "SVN changed file kind was accepted")
				assert(vim.fn.readfile(f.file)[2] == "changed")
				util.system_start = start
				symlinks("svn")
			end),
		},
	}
	return vim.list_extend(cases, extra)
end
