local helpers = require("helpers")

-- Redirect persisted UI state to a throwaway dir so tests never touch the real
-- stdpath("state") file and cannot leak the inline-blame toggle between runs.
local store = require("lazyvcs.store")
local STORE_DIR = vim.fs.normalize(vim.fn.tempname())
store._test_set_dir(STORE_DIR)

local function eq(left, right, msg)
	assert(vim.deep_equal(left, right), msg or (vim.inspect(left) .. " ~= " .. vim.inspect(right)))
end

local function wait_for(predicate, msg, timeout)
	local ok = vim.wait(timeout or 2000, predicate, 10)
	assert(ok, msg or "timed out")
end

-- Budget for waits that depend on real VCS subprocesses: opening a diff resolves
-- the backend and reads the base, and a buffer transfer does the same again
-- while the signs autocmd runs its own commands against the same working copy.
-- Two contended spawns regularly exceed a 2s budget on Windows, which shows up
-- as a flaky suite rather than a real failure. Waits that assert something must
-- NOT happen keep the short default.
local ASYNC_TIMEOUT_MS = 15000

local function async_command_runner(cwd)
	return function(args, opts, on_done)
		opts = opts or {}
		return require("lazyvcs.util").system_start(args, {
			cwd = opts.cwd or cwd,
			timeout = opts.timeout_ms,
		}, on_done)
	end
end

local function await_repo_loader(loader, repo, opts)
	local completed = false
	local loaded
	local err
	loader(repo, opts or {}, async_command_runner(repo.root), function(result, load_err)
		loaded = result
		err = load_err
		completed = true
	end)
	wait_for(function()
		return completed
	end, "async repository load did not finish", 5000)
	return loaded, err
end

local function load_repo_summary(model, repo, opts)
	return await_repo_loader(model.load_repo_summary_async, repo, opts)
end

local function load_repo_details(model, repo, opts)
	return await_repo_loader(model.load_repo_details_async, repo, opts)
end

local function collect_switch_targets(switch, repo)
	local completed = false
	local context
	local err
	switch.collect_async(repo, async_command_runner(repo.root), function(result, collect_err)
		context = result
		err = collect_err
		completed = true
	end)
	wait_for(function()
		return completed
	end, "async switch-target collection did not finish", 5000)
	return context, err
end

-- `actions.open` resolves the backend off the UI thread, so it returns a
-- cancellable task rather than a session; `on_open` delivers the session once
-- the backend replies. A buffer that already has a live session is returned
-- synchronously instead. Tests await the session the same way a user sees it
-- appear, rather than forcing the open path to block.
local function open_diff(opts)
	local actions = require("lazyvcs.actions")
	local opened
	local immediate = actions.open(vim.tbl_extend("force", opts or {}, {
		on_open = function(session)
			opened = session
		end,
	}))
	if type(immediate) == "table" and immediate.editable_bufnr then
		return immediate
	end
	-- Opening spawns a real backend resolve plus a base read, and the signs
	-- autocmd runs its own commands against the same working copy at the same
	-- time. Two contended process spawns routinely exceed wait_for's 2s default
	-- on Windows, so give the await room rather than letting load make the suite
	-- flaky.
	wait_for(function()
		return opened ~= nil
	end, "live diff session should open", ASYNC_TIMEOUT_MS)
	return assert(opened)
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function refresh_signs(signs, bufnr)
	local completed = false
	local state
	local err
	signs.refresh(bufnr, true, function(loaded, load_err)
		state = loaded
		err = load_err
		completed = true
	end)
	-- signs.refresh reads the VCS base through a subprocess; `svn cat -r BASE` in
	-- particular is slower than its Git counterpart and overran the short default.
	wait_for(function()
		return completed
	end, "async signs refresh did not finish", ASYNC_TIMEOUT_MS)
	return state, err
end

local function inline_blame_text(bufnr)
	local test_state = require("lazyvcs.blame")._test_inline_state()
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, test_state.namespace, 0, -1, { details = true })
	if #marks == 0 then
		return nil
	end
	return marks[1][4].virt_text and marks[1][4].virt_text[1][1] or nil
end

