local helpers = require("helpers")

local function eq(left, right, msg)
	assert(vim.deep_equal(left, right), msg or (vim.inspect(left) .. " ~= " .. vim.inspect(right)))
end

local function wait_for(predicate, msg, timeout)
	local ok = vim.wait(timeout or 2000, predicate, 10)
	assert(ok, msg or "timed out")
end

local function diff_window_count()
	local count = 0
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.wo[winid].diff then
			count = count + 1
		end
	end
	return count
end

local function diff_hl_id(winid, line)
	local hl_id = 0
	vim.api.nvim_win_call(winid, function()
		hl_id = vim.fn.diff_hlID(line, 1)
	end)
	return hl_id
end

local function find_first_node(node, wanted_type)
	if not node then
		return nil
	end
	if node.type == wanted_type then
		return node
	end
	for _, child in ipairs(node.children or {}) do
		local found = find_first_node(child, wanted_type)
		if found then
			return found
		end
	end
	return nil
end

local function find_view_section(node, section)
	for _, child in ipairs(node.children or {}) do
		if child.type == "view_section" and child.extra and child.extra.section == section then
			return child
		end
	end
	return nil
end

local function install_aerial_stubs()
	local previous_aerial = package.loaded["aerial"]
	local previous_aerial_util = package.loaded["aerial.util"]
	local refetch_calls = {}
	local util_stub = {
		is_ignored_win = function(_)
			return false
		end,
	}
	package.loaded["aerial"] = {
		refetch_symbols = function(bufnr)
			refetch_calls[#refetch_calls + 1] = bufnr
		end,
	}
	package.loaded["aerial.util"] = util_stub
	package.loaded["lazyvcs.integrations.aerial"] = nil
	package.loaded["lazyvcs.layout"] = nil
	package.loaded["lazyvcs.actions"] = nil
	return refetch_calls,
		util_stub,
		function()
			package.loaded["aerial"] = previous_aerial
			package.loaded["aerial.util"] = previous_aerial_util
			package.loaded["lazyvcs.integrations.aerial"] = nil
			package.loaded["lazyvcs.layout"] = nil
			package.loaded["lazyvcs.actions"] = nil
		end
end

local function assert_transfer_session_matches(session, expected)
	eq(vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false), expected.base_lines)
	eq(diff_window_count(), 2, "transferred session should leave exactly two diff windows")
	assert(vim.wo[session.editable_win].diff, "editable window should stay in diff mode after transfer")
	assert(vim.wo[session.base_win].diff, "base window should stay in diff mode after transfer")
	assert(diff_hl_id(session.editable_win, expected.changed_line) ~= 0, "changed line should be highlighted")
	assert(diff_hl_id(session.base_win, expected.changed_line) ~= 0, "base changed line should be highlighted")
	eq(
		diff_hl_id(session.editable_win, expected.unchanged_line),
		0,
		"unchanged editable line should not be highlighted"
	)
	eq(diff_hl_id(session.base_win, expected.unchanged_line), 0, "unchanged base line should not be highlighted")
end

local function test_diff_reset()
	local diff = require("lazyvcs.diff")
	local current = { "one", "changed", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore base lines")
end

local function test_diff_reset_for_insertion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "inserted", "two", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one insertion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should remove inserted lines")
end

local function test_diff_reset_for_deletion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one deletion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore deleted lines")
end

local function test_diff_reset_for_top_deletion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "two" }
	local base = { "zero", "one", "two" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one top deletion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore top-of-file deletions")
end

local function test_config_normalization()
	local config = require("lazyvcs.config")
	local opts = config.setup({
		debounce_ms = 12.9,
		base_window = {
			width = 40,
		},
		source_control = {
			scan_depth = 4.9,
			selection_mode = "single",
			changes_view_mode = "tree",
			remote_refresh_interval_ms = 1234.9,
		},
	})

	eq(opts.debounce_ms, 12)
	eq(opts.base_window.width, 40)
	eq(opts.source_control.scan_depth, 4)
	eq(opts.source_control.show_clean, false)
	eq(opts.source_control.selection_mode, "single")
	eq(opts.source_control.changes_view_mode, "tree")
	eq(opts.source_control.remote_refresh_interval_ms, 1234)
	eq(opts.ai.commit_message.provider, "copilotchat")

	local ok, err = pcall(config.setup, {
		base_window = {
			width = 0,
		},
	})
	assert(ok == false and tostring(err):match("base_window.width"), "invalid width should fail validation")
end

local function test_source_control_auto_remote_refresh_is_throttled_per_root()
	local config = require("lazyvcs.config")
	local source = require("lazyvcs.source_control.init")
	config.setup({
		source_control = {
			remote_refresh = "on_open",
			remote_refresh_interval_ms = 60000,
		},
	})

	local state = {
		path = "/tmp/workspace",
	}

	eq(source._test_should_remote_refresh(state), true)
	eq(source._test_should_remote_refresh(state), false)

	state.lazyvcs_last_remote_refresh_at[state.path] = vim.uv.now() - 60001
	eq(source._test_should_remote_refresh(state), true)

	state.lazyvcs_remote_refresh = true
	eq(source._test_should_remote_refresh(state), true)
	state.lazyvcs_remote_refresh = nil
	eq(source._test_should_remote_refresh(state), false)
end

local function test_source_control_collects_dirty_nested_repos()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(fixture.root, 3)
	local by_root = {}
	for _, spec in ipairs(specs) do
		by_root[spec.root] = spec
	end
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(model.load_repo_details(by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(model.load_repo_summary(by_root[fixture.git_clean], {}))
	state.lazyvcs_repo_cache[fixture.svn_wc] = assert(model.load_repo_details(by_root[fixture.svn_wc], {}))
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})

	eq(#root.children, 2, "source control should render repositories and changes sections")
	eq(root.children[1].type, "view_section")
	eq(root.children[1].name, "Repositories (3)")
	eq(root.children[2].type, "view_section")
	eq(root.children[2].name, "Changes (3)")

	eq(root.children[1].children[1].type, "repo_selector")
	eq(root.children[1].children[2].type, "repo_selector")
	eq(root.children[1].children[3].type, "repo_selector")
	eq(root.children[1].children[1].name, "git-dirty")
	eq(root.children[1].children[3].name, "projects")

	eq(root.children[2].children[1].type, "repo_changes")
	eq(root.children[2].children[2].type, "repo_changes")
	eq(root.children[2].children[3].type, "repo_changes")
	eq(root.children[2].children[1].name, "git-dirty")
	eq(root.children[2].children[1].extra.vcs, "git")
	eq(root.children[2].children[1].extra.counts.local_changes, 1)
	eq(root.children[2].children[1].children[1].type, "commit_input")
	eq(root.children[2].children[1].children[2].type, "action_button")
	eq(root.children[2].children[1].children[3].type, "section")
	eq(root.children[2].children[2].name, "git-clean")
	eq(root.children[2].children[2].extra.vcs, "git")
	eq(root.children[2].children[3].name, "projects")
	eq(root.children[2].children[3].extra.vcs, "svn")
	eq(root.children[2].children[3].extra.counts.local_changes, 1)
end

local function test_source_control_progressive_collect_shows_unhydrated_repos()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
			selector_label = "VCS",
		},
	})

	local fixture = helpers.make_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(fixture.root, 3)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	eq(root.children[1].name, "Repositories (3)")
	eq(root.children[2].name, "Changes (3)")
	for _, node in ipairs(root.children[1].children) do
		eq(node.type, "repo_selector")
		eq(node.extra.sync.status, "loading")
	end
end

