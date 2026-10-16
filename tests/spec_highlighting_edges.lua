return function(ctx)
	local api = vim.api
	local guard = require("lazyvcs.highlighting")
	local function foreground(win)
		vim.cmd.redraw()
		local pos = vim.fn.win_screenpos(win)
		return api.nvim__inspect_cell(1, pos[1] - 1, pos[2] - 1)[2].foreground
	end
	local function clean_windows()
		for _, win in ipairs(api.nvim_list_wins()) do
			assert(not vim.wo[win].winhighlight:find("LazyVcsSemanticHidden", 1, true), "overlay leaked after release")
		end
	end

	return {
		{
			"test_core_highlighting_remembered_overlay_window",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = ctx.helpers.make_git_fixture()
				local other = f.root .. "/other.txt"
				ctx.helpers.write_file(other, "other\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
				require("lazyvcs.util").set_win_option(win, "winhighlight", "")
				require("lazyvcs").open()
				ctx.wait_for(function()
					local session = require("lazyvcs.state").get(buf)
					return session and session.base_win and api.nvim_win_is_valid(session.base_win)
				end, "live diff did not open", 15000)
				api.nvim_set_current_win(win)
				assert(vim.wo[win].winhighlight:find("LazyVcsSemanticHidden", 1, true), "overlay missing")
				vim.cmd.edit(vim.fn.fnameescape(other))
				require("lazyvcs.actions").close(buf)
				vim.cmd("buffer #")
				assert(api.nvim_get_current_buf() == buf, "alternate buffer did not return")
				assert(
					not vim.wo.winhighlight:find("LazyVcsSemanticHidden", 1, true),
					"remembered overlay survived session close"
				)
			end,
		},

		{
			"test_core_highlighting_remembered_overlay_split",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = ctx.helpers.make_git_fixture()
				local other = f.root .. "/other.txt"
				ctx.helpers.write_file(other, "other\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
				require("lazyvcs.util").set_win_option(win, "winhighlight", "")
				require("lazyvcs").open()
				ctx.wait_for(function()
					local session = require("lazyvcs.state").get(buf)
					return session and session.base_win and api.nvim_win_is_valid(session.base_win)
				end, "live diff did not open", 15000)
				api.nvim_set_current_win(win)
				assert(vim.wo[win].winhighlight:find("LazyVcsSemanticHidden", 1, true), "overlay missing")
				vim.cmd.edit(vim.fn.fnameescape(other))
				require("lazyvcs.actions").close(buf)
				vim.cmd.split()
				local child = api.nvim_get_current_win()
				vim.cmd("buffer #")
				assert(api.nvim_get_current_buf() == buf, "alternate buffer did not return")
				assert(
					not vim.wo.winhighlight:find("LazyVcsSemanticHidden", 1, true),
					"remembered overlay survived session close"
				)
				api.nvim_win_close(child, true)
				api.nvim_set_current_win(win)
				vim.cmd("buffer #")
				assert(not vim.wo.winhighlight:find("LazyVcsSemanticHidden", 1, true), "original window leaked")
			end,
		},

		{
			"test_core_highlighting_reapply_user_mapping_uses_native_namespace",
			function()
				vim.cmd.new()
				local win = api.nvim_get_current_win()
				local util = require("lazyvcs.util")
				util.set_win_option(win, "winhighlight", "Normal:ErrorMsg")
				for _ = 1, 2 do
					guard.apply(win, "syntax")
					assert(vim.wo[win].winhighlight:find("LazyVcsSemanticHidden", 1, true), "native overlay missing")
					local ns = api.nvim_get_hl_ns({ winid = win })
					assert(api.nvim_get_hl(ns, { name = "Normal" }).link == "ErrorMsg", "native mapping disabled")
					assert(
						api.nvim_get_hl(ns, { name = "@lsp.type.variable" }).link == "LazyVcsSemanticHidden",
						"apply selected a pooled namespace"
					)
					guard.release(win)
					assert(vim.wo[win].winhighlight == "Normal:ErrorMsg", "user mapping not restored")
					assert(not api.nvim_get_hl(ns, {})["@lsp.type.variable"], "shrunk mapping retained stale entry")
				end
				api.nvim_win_close(win, true)
			end,
		},
		{
			"test_core_highlighting_noautocmd_float_cleans_on_entry",
			function()
				local win = api.nvim_get_current_win()
				guard.apply(win, "syntax")
				local float = api.nvim_open_win(0, false, {
					relative = "editor",
					row = 1,
					col = 1,
					width = 20,
					height = 3,
					noautocmd = true,
				})
				api.nvim_set_current_win(float)
				assert(
					not vim.wo[float].winhighlight:find("LazyVcsSemanticHidden", 1, true),
					"float overlay survived entry"
				)
				api.nvim_win_close(float, true)
				guard.release(win)
			end,
		},

		{
			"test_core_highlighting_noautocmd_float_cleans_on_other_window_entry",
			function()
				local win = api.nvim_get_current_win()
				vim.cmd.split()
				local other = api.nvim_get_current_win()
				api.nvim_set_current_win(win)
				require("lazyvcs.util").set_win_option(win, "winhighlight", "")
				guard.apply(win, "syntax")
				local float = api.nvim_open_win(0, false, {
					relative = "editor",
					row = 1,
					col = 1,
					width = 20,
					height = 3,
					noautocmd = true,
				})
				assert(api.nvim_get_current_win() == win, "float was entered")
				assert(vim.wo[float].winhighlight:find("LazyVcsSemanticHidden", 1, true), "float did not copy overlay")
				api.nvim_set_current_win(other)
				assert(
					not vim.wo[float].winhighlight:find("LazyVcsSemanticHidden", 1, true),
					"unentered float overlay survived entry into another window"
				)
				api.nvim_win_close(float, true)
				guard.release(win)
				api.nvim_win_close(other, true)
			end,
		},

		{
			"test_core_highlighting_repeated_tokens_do_not_rebuild_native_overlay",
			function()
				local util = require("lazyvcs.util")
				vim.cmd.new()
				local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				vim.bo[buf].filetype = "lua"
				util.set_win_option(win, "winhighlight", "")
				-- Seed the qualified new type so its first event adds exactly one mapping.
				for _, name in ipairs({ "lazyvcsBurstKnown", "lazyvcsBurstKnown.lua", "lazyvcsBurstNew.lua" }) do
					api.nvim_set_hl(0, "@lsp.type." .. name, {})
				end
				guard.apply(win, "syntax")
				local before = vim.wo[win].winhighlight
				local reads, writes = 0, 0
				local get_option, set_option = util.get_win_option, util.set_win_option
				---@diagnostic disable-next-line: duplicate-set-field
				util.get_win_option = function(target, name)
					if target == win and name == "winhighlight" then
						reads = reads + 1
					end
					return get_option(target, name)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.set_win_option = function(target, name, value)
					if target == win and name == "winhighlight" then
						writes = writes + 1
					end
					return set_option(target, name, value)
				end
				local ok, err = pcall(function()
					assert(
						before:find("@lsp.type.lazyvcsBurstKnown:LazyVcsSemanticHidden", 1, true),
						"native overlay missing"
					)
					local function token(kind)
						api.nvim_exec_autocmds("LspTokenUpdate", { buffer = buf, data = { token = { type = kind } } })
					end
					for _ = 1, 2000 do
						token("lazyvcsBurstKnown")
					end
					assert(writes <= 1, "repeated tokens wrote winhighlight " .. writes .. " times")
					-- Identical writes were already avoided; reads catch the expensive rebuild itself.
					assert(reads <= 1, "repeated tokens rebuilt native overlay " .. reads .. " times")
					assert(vim.wo[win].winhighlight == before, "repeated tokens changed native mappings")
					reads, writes = 0, 0
					token("lazyvcsBurstNew")
					local after = vim.wo[win].winhighlight
					local added = "@lsp.type.lazyvcsBurstNew:LazyVcsSemanticHidden"
					local _, entries_before = before:gsub(":LazyVcsSemanticHidden", "")
					local _, entries_after = after:gsub(":LazyVcsSemanticHidden", "")
					assert(entries_after == entries_before + 1, "new token did not add exactly one mapping")
					assert(after:find(added, 1, true), "new token mapping missing")
					assert(writes == 1, "new token did not write winhighlight exactly once")
					token("lazyvcsBurstNew")
					assert(reads == 1 and writes == 1, "duplicate new token rebuilt native overlay")
				end)
				util.get_win_option, util.set_win_option = get_option, set_option
				guard.release(win)
				api.nvim_win_close(win, true)
				assert(ok, err)
			end,
		},
		{
			"test_core_highlighting_reused_pool_resolves_source_parent_links",
			function()
				vim.o.termguicolors = true
				vim.cmd.enew()
				local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.foldcolumn = false, false, "no", "0"
				api.nvim_buf_set_lines(buf, 0, -1, false, { "linked" })
				api.nvim_set_hl(0, "LazyVCSEdgeParent", { fg = "#ee1234" })
				api.nvim_set_hl(0, "LazyVCSEdgeChild", { link = "LazyVCSEdgeParent" })
				api.nvim_set_hl(0, "LazyVCSEdgeChain", { link = "LazyVCSEdgeChild" })
				local old = api.nvim_create_namespace("lazyvcs-edge-old")
				local source = api.nvim_create_namespace("lazyvcs-edge-source")
				api.nvim_set_hl(old, "LazyVCSEdgeChild", { fg = "#1234ee" })
				api.nvim_set_hl(old, "LazyVCSEdgeChain", { fg = "#1234ee" })
				api.nvim_set_hl(source, "LazyVCSEdgeParent", { fg = "#12ee34" })
				local marks = api.nvim_create_namespace("lazyvcs-edge-render")
				api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 6, hl_group = "LazyVCSEdgeChild" })
				api.nvim_win_set_hl_ns(win, source)
				guard.apply(win, "syntax")
				local pooled = api.nvim_get_hl_ns({ winid = win })
				local expected = foreground(win)
				assert(expected == 0x12ee34, "fresh slot changed linked colors")
				guard.release(win)
				api.nvim_win_set_hl_ns(win, old)
				guard.apply(win, "syntax")
				guard.release(win)
				api.nvim_win_set_hl_ns(win, source)
				api.nvim_set_hl(source, "LazyVCSEdgeParent", { fg = "#12ee34" })
				guard.apply(win, "syntax")
				local ok, err = pcall(function()
					assert(api.nvim_get_hl_ns({ winid = win }) == pooled, "pool slot was not reused")
					assert(foreground(win) == expected, "reused slot resolved child through global parent")
					api.nvim_set_hl(0, "LazyVCSEdgeSelf", { link = "LazyVCSEdgeParent" })
					api.nvim_set_hl(source, "LazyVCSEdgeSelf", { link = "LazyVCSEdgeSelf" })
					api.nvim_set_hl(source, "LazyVCSEdgeCycleA", { link = "LazyVCSEdgeCycleB" })
					api.nvim_set_hl(source, "LazyVCSEdgeCycleB", { link = "LazyVCSEdgeCycleA" })
					api.nvim_set_hl(source, "LazyVCSEdgeMissing", { link = "LazyVCSEdgeAbsent" })
					guard.refresh(win)
					assert(
						api.nvim_get_hl(pooled, { name = "LazyVCSEdgeSelf" }).fg == 0x12ee34,
						"self-link did not fall back through the source parent"
					)
					assert(
						api.nvim_get_hl(pooled, { name = "LazyVCSEdgeChain" }).fg == 0x12ee34,
						"chained link lost its source parent"
					)
					for _, name in ipairs({ "LazyVCSEdgeMissing", "LazyVCSEdgeCycleA", "LazyVCSEdgeCycleB" }) do
						assert(
							not api.nvim_get_hl(pooled, { name = name }).fg,
							"missing or cyclic link acquired colors"
						)
					end
				end)
				guard.release(win)
				assert(api.nvim_get_hl_ns({ winid = win }) == source, "explicit namespace not restored")
				assert(ok, err)
				local anonymous = api.nvim_create_namespace("")
				api.nvim_set_hl(anonymous, "LazyVCSEdgeChild", { fg = "#1234ee" })
				api.nvim_win_set_hl_ns(win, anonymous)
				api.nvim_set_hl(anonymous, "@lsp.type.lazyvcsAnonymous", { fg = "#ee1234", italic = true })
				local token = api.nvim_buf_set_extmark(buf, marks, 0, 0, {
					end_col = 6,
					hl_group = "@lsp.type.lazyvcsAnonymous",
					priority = 200,
				})
				guard.apply(win, "syntax")
				assert(foreground(win) == 0x1234ee, "anonymous namespace did not suppress semantic color")
				local pos = vim.fn.win_screenpos(win)
				assert(
					not api.nvim__inspect_cell(1, pos[1] - 1, pos[2] - 1)[2].italic,
					"anonymous namespace did not suppress semantic italic"
				)
				api.nvim_buf_del_extmark(buf, marks, token)
				assert(foreground(win) == 0x1234ee, "anonymous custom namespace lost its colors")
				guard.release(win)
				assert(api.nvim_get_hl_ns({ winid = win }) == anonymous, "anonymous namespace not restored")
				api.nvim_win_set_hl_ns(win, -1)
			end,
		},
		{
			"test_core_highlighting_late_window_mappings_survive_release",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = ctx.helpers.make_git_fixture()
				for _, initial in ipairs({ "", "Normal:ErrorMsg" }) do
					local previous = api.nvim_get_current_win()
					vim.cmd("new")
					api.nvim_win_close(previous, true)
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local win = api.nvim_get_current_win()
					require("lazyvcs.util").set_win_option(win, "winhighlight", initial)
					local global = api.nvim_get_option_value("winhighlight", { win = win, scope = "global" })
					require("lazyvcs").open()
					ctx.wait_for(function()
						local session = require("lazyvcs.state").get(api.nvim_win_get_buf(win))
						return session and session.base_win and api.nvim_win_is_valid(session.base_win)
					end, "live diff did not open", 15000)
					api.nvim_set_current_win(win)
					api.nvim_set_hl(0, "LazyVCSEdgeText", { fg = "#ee1234" })
					api.nvim_set_hl(0, "LazyVCSEdgeMapped", { fg = "#12ee34" })
					api.nvim_buf_set_extmark(
						api.nvim_win_get_buf(win),
						api.nvim_create_namespace("lazyvcs-edge-text"),
						0,
						0,
						{ end_col = 3, hl_group = "LazyVCSEdgeText", priority = 200 }
					)
					local user =
						"Normal:ErrorMsg,NormalNC:ErrorMsg,@lsp.type.variable:Comment,LazyVCSEdgeText:LazyVCSEdgeMapped"
					require("lazyvcs.util").set_win_option(win, "winhighlight", user)
					api.nvim_exec_autocmds("OptionSet", { pattern = "winhighlight" })
					vim.wait(30)
					api.nvim_exec_autocmds("ColorScheme", {})
					vim.wait(30)
					for _, command in ipairs({ "split", "vsplit" }) do
						api.nvim_set_current_win(win)
						vim.cmd(command)
						local child = api.nvim_get_current_win()
						assert(vim.wo[child].winhighlight == user, command .. " inherited semantic overlay")
						api.nvim_win_close(child, true)
					end
					api.nvim_set_current_win(win)
					local float =
						api.nvim_open_win(0, false, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
					assert(vim.wo[float].winhighlight == user, "float inherited semantic overlay")
					api.nvim_win_close(float, true)
					require("lazyvcs").close()
					guard.release(win)
					assert(vim.wo[win].winhighlight == user, "late user mappings changed on release")
					assert(
						api.nvim_get_option_value("winhighlight", { win = win, scope = "global" }) == global,
						"global mapping default changed"
					)
					local mapped = api.nvim_get_hl(api.nvim_get_hl_ns({ winid = win }), { name = "Normal" })
					assert(mapped.link == "ErrorMsg", "late mapping colors disabled after release")
					assert(foreground(win) == 0x12ee34, "released window did not render its user mapping")
					guard.apply(win, "syntax")
					local external = api.nvim_create_namespace("lazyvcs-edge-takeover")
					api.nvim_win_set_hl_ns(win, external)
					guard.release(win)
					assert(api.nvim_get_hl_ns({ winid = win }) == external, "external namespace overwritten")
					clean_windows()
					require("lazyvcs.util").set_win_option(win, "winhighlight", "")
				end
			end,
		},
	}
end
