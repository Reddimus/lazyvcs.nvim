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
			if preserved then
				prune(f.root .. "/cache", f.root)
			end
			wait(function()
				return not vim.uv.fs_stat(path)
			end, "settled commit message leaked")
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
			local age = os.time() - math.min(86402, math.max(0, vim.uv.uptime() - 1))
			vim.uv.fs_utime(path, age, age)
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
					value.boot, value.boot_id, value.pid = value.boot - 100, "another boot", nil
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

	-- Model Linux scope explicitly so these cases also run on macOS and Windows.
	local function linux_scope()
		local stat, open = vim.uv.fs_stat, vim.uv.fs_open
		local boot = h.tempdir() .. "/boot_id"
		h.write_file(boot, "fixture-boot\n")
		vim.uv.fs_stat = function(path, cb)
			if path == "/proc/self/ns/pid" then
				local value = { dev = 12, ino = 34 }
				if cb then
					vim.schedule(function()
						cb(nil, value)
					end)
					return {}
				end
				return value
			end
			return stat(path, cb)
		end
		vim.uv.fs_open = function(path, ...)
			return open(path == "/proc/sys/kernel/random/boot_id" and boot or path, ...)
		end
		return function()
			vim.uv.fs_stat, vim.uv.fs_open = stat, open
		end
	end

	local function prune_scan()
		local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
		local marker = dir .. "/zzzz-review.txt"
		h.write_file(marker, "barrier")
		local old = os.time() - vim.uv.uptime() - 10
		assert(vim.uv.fs_utime(marker, old, old))
		require("lazyvcs.source_control.commit_files").prune()
		wait(function()
			return not vim.uv.fs_stat(marker)
		end, "pruning did not finish", 5000)
		vim.wait(30)
	end
	local extra = {}
	for _, mode in ipairs({ "missing", "unreadable", "malformed", "token", "platform", "version" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_prunes_previous_boot_" .. mode .. "_owner",
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local open = vim.uv.fs_open
				local ok, err = xpcall(function()
					for _, old in ipairs({ false, true }) do
						local file = assert(files.create("private"))
						local owner = file.path .. ".owner"
						if mode == "missing" then
							assert(vim.uv.fs_unlink(owner))
						elseif mode == "malformed" then
							h.write_file(owner, "")
						elseif mode == "unreadable" then
							vim.uv.fs_open = function(path, flags, permissions, cb)
								if path == owner and cb then
									vim.schedule(function()
										cb("EACCES: unreadable")
									end)
									return {}
								end
								return open(path, flags, permissions, cb)
							end
						else
							local record = vim.deepcopy(file.record)
							if mode == "token" then
								record.token = "another message"
							end
							if mode == "platform" then
								record.platform = "another platform"
							end
							if mode == "version" then
								record.version = 999
							end
							h.write_file(owner, vim.json.encode(record))
						end
						if old then
							local before_boot = os.time() - vim.uv.uptime() - 10
							assert(vim.uv.fs_utime(file.path, before_boot, before_boot))
						end
						prune_scan()
						assert((vim.uv.fs_stat(file.path) == nil) == old, mode .. ": wrong legacy age release")
						vim.uv.fs_open = open
						files.release(file)
					end
				end, debug.traceback)
				vim.uv.fs_open = open
				assert(ok, err)
			end,
		}
	end
	for _, suffix in ipairs({ ".owner", ".settled", ".owner.tmp", ".settled.tmp" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_prunes_orphan" .. suffix:gsub("%.", "_"),
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local file = assert(files.create("private"))
				local sidecar = file.path .. suffix
				h.write_file(sidecar, "sidecar")
				local old = os.time() - vim.uv.uptime() - 10
				assert(vim.uv.fs_utime(sidecar, old, old))
				prune_scan()
				assert(vim.uv.fs_stat(sidecar), "owned sidecar was removed")
				assert(vim.uv.fs_unlink(file.path))
				assert(vim.uv.fs_utime(sidecar, os.time(), os.time()))
				prune_scan()
				assert(vim.uv.fs_stat(sidecar), "fresh orphan was removed")
				assert(vim.uv.fs_utime(sidecar, old, old))
				prune_scan()
				assert(not vim.uv.fs_stat(sidecar), "previous-boot orphan leaked")
				files.release(file)
			end,
		}
	end
	extra[#extra + 1] = {
		"test_source_control_commit_clock_step_keeps_live_consumer",
		function()
			local files = require("lazyvcs.source_control.commit_files")
			local uname, kill = vim.uv.os_uname, vim.uv.kill
			local restore_scope = linux_scope()
			local ok, err = xpcall(function()
				for _, platform in ipairs({ "Linux", "Darwin", "Windows_NT" }) do
					vim.uv.os_uname = function()
						return { sysname = platform }
					end
					local file = assert(files.create("live message"))
					files.attach(file, { process = { pid = vim.fn.getpid() } })
					local record = vim.deepcopy(file.record)
					record.boot, record.boot_id, record.platform = record.boot - 100, nil, platform
					h.write_file(file.path .. ".owner", vim.json.encode(record))
					prune_scan()
					assert(vim.uv.fs_stat(file.path), platform .. ": clock step deleted a live consumer message")
					files.release(file)
					vim.uv.os_uname = uname
				end
			end, debug.traceback)
			restore_scope()
			vim.uv.os_uname, vim.uv.kill = uname, kill
			assert(ok, err)
		end,
	}
	extra[#extra + 1] = {
		"test_source_control_commit_records_sync_before_rename",
		function()
			local files = require("lazyvcs.source_control.commit_files")
			local sync, rename, unlink = vim.uv.fs_fsync, vim.uv.fs_rename, vim.uv.fs_unlink
			local synced, renamed, file = false, 0, nil
			local ok, err = xpcall(function()
				vim.uv.fs_fsync = function(fd)
					synced = true
					return sync(fd)
				end
				vim.uv.fs_rename = function(from, to)
					assert(synced, "ownership record renamed without fsync")
					synced, renamed = false, renamed + 1
					return rename(from, to)
				end
				file = assert(files.create("private"))
				files.attach(file, { process = { pid = vim.fn.getpid() } })
				vim.uv.fs_unlink = function(path, ...)
					if path == file.path then
						return nil, "EPERM", "EPERM"
					end
					return unlink(path, ...)
				end
				files.release(file)
				assert(renamed == 3, "owner, attached PID and settlement must all sync")
			end, debug.traceback)
			vim.uv.fs_fsync, vim.uv.fs_rename, vim.uv.fs_unlink = sync, rename, unlink
			if file then
				unlink(file.path)
				unlink(file.path .. ".owner")
				unlink(file.path .. ".settled")
			end
			assert(ok, err)
		end,
	}

	for _, mode in ipairs({ "pending", "attach_failed", "legacy" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_clock_step_protects_pidless_" .. mode,
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local uname, kill, rename = vim.uv.os_uname, vim.uv.kill, vim.uv.fs_rename
				local restore_scope = linux_scope()
				local ok, err = xpcall(function()
					for _, platform in ipairs({ "Linux", "Darwin", "Windows_NT" }) do
						vim.uv.os_uname = function()
							return { sysname = platform }
						end
						for _, result in ipairs({ "alive", "EPERM", "ESRCH" }) do
							local file = assert(files.create("pending message"))
							if mode == "attach_failed" then
								vim.uv.fs_rename = function()
									return nil, "EIO: attach failed"
								end
								files.attach(file, { process = { pid = vim.fn.getpid() } })
								vim.uv.fs_rename = rename
							end
							local record = vim.json.decode(table.concat(vim.fn.readfile(file.path .. ".owner"), "\n"))
							assert(record.pid == nil, "fixture unexpectedly attached PID")
							record.boot, record.boot_id = record.boot - 100, nil
							if mode == "legacy" then
								record.editor_pid = nil
							end
							h.write_file(file.path .. ".owner", vim.json.encode(record))
							local probes = 0
							rawset(vim.uv, "kill", function(pid, signal)
								probes = probes + 1
								assert(
									mode ~= "legacy" and pid == vim.fn.getpid() and signal == 0,
									"PID-less probe used the wrong owner"
								)
								if result == "alive" then
									return true
								end
								return nil, result, result
							end)
							prune_scan()
							local released = mode ~= "legacy" and platform == "Windows_NT" and result == "ESRCH"
							assert(
								(vim.uv.fs_stat(file.path) == nil) == released,
								platform .. "/" .. result .. ": estimate alone released PID-less message"
							)
							if not released then
								local old = os.time() - vim.uv.uptime() - 10
								assert(vim.uv.fs_utime(file.path, old, old))
								prune_scan()
								assert(
									(vim.uv.fs_stat(file.path) == nil) == (mode == "legacy"),
									platform .. ": old mtime released a PID-less editor record"
								)
								if mode ~= "legacy" then
									h.write_file(file.path .. ".settled", vim.json.encode({ token = file.token }))
									prune_scan()
									assert(not vim.uv.fs_stat(file.path), "settlement did not release PID-less record")
								end
							end
							if mode ~= "legacy" then
								assert(
									record.editor_pid == vim.fn.getpid()
										and probes == (platform == "Windows_NT" and (released and 1 or 2) or 0),
									"pending ownership did not record/probe the creating editor"
								)
							end
							files.release(file)
						end
					end
				end, debug.traceback)
				restore_scope()
				vim.uv.os_uname, vim.uv.kill, vim.uv.fs_rename = uname, kill, rename
				assert(ok, err)
			end,
		}
	end
	for _, mode in ipairs({ "pending", "attach_failed" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_matching_boot_id_protects_pidless_" .. mode,
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local uname, kill, rename = vim.uv.os_uname, vim.uv.kill, vim.uv.fs_rename
				local restore_scope = linux_scope()
				local ok, err = xpcall(function()
					vim.uv.os_uname = function()
						return { sysname = "Linux" }
					end
					rawset(vim.uv, "kill", function()
						error("Linux PID-less editor record reached a PID probe")
					end)
					for _, foreign in ipairs({ false, true }) do
						local file = assert(files.create("private pending message"))
						if mode == "attach_failed" then
							vim.uv.fs_rename = function()
								return nil, "EIO: attach failed"
							end
							files.attach(file, { process = { pid = vim.fn.getpid() } })
							vim.uv.fs_rename = rename
						end
						local record = vim.json.decode(table.concat(vim.fn.readfile(file.path .. ".owner"), "\n"))
						assert(record.boot_id == "fixture-boot\n" and record.pid == nil)
						record.boot = record.boot - 100
						if foreign then
							record.namespace.ino = -1
						end
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						local old = os.time() - vim.uv.uptime() - 10
						assert(vim.uv.fs_utime(file.path, old, old))
						prune_scan()
						assert(vim.uv.fs_stat(file.path), "matching boot IDs released PID-less editor record")
						record.boot_id = "previous-boot"
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						prune_scan()
						assert(not vim.uv.fs_stat(file.path), "reboot did not release PID-less editor record")
						files.release(file)
					end
				end, debug.traceback)
				restore_scope()
				vim.uv.os_uname, vim.uv.kill, vim.uv.fs_rename = uname, kill, rename
				assert(ok, err)
			end,
		}
	end

	extra[#extra + 1] = {
		"test_source_control_commit_foreign_namespace_uses_legacy_boot_age",
		function()
			local files = require("lazyvcs.source_control.commit_files")
			local uname, kill = vim.uv.os_uname, vim.uv.kill
			local ok, err = xpcall(function()
				vim.uv.os_uname = function()
					return { sysname = "Linux" }
				end
				rawset(vim.uv, "kill", function()
					error("foreign namespace PID was probed")
				end)
				for _, mode in ipairs({ "attached", "pending", "legacy" }) do
					for _, changed in ipairs({ false, true }) do
						for _, old in ipairs({ false, true }) do
							local file = assert(files.create("foreign message"))
							local record = vim.deepcopy(file.record)
							record.pid = vim.fn.getpid()
							if mode ~= "attached" then
								record.pid = nil
							end
							if mode == "legacy" then
								record.editor_pid = nil
							end
							record.namespace = { dev = -1, ino = -1 }
							record.boot_id = nil
							if changed then
								record.boot = record.boot - 100
							end
							h.write_file(file.path .. ".owner", vim.json.encode(record))
							if old then
								local age = os.time() - vim.uv.uptime() - 10
								assert(vim.uv.fs_utime(file.path, age, age))
							end
							prune_scan()
							assert(
								(vim.uv.fs_stat(file.path) == nil) == (changed and old and mode ~= "pending"),
								"foreign namespace did not apply changed-boot legacy age rule"
							)
							files.release(file)
						end
					end
				end
			end, debug.traceback)
			vim.uv.os_uname, vim.uv.kill = uname, kill
			assert(ok, err)
		end,
	}

	local cases = {
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
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "Windows terminates running mutations at editor exit (#96)" })
				end
				active(true)
			end,
		},
	}
	vim.list_extend(cases, extra)
	return cases
end