local function test_source_control_busy_repo_marks_nodes_disabled()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
			always_show_repositories = true,
		},
	})

	local model = require("lazyvcs.source_control.model")
	local state_mod = require("lazyvcs.state")
	local fixture = helpers.make_git_fixture()
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_details(specs[1], {
		changes_sort = "path",
	}))
	state_mod.set_repo_job(fixture.root, {
		status = "running",
		action = "sync",
		label = "Syncing...",
		sync_text = "Sync",
	})

	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})

	local repo_selector = assert(find_first_node(root, "repo_selector"))
	local repo_changes = assert(find_first_node(root, "repo_changes"))
	local file_node = assert(find_first_node(root, "file"))
	eq(repo_selector.extra.disabled, true)
	eq(repo_selector.extra.sync.status, "busy")
	eq(repo_changes.extra.disabled, true)
	eq(repo_changes.children[1].extra.disabled, true)
	eq(repo_changes.children[2].name, "Syncing...")
	eq(file_node.extra.disabled, true)

	state_mod.clear_repo_job(fixture.root)
end

local function test_source_control_async_summary_waits_for_command_callback()
	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
	}
	local pending = {}
	local summary
	model.load_repo_summary_async(repo, {}, function(args, opts, on_done)
		pending[#pending + 1] = { args = args, opts = opts, on_done = on_done }
	end, function(result)
		summary = result
	end)

	eq(summary, nil, "summary callback should not run until command output arrives")
	eq(#pending, 1)
	pending[1].on_done({ code = 0, stdout = "## main...origin/main [ahead 1]\n M lua/file.lua\n", stderr = "" })
	eq(summary.branch, "main")
	eq(summary.counts.local_changes, 1)
	eq(summary.sync.status, "outgoing")
end

local function test_source_control_background_refresh_preserves_cached_badges()
	require("lazyvcs").setup({
		source_control = {
			show_clean = true,
			always_show_repositories = true,
		},
	})

	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
	}
	local state = {
		path = "/tmp",
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = { repo },
		lazyvcs_hydration_active = true,
		lazyvcs_hydration_pending = 1,
		lazyvcs_repo_cache = {
			[repo.root] = {
				root = repo.root,
				name = repo.name,
				vcs = "git",
				order = 1,
				branch = "develop",
				counts = { local_changes = 2, staged = 0, remote = 2 },
				sync = { text = "2↓", status = "incoming", highlight = "DiagnosticInfo" },
				summary_loaded = true,
				loading_summary = true,
			},
		},
	}

	local root = model.collect(state, {
		root = "/tmp",
		scan_depth = 1,
	})
	local repo_selector = assert(find_first_node(root, "repo_selector"))
	eq(repo_selector.extra.sync.text, "2↓")
	eq(repo_selector.extra.sync.status, "incoming")
	eq(repo_selector.extra.refreshing_summary, true)
	eq(root.extra.hydration_pending, 1)
	eq(root.children[1].extra.hydration_pending, nil)
	eq(root.children[2].extra.hydration_pending, nil)
end

local function test_source_control_unloaded_repo_still_shows_loading_badge()
	require("lazyvcs").setup({
		source_control = {
			show_clean = true,
			always_show_repositories = true,
		},
	})

	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
	}
	local state = {
		path = "/tmp",
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = { repo },
		lazyvcs_repo_cache = {
			[repo.root] = vim.tbl_extend("force", model.make_placeholder(repo, {}), {
				loading_summary = true,
			}),
		},
	}

	local root = model.collect(state, {
		root = "/tmp",
		scan_depth = 1,
	})
	local repo_selector = assert(find_first_node(root, "repo_selector"))
	eq(repo_selector.extra.sync.text, "…")
	eq(repo_selector.extra.sync.status, "loading")
	eq(repo_selector.extra.refreshing_summary, false)
end

