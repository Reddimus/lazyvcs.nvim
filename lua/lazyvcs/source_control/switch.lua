local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")
local picker = require("lazyvcs.picker")
local svn_xml = require("lazyvcs.backends.xml")

local M = {}

local FIELD_SEP = "\0"
local SWITCH_TIMEOUT_MS = 30000
local format_picker_item

local function icon_for_kind(kind)
	local icons = {
		command = "+",
		local_branch = "",
		remote_branch = "󰘬",
		tag = "",
		svn_trunk = "󰘢",
		svn_branch = "󰘬",
		svn_tag = "",
		svn_url = "󰌘",
	}
	return icons[kind] or "•"
end

local function picker_search_text(item)
	local parts = {
		item.label,
		item.short,
		item.description,
		item.detail,
		item.group,
		item.kind,
	}
	return table.concat(
		vim.tbl_filter(function(part)
			return part and part ~= ""
		end, parts),
		" "
	)
end

local function snacks_branch_select(items, opts, on_choice)
	local ok, picker = pcall(require, "snacks.picker")
	if not ok or not picker or type(picker.pick) ~= "function" then
		return nil
	end

	local completed = false
	return picker.pick({
		source = "lazyvcs_git_switch",
		title = opts.prompt or "Select a branch or tag to checkout",
		finder = function()
			local finder_items = {}
			for index, item in ipairs(items) do
				local finder_item = setmetatable({
					idx = index,
					item = item,
					text = picker_search_text(item),
				}, { __index = item })
				finder_items[#finder_items + 1] = finder_item
			end
			return finder_items
		end,
		format = function(item)
			return format_picker_item(item.item or item, true)
		end,
		layout = {
			preset = "vscode",
			layout = {
				width = 0.55,
				min_width = 72,
				height = 0.35,
			},
		},
		matcher = {
			sort_empty = false,
			fuzzy = true,
			smartcase = true,
		},
		sort = {
			fields = { "score:desc", "idx" },
		},
		actions = {
			confirm = function(active_picker, item)
				if completed then
					return
				end
				completed = true
				active_picker:close()
				vim.schedule(function()
					on_choice(item and item.item or nil)
				end)
			end,
		},
		on_close = function()
			if completed then
				return
			end
			completed = true
			vim.schedule(function()
				on_choice(nil)
			end)
		end,
	})
end

local function default_select(items, opts, on_choice)
	local picker_opts = {
		prompt = opts.prompt,
		format_item = function(item, supports_chunks)
			if supports_chunks and opts.format_item then
				return opts.format_item(item, true)
			end
			if opts.format_item then
				return opts.format_item(item, false)
			end
			return tostring(item.label or item.text or item.name or "")
		end,
	}

	if opts.kind == "git_switch" and snacks_branch_select(items, picker_opts, on_choice) then
		return
	end

	return picker.select(items, {
		prompt = picker_opts.prompt,
		format_item = picker_opts.format_item,
		snacks = {
			layout = "select",
			matcher = { sort_empty = true },
		},
	}, on_choice)
end

local function default_input(opts, on_submit)
	return require("lazyvcs.source_control.input").open_text(opts, on_submit)
end

local function defaults(opts)
	opts = opts or {}
	opts.notify = opts.notify or util.notify
	opts.select = opts.select or default_select
	opts.input = opts.input or default_input
	opts.before_mutation = opts.before_mutation or function(...)
		local _ = { ... }
		return true
	end
	opts.after_mutation = opts.after_mutation or function(...)
		local _ = { ... }
	end
	opts.on_ready = opts.on_ready or function(...)
		local _ = { ... }
	end
	return opts
end

local function async_defaults(opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	opts.run_mutation = opts.run_mutation
		or function(repo, _choice, args, mutation_opts)
			return util.system_start(args, { cwd = mutation_opts.cwd or repo.root }, function(result, err, raw)
				if err then
					return mutation_opts.on_error(err, raw)
				end
				mutation_opts.on_success(result, raw)
			end)
		end
	return defaults(opts)
end

local function git_ref_kind(refname)
	if refname:match("^refs/heads/") then
		return "local_branch"
	end
	if refname:match("^refs/remotes/") then
		return "remote_branch"
	end
	if refname:match("^refs/tags/") then
		return "tag"
	end
	return "ref"
end

local function parse_git_ref_records(raw)
	local refs = {}
	for _, record in ipairs(util.split_lines(raw or "")) do
		local fields = vim.split(record, FIELD_SEP, { plain = true, trimempty = false })
		if #fields >= 10 then
			local refname = fields[1]
			local short = fields[2]
			if short ~= "" and not short:match("/HEAD$") then
				refs[#refs + 1] = {
					refname = refname,
					short = short,
					ref_kind = git_ref_kind(refname),
					short_hash = fields[3],
					relative_date = fields[4],
					iso_date = fields[5],
					author = fields[6],
					subject = fields[7],
					upstream = fields[8],
					track = fields[9],
					current = fields[10] == "*",
				}
			end
		end
	end
	return refs
end

local function git_command_items()
	return {
		{
			kind = "command",
			action = "git_create_branch",
			label = "Create new branch...",
			description = "from current HEAD",
			detail = "Create and switch to a new local branch",
			group = "commands",
			order = 1,
		},
		{
			kind = "command",
			action = "git_create_branch_from",
			label = "Create new branch from...",
			description = "choose a starting ref",
			detail = "Select a branch or tag, then create a new branch from it",
			group = "commands",
			order = 2,
		},
		{
			kind = "command",
			action = "git_checkout_detached",
			label = "Checkout detached...",
			description = "switch without a branch",
			detail = "Choose a branch or tag and check it out detached",
			group = "commands",
			order = 3,
		},
	}
end

local function git_picker_items(context, opts)
	opts = opts or {}
	local items = {}
	if opts.include_commands ~= false then
		vim.list_extend(items, git_command_items())
	end

	local groups = {
		local_branch = "local_branches",
		remote_branch = "remote_branches",
		tag = "tags",
	}
	local order = {
		commands = 1,
		local_branches = 10,
		remote_branches = 20,
		tags = 30,
	}

	for _, ref in ipairs(context.refs) do
		if not opts.allowed or opts.allowed[ref.ref_kind] then
			local item = vim.tbl_extend("force", ref, {
				kind = ref.ref_kind,
				label = ref.short,
				description = ref.relative_date,
				detail = string.format("%s  %s  %s", ref.short_hash, ref.author, ref.subject),
				group = groups[ref.ref_kind] or "refs",
				order = order[groups[ref.ref_kind] or "refs"] or 10,
				seq = #items + 1,
			})
			items[#items + 1] = item
		end
	end

	table.sort(items, function(a, b)
		if (a.order or 99) ~= (b.order or 99) then
			return (a.order or 99) < (b.order or 99)
		end
		return (a.seq or 0) < (b.seq or 0)
	end)

	return items
end

local parse_svn_info_xml = svn_xml.parse_info
local parse_svn_list_xml = svn_xml.parse_list

local function svn_date_label(iso_date)
	if not iso_date or iso_date == "" then
		return ""
	end
	return iso_date:sub(1, 10)
end

local function detect_svn_layout(url)
	-- Match exact layout path segments with a non-greedy root. Greedy patterns
	-- misclassified URLs whose repository/root happened to contain "trunk" or
	-- "branches" as a substring.
	local candidates = {}
	local base, suffix = url:match("^(.-)/trunk/(.*)$")
	if not base then
		base = url:match("^(.-)/trunk/?$")
		suffix = ""
	end
	if base then
		candidates[#candidates + 1] = {
			layout_root = base,
			target_kind = "trunk",
			target_name = "trunk",
			suffix = suffix or "",
		}
	end

	local branch_base, branch_name, branch_suffix = url:match("^(.-)/branches/([^/]+)/(.*)$")
	if not branch_base then
		branch_base, branch_name = url:match("^(.-)/branches/([^/]+)/?$")
		branch_suffix = ""
	end
	if branch_base then
		candidates[#candidates + 1] = {
			layout_root = branch_base,
			target_kind = "branch",
			target_name = branch_name,
			suffix = branch_suffix or "",
		}
	end

	local tag_base, tag_name, tag_suffix = url:match("^(.-)/tags/([^/]+)/(.*)$")
	if not tag_base then
		tag_base, tag_name = url:match("^(.-)/tags/([^/]+)/?$")
		tag_suffix = ""
	end
	if tag_base then
		candidates[#candidates + 1] = {
			layout_root = tag_base,
			target_kind = "tag",
			target_name = tag_name,
			suffix = tag_suffix or "",
		}
	end

	table.sort(candidates, function(a, b)
		return #a.layout_root < #b.layout_root
	end)
	if candidates[1] then
		candidates[1].standard = true
		return candidates[1]
	end

	return {
		standard = false,
		current_url = url,
	}
end

local function build_svn_target_url(layout, target_kind, target_name)
	local root = layout.layout_root
	local suffix = layout.suffix ~= "" and ("/" .. layout.suffix) or ""
	if target_kind == "trunk" then
		return root .. "/trunk" .. suffix
	end
	if target_kind == "branch" then
		return string.format("%s/branches/%s%s", root, target_name, suffix)
	end
	return string.format("%s/tags/%s%s", root, target_name, suffix)
end

local function add_svn_target(items, layout, target_kind, entry, current)
	local label
	local kind
	if target_kind == "trunk" then
		label = "trunk"
		kind = "svn_trunk"
	else
		label = entry.name
		kind = target_kind == "branch" and "svn_branch" or "svn_tag"
	end
	items[#items + 1] = {
		kind = kind,
		target_kind = target_kind,
		target_name = entry and entry.name or "trunk",
		label = label,
		description = entry and svn_date_label(entry.date) or "",
		detail = entry and string.format("r%s  %s", entry.revision, entry.author) or "",
		current = current,
		target_url = build_svn_target_url(layout, target_kind, entry and entry.name or "trunk"),
		group = target_kind == "trunk" and "trunk" or (target_kind == "branch" and "branches" or "tags"),
		order = target_kind == "trunk" and 2 or (target_kind == "branch" and 3 or 4),
		seq = #items + 1,
	}
end

function M.collect_async(repo, run_command, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done, { cancel_id = opts.cancel_id })
	local function run(args, command_opts, callback)
		command_opts = vim.tbl_extend("keep", command_opts or {}, {
			timeout_ms = opts.timeout_ms or SWITCH_TIMEOUT_MS,
		})
		local handle = run_command(args, command_opts, function(...)
			if not task.cancelled and not task.done then
				callback(...)
			end
		end)
		task:add(handle)
		return handle
	end
	local function finish(...)
		return task:finish(...)
	end

	if repo.vcs == "git" then
		run({ "git", "branch", "--show-current" }, { kind = "switch" }, function(branch_result)
			local branch = util.trim(branch_result and branch_result.stdout or "")
			local function with_head(head)
				run({
					"git",
					"for-each-ref",
					"--sort=-committerdate",
					"--format=%(refname)"
						.. "%00%(refname:short)"
						.. "%00%(objectname:short)"
						.. "%00%(committerdate:relative)"
						.. "%00%(committerdate:iso8601-strict)"
						.. "%00%(authorname)"
						.. "%00%(subject)"
						.. "%00%(upstream:short)"
						.. "%00%(upstream:track)"
						.. "%00%(HEAD)",
					"refs/heads",
					"refs/remotes",
					"refs/tags",
				}, { kind = "switch" }, function(result, err)
					if not result then
						return finish(nil, err)
					end
					local refs = parse_git_ref_records(result.stdout)
					local locals_by_name = {}
					local locals_by_upstream = {}
					for _, ref in ipairs(refs) do
						if ref.ref_kind == "local_branch" then
							locals_by_name[ref.short] = ref
							if ref.upstream and ref.upstream ~= "" then
								locals_by_upstream[ref.upstream] = ref
							end
						end
					end
					finish({
						repo = repo,
						vcs = "git",
						head = head,
						refs = refs,
						locals_by_name = locals_by_name,
						locals_by_upstream = locals_by_upstream,
						items = nil,
					})
				end)
			end
			if branch ~= "" then
				return with_head({
					current_branch = branch,
					detached = false,
					head = branch,
				})
			end
			run({ "git", "rev-parse", "--short", "HEAD" }, { kind = "switch" }, function(short_result, short_err)
				local short = util.trim(short_result and short_result.stdout or "")
				with_head({
					current_branch = nil,
					detached = short_result ~= nil,
					unborn = short_result == nil,
					head = short ~= "" and short or "HEAD",
					error = short_result and nil or short_err,
				})
			end)
		end)
		return task
	end

	run({ "svn", "info", "--xml", repo.root }, { kind = "switch" }, function(info_result, info_err)
		if not info_result then
			return finish(nil, info_err)
		end
		local info = parse_svn_info_xml(info_result.stdout)
		if not info or not info.url then
			return finish(nil, "Unable to parse svn info for " .. repo.name)
		end
		local layout = detect_svn_layout(info.url)
		local context = {
			repo = repo,
			vcs = "svn",
			info = info,
			layout = layout,
			current_target = layout.standard
					and (layout.target_kind == "trunk" and "trunk" or (layout.target_kind == "branch" and ("branches/" .. layout.target_name) or ("tags/" .. layout.target_name)))
				or nil,
		}
		local items = {
			{
				kind = "command",
				action = "svn_switch_url",
				label = "Switch URL...",
				description = layout.standard and "manual target" or info.url,
				detail = "Enter a repository URL and switch this working copy to it",
				group = "commands",
				order = 1,
			},
		}
		if not layout.standard then
			context.items = items
			return finish(context)
		end

		-- Distinct name: a local `finish` here would shadow the outer `finish`
		-- above and make the call below recurse into itself.
		local function finish_sorted()
			table.sort(items, function(a, b)
				if (a.order or 99) ~= (b.order or 99) then
					return (a.order or 99) < (b.order or 99)
				end
				return (a.seq or 0) < (b.seq or 0)
			end)
			context.items = items
			finish(context)
		end

		run({ "svn", "info", "--xml", layout.layout_root .. "/trunk" }, { kind = "switch" }, function(trunk_info)
			if trunk_info then
				local trunk_meta = parse_svn_info_xml(trunk_info.stdout) or {}
				add_svn_target(items, layout, "trunk", {
					name = "trunk",
					revision = trunk_meta.revision or "",
					author = "",
					date = "",
				}, layout.target_kind == "trunk")
			else
				add_svn_target(items, layout, "trunk", nil, layout.target_kind == "trunk")
			end
			run({ "svn", "ls", "--xml", layout.layout_root .. "/branches" }, { kind = "switch" }, function(branches)
				if branches then
					for _, entry in ipairs(parse_svn_list_xml(branches.stdout)) do
						add_svn_target(
							items,
							layout,
							"branch",
							entry,
							layout.target_kind == "branch" and layout.target_name == entry.name
						)
					end
				end
				run({ "svn", "ls", "--xml", layout.layout_root .. "/tags" }, { kind = "switch" }, function(tags)
					if tags then
						for _, entry in ipairs(parse_svn_list_xml(tags.stdout)) do
							add_svn_target(
								items,
								layout,
								"tag",
								entry,
								layout.target_kind == "tag" and layout.target_name == entry.name
							)
						end
					end
					finish_sorted()
				end)
			end)
		end)
	end)
	return task
end

local function group_label(item)
	local map = {
		commands = "",
		local_branches = "branches",
		remote_branches = "remote branches",
		tags = "tags",
		trunk = "trunk",
		branches = "branches",
		tags_svn = "tags",
	}
	return map[item.group] or item.group or ""
end

local function item_description(item)
	if item.kind == "remote_branch" and item.short_hash and item.short_hash ~= "" then
		return "Remote branch at " .. item.short_hash
	end
	if item.kind == "tag" and item.short_hash and item.short_hash ~= "" then
		return "Tag at " .. item.short_hash
	end
	if item.current then
		return "Current branch"
	end
	if item.kind == "local_branch" and item.short_hash and item.short_hash ~= "" then
		return item.short_hash
	end
	return item.description or ""
end

function format_picker_item(item, chunks)
	local icon = icon_for_kind(item.kind)
	local current = item.current and "✓ " or ""
	local label = item.label or ""
	local description = item_description(item)
	local detail = util.truncate(item.subject or item.detail or "", 64)
	local category = group_label(item)

	if not chunks then
		local prefix = current .. icon
		local line = prefix .. " " .. label
		if description ~= "" then
			line = line .. "  " .. description
		end
		if detail ~= "" and detail ~= description then
			line = line .. "  " .. detail
		end
		if category ~= "" then
			line = line .. "  " .. category
		end
		return line
	end

	local ret = {
		{ current, item.current and "Special" or "Comment" },
		{ icon .. " ", "Identifier" },
		{ label, item.kind == "command" and "Function" or "String" },
	}
	if description ~= "" then
		ret[#ret + 1] = { "  " .. description, "Comment" }
	end
	if detail ~= "" and detail ~= description then
		ret[#ret + 1] = { "  " .. detail, "Comment" }
	end
	if category ~= "" then
		ret[#ret + 1] = {
			col = 0,
			virt_text = { { category, "Comment" } },
			virt_text_pos = "right_align",
			hl_mode = "combine",
		}
	end
	return ret
end

local function select_items(items, opts, on_choice)
	opts = defaults(opts)
	return opts.select(items, {
		prompt = opts.prompt,
		kind = opts.kind,
		format_item = format_picker_item,
	}, on_choice)
end

local function prompt_text(opts, title, prompt, default_value, on_submit)
	return opts.input({
		title = title,
		prompt = prompt,
		default_value = default_value,
	}, on_submit)
end

local function perform(repo, choice, opts, args)
	opts = defaults(opts)
	if opts.before_mutation(repo, choice) == false then
		return
	end

	return opts.run_mutation(repo, choice, args, {
		cwd = repo.root,
		on_success = function(result)
			opts.after_mutation(repo, choice, result)
		end,
		on_error = function(err)
			opts.notify(err, vim.log.levels.ERROR)
		end,
	})
end

local function git_checkout(repo, item, context, opts)
	if item.ref_kind == "local_branch" then
		if context.head.current_branch == item.short then
			return opts.notify(item.short .. " is already checked out", vim.log.levels.INFO)
		end
		return perform(repo, item, opts, { "git", "switch", item.short })
	end

	if item.ref_kind == "remote_branch" then
		local existing = context.locals_by_upstream[item.short]
		if existing then
			if context.head.current_branch == existing.short then
				return opts.notify(existing.short .. " is already checked out", vim.log.levels.INFO)
			end
			return perform(repo, existing, opts, { "git", "switch", existing.short })
		end

		local tail = item.short:match("^[^/]+/(.+)$") or item.short
		local function finish(name)
			name = util.trim(name or "")
			if name == "" then
				return
			end
			if context.locals_by_name[name] then
				opts.notify("Local branch already exists: " .. name, vim.log.levels.WARN)
				return
			end
			perform(repo, item, opts, { "git", "switch", "--track", "-c", name, item.short })
		end

		if context.locals_by_name[tail] then
			return prompt_text(opts, string.format(" Track Remote Branch: %s ", repo.name), " ", tail, finish)
		end
		return finish(tail)
	end

	return perform(repo, item, opts, { "git", "switch", "--detach", item.short })
end

local function git_create_branch(repo, base_ref, context, opts)
	local title = base_ref and string.format(" New Branch From %s: %s ", base_ref.short, repo.name)
		or string.format(" New Branch: %s ", repo.name)
	return prompt_text(opts, title, " ", "", function(name)
		name = util.trim(name or "")
		if name == "" then
			return
		end
		if context.locals_by_name[name] then
			opts.notify("Local branch already exists: " .. name, vim.log.levels.WARN)
			return
		end

		local args = { "git", "switch", "-c", name }
		if base_ref and base_ref.short then
			args[#args + 1] = base_ref.short
		end
		perform(repo, {
			kind = "command",
			action = "git_create_branch",
			label = name,
		}, opts, args)
	end)
end

local function pick_git_refs(context, opts, spec, on_choice)
	local items = git_picker_items(context, spec)
	return select_items(items, {
		prompt = spec.prompt,
		kind = "git_switch",
		select = opts.select,
		input = opts.input,
		notify = opts.notify,
		before_mutation = opts.before_mutation,
		after_mutation = opts.after_mutation,
		run_mutation = opts.run_mutation,
	}, on_choice)
end

local function execute_git(repo, context, choice, opts)
	if choice.kind == "command" then
		if choice.action == "git_create_branch" then
			return git_create_branch(repo, nil, context, opts)
		end
		if choice.action == "git_create_branch_from" then
			return pick_git_refs(context, opts, {
				include_commands = false,
				allowed = {
					local_branch = true,
					remote_branch = true,
					tag = true,
				},
				prompt = "Create new branch from " .. repo.name,
			}, function(ref)
				if ref then
					git_create_branch(repo, ref, context, opts)
				end
			end)
		end
		if choice.action == "git_checkout_detached" then
			return pick_git_refs(context, opts, {
				include_commands = false,
				allowed = {
					local_branch = true,
					remote_branch = true,
					tag = true,
				},
				prompt = "Checkout detached in " .. repo.name,
			}, function(ref)
				if ref then
					perform(repo, ref, opts, { "git", "switch", "--detach", ref.short })
				end
			end)
		end
		return
	end

	return git_checkout(repo, choice, context, opts)
end

local function svn_manual_switch(repo, context, opts)
	return prompt_text(opts, string.format(" Switch SVN URL: %s ", repo.name), "󰌘 ", context.info.url, function(url)
		url = util.trim(url or "")
		if url == "" or url == context.info.url then
			return
		end

		perform(repo, {
			kind = "svn_url",
			label = url,
			target_url = url,
		}, opts, { "svn", "switch", url, repo.root })
	end)
end

local function execute_svn(repo, context, choice, opts)
	if choice.kind == "command" then
		return svn_manual_switch(repo, context, opts)
	end

	local current_url = context.info.url
	if choice.target_url == current_url then
		return opts.notify(choice.label .. " is already checked out", vim.log.levels.INFO)
	end
	return perform(repo, choice, opts, { "svn", "switch", "--ignore-ancestry", choice.target_url, repo.root })
end

function M.open_async(repo, opts, run_command)
	opts = async_defaults(opts)
	return M.collect_async(repo, run_command, function(context, err)
		opts.on_ready(repo, err)
		if not context then
			opts.notify(err or ("Unable to load switch targets for " .. repo.name), vim.log.levels.ERROR)
			return
		end

		local items = context.vcs == "git" and git_picker_items(context) or context.items
		if not items or #items == 0 then
			opts.notify("No switch targets found for " .. repo.name, vim.log.levels.WARN)
			return
		end

		return select_items(items, {
			prompt = context.vcs == "git" and ("Checkout branch or tag for " .. repo.name)
				or ("Switch working copy for " .. repo.name),
			kind = context.vcs == "git" and "git_switch" or nil,
			select = opts.select,
			input = opts.input,
			notify = opts.notify,
			before_mutation = opts.before_mutation,
			after_mutation = opts.after_mutation,
		}, function(choice)
			if not choice then
				return
			end
			if context.vcs == "git" then
				return execute_git(repo, context, choice, opts)
			end
			return execute_svn(repo, context, choice, opts)
		end)
	end, {
		timeout_ms = opts.timeout_ms or SWITCH_TIMEOUT_MS,
		cancel_id = opts.cancel_id,
	})
end

function M._test_git_picker_items(context, opts)
	return git_picker_items(context, opts)
end

function M._test_format_picker_item(item, chunks)
	return format_picker_item(item, chunks)
end

return M
