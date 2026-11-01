return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "active Patch ownership did not settle", 15000)
	end
	local function case(name, fn, initialize)
		cases[#cases + 1] = {
			"test_patch_active_ownership_" .. name,
			function()
				local backend = require("lazyvcs.backends")
				local original, defer, notify = backend.patch_repository_async, vim.defer_fn, vim.notify
				local original_set_lines = api.nvim_buf_set_lines
				local held, group, errors, handles, callbacks = nil, nil, {}, {}, {}
				local owned_buffers = {}
				local holding = true
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					end
				end
				---@diagnostic disable-next-line: duplicate-set-field
				backend.patch_repository_async = function(repo, path, opts, done)
					return original(repo, path, opts, function(...)
						if holding then
							local args = { ... }
							held = function()
								done(unpack(args))
							end
						else
							done(...)
						end
					end)
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local editor = api.nvim_get_current_buf()
					owned_buffers[editor] = true
					api.nvim_buf_set_lines(editor, 0, -1, false, { "original unsaved editor" })
					if initialize then
						group = api.nvim_create_augroup("LazyVCSPatchActiveOwnership", { clear = true })
						initialize(f, group)
					end
					local function open()
						local task = require("lazyvcs").patch({ path = f.root })
						handles[#handles + 1] = task
						return task
					end
					local request = open()
					local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
					owned_buffers[buf] = true
					if not initialize then
						wait(function()
							return held ~= nil
						end)
					end
					fn({
						fixture = f,
						buf = buf,
						win = win,
						request = request,
						open = open,
						group = function()
							group = api.nvim_create_augroup("LazyVCSPatchActiveOwnership", { clear = true })
							return group
						end,
						index = function()
							vim.defer_fn = function(callback, ms)
								if ms == 1 then
									callbacks[#callbacks + 1] = callback
									return nil
								end
								return defer(callback, ms)
							end
							assert(held)()
							wait(function()
								return #callbacks > 0
							end)
						end,
						release = function()
							holding = false
							vim.defer_fn = defer
							if #callbacks > 0 then
								for _, callback in ipairs(callbacks) do
									callback()
								end
							else
								assert(held)()
							end
							wait(function()
								return not request:is_active()
							end)
						end,
					})
					assert(api.nvim_buf_is_valid(editor) and vim.bo[editor].modified)
					assert(text(editor) == "original unsaved editor")
				end, debug.traceback)
				if group then
					api.nvim_del_augroup_by_id(group)
				end
				backend.patch_repository_async, vim.defer_fn = original, defer
				api.nvim_buf_set_lines = original_set_lines
				for _, task in ipairs(handles) do
					task:cancel()
				end
				local cleanup_errors = {}
				for buf in pairs(owned_buffers) do
					if api.nvim_buf_is_valid(buf) then
						local clean, why = pcall(api.nvim_buf_delete, buf, { force = true })
						if not clean then
							cleanup_errors[#cleanup_errors + 1] = tostring(why)
						end
					end
				end
				vim.notify = notify
				assert(ok, err)
				assert(#cleanup_errors == 0, table.concat(cleanup_errors, "; "))
				if name == "failing_line_setter" then
					assert(#errors == 1 and errors[1]:find("injected line setter failure", 1, true))
				else
					assert(#errors == 0, table.concat(errors, "; "))
				end
			end,
		}
	end
	for _, phase in ipairs({ "pending", "indexing" }) do
		for _, mode in ipairs({ "edit", "rename", "profile" }) do
			case(phase .. "_" .. mode, function(f)
				if phase == "indexing" then
					f.index()
				end
				local name = api.nvim_buf_get_name(f.buf)
				if mode == "profile" then
					vim.bo[f.buf].modifiable = true
					vim.bo[f.buf].fileformat = "dos"
					vim.bo[f.buf].modifiable = false
				elseif mode == "rename" then
					name = f.fixture.root .. "/user-retained.txt"
					api.nvim_buf_set_name(f.buf, name)
				else
					vim.bo[f.buf].buftype = ""
					vim.bo[f.buf].modifiable = true
					api.nvim_buf_set_lines(f.buf, 0, -1, false, { "ACTIVE USER BYTES", "second line" })
				end
				local body = text(f.buf)
				f.release()
				assert(text(f.buf) == body, "active completion overwrote user-owned buffer bytes")
				assert(api.nvim_buf_get_name(f.buf) == name)
				assert(f.request.cancelled, "retired active request was not cancelled")
				if mode == "profile" then
					assert(vim.bo[f.buf].fileformat == "dos", "active completion reset the user profile")
				elseif mode == "edit" then
					assert(vim.bo[f.buf].modified and vim.bo[f.buf].modifiable)
				else
					assert(not vim.bo[f.buf].modifiable and not vim.bo[f.buf].modified)
				end
			end)
		end
	end
	for _, mode in ipairs({ "edit", "rename", "profile" }) do
		case("setter_" .. mode, function(f)
			local fired, body, name = 0, nil, api.nvim_buf_get_name(f.buf)
			api.nvim_create_autocmd("OptionSet", {
				group = f.group(),
				pattern = "modifiable",
				nested = true,
				callback = function()
					if fired == 0 and api.nvim_get_current_buf() == f.buf and vim.bo[f.buf].modifiable then
						fired = fired + 1
						if mode == "profile" then
							vim.bo[f.buf].fileformat = "dos"
						else
							vim.bo[f.buf].buftype = ""
							if mode == "rename" then
								name = f.fixture.root .. "/setter-user.txt"
								api.nvim_buf_set_name(f.buf, name)
							end
							api.nvim_buf_set_lines(f.buf, 0, -1, false, { "SETTER USER BYTES" })
						end
						body = text(f.buf)
					end
				end,
			})
			f.release()
			assert(fired == 1, "native OptionSet callback did not run")
			assert(text(f.buf) == body and api.nvim_buf_get_name(f.buf) == name)
			assert(vim.bo[f.buf].modifiable)
			if mode == "profile" then
				assert(vim.bo[f.buf].fileformat == "dos" and not vim.bo[f.buf].modified)
			else
				assert(vim.bo[f.buf].modified)
			end
			assert(f.request.cancelled)
		end)
	end
	case("lines_callback_rename", function(f)
		local fired, name = 0, f.fixture.root .. "/lines-user.txt"
		api.nvim_buf_attach(f.buf, false, {
			on_lines = function()
				if fired == 0 then
					fired = fired + 1
					api.nvim_buf_set_name(f.buf, name)
					vim.bo[f.buf].buftype = ""
					vim.bo[f.buf].modified = true
				end
			end,
		})
		f.release()
		assert(fired == 1 and api.nvim_buf_get_name(f.buf) == name)
		assert(vim.bo[f.buf].modified, "render cleared modified after an on_lines ownership change")
		assert(f.request.cancelled)
	end)
	case("completed_modified_R", function(f)
		f.release()
		assert(not f.request.cancelled)
		vim.bo[f.buf].buftype = ""
		vim.bo[f.buf].modifiable = true
		api.nvim_buf_set_lines(f.buf, 0, -1, false, { "COMPLETED USER BYTES" })
		api.nvim_feedkeys("R", "xt", false)
		vim.wait(50, function()
			return false
		end, 5)
		assert(text(f.buf) == "COMPLETED USER BYTES" and vim.bo[f.buf].modified)
	end)
	case("unchanged_and_reload", function(f)
		f.release()
		assert(not f.request.cancelled and text(f.buf):find("+changed", 1, true))
		local body = text(f.buf)
		local next_request = f.open()
		wait(function()
			return next_request.done
		end)
		assert(not next_request.cancelled and api.nvim_get_current_buf() == f.buf and text(f.buf) == body)
	end)
	case("retirement_keeps_foreign_listener", function(f)
		local events = 0
		api.nvim_buf_attach(f.buf, false, {
			on_lines = function()
				events = events + 1
			end,
		})
		vim.bo[f.buf].buftype, vim.bo[f.buf].modifiable = "", true
		api.nvim_buf_set_lines(f.buf, 0, -1, false, { "FIRST USER BODY" })
		f.release()
		api.nvim_buf_set_lines(f.buf, 0, -1, false, { "SECOND USER BODY" })
		assert(events == 2 and text(f.buf) == "SECOND USER BODY" and vim.bo[f.buf].modified)
	end)
	case("failing_line_setter", function(f)
		local original, fired = api.nvim_buf_set_lines, 0
		---@diagnostic disable-next-line: duplicate-set-field
		api.nvim_buf_set_lines = function(buf, first, last, strict, material)
			if buf == f.buf and fired == 0 then
				fired = fired + 1
				vim.bo[buf].buftype = ""
				vim.bo[buf].fileformat = "dos"
				api.nvim_buf_set_name(buf, f.fixture.root .. "/failure-user.txt")
				original(buf, 0, -1, false, { "FAILED SETTER USER BYTES" })
				error("injected line setter failure")
			end
			return original(buf, first, last, strict, material)
		end
		f.release()
		assert(fired == 1 and f.request.cancelled)
		assert(text(f.buf) == "FAILED SETTER USER BYTES" and vim.bo[f.buf].modified)
		assert(vim.bo[f.buf].fileformat == "dos" and vim.bo[f.buf].modifiable)
		assert(api.nvim_buf_get_name(f.buf) == f.fixture.root .. "/failure-user.txt")
	end)
	for _, label in ipairs({ "FileType", "FileType_rename", "OptionSet" }) do
		local event = label == "OptionSet" and "OptionSet" or "FileType"
		case("constructor_" .. label, function(f)
			assert(f.fixture.claim_fired == 1, "native constructor hook did not run")
			assert(f.request.cancelled and text(f.buf) == "CONSTRUCTOR USER BYTES")
			assert(vim.bo[f.buf].modified and vim.bo[f.buf].modifiable and vim.bo[f.buf].buftype == "")
			if label == "FileType_rename" then
				assert(api.nvim_buf_get_name(f.buf) == f.fixture.root .. "/constructor-user.txt")
			end
		end, function(f, group)
			f.claim_fired = 0
			api.nvim_create_autocmd(event, {
				group = group,
				pattern = event == "FileType" and "diff" or "buftype",
				nested = true,
				callback = function()
					local buf = api.nvim_get_current_buf()
					local name = api.nvim_buf_get_name(buf)
					if
						f.claim_fired == 0
						and (
							name:match("^lazyvcs://patch/")
							or (event == "OptionSet" and name == "" and vim.bo[buf].buftype == "nofile")
						)
					then
						f.claim_fired = f.claim_fired + 1
						vim.bo[buf].buftype = ""
						vim.bo[buf].modifiable = true
						if label == "FileType_rename" then
							api.nvim_buf_set_name(buf, f.root .. "/constructor-user.txt")
						end
						api.nvim_buf_set_lines(buf, 0, -1, false, { "CONSTRUCTOR USER BYTES" })
					end
				end,
			})
		end)
	end
	return cases
end