local function test_source_control_jobs_prioritize_user_work_over_background_refresh()
	require("lazyvcs").setup({
		source_control = {
			background = {
				git_workers = 1,
			},
		},
	})

	local jobs = require("lazyvcs.source_control.jobs")
	jobs.clear_history()
	local repo = {
		root = vim.fn.getcwd(),
		name = "repo",
		vcs = "git",
	}
	local order = {}
	jobs.command(repo, "active", { "sh", "-c", "sleep 0.05; echo active" }, { priority = 0 }, function()
		order[#order + 1] = "active"
	end)
	jobs.command(repo, "background", { "sh", "-c", "echo background" }, { priority = -10 }, function()
		order[#order + 1] = "background"
	end)
	jobs.command(repo, "user", { "sh", "-c", "echo user" }, { priority = 10 }, function()
		order[#order + 1] = "user"
	end)

	wait_for(function()
		return #order == 3
	end, "queued source-control jobs should finish")
	eq(order, { "active", "user", "background" })
end

local function test_source_control_svn_summary_uses_compact_branch_label()
	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/projects",
		name = "projects",
		vcs = "svn",
		order = 1,
	}
	local pending = {}
	local summary
	model.load_repo_summary_async(repo, {}, function(args, opts, on_done)
		pending[#pending + 1] = { args = args, opts = opts, on_done = on_done }
	end, function(result)
		summary = result
	end)

	eq(#pending, 1)
	pending[1].on_done({
		code = 0,
		stdout = [[<?xml version="1.0" encoding="UTF-8"?><status><target path="/tmp/projects"></target></status>]],
		stderr = "",
	})
	eq(#pending, 2)
	pending[2].on_done({
		code = 0,
		stdout = [[<?xml version="1.0" encoding="UTF-8"?>
<info><entry revision="1"><url>svn://ravesvn/Rave/projects/branches/private/KMLopez/RP-2927</url><repository><root>svn://ravesvn/Rave</root></repository></entry></info>]],
		stderr = "",
	})
	eq(summary.branch, "private/KMLopez/RP-2927")
end

local function test_source_control_single_repo_root_uses_unique_node_ids()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_summary(specs[1], {}))

	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})

	local seen = {}
	local duplicates = {}
	local function walk(node)
		if seen[node.id] then
			duplicates[node.id] = true
		end
		seen[node.id] = true
		for _, child in ipairs(node.children or {}) do
			walk(child)
		end
	end

	walk(root)
	eq(next(duplicates), nil, "single-repo source control tree should not generate duplicate node ids")
	eq(root.children[1].type, "view_section")
	eq(root.children[1].id, fixture.root .. "::changes")
	eq(root.children[1].children[1].type, "repo_changes")
	eq(root.children[1].children[1].id, model.repo_changes_id(fixture.root))
	assert(root.children[1].id ~= root.children[1].children[1].id, "view section and repo node ids must differ")
end

local function test_source_control_duplicate_repo_names_use_root_identity()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = true,
		},
	})

	local workspace = vim.fn.tempname()
	local repo_a = workspace .. "/team-a/service"
	local repo_b = workspace .. "/team-b/service"
	vim.fn.mkdir(repo_a .. "/.git", "p")
	vim.fn.mkdir(repo_b .. "/.git", "p")

	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(workspace, 3)
	table.sort(specs, function(a, b)
		return a.root < b.root
	end)

	eq(#specs, 2, "both same-named repositories should be discovered")
	eq(specs[1].name, "service")
	eq(specs[2].name, "service")
	eq(specs[1].root, vim.fs.normalize(repo_a))
	eq(specs[2].root, vim.fs.normalize(repo_b))
	eq(specs[1].path_label, "team-a/service")
	eq(specs[2].path_label, "team-b/service")

	local state = {
		path = workspace,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_repo_visibility = {
			[specs[1].root] = true,
			[specs[2].root] = true,
		},
	}
	for _, spec in ipairs(specs) do
		state.lazyvcs_repo_cache[spec.root] = model.make_placeholder(spec, {})
	end

	local root = model.collect(state, {
		root = workspace,
		scan_depth = 3,
	})

	local seen = {}
	local duplicates = {}
	local function walk(node)
		if seen[node.id] then
			duplicates[node.id] = true
		end
		seen[node.id] = true
		for _, child in ipairs(node.children or {}) do
			walk(child)
		end
	end
	walk(root)
	eq(next(duplicates), nil, "duplicate repo names should not generate duplicate node ids")

	local repositories = assert(find_view_section(root, "repositories"))
	local changes = assert(find_view_section(root, "changes"))
	eq(#repositories.children, 2)
	eq(#changes.children, 2)
	for index, spec in ipairs(specs) do
		local selector = repositories.children[index]
		local repo_changes = changes.children[index]
		eq(selector.name, "service")
		eq(selector.id, model.repo_selector_id(spec.root))
		eq(selector.extra.repo_root, spec.root)
		eq(selector.extra.path_label, spec.path_label)
		eq(selector.extra.visible, true)
		eq(repo_changes.name, "service")
		eq(repo_changes.id, model.repo_changes_id(spec.root))
		eq(repo_changes.extra.repo_root, spec.root)
		eq(repo_changes.extra.path_label, spec.path_label)
	end
end

local function test_source_control_can_show_clean_repos()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(fixture.root, 3)
	local by_root = {}
	for _, spec in ipairs(specs) do
		by_root[spec.root] = spec
	end
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_show_clean = true,
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(model.load_repo_summary(by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(model.load_repo_summary(by_root[fixture.git_clean], {}))
	state.lazyvcs_repo_cache[fixture.svn_wc] = assert(model.load_repo_summary(by_root[fixture.svn_wc], {}))
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	eq(root.children[1].name, "Repositories (3)")
	eq(root.children[2].name, "Changes (3)")
	eq(root.children[2].children[1].name, "git-dirty")
	eq(root.children[2].children[2].name, "git-clean")
	eq(root.children[2].children[3].name, "projects")
end

local function test_source_control_toggle_repo_visibility_keeps_a_visible_repo()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local specs = model.discover(fixture.root, 3)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	local first_repo = root.children[1].children[1]

	local previous_navigate = require("neo-tree.sources.manager").navigate
	require("neo-tree.sources.manager").navigate = function() end

	state.tree = {
		get_node = function()
			return first_repo
		end,
	}
	ops.toggle_repo_visibility(state)

	local visible = 0
	for _, enabled in pairs(state.lazyvcs_repo_visibility) do
		if enabled then
			visible = visible + 1
		end
	end
	assert(visible >= 1, "at least one repository should stay visible")

	require("neo-tree.sources.manager").navigate = previous_navigate
end

local function test_source_control_tree_view_groups_files_into_folders()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = true,
			changes_view_mode = "tree",
		},
	})

	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	helpers.exec({ "git", "init" }, root)
	helpers.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
	helpers.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)
	vim.fn.mkdir(root .. "/src/module", "p")
	helpers.write_file(root .. "/src/module/app.lua", "return 1\n")
	helpers.exec({ "git", "add", "src/module/app.lua" }, root)
	helpers.exec({ "git", "commit", "-m", "init" }, root)
	helpers.write_file(root .. "/src/module/app.lua", "return 2\n")

	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(root, 1)
	local state = {
		path = root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}
	state.lazyvcs_repo_cache[root] = assert(model.load_repo_details(specs[1], {
		changes_sort = "path",
	}))

	local tree = model.collect(state, {
		root = root,
		scan_depth = 1,
	})
	local changes = tree.children[1]
	eq(changes.name, "Changes (1)")
	local repo = changes.children[1]
	local section = repo.children[3]
	eq(section.type, "section")
	eq(section.children[1].type, "folder")
	eq(section.children[1].name, "src/module")
	eq(section.children[1].children[1].type, "file")
	eq(section.children[1].children[1].extra.relpath, "src/module/app.lua")
end

local function test_source_control_components_hide_low_priority_metadata_in_narrow_windows()
	local components = require("lazyvcs.source_control.components")

	local repo_node = {
		type = "repo_selector",
		name = "integrated-solutions-rdk-webserver",
		extra = {
			path_label = "platform/projects/subdir",
			counts = { local_changes = 8 },
			sync = { text = "2↓ 8↑", status = "diverged", highlight = "DiagnosticWarn" },
		},
	}
	local change_node = {
		type = "repo_changes",
		name = "integrated-solutions-rdk-webserver",
		extra = {
			branch = "feature/very-long-branch-name",
			counts = { local_changes = 8 },
			sync = { text = "2↓ 8↑", status = "diverged", highlight = "DiagnosticWarn" },
		},
	}
	local commit_node = {
		type = "commit_input",
		extra = {
			show_input_action_button = true,
			primary_label = "Sync Changes",
			draft = "",
		},
	}
	local selector_meta = components.repo_selector_meta({}, repo_node, {}, 6)
	local changes_meta = components.repo_changes_meta({}, change_node, {}, 6)

	eq(selector_meta.text, " 2↓ 8↑")
	eq(changes_meta.text, " 2↓ 8↑")
	eq(components.input_hint({}, commit_node, {}, 6), nil)
end

local function test_source_control_components_restore_metadata_in_wide_windows()
	local components = require("lazyvcs.source_control.components")

	local repo_node = {
		type = "repo_selector",
		name = "repo",
		extra = {
			path_label = "platform/projects/subdir",
			counts = { local_changes = 8 },
			sync = { text = "2↓ 8↑", status = "diverged", highlight = "DiagnosticWarn" },
		},
	}
	local change_node = {
		type = "repo_changes",
		name = "repo",
		extra = {
			branch = "feature/very-long-branch-name",
			counts = { local_changes = 8 },
			sync = { text = "2↓ 8↑", status = "diverged", highlight = "DiagnosticWarn" },
		},
	}
	local commit_node = {
		type = "commit_input",
		extra = {
			show_input_action_button = true,
			primary_label = "Sync Changes",
			draft = "",
		},
	}
	local selector_meta = components.repo_selector_meta({}, repo_node, {}, 40)
	local changes_meta = components.repo_changes_meta({}, change_node, {}, 40)

	eq(selector_meta[1].text, " platform/projects/subdir ")
	eq(selector_meta[2].text, "2↓ 8↑")
	eq(changes_meta[1].text, " feature/very-long-branch-name ")
	eq(changes_meta[2].text, "2↓ 8↑")
	eq(components.input_hint({}, commit_node, {}, 20).text, "Sync Changes")
end

local function test_source_control_components_show_short_path_when_budget_allows()
	local components = require("lazyvcs.source_control.components")
	local repo_node = {
		type = "repo_selector",
		name = "factory",
		extra = {
			path_label = "platform",
			counts = { local_changes = 2 },
			sync = { text = "2↑", status = "outgoing", highlight = "DiagnosticHint" },
		},
	}
	local meta = components.repo_selector_meta({}, repo_node, {}, 12)
	eq(meta[1].text, " platform ")
	eq(meta[2].text, "2↑")
end

local function test_source_control_components_exact_fit_regression_keeps_last_character()
	local components = require("lazyvcs.source_control.components")
	local repo_node = {
		type = "repo_selector",
		name = "factory",
		extra = {
			path_label = "platform",
			counts = { local_changes = 2 },
			sync = { text = "2↑", status = "outgoing", highlight = "DiagnosticHint" },
		},
	}
	local meta = components.repo_selector_meta({}, repo_node, {}, 12)
	eq(meta[1].text, " platform ")
	eq(meta[2].text, "2↑")
end

local function test_source_control_components_keep_repo_rows_stable_during_refresh()
	local components = require("lazyvcs.source_control.components")
	local repo_node = {
		type = "repo_selector",
		name = "factory",
		extra = {
			path_label = "platform",
			counts = { local_changes = 2 },
			sync = { text = "2↑", status = "outgoing", highlight = "DiagnosticHint" },
			refreshing_summary = true,
		},
	}

	local meta = components.repo_selector_meta({}, repo_node, {}, 13)
	eq(meta[1].text, " platform ")
	eq(meta[2].text, "2↑")
	eq(meta[3], nil)

	local root_node = {
		type = "root",
		name = "Source Control for /tmp",
		extra = {
			hydration_active = true,
			hydration_pending = 7,
		},
	}
	local root_meta = components.root_meta({}, root_node, {}, 4)
	eq(root_meta.text, "󰑓")

	root_node.extra.hydration_active = false
	eq(components.root_meta({}, root_node, {}, 4), nil)
end

local function test_source_control_hides_clean_repo_after_summary_hydration()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local specs = model.discover(fixture.root, 3)
	local by_root = {}
	for _, spec in ipairs(specs) do
		by_root[spec.root] = spec
	end
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
	}

	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(model.load_repo_summary(by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(model.load_repo_summary(by_root[fixture.git_clean], {}))
	state.lazyvcs_repo_cache[fixture.svn_wc] = assert(model.load_repo_summary(by_root[fixture.svn_wc], {}))

	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	eq(root.children[1].name, "Repositories (3)")
	eq(root.children[2].name, "Changes (3)")
	eq(root.children[2].children[1].name, "git-dirty")
	eq(root.children[2].children[2].name, "git-clean")
	eq(root.children[2].children[3].name, "projects")
end

local function test_source_control_smart_e_is_contextual()
	local common = require("neo-tree.sources.common.commands")
	local actions = require("lazyvcs.actions")
	local commands = require("lazyvcs.source_control.commands")
	local ops = require("lazyvcs.source_control.ops")
	local resized = false
	local edited = false
	local rebalanced = false
	local prev_resize = common.toggle_auto_expand_width
	local prev_edit = ops.edit_commit_message
	local prev_rebalance = actions.rebalance_tab

	---@diagnostic disable-next-line: duplicate-set-field
	common.toggle_auto_expand_width = function()
		resized = true
	end
	---@diagnostic disable-next-line: duplicate-set-field
	ops.edit_commit_message = function()
		edited = true
	end
	---@diagnostic disable-next-line: duplicate-set-field
	actions.rebalance_tab = function()
		rebalanced = true
	end

	local non_message_state = {
		tabid = 7,
		tree = {
			get_node = function()
				return { type = "repo_changes" }
			end,
		},
	}
	commands.smart_e(non_message_state)
	eq(resized, true)
	eq(edited, false)
	vim.wait(100, function()
		return rebalanced
	end)
	eq(rebalanced, true)

	resized = false
	edited = false
	rebalanced = false
	local message_state = {
		tree = {
			get_node = function()
				return { type = "commit_input" }
			end,
		},
	}
	commands.smart_e(message_state)
	eq(resized, false)
	eq(edited, true)
	eq(rebalanced, false)

	common.toggle_auto_expand_width = prev_resize
	ops.edit_commit_message = prev_edit
	actions.rebalance_tab = prev_rebalance
end

local function test_source_control_open_repo_recreates_force_expand_after_intermediate_navigate()
	local ops = require("lazyvcs.source_control.ops")
	local model = require("lazyvcs.source_control.model")
	local manager = require("neo-tree.sources.manager")

	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
		counts = { local_changes = 1, staged = 0, remote = 0 },
		sync = { status = "dirty" },
		details_loaded = false,
	}
	local state = {
		path = "/tmp",
		lazyvcs_repo_cache = {
			[repo.root] = repo,
		},
		tree = {
			get_node = function()
				return {
					type = "repo_changes",
					path = repo.root,
					extra = { repo_root = repo.root },
					get_id = function()
						return repo.root
					end,
				}
			end,
		},
	}

	local previous_navigate = manager.navigate
	local previous_load = model.load_repo_details_async
	local navigate_count = 0
	manager.navigate = function(s)
		navigate_count = navigate_count + 1
		if navigate_count == 1 then
			s.lazyvcs_force_expand = nil
		end
	end
	---@diagnostic disable-next-line: duplicate-set-field
	model.load_repo_details_async = function(_, _, _, on_done)
		on_done(vim.tbl_extend("force", repo, {
			details_loaded = true,
			sections = {},
		}))
	end

	ops.open_repo(state)

	eq(state.lazyvcs_repo_cache[repo.root].details_loaded, true)
	eq(navigate_count, 1)

	manager.navigate = previous_navigate
	model.load_repo_details_async = previous_load
end

local function test_source_control_open_repo_collapses_expanded_stale_node_first()
	local ops = require("lazyvcs.source_control.ops")
	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
		counts = { local_changes = 1, staged = 0, remote = 0 },
		sync = { status = "dirty" },
		details_loaded = false,
	}
	local state = {
		path = "/tmp",
		lazyvcs_repo_cache = {
			[repo.root] = repo,
		},
	}
	local node = {
		type = "repo_changes",
		path = repo.root,
		extra = { repo_root = repo.root },
		is_expanded = function()
			return true
		end,
		get_id = function()
			return repo.root
		end,
	}
	local previous_load = model.load_repo_details_async
	local toggled = false
	local loaded = false
	---@diagnostic disable-next-line: duplicate-set-field
	model.load_repo_details_async = function()
		loaded = true
	end

	ops.open_repo(state, node, function()
		toggled = true
	end)

	eq(toggled, true)
	eq(loaded, false)

	model.load_repo_details_async = previous_load
end

local function test_svn_status_xml_ignores_external_banner_noise()
	local model = require("lazyvcs.source_control.model")
	local util = require("lazyvcs.util")
	local previous_system = util.system

	---@diagnostic disable-next-line: duplicate-set-field
	util.system = function()
		return {
			stdout = [[<?xml version="1.0" encoding="UTF-8"?>
<status>
<target path=".">
<entry path="src/local/config/rdu-armv8.config">
<wc-status item="normal" props="none"></wc-status>
<repos-status item="modified" props="none"></repos-status>
</entry>
<entry path="src/local/bootloader/diagnostics/UBoot">
<wc-status item="external" props="none"></wc-status>
</entry>
<entry path="src/local/bootloader/diagnostics/ZiiDiagProtocol">
<wc-status item="external" props="none"></wc-status>
</entry>
</target>
</status>]],
		}
	end

	local repo = {
		root = "/tmp/factory",
		name = "factory",
		vcs = "svn",
		order = 1,
		relpath = "platform/factory",
		path_label = "platform",
	}
	local detail = assert(model.load_repo_details(repo, {
		remote_refresh = true,
		changes_sort = "path",
	}))

	eq(detail.counts.local_changes, 0)
	eq(detail.counts.remote, 1)
	eq(#detail.sections, 1)
	eq(detail.sections[1].id, "remote")
	eq(detail.sections[1].items[1].extra.relpath, "src/local/config/rdu-armv8.config")

	util.system = previous_system
end

local function test_source_control_open_change_reopens_without_base_buffer_collision()
	require("lazyvcs").setup({
		debounce_ms = 10,
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local actions = require("lazyvcs.actions")
	local state_mod = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	require("neo-tree").config = {
		open_files_using_relative_paths = false,
		keep_altfile = false,
	}
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_details(specs[1], {
		changes_sort = "path",
	}))

	local tree = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})
	local file_node = assert(find_first_node(tree, "file"))

	ops.open_change(state, file_node)
	local session = assert(state_mod.current())
	local base_name = vim.api.nvim_buf_get_name(session.base_bufnr)
	actions.close()

	local stale = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(stale, base_name)

	ops.open_change(state, file_node)
	local reopened = assert(state_mod.current())
	eq(vim.api.nvim_buf_get_lines(reopened.base_bufnr, 0, -1, false), reopened.base_lines)
	assert(diff_window_count() == 2, "VCS open_change should reopen lazyvcs diff cleanly")
	assert(not util.buf_is_valid(stale), "stale base buffer should be cleaned before reopen")

	actions.close()
end

local function test_source_control_open_change_reuses_active_diff_window()
	require("lazyvcs").setup({
		debounce_ms = 10,
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_transfer_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local state_mod = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	require("neo-tree").config = {
		open_files_using_relative_paths = false,
		keep_altfile = false,
	}
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_details(specs[1], {
		changes_sort = "path",
	}))

	local tree = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})
	local files = {}
	local function collect_files(node)
		if node.type == "file" then
			files[#files + 1] = node
		end
		for _, child in ipairs(node.children or {}) do
			collect_files(child)
		end
	end
	collect_files(tree)
	assert(#files >= 2, "fixture should expose at least two changed file nodes")

	ops.open_change(state, files[1])
	vim.wait(300, function()
		local live = state_mod.current()
		return live and live.source_path == files[1].path
	end)

	local first_session = assert(state_mod.current())
	local editable_win = first_session.editable_win

	ops.open_change(state, files[2])
	vim.wait(300, function()
		local live = state_mod.current()
		return live and live.source_path == files[2].path
	end)

	local second_session = assert(state_mod.current())
	eq(second_session.source_path, files[2].path)
	assert(diff_window_count() == 2, "repeated VCS clicks should keep a two-window diff layout")
	assert(util.win_is_valid(second_session.editable_win), "editable diff window should stay valid")
	assert(util.win_is_valid(second_session.base_win), "base diff window should stay valid")
	eq(second_session.editable_win, editable_win)

	require("lazyvcs.actions").close()
end

local function test_aerial_integration_suspends_window_and_restores_buffer_state()
	local refetch_calls, util_stub, cleanup = install_aerial_stubs()
	local aerial = require("lazyvcs.integrations.aerial")
	local current_buf = vim.api.nvim_get_current_buf()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_var(buf, "aerial_backends", { "treesitter", "lsp" })
	local state = aerial.disable_buffer(buf)
	eq(vim.api.nvim_buf_get_var(buf, "aerial_backends"), {})
	aerial.restore_buffer(state)
	eq(vim.api.nvim_buf_get_var(buf, "aerial_backends"), { "treesitter", "lsp" })

	local winid = vim.api.nvim_get_current_win()
	aerial.suspend_win(winid)
	local ignored, message = util_stub.is_ignored_win(winid)
	eq(ignored, true)
	assert(
		type(message) == "string" and message:match("lazyvcs suspended Aerial"),
		"suspended windows should report lazyvcs ignore reason"
	)
	aerial.resume_win(winid)
	eq(select(1, util_stub.is_ignored_win(winid)), false)

	aerial.refetch_buffer(current_buf)
	vim.wait(200, function()
		return #refetch_calls == 1
	end)
	eq(refetch_calls[1], current_buf)
	cleanup()
end

local function test_compute_target_view_centered_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 100,
		current_count = 3,
		base_start = 100,
		base_count = 3,
	}, 22, 200)

	eq(view.lnum, 100)
	eq(view.topline, 91)
