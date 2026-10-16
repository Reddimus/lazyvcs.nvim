return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, provider = require("lazyvcs.compare"), require("lazyvcs.backends.compare_svn")
	local function await(start)
		local done, value, failure = false, nil, nil
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "SVN metadata did not load", 15000)
		return value, failure
	end
	local function contains(lines, text)
		return lines and table.concat(lines, "\n"):find(text, 1, true)
	end
	local function set_property(f, path, name, value)
		local propfile = h.tempdir() .. "/property"
		local file = assert(io.open(propfile, "wb"))
		file:write(value)
		file:close()
		h.exec({ "svn", "propset", name, "--file", propfile, "--", path .. "@" }, f.root)
	end
	local function directory_preview(f, path, status, snapshot)
		return await(function(done)
			provider.preview(
				snapshot or { root = f.root, url = h.file_url(f.repo), revision = "HEAD" },
				{ relpath = path, kind = "dir", status = status or "M", property_only = true },
				done
			)
		end)
	end
	return {
		{
			"test_svn_compare_directory_property_whitespace_linear",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "padding" }, f.root)
				set_property(f, "padding", "custom:padding", string.rep(" ", 300000))
				local started = vim.uv.hrtime()
				local result, err = directory_preview(f, "padding", "A")
				assert(result, err)
				assert(contains(result.right, "+" .. string.rep(" ", 300000)), "whitespace value was trimmed")
				assert((vim.uv.hrtime() - started) / 1e9 < 5, "whitespace property parsing took over five seconds")
			end,
		},
		{
			"test_svn_compare_directory_property_literal_hex_text",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "mkdir", "text" }, f.root)
				set_property(f, "text", "custom:text", "see <42> café\n")
				set_property(f, "text", "custom:invalid", "invalid \255\n")
				local result, err = directory_preview(f, "text", "A")
				assert(result, err)
				assert(contains(result.right, "+see <42> café"), "literal hex text was treated as binary")
				assert(contains(result.right, "[base64] " .. vim.base64.encode("invalid \255\n")))
			end,
		},
		{
			"test_svn_compare_root_and_canonical_url_properties",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				local paths = { ".", "dir &@'()", "dir %23#", "dir ;café", "dir !$+,=" }
				-- Windows rejects * : ? in file names.
				if vim.fn.has("win32") ~= 1 then
					paths[#paths + 1] = "dir *!+,=:?"
				end
				for _, path in ipairs(paths) do
					if path ~= "." then
						h.exec({ "svn", "mkdir", "--", path .. "@" }, f.root)
					end
					set_property(f, path, "custom:value", "BEFORE\n")
				end
				h.exec({ "svn", "commit", "-m", "property targets" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				local url = h.exec({ "svn", "info", "--show-item", "url", "." }, f.root):gsub("%s+$", "")
				local revision = h.exec({ "svn", "info", "--show-item", "revision", "." }, f.root):match("%d+")
				-- A trailing slash is accepted as input but is absent in svn info's URL.
				local base = url .. "/@" .. assert(revision)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, base, done)
				end))
				assert(snapshot.url == url and snapshot.url ~= url .. "/", "snapshot retained the input URL")
				assert(snapshot.base == base and snapshot.revision == revision)
				for _, path in ipairs(paths) do
					set_property(f, path, "custom:value", "AFTER\n")
					local result, err = directory_preview(f, path, nil, snapshot)
					assert(result, path .. ": " .. tostring(err))
					assert(contains(result.right, "-BEFORE") and contains(result.right, "+AFTER"))
				end
				assert(require("lazyvcs.backends.svn_url").append_path(url, ".") == url)
				local s = assert(compare.open({ path = f.root, base = base }))
				local ok, err = xpcall(function()
					ctx.wait_for(function()
						return s.preview_result
					end, "root property rows did not load", 15000)
					api.nvim_set_current_win(s.sidewin)
					api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path["."]), 0 })
					s.actions.preview()
					ctx.wait_for(function()
						return s.preview_result and s.shown_item.relpath == "."
					end, "root property preview did not load", 15000)
					assert(contains(api.nvim_buf_get_lines(s.right, 0, -1, false), "+AFTER"))
				end, debug.traceback)
				compare.close(s)
				assert(ok, err)
			end,
		},
		{
			"test_svn_compare_cr_property_and_xml_attributes",
			function()
				local f = h.make_svn_fixture()
				local path = "dir & 'entities'"
				h.exec({ "svn", "mkdir", path }, f.root)
				set_property(f, path, "custom:cr", "first\rsecond\r\nthird\n")
				local raw = h.exec({ "svn", "proplist", "--xml", "--verbose", path }, f.root)
				assert(raw:find("&#13;", 1, true), "SVN did not emit numeric CR references")
				local result, err = directory_preview(f, path, "A")
				assert(result, err)
				assert(contains(result.right, "first\rsecond"), "numeric CR entity was not decoded")
				local xml = require("lazyvcs.backends.xml")
				local attrs = xml.attributes([[path="dir &amp; &apos;entities&apos;" name="custom:&#x63;&#114;"]])
				assert(attrs.path == path and attrs.name == "custom:cr", "attribute entities were not decoded")
			end,
		},
		{
			"test_svn_compare_directory_properties_are_pinned_and_shallow",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "selected", "selected/child", "deleted" }, f.root)
				local propfile = h.tempdir() .. "/property"
				local function set(path, name, value)
					local file = assert(io.open(propfile, "wb"))
					file:write(value)
					file:close()
					h.exec({ "svn", "propset", name, "--file", propfile, path }, f.root)
				end
				set("selected", "custom:modified", "PINNED VALUE\n")
				set("selected", "custom:deleted", "DELETE VALUE\n")
				set("selected", "custom:empty", "NONEMPTY\n")
				set("deleted", "custom:removed", "REMOVED DIRECTORY\n")
				h.exec({ "svn", "commit", "-m", "pinned properties" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				set("selected", "custom:modified", "WORKING PROBE\n")
				local initial = assert(await(function(done)
					provider.preview(
						{ root = f.root, url = h.file_url(f.repo), revision = "2" },
						{ relpath = "selected", kind = "dir", status = "M", property_only = true },
						done
					)
				end))
				assert(contains(initial.right, "WORKING PROBE"), "directory property preview was empty")
				set("selected", "custom:modified", "WC BASE ONLY\n")
				h.exec({ "svn", "commit", "-m", "advance BASE" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				set("selected", "custom:modified", "WORKING VALUE\n")
				set("selected", "custom:empty", "")
				set("selected", "custom:escaped", "<&> \"quoted\" 'value'\n")
				set("selected", "custom:binary", "a\0b\1")
				set("selected/child", "custom:child", "CHILD MUST NOT APPEAR\n")
				h.exec({ "svn", "propdel", "custom:deleted", "selected" }, f.root)
				h.exec({ "svn", "mkdir", "added" }, f.root)
				set("added", "custom:new", "ADDED DIRECTORY\n")
				h.exec({ "svn", "delete", "deleted" }, f.root)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@2", done)
				end))
				local items = assert(await(function(done)
					provider.list(snapshot, false, done)
				end))
				local by_path = {}
				for _, item in ipairs(items) do
					by_path[item.relpath] = item
				end
				local function preview(item)
					return await(function(done)
						provider.preview(snapshot, item or by_path.selected, done)
					end)
				end
				local result, err = preview()
				assert(result, err)
				assert(
					contains(result.right, "-PINNED VALUE") and contains(result.right, "+WORKING VALUE"),
					"directory patch did not compare pinned and working properties"
				)
				assert(
					not contains(result.right, "WC BASE ONLY") and not contains(result.right, "CHILD MUST NOT APPEAR"),
					"directory patch used BASE or descendants"
				)
				assert(
					contains(result.right, "Deleted: custom:deleted")
						and contains(result.right, "Modified: custom:empty")
				)
				assert(
					contains(result.right, "<&> \"quoted\" 'value'")
						and contains(result.right, "[base64] " .. vim.base64.encode("a\0b\1"))
				)
				assert(vim.deep_equal(result.right, result.properties), "directory metadata differs from text")
				assert(contains(assert(preview(assert(by_path.added))).right, "ADDED DIRECTORY"))
				assert(contains(assert(preview(assert(by_path.deleted))).right, "REMOVED DIRECTORY"))
				for _, name in ipairs({ "dir &@%#" }) do
					local path = f.root .. "/" .. name
					vim.fn.mkdir(path, "p")
					h.exec({ "svn", "add", path .. "@" }, f.root)
					set(path .. "@", "custom:literal", "LITERAL DIRECTORY")
					assert(
						contains(
							assert(preview({ relpath = name, kind = "dir", status = "A", property_only = true })).right,
							"LITERAL DIRECTORY"
						)
					)
				end
				local common, util = require("lazyvcs.backends.comparison"), require("lazyvcs.util")
				local command, start = common.command, util.system_start
				local s
				local ok, failure = xpcall(function()
					s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@2" }))
					ctx.wait_for(function()
						return s.preview_result
					end, "directory comparison did not load", 15000)
					api.nvim_set_current_win(s.sidewin)
					api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path.selected), 0 })
					s.actions.preview()
					ctx.wait_for(function()
						return s.preview_result and s.shown_item.relpath == "selected"
					end, "directory preview did not load", 15000)
					assert(contains(api.nvim_buf_get_lines(s.right, 0, -1, false), "PINNED VALUE"))
					s.actions.metadata()
					assert(contains(api.nvim_buf_get_lines(s.left, 0, -1, false), "WORKING VALUE"))
					compare.close(s)
					s = nil
					local held, delivered
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						return start(args, opts, function(raw)
							if vim.tbl_contains(args, "proplist") then
								held = function()
									done(raw)
								end
							else
								done(raw)
							end
						end)
					end
					local task = provider.preview(snapshot, by_path.selected, function()
						delivered = true
					end)
					ctx.wait_for(function()
						return held
					end, "directory property query did not run", 15000)
					task:cancel()
					held()
					util.system_start = start
					assert(not delivered, "cancelled property query delivered a result")
					for _, raw in ipairs({
						"<properties><target>",
						'<properties><target path="wrong"></target></properties>',
						'<properties><target path="wrong"></target><target path="wrong"></target></properties>',
					}) do
						---@diagnostic disable-next-line: duplicate-set-field
						common.command = function(_, _, _, done)
							done(raw)
						end
						result, err = preview()
						assert(not result and err, "malformed property XML was accepted")
					end
					---@diagnostic disable-next-line: duplicate-set-field
					common.command = function(_, _, _, done, opts)
						assert(opts.output_limit_bytes == 16 * 1024 * 1024)
						done(nil, "truncated", { stdout_truncated = true })
					end
					result, err = preview()
					assert(not result and err and err:find("transport limit", 1, true))
					common.command = command
					set("selected", "custom:large", string.rep("x", 1024 * 1024 + 1))
					result, err = preview()
					assert(
						not result and err and err:find("Decoded properties", 1, true),
						"decoded property map exceeded its bound"
					)
					h.exec({ "svn", "propdel", "custom:large", "selected" }, f.root)
					set("selected", "custom:expanded", string.rep("&", 700000))
					result, err = preview()
					assert(
						result and contains(result.right, string.rep("&", 700000)),
						"XML expansion reduced property budget: " .. tostring(err)
					)
					set("selected", "custom:expanded", string.rep("x", 1024 * 1024 - 250))
					result, err = preview()
					assert(
						not result and err and err:find("Property patch", 1, true),
						"rendered patch headers exceeded their bound"
					)
				end, debug.traceback)
				common.command, util.system_start = command, start
				if s then
					compare.close(s)
				end
				assert(ok, failure)
			end,
		},
		{
			"test_svn_compare_property_only_file_metadata_actions",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "propset", "custom:review", "changed value", f.file }, f.root)
				local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@1" }))
				local ok, err = xpcall(function()
					ctx.wait_for(function()
						return s.preview_result
					end, "property-only preview did not load", 15000)
					api.nvim_set_current_win(s.sidewin)
					api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path["sample.txt"]), 0 })
					s.actions.preview()
					ctx.wait_for(function()
						return s.preview_result and s.shown_item.relpath == "sample.txt"
					end, "file property preview did not load", 15000)
					assert(
						s.shown_item.property_only
							and contains(api.nvim_buf_get_lines(s.right, 0, -1, false), "changed value")
					)
					api.nvim_set_current_win(s.sidewin)
					vim.fn.maparg("p", "n", false, true).callback()
					assert(
						s.mode == "metadata" and contains(api.nvim_buf_get_lines(s.left, 0, -1, false), "custom:review"),
						"property-only mapping showed empty metadata"
					)
					vim.cmd("LazyVCS compare metadata")
					assert(
						s.mode == "text" and contains(api.nvim_buf_get_lines(s.right, 0, -1, false), "changed value")
					)
					vim.cmd("LazyVCS compare metadata")
					assert(
						s.mode == "metadata" and contains(api.nvim_buf_get_lines(s.left, 0, -1, false), "changed value"),
						"property-only command showed empty metadata"
					)
				end, debug.traceback)
				compare.close(s)
				assert(ok, err)
			end,
		},
		{
			"test_svn_compare_property_patch_uses_full_byte_limit",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@1", done)
				end))
				local property = h.tempdir() .. "/property"
				local item =
					{ relpath = "sample.txt", kind = "file", status = "M", property_only = true, properties = true }
				local function preview()
					return await(function(done)
						provider.preview(snapshot, item, done)
					end)
				end
				h.write_file(property, string.rep("x", 700000))
				h.exec({ "svn", "propset", "custom:large", "--file", property, "sample.txt" }, f.root)
				local patch = h.exec({
					"svn",
					"diff",
					"--properties-only",
					"--old",
					snapshot.url .. "/sample.txt@1",
					"--new",
					f.file .. "@",
				}, f.root)
				assert(#patch > 512 * 1024 and #patch < 1024 * 1024, "fixture patch outside supported budget")
				local result, err = preview()
				assert(result, "supported property patch rejected: " .. tostring(err))
				assert(
					vim.deep_equal(result.right, require("lazyvcs.util").split_lines(patch)),
					"property patch bytes changed"
				)
				h.write_file(property, string.rep("x", 1024 * 1024))
				h.exec({ "svn", "propset", "custom:large", "--file", property, "sample.txt" }, f.root)
				result, err = preview()
				assert(not result and err and err:find("1 MiB", 1, true), "oversized property patch was accepted")
				item.property_only = false
				h.write_file(f.file, "edited text")
				result, err = preview()
				assert(result and result.right[1] == "edited text", err)
				assert(
					not result.properties and contains(result.details, "1 MiB"),
					"optional property failure discarded text or its error"
				)
			end,
		},
		{
			"test_svn_compare_added_file_metadata_includes_properties",
			function()
				local f = h.make_svn_fixture()
				local added = "added #%.txt"
				for _, path in ipairs({ added, "plain.txt", "untracked.txt" }) do
					h.write_file(f.root .. "/" .. path, "added text\n")
				end
				h.exec({ "svn", "add", added, "plain.txt" }, f.root)
				h.exec({ "svn", "propset", "svn:eol-style", "native", added }, f.root)
				-- SVN on Windows expands a "*" argument as a wildcard; it stores any svn:executable value as "*".
				h.exec({ "svn", "propset", "svn:executable", "ON", added }, f.root)
				h.write_file(f.file, "one\ntwo\nthree\n")
				h.exec({ "svn", "propset", "custom:file", "value", "sample.txt" }, f.root)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@1", done)
				end))
				local items = assert(await(function(done)
					provider.list(snapshot, true, done)
				end))
				local paths = {}
				for _, item in ipairs(items) do
					paths[item.relpath] = item
				end
				local function preview(name)
					return await(function(done)
						provider.preview(snapshot, assert(paths[name]), done)
					end)
				end
				local result, err = preview(added)
				assert(result, err)
				assert(contains(result.properties, "svn:eol-style"), "added SVN properties missing from metadata")
				assert(contains(result.properties, "svn:executable"))
				assert(#result.left == 0 and result.right[1] == "added text")
				assert(not assert(preview("plain.txt")).properties, "property-free addition has metadata")
				assert(not assert(preview("untracked.txt")).properties, "untracked file has property metadata")
				assert(
					contains(assert(preview("sample.txt")).right, "custom:file"),
					"file property-only preview changed"
				)
				local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@1" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "SVN comparison did not load", 15000)
				api.nvim_set_current_win(s.sidewin)
				api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[added], 0 })
				s.actions.metadata()
				ctx.wait_for(function()
					return s.mode == "metadata" and s.shown_item.relpath == added
				end, "added metadata UI did not load", 15000)
				assert(contains(api.nvim_buf_get_lines(s.left, 0, -1, false), "svn:eol-style"))
				compare.refresh(s)
				ctx.wait_for(function()
					return s.preview_result
				end, "SVN refresh did not load", 15000)
				assert(contains(s.preview_result.properties, "svn:executable"), "refresh lost added properties")
				compare.close(s)
				local large = h.tempdir() .. "/large-property"
				h.write_file(large, string.rep("x", 1024 * 1024 + 1))
				h.exec({ "svn", "propset", "custom:large", "--file", large, added }, f.root)
				result, err = preview(added)
				assert(
					result and result.right[1] == "added text",
					"oversized optional properties discarded valid text: " .. tostring(err)
				)
				assert(not result.properties and contains(result.details, "1 MiB"), "property limit was not reported")
			end,
		},
	}
end
