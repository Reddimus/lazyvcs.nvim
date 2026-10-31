return function(ctx)
	local h, api = ctx.helpers, vim.api
	local comparisons = {}
	local function wait(fn)
		ctx.wait_for(fn, "patch repository context timed out", 15000)
	end
	local function write(path, text)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(text))
		assert(fd:close())
	end
	local function keys(text)
		api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function collect(path)
		local result = {}
		require("lazyvcs").patch({
			path = path,
			on_done = function(text, err)
				result.text, result.err, result.done = text, err, true
			end,
		})
		wait(function()
			return result.done
		end)
		return result
	end
	local function ui(path)
		local task = require("lazyvcs").patch({ path = path })
		local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
		wait(function()
			return task.done
		end)
		return buf, win
	end
	local function jump(buf, win, line)
		api.nvim_set_current_win(win)
		for row, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if text == line then
				api.nvim_win_set_cursor(win, { row, 0 })
				keys("gf")
				return
			end
		end
		error("missing patch line " .. line)
	end
	local function repository(parent, name, content)
		local f = h.make_git_fixture()
		local root = parent .. "/" .. name
		assert(vim.uv.fs_rename(f.root, root))
		write(root .. "/sample.txt", "one\n" .. content .. "\nthree\n")
		return root
	end
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_context_" .. name,
			function()
				local tabs, buffers = {}, {}
				for _, tab in ipairs(api.nvim_list_tabpages()) do
					tabs[tab] = true
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					buffers[buf] = true
				end
				local win = api.nvim_get_current_win()
				local scan = vim.uv.fs_scandir
				local backend = require("lazyvcs.backends")
				local facade = backend.patch_repository_async
				local config = require("lazyvcs.config")
				local original = vim.deepcopy(config.get())
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				vim.uv.fs_scandir, backend.patch_repository_async = scan, facade
				for _, session in ipairs(comparisons) do
					pcall(require("lazyvcs.compare").close, session, false)
				end
				comparisons = {}
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if not buffers[buf] and api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				for _, tab in ipairs(api.nvim_list_tabpages()) do
					if not tabs[tab] and api.nvim_tabpage_is_valid(tab) then
						api.nvim_set_current_tabpage(tab)
						vim.cmd("tabclose!")
					end
				end
				if api.nvim_win_is_valid(win) then
					api.nvim_set_current_win(win)
				end
				config.setup(original)
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	for _, mode in ipairs({ "default", "tab", "0tab", "vertical" }) do
		case("compare_tab_placement_" .. mode, function()
			local f = h.make_git_fixture()
			local compare = require("lazyvcs.compare")
			local session = assert(compare.open({ path = f.root, base = "HEAD", editable = false }))
			comparisons[#comparisons + 1] = session
			wait(function()
				return session.preview_result and not session.preview_job and not session.job
			end)
			local target = api.nvim_win_get_tabpage(session.rightwin)
			vim.cmd("tabnew")
			api.nvim_set_current_win(session.rightwin)
			local before, number = api.nvim_list_tabpages(), api.nvim_tabpage_get_number(target)
			local buffers = {}
			for _, tab in ipairs(before) do
				for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
					buffers[win] = api.nvim_win_get_buf(win)
				end
			end
			if mode == "default" then
				require("lazyvcs").patch({ path = f.root })
			else
				require("lazyvcs.commands").setup()
				vim.cmd(mode .. " LazyVCS patch " .. vim.fn.fnameescape(f.root))
			end
			local buf, opened = api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
			local actual = api.nvim_tabpage_get_number(opened)
			print(
				vim.json.encode({ mode = mode, before_tabs = #before, current_before = number, current_after = actual })
			)
			if mode == "vertical" then
				assert(opened == target and #api.nvim_list_tabpages() == #before, "vertical modifier created a tab")
			else
				local expected = mode == "0tab" and 1 or number + 1
				assert(actual == expected, "patch tab opened at " .. actual .. " instead of " .. expected)
				local retained = vim.tbl_filter(function(tab)
					return tab ~= opened
				end, api.nvim_list_tabpages())
				assert(vim.deep_equal(retained, before), "patch reordered existing tabs")
			end
			assert(api.nvim_buf_get_name(buf):match("^lazyvcs://patch/"))
			keys("q")
			assert(not api.nvim_buf_is_valid(buf), "q did not wipe the last patch view")
			assert(vim.deep_equal(api.nvim_list_tabpages(), before), "q changed the original tabs")
			for win, original in pairs(buffers) do
				assert(
					api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == original,
					"patch replaced an original buffer"
				)
			end
		end)
	end
	for _, entry in ipairs({ { "newline", "line\nroot" }, { "carriage", "carriage\r" }, { "tab", 'tab\t"é' } }) do
		case("control_root_" .. entry[1], function()
			local name = entry[2]
			if vim.fn.has("win32") == 1 then
				error({ lazyvcs_skip = "control-byte directory names require POSIX" }, 0)
			end
			local parent = h.tempdir()
			local unusual = repository(parent, name, "unusual root change")
			local ordinary = repository(parent, "ordinary", "ordinary root change")
			local clean = repository(parent, "clean", "two")
			local raw, single = collect(parent), collect(unusual)
			assert(raw.text and single.text and not raw.err and not single.err)
			local buf, win = ui(parent)
			jump(buf, win, "+ordinary root change")
			assert(api.nvim_buf_get_name(0) == ordinary .. "/sample.txt", "ordinary root navigation failed")
			jump(buf, win, "+unusual root change")
			assert(api.nvim_buf_get_name(0) == unusual .. "/sample.txt", "control-byte root lost its navigation path")
			local header = "# Repository: " .. vim.json.encode(unusual) .. "\n"
			assert(raw.text:find(header .. single.text, 1, true), "encoded header changed native patch bytes")
			assert(raw.text:find("# Repository: " .. ordinary .. "\n", 1, true), "ordinary header format changed")
			assert(not raw.text:find("# Repository: " .. clean, 1, true), "clean root emitted a header")
			local encoded = assert(raw.text:match('# Repository: ("[^\n]+)\n'))
			assert(vim.json.decode(encoded) == unusual, "saved header is not self-contained")
		end)
	end
	case("incomplete_discovery_refuses_before_collection", function()
		local parent = h.tempdir()
		local blocked = repository(parent, "blocked", "blocked change")
		repository(parent, "ordinary", "ordinary change")
		local scan, backend = vim.uv.fs_scandir, require("lazyvcs.backends")
		local collect_backend, collected = backend.patch_repository_async, 0
		vim.uv.fs_scandir = function(path, done)
			if path == blocked and done then
				vim.schedule(function()
					done("EACCES: injected unreadable repository", nil)
				end)
				return {}
			end
			return scan(path, done)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backend.patch_repository_async = function(...)
			collected = collected + 1
			return collect_backend(...)
		end
		local failed = collect(parent)
		assert(not failed.text and failed.err and failed.err:find("incomplete", 1, true), "partial patch was published")
		assert(
			failed.err:find("blocked", 1, true) and failed.err:find("narrow", 1, true),
			"incomplete error lacks recovery"
		)
		assert(collected == 0, "incomplete discovery started patch collection")
		vim.uv.fs_scandir = scan
		local restored = collect(parent)
		assert(restored.text and not restored.err)
		assert(restored.text:find("+blocked change", 1, true) and restored.text:find("+ordinary change", 1, true))
	end)
	case("scan_depth_remains_an_intended_boundary", function()
		local parent = h.tempdir()
		repository(parent, "ordinary", "ordinary change")
		vim.fn.mkdir(parent .. "/container")
		local deep = repository(parent .. "/container", "deep", "outside depth")
		require("lazyvcs.config").setup({ source_control = { scan_depth = 1 } })
		local scan, visited = vim.uv.fs_scandir, false
		vim.uv.fs_scandir = function(path, done)
			visited = visited or path == deep
			return scan(path, done)
		end
		local result = collect(parent)
		assert(result.text and not result.err and not visited)
		assert(result.text:find("+ordinary change", 1, true) and not result.text:find("+outside depth", 1, true))
	end)
	case("cancel_held_discovery_suppresses_late_failure", function()
		local parent = h.tempdir()
		local blocked = repository(parent, "blocked", "blocked change")
		local scan, held = vim.uv.fs_scandir, nil
		vim.uv.fs_scandir = function(path, done)
			if path == blocked and done then
				held = done
				return {}
			end
			return scan(path, done)
		end
		local completed = false
		local task = require("lazyvcs").patch({
			path = parent,
			on_done = function()
				completed = true
			end,
		})
		wait(function()
			return held
		end)
		task:cancel()
		assert(held)("EACCES: late discovery failure", nil)
		vim.wait(30)
		assert(task.cancelled and not completed)
	end)
	return cases
end