end

local function test_compute_target_view_large_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 100,
		current_count = 40,
		base_start = 100,
		base_count = 40,
	}, 22, 200)

	eq(view.lnum, 100)
	eq(view.topline, 100)
end

local function test_compute_target_view_start_and_end_clamping()
	local diff = require("lazyvcs.diff")

	local start_view = diff.compute_target_view({
		current_start = 3,
		current_count = 2,
		base_start = 3,
		base_count = 2,
	}, 22, 200)
	eq(start_view.topline, 1)

	local end_view = diff.compute_target_view({
		current_start = 198,
		current_count = 2,
		base_start = 198,
		base_count = 2,
	}, 22, 200)
	eq(end_view.topline, 179)
end

local function test_compute_target_view_for_deletion_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 50,
		current_count = 0,
		base_start = 51,
		base_count = 1,
	}, 22, 200)

	eq(view.lnum, 50)
	eq(view.topline, 40)
end

local function test_git_backend()
	local backend = require("lazyvcs.backends.git")
	local fixture = helpers.make_git_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "git")
	eq(info.base_label, "INDEX")
	eq(info.base_lines, { "one", "two", "three" })
end

local function test_svn_backend()
	local backend = require("lazyvcs.backends.svn")
	local fixture = helpers.make_svn_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "svn")
	eq(info.base_label, "BASE")
	eq(info.base_lines, { "one", "two", "three" })
