local common = require("lazyvcs.backends.comparison")
local util = require("lazyvcs.util")
local M = {}

local function command(task, repo, args, cb)
	local argv = { "git", "--literal-pathspecs" }
	vim.list_extend(argv, args)
	common.command(task, repo, argv, cb)
end

function M.context(repo, callback)
	local task = common.task(callback)
	command(task, repo, { "symbolic-ref", "--quiet", "--short", "HEAD" }, function(branch, err, raw)
		if err and (not raw or raw.code ~= 1) then
			return task:finish(nil, err)
		end
		command(
			task,
			repo,
			{ "for-each-ref", "--format=%(refname:short)\t%(symref)", "refs/heads", "refs/remotes" },
			function(refs, refs_err)
				if not refs then
					return task:finish(nil, refs_err)
				end
				local context = { branch = branch and util.trim(branch), candidates = {}, suggestion = nil }
				for line in refs:gmatch("[^\n]+") do
					local name, target = line:match("^(.-)\t(.*)$")
					if name and target == "" then
						context.candidates[#context.candidates + 1] = name
					end
					if name == "origin/HEAD" then
						context.suggestion = target:gsub("^refs/remotes/", "")
					end
				end
				if not context.suggestion then
					for _, name in ipairs(context.candidates) do
						if name == "main" or name == "master" then
							context.suggestion = name
							break
						end
					end
				end
				task:finish(context)
			end
		)
	end)
	return task
end

function M.resolve(repo, base, callback)
	local task = common.task(callback)
	command(task, repo, { "rev-parse", "--verify", "HEAD^{commit}" }, function(head, head_err)
		if not head then
			return task:finish(nil, "A committed HEAD is required: " .. tostring(head_err))
		end
		command(task, repo, { "rev-parse", "--verify", "--end-of-options", base .. "^{commit}" }, function(oid, err)
			if not oid then
				return task:finish(nil, "Cannot resolve comparison base: " .. tostring(err))
			end
			command(task, repo, { "merge-base", "--all", util.trim(head), util.trim(oid) }, function(bases, base_err)
				if not bases then
					return task:finish(
						nil,
						"No common ancestor; check unrelated or shallow history: " .. tostring(base_err)
					)
				end
				local values = util.split_lines(bases)
				if #values ~= 1 then
					return task:finish(nil, "Multiple merge bases; select a specific ancestor commit as the base")
				end
				task:finish({ root = repo.root, vcs = "git", base = base, revision = values[1], head = util.trim(head) })
			end)
		end)
	end)
	return task
end

function M.list(snapshot, include_untracked, callback)
	local task = common.task(callback)
	command(task, snapshot, {
		"diff",
		"--no-ext-diff",
		"--no-textconv",
		"--name-status",
		"-z",
		"--find-renames",
		"-l1000",
		snapshot.revision,
		"--",
	}, function(raw, err)
		if not raw then
			return task:finish(nil, err)
		end
		local fields = vim.split(raw, "\0", { plain = true, trimempty = true })
		local items, by_path, i = {}, {}, 1
		while i <= #fields do
			local code, path = fields[i], fields[i + 1]
			if not path then
				return task:finish(nil, "Invalid Git comparison output")
			end
			local item = { status = code:sub(1, 1), relpath = path }
			i = i + 2
			if item.status == "R" or item.status == "C" then
				item.old_path, item.relpath, i = path, fields[i], i + 1
			end
			if not item.relpath then
				return task:finish(nil, "Invalid Git rename output")
			end
			items[#items + 1], by_path[item.relpath] = item, item
		end
		local function finish()
			table.sort(items, function(a, b)
				return a.relpath < b.relpath
			end)
			command(task, snapshot, {
				"diff",
				"--no-ext-diff",
				"--no-textconv",
				"--numstat",
				"-z",
				"--find-renames",
				"-l1000",
				snapshot.revision,
				"--",
			}, function(stats, stats_err)
				if not stats then
					return task:finish(nil, stats_err)
				end
				local index, cursor = {}, 1
				while cursor <= #stats do
					local last = stats:find("\0", cursor, true)
					if not last then
						return task:finish(nil, "Invalid Git line statistics")
					end
					local added, deleted, path = stats:sub(cursor, last - 1):match("^(%S+)\t(%S+)\t(.*)$")
					if not path then
						return task:finish(nil, "Invalid Git line statistics")
					end
					cursor = last + 1
					if path == "" then
						local old_end = stats:find("\0", cursor, true)
						local new_end = old_end and stats:find("\0", old_end + 1, true)
						if not new_end then
							return task:finish(nil, "Invalid Git rename statistics")
						end
						path, cursor = stats:sub(old_end + 1, new_end - 1), new_end + 1
					end
					index[path] = { added = tonumber(added), deleted = tonumber(deleted) }
				end
				for _, item in ipairs(items) do
					local value = index[item.relpath]
					if value and not item.recreated then
						item.added, item.deleted = value.added, value.deleted
					end
				end
				task:finish(items)
			end)
		end
		if not include_untracked then
			return finish()
		end
		command(task, snapshot, { "ls-files", "--others", "--exclude-standard", "-z" }, function(others, others_err)
			if not others then
				return task:finish(nil, others_err)
			end
			local collisions = {}
			for path in others:gmatch("([^%z]+)%z") do
				local existing = by_path[path]
				if existing then
					existing.status = "M"
					existing.recreated = true
					collisions[#collisions + 1] = existing
				else
					items[#items + 1] = { status = "?", relpath = path, untracked = true }
				end
			end
			local cursor = 0
			local function reconcile()
				cursor = cursor + 1
				local item = collisions[cursor]
				if not item then
					local filtered = {}
					for _, value in ipairs(items) do
						if not value.identical then
							filtered[#filtered + 1] = value
						end
					end
					items = filtered
					return finish()
				end
				command(
					task,
					snapshot,
					{ "ls-tree", "-z", snapshot.revision, "--", item.relpath },
					function(tree, tree_err)
						if not tree then
							return task:finish(nil, tree_err)
						end
						local mode, oid = tree:match("^(%d+) blob (%x+)\t")
						if not oid or mode == "120000" then
							return reconcile()
						end
						command(
							task,
							snapshot,
							{ "hash-object", "--path=" .. item.relpath, "--", item.relpath },
							function(hash, hash_err)
								if not hash then
									return task:finish(nil, hash_err)
								end
								local stat = vim.uv.fs_lstat(snapshot.root .. "/" .. item.relpath)
								local executable = stat and bit.band(stat.mode, 73) ~= 0
								item.identical = util.trim(hash) == oid
									and (vim.fn.has("win32") == 1 or executable == (mode == "100755"))
								reconcile()
							end
						)
					end
				)
			end
			reconcile()
		end)
	end)
	return task
end

function M.preview(snapshot, item, callback)
	local task = common.task(callback)
	local result =
		{ left_label = snapshot.base .. " @ " .. snapshot.revision:sub(1, 12), right_label = "SAVED WORKTREE" }
	local function right()
		if item.status == "D" then
			result.right = {}
			return task:finish(result)
		end
		common.read_file(task, snapshot.root .. "/" .. item.relpath, function(data, err)
			if not data then
				return task:finish(nil, err)
			end
			local lines, line_err = common.lines(data)
			if not lines then
				return task:finish(nil, line_err)
			end
			result.right = lines
			task:finish(result)
		end)
	end
	if item.status == "A" or item.untracked then
		result.left = {}
		right()
	else
		command(
			task,
			snapshot,
			{ "show", "--no-ext-diff", snapshot.revision .. ":" .. (item.old_path or item.relpath) },
			function(data, err)
				if not data then
					return task:finish(nil, err)
				end
				local lines, line_err = common.lines(data)
				if not lines then
					return task:finish(nil, line_err)
				end
				result.left = lines
				right()
			end
		)
	end
	return task
end

return M