local function flatten_chunks(chunks)
	local text = {}
	for _, chunk in ipairs(chunks or {}) do
		if type(chunk[1]) == "string" then
			text[#text + 1] = chunk[1]
		end
	end
	return table.concat(text)
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

local function with_diffopt_flag(flag, enabled, fn)
	local previous = vim.o.diffopt
	local entries = {}
	for _, entry in ipairs(vim.split(previous, ",", { plain = true })) do
		if entry ~= flag then
			entries[#entries + 1] = entry
		end
	end
	if enabled then
		entries[#entries + 1] = flag
	end
	vim.o.diffopt = table.concat(entries, ",")

	local ok, err = xpcall(fn, debug.traceback)
	vim.o.diffopt = previous
	if not ok then
		error(err, 0)
	end
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
	eq(opts.source_control.auto_expand_width, false)
	eq(opts.source_control.auto_expand_max_width_ratio, 0.5)
	eq(opts.source_control.selection_mode, "single")
	eq(opts.source_control.changes_view_mode, "tree")
	eq(opts.source_control.remote_refresh_interval_ms, 1234)
	eq(opts.ai.commit_message.provider, "copilotchat")
	eq(opts.ai.commit_message.provider_order, { "copilotchat", "claude", "codex", "gemini", "copilot_cli" })
	eq(opts.ai.commit_message.instructions, "")
	eq(opts.ai.commit_message.timeout_ms, 30000)
	eq(opts.ai.commit_message.max_context_chars, 12000)
	eq(opts.ai.commit_message.context, "staged_first")
	eq(opts.ai.commit_message.generate_key, "gm")
	eq(opts.ai.commit_message.insert_generate_key, "<C-g>")
	eq(opts.ai.commit_message.confirm_privacy, true)
	eq(opts.signs.enabled, true)
	eq(opts.signs.debounce_ms, 120)
	eq(opts.blame.mode, "inline")
	eq(opts.blame.persist, true)
	eq(opts.blame.delay_ms, 150)
	eq(opts.blame.loading_delay_ms, 750)
	eq(opts.blame.loading_text, "Blame loading...")
	eq(opts.blame.uncommitted_text, "Uncommitted line")
	eq(opts.blame.max_width, 80)
	eq(opts.blame.split_min_width, 20)
	eq(opts.blame.split_max_width, 34)

	local ok, err = pcall(config.setup, {
		base_window = {
			width = 0,
		},
	})
	assert(ok == false and tostring(err):match("base_window.width"), "invalid width should fail validation")

	ok, err = pcall(config.setup, {
		blame = {
			mode = "bad",
		},
	})
	assert(ok == false and tostring(err):match("blame.mode"), "invalid blame mode should fail validation")

	ok, err = pcall(config.setup, {
		ai = {
			commit_message = {
				provider = "bad",
			},
		},
	})
	assert(
		ok == false and tostring(err):match("ai.commit_message.provider"),
		"invalid AI provider should fail validation"
	)
end

local function test_source_control_auto_remote_refresh_is_throttled_per_root()
	local config = require("lazyvcs.config")
	local source = require("lazyvcs.source_control.native")
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

local function test_source_control_rejects_removed_neotree_ui()
	local config = require("lazyvcs.config")
	-- The Neo-tree adapter was removed; the option value must be rejected outright
	-- rather than silently accepted and ignored.
	local ok, err = pcall(config.setup, {
		source_control = {
			ui = "neo-tree",
			remote_refresh = "manual",
		},
	})
	assert(not ok, "source_control.ui = 'neo-tree' should be rejected")
	assert(tostring(err):match("'auto' or 'native'"), tostring(err))

	local opts = config.setup({ source_control = { ui = "native", remote_refresh = "manual" } })
	eq(opts.source_control.ui, "native")
	assert(require("lazyvcs.source_control.native")._test_should_remote_refresh({ path = "/tmp/workspace" }) == false)
end

local function test_optional_integrations_detect_vanilla_and_enhanced_modes()
	package.loaded["lazyvcs.integrations.optional"] = nil

	local optional = require("lazyvcs.integrations.optional")
	local vanilla = optional.status(function()
		return false
	end)
	eq(vanilla.mode, "vanilla")

	local enhanced = optional.status(function(module)
		return module == "snacks.picker.select"
	end)
	eq(enhanced.mode, "enhanced")

	local enhanced_picker = optional.status(function(module)
		return module == "fzf-lua"
	end)
	eq(enhanced_picker.mode, "enhanced")

	local recommended_modules = {
		"gitsigns",
		"snacks.picker.select",
		"fzf-lua",
		"CopilotChat",
		"claude",
		"codex",
		"gemini",
		"copilot",
	}
	for _, module in ipairs(recommended_modules) do
		local status = optional.status(function(candidate)
			return candidate == module
		end)
		eq(status.mode, "enhanced", module .. " should enable enhanced mode")
	end
end

local function test_commit_input_generates_message_from_popup()
	require("lazyvcs").setup({
		ai = {
			commit_message = {
				provider = "off",
			},
		},
	})

	local input = require("lazyvcs.source_control.input")
	local submitted
	local handle = input.open_text({
		title = " Commit Message: repo ",
		can_generate = true,
		on_generate = function(done)
			done("Add generated commit message")
		end,
	}, function(value)
		submitted = value
	end)

	local footer = vim.api.nvim_win_get_config(handle.winid).footer
	assert(vim.inspect(footer):match("Generate"), "commit popup should expose a generate hint")
	handle.generate()
	wait_for(function()
		return vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1] == "Add generated commit message"
	end, "generated commit message was not inserted")
	feed("<CR>")
	wait_for(function()
		return submitted ~= nil
	end, "generated commit message was not submitted")
	eq(submitted, "Add generated commit message")
end

local function test_ai_commit_message_auto_falls_back_to_next_cli_provider()
	require("lazyvcs").setup({
		ai = {
			commit_message = {
				provider = "auto",
				provider_order = { "claude", "codex" },
				instructions = "Use ticket IDs when present.",
				confirm_privacy = false,
			},
		},
	})

	local ai = require("lazyvcs.source_control.ai")
	local util = require("lazyvcs.util")
	local previous_system_start = util.system_start
	local calls = {}
	local codex_stdin
	ai._test_reset_privacy()
	ai._test_set_executable_checker(function(name)
		return name == "claude" or name == "codex"
	end)

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		if key:match("^git diff %-%-staged") then
			on_exit({ code = 0, stdout = "diff --git a/app.lua b/app.lua\n+return true\n", stderr = "" }, nil)
		elseif key:match("^claude ") then
			on_exit(nil, "claude failed")
		elseif key:match("^codex exec") then
			codex_stdin = opts.stdin
			on_exit({ code = 0, stdout = "Add generated commit message\n\nignored body\n", stderr = "" }, nil)
		else
			error("unexpected command: " .. key)
		end
		return {}
	end

	local message
	local err
	local provider
	local ok = ai.generate({
		vcs = "git",
		root = vim.fs.normalize(vim.fn.tempname()),
	}, function(generated, generate_err, used_provider)
		message = generated
		err = generate_err
		provider = used_provider
	end)
	assert(ok, "AI generation should start")
	wait_for(function()
		return message ~= nil or err ~= nil
	end, "AI generation did not finish")
	eq(message, "Add generated commit message")
	eq(err, nil)
	eq(provider, "codex")
	assert(codex_stdin:match("Use ticket IDs when present"), "custom instructions should be included")
	assert(codex_stdin:match("diff %-%-git"), "diff context should be included")
	eq(calls[1], "git diff --staged --stat --patch --minimal --unified=1")
	assert(calls[2]:match("^claude "), "auto provider should try claude first")
	eq(calls[3], "codex exec --skip-git-repo-check --ephemeral --sandbox read-only --ask-for-approval never -")

	util.system_start = previous_system_start
	ai._test_reset_privacy()
end

local function test_picker_uses_snacks_select_module_when_available()
	local previous_picker = package.loaded["lazyvcs.picker"]
	local previous_snacks = package.loaded["snacks.picker.select"]
	package.loaded["lazyvcs.picker"] = nil

	local calls = {}
	package.loaded["snacks.picker.select"] = {
		select = function(items, opts, on_choice)
			calls[#calls + 1] = {
				items = items,
				opts = opts,
			}
			on_choice(items[1])
		end,
	}

	local selected
	require("lazyvcs.picker").select({
		{ label = "first" },
	}, {
		prompt = "Pick",
		snacks = {
			layout = "select",
			matcher = { sort_empty = true },
		},
	}, function(item)
		selected = item
	end)

	eq(#calls, 1)
	eq(calls[1].opts.prompt, "Pick")
	eq(calls[1].opts.snacks, {
		layout = "select",
		matcher = { sort_empty = true },
	})
	eq(selected, { label = "first" })

	package.loaded["lazyvcs.picker"] = previous_picker
	package.loaded["snacks.picker.select"] = previous_snacks
end

local function test_picker_uses_fzf_lua_when_snacks_select_is_unavailable()
	local previous_picker = package.loaded["lazyvcs.picker"]
	local previous_snacks = package.loaded["snacks.picker.select"]
	local previous_fzf = package.loaded["fzf-lua"]
	package.loaded["lazyvcs.picker"] = nil
	package.loaded["snacks.picker.select"] = {}

	local captured
	package.loaded["fzf-lua"] = {
		fzf_exec = function(entries, opts)
			captured = {
				entries = entries,
				opts = opts,
			}
			opts.actions.default({ entries[2] })
		end,
	}

	local selected
	require("lazyvcs.picker").select({
		{ label = "first" },
		{ label = "second" },
	}, {
		prompt = "Choose> ",
	}, function(item)
		selected = item
	end)

	assert(captured, "fzf-lua should receive the shared picker request")
	eq(captured.opts.prompt, "Choose> ")
	assert(captured.entries[1]:match("^00000001\tfirst$"), captured.entries[1])
	assert(captured.entries[2]:match("^00000002\tsecond$"), captured.entries[2])
	eq(selected, { label = "second" })

	package.loaded["lazyvcs.picker"] = previous_picker
	package.loaded["snacks.picker.select"] = previous_snacks
	package.loaded["fzf-lua"] = previous_fzf
end

local function test_core_backend_task_cancellation_finish_and_late_add()
	local Task = require("lazyvcs.backends.task")
	local cancelled_ids = {}
	local first_signals = {}
	local second_signals = {}
	local task = Task.new(function()
		error("a cancelled task must not finish")
	end, {
		cancel_id = function(id)
			cancelled_ids[#cancelled_ids + 1] = id
		end,
	})
	task:add({
		cancel = function(_, signal)
			first_signals[#first_signals + 1] = signal
		end,
	})
	task:add({
		kill = function(_, signal)
			second_signals[#second_signals + 1] = signal
		end,
	})
	task:add(42)

	assert(task:kill(9), "first cancellation should take effect")
	eq(first_signals, { 9 })
	eq(second_signals, { 9 })
	eq(cancelled_ids, { 42 })
	eq(task:is_active(), false)
	eq(task:kill(9), false, "cancellation should be idempotent")

	local late_signals = {}
	task:add({
		kill = function(_, signal)
			late_signals[#late_signals + 1] = signal
		end,
	})
	eq(late_signals, { 15 }, "a handle added after cancellation should be stopped immediately")

	local finished = {}
	local finish_task = Task.new(function(value)
		finished[#finished + 1] = value
	end)
	assert(finish_task:finish("first"), "the first finish should resolve the task")
	eq(finish_task:finish("second"), false, "finish should be idempotent")
	eq(finished, { "first" })
end

local function test_svn_xml_parses_info_status_list_and_entities()
	local xml = require("lazyvcs.backends.xml")
	eq(xml.decode("A&amp;B &lt;x&gt; &quot;q&quot; &apos;s&apos; &#65; &#x42;"), "A&B <x> \"q\" 's' A B")

	local info = assert(xml.parse_info([[
		<info>
		  <entry kind="dir" path="proj&amp;ect" revision="12">
		    <url>https://example.test/svn/proj&amp;ect/trunk</url>
		    <repository><root>https://example.test/svn/proj&#101;ct</root></repository>
		  </entry>
		</info>
	]]))
	eq(info.kind, "dir")
	eq(info.path, "proj&ect")
	eq(info.revision, "12")
	eq(info.url, "https://example.test/svn/proj&ect/trunk")
	eq(info.root, "https://example.test/svn/project")

	local status = xml.parse_status([[
		<status><target path=".">
		  <entry path="src/a&amp;b.txt">
		    <wc-status item="modified" props="modified" revision="7" tree-conflicted="true"/>
		    <repos-status item="deleted" props="none"/>
		  </entry>
		</target></status>
	]])
	eq(#status, 1)
	eq(status[1], {
		path = "src/a&b.txt",
		wc_item = "modified",
		wc_props = "modified",
		repos_item = "deleted",
		repos_props = "none",
		revision = "7",
		tree_conflicted = true,
	})

	local listed = xml.parse_list([[
		<lists><list path="https://example.test/svn/branches">
		  <entry kind="dir">
		    <name>release&amp;next/</name>
		    <commit revision="19">
		      <author>Ada &lt;ada@example.test&gt;</author>
		      <date>2026-07-27T12:00:00.000000Z</date>
		    </commit>
		  </entry>
		  <entry kind="file"><name>ignored.txt</name></entry>
		</list></lists>
	]])
	eq(listed, {
		{
			name = "release&next",
			revision = "19",
			author = "Ada <ada@example.test>",
			date = "2026-07-27T12:00:00.000000Z",
		},
	})
end

local function test_core_json_file_migration_atomic_replace_and_invalid_reads()
	local json_file = require("lazyvcs.json_file")
	local root = vim.fs.normalize(vim.fn.tempname())
	local path = root .. "/state.json"
	local unreadable = root .. "/unreadable.json"
	local corrupt = root .. "/corrupt.json"
	vim.fn.mkdir(root, "p")
	helpers.write_file(path, vim.json.encode({ legacy = true, nested = { value = 4 } }))
	eq(json_file.read(path), {
		legacy = true,
		nested = { value = 4 },
	}, "v0.4.x direct-table state should migrate on read")

	local previous_rename = vim.uv.fs_rename
	local rename_call
	---@diagnostic disable-next-line: duplicate-set-field
	vim.uv.fs_rename = function(from, to)
		rename_call = { from = from, to = to }
		eq(json_file.read(path), {
			legacy = true,
			nested = { value = 4 },
		}, "the destination should remain readable until the atomic rename")
		return previous_rename(from, to)
	end
	local ok, err = xpcall(function()
		assert(json_file.write(path, { replacement = "complete" }))
	end, debug.traceback)
	vim.uv.fs_rename = previous_rename
	if not ok then
		error(err, 0)
	end
	assert(rename_call and rename_call.from ~= path, "atomic writes should rename a distinct temporary file")
	eq(rename_call.to, path)
	assert(rename_call.from:find(path .. ".tmp.", 1, true) == 1, rename_call.from)
	eq(json_file.read(path), { replacement = "complete" })
	local encoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	eq(encoded.version, 1)
	eq(encoded.data, { replacement = "complete" })
	eq(vim.fn.glob(path .. ".tmp.*"), "", "successful atomic replacement should not leave a temporary file")

	helpers.write_file(corrupt, "{ definitely not json")
	eq(json_file.read(corrupt), {}, "corrupt JSON should be ignored")
	helpers.write_file(unreadable, "{}")
	local previous_open = vim.uv.fs_open
	---@diagnostic disable-next-line: duplicate-set-field
	vim.uv.fs_open = function(candidate, ...)
		if candidate == unreadable then
			return nil, "simulated unreadable file"
		end
		return previous_open(candidate, ...)
	end
	ok, err = xpcall(function()
		eq(json_file.read(unreadable), {}, "an unreadable state file should be ignored")
	end, debug.traceback)
	vim.uv.fs_open = previous_open
	vim.fn.delete(root, "rf")
	if not ok then
		error(err, 0)
	end
end

local function test_source_control_modal_escape_q_and_wipe_finish_once_and_restore_view()
	local modal = require("lazyvcs.source_control.modal")
	local compat = require("lazyvcs.compat")

	local function run_case(close_modal)
		vim.cmd.enew()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second", "third" })
		local previous_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_cursor(previous_win, { 2, 3 })
		local previous_cursor = vim.api.nvim_win_get_cursor(previous_win)
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "modal" })
		local winid = vim.api.nvim_open_win(bufnr, true, {
			relative = "editor",
			row = 1,
			col = 1,
			width = 20,
			height = 1,
			style = "minimal",
		})
		local finished = {}
		local owner = modal.new({
			bufnr = bufnr,
			winid = winid,
			previous_win = previous_win,
			previous_cursor = previous_cursor,
			cancel_value = "cancel",
			on_finish = function(value)
				finished[#finished + 1] = value
			end,
		})
		compat.keymap_set("n", "<Esc>", function()
			owner:finish("cancel")
		end, { buffer = bufnr, nowait = true })

		close_modal(owner, bufnr)
		wait_for(function()
			return #finished == 1
		end, "modal close path did not finish")
		vim.wait(20)
		eq(finished, { "cancel" }, "overlapping close events must resolve the modal once")
		eq(vim.api.nvim_get_current_win(), previous_win)
		eq(vim.api.nvim_win_get_cursor(previous_win), previous_cursor)
	end

	run_case(function()
		feed("<Esc>")
	end)
	run_case(function()
		vim.cmd("q")
	end)
	run_case(function(_, bufnr)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)
end

local function test_core_compat_routes_neovim_011_and_012_apis()
	local compat = require("lazyvcs.compat")
	local previous_fn = vim.fn
	local previous_keymap = vim.keymap
	local previous_text = vim.text
	local previous_diff = vim.diff
	local version = 12
	local calls = {}
	vim.fn = setmetatable({
		has = function(name)
			eq(name, "nvim-0.12")
			return version == 12 and 1 or 0
		end,
	}, { __index = previous_fn })
	vim.keymap = {
		set = function(mode, lhs, rhs, opts)
			calls[#calls + 1] = { action = "set", mode = mode, lhs = lhs, rhs = rhs, opts = opts }
		end,
		del = function(mode, lhs, opts)
			calls[#calls + 1] = { action = "del", mode = mode, lhs = lhs, opts = opts }
		end,
	}

	local ok, err = xpcall(function()
		vim.text = {
			diff = function(a, b, opts)
				return { api = "0.12", a = a, b = b, opts = opts }
			end,
		}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.diff = function()
			error("the 0.12 diff branch should prefer vim.text.diff")
		end
		eq(compat.diff("a", "b", { result_type = "indices" }).api, "0.12")
		local original_opts = { buffer = 7, silent = true }
		compat.keymap_set("n", "x", function() end, original_opts)
		compat.keymap_del("n", "x", original_opts)
		eq(calls[1].opts, { buf = 7, silent = true })
		eq(calls[2].opts, { buf = 7, silent = true })
		eq(original_opts, { buffer = 7, silent = true }, "compat mapping options should be copied")

		version = 11
		vim.text = nil
		---@diagnostic disable-next-line: duplicate-set-field
		vim.diff = function(a, b, opts)
			return { api = "0.11", a = a, b = b, opts = opts }
		end
		eq(compat.diff("c", "d", { result_type = "indices" }).api, "0.11")
		compat.keymap_set("n", "y", function() end, { buffer = 8 })
		compat.keymap_del("n", "y", { buffer = 8 })
		eq(calls[3].opts, { buffer = 8 })
		eq(calls[4].opts, { buffer = 8 })
	end, debug.traceback)
	vim.fn = previous_fn
	vim.keymap = previous_keymap
	vim.text = previous_text
	vim.diff = previous_diff
	if not ok then
		error(err, 0)
	end
end

local function test_source_control_persist_owns_state_serialization_and_apply()
	local persist = require("lazyvcs.source_control.persist")
	local previous_save = persist.save
	local previous_load = persist.load
	local saved_root
	local saved_value
	---@diagnostic disable-next-line: duplicate-set-field
	persist.save = function(root, value)
		saved_root = root
		saved_value = value
	end
	---@diagnostic disable-next-line: duplicate-set-field
	persist.load = function(root)
		eq(root, "/workspace")
		return {
			visible_repos = { "/repo/a" },
			hidden_repos = { "/repo/b" },
			focused_repo = "/repo/a",
			show_clean = true,
			selection_mode = "multiple",
			changes_view_mode = "list",
			changes_sort = "status",
		}
	end

	local ok, err = xpcall(function()
		persist.save_state({
			path = "/workspace",
			lazyvcs_repo_visibility_overrides = {
				["/repo/z"] = true,
				["/repo/a"] = true,
				["/repo/b"] = false,
			},
			lazyvcs_focused_repo = "/repo/z",
			lazyvcs_show_clean = false,
			lazyvcs_selection_mode = "single",
			lazyvcs_changes_view_mode = "tree",
			lazyvcs_changes_sort = "path",
		})
		eq(saved_root, "/workspace")
		eq(saved_value, {
			visible_repos = { "/repo/a", "/repo/z" },
			hidden_repos = { "/repo/b" },
			focused_repo = "/repo/z",
			show_clean = false,
			selection_mode = "single",
			changes_view_mode = "tree",
			changes_sort = "path",
		})

		local state = {}
		persist.apply_state(state, "/workspace")
		eq(state.lazyvcs_repo_visibility, {})
		eq(state.lazyvcs_repo_visibility_overrides, {
			["/repo/a"] = true,
			["/repo/b"] = false,
		})
		eq(state.lazyvcs_focused_repo, "/repo/a")
		eq(state.lazyvcs_show_clean, true)
		eq(state.lazyvcs_selection_mode, "multiple")
		eq(state.lazyvcs_changes_view_mode, "list")
		eq(state.lazyvcs_changes_sort, "status")
	end, debug.traceback)
	persist.save = previous_save
	persist.load = previous_load
	if not ok then
		error(err, 0)
	end
end

local function test_source_control_discovery_error_is_rendered_in_sidebar()
	require("lazyvcs").setup({
		source_control = {
			remote_refresh = "manual",
			width = 100,
		},
	})
	local native = require("lazyvcs.source_control.native")
	local state = {
		path = "/workspace",
		bufnr = vim.api.nvim_create_buf(false, true),
		lazyvcs_expanded = {},
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = {},
		lazyvcs_repo_cache = {},
		lazyvcs_discovery_error = "simulated scan failure",
	}
	native.render(state)
	local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
	assert(
		text:match("Repository discovery failed: simulated scan failure"),
		"the native sidebar should surface asynchronous discovery failures"
	)
	local error_node = assert(state.lazyvcs_line_nodes[2])
	eq(error_node.type, "message")
	eq(error_node.extra.error, true)
	eq(error_node.extra.discovery_error, true)
end

local function test_source_control_confirm_popup_key_paths()
	local confirm = require("lazyvcs.source_control.confirm")
	vim.cmd.enew()
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "source" })
	local previous_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(previous_win, { 1, 0 })

	local function choose(keys)
		local choice
		local handle = confirm.open({
			prompt = "Sync example?",
		}, function(result)
			choice = result
		end)
		eq(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), {
			"1. Confirm",
			"2. Confirm and do not ask again this session",
			"3. Cancel",
		})
		feed(keys)
		wait_for(function()
			return choice ~= nil
		end, "confirmation popup did not resolve")
		eq(vim.api.nvim_get_current_win(), previous_win)
		eq(vim.api.nvim_win_get_cursor(previous_win), { 1, 0 })
		return choice
	end

	eq(choose("1"), "confirm")
	eq(choose("<CR>"), "confirm")
	eq(choose("2"), "confirm_session")
	eq(choose("3"), "cancel")
	eq(choose("j<CR>"), "confirm_session")
	eq(choose("k<CR>"), "cancel")
	eq(choose("q"), "cancel")
	eq(choose("<Esc>"), "cancel")
end

local function test_svn_async_blame_cancels_active_child_process()
	if vim.fn.executable("svn") ~= 1 then
		-- backends/svn.lua short-circuits when the svn executable is missing,
		-- so blame_lines_async never reaches the mocked system_start. Skip
		-- rather than fail (consistent with the other SVN tests).
		error({ lazyvcs_skip = "svn not installed — SVN tests skipped" })
	end

	local backend = require("lazyvcs.backends.svn")
	local util = require("lazyvcs.util")
	local original_system_start = util.system_start

	-- Guarantee the global monkey-patch is restored even if an assertion
	-- fails, so a failure here cannot contaminate later tests.
	local ok, err = pcall(function()
		local handles = {}
		local callbacks = {}

		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			local handle = {
				args = args,
				killed = false,
				kill = function(self)
					self.killed = true
				end,
			}
			handles[#handles + 1] = handle
			callbacks[#callbacks + 1] = on_exit
			return handle
		end

		local completed = false
		local job = backend.blame_lines_async("/tmp/wc/sample.txt", function()
			completed = true
		end)
		callbacks[1]({ stdout = "/tmp/wc\n", code = 0 })
		eq(#handles, 2)
		job:kill()
		assert(handles[2].killed, "active svn blame child process should be killed")
		callbacks[2]({ stdout = "     1 alice        2026-04-01 line\n", code = 0 })
		eq(completed, false)
	end)

	util.system_start = original_system_start
	if not ok then
		error(err)
	end
end

local function test_source_control_collects_dirty_nested_repos()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_mixed_source_control_fixture()
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
	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(load_repo_details(model, by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(load_repo_summary(model, by_root[fixture.git_clean], {}))
	state.lazyvcs_repo_cache[fixture.svn_wc] = assert(load_repo_details(model, by_root[fixture.svn_wc], {}))
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
		},
	})

	local fixture = helpers.make_git_source_control_fixture()
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
	eq(root.children[1].name, "Repositories (2)")
	eq(root.children[2].name, "Changes (2)")
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
		lazyvcs_force_expand = {
			[model.repo_changes_id(fixture.root)] = true,
		},
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_details(model, specs[1], {
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
	local started = {}
	local pending = {}
	local order = {}
	local function fake_start(args, _, on_done)
		local name = args[1]
		started[#started + 1] = name
		pending[name] = on_done
		return {
			kill = function() end,
		}
	end
	local function enqueue(name, priority)
		jobs.command(repo, name, { name }, { priority = priority, start = fake_start }, function()
			order[#order + 1] = name
		end)
	end
	local function finish(name)
		local callback = assert(pending[name], "missing fake process callback for " .. name)
		pending[name] = nil
		callback({ code = 0, stdout = name .. "\n", stderr = "" })
	end

	enqueue("active", 0)
	enqueue("background", -10)
	enqueue("user", 10)
	eq(started, { "active" }, "the worker limit should leave later work queued")
	finish("active")
	eq(started, { "active", "user" }, "user work should start before background refresh")
	finish("user")
	eq(started, { "active", "user", "background" })
	finish("background")
	eq(order, { "active", "user", "background" })
end

local function fake_process_start(processes, started)
	return function(args, opts, on_exit)
		local name = args[1]
		local process = {
			name = name,
			signals = {},
			exited = false,
		}
		local timeout_timer
		local kill_timer
		local forced
		local function close_timer(timer)
			if timer and not timer:is_closing() then
				timer:stop()
				timer:close()
			end
		end
		local function force(kind, reason)
			if process.exited or forced then
				return false
			end
			local message
			local raw
			if kind == "timeout" then
				message = string.format("Timed out after %dms: %s", opts.timeout, name)
				raw = {
					code = 124,
					stdout = "",
					stderr = message,
					timed_out = true,
					reason = "timeout",
				}
			else
				message = "Cancelled: " .. tostring(reason or "cancelled")
				raw = {
					code = 130,
					stdout = "",
					stderr = message,
					cancelled = true,
					reason = reason or "cancelled",
				}
			end
			forced = { err = message, raw = raw }
			process.signals[#process.signals + 1] = 15
			if type(opts.on_terminate) == "function" then
				opts.on_terminate(nil, message, raw)
			end
			if opts.kill_grace_ms and opts.kill_grace_ms > 0 then
				kill_timer = vim.defer_fn(function()
					kill_timer = nil
					if not process.exited then
						process.signals[#process.signals + 1] = 9
					end
				end, opts.kill_grace_ms)
			end
			return true
		end
		function process:kill(signal)
			self.signals[#self.signals + 1] = signal
			return true
		end
		function process:cancel(reason)
			return force("cancelled", reason)
		end
		function process:exit(result, err, raw)
			assert(not self.exited, "fake child process exited more than once")
			self.exited = true
			close_timer(timeout_timer)
			close_timer(kill_timer)
			if forced then
				on_exit(nil, forced.err, forced.raw)
			else
				on_exit(result or { code = 0, stdout = "", stderr = "" }, err, raw)
			end
		end
		processes[name] = process
		started[#started + 1] = name
		if opts.timeout and opts.timeout > 0 then
			timeout_timer = vim.defer_fn(function()
				timeout_timer = nil
				force("timeout")
			end, opts.timeout)
		end
		return process
	end
end

local function enqueue_fake_svn_job(jobs, repo, start, name, opts, on_done)
	opts = vim.tbl_extend("force", {
		start = start,
		scope = name,
	}, opts or {})
	return jobs.command(repo, name, { name }, opts, on_done)
end

local function test_source_control_jobs_cancel_holds_worker_until_delayed_exit()
	require("lazyvcs").setup({
		source_control = {
			background = {
				svn_workers = 1,
			},
		},
	})

	local jobs = require("lazyvcs.source_control.jobs")
	local repo = { root = vim.fn.getcwd(), name = "repo", vcs = "svn" }
	local processes = {}
	local started = {}
	local done = 0
	local start = fake_process_start(processes, started)
	enqueue_fake_svn_job(jobs, repo, start, "cancel-delayed", { kill_grace_ms = 100 }, function(_, err, raw)
		done = done + 1
		assert(err and err:match("Cancelled"), "cancel should report its logical result immediately")
		assert(raw and raw.cancelled, "cancel callback should receive the forced cancellation result")
	end)
	enqueue_fake_svn_job(jobs, repo, start, "after-cancel-delayed")

	eq(started, { "cancel-delayed" })
	eq(
		jobs.cancel(function(job)
			return job.kind == "cancel-delayed"
		end, "test"),
		1
	)
	eq(done, 1, "cancel should complete logically exactly once")
	eq(processes["cancel-delayed"].signals, { 15 })
	eq(started, { "cancel-delayed" }, "the queued job must wait for the cancelled child to exit")

	vim.defer_fn(function()
		processes["cancel-delayed"]:exit({ code = 143, signal = 15, stdout = "", stderr = "" })
	end, 10)
	wait_for(function()
		return #started == 2
	end, "the worker slot should release after the cancelled child is reaped")
	eq(done, 1, "the late exit must not complete the cancelled job twice")
	eq(started, { "cancel-delayed", "after-cancel-delayed" })
	processes["after-cancel-delayed"]:exit()
end

local function test_source_control_jobs_cancel_forces_kill_after_grace_before_reap()
	require("lazyvcs").setup({
		source_control = {
			background = {
				svn_workers = 1,
			},
		},
	})

	local jobs = require("lazyvcs.source_control.jobs")
	local repo = { root = vim.fn.getcwd(), name = "repo", vcs = "svn" }
	local processes = {}
	local started = {}
	local done = 0
	local start = fake_process_start(processes, started)
	enqueue_fake_svn_job(jobs, repo, start, "cancel-kill", { kill_grace_ms = 10 }, function()
		done = done + 1
	end)
	enqueue_fake_svn_job(jobs, repo, start, "after-cancel-kill")

	jobs.cancel(function(job)
		return job.kind == "cancel-kill"
	end, "test")
	eq(done, 1)
	wait_for(function()
		return vim.deep_equal(processes["cancel-kill"].signals, { 15, 9 })
	end, "an uncooperative child should receive KILL after the grace period")
	eq(started, { "cancel-kill" }, "KILL delivery must not release the worker before process exit")

	processes["cancel-kill"]:exit({ code = 137, signal = 9, stdout = "", stderr = "" })
	eq(started, { "cancel-kill", "after-cancel-kill" })
	eq(done, 1, "forced KILL followed by exit must still complete once")
	processes["after-cancel-kill"]:exit()
end

local function test_source_control_jobs_timeout_racing_late_exit_completes_once()
	require("lazyvcs").setup({
		source_control = {
			background = {
				svn_workers = 1,
			},
		},
	})

	local jobs = require("lazyvcs.source_control.jobs")
	local repo = { root = vim.fn.getcwd(), name = "repo", vcs = "svn" }
	local processes = {}
	local started = {}
	local done = 0
	local forced
	local start = fake_process_start(processes, started)
	enqueue_fake_svn_job(
		jobs,
		repo,
		start,
		"timeout-late",
		{ timeout_ms = 10, kill_grace_ms = 100 },
		function(_, err, raw)
			done = done + 1
			forced = raw
			assert(err and err:match("Timed out"), "timeout should report immediately")
		end
	)
	enqueue_fake_svn_job(jobs, repo, start, "after-timeout-late")

	wait_for(function()
		return done == 1
	end, "timeout callback should fire")
	assert(forced and forced.timed_out, "timeout callback should receive the forced timeout result")
	eq(started, { "timeout-late" }, "timing out must not free a live child's worker slot")
	processes["timeout-late"]:exit({ code = 0, stdout = "late success", stderr = "" })
	eq(started, { "timeout-late", "after-timeout-late" })
	eq(done, 1, "a successful late exit must not override or repeat the timeout result")
	processes["after-timeout-late"]:exit()
end

local function test_source_control_jobs_cancel_racing_late_exit_completes_once()
	require("lazyvcs").setup({
		source_control = {
			background = {
				svn_workers = 1,
			},
		},
	})

	local jobs = require("lazyvcs.source_control.jobs")
	local repo = { root = vim.fn.getcwd(), name = "repo", vcs = "svn" }
	local processes = {}
	local started = {}
	local done = 0
	local start = fake_process_start(processes, started)
	enqueue_fake_svn_job(jobs, repo, start, "cancel-race", { kill_grace_ms = 100 }, function()
		done = done + 1
	end)
	enqueue_fake_svn_job(jobs, repo, start, "after-cancel-race")

	jobs.cancel(function(job)
		return job.kind == "cancel-race"
	end, "test")
	eq(started, { "cancel-race" }, "cancellation must hold the worker until the racing exit is reaped")
	vim.schedule(function()
		processes["cancel-race"]:exit({ code = 0, stdout = "late success", stderr = "" })
	end)
	wait_for(function()
		return #started == 2
	end, "late exit should reap the cancelled child")
	eq(done, 1, "cancel racing process exit must complete exactly once")
	processes["after-cancel-race"]:exit()
end

local function test_source_control_jobs_generation_isolated_for_equal_tostring_owners()
	local jobs = require("lazyvcs.source_control.jobs")
	local repo = { root = vim.fn.getcwd(), name = "repo", vcs = "git" }
	local owner_meta = {
		__tostring = function()
			return "shared-owner-label"
		end,
	}
	local first_owner = setmetatable({}, owner_meta)
	local second_owner = setmetatable({}, owner_meta)
	local results = {}
	local function immediate_start(_, _, on_exit)
		on_exit({ code = 0, stdout = "", stderr = "" })
		return { kill = function() end }
	end

	jobs.command(repo, "first-owner", { "first-owner" }, {
		owner = first_owner,
		scope = "generation-test",
		generation = 5,
		start = immediate_start,
	}, function(_, err, raw)
		results[#results + 1] = { err = err, raw = raw }
	end)
	jobs.command(repo, "second-owner", { "second-owner" }, {
		owner = second_owner,
		scope = "generation-test",
		generation = 1,
		start = immediate_start,
	}, function(_, err, raw)
		results[#results + 1] = { err = err, raw = raw }
	end)

	eq(#results, 2)
	eq(results[1].err, nil)
	eq(results[2].err, nil, "distinct owners with identical tostring values must not share generations")
	assert(not results[2].raw.cancelled, "the second owner's lower generation must not be considered stale")
end

local function with_fake_details_jobs(run)
	local util = require("lazyvcs.util")
	local model = require("lazyvcs.source_control.model")
	local previous_system_start = util.system_start
	local previous_load_details = model.load_repo_details_async
	local processes = {}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _, on_exit)
		local root = args[2]
		local process = {
			cancel_count = 0,
			exited = false,
		}
		function process:cancel(reason)
			self.cancel_count = self.cancel_count + 1
			self.cancel_reason = reason
			return true
		end
		function process:exit(result, err, raw)
			assert(not self.exited, "fake details child exited more than once")
			self.exited = true
			on_exit(result or { code = 0, stdout = "", stderr = "" }, err, raw)
		end
		processes[root] = processes[root] or {}
		processes[root][#processes[root] + 1] = process
		return process
	end

	---@diagnostic disable-next-line: duplicate-set-field
	model.load_repo_details_async = function(repo, _, run_command, on_done)
		return run_command({ "details", repo.root }, { kind = "details", timeout_ms = 0 }, function(_, err)
			if err then
				return on_done(nil, err)
			end
			on_done(vim.tbl_extend("force", repo, {
				details_loaded = true,
				loading_details = false,
				sections = {},
			}))
		end)
	end

	local ok, err = xpcall(function()
		run(processes)
	end, debug.traceback)
	for _, children in pairs(processes) do
		for _, process in ipairs(children) do
			if not process.exited then
				pcall(process.exit, process)
			end
		end
	end
	util.system_start = previous_system_start
	model.load_repo_details_async = previous_load_details
	if not ok then
		error(err, 0)
	end
end

local function fake_details_state(repo)
	local state = {
		lazyvcs_repo_cache = {
			[repo.root] = vim.tbl_extend("force", {}, repo),
		},
		lazyvcs_repo_generations = {},
		lazyvcs_loading_details = {},
	}
	state.lazyvcs_get_node = function()
		return {
			type = "repo_changes",
			path = repo.root,
			extra = { repo_root = repo.root },
			get_id = function()
				return repo.root
			end,
		}
	end
	return state
end

local function test_source_control_details_cancel_clears_cached_loading_flag_and_requeues()
	require("lazyvcs").setup({
		source_control = {
			background = {
				git_workers = 4,
			},
		},
	})

	with_fake_details_jobs(function(processes)
		local ops = require("lazyvcs.source_control.ops")
		local repo = {
			root = vim.fs.joinpath(vim.fn.getcwd(), "details-requeue"),
			name = "details-requeue",
			vcs = "git",
			details_loaded = false,
		}
		local state = fake_details_state(repo)

		ops.open_repo(state)
		eq(#processes[repo.root], 1)
		assert(state.lazyvcs_repo_cache[repo.root].loading_details)
		assert(state.lazyvcs_loading_details[repo.root])

		eq(ops.cancel_repo(state), 1)
		eq(state.lazyvcs_repo_cache[repo.root].loading_details, false)
		eq(state.lazyvcs_loading_details[repo.root], nil)

		ops.open_repo(state)
		eq(#processes[repo.root], 2, "expanding after cancellation must queue a replacement details load")
		assert(state.lazyvcs_repo_cache[repo.root].loading_details)

		processes[repo.root][1]:exit({ code = 143, signal = 15, stdout = "", stderr = "" })
		assert(
			state.lazyvcs_repo_cache[repo.root].loading_details,
			"the cancelled child's late exit must not clear its replacement loading state"
		)
		processes[repo.root][2]:exit()
		assert(state.lazyvcs_repo_cache[repo.root].details_loaded)
	end)
end

local function test_source_control_details_cancel_isolated_between_sidebar_owners()
	require("lazyvcs").setup({
		source_control = {
			background = {
				git_workers = 4,
			},
		},
	})

	with_fake_details_jobs(function(processes)
		local ops = require("lazyvcs.source_control.ops")
		local repo = {
			root = vim.fs.joinpath(vim.fn.getcwd(), "shared-details"),
			name = "shared-details",
			vcs = "git",
			details_loaded = false,
		}
		local first = fake_details_state(repo)
		local second = fake_details_state(repo)

		ops.open_repo(first)
		ops.open_repo(second)
		eq(#processes[repo.root], 2)

		eq(ops.cancel_repo(first), 1, "cancelling one sidebar must select only its details job")
		eq(processes[repo.root][1].cancel_count, 1)
		eq(processes[repo.root][2].cancel_count, 0, "the sibling sidebar's child must not be cancelled")
		eq(first.lazyvcs_repo_cache[repo.root].loading_details, false)
		assert(second.lazyvcs_repo_cache[repo.root].loading_details)

		processes[repo.root][2]:exit()
		assert(second.lazyvcs_repo_cache[repo.root].details_loaded)
		eq(second.lazyvcs_repo_cache[repo.root].error, nil)
		processes[repo.root][1]:exit({ code = 143, signal = 15, stdout = "", stderr = "" })
	end)
end

local function with_fake_summary_hydration(run)
	local util = require("lazyvcs.util")
	local model = require("lazyvcs.source_control.model")
	local previous_system_start = util.system_start
	local previous_load_summary = model.load_repo_summary_async
	local processes = {}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _, on_exit)
		local root = args[2]
		local process = {
			root = root,
			signals = {},
			exited = false,
		}
		function process:kill(signal)
			self.signals[#self.signals + 1] = signal
			return true
		end
		function process:exit(result, err, raw)
			assert(not self.exited, "fake hydration child exited more than once")
			self.exited = true
			on_exit(result or { code = 0, stdout = "", stderr = "" }, err, raw)
		end
		processes[root] = processes[root] or {}
		processes[root][#processes[root] + 1] = process
		return process
	end

	---@diagnostic disable-next-line: duplicate-set-field
	model.load_repo_summary_async = function(repo, _, run_command, on_done)
		return run_command({ "hydrate", repo.root }, { kind = "summary", timeout_ms = 0 }, function(_, err)
			if err then
				return on_done(nil, err)
			end
			on_done(
				vim.tbl_extend("force", model.make_placeholder(repo, {}), {
					summary_loaded = true,
					loading_summary = false,
					refreshing_summary = false,
				}),
				nil
			)
		end)
	end

	local ok, err = xpcall(function()
		run(processes)
	end, debug.traceback)
	for _, children in pairs(processes) do
		for _, process in ipairs(children) do
			if not process.exited then
				pcall(process.exit, process)
			end
		end
	end
	util.system_start = previous_system_start
	model.load_repo_summary_async = previous_load_summary
	if not ok then
		error(err, 0)
	end
end

local function fake_hydration_state(native, repos)
	local state = {
		path = vim.fn.getcwd(),
		lazyvcs_repo_specs = repos,
		lazyvcs_repo_cache = {},
		lazyvcs_repo_generations = {},
		lazyvcs_loading_details = {},
		lazyvcs_window_exists = function()
			return true
		end,
	}
	state.lazyvcs_invalidate_hydration = native._test_invalidate_hydration
	state.lazyvcs_render = function(current)
		native._test_start_summary_hydration(current, false)
	end
	return state
end

local function test_source_control_hydration_cancel_one_of_two_repositories_requeues_without_stranding()
	require("lazyvcs").setup({
		source_control = {
			background = {
				git_workers = 4,
			},
		},
	})

	with_fake_summary_hydration(function(processes)
		local native = require("lazyvcs.source_control.native")
		local ops = require("lazyvcs.source_control.ops")
		local root = vim.fn.getcwd()
		local repo_a = { root = vim.fs.joinpath(root, "repo-a"), name = "repo-a", vcs = "git" }
		local repo_b = { root = vim.fs.joinpath(root, "repo-b"), name = "repo-b", vcs = "git" }
		local state = fake_hydration_state(native, { repo_a, repo_b })

		native._test_start_summary_hydration(state, false)
		eq(#processes[repo_a.root], 1)
		eq(#processes[repo_b.root], 1)
		assert(state.lazyvcs_repo_cache[repo_a.root].loading_summary)
		assert(state.lazyvcs_repo_cache[repo_b.root].loading_summary)

		state.lazyvcs_get_node = function()
			return { path = repo_a.root }
		end
		ops.cancel_repo(state)
		eq(#processes[repo_a.root], 2, "the invalidated repository should start a fresh hydration")
		eq(#processes[repo_b.root], 1, "the other repository must keep its original hydration")
		eq(processes[repo_a.root][1].signals, { 15 })
		eq(processes[repo_b.root][1].signals, {}, "cancelling repo A must not signal repo B")
		assert(state.lazyvcs_repo_cache[repo_b.root].loading_summary, "repo B must remain in flight")

		processes[repo_b.root][1]:exit()
		assert(state.lazyvcs_repo_cache[repo_b.root].summary_loaded, "repo B should finish normally")
		processes[repo_a.root][1]:exit({ code = 143, signal = 15, stdout = "", stderr = "" })
		assert(
			state.lazyvcs_repo_cache[repo_a.root].loading_summary,
			"repo A's stale exit must not clear its replacement loading state"
		)
		processes[repo_a.root][2]:exit()
		assert(state.lazyvcs_repo_cache[repo_a.root].summary_loaded, "repo A replacement should finish")
		eq(state.lazyvcs_hydration_pending, 0)
		eq(state.lazyvcs_hydration_active, false)
	end)
end

local function test_source_control_hydration_cancel_isolated_between_sidebar_owners()
	require("lazyvcs").setup({
		source_control = {
			background = {
				git_workers = 4,
			},
		},
	})

	with_fake_summary_hydration(function(processes)
		local native = require("lazyvcs.source_control.native")
		local ops = require("lazyvcs.source_control.ops")
		local repo = {
			root = vim.fs.joinpath(vim.fn.getcwd(), "shared-repo"),
			name = "shared-repo",
			vcs = "git",
		}
		local first = fake_hydration_state(native, { repo })
		local second = fake_hydration_state(native, { repo })
		first.lazyvcs_get_node = function()
			return { path = repo.root }
		end

		native._test_start_summary_hydration(first, false)
		native._test_start_summary_hydration(second, false)
		eq(#processes[repo.root], 2)
		ops.cancel_repo(first)
		eq(#processes[repo.root], 3, "only the cancelled owner should enqueue a replacement")
		eq(processes[repo.root][1].signals, { 15 })
		eq(processes[repo.root][2].signals, {}, "the second sidebar owner's child must not be signalled")
		assert(second.lazyvcs_repo_cache[repo.root].loading_summary)

		processes[repo.root][2]:exit()
		assert(second.lazyvcs_repo_cache[repo.root].summary_loaded)
		eq(second.lazyvcs_hydration_pending, 0)
		processes[repo.root][1]:exit({ code = 143, signal = 15, stdout = "", stderr = "" })
		processes[repo.root][3]:exit()
		assert(first.lazyvcs_repo_cache[repo.root].summary_loaded)
	end)
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
	<info><entry revision="1"><url>svn://example/svn/projects/branches/private/devuser/RP-2927</url><repository><root>svn://example/svn</root></repository></entry></info>]],
		stderr = "",
	})
	eq(summary.branch, "private/devuser/RP-2927")
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
	state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_summary(model, specs[1], {}))

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

	local workspace = vim.fs.normalize(vim.fn.tempname())
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

	local fixture = helpers.make_git_source_control_fixture()
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
	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(load_repo_summary(model, by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(load_repo_summary(model, by_root[fixture.git_clean], {}))
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	eq(root.children[1].name, "Repositories (2)")
	eq(root.children[2].name, "Changes (2)")
	eq(root.children[2].children[1].name, "git-dirty")
	eq(root.children[2].children[2].name, "git-clean")
end

local function test_source_control_toggle_repo_visibility_keeps_a_visible_repo()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_git_source_control_fixture()
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

	state.lazyvcs_get_node = function()
		return first_repo
	end
	state.lazyvcs_render = function() end
	ops.toggle_repo_visibility(state)

	local visible = 0
	for _, enabled in pairs(state.lazyvcs_repo_visibility) do
		if enabled then
			visible = visible + 1
		end
	end
	assert(visible >= 1, "at least one repository should stay visible")
end

local function test_source_control_toggle_repo_visibility_ignores_section_rows()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_git_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local specs = model.discover(fixture.root, 3)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_render = function() end,
	}
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	local repositories = assert(find_view_section(root, "repositories"))
	local changes = assert(find_view_section(root, "changes"))
	local visibility_before = vim.deepcopy(state.lazyvcs_repo_visibility)

	local ok, err = pcall(ops.toggle_repo_visibility, state, repositories)
	assert(ok, tostring(err))
	ok, err = pcall(ops.toggle_repo_visibility, state, changes)
	assert(ok, tostring(err))
	eq(state.lazyvcs_repo_visibility, visibility_before)
end

local function test_source_control_repo_actions_ignore_non_repo_rows()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_git_source_control_fixture()
	local model = require("lazyvcs.source_control.model")
	local ops = require("lazyvcs.source_control.ops")
	local specs = model.discover(fixture.root, 3)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_render = function() end,
	}
	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	local section = assert(find_view_section(root, "repositories"))
	local actions = {
		ops.focus_repo,
		ops.open_repo,
		ops.switch_repo,
		ops.run_primary_action,
		ops.repo_action_picker,
		ops.sync_repo,
		ops.generate_commit_message,
		ops.open_change,
		ops.stage_file,
		ops.unstage_file,
		ops.revert_file,
		ops.commit_repo,
	}

	for _, action in ipairs(actions) do
		local ok, err = pcall(action, state, section)
		assert(ok, tostring(err))
	end
end

local function test_source_control_confirm_session_choice_disables_more_prompts()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
			confirm_mutations = true,
		},
	})

	local root = vim.fs.normalize(vim.fn.tempname())
	vim.fn.mkdir(root, "p")
	helpers.exec({ "git", "init" }, root)
	helpers.write_file(root .. "/changed.txt", "changed\n")

	local state = {
		lazyvcs_confirm_mutations = true,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[root] = {
				root = root,
				name = "repo",
				vcs = "git",
				counts = { local_changes = 1, staged = 0, remote = 0 },
			},
		},
		lazyvcs_render = function() end,
	}
	local node = {
		type = "file",
		path = root .. "/changed.txt",
		extra = {
			repo_root = root,
			relpath = "changed.txt",
		},
	}

	require("lazyvcs.source_control.ops").stage_file(state, node)
	feed("2")
	wait_for(function()
		local result = vim.system({ "git", "diff", "--cached", "--name-only" }, { cwd = root, text = true }):wait()
		return result.stdout:match("changed%.txt") ~= nil
	end, "stage confirmation did not run git add")
	eq(state.lazyvcs_confirm_mutations, false)
end

local function test_source_control_tree_view_groups_files_into_folders()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = true,
			changes_view_mode = "tree",
		},
	})

	local root = vim.fs.normalize(vim.fn.tempname())
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
	state.lazyvcs_repo_cache[root] = assert(load_repo_details(model, specs[1], {
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
	eq(section.children[1].type, "lazy_placeholder")

	state.lazyvcs_expanded = {
		[section.id] = true,
	}
	tree = model.collect(state, {
		root = root,
		scan_depth = 1,
	})
	changes = tree.children[1]
	repo = changes.children[1]
	section = repo.children[3]
	eq(section.children[1].type, "folder")
	eq(section.children[1].name, "src/module")
	eq(section.children[1].children[1].type, "file")
	eq(section.children[1].children[1].extra.relpath, "src/module/app.lua")
end

local function test_source_control_hides_clean_repo_after_summary_hydration()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 3,
			show_clean = false,
		},
	})

	local fixture = helpers.make_git_source_control_fixture()
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

	state.lazyvcs_repo_cache[fixture.git_dirty] = assert(load_repo_summary(model, by_root[fixture.git_dirty], {}))
	state.lazyvcs_repo_cache[fixture.git_clean] = assert(load_repo_summary(model, by_root[fixture.git_clean], {}))

	local root = model.collect(state, {
		root = fixture.root,
		scan_depth = 3,
	})
	eq(root.children[1].name, "Repositories (2)")
	eq(root.children[2].name, "Changes (2)")
	eq(root.children[2].children[1].name, "git-dirty")
	eq(root.children[2].children[2].name, "git-clean")
end

local function test_source_control_open_repo_recreates_force_expand_after_intermediate_navigate()
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
	state.lazyvcs_get_node = function()
		return {
			type = "repo_changes",
			path = repo.root,
			extra = { repo_root = repo.root },
			get_id = function()
				return repo.root
			end,
		}
	end

	local previous_load = model.load_repo_details_async
	local navigate_count = 0
	state.lazyvcs_render = function()
		navigate_count = navigate_count + 1
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
	assert(navigate_count >= 1, "open_repo should render after details load")
	assert(state.lazyvcs_force_expand[model.repo_changes_id(repo.root)], "open_repo should keep force-expand state")

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
		lazyvcs_expanded = {
			[model.repo_changes_id(repo.root)] = true,
		},
		lazyvcs_force_expand = {
			[model.repo_changes_id(repo.root)] = true,
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
	local loaded = false
	---@diagnostic disable-next-line: duplicate-set-field
	model.load_repo_details_async = function()
		loaded = true
	end

	ops.open_repo(state, node)

	eq(state.lazyvcs_expanded[model.repo_changes_id(repo.root)], false)
	eq(state.lazyvcs_force_expand[model.repo_changes_id(repo.root)], nil)
	eq(loaded, false)

	model.load_repo_details_async = previous_load
end

local function test_source_control_open_repo_expands_loaded_collapsed_node()
	local ops = require("lazyvcs.source_control.ops")
	local model = require("lazyvcs.source_control.model")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
		counts = { local_changes = 1, staged = 0, remote = 0 },
		sync = { status = "dirty" },
		details_loaded = true,
	}
	local state = {
		path = "/tmp",
		lazyvcs_repo_cache = {
			[repo.root] = repo,
		},
		lazyvcs_expanded = {
			[model.repo_changes_id(repo.root)] = false,
		},
	}
	local node = {
		type = "repo_changes",
		path = repo.root,
		extra = { repo_root = repo.root },
		is_expanded = function()
			return false
		end,
	}
	local render_count = 0
	state.lazyvcs_render = function()
		render_count = render_count + 1
	end

	ops.open_repo(state, node)

	eq(state.lazyvcs_expanded[model.repo_changes_id(repo.root)], true)
	eq(render_count, 1)
end

local function test_source_control_open_repo_can_collapse_while_busy()
	local ops = require("lazyvcs.source_control.ops")
	local model = require("lazyvcs.source_control.model")
	local state_mod = require("lazyvcs.state")
	local repo = {
		root = "/tmp/repo",
		name = "repo",
		vcs = "git",
		order = 1,
		counts = { local_changes = 1, staged = 0, remote = 0 },
		sync = { status = "dirty" },
		details_loaded = true,
	}
	local state = {
		path = "/tmp",
		lazyvcs_repo_cache = {
			[repo.root] = repo,
		},
		lazyvcs_expanded = {
			[model.repo_changes_id(repo.root)] = true,
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

	state_mod.set_repo_job(repo.root, {
		status = "running",
		action = "sync",
		label = "Syncing...",
		sync_text = "Sync",
	})
	ops.open_repo(state, node)

	eq(state.lazyvcs_expanded[model.repo_changes_id(repo.root)], false)
	state_mod.clear_repo_job(repo.root)
end

local function test_source_control_native_render_consumes_force_expand()
	require("lazyvcs").setup({
		source_control = {
			scan_depth = 1,
			show_clean = true,
		},
	})

	local fixture = helpers.make_git_fixture()
	local model = require("lazyvcs.source_control.model")
	local native = require("lazyvcs.source_control.native")
	local specs = model.discover(fixture.root, 1)
	local repo = assert(load_repo_details(model, specs[1], {
		changes_sort = "path",
	}))
	local repo_id = model.repo_changes_id(repo.root)
	local state = {
		path = fixture.root,
		bufnr = vim.api.nvim_create_buf(false, true),
		lazyvcs_expanded = {},
		lazyvcs_force_expand = {
			[repo_id] = true,
		},
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {
			[repo.root] = repo,
		},
		lazyvcs_repo_visibility = {
			[repo.root] = true,
		},
	}

	native.render(state)

	local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
	assert(text:match("Commit message"), text)
	assert(text:match("sample%.txt"), text)
	eq(state.lazyvcs_expanded[repo_id], true)
	eq(state.lazyvcs_force_expand[repo_id], nil)
end

local function test_source_control_native_open_can_preserve_current_window()
	require("lazyvcs").setup({
		source_control = {
			ui = "native",
			scan_depth = 1,
			show_clean = true,
			remote_refresh = "manual",
		},
	})

	local fixture = helpers.make_git_fixture()
	local original_win = vim.api.nvim_get_current_win()
	require("lazyvcs").source_control_open({ path = fixture.root, focus = false })
	local state = assert(require("lazyvcs.source_control.native")._state(), "missing native state")

	eq(vim.api.nvim_get_current_win(), original_win, "focus=false open should preserve the active window")
	local sidebar_winid = state.winid
	require("lazyvcs").source_control_close()
	assert(not vim.api.nvim_win_is_valid(sidebar_winid), "sidebar window should close")
end

local function test_source_control_native_smart_e_toggles_auto_width_and_restores_cursor()
	require("lazyvcs").setup({
		source_control = {
			ui = "native",
			scan_depth = 1,
			show_clean = true,
			remote_refresh = "manual",
			width = 24,
			auto_expand_max_width_ratio = 0.5,
		},
	})

	local previous_columns = vim.o.columns
	vim.o.columns = 100
	local fixture = helpers.make_git_fixture()
	local native = require("lazyvcs.source_control.native")
	require("lazyvcs").source_control_open({ path = fixture.root })
	local state = assert(native._state(), "missing native state")
	vim.api.nvim_win_set_width(state.winid, 24)
	native.render(state)
	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { 1, 3 })

	native.dispatch("smart_e")
	eq(vim.api.nvim_win_get_cursor(state.winid), { 1, 3 }, "auto-fit should preserve sidebar cursor")
	assert(vim.api.nvim_win_get_width(state.winid) > 24, "auto-fit should expand for long visible text")
	assert(vim.api.nvim_win_get_width(state.winid) <= 50, "auto-fit should respect max width ratio")

	native.dispatch("smart_e")
	eq(vim.api.nvim_win_get_width(state.winid), 24, "auto-fit should restore the previous user width")

	require("lazyvcs").source_control_close()
	vim.o.columns = previous_columns
end

local function test_source_control_native_render_preserves_active_window_and_repo_meta_spacing()
	require("lazyvcs").setup({
		source_control = {
			ui = "native",
			scan_depth = 1,
			show_clean = true,
			remote_refresh = "manual",
			width = 80,
		},
	})

	local fixture = helpers.make_git_fixture()
	local native = require("lazyvcs.source_control.native")
	local editor_win = vim.api.nvim_get_current_win()
	require("lazyvcs").source_control_open({ path = fixture.root, focus = false })
	local state = assert(native._state(), "missing native state")
	local spec = assert(state.lazyvcs_repo_specs[1], "missing repo spec")
	state.lazyvcs_repo_cache[spec.root] = {
		root = spec.root,
		name = spec.name,
		vcs = "git",
		order = 1,
		relpath = spec.relpath,
		path_label = spec.path_label,
		branch = "feature/spacing-check",
		sections = {},
		counts = {
			local_changes = 2,
			staged = 0,
			remote = 0,
		},
		sync = {
			text = "Publish Branch",
			status = "publish",
			highlight = "DiagnosticInfo",
		},
		summary_loaded = true,
		details_loaded = true,
		loading_details = false,
		loading_summary = false,
	}
	vim.api.nvim_win_set_width(state.winid, 80)
	native.render(state)

	eq(vim.api.nvim_get_current_win(), editor_win, "render should not steal focus from the editor")
	local repo_line
	for _, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)) do
		if line:find("feature/spacing%-check") then
			repo_line = line
			break
		end
	end
	assert(repo_line, "expected rendered repo branch metadata")
	local name_start = assert(repo_line:find(spec.name, 1, true), repo_line)
	local after_name = repo_line:sub(name_start + #spec.name, name_start + #spec.name)
	eq(after_name, " ", "repo name and branch metadata should not touch")

	require("lazyvcs").source_control_close()
end

local function test_source_control_native_invalidated_cache_rehydrates()
	require("lazyvcs").setup({
		source_control = {
			ui = "native",
			scan_depth = 1,
			show_clean = true,
			remote_refresh = "manual",
			confirm_mutations = false,
		},
	})

	local fixture = helpers.make_git_fixture()
	local ops = require("lazyvcs.source_control.ops")
	require("lazyvcs").source_control_open({ path = fixture.root })
	local state = assert(require("lazyvcs.source_control.native")._state(), "missing native state")
	local spec = assert(state.lazyvcs_repo_specs[1], "missing repo spec")

	wait_for(function()
		local cached = state.lazyvcs_repo_cache[spec.root]
		return cached and cached.summary_loaded == true and cached.loading_summary ~= true
	end, "initial native hydration should load repo summary", ASYNC_TIMEOUT_MS)

	local generation = state.lazyvcs_hydration_generation
	ops.toggle_show_clean(state)
	local placeholder = state.lazyvcs_repo_cache[spec.root]
	assert(placeholder and placeholder.loading_summary == true, "invalidated cache should render a loading placeholder")

	wait_for(function()
		local cached = state.lazyvcs_repo_cache[spec.root]
		return cached
			and cached.summary_loaded == true
			and cached.loading_summary ~= true
			and state.lazyvcs_hydration_generation > generation
	end, "native navigate should restart hydration after cache invalidation", ASYNC_TIMEOUT_MS)

	require("lazyvcs").source_control_close()
end

local function test_svn_status_xml_ignores_external_banner_noise()
	local model = require("lazyvcs.source_control.model")
	local status_xml = [[<?xml version="1.0" encoding="UTF-8"?>
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
</status>]]

	local repo = {
		root = "/tmp/factory",
		name = "factory",
		vcs = "svn",
		order = 1,
		relpath = "platform/factory",
		path_label = "platform",
	}
	local completed = false
	local detail
	local load_err
	model.load_repo_details_async(repo, {
		remote_refresh = true,
		changes_sort = "path",
	}, function(args, _, on_done)
		local stdout = args[2] == "status" and status_xml or ""
		on_done({ code = 0, stdout = stdout, stderr = "" })
		return { kill = function() end }
	end, function(result, err)
		detail = result
		load_err = err
		completed = true
	end)
	assert(completed, "the fake async SVN runner should resolve the detail load")
	eq(load_err, nil)
	detail = assert(detail)

	eq(detail.counts.local_changes, 0)
	eq(detail.counts.remote, 1)
	eq(#detail.sections, 1)
	eq(detail.sections[1].id, "remote")
	eq(detail.sections[1].items[1].extra.relpath, "src/local/config/rdu-armv8.config")
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
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
		lazyvcs_force_expand = {
			[model.repo_changes_id(fixture.root)] = true,
		},
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_details(model, specs[1], {
		changes_sort = "path",
	}))

	local tree = model.collect(state, {
		root = fixture.root,
		scan_depth = 1,
	})
	local file_node = assert(find_first_node(tree, "file"))

	ops.open_change(state, file_node)
	wait_for(function()
		return state_mod.current() ~= nil
	end, "source-control comparison should finish loading", ASYNC_TIMEOUT_MS)
	local session = assert(state_mod.current())
	local base_name = vim.api.nvim_buf_get_name(session.base_bufnr)
	actions.close()

	local stale = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(stale, base_name)

	ops.open_change(state, file_node)
	wait_for(function()
		return state_mod.current() ~= nil and diff_window_count() == 2
	end, "source-control comparison should reopen after loading", ASYNC_TIMEOUT_MS)
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
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
		lazyvcs_force_expand = {
			[model.repo_changes_id(fixture.root)] = true,
		},
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_details(model, specs[1], {
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
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state_mod.current()
		return live ~= nil and live.source_path == files[1].path
	end)

	local first_session = assert(state_mod.current())
	local editable_win = first_session.editable_win

	ops.open_change(state, files[2])
	wait_for(function()
		local live = state_mod.current()
		return live ~= nil and live.source_path == files[2].path and diff_window_count() == 2
	end, "repeated VCS clicks should replace the active comparison", ASYNC_TIMEOUT_MS)

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
	vim.wait(ASYNC_TIMEOUT_MS, function()
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

local function test_async_system_reports_missing_executable()
	local util = require("lazyvcs.util")
	local callback_err
	local callback_result
	util.system_start({ "lazyvcs-definitely-missing-executable" }, {}, function(result, err)
		callback_result = result
		callback_err = err
	end)
	wait_for(function()
		return callback_err ~= nil
	end, "missing async executable should report through callback")
	eq(callback_result, nil)
	assert(callback_err:match("lazyvcs%-definitely%-missing%-executable"), callback_err)
end

local function test_async_system_cancel_waits_for_real_process_exit()
	local util = require("lazyvcs.util")
	local previous_system = vim.system
	local process_exit
	local signals = {}
	local callback_count = 0
	local callback_raw
	---@diagnostic disable-next-line: duplicate-set-field
	vim.system = function(_, _, on_exit)
		process_exit = on_exit
		return {
			kill = function(_, signal)
				signals[#signals + 1] = signal
			end,
		}
	end

	local ok, err = xpcall(function()
		local handle = assert(util.system_start({ "fake-process" }, { kill_grace_ms = 100 }, function(_, _, raw)
			callback_count = callback_count + 1
			callback_raw = raw
		end))
		assert(handle:kill(15))
		eq(signals, { 15 })
		eq(callback_count, 0, "logical cancellation must not masquerade as a process exit")
		process_exit({ code = 143, signal = 15, stdout = "", stderr = "" })
		wait_for(function()
			return callback_count == 1
		end, "system callback should run after the fake child exits")
		assert(callback_raw and callback_raw.cancelled)
		eq(callback_count, 1)
	end, debug.traceback)
	vim.system = previous_system
	if not ok then
		error(err, 0)
	end
end

local function test_async_system_owns_timeout_escalation_and_bounded_output()
	local util = require("lazyvcs.util")
	local previous_system = vim.system
	local process_exit
	local system_opts
	local signals = {}
	local termination_count = 0
	local callback_count = 0
	local callback_raw
	---@diagnostic disable-next-line: duplicate-set-field
	vim.system = function(_, opts, on_exit)
		system_opts = opts
		process_exit = on_exit
		return {
			kill = function(_, signal)
				signals[#signals + 1] = signal
			end,
		}
	end

	local ok, err = xpcall(function()
		assert(util.system_start({
			"fake-timeout",
		}, {
			timeout = 10,
			kill_grace_ms = 10,
			output_limit = 256,
			on_terminate = function(_, terminate_err, raw)
				termination_count = termination_count + 1
				assert(terminate_err and terminate_err:match("Timed out"), terminate_err)
				assert(raw and raw.timed_out, "the logical timeout should be reported by the process owner")
			end,
		}, function(_, _, raw)
			callback_count = callback_count + 1
			callback_raw = raw
		end))
		eq(system_opts.timeout, nil)
		eq(system_opts.output_limit, nil)
		eq(system_opts.kill_grace_ms, nil)
		eq(system_opts.on_terminate, nil)
		assert(type(system_opts.stdout) == "function")
		assert(type(system_opts.stderr) == "function")
		system_opts.stdout(nil, string.rep("x", 400))
		system_opts.stderr(nil, string.rep("y", 400))

		wait_for(function()
			return termination_count == 1
		end, "system timeout should report logical termination")
		eq(signals, { 15 })
		eq(callback_count, 0, "physical completion must wait for the child exit")
		wait_for(function()
			return vim.deep_equal(signals, { 15, 9 })
		end, "the process owner should escalate TERM to KILL")
		eq(callback_count, 0, "KILL delivery must not masquerade as physical completion")

		process_exit({ code = 137, signal = 9, stdout = "", stderr = "" })
		wait_for(function()
			return callback_count == 1
		end, "the timeout callback should run after physical exit")
		assert(callback_raw and callback_raw.timed_out)
		assert(#callback_raw.stdout <= 128, "bounded stdout should honor half the total output limit")
		assert(callback_raw.stdout:match("truncated"), callback_raw.stdout)
		eq(callback_count, 1)
	end, debug.traceback)
	vim.system = previous_system
	if not ok then
		error(err, 0)
	end
end

local function test_svn_backend()
	local backend = require("lazyvcs.backends.svn")
	local fixture = helpers.make_svn_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "svn")
	eq(info.base_label, "BASE")
	eq(info.base_lines, { "one", "two", "three" })
end

local function test_svn_backend_added_file_uses_empty_base()
	local backend = require("lazyvcs.backends.svn")
	local fixture = helpers.make_svn_added_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "svn")
	eq(info.tracked, true)
	eq(info.base_label, "EMPTY")
	eq(info.base_lines, {})

	local base = assert(backend.load_base(fixture.file))
	eq(base.base_label, "EMPTY")
	eq(base.base_lines, {})

	local async_result
	local async_err
	backend.load_base_async(fixture.file, function(result, err)
		async_result = result
		async_err = err
	end)
	wait_for(function()
		return async_result ~= nil or async_err ~= nil
	end, "SVN added file base should load asynchronously", ASYNC_TIMEOUT_MS)
	eq(async_err, nil)
	eq(async_result.base_label, "EMPTY")
	eq(async_result.base_lines, {})
end

local function test_svn_added_file_blame_uses_uncommitted_lines()
	local backend = require("lazyvcs.backends.svn")
	local fixture = helpers.make_svn_added_fixture()

	local lines = assert(backend.blame_lines(fixture.file))
	eq(backend.parse_blame_metadata(lines), { "Uncommitted line", "Uncommitted line" })

	local async_lines
	local async_err
	backend.blame_lines_async(fixture.file, function(result, err)
		async_lines = result
		async_err = err
	end)
	wait_for(function()
		return async_lines ~= nil or async_err ~= nil
	end, "SVN added file blame should load asynchronously", ASYNC_TIMEOUT_MS)
	eq(async_err, nil)
	eq(backend.parse_blame_metadata(async_lines), { "Uncommitted line", "Uncommitted line" })
end

local function test_svn_status_and_blame_parsers()
	local backend = require("lazyvcs.backends.svn")
	local items = backend.parse_status_lines({
		"M       src/changed.lua",
		"A       src/added.lua",
		"?       scratch.txt",
	}, "/tmp/wc")

	eq(#items, 3)
	eq(items[1].status, "M")
	eq(items[1].label, "modified")
	eq(items[1].path, "src/changed.lua")
	eq(items[1].absolute_path, "/tmp/wc/src/changed.lua")
	eq(items[3].label, "untracked")

	local blame = backend.parse_blame_metadata({
		"     7 alice        2026-04-01 line one",
		"    12 bob          2026-04-02 line two",
		"      -          -                                            -     local line",
	})
	eq(blame, {
		"     7           alice 2026-04-01",
		"    12             bob 2026-04-02",
		"Uncommitted line",
	})
	local entries = backend.parse_blame_entries({
		"     7 alice        2026-04-01 line one",
		"    12 bob          2026-04-02 line two",
		"      -          -                                            -     local line",
	})
	eq(entries, {
		{ revision = "7", full_revision = "7", author = "alice", date = "2026-04-01", backend = "svn" },
		{ revision = "12", full_revision = "12", author = "bob", date = "2026-04-02", backend = "svn" },
		{ revision = "-", full_revision = "-", author = "-", date = "-", backend = "svn", uncommitted = true },
	})
end

local function test_git_blame_parser_and_remote_urls()
	local backend = require("lazyvcs.backends.git")
	local entries = backend.parse_blame_entries({
		"0123456789abcdef0123456789abcdef01234567 1 1 1",
		"author Alice Example",
		"author-time 1775000000",
		"summary Add first line",
		"filename sample.txt",
		"\tline one",
		"0000000000000000000000000000000000000000 2 2 1",
		"author Not Committed Yet",
		"author-time 1775000100",
		"summary Not Committed Yet",
		"filename sample.txt",
		"\tlocal line",
	})
	eq(entries[1].revision, "01234567")
	eq(entries[1].full_revision, "0123456789abcdef0123456789abcdef01234567")
	eq(entries[1].author, "Alice Example")
	eq(entries[1].summary, "Add first line")
	eq(entries[1].backend, "git")
	eq(entries[2].revision, "-")
	eq(entries[2].uncommitted, true)

	eq(
		backend.commit_url(nil, "0123456789abcdef", "https://github.com/Reddimus/lazyvcs.nvim.git"),
		"https://github.com/Reddimus/lazyvcs.nvim/commit/0123456789abcdef"
	)
	eq(
		backend.commit_url(nil, "0123456789abcdef", "git@bitbucket.org:team/project.git"),
		"https://bitbucket.org/team/project/commits/0123456789abcdef"
	)
	eq(
		backend.commit_url(nil, "0123456789abcdef", "ssh://git@bitbucket.example.com:7999/scm/PROJ/repo.git"),
		"https://bitbucket.example.com:7999/projects/PROJ/repos/repo/commits/0123456789abcdef"
	)
end

local function test_git_blame_inline_virtual_text()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			format = "{author} {revision}",
			max_width = 40,
		},
	})

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(source_win, { 1, 0 })

	assert(require("lazyvcs").blame())
	wait_for(function()
		local test_state = require("lazyvcs.blame")._test_inline_state()
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, test_state.namespace, 0, -1, { details = true })
		return #marks == 1 and marks[1][4].virt_text and marks[1][4].virt_text[1][2] == "LazyVcsBlame"
	end, "git inline blame virtual text should render", 5000)
	eq(vim.api.nvim_get_current_win(), source_win)

	require("lazyvcs").blame_clear()
	local test_state = require("lazyvcs.blame")._test_inline_state()
	local marks = vim.api.nvim_buf_get_extmarks(source_buf, test_state.namespace, 0, -1, { details = true })
	eq(#marks, 0)
end

local function test_svn_blame_inline_virtual_text()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			format = "{author} r{revision}",
			max_width = 40,
		},
		signs = {
			debounce_ms = 10,
		},
	})

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(source_win, { 2, 0 })

	assert(require("lazyvcs.blame").blame())
	wait_for(function()
		local test_state = require("lazyvcs.blame")._test_inline_state()
		local marks = vim.api.nvim_buf_get_extmarks(source_buf, test_state.namespace, 0, -1, { details = true })
		return #marks == 1 and marks[1][4].virt_text and marks[1][4].virt_text[1][2] == "LazyVcsBlame"
	end, "inline blame virtual text should render", 5000)
	eq(vim.api.nvim_get_current_win(), source_win)
	eq(vim.api.nvim_win_get_cursor(source_win), { 2, 0 })

	require("lazyvcs.blame").blame_clear()
	local test_state = require("lazyvcs.blame")._test_inline_state()
	local marks = vim.api.nvim_buf_get_extmarks(source_buf, test_state.namespace, 0, -1, { details = true })
	eq(#marks, 0)
end

local function test_svn_blame_inline_delays_loading_indicator()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			loading_delay_ms = 1000,
		},
	})

	local backend = require("lazyvcs.backends.svn")
	local original_blame_lines_async = backend.blame_lines_async
	local callback
	---@diagnostic disable-next-line: duplicate-set-field
	backend.blame_lines_async = function(_, on_done)
		callback = on_done
		return {
			kill = function() end,
		}
	end

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	assert(require("lazyvcs.blame").blame())
	wait_for(function()
		local view = require("lazyvcs.blame")._test_inline_state().views[source_buf]
		return view and view.loading and callback
	end, "inline blame should start loading", ASYNC_TIMEOUT_MS)
	eq(inline_blame_text(source_buf), nil, "inline blame should stay quiet before loading delay")

	callback({ "     7 alice        2026-04-01 line one" })
	wait_for(function()
		return inline_blame_text(source_buf) ~= nil
	end, "inline blame result should render", ASYNC_TIMEOUT_MS)

	require("lazyvcs.blame").blame_clear()
	backend.blame_lines_async = original_blame_lines_async
end

local function test_svn_blame_inline_loading_indicator_and_uncommitted_line()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			loading_delay_ms = 10,
			loading_text = "Blame loading...",
			uncommitted_text = "Uncommitted line",
			format = "{author} r{revision}",
			max_width = 40,
		},
	})

	local backend = require("lazyvcs.backends.svn")
	local original_blame_lines_async = backend.blame_lines_async
	local callback
	---@diagnostic disable-next-line: duplicate-set-field
	backend.blame_lines_async = function(_, on_done)
		callback = on_done
		return {
			kill = function() end,
		}
	end

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	assert(require("lazyvcs.blame").blame())
	wait_for(function()
		return inline_blame_text(source_buf) == "  Blame loading..."
	end, "inline blame loading indicator should render after delay", ASYNC_TIMEOUT_MS)

	callback({
		"     7 alice        2026-04-01 line one",
		"      -          -                                            -     local line",
	})
	wait_for(function()
		return inline_blame_text(source_buf) == "  Uncommitted line"
	end, "inline blame should render a friendly uncommitted label", ASYNC_TIMEOUT_MS)

	require("lazyvcs.blame").blame_clear()
	backend.blame_lines_async = original_blame_lines_async
end

local function test_svn_blame_inline_loading_indicator_follows_cursor()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			loading_delay_ms = 10,
			loading_text = "Blame loading...",
		},
	})

	local backend = require("lazyvcs.backends.svn")
	local original_blame_lines_async = backend.blame_lines_async
	---@diagnostic disable-next-line: duplicate-set-field
	backend.blame_lines_async = function()
		return {
			kill = function() end,
		}
	end

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
	assert(require("lazyvcs.blame").blame())
	wait_for(function()
		return inline_blame_text(source_buf) == "  Blame loading..."
	end, "inline blame loading indicator should render after delay", ASYNC_TIMEOUT_MS)

	vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
	local test_state = require("lazyvcs.blame")._test_inline_state()
	local marks = vim.api.nvim_buf_get_extmarks(source_buf, test_state.namespace, 0, -1, {})
	eq(#marks, 1)
	eq(marks[1][2] + 1, 3, "loading inline blame should follow the cursor immediately once visible")

	require("lazyvcs.blame").blame_clear()
	backend.blame_lines_async = original_blame_lines_async
end

local function test_svn_blame_inline_failure_does_not_retry_on_cursor_move()
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
		},
	})

	local backend = require("lazyvcs.backends.svn")
	local original_blame_lines_async = backend.blame_lines_async
	local util = require("lazyvcs.util")
	local original_notify = util.notify
	local calls = 0
	---@diagnostic disable-next-line: duplicate-set-field
	backend.blame_lines_async = function(_, on_done)
		calls = calls + 1
		vim.schedule(function()
			on_done(nil, "simulated blame failure")
		end)
		return {
			kill = function() end,
		}
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function() end

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	assert(require("lazyvcs.blame").blame())
	wait_for(function()
		local view = require("lazyvcs.blame")._test_inline_state().views[source_buf]
		return view and view.error
	end, "inline blame failure should be recorded", ASYNC_TIMEOUT_MS)
	eq(calls, 1)

	for line = 1, 3 do
		vim.api.nvim_win_set_cursor(source_win, { line, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
	end
	vim.wait(50)
	eq(calls, 1, "failed inline blame should not refetch until the buffer is invalidated")

	require("lazyvcs.blame").blame_clear()
	backend.blame_lines_async = original_blame_lines_async
	util.notify = original_notify
end

local function test_svn_blame_split_is_fixed_width_and_muted()
	require("lazyvcs").setup({
		blame = {
			mode = "split",
			uncommitted_text = "Uncommitted line",
			split_min_width = 20,
			split_max_width = 24,
		},
	})

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()
	vim.wo[source_win].scrollbind = false
	vim.wo[source_win].cursorbind = false
	require("lazyvcs.blame").blame_split()

	wait_for(function()
		local view = require("lazyvcs.blame")._test_blame_views()[source_buf]
		return view and not view.loading and vim.api.nvim_win_is_valid(view.winid)
	end, "split blame should open", 5000)

	local view = require("lazyvcs.blame")._test_blame_views()[source_buf]
	eq(vim.api.nvim_get_current_win(), source_win)
	assert(vim.wo[view.winid].winfixwidth, "split blame should use fixed width")
	assert(vim.api.nvim_win_get_width(view.winid) <= 24, "split blame should respect max width")
	assert(vim.wo[view.winid].winhighlight:match("LazyVcsBlame"), "split blame should use muted highlights")
	eq(vim.wo[view.winid].number, false)
	eq(vim.wo[view.winid].relativenumber, false)
	eq(vim.wo[view.winid].signcolumn, "no")
	eq(vim.wo[view.winid].foldcolumn, "0")
	eq(vim.wo[view.winid].wrap, false)
	eq(vim.wo[view.winid].list, false)
	eq(vim.wo[view.winid].spell, false)
	eq(vim.wo[view.winid].scrollbind, true)
	eq(vim.wo[view.winid].cursorbind, true)
	eq(vim.wo[source_win].scrollbind, true)
	eq(vim.wo[source_win].cursorbind, true)
	pcall(function()
		eq(vim.wo[view.winid].statuscolumn, "")
	end)
	local blame_lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
	assert(vim.tbl_contains(blame_lines, "Uncommitted line"), "split blame should label uncommitted rows")
	require("lazyvcs.blame").blame_split()
	eq(vim.wo[source_win].scrollbind, false)
	eq(vim.wo[source_win].cursorbind, false)
end

local function test_live_diff_places_base_window_on_the_left()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local actions = require("lazyvcs.actions")
	local session = open_diff()

	local base_col = vim.api.nvim_win_get_position(session.base_win)[2]
	local editable_col = vim.api.nvim_win_get_position(session.editable_win)[2]
	assert(
		base_col < editable_col,
		"base/OLD window should sit left of the editable/NEW window (old -> new, left -> right)"
	)

	actions.close()
end

local function test_live_diff_scrollbinds_panes_and_restores_editable_window()
	require("lazyvcs").setup({ debounce_ms = 10 })

	vim.cmd.enew()
	local editable_buf = vim.api.nvim_get_current_buf()
	local editable_win = vim.api.nvim_get_current_win()
	vim.api.nvim_buf_set_name(editable_buf, vim.fs.normalize(vim.fn.tempname()) .. "/scrollbind-sample.txt")
	vim.api.nvim_buf_set_lines(editable_buf, 0, -1, false, {
		"one",
		"two changed",
		"three",
		"four",
		"five",
	})
	vim.wo[editable_win].scrollbind = false

	local config = require("lazyvcs.config")
	local layout = require("lazyvcs.layout")
	local session = {
		editable_bufnr = editable_buf,
		editable_win = editable_win,
		backend = "git",
		root = vim.fs.normalize(vim.fn.tempname()),
		relpath = "scrollbind-sample.txt",
		base_label = "base",
		base_lines = {
			"one",
			"two",
			"three",
			"four",
			"five",
		},
		opts = vim.deepcopy(config.get()),
	}

	layout.open(session)
	eq(vim.wo[session.editable_win].scrollbind, true)
	eq(vim.wo[session.base_win].scrollbind, true)

	layout.close(session)
	eq(vim.wo[editable_win].scrollbind, false)
end

local function assert_live_diff_window_options(session, expected_wrap)
	for _, winid in ipairs({ session.editable_win, session.base_win }) do
		eq(vim.wo[winid].diff, true)
		eq(vim.wo[winid].scrollbind, true)
		eq(vim.wo[winid].wrap, expected_wrap)
		eq(vim.wo[winid].linebreak, true)
		eq(vim.wo[winid].breakindent, true)
	end
end

local function assert_live_diff_wrap_behavior(followwrap)
	with_diffopt_flag("followwrap", followwrap, function()
		require("lazyvcs").setup({ debounce_ms = 10 })

		vim.cmd.enew()
		local editable_buf = vim.api.nvim_get_current_buf()
		local editable_win = vim.api.nvim_get_current_win()
		local previous_window_options = {
			wrap = vim.wo[editable_win].wrap,
			linebreak = vim.wo[editable_win].linebreak,
			breakindent = vim.wo[editable_win].breakindent,
		}
		vim.api.nvim_buf_set_name(editable_buf, vim.fs.normalize(vim.fn.tempname()) .. "/wrap-sample.txt")
		vim.api.nvim_buf_set_lines(editable_buf, 0, -1, false, {
			"a long editable line that can wrap in a narrow live diff window",
			"two changed",
			"three",
		})
		vim.wo[editable_win].wrap = true
		vim.wo[editable_win].linebreak = true
		vim.wo[editable_win].breakindent = true

		local layout = require("lazyvcs.layout")
		local session = {
			editable_bufnr = editable_buf,
			editable_win = editable_win,
			backend = "git",
			root = vim.fs.normalize(vim.fn.tempname()),
			relpath = "wrap-sample.txt",
			base_label = "base",
			base_lines = {
				"a long base line that can wrap in a narrow live diff window",
				"two",
				"three",
			},
			opts = vim.deepcopy(require("lazyvcs.config").get()),
		}

		local closed = false
		local ok, err = xpcall(function()
			layout.open(session)

			assert_live_diff_window_options(session, followwrap)

			layout.close(session)
			closed = true
			eq(vim.wo[editable_win].wrap, true)
			eq(vim.wo[editable_win].linebreak, true)
			eq(vim.wo[editable_win].breakindent, true)
		end, debug.traceback)

		if not closed then
			pcall(layout.close, session)
		end
		if vim.api.nvim_win_is_valid(editable_win) then
			for name, value in pairs(previous_window_options) do
				vim.wo[editable_win][name] = value
			end
		end
		if not ok then
			error(err, 0)
		end
	end)
end

local function test_live_diff_followwrap_preserves_wrapping_and_restores_editable_window()
	assert_live_diff_wrap_behavior(true)
end

local function test_live_diff_without_followwrap_uses_native_nowrap_and_restores_editable_window()
	assert_live_diff_wrap_behavior(false)
end

local function test_live_diff_sync_scroll_catches_unfocused_pane()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local session
	local ok, err = pcall(function()
		local root = vim.fs.normalize(vim.fn.tempname())
		vim.fn.mkdir(root, "p")
		helpers.exec({ "git", "init" }, root)
		helpers.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
		helpers.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)

		local base = {}
		local current = {}
		for i = 1, 120 do
			base[i] = string.format("line %03d base", i)
			current[i] = string.format("line %03d current", i)
		end

		local file = root .. "/scroll.txt"
		helpers.write_file(file, table.concat(base, "\n") .. "\n")
		helpers.exec({ "git", "add", "scroll.txt" }, root)
		helpers.exec({ "git", "commit", "-m", "init" }, root)
		helpers.write_file(file, table.concat(current, "\n") .. "\n")

		vim.cmd.edit(vim.fn.fnameescape(file))
		local actions = require("lazyvcs.actions")
		session = open_diff()
		vim.api.nvim_set_current_win(session.editable_win)

		vim.api.nvim_win_call(session.base_win, function()
			vim.wo[session.base_win].scrollbind = false
			vim.api.nvim_win_set_cursor(session.base_win, { 25, 0 })
			vim.fn.winrestview({ topline = 25, lnum = 25, col = 0, curswant = 0 })
			vim.wo[session.base_win].scrollbind = true
		end)

		local editable_view = vim.api.nvim_win_call(session.editable_win, vim.fn.winsaveview)
		local base_view = vim.api.nvim_win_call(session.base_win, vim.fn.winsaveview)
		eq(editable_view.topline, 1, "test setup should leave the focused pane unmoved")
		eq(base_view.topline, 25, "test setup should simulate an unfocused pane scroll")

		-- Shaped like a real WinScrolled `v:event`: keyed by window-ID strings,
		-- plus the "all" aggregate Neovim always includes.
		local source = actions._test_scroll_event_source(session, {
			all = { topline = 24 },
			[tostring(session.base_win)] = { topline = 24 },
		})
		eq(source, session.base_win, "only the unfocused pane moved, so it is the source")

		eq(
			actions._test_scroll_event_source(session, {
				all = { topline = 24 },
				[tostring(session.editable_win)] = { topline = 24 },
			}),
			session.editable_win,
			"only the focused pane moved, so it is the source"
		)

		-- Both panes moving used to return nil, on the assumption that native
		-- binding had already produced a correct result. That silently declined
		-- every genuine misalignment, so it now follows the focused pane.
		vim.api.nvim_set_current_win(session.editable_win)
		eq(
			actions._test_scroll_event_source(session, {
				all = { topline = 24 },
				[tostring(session.base_win)] = { topline = 24 },
				[tostring(session.editable_win)] = { topline = 24 },
			}),
			session.editable_win,
			"both panes moved, so the focused pane wins"
		)

		-- An event naming neither pane belongs to some other window entirely.
		eq(
			actions._test_scroll_event_source(session, { all = { topline = 3 }, ["9999"] = { topline = 3 } }),
			nil,
			"an unrelated window is not a source"
		)

		assert(require("lazyvcs.layout").sync_scroll(session, session.base_win))
		editable_view = vim.api.nvim_win_call(session.editable_win, vim.fn.winsaveview)
		base_view = vim.api.nvim_win_call(session.base_win, vim.fn.winsaveview)
		eq(editable_view.topline, base_view.topline, "sync_scroll should catch the focused pane up")

		actions.close()
		session = nil
	end)

	if session then
		require("lazyvcs.actions").close(session.editable_bufnr)
	end
	if not ok then
		error(err)
	end
end

local align_specs = {}

function align_specs.pairs_units()
	local align = require("lazyvcs.align")

	local units = align.pair_units({}, 3, 3)
	eq(#units, 3, "identical buffers pair every line one to one")
	eq(units[2].base[1], 2)
	eq(units[2].current[1], 2)

	units = align.pair_units({ { base_start = 3, base_count = 1, current_start = 3, current_count = 1 } }, 5, 5)
	eq(#units, 5, "a changed line does not desynchronise the pairing after it")
	eq(units[3].base[1], 3, "the changed line is its own unit")
	eq(units[3].current[1], 3)
	eq(units[5].base[1], 5, "lines after the change realign")
	eq(units[5].current[1], 5)

	-- vim.diff "indices" form: count 0 means the range is empty and `start` is
	-- the line the change sits after, so the anchor is still unchanged text.
	units = align.pair_units({ { base_start = 2, base_count = 0, current_start = 3, current_count = 2 } }, 4, 6)
	local insertion
	for _, unit in ipairs(units) do
		if unit.current and not unit.base then
			insertion = unit
		end
	end
	assert(insertion, "a pure insertion yields a unit with no base side")
	eq(insertion.current[1], 3)

	units = align.pair_units({ { base_start = 3, base_count = 2, current_start = 2, current_count = 0 } }, 6, 4)
	local deletion
	for _, unit in ipairs(units) do
		if unit.base and not unit.current then
			deletion = unit
		end
	end
	assert(deletion, "a pure deletion yields a unit with no current side")
	eq(deletion.base[1], 3)
end

-- Build a session whose two sides wrap to very different heights: the base has
-- one long line where the working copy has a short one, and vice versa. Without
-- alignment every line below the first mismatch renders on a different screen
-- row on each side, and the offset never recovers.
function align_specs.open_wrapped_mismatch_session()
	local root = vim.fs.normalize(vim.fn.tempname())
	vim.fn.mkdir(root, "p")
	helpers.exec({ "git", "init" }, root)
	helpers.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
	helpers.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)

	local long_a = "AAAA " .. string.rep("alpha beta gamma delta ", 20)
	local long_b = "BBBB " .. string.rep("omega psi chi phi ", 20)
	local base, current = {}, {}
	for i = 1, 10 do
		base[i] = string.format("line %02d", i)
		current[i] = string.format("line %02d", i)
	end
	base[11] = long_a
	current[11] = "AAAA short"
	base[12] = "BBBB short"
	current[12] = long_b
	for i = 13, 24 do
		base[i] = string.format("line %02d", i)
		current[i] = string.format("line %02d", i)
	end

	local file = root .. "/wrapped.txt"
	helpers.write_file(file, table.concat(base, "\n") .. "\n")
	helpers.exec({ "git", "add", "wrapped.txt" }, root)
	helpers.exec({ "git", "commit", "-m", "init" }, root)
	helpers.write_file(file, table.concat(current, "\n") .. "\n")

	vim.cmd.edit(vim.fn.fnameescape(file))
	vim.wo.wrap = true
	vim.wo.linebreak = true
	return open_diff()
end

---Screen row at which `lnum` is drawn, relative to the window's own first row.
---`screenpos` and not `nvim_win_text_height`: the latter attributes virtual rows
---to the line below them, which is exactly the padding being asserted here.
function align_specs.pane_screen_row(winid, lnum)
	local pos = vim.fn.screenpos(winid, lnum, 1)
	if not pos or (pos.row or 0) == 0 then
		return nil
	end
	return pos.row - 1 - vim.api.nvim_win_get_position(winid)[1]
end

function align_specs.same_screen_row()
	local session
	local ok, err = pcall(function()
		with_diffopt_flag("followwrap", true, function()
			require("lazyvcs").setup({ debounce_ms = 10, base_window = { align_wrapped = "auto" } })
			session = align_specs.open_wrapped_mismatch_session()

			eq(vim.wo[session.base_win].wrap, true, "followwrap should leave the base pane wrapped")
			eq(vim.wo[session.editable_win].wrap, true, "followwrap should leave the editable pane wrapped")
			eq(vim.wo[session.base_win].cursorbind, true, "cursor_sync defaults on")
			eq(
				vim.wo[session.base_win].smoothscroll,
				false,
				"smoothscroll must stay off while alignment owns the padding"
			)

			require("lazyvcs.align").apply(session)

			-- Lines 13..24 are identical on both sides, so after the mismatched
			-- pair above them they must face each other again.
			local misaligned = {}
			for _, lnum in ipairs({ 13, 16, 20 }) do
				local base_row = align_specs.pane_screen_row(session.base_win, lnum)
				local edit_row = align_specs.pane_screen_row(session.editable_win, lnum)
				if base_row ~= edit_row then
					misaligned[#misaligned + 1] =
						string.format("line %d base=%s edit=%s", lnum, tostring(base_row), tostring(edit_row))
				end
			end
			eq(#misaligned, 0, "corresponding lines should share a screen row: " .. table.concat(misaligned, "; "))

			-- A second pass must not stack more padding on top of the first.
			eq(require("lazyvcs.align").apply(session), false, "an unchanged plan should not be re-applied")
			for _, lnum in ipairs({ 13, 20 }) do
				eq(
					align_specs.pane_screen_row(session.base_win, lnum),
					align_specs.pane_screen_row(session.editable_win, lnum),
					"alignment should be idempotent"
				)
			end

			local editable_bufnr = session.editable_bufnr
			require("lazyvcs.actions").close()
			session = nil
			eq(
				#vim.api.nvim_buf_get_extmarks(editable_bufnr, require("lazyvcs.align").namespace(), 0, -1, {}),
				0,
				"closing the session should clear the alignment namespace"
			)
		end)
	end)

	if session then
		require("lazyvcs.actions").close(session.editable_bufnr)
	end
	if not ok then
		error(err)
	end
end

function align_specs.smoothscroll_off()
	local session
	local ok, err = pcall(function()
		with_diffopt_flag("followwrap", true, function()
			require("lazyvcs").setup({ debounce_ms = 10 })
			session = align_specs.open_wrapped_mismatch_session()

			eq(
				vim.wo[session.base_win].smoothscroll,
				true,
				"align_wrapped defaults to off, so smoothscroll gives screen-row scrolling"
			)
			eq(require("lazyvcs.align").apply(session), false, "alignment must not run when it is switched off")

			local editable_win = session.editable_win
			require("lazyvcs.actions").close()
			session = nil
			eq(vim.wo[editable_win].smoothscroll, false, "smoothscroll should be restored on close")
		end)
	end)

	if session then
		require("lazyvcs.actions").close(session.editable_bufnr)
	end
	if not ok then
		error(err)
	end
end

local function test_store_persists_values_across_reload()
	store._test_set_dir(STORE_DIR)
	store.set("lazyvcs_test_flag", true)
	store.set("lazyvcs_test_name", "kevin")

	eq(store.get("lazyvcs_test_flag"), true)
	eq(store.get("lazyvcs_test_name"), "kevin")
	eq(store.get("lazyvcs_test_missing", "fallback"), "fallback")

	-- Drop the in-memory cache and re-read from disk to prove the values were
	-- actually written, not just memoized.
	store._test_set_dir(STORE_DIR)
	eq(store.get("lazyvcs_test_flag"), true)
	eq(store.get("lazyvcs_test_name"), "kevin")
	assert(vim.uv.fs_stat(store.path()), "state file should exist on disk")

	store.set("lazyvcs_test_flag", nil)
	store.set("lazyvcs_test_name", nil)
end

local function test_blame_inline_toggle_persists_across_setup()
	store._test_set_dir(STORE_DIR)
	store.set("blame_inline_enabled", true)

	require("lazyvcs").setup({})
	local blame = require("lazyvcs.blame")
	assert(blame._test_inline_enabled(), "persisted inline blame should be restored on setup")

	-- A non-inline mode must ignore the persisted flag.
	require("lazyvcs").setup({ blame = { mode = "off" } })
	assert(not blame._test_inline_enabled(), "non-inline blame mode should not restore the toggle")

	-- Reset shared state so later tests start with blame off.
	store.set("blame_inline_enabled", nil)
	require("lazyvcs").setup({})
	assert(not blame._test_inline_enabled(), "inline blame should be off once the flag is cleared")
end

local function test_blame_inline_follows_cursor_without_waiting()
	-- persist = false keeps this responsiveness test from touching the toggle store.
	require("lazyvcs").setup({
		blame = {
			persist = false,
			delay_ms = 0,
			format = "{author} r{revision}",
		},
	})

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(source_win, { 1, 0 })

	local blame = require("lazyvcs.blame")
	assert(blame.blame())

	-- Wait once for the initial async `svn blame` fetch to populate the cache.
	wait_for(function()
		local view = blame._test_inline_state().views[source_buf]
		return view and view.entries ~= nil
	end, "inline blame data should load", 5000)

	local ns = blame._test_inline_state().namespace
	local function mark_lines()
		local out = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, ns, 0, -1, {})) do
			out[#out + 1] = mark[2] + 1
		end
		return out
	end

	-- Move to line 3 and fire CursorMoved. With data cached the overlay must
	-- follow on this very tick, so assert immediately without any vim.wait.
	vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
	eq(mark_lines(), { 3 }, "cached inline blame should follow the cursor immediately")

	blame.blame_clear()
	eq(#mark_lines(), 0)
end

local function test_svn_signs_render_and_revert_without_live_diff()
	require("lazyvcs").setup({
		debounce_ms = 10,
		signs = {
			debounce_ms = 10,
		},
	})

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local signs = require("lazyvcs.signs")
	local actions = require("lazyvcs.actions")
	local state = assert(refresh_signs(signs, 0))
	eq(#state.hunks, 1)

	local test_state = signs._test_state()
	local marks = vim.api.nvim_buf_get_extmarks(0, test_state.namespace, 0, -1, { details = true })
	assert(#marks > 0, "SVN signs should render extmarks")

	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	actions.next_hunk()
	eq(vim.api.nvim_win_get_cursor(0)[1], 2)
	actions.revert_hunk()
	eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "two", "three" })
end

local function test_svn_signs_preview_diff_window()
	require("lazyvcs").setup({
		signs = {
			debounce_ms = 10,
		},
	})

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local source_buf = vim.api.nvim_get_current_buf()
	assert(require("lazyvcs.signs").preview_diff())
	wait_for(function()
		local current = vim.api.nvim_get_current_buf()
		return current ~= source_buf and vim.bo[current].filetype == "diff"
	end, "SVN signs preview should open after signs finish loading", ASYNC_TIMEOUT_MS)
	local buf = vim.api.nvim_get_current_buf()
	eq(vim.bo[buf].filetype, "diff")
	vim.cmd.close()
end

local function test_svn_added_file_signs_and_live_diff()
	require("lazyvcs").setup({
		debounce_ms = 10,
		use_gitsigns = false,
		signs = {
			debounce_ms = 10,
		},
	})

	local fixture = helpers.make_svn_added_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))

	local signs = require("lazyvcs.signs")
	local state = assert(refresh_signs(signs, 0))
	eq(state.base_label, "EMPTY")
	eq(state.base_lines, {})
	eq(#state.hunks, 1)
	eq(state.hunks[1].base_count, 0)
	eq(state.hunks[1].current_count, 2)

	local marks = vim.api.nvim_buf_get_extmarks(0, signs._test_state().namespace, 0, -1, { details = true })
	eq(#marks, 2, "SVN added files should render every line as an added hunk")

	local actions = require("lazyvcs.actions")
	local session = open_diff()
	eq(session.backend, "svn")
	eq(session.base_label, "EMPTY")
	eq(session.base_lines, {})
	eq(#session.hunks, 1)
	actions.close()
end

local function test_svn_signs_ignore_untracked_files()
	require("lazyvcs").setup({
		debounce_ms = 10,
		use_gitsigns = false,
		signs = {
			debounce_ms = 10,
		},
	})

	local fixture = helpers.make_svn_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.untracked))

	local signs = require("lazyvcs.signs")
	local state, err = refresh_signs(signs, 0)
	eq(state, nil)
	-- supported_buffer no longer runs a synchronous is_versioned() probe (it ran on
	-- every BufEnter and blocked the UI thread), so trackedness is now decided by
	-- the backend load. An untracked file therefore reports the backend's error
	-- rather than being filtered out beforehand. What matters is unchanged: no
	-- state is cached and no signs are placed.
	if err ~= nil then
		assert(
			err:match("not found") or err:match("not tracked") or err:match("E200009"),
			"unexpected error for an untracked SVN file: " .. tostring(err)
		)
	end
	local marks = vim.api.nvim_buf_get_extmarks(0, signs._test_state().namespace, 0, -1, { details = true })
	eq(#marks, 0, "SVN untracked files should not render signs or load a base")
end

local function test_backend_resolves_directory_arguments()
	local helpers_fixture = helpers.make_git_fixture()
	local backends = require("lazyvcs.backends")
	backends.invalidate()

	-- Callers pass directories too (buffer_ops falls back to the cwd for non-file
	-- buffers). Resolving via dirname probed the PARENT, so a repo root reported
	-- "no working copy found".
	local backend, root = backends.resolve(helpers_fixture.root)
	assert(backend, "a repository root directory should resolve to a backend")
	eq(backend.name, "git")
	assert(root and root ~= "", "resolving a directory should yield a root")

	-- A file inside it must resolve to the same backend and root.
	local file_backend, file_root = backends.resolve(helpers_fixture.file)
	assert(file_backend, "a file inside a repository should resolve to a backend")
	eq(file_backend.name, "git")
	eq(file_root, root)
end

local function test_git_status_decodes_quoted_paths()
	local git = require("lazyvcs.backends.git")

	-- git C-quotes non-ASCII paths: a file named "cafe" with an acute accent is
	-- reported with LITERAL backslash-escaped octal bytes inside quotes. Stripping
	-- the quotes left those backslashes, and vim.fs.normalize then turned them
	-- into path separators, so the file could never be opened.
	local bs = string.char(92)
	local quoted = '?? "caf' .. bs .. "303" .. bs .. '251.txt"'
	local items = git.parse_status_lines({ quoted }, "/repo")
	eq(#items, 1)
	eq(items[1].path, "caf" .. string.char(195, 169) .. ".txt")
	assert(not items[1].absolute_path:match("/303/"), "octal escapes must not become path separators")

	-- A file legitimately named `a -> b.txt` must not be truncated: only R/C
	-- entries use the rename arrow.
	local plain = git.parse_status_lines({ " M a -> b.txt" }, "/repo")
	eq(#plain, 1)
	eq(plain[1].path, "a -> b.txt")

	local renamed = git.parse_status_lines({ "R  old.txt -> new.txt" }, "/repo")
	eq(#renamed, 1)
	eq(renamed[1].path, "new.txt")
end

local function test_relpath_never_returns_nil()
	local util = require("lazyvcs.util")

	eq(util.relpath("/repo", "/repo/a.txt"), "a.txt")
	eq(util.relpath("/repo", "/repo/sub/a.txt"), "sub/a.txt")

	-- vim.fs.relpath returns nil when the paths share no prefix, which happens on
	-- Windows when one side is an 8.3 short name (C:/Users/RUNNER~1/...) and the
	-- other is the long form. Callers concatenate this into buffer names and VCS
	-- arguments, so it must always be a string.
	local unrelated = util.relpath("/somewhere/else", "/repo/a.txt")
	eq(type(unrelated), "string")
	assert(unrelated ~= "", "relpath must not return an empty string")

	eq(type(util.relpath("", "/repo/a.txt")), "string")
end

local function test_single_command_replaces_legacy_surface()
	require("lazyvcs").setup({})

	eq(vim.fn.exists(":LazyVCS"), 2)

	-- The 47-command surface (casing twins, svnsigns aliases, per-action
	-- commands) collapsed into one dispatcher.
	for _, gone in ipairs({
		":LazyVcsBlame",
		":LazyVCSBlame",
		":LazyVCSBlameSplit",
		":LazyVCSDiffOpen",
		":LazyVCSSourceControlToggle",
		":LazyVcsSourceControlToggle",
		":VcsLiveDiffOpen",
		":SvnBlame",
		":SvnFiles",
	}) do
		eq(vim.fn.exists(gone), 0)
	end
end

local function test_command_completion_is_two_level()
	require("lazyvcs").setup({})
	local complete = require("lazyvcs.commands")._complete

	local top = complete("", "LazyVCS ")
	for _, name in ipairs({ "blame", "diff", "files", "hunk", "preview", "profile", "revert", "sidebar", "signs" }) do
		assert(vim.tbl_contains(top, name), "missing top-level completion: " .. name)
	end

	-- Prefix filtering.
	eq(complete("bl", "LazyVCS bl"), { "blame" })

	-- Second level.
	local blame_verbs = complete("", "LazyVCS blame ")
	for _, verb in ipairs({ "clear", "log", "split", "toggle" }) do
		assert(vim.tbl_contains(blame_verbs, verb), "missing blame verb: " .. verb)
	end
	eq(complete("", "LazyVCS hunk "), { "next", "prev", "revert" })

	-- Leaf subcommands take no verbs.
	eq(complete("", "LazyVCS files "), {})

	-- Unknown subcommand yields nothing rather than erroring.
	eq(complete("", "LazyVCS nope "), {})
end

local function test_unknown_subcommand_reports_valid_options()
	require("lazyvcs").setup({})

	-- Stub util.notify rather than vim.notify: it is what the dispatcher calls,
	-- and it stays intercepted even if an earlier test left its own stub behind.
	local util = require("lazyvcs.util")
	local messages = {}
	local real_notify = util.notify
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function(msg)
		messages[#messages + 1] = tostring(msg)
	end
	local ok = pcall(function()
		vim.cmd("LazyVCS definitely-not-a-subcommand")
	end)
	util.notify = real_notify

	assert(ok, "an unknown subcommand must not raise")
	local joined = table.concat(messages, "\n")
	assert(joined:match("Unknown subcommand"), joined)
	assert(joined:match("blame"), "the error should list valid subcommands: " .. joined)
end

local function test_setup_is_idempotent_and_respects_sign_toggle()
	require("lazyvcs").setup({
		signs = {
			enabled = true,
		},
	})
	require("lazyvcs").setup({
		signs = {
			enabled = false,
		},
	})

	eq(vim.fn.exists(":LazyVCS"), 2)

	require("lazyvcs").setup({
		signs = {
			enabled = true,
		},
	})
	eq(vim.fn.exists(":LazyVCS"), 2)
end

local function test_git_integration()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")

	local session = open_diff()
	eq(session.backend, "git")
	assert(vim.wo[session.editable_win].diff, "editable window should be in diff mode")
	assert(vim.wo[session.base_win].diff, "base window should be in diff mode")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(ASYNC_TIMEOUT_MS, function()
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
	local session = open_diff()
	local base_name = vim.api.nvim_buf_get_name(session.base_bufnr)

	actions.close()

	local stale = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(stale, base_name)

	local reopened = open_diff()
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
	local first_session = open_diff()
	local first_name = vim.api.nvim_buf_get_name(first_session.base_bufnr)
	local first_tab = vim.api.nvim_get_current_tabpage()

	vim.cmd.tabnew()
	vim.cmd.edit(vim.fn.fnameescape(second_fixture.file))
	local second_session = open_diff()
	local second_name = vim.api.nvim_buf_get_name(second_session.base_bufnr)

	assert(first_session.base_bufnr ~= second_session.base_bufnr, "sessions should not share base buffers")
	assert(first_name ~= second_name, "repo-aware base buffer names should differ across repos")

	actions.close()
	vim.cmd.tabclose()

	vim.api.nvim_set_current_tabpage(first_tab)
	actions.close(first_session.editable_bufnr)
end

local function comparison_for_file(path, root)
	return {
		backend = "git",
		kind = "working",
		path = path,
		root = root,
		relpath = vim.fs.basename(path),
		editable_side = "right",
		left = {
			label = "BASE",
			lines = { "base" },
			modifiable = false,
		},
		right = {
			label = "WORKING",
			path = path,
			modifiable = true,
		},
	}
end

local function fake_git_load_result(path, root)
	return {
		name = "git",
		impl = require("lazyvcs.backends.git"),
		root = root,
		relpath = vim.fs.basename(path),
		tracked = true,
		base_label = "BASE",
		base_lines = { "base" },
	}
end

local function test_live_diff_async_open_does_not_reclaim_navigated_window()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	local root = helpers.tempdir()
	local first = vim.fs.joinpath(root, "first.txt")
	local second = vim.fs.joinpath(root, "second.txt")
	helpers.write_file(first, "first\n")
	helpers.write_file(second, "second\n")
	vim.cmd.edit(vim.fn.fnameescape(first))

	local actions = require("lazyvcs.actions")
	local backends = require("lazyvcs.backends")
	local state = require("lazyvcs.state")
	local Task = require("lazyvcs.backends.task")
	local previous_load_async = backends.load_async
	local deferred
	local first_bufnr = vim.api.nvim_get_current_buf()
	local ok, err = xpcall(function()
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(_, on_done)
			deferred = Task.new(on_done)
			return deferred
		end

		local task = actions.open({ silent = true })
		eq(task, deferred)
		vim.cmd.edit(vim.fn.fnameescape(second))
		local second_bufnr = vim.api.nvim_get_current_buf()

		assert(deferred:finish(fake_git_load_result(first, root)))
		eq(vim.api.nvim_get_current_buf(), second_bufnr, "async completion must not restore the source buffer")
		eq(state.get(first_bufnr), nil, "navigation must prevent the stale diff session from opening")
		eq(diff_window_count(), 0)
	end, debug.traceback)
	backends.load_async = previous_load_async
	if state.get(first_bufnr) then
		pcall(actions.close, first_bufnr)
	end
	if not ok then
		error(err, 0)
	end
end

local function test_live_diff_cancelled_open_task_allows_future_open()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	local root = helpers.tempdir()
	local path = vim.fs.joinpath(root, "open-cancel.txt")
	helpers.write_file(path, "working\n")
	vim.cmd.edit(vim.fn.fnameescape(path))

	local actions = require("lazyvcs.actions")
	local backends = require("lazyvcs.backends")
	local state = require("lazyvcs.state")
	local Task = require("lazyvcs.backends.task")
	local previous_load_async = backends.load_async
	local tasks = {}
	local opened
	local ok, err = xpcall(function()
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(_, on_done)
			local task = Task.new(on_done)
			tasks[#tasks + 1] = task
			return task
		end

		local first_task = actions.open({ silent = true })
		assert(first_task:kill(), "the first open task should be cancellable")
		local second_task = actions.open({
			silent = true,
			on_open = function(session)
				opened = session
			end,
		})
		assert(second_task ~= first_task, "a cancelled task must not remain cached as the pending open")
		eq(#tasks, 2, "a later open must start a fresh backend request")
		assert(second_task:finish(fake_git_load_result(path, root)))
		assert(opened, "the replacement open should create a live diff session")
	end, debug.traceback)
	backends.load_async = previous_load_async
	if opened and state.get(opened.editable_bufnr) then
		pcall(actions.close, opened.editable_bufnr)
	end
	if not ok then
		error(err, 0)
	end
end

local function test_live_diff_close_during_inflight_transfer_does_not_reopen()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	local root = helpers.tempdir()
	local first = vim.fs.joinpath(root, "transfer-first.txt")
	local second = vim.fs.joinpath(root, "transfer-second.txt")
	helpers.write_file(first, "first\n")
	helpers.write_file(second, "second\n")
	vim.cmd.edit(vim.fn.fnameescape(first))

	local actions = require("lazyvcs.actions")
	local backends = require("lazyvcs.backends")
	local state = require("lazyvcs.state")
	local previous_load_async = backends.load_async
	local pending
	local session = assert(actions.open_target(comparison_for_file(first, root)))
	local ok, err = xpcall(function()
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(path, on_done)
			pending = {
				path = path,
				on_done = on_done,
				killed = false,
			}
			function pending:kill()
				self.killed = true
				return true
			end
			return pending
		end

		vim.api.nvim_set_current_win(session.editable_win)
		vim.cmd.badd(vim.fn.fnameescape(second))
		vim.cmd.buffer(vim.fn.fnameescape(second))
		wait_for(function()
			return pending ~= nil
		end, "transfer should start a deferred backend request")
		eq(state.peek_pending_transfer(session.editable_win).handle, pending)

		actions.close()
		assert(pending.killed, "closing the session must cancel its in-flight transfer")
		eq(state.get(session.editable_bufnr), nil)
		eq(state.peek_pending_transfer(session.editable_win), nil)
		eq(diff_window_count(), 0)

		pending.on_done(fake_git_load_result(second, root))
		eq(state.current(), nil, "a late transfer callback must not register a replacement session")
		eq(diff_window_count(), 0, "a late transfer callback must not resurrect the diff layout")
		eq(#vim.api.nvim_tabpage_list_wins(0), 1)
	end, debug.traceback)
	backends.load_async = previous_load_async
	if state.get(session.editable_bufnr) then
		pcall(actions.close, session.editable_bufnr)
	end
	if not ok then
		error(err, 0)
	end
end

local function test_live_diff_close_restores_exact_buffer_mapping()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file))
	local bufnr = vim.api.nvim_get_current_buf()
	vim.keymap.set("n", "q", function()
		return "<CR>"
	end, {
		buffer = bufnr,
		expr = true,
		nowait = true,
		remap = true,
		replace_keycodes = false,
		script = true,
		silent = true,
	})
	local original = vim.fn.maparg("q", "n", false, true)

	local actions = require("lazyvcs.actions")
	local session = open_diff()
	actions.close(session.editable_bufnr)

	local restored = vim.fn.maparg("q", "n", false, true)
	-- The round trip is the actual guarantee: whatever maparg() reported before
	-- must come back identical afterwards.
	eq(restored, original, "closing LazyVCS must round-trip every attribute of the overwritten mapping")
	-- Neovim 0.11 omits replace_keycodes from maparg() entirely while 0.12
	-- reports it, so pin the concrete values only where the running version
	-- exposes them.
	if original.replace_keycodes ~= nil then
		eq(restored.replace_keycodes, 0)
	end
	if original.script ~= nil then
		eq(restored.script, 1)
	end
end

local function test_live_diff_failed_transfer_resets_preexisting_diff_state()
	require("lazyvcs").setup({ signs = { enabled = false } })
	local root = helpers.tempdir()
	local first = vim.fs.joinpath(root, "first.txt")
	local second = vim.fs.joinpath(root, "second.txt")
	helpers.write_file(first, "first\n")
	helpers.write_file(second, "second\n")

	vim.cmd.tabnew()
	local test_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd.edit(vim.fn.fnameescape(first))
	vim.cmd("diffthis")
	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local backends = require("lazyvcs.backends")
	local previous_load_async = backends.load_async
	local pending
	local session
	local ok, err = xpcall(function()
		session = assert(actions.open_target(comparison_for_file(first, root)))
		assert(session.editable_had_diff, "the transfer fixture should capture a preexisting diff window")

		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(path, on_done)
			pending = { path = path, on_done = on_done }
			return { kill = function() end }
		end
		vim.api.nvim_set_current_win(session.editable_win)
		vim.cmd.badd(vim.fn.fnameescape(second))
		vim.cmd.buffer(vim.fn.fnameescape(second))
		wait_for(function()
			return pending ~= nil
		end, "failed transfer should start an async backend request")
		eq(pending.path, second)
		pending.on_done(nil, "not tracked")
		wait_for(function()
			return state.get(session.editable_bufnr) == nil
		end, "failed transfer should close the stale session", ASYNC_TIMEOUT_MS)
		eq(diff_window_count(), 0, "failed transfer should clear captured diff state")
	end, debug.traceback)
	backends.load_async = previous_load_async
	if session and state.get(session.editable_bufnr) then
		pcall(actions.close, session.editable_bufnr)
	end
	if vim.api.nvim_tabpage_is_valid(test_tab) then
		pcall(vim.api.nvim_set_current_tabpage, test_tab)
		pcall(function()
			vim.cmd("tabclose!")
		end)
	end
	if not ok then
		error(err, 0)
	end
end

local function test_live_diff_rapid_transfer_late_exit_resets_preexisting_diff_state()
	require("lazyvcs").setup({ signs = { enabled = false } })
	local root = helpers.tempdir()
	local first = vim.fs.joinpath(root, "first.txt")
	local second = vim.fs.joinpath(root, "second.txt")
	local third = vim.fs.joinpath(root, "third.txt")
	helpers.write_file(first, "first\n")
	helpers.write_file(second, "second\n")
	helpers.write_file(third, "third\n")

	vim.cmd.tabnew()
	local test_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd.edit(vim.fn.fnameescape(first))
	vim.cmd("diffthis")
	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local backends = require("lazyvcs.backends")
	local previous_load_async = backends.load_async
	local pending
	local session
	local ok, err = xpcall(function()
		session = assert(actions.open_target(comparison_for_file(first, root)))
		assert(session.editable_had_diff, "the transfer fixture should capture a preexisting diff window")

		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(path, on_done)
			pending = { path = path, on_done = on_done }
			return { kill = function() end }
		end
		vim.api.nvim_set_current_win(session.editable_win)
		vim.cmd.badd(vim.fn.fnameescape(second))
		vim.cmd.buffer(vim.fn.fnameescape(second))
		wait_for(function()
			return pending ~= nil
		end, "rapid transfer should start an async backend request")
		vim.cmd.badd(vim.fn.fnameescape(third))
		vim.cmd.buffer(vim.fn.fnameescape(third))
		pending.on_done({
			name = "git",
			impl = require("lazyvcs.backends.git"),
			root = root,
			relpath = "second.txt",
			tracked = true,
			base_label = "BASE",
			base_lines = { "base" },
		})
		wait_for(function()
			return state.get(session.editable_bufnr) == nil
		end, "a late transfer result should close the stale session after rapid navigation", ASYNC_TIMEOUT_MS)
		eq(diff_window_count(), 0, "rapid transfer should clear captured diff state")
	end, debug.traceback)
	backends.load_async = previous_load_async
	if session and state.get(session.editable_bufnr) then
		pcall(actions.close, session.editable_bufnr)
	end
	if vim.api.nvim_tabpage_is_valid(test_tab) then
		pcall(vim.api.nvim_set_current_tabpage, test_tab)
		pcall(function()
			vim.cmd("tabclose!")
		end)
	end
	if not ok then
		error(err, 0)
	end
end

local function readonly_comparison(root)
	return {
		backend = "git",
		kind = "commit",
		root = root,
		relpath = "sample.txt",
		left = {
			label = "LEFT",
			lines = { "left" },
			modifiable = false,
		},
		right = {
			label = "RIGHT",
			lines = { "right" },
			modifiable = false,
		},
	}
end

local function test_source_control_comparison_closes_plugin_created_editor_split()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	vim.cmd.enew()
	local sidebar_buf = vim.api.nvim_get_current_buf()
	vim.bo[sidebar_buf].filetype = "lazyvcs-source-control"
	local actions = require("lazyvcs.actions")

	local session = assert(actions.open_target(readonly_comparison(vim.fn.getcwd())))
	assert(session.owned_editor_win, "comparison should record the editor split it created")
	eq(#vim.api.nvim_tabpage_list_wins(0), 3, "comparison should own an editor split plus its base split")
	actions.close(session.editable_bufnr)
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "closing comparison should close both plugin-owned splits")
	eq(vim.api.nvim_get_current_buf(), sidebar_buf)
end

local function test_source_control_comparison_failure_closes_plugin_created_editor_split()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	vim.cmd.enew()
	local sidebar_buf = vim.api.nvim_get_current_buf()
	vim.bo[sidebar_buf].filetype = "lazyvcs-source-control"
	local actions = require("lazyvcs.actions")
	local layout = require("lazyvcs.layout")
	local previous_open = layout.open
	---@diagnostic disable-next-line: duplicate-set-field
	layout.open = function()
		error("forced comparison layout failure")
	end

	local ok, result = pcall(actions.open_target, readonly_comparison(vim.fn.getcwd()))
	layout.open = previous_open
	assert(ok, tostring(result))
	eq(result, nil)
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "failed comparison should close its plugin-owned editor split")
	eq(vim.api.nvim_get_current_buf(), sidebar_buf)
end

local function test_source_control_comparison_bufread_error_closes_plugin_created_editor_split()
	require("lazyvcs").setup({ signs = { enabled = false } })
	vim.cmd("silent! only")
	vim.cmd.enew()
	local sidebar_buf = vim.api.nvim_get_current_buf()
	vim.bo[sidebar_buf].filetype = "lazyvcs-source-control"
	local root = helpers.tempdir()
	local path = vim.fs.joinpath(root, "bufread-error.txt")
	helpers.write_file(path, "working\n")
	local group = vim.api.nvim_create_augroup("lazyvcs_test_comparison_bufread_error", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		callback = function(args)
			if vim.fs.normalize(vim.api.nvim_buf_get_name(args.buf)) == path then
				error("forced comparison BufReadPost failure")
			end
		end,
	})

	local actions = require("lazyvcs.actions")
	local ok, result = pcall(actions.open_target, comparison_for_file(path, root))
	pcall(vim.api.nvim_del_augroup_by_id, group)
	assert(ok, tostring(result))
	eq(result, nil)
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "BufReadPost failure must close the plugin-created editor split")
	eq(vim.api.nvim_get_current_buf(), sidebar_buf)
end

local function test_git_buffer_transfer_reopens_session()
	with_diffopt_flag("followwrap", true, function()
		require("lazyvcs").setup({ debounce_ms = 10 })

		local fixture = helpers.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

		local editable_win = vim.api.nvim_get_current_win()
		local previous_window_options = {
			wrap = vim.wo[editable_win].wrap,
			linebreak = vim.wo[editable_win].linebreak,
			breakindent = vim.wo[editable_win].breakindent,
		}
		vim.wo[editable_win].wrap = true
		vim.wo[editable_win].linebreak = true
		vim.wo[editable_win].breakindent = true

		local actions = require("lazyvcs.actions")
		local state = require("lazyvcs.state")
		local session
		local ok, err = xpcall(function()
			local first_session = open_diff()
			session = first_session
			assert_live_diff_window_options(first_session, true)

			vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
			vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
			wait_for(function()
				local live = state.current()
				return live ~= nil and live.source_path == fixture.file2
			end, "live diff should transfer to the second Git buffer", ASYNC_TIMEOUT_MS)

			local second_session = assert(state.current())
			session = second_session
			eq(second_session.backend, "git")
			eq(second_session.source_path, fixture.file2)
			assert(second_session.editable_bufnr ~= first_session.editable_bufnr, "should reopen on the new buffer")
			assert_transfer_session_matches(second_session, {
				base_lines = fixture.base2,
				changed_line = 4,
				unchanged_line = 2,
			})
			assert_live_diff_window_options(second_session, true)

			vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
			wait_for(function()
				local live = state.current()
				return live ~= nil and live.source_path == fixture.file1
			end, "live diff should transfer back to the first Git buffer", ASYNC_TIMEOUT_MS)

			local third_session = assert(state.current())
			session = third_session
			eq(third_session.backend, "git")
			eq(third_session.source_path, fixture.file1)
			assert_transfer_session_matches(third_session, {
				base_lines = fixture.base1,
				changed_line = 2,
				unchanged_line = 4,
			})
			assert_live_diff_window_options(third_session, true)

			actions.close()
			session = nil
		end, debug.traceback)

		local live = state.current()
		if live then
			pcall(actions.close, live.editable_bufnr)
		elseif session then
			pcall(actions.close, session.editable_bufnr)
		end
		if vim.api.nvim_win_is_valid(editable_win) then
			for name, value in pairs(previous_window_options) do
				vim.wo[editable_win][name] = value
			end
		end
		if not ok then
			error(err, 0)
		end
	end)
end

local function test_git_buffer_transfer_refetches_aerial_after_reopen()
	local refetch_calls, util_stub, cleanup = install_aerial_stubs()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = open_diff()
	eq(select(1, util_stub.is_ignored_win(first_session.editable_win)), false)

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file2 and #refetch_calls > 0
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
	local session = open_diff()

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
	local session = open_diff()

	pcall(vim.api.nvim_win_set_width, session.base_win, 20)
	vim.api.nvim_exec_autocmds("WinResized", {})
	vim.wait(ASYNC_TIMEOUT_MS, function()
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
	local session = open_diff()
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
	vim.wait(ASYNC_TIMEOUT_MS, function()
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
	local first_session = open_diff()
	eq(first_session.source_path, fixture.file1)

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file2
	end)

	local markdown_session = assert(state.current())
	eq(markdown_session.source_path, fixture.file2)
	eq(vim.b[markdown_session.editable_bufnr].snacks_scope, false)
	eq(vim.b[markdown_session.editable_bufnr].snacks_indent, false)
	assert(diff_window_count() == 2, "markdown transfer should keep a two-window diff layout")

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file1
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
	local session_state = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	local specs = model.discover(fixture.root, 1)
	local state = {
		path = fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
		lazyvcs_force_expand = {
			[model.repo_changes_id(fixture.root)] = true,
		},
	}
	state.lazyvcs_render = function() end

	local function reload_tree()
		state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_details(model, specs[1], {
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
	eq(file_node.extra.section, "changes", "fixture change should be an unstaged tracked file")

	ops.revert_file(state, file_node)
	wait_for(function()
		-- `git checkout --` replaces the file, so there is a window in which it
		-- does not exist. `readfile` *throws* on a missing file, and an error out
		-- of a wait_for predicate fails the test outright instead of retrying --
		-- which made this spuriously fail roughly one run in three.
		if vim.fn.filereadable(fixture.file) ~= 1 then
			return false
		end
		return vim.deep_equal(vim.fn.readfile(fixture.file), { "one", "two", "three" })
			and session_state.get_repo_job(fixture.root) == nil
	end, "git discard should finish in the background", ASYNC_TIMEOUT_MS)
	eq(vim.fn.readfile(fixture.file), { "one", "two", "three" })

	helpers.write_file(fixture.file, "one\nchanged\nthree\n")
	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.stage_file(state, file_node)
	wait_for(function()
		return helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root):match("sample.txt") ~= nil
			and session_state.get_repo_job(fixture.root) == nil
	end, "git stage should finish in the background", ASYNC_TIMEOUT_MS)
	assert(helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root):match("sample.txt"))

	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.unstage_file(state, file_node)
	wait_for(function()
		return util.trim(helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root)) == ""
			and session_state.get_repo_job(fixture.root) == nil
	end, "git unstage should finish in the background", ASYNC_TIMEOUT_MS)
	eq(util.trim(helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root)), "")

	tree = reload_tree()
	file_node = assert(find_first_node(tree, "file"))
	ops.stage_file(state, file_node)
	wait_for(function()
		return helpers.exec({ "git", "diff", "--cached", "--name-only" }, fixture.root):match("sample.txt") ~= nil
			and session_state.get_repo_job(fixture.root) == nil
	end, "git restage should finish in the background", ASYNC_TIMEOUT_MS)

	tree = reload_tree()
	repo_node = assert(find_first_node(tree, "repo_changes"))
	state.lazyvcs_commit_drafts[fixture.root] = "fixture commit"
	ops.commit_repo(state, repo_node)
	wait_for(function()
		return util.trim(helpers.exec({ "git", "log", "-1", "--pretty=%s" }, fixture.root)) == "fixture commit"
			and session_state.get_repo_job(fixture.root) == nil
	end, "git commit should finish in the background", ASYNC_TIMEOUT_MS)
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
	remote_state.lazyvcs_repo_cache[remote_fixture.root] = assert(load_repo_summary(model, remote_specs[1], {
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
		) == util.trim(helpers.exec({ "git", "rev-parse", "HEAD" }, remote_fixture.root)) and session_state.get_repo_job(
			remote_fixture.root
		) == nil
	end, "git sync should finish in the background", ASYNC_TIMEOUT_MS)
	eq(
		util.trim(
			helpers.exec(
				{ "git", "--git-dir", remote_fixture.origin, "rev-parse", "refs/heads/main" },
				remote_fixture.root
			)
		),
		util.trim(helpers.exec({ "git", "rev-parse", "HEAD" }, remote_fixture.root))
	)
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
	local repo_root = vim.fs.normalize(vim.fn.tempname())
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
		["git branch --show-current"] = "develop\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/develop"] = "origin/develop\n",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/develop",
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
	local repo_root = vim.fs.normalize(vim.fn.tempname())
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
		["git branch --show-current"] = "develop\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/develop"] = "origin/develop\n",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/develop",
		"git fetch --prune --quiet origin",
		"git status --branch --porcelain=v1 --untracked-files=no --ignored=no",
		"git branch --show-current",
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
	local repo_root = vim.fs.normalize(vim.fn.tempname())
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
		["git branch --show-current"] = "feature/local\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/feature/local"] = "fork/feature/shared\n",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/local",
		"git fetch --prune --quiet fork",
		"git status --branch --porcelain=v1 --untracked-files=no --ignored=no",
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/local",
		"git branch --show-current",
		"git push fork feature/local:feature/shared",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_publish_branch_sets_upstream_to_origin()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/new",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git branch --show-current"] = "feature/new\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/feature/new"] = "",
		["git remote"] = "fork\norigin\n",
		["git push --set-upstream origin feature/new"] = "",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git remote",
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git push --set-upstream origin feature/new",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_sync_without_upstream_publishes_branch()
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
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/new",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
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
		["git branch --show-current"] = "feature/new\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/feature/new"] = "",
		["git remote"] = "origin\n",
		["git push --set-upstream origin feature/new"] = "",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git remote",
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git push --set-upstream origin feature/new",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_push_uses_configured_upstream()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
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
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git branch --show-current"] = "feature/local\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/feature/local"] = "fork/feature/shared\n",
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

	ops.run_primary_action(state, node)
	eq(calls, {
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/local",
		"git branch --show-current",
		"git push fork feature/local:feature/shared",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_publish_falls_back_to_single_remote()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local calls = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/new",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}
	local responses = {
		["git branch --show-current"] = "feature/new\n",
		["git for-each-ref --format=%(upstream:short) refs/heads/feature/new"] = "",
		["git remote"] = "fork\n",
		["git push --set-upstream fork feature/new"] = "",
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
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git remote",
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git push --set-upstream fork feature/new",
	})
	eq(session_state.get_repo_job(repo_root), nil)

	util.system_start = previous_system_start
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_publish_requires_unambiguous_remote()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local previous_notify = util.notify
	local calls = {}
	local notifications = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/new",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		if key == "git branch --show-current" then
			on_exit({ code = 0, stdout = "feature/new\n", stderr = "" }, nil)
			return {}
		end
		if key == "git for-each-ref --format=%(upstream:short) refs/heads/feature/new" then
			on_exit({ code = 0, stdout = "", stderr = "" }, nil)
			return {}
		end
		if key == "git remote" then
			on_exit({ code = 0, stdout = "fork\nupstream\n", stderr = "" }, nil)
			return {}
		end
		error("unexpected command: " .. key)
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function(message)
		notifications[#notifications + 1] = message
	end

	ops.run_primary_action(state, node)
	eq(calls, {
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git remote",
	})
	local job = assert(session_state.get_repo_job(repo_root))
	eq(job.status, "error")
	assert(job.error:match("multiple Git remotes and no origin remote"), job.error)
	assert(notifications[1]:match("multiple Git remotes and no origin remote"), notifications[1])

	util.system_start = previous_system_start
	util.notify = previous_notify
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_publish_requires_a_remote()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local previous_notify = util.notify
	local calls = {}
	local notifications = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "feature/new",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		if key == "git branch --show-current" then
			on_exit({ code = 0, stdout = "feature/new\n", stderr = "" }, nil)
			return {}
		end
		if key == "git for-each-ref --format=%(upstream:short) refs/heads/feature/new" then
			on_exit({ code = 0, stdout = "", stderr = "" }, nil)
			return {}
		end
		if key == "git remote" then
			on_exit({ code = 0, stdout = "", stderr = "" }, nil)
			return {}
		end
		error("unexpected command: " .. key)
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function(message)
		notifications[#notifications + 1] = message
	end

	ops.run_primary_action(state, node)
	eq(calls, {
		"git branch --show-current",
		"git for-each-ref --format=%(upstream:short) refs/heads/feature/new",
		"git remote",
	})
	local job = assert(session_state.get_repo_job(repo_root))
	eq(job.status, "error")
	assert(job.error:match("has no Git remotes"), job.error)
	assert(notifications[1]:match("has no Git remotes"), notifications[1])

	util.system_start = previous_system_start
	util.notify = previous_notify
	session_state.clear_repo_job(repo_root)
end

local function test_source_control_git_publish_rejects_detached_head()
	require("lazyvcs").setup()

	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local session_state = require("lazyvcs.state")
	local previous_system_start = util.system_start
	local previous_notify = util.notify
	local calls = {}
	local notifications = {}
	local repo_root = vim.fs.normalize(vim.fn.tempname())
	local state = {
		path = repo_root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_cache = {
			[repo_root] = {
				root = repo_root,
				name = "repo",
				vcs = "git",
				branch = "HEAD",
				counts = { local_changes = 0, staged = 0, remote = 0 },
				sync = { status = "publish" },
			},
		},
	}
	local node = {
		type = "action_button",
		path = repo_root,
		extra = {
			repo_root = repo_root,
			action = "push",
		},
		get_id = function()
			return repo_root
		end,
	}

	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _opts, on_exit)
		local key = table.concat(args, " ")
		calls[#calls + 1] = key
		assert(key == "git branch --show-current", "unexpected command: " .. key)
		on_exit({ code = 0, stdout = "", stderr = "" }, nil)
		return {}
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.notify = function(message)
		notifications[#notifications + 1] = message
	end

	ops.run_primary_action(state, node)
	eq(calls, { "git branch --show-current" })
	local job = assert(session_state.get_repo_job(repo_root))
	eq(job.status, "error")
	assert(job.error:match("detached HEAD"), job.error)
	assert(notifications[1]:match("detached HEAD"), notifications[1])

	util.system_start = previous_system_start
	util.notify = previous_notify
	session_state.clear_repo_job(repo_root)
end

local function test_svn_integration()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local session = open_diff()
	eq(session.backend, "svn")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(ASYNC_TIMEOUT_MS, function()
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
	local util = require("lazyvcs.util")

	local commit_fixture = helpers.make_svn_fixture()
	local commit_specs = model.discover(commit_fixture.root, 1)
	local commit_state = {
		path = commit_fixture.root,
		lazyvcs_commit_drafts = {},
		lazyvcs_repo_specs = commit_specs,
		lazyvcs_repo_cache = {},
		lazyvcs_changes_sort = "path",
	}
	commit_state.lazyvcs_render = function() end
	commit_state.lazyvcs_repo_cache[commit_fixture.root] = assert(load_repo_details(model, commit_specs[1], {
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
	end, "svn commit should finish in the background", ASYNC_TIMEOUT_MS)
	eq(util.trim(helpers.exec({ "svn", "status" }, commit_fixture.root)), "")
	assert(
		helpers
			.exec({ "svn", "log", "-l", "1", helpers.file_url(commit_fixture.repo) }, commit_fixture.root)
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
	update_state.lazyvcs_render = function() end
	update_state.lazyvcs_repo_cache[update_fixture.root] = assert(load_repo_summary(model, update_specs[1], {
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
	end, "svn update should finish in the background", ASYNC_TIMEOUT_MS)
	eq(vim.fn.readfile(update_fixture.file), { "one", "updated", "three" })
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
		lazyvcs_force_expand = {
			[model.repo_changes_id(fixture.root)] = true,
		},
	}
	state.lazyvcs_repo_cache[fixture.root] = assert(load_repo_details(model, specs[1], {
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
	local context = assert(collect_switch_targets(switch, repo))
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

local function test_source_control_git_switch_picker_is_vscode_like()
	local switch = require("lazyvcs.source_control.switch")
	local context = {
		refs = {
			{
				ref_kind = "remote_branch",
				short = "origin/feature/remote",
				short_hash = "2222222",
				relative_date = "2 days ago",
				author = "Ada",
				subject = "Remote work",
			},
			{
				ref_kind = "local_branch",
				short = "main",
				short_hash = "1111111",
				relative_date = "1 day ago",
				author = "Ada",
				subject = "Main work",
				current = true,
			},
			{
				ref_kind = "tag",
				short = "v1.0.0",
				short_hash = "3333333",
				relative_date = "3 days ago",
				author = "Ada",
				subject = "Release",
			},
		},
	}
	local items = switch._test_git_picker_items(context)
	eq(items[1].action, "git_create_branch")
	eq(items[2].action, "git_create_branch_from")
	eq(items[3].action, "git_checkout_detached")
	eq(items[4].kind, "local_branch")
	eq(items[5].kind, "remote_branch")
	eq(items[6].kind, "tag")

	local command_line = switch._test_format_picker_item(items[1], false)
	assert(command_line:match("^%+ Create new branch%.%.%."), command_line)
	local current_chunks = switch._test_format_picker_item(items[4], true)
	assert(type(current_chunks) == "table", "current branch should format as chunks")
	local current_line = flatten_chunks(current_chunks)
	assert(not current_line:match("^%s*%d+%."), current_line)
	assert(current_line:find("✓", 1, true), current_line)
	assert(current_line:find("main", 1, true), current_line)
	local remote_chunks = switch._test_format_picker_item(items[5], true)
	assert(type(remote_chunks) == "table", "remote branch should format as chunks")
	local remote_line = flatten_chunks(remote_chunks)
	assert(remote_line:find("Remote branch at 2222222", 1, true), remote_line)
	local has_remote_category = false
	for _, chunk in ipairs(remote_chunks) do
		if chunk.virt_text and chunk.virt_text[1] and chunk.virt_text[1][1] == "remote branches" then
			has_remote_category = true
		end
	end
	assert(has_remote_category, "remote branch category should be right-aligned virtual text")
end

local function test_source_control_git_switch_snacks_picker_omits_indices()
	local previous_snacks_picker = package.loaded["snacks.picker"]
	local captured
	package.loaded["snacks.picker"] = {
		pick = function(opts)
			local items = opts.finder()
			captured = {
				title = opts.title,
				layout = opts.layout,
				first_line = flatten_chunks(opts.format(items[1])),
				second_line = flatten_chunks(opts.format(items[2])),
			}
			return {}
		end,
	}

	local fixture = helpers.make_git_switch_fixture()
	local repo = { root = fixture.root, name = "clone", vcs = "git" }
	require("lazyvcs.source_control.switch").open_async(repo, {
		input = function(_, _) end,
		notify = function() end,
	}, async_command_runner(repo.root))

	wait_for(function()
		return captured ~= nil
	end, "async Git switch targets should reach the Snacks picker", 5000)
	assert(captured, "expected Snacks picker to be used")
	eq(captured.title, "Checkout branch or tag for clone")
	eq(captured.layout.preset, "vscode")
	assert(not captured.first_line:match("^%s*%d+%."), captured.first_line)
	assert(captured.first_line:match("^%+ Create new branch%.%.%."), captured.first_line)
	assert(not captured.second_line:match("^%s*%d+%."), captured.second_line)

	package.loaded["snacks.picker"] = previous_snacks_picker
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
		local expected_after = after_count + 1
		switch.open_async(repo, {
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
		}, async_command_runner(repo.root))
		wait_for(function()
			return after_count == expected_after
		end, "async Git switch mutation did not finish", 5000)
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

local function test_source_control_switch_open_async_uses_async_default_mutation()
	local switch = require("lazyvcs.source_control.switch")
	local util = require("lazyvcs.util")
	local previous_collect_async = switch.collect_async
	local previous_system = util.system
	local previous_system_start = util.system_start
	local command
	local exit_callback
	local after_count = 0

	---@diagnostic disable-next-line: duplicate-set-field
	switch.collect_async = function(_, _, on_done)
		on_done({
			vcs = "svn",
			info = { url = "https://example.test/svn/trunk" },
			items = {
				{
					kind = "svn_branch",
					label = "branches/next",
					target_url = "https://example.test/svn/branches/next",
				},
			},
		}, nil)
		return { kill = function() end }
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.system = function()
		error("switch.open_async must not call the synchronous system runner")
	end
	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, _, on_exit)
		command = args
		exit_callback = on_exit
		return { kill = function() end }
	end

	local ok, err = xpcall(function()
		switch.open_async({
			root = vim.fn.getcwd(),
			name = "repo",
			vcs = "svn",
		}, {
			select = function(items, _, on_choice)
				on_choice(items[1])
			end,
			notify = function() end,
			after_mutation = function()
				after_count = after_count + 1
			end,
		})
		eq(command, {
			"svn",
			"switch",
			"--ignore-ancestry",
			"https://example.test/svn/branches/next",
			vim.fn.getcwd(),
		})
		eq(after_count, 0, "async switch completion must wait for the process callback")
		assert(exit_callback, "async switch should retain the process callback")
		exit_callback({ code = 0, stdout = "", stderr = "" }, nil, { code = 0, stdout = "", stderr = "" })
		eq(after_count, 1)
	end, debug.traceback)
	switch.collect_async = previous_collect_async
	util.system = previous_system
	util.system_start = previous_system_start
	if not ok then
		error(err, 0)
	end
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

	switch.open_async(standard_repo, {
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
	}, async_command_runner(standard_repo.root))
	wait_for(function()
		return after_count == 1
	end, "async SVN switch mutation did not finish", 5000)

	eq(
		util.trim(helpers.exec({ "svn", "info", "--show-item", "url" }, standard_fixture.root)),
		standard_fixture.release_url
	)
	eq(before_count, 1)
	eq(after_count, 1)

	local nonstandard_fixture = helpers.make_svn_fixture()
	local nonstandard_repo = { root = nonstandard_fixture.root, name = "sample", vcs = "svn" }
	local context = assert(collect_switch_targets(switch, nonstandard_repo))
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
	end, "switch repo should invalidate cache after async completion", ASYNC_TIMEOUT_MS)
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
	local first_session = open_diff()

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file2
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
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file1
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

local function test_svn_buffer_transfer_handles_added_and_untracked_files()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = open_diff()

	vim.cmd.badd(vim.fn.fnameescape(fixture.added))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.added))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.added
	end)

	local added_session = assert(state.current())
	eq(added_session.backend, "svn")
	eq(added_session.source_path, fixture.added)
	eq(added_session.base_label, "EMPTY")
	eq(added_session.base_lines, {})
	eq(diff_window_count(), 2, "SVN added file transfer should keep the live diff layout")

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		local live = state.current()
		return live ~= nil and live.source_path == fixture.file2
	end)

	local tracked_session = assert(state.current())
	eq(tracked_session.backend, "svn")
	eq(tracked_session.source_path, fixture.file2)
	assert_transfer_session_matches(tracked_session, {
		base_lines = fixture.base2,
		changed_line = 4,
		unchanged_line = 2,
	})

	vim.cmd.badd(vim.fn.fnameescape(fixture.untracked))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.untracked))
	vim.wait(ASYNC_TIMEOUT_MS, function()
		return state.get(first_session.editable_bufnr) == nil
			and state.get(added_session.editable_bufnr) == nil
			and state.get(tracked_session.editable_bufnr) == nil
			and diff_window_count() == 0
	end)

	eq(state.current(), nil, "SVN untracked transfer should close the active session")
	eq(diff_window_count(), 0, "SVN untracked transfer should clear tab diff state")
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "SVN untracked transfer should not leave a stale base split")
end

local function test_transfer_to_unsupported_buffer_closes_session()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = open_diff()

	vim.cmd.enew()
	vim.wait(ASYNC_TIMEOUT_MS, function()
		return state.get(first_session.editable_bufnr) == nil and diff_window_count() == 0
	end)

	eq(state.get(first_session.editable_bufnr), nil, "old session should close on unsupported buffer transfer")
	eq(diff_window_count(), 0, "unsupported buffer transfer should clear tab diff state")
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "base window should close on unsupported buffer transfer")
end

-- Test registry. Each test runs in isolation via xpcall so one failing or
-- skipped test no longer aborts the whole suite (previously the missing-svnadmin
-- assert in make_svn_fixture killed every test that followed it).
local cases = {
	{ "test_diff_reset", test_diff_reset },
	{ "test_diff_reset_for_insertion", test_diff_reset_for_insertion },
	{ "test_diff_reset_for_deletion", test_diff_reset_for_deletion },
	{ "test_diff_reset_for_top_deletion", test_diff_reset_for_top_deletion },
	{ "test_config_normalization", test_config_normalization },
	{
		"test_source_control_auto_remote_refresh_is_throttled_per_root",
		test_source_control_auto_remote_refresh_is_throttled_per_root,
	},
	{
		"test_source_control_rejects_removed_neotree_ui",
		test_source_control_rejects_removed_neotree_ui,
	},
	{
		"test_optional_integrations_detect_vanilla_and_enhanced_modes",
		test_optional_integrations_detect_vanilla_and_enhanced_modes,
	},
	{ "test_commit_input_generates_message_from_popup", test_commit_input_generates_message_from_popup },
	{
		"test_ai_commit_message_auto_falls_back_to_next_cli_provider",
		test_ai_commit_message_auto_falls_back_to_next_cli_provider,
	},
	{ "test_picker_uses_snacks_select_module_when_available", test_picker_uses_snacks_select_module_when_available },
	{
		"test_picker_uses_fzf_lua_when_snacks_select_is_unavailable",
		test_picker_uses_fzf_lua_when_snacks_select_is_unavailable,
	},
	{
		"test_core_backend_task_cancellation_finish_and_late_add",
		test_core_backend_task_cancellation_finish_and_late_add,
	},
	{ "test_svn_xml_parses_info_status_list_and_entities", test_svn_xml_parses_info_status_list_and_entities },
	{
		"test_core_json_file_migration_atomic_replace_and_invalid_reads",
		test_core_json_file_migration_atomic_replace_and_invalid_reads,
	},
	{
		"test_source_control_modal_escape_q_and_wipe_finish_once_and_restore_view",
		test_source_control_modal_escape_q_and_wipe_finish_once_and_restore_view,
	},
	{
		"test_core_compat_routes_neovim_011_and_012_apis",
		test_core_compat_routes_neovim_011_and_012_apis,
	},
	{
		"test_source_control_persist_owns_state_serialization_and_apply",
		test_source_control_persist_owns_state_serialization_and_apply,
	},
	{
		"test_source_control_discovery_error_is_rendered_in_sidebar",
		test_source_control_discovery_error_is_rendered_in_sidebar,
	},
	{ "test_source_control_confirm_popup_key_paths", test_source_control_confirm_popup_key_paths },
	{ "test_compute_target_view_centered_hunk", test_compute_target_view_centered_hunk },
	{ "test_compute_target_view_large_hunk", test_compute_target_view_large_hunk },
	{ "test_compute_target_view_start_and_end_clamping", test_compute_target_view_start_and_end_clamping },
	{ "test_compute_target_view_for_deletion_hunk", test_compute_target_view_for_deletion_hunk },
	{ "test_git_backend", test_git_backend },
	{ "test_async_system_reports_missing_executable", test_async_system_reports_missing_executable },
	{ "test_async_system_cancel_waits_for_real_process_exit", test_async_system_cancel_waits_for_real_process_exit },
	{
		"test_async_system_owns_timeout_escalation_and_bounded_output",
		test_async_system_owns_timeout_escalation_and_bounded_output,
	},
	{ "test_svn_backend", test_svn_backend },
	{ "test_svn_backend_added_file_uses_empty_base", test_svn_backend_added_file_uses_empty_base },
	{ "test_svn_added_file_blame_uses_uncommitted_lines", test_svn_added_file_blame_uses_uncommitted_lines },
	{ "test_svn_status_and_blame_parsers", test_svn_status_and_blame_parsers },
	{ "test_git_blame_parser_and_remote_urls", test_git_blame_parser_and_remote_urls },
	{ "test_svn_async_blame_cancels_active_child_process", test_svn_async_blame_cancels_active_child_process },
	{ "test_git_blame_inline_virtual_text", test_git_blame_inline_virtual_text },
	{ "test_svn_blame_inline_virtual_text", test_svn_blame_inline_virtual_text },
	{ "test_svn_blame_inline_delays_loading_indicator", test_svn_blame_inline_delays_loading_indicator },
	{
		"test_svn_blame_inline_loading_indicator_and_uncommitted_line",
		test_svn_blame_inline_loading_indicator_and_uncommitted_line,
	},
	{
		"test_svn_blame_inline_loading_indicator_follows_cursor",
		test_svn_blame_inline_loading_indicator_follows_cursor,
	},
	{
		"test_svn_blame_inline_failure_does_not_retry_on_cursor_move",
		test_svn_blame_inline_failure_does_not_retry_on_cursor_move,
	},
	{ "test_svn_blame_split_is_fixed_width_and_muted", test_svn_blame_split_is_fixed_width_and_muted },
	{ "test_live_diff_places_base_window_on_the_left", test_live_diff_places_base_window_on_the_left },
	{
		"test_live_diff_scrollbinds_panes_and_restores_editable_window",
		test_live_diff_scrollbinds_panes_and_restores_editable_window,
	},
	{
		"test_live_diff_followwrap_preserves_wrapping_and_restores_editable_window",
		test_live_diff_followwrap_preserves_wrapping_and_restores_editable_window,
	},
	{
		"test_live_diff_without_followwrap_uses_native_nowrap_and_restores_editable_window",
		test_live_diff_without_followwrap_uses_native_nowrap_and_restores_editable_window,
	},
	{
		"test_live_diff_align_pairs_corresponding_text_into_units",
		align_specs.pairs_units,
	},
	{
		"test_live_diff_align_puts_wrapped_lines_on_the_same_screen_row",
		align_specs.same_screen_row,
	},
	{
		"test_live_diff_align_off_uses_smoothscroll_and_restores_it",
		align_specs.smoothscroll_off,
	},
	{
		"test_live_diff_sync_scroll_catches_unfocused_pane",
		test_live_diff_sync_scroll_catches_unfocused_pane,
	},
	{
		"test_live_diff_async_open_does_not_reclaim_navigated_window",
		test_live_diff_async_open_does_not_reclaim_navigated_window,
	},
	{
		"test_live_diff_cancelled_open_task_allows_future_open",
		test_live_diff_cancelled_open_task_allows_future_open,
	},
	{
		"test_live_diff_close_during_inflight_transfer_does_not_reopen",
		test_live_diff_close_during_inflight_transfer_does_not_reopen,
	},
	{
		"test_live_diff_close_restores_exact_buffer_mapping",
		test_live_diff_close_restores_exact_buffer_mapping,
	},
	{
		"test_live_diff_failed_transfer_resets_preexisting_diff_state",
		test_live_diff_failed_transfer_resets_preexisting_diff_state,
	},
	{
		"test_live_diff_rapid_transfer_late_exit_resets_preexisting_diff_state",
		test_live_diff_rapid_transfer_late_exit_resets_preexisting_diff_state,
	},
	{ "test_store_persists_values_across_reload", test_store_persists_values_across_reload },
	{ "test_blame_inline_toggle_persists_across_setup", test_blame_inline_toggle_persists_across_setup },
	{ "test_blame_inline_follows_cursor_without_waiting", test_blame_inline_follows_cursor_without_waiting },
	{ "test_svn_signs_render_and_revert_without_live_diff", test_svn_signs_render_and_revert_without_live_diff },
	{ "test_svn_signs_preview_diff_window", test_svn_signs_preview_diff_window },
	{ "test_svn_added_file_signs_and_live_diff", test_svn_added_file_signs_and_live_diff },
	{ "test_svn_signs_ignore_untracked_files", test_svn_signs_ignore_untracked_files },
	{ "test_relpath_never_returns_nil", test_relpath_never_returns_nil },
	{ "test_backend_resolves_directory_arguments", test_backend_resolves_directory_arguments },
	{ "test_git_status_decodes_quoted_paths", test_git_status_decodes_quoted_paths },
	{ "test_single_command_replaces_legacy_surface", test_single_command_replaces_legacy_surface },
	{ "test_command_completion_is_two_level", test_command_completion_is_two_level },
	{ "test_unknown_subcommand_reports_valid_options", test_unknown_subcommand_reports_valid_options },
	{ "test_setup_is_idempotent_and_respects_sign_toggle", test_setup_is_idempotent_and_respects_sign_toggle },
	{ "test_source_control_collects_dirty_nested_repos", test_source_control_collects_dirty_nested_repos },
	{
		"test_source_control_progressive_collect_shows_unhydrated_repos",
		test_source_control_progressive_collect_shows_unhydrated_repos,
	},
	{ "test_source_control_busy_repo_marks_nodes_disabled", test_source_control_busy_repo_marks_nodes_disabled },
	{
		"test_source_control_async_summary_waits_for_command_callback",
		test_source_control_async_summary_waits_for_command_callback,
	},
	{
		"test_source_control_background_refresh_preserves_cached_badges",
		test_source_control_background_refresh_preserves_cached_badges,
	},
	{
		"test_source_control_unloaded_repo_still_shows_loading_badge",
		test_source_control_unloaded_repo_still_shows_loading_badge,
	},
	{
		"test_source_control_jobs_prioritize_user_work_over_background_refresh",
		test_source_control_jobs_prioritize_user_work_over_background_refresh,
	},
	{
		"test_source_control_jobs_cancel_holds_worker_until_delayed_exit",
		test_source_control_jobs_cancel_holds_worker_until_delayed_exit,
	},
	{
		"test_source_control_jobs_cancel_forces_kill_after_grace_before_reap",
		test_source_control_jobs_cancel_forces_kill_after_grace_before_reap,
	},
	{
		"test_source_control_jobs_timeout_racing_late_exit_completes_once",
		test_source_control_jobs_timeout_racing_late_exit_completes_once,
	},
	{
		"test_source_control_jobs_cancel_racing_late_exit_completes_once",
		test_source_control_jobs_cancel_racing_late_exit_completes_once,
	},
	{
		"test_source_control_jobs_generation_isolated_for_equal_tostring_owners",
		test_source_control_jobs_generation_isolated_for_equal_tostring_owners,
	},
	{
		"test_source_control_details_cancel_clears_cached_loading_flag_and_requeues",
		test_source_control_details_cancel_clears_cached_loading_flag_and_requeues,
	},
	{
		"test_source_control_details_cancel_isolated_between_sidebar_owners",
		test_source_control_details_cancel_isolated_between_sidebar_owners,
	},
	{
		"test_source_control_hydration_cancel_one_of_two_repositories_requeues_without_stranding",
		test_source_control_hydration_cancel_one_of_two_repositories_requeues_without_stranding,
	},
	{
		"test_source_control_hydration_cancel_isolated_between_sidebar_owners",
		test_source_control_hydration_cancel_isolated_between_sidebar_owners,
	},
	{
		"test_source_control_svn_summary_uses_compact_branch_label",
		test_source_control_svn_summary_uses_compact_branch_label,
	},
	{
		"test_source_control_single_repo_root_uses_unique_node_ids",
		test_source_control_single_repo_root_uses_unique_node_ids,
	},
	{
		"test_source_control_duplicate_repo_names_use_root_identity",
		test_source_control_duplicate_repo_names_use_root_identity,
	},
	{ "test_source_control_can_show_clean_repos", test_source_control_can_show_clean_repos },
	{
		"test_source_control_toggle_repo_visibility_keeps_a_visible_repo",
		test_source_control_toggle_repo_visibility_keeps_a_visible_repo,
	},
	{
		"test_source_control_toggle_repo_visibility_ignores_section_rows",
		test_source_control_toggle_repo_visibility_ignores_section_rows,
	},
	{ "test_source_control_repo_actions_ignore_non_repo_rows", test_source_control_repo_actions_ignore_non_repo_rows },
	{
		"test_source_control_confirm_session_choice_disables_more_prompts",
		test_source_control_confirm_session_choice_disables_more_prompts,
	},
	{
		"test_source_control_tree_view_groups_files_into_folders",
		test_source_control_tree_view_groups_files_into_folders,
	},
	{
		"test_source_control_hides_clean_repo_after_summary_hydration",
		test_source_control_hides_clean_repo_after_summary_hydration,
	},
	{
		"test_source_control_open_repo_recreates_force_expand_after_intermediate_navigate",
		test_source_control_open_repo_recreates_force_expand_after_intermediate_navigate,
	},
	{
		"test_source_control_open_repo_collapses_expanded_stale_node_first",
		test_source_control_open_repo_collapses_expanded_stale_node_first,
	},
	{
		"test_source_control_open_repo_expands_loaded_collapsed_node",
		test_source_control_open_repo_expands_loaded_collapsed_node,
	},
	{ "test_source_control_open_repo_can_collapse_while_busy", test_source_control_open_repo_can_collapse_while_busy },
	{
		"test_source_control_native_render_consumes_force_expand",
		test_source_control_native_render_consumes_force_expand,
	},
	{
		"test_source_control_native_open_can_preserve_current_window",
		test_source_control_native_open_can_preserve_current_window,
	},
	{
		"test_source_control_native_smart_e_toggles_auto_width_and_restores_cursor",
		test_source_control_native_smart_e_toggles_auto_width_and_restores_cursor,
	},
	{
		"test_source_control_native_render_preserves_active_window_and_repo_meta_spacing",
		test_source_control_native_render_preserves_active_window_and_repo_meta_spacing,
	},
	{
		"test_source_control_native_invalidated_cache_rehydrates",
		test_source_control_native_invalidated_cache_rehydrates,
	},
	{ "test_svn_status_xml_ignores_external_banner_noise", test_svn_status_xml_ignores_external_banner_noise },
	{
		"test_source_control_open_change_reopens_without_base_buffer_collision",
		test_source_control_open_change_reopens_without_base_buffer_collision,
	},
	{
		"test_source_control_open_change_reuses_active_diff_window",
		test_source_control_open_change_reuses_active_diff_window,
	},
	{
		"test_source_control_comparison_closes_plugin_created_editor_split",
		test_source_control_comparison_closes_plugin_created_editor_split,
	},
	{
		"test_source_control_comparison_failure_closes_plugin_created_editor_split",
		test_source_control_comparison_failure_closes_plugin_created_editor_split,
	},
	{
		"test_source_control_comparison_bufread_error_closes_plugin_created_editor_split",
		test_source_control_comparison_bufread_error_closes_plugin_created_editor_split,
	},
	{
		"test_aerial_integration_suspends_window_and_restores_buffer_state",
		test_aerial_integration_suspends_window_and_restores_buffer_state,
	},
	{ "test_git_integration", test_git_integration },
	{ "test_git_reopen_tolerates_stale_base_buffer_name", test_git_reopen_tolerates_stale_base_buffer_name },
	{
		"test_git_sessions_with_same_relpath_in_different_repos_do_not_collide",
		test_git_sessions_with_same_relpath_in_different_repos_do_not_collide,
	},
	{ "test_git_buffer_transfer_reopens_session", test_git_buffer_transfer_reopens_session },
	{
		"test_git_buffer_transfer_refetches_aerial_after_reopen",
		test_git_buffer_transfer_refetches_aerial_after_reopen,
	},
	{ "test_git_rebalance_evenly_splits_active_diff_pair", test_git_rebalance_evenly_splits_active_diff_pair },
	{ "test_git_win_resized_rebalances_active_diff_pair", test_git_win_resized_rebalances_active_diff_pair },
	{ "test_git_base_window_leader_q_closes_session", test_git_base_window_leader_q_closes_session },
	{
		"test_markdown_transfer_sets_editor_guards_and_reopens_cleanly",
		test_markdown_transfer_sets_editor_guards_and_reopens_cleanly,
	},
	{
		"test_source_control_git_file_actions_commit_and_sync",
		test_source_control_git_file_actions_commit_and_sync,
	},
	{
		"test_source_control_git_sync_uses_explicit_upstream_fast_forward",
		test_source_control_git_sync_uses_explicit_upstream_fast_forward,
	},
	{
		"test_source_control_git_pull_action_uses_explicit_upstream_fast_forward",
		test_source_control_git_pull_action_uses_explicit_upstream_fast_forward,
	},
	{
		"test_source_control_git_sync_pushes_to_configured_upstream",
		test_source_control_git_sync_pushes_to_configured_upstream,
	},
	{
		"test_source_control_git_publish_branch_sets_upstream_to_origin",
		test_source_control_git_publish_branch_sets_upstream_to_origin,
	},
	{
		"test_source_control_git_sync_without_upstream_publishes_branch",
		test_source_control_git_sync_without_upstream_publishes_branch,
	},
	{ "test_source_control_git_push_uses_configured_upstream", test_source_control_git_push_uses_configured_upstream },
	{
		"test_source_control_git_publish_falls_back_to_single_remote",
		test_source_control_git_publish_falls_back_to_single_remote,
	},
	{
		"test_source_control_git_publish_requires_unambiguous_remote",
		test_source_control_git_publish_requires_unambiguous_remote,
	},
	{ "test_source_control_git_publish_requires_a_remote", test_source_control_git_publish_requires_a_remote },
	{ "test_source_control_git_publish_rejects_detached_head", test_source_control_git_publish_rejects_detached_head },
	{ "test_source_control_busy_repo_blocks_repo_actions", test_source_control_busy_repo_blocks_repo_actions },
	{ "test_source_control_git_switch_collects_refs", test_source_control_git_switch_collects_refs },
	{ "test_source_control_git_switch_picker_is_vscode_like", test_source_control_git_switch_picker_is_vscode_like },
	{
		"test_source_control_git_switch_snacks_picker_omits_indices",
		test_source_control_git_switch_snacks_picker_omits_indices,
	},
	{
		"test_source_control_git_switch_executes_checkout_flows",
		test_source_control_git_switch_executes_checkout_flows,
	},
	{
		"test_source_control_switch_open_async_uses_async_default_mutation",
		test_source_control_switch_open_async_uses_async_default_mutation,
	},
	{ "test_svn_integration", test_svn_integration },
	{ "test_source_control_svn_commit_and_update", test_source_control_svn_commit_and_update },
	{
		"test_source_control_svn_switch_supports_standard_and_manual_layouts",
		test_source_control_svn_switch_supports_standard_and_manual_layouts,
	},
	{
		"test_source_control_switch_repo_closes_matching_sessions_and_refreshes_repo",
		test_source_control_switch_repo_closes_matching_sessions_and_refreshes_repo,
	},
	{ "test_svn_buffer_transfer_reopens_session", test_svn_buffer_transfer_reopens_session },
	{
		"test_svn_buffer_transfer_handles_added_and_untracked_files",
		test_svn_buffer_transfer_handles_added_and_untracked_files,
	},
	{ "test_transfer_to_unsupported_buffer_closes_session", test_transfer_to_unsupported_buffer_closes_session },
}

local svn_group_overrides = {
	test_source_control_collects_dirty_nested_repos = true,
}

local live_diff_prefixes = {
	"test_git_integration",
	"test_git_reopen",
	"test_git_sessions",
	"test_git_buffer",
	"test_git_rebalance",
	"test_git_win",
	"test_git_base",
}

local function group_for(name)
	if svn_group_overrides[name] or name:find("svn", 1, true) then
		return "svn"
	end
	if name:find("blame", 1, true) or name:find("sign", 1, true) then
		return "blame_signs"
	end
	local is_live_diff = name:find("live_diff", 1, true)
		or name:find("markdown_transfer", 1, true)
		or name:find("open_change", 1, true)
		or name:find("aerial_integration", 1, true)
		or name:find("transfer_to_unsupported", 1, true)
	for _, prefix in ipairs(live_diff_prefixes) do
		is_live_diff = is_live_diff or vim.startswith(name, prefix)
	end
	if is_live_diff then
		return "live_diff"
	end
	if name:find("source_control", 1, true) then
		return "source_control"
	end
	return "core"
end

local selected_group = assert(vim.env.LAZYVCS_TEST_GROUP, "tests/spec.lua must run through tests/run.lua")
local selected_case = vim.env.LAZYVCS_TEST_CASE
local passed, skipped = 0, 0
local failures = {}
for _, case in ipairs(cases) do
	local name, fn = case[1], case[2]
	if group_for(name) == selected_group and (not selected_case or selected_case == "" or selected_case == name) then
		local ok, err = xpcall(fn, function(e)
			if type(e) == "table" then
				return e
			end
			return debug.traceback(tostring(e), 2)
		end)
		local cleanup_ok, cleanup_err = pcall(helpers.cleanup)
		if ok and cleanup_ok then
			passed = passed + 1
			print(string.format("PASS  %s", name))
		elseif type(err) == "table" and err.lazyvcs_skip and cleanup_ok then
			skipped = skipped + 1
			print(string.format("SKIP  %s — %s", name, err.lazyvcs_skip))
		else
			failures[#failures + 1] = name
			local reason = cleanup_ok and err or ("fixture cleanup failed: " .. tostring(cleanup_err))
			print(string.format("FAIL  %s\n%s", name, tostring(reason)))
		end
	end
end

pcall(vim.fn.delete, STORE_DIR, "rf")
print(string.format("\nlazyvcs %s tests: %d passed, %d skipped, %d failed", selected_group, passed, skipped, #failures))
if #failures > 0 then
	print("FAILED: " .. table.concat(failures, ", "))
	_G.LAZYVCS_TEST_FAILED = true
else
	print("lazyvcs tests: ok")
	_G.LAZYVCS_TEST_FAILED = false
end
