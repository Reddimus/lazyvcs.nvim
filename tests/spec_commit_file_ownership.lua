return function(ctx)
	local h, p, wait = ctx.helpers, require("process_helpers"), ctx.wait_for
	local ops, util = require("lazyvcs.source_control.ops"), require("lazyvcs.util")
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local function prune(cache, cwd)
		h.exec({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			root .. "/tests/fixtures/commit_prune.lua",
			root,
			cache,
		}, cwd)
	end
	local function active(preserved)
		local f = h.make_git_fixture()
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.write_file(f.root .. "/message", "Owned commit")
		h.write_file(
			f.root .. "/.git/hooks/pre-commit",
			"#!/bin/sh\n"
				.. (vim.fn.has("win32") == 1 and "" or "echo $PPID > mutation.pid\necho $$ > hook.pid\n")
				.. "echo ready > hook.ready\nwhile [ ! -f release ]; do sleep 0.05; done\n"
		)
		assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493))
		p.guarded(f.root, function()
			local path, consumer
			if preserved then
				p.editor(root .. "/tests/fixtures/process_mutation_shutdown.lua", f.root, { root, f.root, "ops" })
				path = vim.fn.readfile(f.root .. "/message-path")[1]
			else
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { confirm_mutations = false },
				})
				local start = util.system_start
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, ...)
					if vim.tbl_contains(args, "commit") then
						path = args[vim.fn.index(args, "-F") + 2]
					end
					local handle = start(args, ...)
					if vim.tbl_contains(args, "commit") then
						consumer = handle.process and handle.process.pid
					end
					return handle
				end
				local ok, err = pcall(ops.commit_repo, {
					lazyvcs_repo_cache = {
						[f.root] = {
							root = f.root,
							vcs = "git",
							name = "repo",
							counts = { staged = 1, local_changes = 1 },
						},
					},
					lazyvcs_commit_drafts = { [f.root] = "Owned commit" },
					lazyvcs_render = function() end,
				}, { path = f.root })
				util.system_start = start
				assert(ok, err)
				wait(function()
					return vim.fn.filereadable(f.root .. "/hook.ready") == 1
				end, "hook did not start", 5000)
			end
			consumer = consumer or p.pid(f.root .. "/mutation.pid")
			assert(p.alive(consumer), "commit is not alive")
			local old = os.time() - 86402
			assert(vim.uv.fs_utime(path, old, old))
			prune(preserved and (f.root .. "/cache") or vim.env.XDG_CACHE_HOME, f.root)
			assert(vim.uv.fs_stat(path), "pruner deleted a message still owned by a live commit")
			h.write_file(f.root .. "/release", "finish")
			wait(function()
				return not p.alive(consumer)
			end, "commit did not finish", 5000)
			assert(
				util.trim(h.exec({ "git", "log", "-1", "--format=%B" }, f.root)) == "Owned commit",
				"commit lost its message"
			)
			if not preserved then
				wait(function()
					return not vim.uv.fs_stat(path)
				end, "settled commit message leaked")
			end
		end)
	end
	local function policy()
		local files = require("lazyvcs.source_control.commit_files")
		local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
		vim.fn.mkdir(dir, "p")
		local path = dir .. "/policy.txt"
		local uname, kill, open, unlink = vim.uv.os_uname, vim.uv.kill, vim.uv.fs_open, vim.uv.fs_unlink
		local record = {
			version = 1,
			token = "policy",
			boot = os.time() - vim.uv.uptime(),
			platform = uname().sysname,
			pid = vim.fn.getpid(),
		}
		if record.platform == "Linux" then
			local ns = assert(vim.uv.fs_stat("/proc/self/ns/pid"))
			record.namespace = { dev = ns.dev, ino = ns.ino }
			record.boot_id = table.concat(vim.fn.readfile("/proc/sys/kernel/random/boot_id"), "\n") .. "\n"
		end
		local function save(value, receipt)
			h.write_file(path, "private message")
			vim.uv.fs_utime(path, os.time() - 86402, os.time() - 86402)
			h.write_file(path .. ".owner", vim.json.encode(value))
			if receipt then
				h.write_file(path .. ".settled", vim.json.encode(receipt))
			else
				pcall(unlink, path .. ".settled")
			end
		end
		local function scan()
			local marker = dir .. "/zzzz-policy.txt"
			h.write_file(marker, "finished")
			local old = os.time() - vim.uv.uptime() - 10
			vim.uv.fs_utime(marker, old, old)
			files.prune()
			assert(vim.uv.fs_stat(marker), "pruning blocked")
			wait(function()
				return not vim.uv.fs_stat(marker)
			end, "pruning did not finish")
			vim.wait(30)
		end
		local ok, err = xpcall(function()
			save(record)
			scan()
			assert(vim.uv.fs_stat(path), "age alone released an owned message")
			for _, platform in ipairs({ "Linux", "Darwin", "Windows_NT" }) do
				for _, result in ipairs({ "alive", "ESRCH", "EPERM" }) do
					local value = vim.deepcopy(record)
					value.platform = platform
					if platform == "Linux" and not value.namespace then
						value.namespace = { dev = 1, ino = 2 }
					end
					vim.uv.os_uname = function()
						return { sysname = platform }
					end
					rawset(vim.uv, "kill", function(pid, signal)
						assert(pid == record.pid and signal == 0)
						if result == "alive" then
							return true
						end
						return nil, result .. ": probe", result
					end)
					save(value)
					scan()
					local linux_scope = platform ~= "Linux" or record.platform == "Linux"
					assert(
						(vim.uv.fs_stat(path) == nil) == (result == "ESRCH" and linux_scope),
						platform .. ": wrong liveness release"
					)
				end
			end
			vim.uv.os_uname, vim.uv.kill = uname, kill
			for _, mode in ipairs({ "foreign", "unknown", "permission", "receipt", "wrong_receipt", "boot" }) do
				local value = vim.deepcopy(record)
				if mode == "foreign" and value.namespace then
					value.namespace.ino = value.namespace.ino + 1
				end
				if mode == "unknown" or (mode == "foreign" and not value.namespace) then
					value.pid = nil
				end
				if mode == "boot" then
					value.boot, value.boot_id = value.boot - 100, "another boot"
				end
				rawset(vim.uv, "kill", function()
					error("unverifiable scope reached liveness probe")
				end)
				if mode == "permission" or mode == "wrong_receipt" then
					rawset(vim.uv, "kill", function()
						return nil, "EPERM", "EPERM"
					end)
				end
				vim.uv.fs_open = function(name, ...)
					if name == path .. ".owner" and mode == "permission" then
						local args = { ... }
						local cb = args[#args]
						if type(cb) == "function" then
							vim.schedule(function()
								cb("EACCES: denied")
							end)
							return {}
						end
					end
					return open(name, ...)
				end
				save(
					value,
					(mode == "receipt" or mode == "wrong_receipt")
							and { token = mode == "receipt" and "policy" or "wrong" }
						or nil
				)
				scan()
				assert(
					(vim.uv.fs_stat(path) == nil) == (mode == "receipt" or mode == "boot"),
					mode .. ": wrong ownership release"
				)
			end
			vim.uv.kill, vim.uv.fs_open = kill, open
			local file = assert(files.create("settled private message"))
			files.attach(file, { process = { pid = vim.fn.getpid() } })
			vim.uv.fs_unlink = function(name, ...)
				if name == file.path then
					return nil, "EPERM", "EPERM"
				end
				return unlink(name, ...)
			end
			files.release(file)
			assert(vim.uv.fs_stat(file.path .. ".settled"), "failed deletion lost settlement evidence")
			vim.uv.fs_unlink = unlink
			scan()
			assert(not vim.uv.fs_stat(file.path), "settlement receipt did not release message")
			assert(not vim.uv.fs_stat(file.path .. ".owner") and not vim.uv.fs_stat(file.path .. ".settled"))
		end, debug.traceback)
		vim.uv.os_uname, vim.uv.kill, vim.uv.fs_open, vim.uv.fs_unlink = uname, kill, open, unlink
		assert(ok, err)
	end

	return {
		{ "test_source_control_commit_pruning_requires_ownership_evidence", policy },
		{
			"test_source_control_commit_pruning_preserves_active_message",
			function()
				active(false)
			end,
		},
		{
			"test_source_control_commit_pruning_preserves_message_after_editor_exit",
			function()
				active(vim.fn.has("win32") ~= 1)
			end,
		},
	}
end
