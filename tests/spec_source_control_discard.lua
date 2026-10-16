return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local jobs = require("lazyvcs.source_control.jobs")
	local session = require("lazyvcs.state")
	local confirm = require("lazyvcs.source_control.confirm")
	local function fixture()
		local f = h.make_git_fixture()
		f.path = f.root .. "/victim"
		h.write_file(f.path, "untracked\n")
		local repo, failure
		local model = require("lazyvcs.source_control.model")
		model.load_repo_details_async({ root = f.root, vcs = "git", name = "repo" }, {}, function(args, _, done)
			return util.system_start(args, { cwd = f.root }, done)
		end, function(value, err)
			repo, failure = value, err
		end)
		wait(function()
			return repo or failure
		end, "details did not finish", 15000)
		assert(repo, failure)
		f.state = {
			path = f.root,
			lazyvcs_repo_cache = { [f.root] = repo },
			lazyvcs_repo_specs = { { root = f.root, vcs = "git", name = "repo" } },
			lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true },
			lazyvcs_render = function() end,
		}
		local function find(node)
			if node.type == "file" and node.path == f.path then
				return node
			end
			for _, child in ipairs(node.children or {}) do
				local found = find(child)
				if found then
					return found
				end
			end
		end
		f.node = assert(find(model.collect(f.state, { root = f.root, scan_depth = 1 })), "untracked row missing")

		assert(h.exec({ "git", "status", "--porcelain", "--", "victim" }, f.root) == "?? victim\n")
		return f
	end
	local function finished(f)
		wait(function()
			local job = session.get_repo_job(f.root)
			return not job or job.status ~= "running"
		end, "discard did not settle", 15000)
	end
	local function replace(f)
		assert(vim.uv.fs_unlink(f.path))
		vim.fn.mkdir(f.path)
		h.write_file(f.path .. "/child", "child\n")
		h.write_file(f.path .. "/sibling", "sibling\n")
	end
	return {
		{
			"test_source_control_untracked_discard_refuses_replacement_directories",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { confirm_mutations = false, background = { git_workers = 1 } },
				})
				local open, unlink, lstat, notify, start =
					confirm.open, vim.uv.fs_unlink, vim.uv.fs_lstat, util.notify, util.system_start
				local notices = {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					notices[#notices + 1] = message
				end
				local ok, err = xpcall(function()
					for _, phase in ipairs({ "cached", "modified", "confirmation", "queued", "unlink", "nested" }) do
						local f = fixture()
						local release
						if phase == "cached" or phase == "modified" or phase == "nested" then
							replace(f)
						end
						if phase == "nested" then
							h.exec({ "git", "init", f.path }, f.root)
						end
						local buf
						if phase == "modified" then
							buf = vim.fn.bufadd(f.path .. "/child")
							vim.fn.bufload(buf)
							vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved child" })
						elseif phase == "confirmation" then
							require("lazyvcs.config").get().source_control.confirm_mutations = true
							---@diagnostic disable-next-line: duplicate-set-field
							confirm.open = function(_, done)
								replace(f)
								done("confirm")
								return {}
							end
						elseif phase == "queued" then
							jobs.command({ root = f.root, vcs = "git" }, "hold", { "git", "status" }, {
								start = function(_, _, done)
									release = done
									return {}
								end,
							})
						elseif phase == "unlink" then
							---@diagnostic disable-next-line: duplicate-set-field
							vim.uv.fs_unlink = function(path, callback)
								if path == f.path and callback then
									replace(f)
								end
								return unlink(path, callback)
							end
						end
						ops.revert_file(f.state, f.node)
						if release then
							replace(f)
							release({ code = 0, stdout = "", stderr = "" })
						end
						finished(f)
						assert(
							vim.uv.fs_stat(f.path .. "/child"),
							phase .. ": discard deleted replacement directory descendants"
						)
						assert(vim.fn.readfile(f.path .. "/sibling")[1] == "sibling", "sibling changed")
						if buf then
							assert(
								vim.bo[buf].modified
									and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved child"
							)
							vim.api.nvim_buf_delete(buf, { force = true })
						end
						vim.uv.fs_unlink, confirm.open = unlink, open
						require("lazyvcs.config").get().source_control.confirm_mutations = false
						h.cleanup()
					end
					assert(table.concat(notices, " "):find("director"), "directory refusal was not reported")
					for _, mode in ipairs({
						"file",
						"staged",
						"ignored",
						"symlink",
						"permission",
						"literal",
						"newline",
						"truncated",
					}) do
						local f = fixture()
						if mode == "literal" or mode == "newline" then
							local literal = mode == "newline" and "line\r\nbreak" or ":(glob)*"
							if vim.fn.has("win32") == 1 then
								literal = "[glob]"
							end
							assert(vim.uv.fs_rename(f.path, f.root .. "/" .. literal))
							f.path = f.root .. "/" .. literal
							f.node.path, f.node.extra.relpath = f.path, literal
						elseif mode == "truncated" then
							---@diagnostic disable-next-line: duplicate-set-field
							util.system_start = function(args, opts, done)
								if vim.tbl_contains(args, "--porcelain=v1") then
									done({ code = 0, stdout = "?? victim\0", stderr = "", stdout_truncated = true })
									return {}
								end
								return start(args, opts, done)
							end
						elseif mode == "staged" then
							h.exec({ "git", "add", "victim" }, f.root)
						elseif mode == "ignored" then
							h.write_file(f.root .. "/.git/info/exclude", "victim\n")
						elseif mode == "symlink" then
							assert(unlink(f.path))
							h.write_file(f.root .. "/target", "target\n")
							local linked, link_err = vim.uv.fs_symlink(f.root .. "/target", f.path)
							assert(linked, link_err)
						elseif mode == "permission" then
							---@diagnostic disable-next-line: duplicate-set-field
							vim.uv.fs_unlink = function(path, callback)
								if path == f.path and callback then
									vim.schedule(function()
										callback("EPERM: denied")
									end)
									return {}
								end
								return unlink(path, callback)
							end
						end
						ops.revert_file(f.state, f.node)
						finished(f)
						if mode == "file" or mode == "symlink" or mode == "literal" or mode == "newline" then
							assert(not lstat(f.path), "selected file was not deleted")
						else
							assert(lstat(f.path), mode .. " file was deleted")
						end
						if mode == "symlink" then
							assert(vim.fn.readfile(f.root .. "/target")[1] == "target", "symlink target changed")
						end
						assert(vim.uv.fs_stat(f.file), "discard deleted another file")
						vim.uv.fs_unlink, util.system_start = unlink, start
						h.cleanup()
					end
					for _, mode in ipairs({ "cancel", "timeout" }) do
						local f = fixture()
						local pending, queued
						---@diagnostic disable-next-line: duplicate-set-field
						vim.uv.fs_lstat = function(path, callback)
							if path == f.path and callback then
								pending = callback
								return {}
							end
							return lstat(path, callback)
						end
						require("lazyvcs.config").get().source_control.background.mutation_timeout_ms = mode
									== "timeout"
								and 25
							or 15000
						ops.revert_file(f.state, f.node)
						assert(pending, "native preflight was not submitted")
						if mode == "cancel" then
							jobs.cancel_repo(f.root)
						end
						finished(f)
						jobs.command({ root = f.root, vcs = "git" }, "after", { "git", "status" }, {
							start = function(_, _, done)
								queued = true
								done({ code = 0, stdout = "", stderr = "" })
								return {}
							end,
						})
						assert(not queued, "worker released before native completion")
						pending(nil, lstat(f.path))
						wait(function()
							return queued
						end, "native completion did not release worker")
						assert(lstat(f.path), mode .. " submitted unlink after termination")
						vim.uv.fs_lstat = lstat
						h.cleanup()
					end
				end, debug.traceback)
				confirm.open, vim.uv.fs_unlink, vim.uv.fs_lstat, util.notify, util.system_start =
					open, unlink, lstat, notify, start
				assert(ok, err)
			end,
		},
	}
end