end

local function test_git_integration()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")

	local session = assert(actions.open())
	eq(session.backend, "git")
	assert(vim.wo[session.editable_win].diff, "editable window should be in diff mode")
	assert(vim.wo[session.base_win].diff, "base window should be in diff mode")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(100, function()
		return vim.deep_equal(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	end)

	eq(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	actions.close()
	assert(state.get(session.editable_bufnr) == nil, "session should be cleared after close")
end

local function test_git_reopen_tolerates_stale_base_buffer_name()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local actions = require("lazyvcs.actions")
	local util = require("lazyvcs.util")
	local session = assert(actions.open())
	local base_name = vim.api.nvim_buf_get_name(session.base_bufnr)

	actions.close()

	local stale = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(stale, base_name)

	local reopened = assert(actions.open())
	eq(vim.api.nvim_buf_get_lines(reopened.base_bufnr, 0, -1, false), reopened.base_lines)
	assert(diff_window_count() == 2, "reopened session should restore a two-window diff")
	assert(not util.buf_is_valid(stale), "stale hidden base buffer should be replaced before reopening")

	actions.close()
end

local function test_git_sessions_with_same_relpath_in_different_repos_do_not_collide()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local first_fixture = helpers.make_git_fixture()
	local second_fixture = helpers.make_git_fixture()
	local actions = require("lazyvcs.actions")

	vim.cmd.edit(vim.fn.fnameescape(first_fixture.file))
	local first_session = assert(actions.open())
	local first_name = vim.api.nvim_buf_get_name(first_session.base_bufnr)
	local first_tab = vim.api.nvim_get_current_tabpage()

	vim.cmd.tabnew()
	vim.cmd.edit(vim.fn.fnameescape(second_fixture.file))
	local second_session = assert(actions.open())
	local second_name = vim.api.nvim_buf_get_name(second_session.base_bufnr)

	assert(first_session.base_bufnr ~= second_session.base_bufnr, "sessions should not share base buffers")
	assert(first_name ~= second_name, "repo-aware base buffer names should differ across repos")

	actions.close()
	vim.cmd.tabclose()

	vim.api.nvim_set_current_tabpage(first_tab)
	actions.close(first_session.editable_bufnr)
end

local function test_git_buffer_transfer_reopens_session()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file2
	end)

	local second_session = assert(state.current())
	eq(second_session.backend, "git")
	eq(second_session.source_path, fixture.file2)
	assert(second_session.editable_bufnr ~= first_session.editable_bufnr, "should reopen on the new buffer")
	assert_transfer_session_matches(second_session, {
		base_lines = fixture.base2,
		changed_line = 4,
		unchanged_line = 2,
	})

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file1
	end)

	local third_session = assert(state.current())
	eq(third_session.backend, "git")
	eq(third_session.source_path, fixture.file1)
	assert_transfer_session_matches(third_session, {
		base_lines = fixture.base1,
		changed_line = 2,
		unchanged_line = 4,
	})

	actions.close()
end

