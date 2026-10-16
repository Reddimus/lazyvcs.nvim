return function(ctx)
	local h, api = ctx.helpers, vim.api
	local git, util = require("lazyvcs.backends.git"), require("lazyvcs.util")
	local function await(start)
		local done, value, failure
		start(function(result, err)
			value, failure, done = result, err, true
		end)
		ctx.wait_for(function()
			return done
		end, "base validation did not finish", 15000)
		return value, failure
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, debounce_ms = 0, signs = { enabled = false, debounce_ms = 0 } })
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/.gitattributes", "sample.txt ident")
		h.write_file(f.file, "$Id$\nbeta")
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "ident base" }, f.root)
		assert(os.remove(f.file))
		h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
		return f
	end
	local function loads(f)
		local results = { assert(git.load(f.file)), assert(git.load_base(f.file)) }
		for _, method in ipairs({ "load_async", "load_base_async" }) do
			results[#results + 1] = assert(await(function(done)
				git[method](f.file, done)
			end))
		end
		for _, payload in ipairs(results) do
			assert(payload.base_bytes == results[1].base_bytes)
			assert(vim.deep_equal(payload.base_identity, results[1].base_identity), "loader identities disagree")
		end
		return results[1]
	end
	local function confirmation(live, change_base)
		local f = fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = api.nvim_get_current_buf()
		local original = api.nvim_buf_get_lines(buf, 0, -1, false)
		api.nvim_buf_set_lines(buf, 0, 1, false, { "EDIT" })
		local target = require(live and "lazyvcs.actions" or "lazyvcs.signs")
		if live then
			local owner = target.open({ silent = true })
			ctx.wait_for(function()
				return owner.done
			end, "ident live diff did not open", 15000)
		else
			require("lazyvcs.config").get().signs.enabled = true
			assert(await(function(done)
				target.refresh(buf, true, done)
			end))
		end
		api.nvim_win_set_cursor(0, { 1, 0 })
		local notify, messages = util.notify, {}
		---@diagnostic disable-next-line: duplicate-set-field
		util.notify = function(message)
			messages[#messages + 1] = message
		end
		local ok, err = xpcall(function()
			target.revert_hunk()
			ctx.wait_for(function()
				return vim.bo.buftype == "nofile"
			end, "ident hunk confirmation did not open", 15000)
			if change_base ~= false then
				h.write_file(f.root .. "/.gitattributes", "sample.txt -ident")
			end
			vim.fn.maparg("1", "n", false, true).callback()
			ctx.wait_for(function()
				return #messages > 0 or api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "EDIT"
			end, "ident revert did not settle", 15000)
			if change_base == false then
				assert(
					vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), original),
					"unchanged base was rejected"
				)
				return
			end
			assert(
				api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "EDIT",
				"changed ident base replaced the edited buffer"
			)
			assert(table.concat(messages, " "):find("base changed", 1, true), "changed effective base was not reported")
		end, debug.traceback)
		util.notify = notify
		assert(ok, err)
	end
	return {
		{
			"test_live_diff_ident_unchanged_base_revert_confirmation",
			function()
				confirmation(true, false)
			end,
		},
		{
			"test_sign_ident_unchanged_base_revert_confirmation",
			function()
				confirmation(false, false)
			end,
		},
		{
			"test_core_git_ident_effective_base_identity",
			function()
				local f = fixture()
				local before = loads(f)
				assert(before.base_bytes:match("^%$Id: %x+ %$"), "fixture ident was not expanded")
				h.write_file(f.root .. "/.gitattributes", "sample.txt -ident")
				local after = loads(f)
				assert(after.base_bytes == "$Id$\nbeta\n")
				assert(
					not vim.deep_equal(before.base_identity, after.base_identity),
					"effective bytes changed without changing base identity"
				)
				local valid, err = await(function(done)
					git.validate_editable_base_async(f.file, before.base_identity, done)
				end)
				assert(valid == false and err:find("base changed", 1, true))
				local function digest(payload)
					assert(
						payload.base_identity.content == vim.fn.sha256(vim.base64.encode(payload.base_bytes)),
						"missing binary-safe content digest"
					)
					assert(payload.base_identity.base_encoding == payload.base_encoding)
				end
				digest(after)
				local file = assert(io.open(f.file, "wb"))
				file:write("a\0b\n")
				file:close()
				h.exec({ "git", "add", "sample.txt" }, f.root)
				local binary = loads(f)
				assert(binary.base_bytes == "a\0b\n")
				digest(binary)
				local oid = binary.base_identity.oid
				local function conflict(stages)
					local records = "0 " .. string.rep("0", #oid) .. "\tsample.txt\n"
					for _, stage in ipairs(stages) do
						records = records .. "100644 " .. oid .. " " .. stage .. "\tsample.txt\n"
					end
					assert(
						vim.system({ "git", "update-index", "--index-info" }, { cwd = f.root, stdin = records })
							:wait().code == 0
					)
					return assert(await(function(done)
						git.load_diff_target_async({ root = f.root, relpath = "sample.txt", section = "merge" }, done)
					end))
				end
				local merged = conflict({ 1, 2, 3 })
				digest({
					base_identity = merged.base_identity,
					base_bytes = merged.left.bytes,
					base_encoding = merged.left.base_encoding,
				})
				local empty = conflict({ 1, 3 })
				assert(empty.left.bytes == "")
				digest({ base_identity = empty.base_identity, base_bytes = "" })
				local path = f.root .. "/untracked"
				for _, method in ipairs({ "load", "load_base" }) do
					digest(assert(git[method](path)))
				end
				for _, method in ipairs({ "load_async", "load_base_async" }) do
					digest(assert(await(function(done)
						git[method](path, done)
					end)))
				end
			end,
		},
		{
			"test_live_diff_ident_change_during_revert_confirmation",
			function()
				confirmation(true)
			end,
		},
		{
			"test_sign_ident_change_during_revert_confirmation",
			function()
				confirmation(false)
			end,
		},
	}
end
