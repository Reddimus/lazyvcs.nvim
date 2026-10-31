return function(ctx)
	local api, h = vim.api, ctx.helpers
	local actions, signs, state = require("lazyvcs.actions"), require("lazyvcs.signs"), require("lazyvcs.state")
	local tokens, tasks = {}, {}
	local function guard(fn)
		return function()
			local policy = vim.o.fileignorecase
			local backends = require("lazyvcs.backends")
			local resolve = backends.resolve_async
			local ok, err = xpcall(fn, debug.traceback)
			for _, task in ipairs(tasks) do
				task:kill()
			end
			tasks = {}
			backends.resolve_async = resolve
			for _, item in ipairs(tokens) do
				item.api.finish_base_change(item.token)
			end
			tokens = {}
			vim.o.fileignorecase = policy
			h.cleanup()
			assert(ok, err)
		end
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local source = h.make_git_fixture()
		local root = h.tempdir() .. "/UPPERREPO"
		h.exec({ "git", "clone", "--quiet", "--no-hardlinks", source.root, root }, source.root)
		h.exec({ "git", "config", "user.name", "Probe" }, root)
		h.exec({ "git", "config", "user.email", "probe@example.test" }, root)
		h.exec({ "git", "mv", "sample.txt", "UPPERFILE.TXT" }, root)
		h.exec({ "git", "commit", "-m", "uppercase path" }, root)
		local path = root .. "/UPPERFILE.TXT"
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(path))
		return root, path, api.nvim_get_current_buf()
	end
	local function begin(controller, root, path)
		local token = controller.begin_base_change(root, { path })
		tokens[#tokens + 1] = { api = controller, token = token }
		return token
	end
	local function open()
		local task = assert(actions.open())
		tasks[#tasks + 1] = task
		return task
	end
	local cases = {
		{
			"test_core_case_policy_explicit_literal_membership",
			guard(function()
				local relative = require("lazyvcs.util").relative_literal_path
				vim.o.fileignorecase = true
				assert(
					relative("/UpperRoot", "/upperroot/file", false) == nil,
					"explicit false inherited current global policy"
				)
				assert(
					relative("/UpperRoot", "/upperroot/file") == "file",
					"omitted policy stopped following current global"
				)
				vim.o.fileignorecase = false
				assert(relative("/UpperRoot", "/upperroot/file", true) == "file", "explicit true was not honored")
				assert(
					relative("/UpperRoot", "/upperroot/file") == nil,
					"omitted policy no longer follows current global"
				)
			end),
		},
	}
	for _, mode in ipairs({ "actions", "signs", "pending" }) do
		for _, scenario in ipairs({ "true_to_false", "false_to_true", "overlapping" }) do
			local name = (mode == "signs" and "test_signs_case_policy_" or "test_live_diff_case_policy_")
				.. mode
				.. "_"
				.. scenario
			cases[#cases + 1] = {
				name,
				guard(function()
					local root, path, buf = fixture()
					local controller = mode == "signs" and signs or actions
					vim.o.fileignorecase = scenario ~= "false_to_true"
					local live, completed, owner
					if mode == "actions" then
						open()
						ctx.wait_for(function()
							return state.get(buf)
						end, "live absent", 15000)
						live = assert(state.get(buf))
					elseif mode == "signs" then
						local ready
						signs.refresh(buf, true, function(value, err)
							assert(value, err)
							ready = true
						end, true)
						ctx.wait_for(function()
							return ready
						end, "initial signs absent", 15000)
					end
					local first = begin(controller, root, path)
					if mode == "pending" then
						local backends = require("lazyvcs.backends")
						local resolve = backends.resolve_async
						local resolved = false
						---@diagnostic disable-next-line: duplicate-set-field
						backends.resolve_async = function(p, done, opts)
							return resolve(p, function(...)
								resolved = true
								done(...)
							end, opts)
						end
						owner = open()
						ctx.wait_for(function()
							return resolved
						end, "pending owner unresolved", 15000)
						backends.resolve_async = resolve
					elseif mode == "signs" then
						signs.refresh(buf, false, function(value)
							completed = value ~= nil
						end, true)
					end
					local function blocked()
						if mode == "actions" then
							assert(live.base_changing, "live owner lost its active mutation")
						elseif mode == "signs" then
							assert(not completed, "signs settled before the final matching mutation")
						else
							assert(
								owner:is_active() and not state.get(buf),
								"pending owner read before matching mutations settled"
							)
						end
					end
					blocked()
					local second
					if scenario == "overlapping" then
						vim.o.fileignorecase = false
						second = begin(controller, root, path)
					end
					h.write_file(path, "FRESH INDEX BASE\n")
					h.exec({ "git", "add", "UPPERFILE.TXT" }, root)
					if second then
						vim.o.fileignorecase = true
						controller.finish_base_change(second)
						blocked()
						vim.o.fileignorecase = false
					else
						vim.o.fileignorecase = not vim.o.fileignorecase
					end
					controller.finish_base_change(first)
					ctx.wait_for(function()
						if mode == "signs" then
							local current = signs.current_state(buf)
							return completed
								and current
								and current.base_lines
								and current.base_lines[1] == "FRESH INDEX BASE"
						end
						local current = state.get(buf)
						return current and not current.base_changing and current.base_lines[1] == "FRESH INDEX BASE"
					end, "case policy change stranded mutation settlement", 15000)
					if mode == "signs" then
						assert(not signs.current_state(buf).base_waiters, "signs retained settled waiters")
					elseif mode == "pending" then
						assert(not owner:is_active(), "settled pending owner remained active")
					end
				end),
			}
		end
	end
	return cases
end