local function test_git_buffer_transfer_refetches_aerial_after_reopen()
	local refetch_calls, util_stub, cleanup = install_aerial_stubs()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())
	eq(select(1, util_stub.is_ignored_win(first_session.editable_win)), false)

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(500, function()
		local live = state.current()
		return live and live.source_path == fixture.file2 and #refetch_calls > 0
	end)

	local second_session = assert(state.current())
	eq(second_session.source_path, fixture.file2)
	eq(refetch_calls[#refetch_calls], second_session.editable_bufnr)
	eq(select(1, util_stub.is_ignored_win(second_session.editable_win)), false)
	assert(diff_window_count() == 2, "transfer with Aerial stub should preserve the two-window diff layout")

	actions.close()
	cleanup()
end

local function test_git_rebalance_evenly_splits_active_diff_pair()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local session = assert(actions.open())

	pcall(vim.api.nvim_win_set_width, session.base_win, 20)
	actions.rebalance(session.base_bufnr)

	local live = assert(state.current())
	local editable_width = vim.api.nvim_win_get_width(live.editable_win)
	local base_width = vim.api.nvim_win_get_width(live.base_win)
	assert(math.abs(editable_width - base_width) <= 1, "rebalance should restore an even split")

	actions.close()
end

local function test_git_win_resized_rebalances_active_diff_pair()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local session = assert(actions.open())

	pcall(vim.api.nvim_win_set_width, session.base_win, 20)
	vim.api.nvim_exec_autocmds("WinResized", {})
	vim.wait(200, function()
		local live = state.current()
		if not live then
			return false
		end
		local editable_width = vim.api.nvim_win_get_width(live.editable_win)
		local base_width = vim.api.nvim_win_get_width(live.base_win)
		return math.abs(editable_width - base_width) <= 1
	end)

	local live = assert(state.current())
	assert(
		math.abs(vim.api.nvim_win_get_width(live.editable_win) - vim.api.nvim_win_get_width(live.base_win)) <= 1,
		"WinResized should rebalance the active diff pair"
	)

	actions.close()
end

local function test_git_base_window_leader_q_closes_session()
	local previous_leader = vim.g.mapleader
	vim.g.mapleader = " "

	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local session = assert(actions.open())
	local function count_close_maps(bufnr)
		local count = 0
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if map.desc == "lazyvcs close diff view" then
				count = count + 1
			end
		end
		return count
	end

	eq(count_close_maps(session.editable_bufnr), 1)
	eq(count_close_maps(session.base_bufnr), 2)

	vim.api.nvim_set_current_win(session.base_win)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>q", true, false, true), "xt", false)
	vim.wait(200, function()
		return state.get(session.base_bufnr) == nil
	end)

	eq(state.get(session.base_bufnr), nil)
	vim.g.mapleader = previous_leader
end

local function test_markdown_transfer_sets_editor_guards_and_reopens_cleanly()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_markdown_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())
	eq(first_session.source_path, fixture.file1)

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(500, function()
		local live = state.current()
		return live and live.source_path == fixture.file2
	end)

	local markdown_session = assert(state.current())
	eq(markdown_session.source_path, fixture.file2)
	eq(vim.b[markdown_session.editable_bufnr].snacks_scope, false)
	eq(vim.b[markdown_session.editable_bufnr].snacks_indent, false)
	assert(diff_window_count() == 2, "markdown transfer should keep a two-window diff layout")

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(500, function()
		local live = state.current()
		return live and live.source_path == fixture.file1
	end)

	local lua_session = assert(state.current())
	eq(lua_session.source_path, fixture.file1)
	assert(diff_window_count() == 2, "switching back from markdown should keep the diff layout stable")

	actions.close()
end

local function test_source_control_git_file_actions_commit_and_sync()
	require("lazyvcs").setup({
		debounce_ms = 10,
		source_control = {
			scan_depth = 1,
			show_clean = true,
			sync_button_behavior = "direct",
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local manager = require("neo-tree.sources.manager")
	local util = require("lazyvcs.util")
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}

	local previous_navigate = manager.navigate
	manager.navigate = function() end

	local function reload_tree()
		state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_details(specs[1], {
			changes_sort = "path",
		}))
		return model.collect(state, {
			root = fixture.root,
			scan_depth = 1,
		})
	end

	local tree = reload_tree()
	local repo_node = assert(find_first_node(tree, "repo_changes"))
	local file_node = assert(find_first_node(tree, "file"))

	ops.revert_file(state, file_node)
	eq(vim.fn.readfile(fixture.file), { "one", "two", "three" })

	helpers.write_file(fixture.file, "one\nchanged\nthree\n")
	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.stage_file(state, file_node)
	assert(helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root):match("sample.txt"))

	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.unstage_file(state, file_node)
	eq(util.trim(helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root)), "")

	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.stage_file(state, file_node)

	tree = reload_tree()
	repo_node = assert(find_first_node(tree, "repo_changes"))
	state.lazyvcs_commit_drafts[fixture.root] = "fixture commit"
	ops.commit_repo(state, repo_node)
	wait_for(function()
		return util.trim(helpers.exec({ "git", "log", "-1", "--pretty=%s" }, fixture.root)) == "fixture commit"
	end, "git commit should finish in the background")
	eq(util.trim(helpers.exec({ "git", "log", "-1", "--pretty=%s" }, fixture.root)), "fixture commit")
	eq(util.trim(helpers.exec({ "git", "status", "--short" }, fixture.root)), "")

	local remote_fixture = helpers.make_git_remote_fixture()
	local remote_specs = model.discover(remote_fixture.root, 1)
	local remote_state = {
		path = remote_fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = remote_specs,
		lazyvcs_repo_cache = {},
	}
	remote_state.lazyvcs_repo_cache[remote_fixture.root] = assert(model.load_repo_summary(remote_specs[1], {
		remote_refresh = false,
	}))
	local remote_node = {
		type = "repo_changes",
		path = remote_fixture.root,
		extra = { repo_root = remote_fixture.root },
		get_id = function()
			return remote_fixture.root
		end,
	}
	ops.sync_repo(remote_state, remote_node)
	wait_for(function()
		return util.trim(
			helpers.exec(
				{ "git", "--git-dir", remote_fixture.origin, "rev-parse", "refs/heads/main" },
				remote_fixture.root
			)
		) == util.trim(helpers.exec({ "git", "rev-parse", "HEAD" }, remote_fixture.root))
	end, "git sync should finish in the background")
	eq(
		util.trim(
			helpers.exec(
				{ "git", "--git-dir", remote_fixture.origin, "rev-parse", "refs/heads/main" },
				remote_fixture.root
			)
		),
		util.trim(helpers.exec({ "git", "rev-parse", "HEAD" }, remote_fixture.root))
	)

	manager.navigate = previous_navigate
end

