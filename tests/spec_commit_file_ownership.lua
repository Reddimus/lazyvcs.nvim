return function(ctx)
	local h, p, wait = ctx.helpers, require("process_helpers"), ctx.wait_for
	local pruning = require("commit_file_helpers")
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
	local variants = {
		{ platform = "Linux", name = "Linux_boot_id" },
		{ platform = "Linux", name = "Linux_ENOENT", boot_id_error = "ENOENT" },
		{ platform = "Linux", name = "Linux_EACCES", boot_id_error = "EACCES" },
		{ platform = "Darwin", name = "Darwin" },
		{ platform = "Windows_NT", name = "Windows_NT" },
	}
	local function policy(platform, opts)
		local files = require("lazyvcs.source_control.commit_files")
		local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
		vim.fn.mkdir(dir, "p")
		local path = dir .. "/policy.txt"
		-- Capture inside the caller's scope, so permission stubs delegate to its
		-- simulated /proc and both cleanup paths restore that same scope.
		local uname, kill, open, unlink = vim.uv.os_uname, vim.uv.kill, vim.uv.fs_open, vim.uv.fs_unlink
		local record = {
			version = 1,
			token = "policy",
			boot = os.time() - vim.uv.uptime(),
			platform = platform,
			pid = vim.fn.getpid(),
		}
		if platform == "Linux" then
			record.namespace = { dev = 12, ino = 34 }
			record.boot_id = "fixture-boot\n"
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
			pruning.scan(files.prune, wait)
		end
		local ok, err = xpcall(function()
			save(record)
			scan()
			assert(vim.uv.fs_stat(path), "age alone released an owned message")
			for _, result in ipairs({ "alive", "ESRCH", "EPERM" }) do
				rawset(vim.uv, "kill", function(pid, signal)
					assert(pid == record.pid and signal == 0)
					if result == "alive" then
						return true
					end
					return nil, result .. ": probe", result
				end)
				save(record)
				scan()
				assert((vim.uv.fs_stat(path) == nil) == (result == "ESRCH"), platform .. ": wrong liveness release")
			end
			for _, mode in ipairs({
				"foreign",
				"unknown",
				"permission",
				"receipt",
				"wrong_receipt",
				"boot",
				"missing_boot_id",
			}) do
				local value = vim.deepcopy(record)
				if mode == "foreign" and value.namespace then
					value.namespace.ino = value.namespace.ino + 1
				end
				if mode == "unknown" or (mode == "foreign" and not value.namespace) then
					value.pid = nil
				end
				if mode == "boot" or mode == "missing_boot_id" then
					value.boot, value.boot_id, value.pid = value.boot - 100, "another boot", nil
					if mode == "missing_boot_id" then
						value.boot_id = nil
					end
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
					(vim.uv.fs_stat(path) == nil)
						== (mode == "receipt" or (mode == "boot" and platform == "Linux" and not opts.boot_id_error)),
					platform .. "/" .. mode .. ": wrong ownership release"
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

	local function linux_scope()
		return pruning.scope(h)
	end

	local function prune_scan()
		pruning.scan(require("lazyvcs.source_control.commit_files").prune, wait)
	end

	local extra = {}
	for _, variant in ipairs(variants) do
		extra[#extra + 1] = {
			"test_source_control_commit_previous_boot_" .. variant.name,
			function(notices)
				local files = require("lazyvcs.source_control.commit_files")
				local kill = vim.uv.kill
				local restore = pruning.scope(h, variant.platform, variant)
				local file
				local ok, err = xpcall(function()
					-- Prove that the machine-side boot ID failure affects recording too.
					file = assert(files.create("previous boot message"))
					assert(file.record.platform == variant.platform, "platform simulation was bypassed")
					assert((file.record.boot_id ~= nil) == (variant.name == "Linux_boot_id"))
					for _, mode in ipairs({ "attached", "old_pidless", "recent_pidless" }) do
						local record = vim.deepcopy(file.record)
						local boot = os.time() - vim.uv.uptime()
						record.boot = boot - 172800
						-- First use no boot ID pair, so ESRCH and age must each work alone.
						record.boot_id, record.pid = nil, nil
						if mode == "attached" then
							record.pid = vim.fn.getpid()
						end
						h.write_file(file.path, "previous boot message")
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						local mtime = boot - (mode == "old_pidless" and 86410 or 10)
						assert(vim.uv.fs_utime(file.path, mtime, mtime))
						local probes = 0
						rawset(vim.uv, "kill", function(pid, signal)
							probes = probes + 1
							assert(pid == vim.fn.getpid() and signal == 0)
							if mode == "attached" then
								return nil, "ESRCH: previous boot consumer", "ESRCH"
							end
							return true -- Keep the Windows creating editor alive.
						end)
						prune_scan()
						assert(
							(vim.uv.fs_stat(file.path) == nil) == (mode ~= "recent_pidless"),
							variant.name .. "/" .. mode .. ": wrong previous-boot release"
						)
						assert(
							probes
								== (
									mode == "attached" and 1
									or (variant.platform == "Windows_NT" and mode == "recent_pidless" and 1 or 0)
								)
						)
						if variant.name == "Linux_boot_id" then
							-- Restore the real boot ID pair: the changed ID releases even
							-- the recent PID-less record, without any liveness probe.
							record.boot_id = "previous-boot"
							if mode ~= "recent_pidless" then
								h.write_file(file.path, "previous boot message")
								assert(vim.uv.fs_utime(file.path, mtime, mtime))
							end
							h.write_file(file.path .. ".owner", vim.json.encode(record))
							rawset(vim.uv, "kill", function()
								error("changed boot ID reached liveness probe")
							end)
							prune_scan()
							assert(
								not vim.uv.fs_stat(file.path),
								"changed boot ID did not release previous-boot record"
							)
						end
					end
					assert(#notices == 0, "previous-boot pruning reported an error")
				end, debug.traceback)
				restore()
				vim.uv.kill = kill
				if file then
					files.release(file)
				end
				assert(ok, err)
			end,
		}
	end
	for _, mode in ipairs({ "missing", "unreadable", "malformed", "token", "platform", "version" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_prunes_previous_boot_" .. mode .. "_owner",
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local open = vim.uv.fs_open
				local ok, err = xpcall(function()
					for _, age in ipairs({ 0, 10, 86390, 86410 }) do
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
						if age > 0 then
							local before_boot = os.time() - vim.uv.uptime() - age
							assert(vim.uv.fs_utime(file.path, before_boot, before_boot))
						end
						prune_scan()
						assert(
							(vim.uv.fs_stat(file.path) == nil) == (age > 86400),
							mode .. ": wrong legacy age release"
						)
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
				local old = os.time() - vim.uv.uptime() - 86410
				assert(vim.uv.fs_utime(sidecar, old, old))
				prune_scan()
				assert(vim.uv.fs_stat(sidecar), "owned sidecar was removed")
				assert(vim.uv.fs_unlink(file.path))
				local recent = os.time() - vim.uv.uptime() - 10
				assert(vim.uv.fs_utime(sidecar, recent, recent))
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
		"test_source_control_commit_clock_step_requires_consumer_evidence",
		function()
			local files = require("lazyvcs.source_control.commit_files")
			local uname, kill = vim.uv.os_uname, vim.uv.kill
			local restore_scope = linux_scope()
			local ok, err = xpcall(function()
				for _, platform in ipairs({ "Linux", "Darwin", "Windows_NT" }) do
					vim.uv.os_uname = function()
						return { sysname = platform }
					end
					for _, result in ipairs({ "alive", "EPERM", "ESRCH" }) do
						local file = assert(files.create("live message"))
						files.attach(file, { process = { pid = vim.fn.getpid() } })
						local record = vim.deepcopy(file.record)
						record.boot, record.boot_id = record.boot - 100, nil
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						local probes = 0
						rawset(vim.uv, "kill", function(pid, signal)
							assert(pid == record.pid and signal == 0)
							probes = probes + 1
							if result == "alive" then
								return true
							end
							return nil, result, result
						end)
						prune_scan()
						assert(
							(vim.uv.fs_stat(file.path) == nil) == (result == "ESRCH"),
							platform .. "/" .. result .. ": estimate change alone released consumer message"
						)
						assert(probes == 1, "consumer was not probed after estimate change")
						files.release(file)
					end
					vim.uv.os_uname = uname
				end
			end, debug.traceback)
			restore_scope()
			vim.uv.os_uname, vim.uv.kill = uname, kill
			assert(ok, err)
		end,
	}
	extra[#extra + 1] = {
		"test_source_control_commit_matching_boot_id_keeps_old_live_message",
		function()
			-- Issue #107 on Linux: an active commit's day-old message survives another editor's setup.
			local files = require("lazyvcs.source_control.commit_files")
			local uname, kill = vim.uv.os_uname, vim.uv.kill
			local restore_scope = linux_scope()
			local file
			local ok, err = xpcall(function()
				vim.uv.os_uname = function()
					return { sysname = "Linux" }
				end
				file = assert(files.create("live message"))
				files.attach(file, { process = { pid = vim.fn.getpid() } })
				assert(file.record.boot_id, "fixture boot ID was not recorded")
				local aged = os.time() - vim.uv.uptime() - 86410
				assert(vim.uv.fs_utime(file.path, aged, aged))
				local probes = 0
				rawset(vim.uv, "kill", function(pid, signal)
					assert(pid == file.record.pid and signal == 0)
					probes = probes + 1
					return true
				end)
				prune_scan()
				assert(vim.uv.fs_stat(file.path), "matching boot ID released a live consumer's old message")
				assert(probes == 1, "live consumer was not probed")
			end, debug.traceback)
			restore_scope()
			vim.uv.os_uname, vim.uv.kill = uname, kill
			if file then
				files.release(file)
			end
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

	for _, platform in ipairs({ "Darwin", "Linux", "Windows_NT" }) do
		for _, mode in ipairs({ "pending", "attach_failed", "legacy" }) do
			extra[#extra + 1] = {
				"test_source_control_commit_pidless_cleanup_" .. platform .. "_" .. mode,
				function(notices)
					local files = require("lazyvcs.source_control.commit_files")
					local uname, kill, rename = vim.uv.os_uname, vim.uv.kill, vim.uv.fs_rename
					local restore_scope = linux_scope()
					local ok, err = xpcall(function()
						vim.uv.os_uname = function()
							return { sysname = platform }
						end
						for _, changed in ipairs({ true, false }) do
							for _, result in ipairs({ "alive", "ESRCH", "EPERM" }) do
								local file = assert(files.create("pending message"))
								if mode == "attach_failed" then
									local before = #notices
									vim.uv.fs_rename = function()
										return nil, "EIO: attach failed"
									end
									files.attach(file, { process = { pid = vim.fn.getpid() } })
									vim.uv.fs_rename = rename
									assert(
										#notices == before + 1
											and notices[#notices]:match("Commit message cleanup failed:.*attach failed")
									)
								end
								-- Read the durable record, including a crash before attachment.
								local record =
									vim.json.decode(table.concat(vim.fn.readfile(file.path .. ".owner"), "\n"))
								assert(record.pid == nil, "fixture unexpectedly attached PID")
								record.boot_id = nil
								if changed then
									record.boot = record.boot - 100
								end
								if mode == "legacy" then
									record.editor_pid = nil
								end
								h.write_file(file.path .. ".owner", vim.json.encode(record))
								local probes = 0
								rawset(vim.uv, "kill", function(pid, signal)
									probes = probes + 1
									assert(pid == vim.fn.getpid() and signal == 0, "wrong creating editor probe")
									if result == "alive" then
										return true
									end
									return nil, result, result
								end)
								prune_scan()
								local released = platform == "Windows_NT" and mode ~= "legacy" and result == "ESRCH"
								assert(
									(vim.uv.fs_stat(file.path) == nil) == released,
									platform .. "/" .. result .. ": wrong fresh PID-less release"
								)
								if not released then
									local boot = os.time() - vim.uv.uptime()
									for _, age in ipairs({ 10, 86390, 86410 }) do
										assert(vim.uv.fs_utime(file.path, boot - age, boot - age))
										prune_scan()
										assert(
											(vim.uv.fs_stat(file.path) == nil) == (age > 86400),
											platform .. ": wrong one-day PID-less age release at " .. age
										)
									end
								end
								assert(
									probes
										== (
											(platform == "Windows_NT" and mode ~= "legacy")
												and (released and 1 or 3)
											or 0
										),
									"PID-less cleanup probed an unverifiable owner"
								)
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
	end
	for _, mode in ipairs({ "pending", "attach_failed" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_matching_boot_id_protects_pidless_" .. mode,
			function(notices)
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
							local before = #notices
							vim.uv.fs_rename = function()
								return nil, "EIO: attach failed"
							end
							files.attach(file, { process = { pid = vim.fn.getpid() } })
							vim.uv.fs_rename = rename
							assert(
								#notices == before + 1
									and notices[#notices]:match("Commit message cleanup failed:.*attach failed")
							)
						end
						local record = vim.json.decode(table.concat(vim.fn.readfile(file.path .. ".owner"), "\n"))
						assert(record.boot_id == "fixture-boot\n" and record.pid == nil)
						record.boot = record.boot - 100
						if foreign then
							record.namespace.ino = -1
						end
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						local old = os.time() - vim.uv.uptime() - 86410
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
		"test_source_control_commit_foreign_namespace_requires_one_day_margin",
		function()
			local files = require("lazyvcs.source_control.commit_files")
			local uname, kill = vim.uv.os_uname, vim.uv.kill
			local restore_scope = linux_scope()
			local ok, err = xpcall(function()
				vim.uv.os_uname = function()
					return { sysname = "Linux" }
				end
				rawset(vim.uv, "kill", function()
					error("foreign namespace PID was probed")
				end)
				for _, mode in ipairs({ "attached", "pending", "legacy" }) do
					for _, changed in ipairs({ false, true }) do
						for _, age in ipairs({ 0, 10, 86390, 86410 }) do
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
							if age > 0 then
								local mtime = os.time() - vim.uv.uptime() - age
								assert(vim.uv.fs_utime(file.path, mtime, mtime))
							end
							prune_scan()
							assert(
								(vim.uv.fs_stat(file.path) == nil) == (age > 86400),
								"foreign namespace did not apply one-day margin"
							)
							files.release(file)
						end
					end
				end
			end, debug.traceback)
			restore_scope()
			vim.uv.os_uname, vim.uv.kill = uname, kill
			assert(ok, err)
		end,
	}

	for _, platform in ipairs({ "Darwin", "Linux", "Windows_NT" }) do
		extra[#extra + 1] = {
			"test_source_control_commit_attached_one_day_margin_" .. platform,
			function()
				local files = require("lazyvcs.source_control.commit_files")
				local uname, kill = vim.uv.os_uname, vim.uv.kill
				local restore_scope = linux_scope()
				local ok, err = xpcall(function()
					vim.uv.os_uname = function()
						return { sysname = platform }
					end
					for _, result in ipairs({ "alive", "EPERM" }) do
						local file = assert(files.create("attached message"))
						files.attach(file, { process = { pid = vim.fn.getpid() } })
						local record = vim.deepcopy(file.record)
						record.boot_id = nil
						h.write_file(file.path .. ".owner", vim.json.encode(record))
						rawset(vim.uv, "kill", function()
							if result == "alive" then
								return true
							end
							return nil, result, result
						end)
						for _, age in ipairs({ 10, 86390, 86410 }) do
							local mtime = os.time() - vim.uv.uptime() - age
							assert(vim.uv.fs_utime(file.path, mtime, mtime))
							prune_scan()
							assert((vim.uv.fs_stat(file.path) == nil) == (age > 86400), "wrong attached age release")
						end
						files.release(file)
					end
				end, debug.traceback)
				restore_scope()
				vim.uv.os_uname, vim.uv.kill = uname, kill
				assert(ok, err)
			end,
		}
	end

	local cases = {
		{
			"test_source_control_commit_pruning_requires_ownership_evidence",
			function(notices)
				for _, variant in ipairs(variants) do
					local restore = pruning.scope(h, variant.platform, variant)
					local ok, err = xpcall(function()
						policy(variant.platform, variant)
					end, debug.traceback)
					restore()
					assert(ok, err)
				end
				assert(#notices == 0, "ownership policy reported an error")
			end,
		},
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
	for _, case in ipairs(cases) do
		case[2] = pruning.notified(case[2])
	end
	return cases
end
