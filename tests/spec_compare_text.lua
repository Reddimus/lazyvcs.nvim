return function()
	local function profile(encoding, format)
		return {
			fileencoding = encoding or "utf-8",
			fileformat = format or "unix",
			bomb = false,
			binary = false,
			key = "test",
		}
	end
	return {
		{
			"test_process_text_capture_normalizes_split_crlf",
			function()
				local system, util = vim.system, require("lazyvcs.util")
				local ok, err = xpcall(function()
					---@diagnostic disable-next-line: duplicate-set-field
					vim.system = function(_, opts, exit)
						for _, stream in ipairs({ "stdout", "stderr" }) do
							opts[stream](nil, "a\r")
							opts[stream](nil, "\nb\rc\0")
						end
						exit({ code = 0 })
						return { kill = function() end }
					end
					for _, mode in ipairs({ "default", "text", "bytes" }) do
						local opts = {}
						if mode ~= "default" then
							opts.text = mode == "text"
						end
						local result
						util.system_start({ "test" }, opts, function(value)
							result = value
						end)
						assert(vim.wait(2000, function()
							return result ~= nil
						end))
						local expected = mode == "bytes" and "a\r\nb\rc\0" or "a\nb\rc\0"
						assert(
							result.stdout == expected and result.stderr == expected,
							"text capture did not normalize split CRLF in " .. mode .. " mode"
						)
					end
					local completed, bytes, failure, raw
					require("lazyvcs.backends.process").bytes(
						{ "git", "show" },
						{ text = true },
						function(value, why, result)
							bytes, failure, raw, completed = value, why, result, true
						end
					)
					assert(vim.wait(2000, function()
						return completed
					end))
					assert(bytes == "a\r\nb\rc\0" and not failure, "raw content wrapper normalized binary records")
					---@diagnostic disable-next-line: duplicate-set-field
					vim.system = function(_, opts, exit)
						opts.stdout(nil, string.rep("x", 4096))
						exit({ code = 0 })
						return { kill = function() end }
					end
					completed = false
					require("lazyvcs.backends.process").bytes(
						{ "git", "show" },
						{ output_limit_bytes = 256 },
						function(value, why, result)
							bytes, failure, raw, completed = value, why, result, true
						end
					)
					assert(vim.wait(2000, function()
						return completed
					end))
					assert(
						not bytes and failure and raw.stdout_truncated,
						"raw content wrapper accepted truncated bytes"
					)
				end, debug.traceback)
				vim.system = system
				assert(ok, err)
			end,
		},
		{
			"test_compare_text_decode_is_lossless_and_bounded",
			function()
				local text = require("lazyvcs.compare_text")
				for _, item in ipairs({
					{ "alpha\nbeta\n", profile(), { "alpha", "beta" }, true },
					{ "alpha\r\nbeta\r\n", profile("utf-8", "dos"), { "alpha", "beta" }, true },
					{ "alpha\r\nb\rc\n", profile(), { "alpha\r", "b\rc" }, true },
					{ "a\r\nb\nc\r\r\n", profile("utf-8", "dos"), { "a", "b", "c\r" }, true },
					{ "a\rb\r", profile("utf-8", "mac"), { "a", "b" }, true },
					{ "\239\187\191alpha\n", profile(), { "alpha" }, true },
					{ "caf\233\n", profile("latin1"), { "café" }, true },
					{ "\255\254a\0\n\0", profile("utf-16le"), { "a" }, true },
					{ "\254\255\0a\0\n", profile("utf-16"), { "a" }, true },
					{ "", profile(), {}, false },
					{ "\n", profile(), { "" }, true },
					{ "alpha", profile(), { "alpha" }, false },
				}) do
					local decoded, err = text.decode(item[1], item[2], 1024)
					assert(decoded, err)
					assert(
						vim.deep_equal(decoded.lines, item[3]) and decoded.eol == item[4],
						"incorrect decoded document: " .. vim.inspect(decoded)
					)
				end
				for _, bytes in ipairs({ "a\0b", "\192\175", "\237\160\128", "\244\144\128\128", "\255\254a" }) do
					local value, err = text.decode(bytes, profile(), 1024)
					assert(not value and err, "decoder accepted binary or invalid encoding")
				end
				assert(not text.decode("abc", profile(), 2), "raw limit was ignored")
				assert(not text.decode("\233\233", profile("latin1"), 3), "decoded limit was ignored")
				assert(not text.decode("abc", profile("not-an-encoding"), 1024), "unknown encoding was accepted")
			end,
		},
		{
			"test_compare_text_capture_preserves_empty_and_option_identity",
			function()
				local text, api = require("lazyvcs.compare_text"), vim.api
				local buf = api.nvim_create_buf(false, true)
				local ok, err = xpcall(function()
					local empty = assert(text.capture(buf, 1024))
					assert(empty.empty and text.serialize(empty) == "", "empty placeholder became a newline")
					api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
					vim.bo[buf].endofline = false
					local before = assert(text.identity(buf))
					local content = assert(text.capture(buf, 1024))
					assert(text.serialize(content) == "a\nb")
					vim.bo[buf].fixendofline = not vim.bo[buf].fixendofline
					local after = assert(text.identity(buf))
					assert(
						before.changedtick == after.changedtick and not vim.deep_equal(before, after),
						"option changes escaped identity"
					)
					local opts, tick, modified =
						require("lazyvcs.util").buffer_text_options(buf),
						api.nvim_buf_get_changedtick(buf),
						vim.bo[buf].modified
					assert(text.decode("\255\254a\0", assert(text.profile(buf)), 1024))
					assert(
						vim.deep_equal(opts, require("lazyvcs.util").buffer_text_options(buf))
							and tick == api.nvim_buf_get_changedtick(buf)
							and modified == vim.bo[buf].modified,
						"decoding changed the real buffer"
					)
				end, debug.traceback)
				api.nvim_buf_delete(buf, { force = true })
				assert(ok, err)
			end,
		},
	}
end