local function test_source_control_git_sync_uses_explicit_upstream_fast_forward()
	require("lazyvcs").setup({
		source_control = {
			sync_button_behavior = "direct",
		},
	})

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fn.tempname()
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "develop",
				counts = { local_changes = 0, staged = 0, remote = 1 },
				sync = { status = "incoming" },
			},
		},
	}
	local node = {
		type = "repo_changes",
		path = repo_root,
		extra = { repo_root = repo_root },
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git rev-parse --abbrev-ref --symbolic-full-name @{upstream}"] = "origin/develop\n",
		["git fetch --prune --quiet origin"] = "",
		["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## develop...origin/develop [behind 1]\n",
		["git merge --ff-only origin/develop"] = "",
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		assert(responses[key] ~= nil, "unexpected command: " .. key)
		on_exit({ code = 0, stdout = responses[key], stderr = "" }, nil)
		return {}
	end

	ops.sync_repo(state, node)
	eq(calls, {
		"git rev-parse --abbrev-ref --symbolic-full-name @{upstream}",
		"git fetch --prune --quiet origin",
		"git status --branch --porcelain=v1 --untracked-files=no --ignored=no",
		"git merge --ff-only origin/develop",
	})
	assert(not table.concat(calls, "\n"):match("git pull"), "sync should not run bare git pull")
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_pull_action_uses_explicit_upstream_fast_forward()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fn.tempname()
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "develop",
				counts = { local_changes = 0, staged = 0, remote = 1 },
				sync = { status = "incoming" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "pull",
		},
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git rev-parse --abbrev-ref --symbolic-full-name @{upstream}"] = "origin/develop\n",
		["git fetch --prune --quiet origin"] = "",
		["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## develop...origin/develop [behind 1]\n",
		["git merge --ff-only origin/develop"] = "",
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		assert(responses[key] ~= nil, "unexpected command: " .. key)
		on_exit({ code = 0, stdout = responses[key], stderr = "" }, nil)
		return {}
	end

	ops.run_primary_action(state, node)
	eq(calls, {
		"git rev-parse --abbrev-ref --symbolic-full-name @{upstream}",
		"git fetch --prune --quiet origin",
		"git status --branch --porcelain=v1 --untracked-files=no --ignored=no",
		"git merge --ff-only origin/develop",
	})
	assert(not table.concat(calls, "\n"):match("git pull"), "pull action should not run bare git pull")
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_sync_pushes_to_configured_upstream()
	require("lazyvcs").setup({
		source_control = {
			sync_button_behavior = "direct",
		},
	})

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fn.tempname()
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/local",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "outgoing" },
			},
		},
	}
	local node = {
		type = "repo_changes",
		path = repo_root,
		extra = { repo_root = repo_root },
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git rev-parse --abbrev-ref --symbolic-full-name @{upstream}"] = "fork/feature/shared\n",
		["git fetch --prune --quiet fork"] = "",
		["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## feature/local...fork/feature/shared [ahead 2]\n",
		["git push fork feature/local:feature/shared"] = "",
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		assert(responses[key] ~= nil, "unexpected command: " .. key)
		on_exit({ code = 0, stdout = responses[key], stderr = "" }, nil)
		return {}
	end

	ops.sync_repo(state, node)
	eq(calls, {
		"git rev-parse --abbrev-ref --symbolic-full-name @{upstream}",
		"git fetch --prune --quiet fork",
		"git status --branch --porcelain=v1 --untracked-files=no --ignored=no",
		"git push fork feature/local:feature/shared",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_svn_integration()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local session = assert(actions.open())
	eq(session.backend, "svn")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(100, function()
		return vim.deep_equal(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	end)

	eq(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	actions.close()
end

local function test_source_control_svn_commit_and_update()
	require("lazyvcs").setup({
		debounce_ms = 10,
		use_gitsigns = false,
		source_control = {
			scan_depth = 1,
			show_clean = true,
			sync_button_behavior = "direct",
		},
	})

	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local manager = require("neo-tree.sources.manager")
	local util = require("lazyvcs.util")
	local previous_navigate = manager.navigate
	manager.navigate = function() end

	local commit_fixture = helpers.make_svn_fixture()
	local commit_specs = model.discover(commit_fixture.root, 1)
	local commit_state = {
		path = commit_fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = commit_specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	commit_state.lazyvcs_repo_cache[commit_fixture.root] = assert(model.load_repo_details(commit_specs[1], {
		changes_sort = "path",
	}))
	local commit_tree = model.collect(commit_state, {
		root = commit_fixture.root,
		scan_depth = 1,
	})
	local commit_repo_node = assert(find_first_node(commit_tree, "repo_changes"))
	commit_state.lazyvcs_commit_drafts[commit_fixture.root] = "svn fixture commit"
	ops.commit_repo(commit_state, commit_repo_node)
	wait_for(function()
		return util.trim(helpers.exec({ "svn", "status" }, commit_fixture.root)) == ""
	end, "svn commit should finish in the background")
	eq(util.trim(helpers.exec({ "svn", "status" }, commit_fixture.root)), "")
	assert(
		helpers
			.exec({ "svn", "log", "-l", "1", "file://" .. commit_fixture.repo }, commit_fixture.root)
			:match("svn fixture commit")
	)

	local update_fixture = helpers.make_svn_update_fixture()
	local update_specs = model.discover(update_fixture.root, 1)
	local update_state = {
		path = update_fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = update_specs,
		lazyvcs_repo_cache = {},
	}
	update_state.lazyvcs_repo_cache[update_fixture.root] = assert(model.load_repo_summary(update_specs[1], {
		remote_refresh = false,
	}))
	local update_node = {
		type = "repo_changes",
		path = update_fixture.root,
		extra = { repo_root = update_fixture.root },
		get_id = function()
			return update_fixture.root
		end,
	}
	ops.sync_repo(update_state, update_node)
	wait_for(function()
		return vim.deep_equal(vim.fn.readfile(update_fixture.file), { "one", "updated", "three" })
	end, "svn update should finish in the background")
	eq(vim.fn.readfile(update_fixture.file), { "one", "updated", "three" })

	manager.navigate = previous_navigate
end

local function test_source_control_busy_repo_blocks_repo_actions()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
			sync_button_behavior = "direct",
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local state_mod = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(model.load_repo_details(specs[1], {
		changes_sort = "path",
	}))
	local tree = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})
	local repo_node = assert(find_first_node(tree, "repo_changes"))
	local file_node = assert(find_first_node(tree, "file"))
	local previous_notify = util.notify
	local messages = {}

	state_mod.set_repo_job(fixture.root, {
		status = "running",
		action = "sync",
		label = "Syncing...",
		sync_text = "Sync",
	})
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function(msg)
		messages[#messages + 1] = msg
	end

	ops.sync_repo(state, repo_node)
	ops.open_change(state, file_node)

	assert(messages[1] and messages[1]:match("Syncing"), "busy repo should notify when actions are blocked")
	assert(messages[2] and messages[2]:match("Syncing"), "busy repo should block opening file diffs")

	util.notify = previous_notify
	state_mod.clear_repo_job(fixture.root)
end

local function test_source_control_git_switch_collects_refs()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_switch_fixture()
	local repo = { root = fixture.root, name = "clone", vcs = "git" }
	local switch = require("lazyvcs.source_control.switch")
	local context = assert(switch.collect(repo))
	local kinds = {}
	for _, ref in ipairs(context.refs) do
		kinds[ref.ref_kind] = kinds[ref.ref_kind] or {}
		kinds[ref.ref_kind][ref.short] = true
	end

	assert(kinds.local_branch["main"], "git switch picker should include local branches")
	assert(kinds.local_branch["feature/local"], "git switch picker should include local feature branches")
	assert(kinds.remote_branch["origin/feature/remote"], "git switch picker should include remote branches")
	assert(kinds.tag["v1.0.0"], "git switch picker should include tags")
	eq(context.head.current_branch, "main")
end

local function test_source_control_git_switch_executes_checkout_flows()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_switch_fixture()
	local repo = { root = fixture.root, name = "clone", vcs = "git" }
	local switch = require("lazyvcs.source_control.switch")
	local util = require("lazyvcs.util")
	local before_count = 0
	local after_count = 0

	local function run_pick(predicate, input_value)
		switch.open(repo, {
			select = function(items, _, on_choice)
				for _, item in ipairs(items) do
					if predicate(item) then
						on_choice(item)
						return
					end
				end
				error("picker item not found")
			end,
			input = function(_, on_submit)
				on_submit(input_value)
			end,
			before_mutation = function()
				before_count = before_count + 1
				return true
			end,
			after_mutation = function()
				after_count = after_count + 1
			end,
			notify = function() end,
		})
	end

	run_pick(function(item)
		return item.kind == "local_branch" and item.short == "feature/local"
	end)
	eq(util.trim(helpers.exec({ "git", "branch", "--show-current" }, fixture.root)), "feature/local")

	run_pick(function(item)
		return item.kind == "remote_branch" and item.short == "origin/feature/remote"
	end)
	eq(util.trim(helpers.exec({ "git", "branch", "--show-current" }, fixture.root)), "feature/remote")
	eq(
		util.trim(
			helpers.exec({ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, fixture.root)
		),
		"origin/feature/remote"
	)

	run_pick(function(item)
		return item.kind == "tag" and item.short == "v1.0.0"
	end)
	eq(util.trim(helpers.exec({ "git", "branch", "--show-current" }, fixture.root)), "")
	eq(util.trim(helpers.exec({ "git", "describe", "--tags", "--exact-match", "HEAD" }, fixture.root)), "v1.0.0")

	run_pick(function(item)
		return item.kind == "command" and item.action == "git_create_branch"
	end, "feature/new-ui")
	eq(util.trim(helpers.exec({ "git", "branch", "--show-current" }, fixture.root)), "feature/new-ui")
	eq(before_count, 4)
	eq(after_count, 4)
end

local function test_source_control_svn_switch_supports_standard_and_manual_layouts()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local switch = require("lazyvcs.source_control.switch")
	local util = require("lazyvcs.util")
	local standard_fixture = helpers.make_svn_switch_fixture()
	local standard_repo = { root = standard_fixture.root, name = "projects", vcs = "svn" }
	local before_count = 0
	local after_count = 0

	switch.open(standard_repo, {
		select = function(items, _, on_choice)
			for _, item in ipairs(items) do
				if item.kind == "svn_branch" and item.label == "release" then
					on_choice(item)
					return
				end
			end
			error("svn branch target not found")
		end,
		before_mutation = function()
			before_count = before_count + 1
			return true
		end,
		after_mutation = function()
			after_count = after_count + 1
		end,
		notify = function() end,
	})

	eq(
		util.trim(helpers.exec({ "svn", "info", "--show-item", "url" }, standard_fixture.root)),
		standard_fixture.release_url
	)
	eq(before_count, 1)
	eq(after_count, 1)

	local nonstandard_fixture = helpers.make_svn_fixture()
	local nonstandard_repo = { root = nonstandard_fixture.root, name = "sample", vcs = "svn" }
	local context = assert(switch.collect(nonstandard_repo))
	eq(#context.items, 1)
	eq(context.items[1].action, "svn_switch_url")
end

local function test_source_control_switch_repo_closes_matching_sessions_and_refreshes_repo()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local switch = require("lazyvcs.source_control.switch")
	local actions = require("lazyvcs.actions")
	local session_state = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {
			[fixture.root] = { root = fixture.root, name = "repo" },
			["/tmp/other"] = { root = "/tmp/other", name = "other" },
		},
		lazyvcs_loading_details = {},
	}
	local node = {
		type = "repo_changes",
		path = fixture.root,
		extra = { repo_root = fixture.root },
		get_id = function()
			return fixture.root
		end,
	}

	local previous_open_async = switch.open_async
	local previous_close = actions.close
	local previous_system_start = util.system_start
	local previous_sessions = session_state.sessions
	local previous_buffer_index = session_state.buffer_index
	local closed = {}

	session_state.sessions = {
		[11] = { root = fixture.root, editable_bufnr = 11 },
		[22] = { root = "/tmp/other", editable_bufnr = 22 },
	}
	session_state.buffer_index = {}
	---@diagnostic disable-next-line: duplicate-set-field
	switch.open_async = function(repo, opts)
		opts.on_ready(repo)
		opts.before_mutation(repo)
		opts.run_mutation(repo, { short = "main" }, { "git", "switch", "main" }, { cwd = repo.root })
	end
	---@diagnostic disable-next-line: duplicate-set-field
	actions.close = function(bufnr)
		closed[#closed + 1] = bufnr
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(_args, _opts, on_exit)
		on_exit({ code = 0, stdout = "", stderr = "" }, nil)
		return {}
	end

	ops.switch_repo(state, node)
	wait_for(function()
		return state.lazyvcs_repo_cache[fixture.root] == nil and session_state.get_repo_job(fixture.root) == nil
	end, "switch repo should invalidate cache after async completion")
	eq(closed, { 11 })
	eq(state.lazyvcs_repo_cache[fixture.root], nil)
	assert(state.lazyvcs_repo_cache["/tmp/other"], "other repo cache should stay intact")

	switch.open_async = previous_open_async
	actions.close = previous_close
	util.system_start = previous_system_start
	session_state.sessions = previous_sessions
	session_state.buffer_index = previous_buffer_index
end

local function test_svn_buffer_transfer_reopens_session()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file2
	end)

	local second_session = assert(state.current())
	eq(second_session.backend, "svn")
	eq(second_session.source_path, fixture.file2)
	assert(second_session.editable_bufnr ~= first_session.editable_bufnr, "should reopen on the new buffer")
	assert_transfer_session_matches(second_session, {
		base_lines = fixture.base2,
		changed_line = 4,
		unchanged_line = 2,
	})

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file1
	end)

	local third_session = assert(state.current())
	eq(third_session.backend, "svn")
	eq(third_session.source_path, fixture.file1)
	assert_transfer_session_matches(third_session, {
		base_lines = fixture.base1,
		changed_line = 2,
		unchanged_line = 4,
	})

	actions.close()
end

local function test_transfer_to_unsupported_buffer_closes_session()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.enew()
	vim.wait(300, function()
		return state.get(first_session.editable_bufnr) == nil and diff_window_count() == 0
	end)

	eq(state.get(first_session.editable_bufnr), nil, "old session should close on unsupported buffer transfer")
	eq(diff_window_count(), 0, "unsupported buffer transfer should clear tab diff state")
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "base window should close on unsupported buffer transfer")
end

test_diff_reset()
test_diff_reset_for_insertion()
test_diff_reset_for_deletion()
test_diff_reset_for_top_deletion()
test_config_normalization()
test_source_control_auto_remote_refresh_is_throttled_per_root()
test_compute_target_view_centered_hunk()
test_compute_target_view_large_hunk()
test_compute_target_view_start_and_end_clamping()
test_compute_target_view_for_deletion_hunk()
test_git_backend()
test_svn_backend()
test_source_control_collects_dirty_nested_repos()
test_source_control_progressive_collect_shows_unhydrated_repos()
test_source_control_busy_repo_marks_nodes_disabled()
test_source_control_async_summary_waits_for_command_callback()
test_source_control_background_refresh_preserves_cached_badges()
test_source_control_unloaded_repo_still_shows_loading_badge()
test_source_control_jobs_prioritize_user_work_over_background_refresh()
test_source_control_svn_summary_uses_compact_branch_label()
test_source_control_single_repo_root_uses_unique_node_ids()
test_source_control_duplicate_repo_names_use_root_identity()
test_source_control_can_show_clean_repos()
test_source_control_toggle_repo_visibility_keeps_a_visible_repo()
test_source_control_tree_view_groups_files_into_folders()
test_source_control_components_hide_low_priority_metadata_in_narrow_windows()
test_source_control_components_restore_metadata_in_wide_windows()
test_source_control_components_show_short_path_when_budget_allows()
test_source_control_components_exact_fit_regression_keeps_last_character()
test_source_control_components_keep_repo_rows_stable_during_refresh()
test_source_control_hides_clean_repo_after_summary_hydration()
test_source_control_smart_e_is_contextual()
test_source_control_open_repo_recreates_force_expand_after_intermediate_navigate()
test_source_control_open_repo_collapses_expanded_stale_node_first()
test_svn_status_xml_ignores_external_banner_noise()
test_source_control_open_change_reopens_without_base_buffer_collision()
test_source_control_open_change_reuses_active_diff_window()
test_aerial_integration_suspends_window_and_restores_buffer_state()
test_git_integration()
test_git_reopen_tolerates_stale_base_buffer_name()
test_git_sessions_with_same_relpath_in_different_repos_do_not_collide()
test_git_buffer_transfer_reopens_session()
test_git_buffer_transfer_refetches_aerial_after_reopen()
test_git_rebalance_evenly_splits_active_diff_pair()
test_git_win_resized_rebalances_active_diff_pair()
test_git_base_window_leader_q_closes_session()
test_markdown_transfer_sets_editor_guards_and_reopens_cleanly()
test_source_control_git_file_actions_commit_and_sync()
test_source_control_git_sync_uses_explicit_upstream_fast_forward()
test_source_control_git_pull_action_uses_explicit_upstream_fast_forward()
test_source_control_git_sync_pushes_to_configured_upstream()
test_source_control_busy_repo_blocks_repo_actions()
test_source_control_git_switch_collects_refs()
test_source_control_git_switch_executes_checkout_flows()
test_svn_integration()
test_source_control_svn_commit_and_update()
test_source_control_svn_switch_supports_standard_and_manual_layouts()
test_source_control_switch_repo_closes_matching_sessions_and_refreshes_repo()
test_svn_buffer_transfer_reopens_session()
test_transfer_to_unsupported_buffer_closes_session()

print("lazyvcs tests: ok")
