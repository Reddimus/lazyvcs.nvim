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

	local function windows_links()
		local has, lstat, start = vim.fn.has, vim.uv.fs_lstat, util.system_start
		local ok, err = xpcall(function()
			for _, kind in ipairs({ "Junction", "SymbolicLink", "unknown" }) do
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
				util.system_start = function(args, _, cb)
					if args[1] == "powershell.exe" then
						checked = true
						assert(
							args[#args]:find("-LiteralPath 'C:/repo/it''s a link'", 1, true),
							"PowerShell path was not quoted literally"
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
					{ timeout = 5000 },
					{ tracked_discard = { { path = "C:/repo/it's a link", relpath = "it's a link" } } },
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

	return {
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
				windows_links()
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
end
