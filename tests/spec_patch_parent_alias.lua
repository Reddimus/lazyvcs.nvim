return function(ctx)
	local uv, h = vim.uv, ctx.helpers
	local fs = require("lazyvcs.backends.patch_io")
	local paths = require("lazyvcs.backends.patch_path")
	local parent = require("lazyvcs.backends.patch_path").parent
	local Task = require("lazyvcs.backends.task")
	local cases = {}
	local function wait(fn)
		ctx.wait_for(fn, "patch parent alias did not settle", 2000)
	end
	local function request(path)
		local result = {}
		local task = Task.new(function(ok, err)
			result.ok, result.err, result.done = ok, err, true
		end)
		local function guard(fn)
			return function(...)
				if task:is_active() then
					return fn(...)
				end
			end
		end
		parent(task, path, guard, function()
			task:finish(true)
		end)
		return task, result
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_parent_alias_" .. name,
			function()
				local realpath, lstat = uv.fs_realpath, fs.fs_lstat
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				uv.fs_realpath, fs.fs_lstat = realpath, lstat
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	case("native_exact_path_keeps_no_extra_lstat", function()
		local dir = h.tempdir()
		local count, lstat = 0, fs.fs_lstat
		---@diagnostic disable-next-line: duplicate-set-field
		fs.fs_lstat = function(...)
			count = count + 1
			---@diagnostic disable-next-line: return-type-mismatch
			return lstat(...)
		end
		local _, result = request(dir)
		wait(function()
			return result.done
		end)
		assert(result.ok and count == 0, "exact native path added directory metadata work")
	end)
	-- These are explicitly recorded-value unit seams, not Linux evidence of
	-- macOS normalization: native run41237105673 returned NFC -> NFD and dev16777228.
	for _, mode in ipairs({
		"directory",
		"deep_directory",
		"link",
		"deep_link",
		"different_inode",
		"different_device",
		"invalid_identity",
		"lexical_error",
		"physical_error",
		"different_depth",
		"relative_input",
		"cancel_lexical",
		"cancel_physical",
		"native_tokens",
		"token_change",
	}) do
		local native_tokens = mode == "native_tokens" or mode == "token_change"
		case((native_tokens and "controlled_windows_" or "recorded_macos_") .. mode, function()
			local root = "/recorded/mac-native-root"
			local lexical, physical = root .. "/caf\195\169", root .. "/cafe\204\129"
			local first_lexical, first_physical = lexical, physical
			local deep = mode == "deep_directory" or mode == "deep_link"
			if deep then
				lexical, physical = lexical .. "/child", physical .. "/child"
			elseif mode == "different_depth" then
				physical = physical .. "/child"
			elseif mode == "relative_input" then
				lexical = "relative/caf\195\169"
			end
			local calls, held = {}, nil
			-- Recorded callbacks intentionally have no native request handle.
			---@diagnostic disable: missing-return
			uv.fs_realpath = function(path, callback)
				assert(path == lexical)
				vim.schedule(function()
					callback(nil, physical)
				end)
			end
			---@diagnostic disable-next-line: duplicate-set-field
			fs.fs_lstat = function(path, callback)
				calls[#calls + 1] = path
				assert(
					path == first_lexical or path == first_physical or deep and (path == lexical or path == physical)
				)
				local stat = { type = "directory", dev = 16777228, ino = 3539091 }
				if native_tokens then
					stat = {
						type = "directory",
						identity = "windows-file-id-128",
						dev = "0000000054cba874",
						ino = "000000000000000000000000003602d3",
						directory_reparse = false,
					}
					if mode == "token_change" and path == physical then
						stat.ino = "000000000000000000000000003602d4"
					end
				end
				if deep and (path == lexical or path == physical) then
					stat.ino = 3539092
				end
				local err
				if mode == "link" and path == first_lexical or mode == "deep_link" and path == lexical then
					stat.type = "link"
				elseif mode == "different_inode" and path == physical then
					stat.ino = stat.ino + 1
				elseif mode == "different_device" and path == physical then
					stat.dev = stat.dev + 1
				elseif mode == "invalid_identity" and path == physical then
					stat.dev = -1
				elseif mode == "lexical_error" and path == lexical or mode == "physical_error" and path == physical then
					err, stat = "EIO controlled directory metadata", nil
				end
				if mode == "cancel_lexical" and path == lexical or mode == "cancel_physical" and path == physical then
					held = function()
						callback(err, stat)
					end
				else
					vim.schedule(function()
						callback(err, stat)
					end)
				end
			end
			---@diagnostic enable: missing-return
			local task, result = request(lexical)
			if mode:match("^cancel_") then
				wait(function()
					return held ~= nil or result.done
				end)
				assert(held, "alias prefix check never reached cancellation seam")
				local count = #calls
				task:cancel()
				held()
				vim.wait(20, function()
					return false
				end, 5)
				assert(not result.done and #calls == count, "cancelled alias lookup continued or published")
			else
				wait(function()
					return result.done
				end)
				if mode == "directory" or mode == "deep_directory" or mode == "native_tokens" then
					assert(result.ok and not result.err, result.err)
					assert(#calls == (deep and 4 or 2), "alias check did not cover each differing directory prefix")
				else
					assert(not result.ok and result.err, "invalid alias directory was accepted")
				end
			end
		end)
	end
	for _, deep in ipairs({ false, true }) do
		case("native_" .. (deep and "ancestor" or "parent") .. "_link_same_inode_rejected", function()
			local root = h.tempdir()
			local old, alias = root .. "/original", root .. "/alias"
			vim.fn.mkdir(old .. "/child", "p")
			local linked, err = uv.fs_symlink(old, alias, vim.fn.has("win32") == 1 and { junction = true } or nil)
			if not linked and vim.fn.has("win32") == 1 then
				error({ lazyvcs_skip = "fixture directory link unavailable: " .. tostring(err) }, 0)
			end
			assert(linked, err)
			local selected, target = deep and alias .. "/child" or alias, deep and old .. "/child" or old
			assert(uv.fs_realpath(selected) == uv.fs_realpath(target), "fixture must reach the same original directory")
			local _, result = request(selected)
			wait(function()
				return result.done
			end)
			assert(uv.fs_unlink(alias) or uv.fs_rmdir(alias))
			assert(not result.ok and result.err, "native directory link bypassed parent containment")
		end)
	end
	case("native_distinct_sibling_ids_rejected_under_controlled_realpath", function()
		local root = h.tempdir()
		local a, b = root .. "/first", root .. "/second"
		vim.fn.mkdir(a)
		vim.fn.mkdir(b)
		local first, second
		fs.fs_lstat(a, function(err, entry)
			assert(not err, err)
			first = entry
		end)
		fs.fs_lstat(b, function(err, entry)
			assert(not err, err)
			second = entry
		end)
		wait(function()
			return first ~= nil and second ~= nil
		end)
		assert(paths.identity(first) and paths.identity(second) and not paths.same(first, second))
		-- The canonical result is controlled; directory identities are native.
		---@diagnostic disable: missing-return
		uv.fs_realpath = function(path, callback)
			assert(path == a)
			vim.schedule(function()
				callback(nil, b)
			end)
		end
		---@diagnostic enable: missing-return
		local _, result = request(a)
		wait(function()
			return result.done
		end)
		assert(not result.ok and result.err, "distinct native sibling identities were treated as aliases")
	end)
	return cases
end
