local Task = require("lazyvcs.backends.task")
local process = require("lazyvcs.backends.process")
local format = require("lazyvcs.backends.blame_format")
local comparison = require("lazyvcs.backends.comparison")
local M = {}
local legacy_git = {}

local function index_git_entries(raw, entries)
	local indexed, index = {}, 0
	for _, line in ipairs(raw) do
		local oid, number = line:match("^(%x+)%s+%d+%s+(%d+)")
		if oid and (#oid == 40 or #oid == 64) then
			index = index + 1
			indexed[tonumber(number)] = entries[index]
		end
	end
	return indexed
end

function M.load(target, contents, callback, capture)
	local task = Task.new(callback)
	local backends = require("lazyvcs.backends")
	local function load(backend, root)
		local function finish(raw, err)
			if task:is_active() then
				local entries = raw and backend.parse_blame_entries(raw)
				if entries and backend.name == "git" then
					entries = index_git_entries(raw, entries)
				end
				task:finish(entries, err)
			end
		end
		local snapshot, item = target.snapshot, target.item
		if not snapshot then
			task:add(backend.blame_lines_async(target.path, finish, {
				root = root,
				contents = contents,
				text = capture and capture.text,
				profile = capture and capture.profile,
				line_start = target.first,
				line_end = target.last,
			}))
		elseif snapshot.vcs == "git" then
			contents = target.bytes or contents
			local document, lines_err = target.text, nil
			if not document and type(contents) ~= "string" then
				lines_err = "File contents unavailable"
			elseif not document then
				document, lines_err = require("lazyvcs.compare_text").decode_preview(
					contents,
					comparison.decode_options(target.path),
					format.decode_limit()
				)
			end
			if not document then
				vim.schedule(function()
					task:finish(nil, lines_err)
				end)
				return
			end
			-- Keep decoded rows for line-model and clean-filter validation.
			local opts = {
				profile = {
					fileencoding = document.encoding,
					fileformat = contents:find("\r", 1, true) and not contents:find("\n", 1, true) and "mac" or "unix",
				},
				text = document,
				line_start = target.first,
				line_end = target.last,
			}
			local full_file = format.full_file(opts)
			local policy
			local base = target.side == "base"
			local revision = base and snapshot.revision or snapshot.head
			local path = base and (item.old_path or item.relpath) or item.relpath
			local executable = vim.fn.exepath("git")
			local function uncommitted()
				local entries = {}
				for number = target.first, target.last do
					entries[number] = { uncommitted = true, backend = "git" }
				end
				task:finish(entries)
			end
			local function historical(relpath, retry)
				-- Before Git 2.41, --contents cannot accompany a revision. Its fallback
				-- maps git-show bytes, so byte-compatible previews must use captured bytes
				-- too (including encoding and BOM). Retain decoded rows when Git reencodes
				-- the file, or full-file validation checks its line model or filter output.
				if document and not full_file and policy.profile.fileencoding == opts.profile.fileencoding then
					snapshot_lines, lines_err = comparison.lines(contents)
					if not snapshot_lines then
						return task:finish(nil, lines_err)
					end
				end
				if policy and policy.validate and not policy.validated then
					return task:add(
						process.lines(
							{ "git", "blame", "--encoding=UTF-8", "--line-porcelain", "--contents", "-", "--", relpath },
							{ cwd = root, stdin = contents },
							function(raw, err)
								if not task:is_active() then
									return
								end
								if not raw and type(err) == "string" and err:find("no such path", 1, true) then
									if item.old_path and not retry then
										return historical(item.old_path, true)
									end
									return uncommitted()
								end
								local selected, format_err, cleaned
								if raw then
									selected, format_err, cleaned = format.select(raw, opts, policy)
								end
								if not selected then
									return task:finish(nil, format_err or err)
								end
								document = vim.tbl_extend("force", document, { lines = cleaned })
								policy.validated = true
								historical(relpath, retry)
							end
						)
					)
				end
				task:add(
					process.bytes(
						{ "git", "show", revision .. ":" .. relpath },
						{ cwd = root },
						function(base_bytes, err)
							if not task:is_active() then
								return
							end
							if not base_bytes then
								if
									type(err) == "string"
									and (
										err:find("does not exist in", 1, true)
										or err:find("exists on disk, but not in", 1, true)
									)
								then
									if item.old_path and not retry then
										return historical(item.old_path, true)
									end
									return uncommitted()
								end
								return task:finish(nil, err)
							end
							local text = require("lazyvcs.compare_text")
							local decode_opts = comparison.decode_options(target.path)
							-- Historical blobs may use a different encoding from the saved buffer.
							-- Prefer their BOM or UTF-8 before the buffer's fallback hint.
							if decode_opts.hint then
								decode_opts.fileencodings = "ucs-bom,utf-8,"
									.. decode_opts.hint.fileencoding
									.. ","
									.. decode_opts.fileencodings
								decode_opts.hint = nil
							end
							decode_opts.encoding = policy and policy.base_encoding
							local base_document, decode_err =
								text.decode_preview(base_bytes, decode_opts, format.decode_limit())
							if not base_document then
								return task:finish(nil, decode_err)
							end
							local base_opts = {
								profile = { fileencoding = base_document.encoding, fileformat = "dos" },
								text = base_document,
							}
							local indices = {}
							for i = 1, #base_document.lines do
								indices[i] = i
							end
							local mapped =
								require("lazyvcs.backends.blame_mapping").map(indices, base_document, document, false)
							local ranges, wanted, entries = {}, {}, {}
							for number = target.first, target.last do
								local old = mapped[number]
								if old then
									wanted[old] = number
									local range = ranges[#ranges]
									if range and old == range[2] + 1 then
										range[2] = old
									else
										ranges[#ranges + 1] = { old, old }
									end
								else
									entries[number] = { uncommitted = true, backend = "git" }
								end
							end
							local next_range = 1
							local function chunk()
								if not task:is_active() then
									return
								end
								if next_range > #ranges then
									return task:finish(entries)
								end
								local args = { "git", "blame", "--encoding=UTF-8", "--line-porcelain" }
								-- Bound argv size on Windows when deletions split the selected history.
								local ending = math.min(#ranges, next_range + 127)
								if full_file or format.full_file(base_opts) then
									next_range = #ranges + 1
								else
									for i = next_range, ending do
										vim.list_extend(args, { "-L", ranges[i][1] .. "," .. ranges[i][2] })
									end
									next_range = ending + 1
								end
								vim.list_extend(args, { revision, "--", relpath })
								task:add(process.lines(args, { cwd = root }, function(raw, blame_err)
									if not task:is_active() then
										return
									end
									if not raw then
										return task:finish(nil, blame_err)
									end
									local validated, format_err = format.select(raw, base_opts)
									if not validated then
										return task:finish(nil, format_err)
									end
									for old, entry in
										pairs(index_git_entries(validated, backend.parse_blame_entries(validated)))
									do
										if wanted[old] then
											entries[wanted[old]] = entry
										end
									end
									chunk()
								end))
							end
							chunk()
						end
					)
				)
			end
			local function blame(relpath, retry)
				if not base and legacy_git[executable] then
					return historical(relpath, retry)
				end
				local args = { "git", "blame", "--encoding=UTF-8", "--line-porcelain" }
				if not full_file then
					vim.list_extend(args, { "-L", target.first .. "," .. target.last })
				end
				if not base then
					vim.list_extend(args, { "--contents", "-" })
				end
				vim.list_extend(args, { revision, "--", relpath })
				task:add(process.lines(args, { cwd = root, stdin = not base and contents or nil }, function(raw, err)
					if not task:is_active() then
						return
					end
					if
						not base
						and not raw
						and type(err) == "string"
						and err:find("cannot use --contents", 1, true)
					then
						legacy_git[executable] = true
						return historical(relpath, retry)
					end
					if not base and not raw and type(err) == "string" and err:find("no such path", 1, true) then
						if item.old_path and not retry then
							return blame(item.old_path, true)
						end
						return uncommitted()
					end
					if not raw then
						return finish(nil, err)
					end
					local selected, format_err = format.select(raw, opts, policy)
					finish(selected, format_err)
				end))
			end
			if base then
				blame(path, false)
			else
				task:add(require("lazyvcs.backends.git_blame_policy").load(root, path, opts, function(value, err)
					if not task:is_active() then
						return
					end
					if not value then
						return task:finish(nil, err)
					end
					policy = value
					full_file = full_file or policy.validate
					blame(path, false)
				end))
			end
		elseif target.side == "base" then
			local path = item.relpath:gsub("[^%w%-%._~/]", function(char)
				return string.format("%%%02X", char:byte())
			end)
			local url = snapshot.url .. "/" .. path
			task:add(process.lines({
				"svn",
				"--non-interactive",
				"blame",
				"-v",
				"-r",
				snapshot.revision,
				url .. "@" .. snapshot.revision,
			}, { cwd = root }, function(raw, err)
				if raw then
					local document = target.text
					if not document then
						document, err = require("lazyvcs.compare_text").decode_preview(
							target.bytes or contents,
							comparison.decode_options(target.path),
							comparison.max_file_bytes
						)
					end
					if not document then
						return finish(nil, err)
					end
					local valid, why = format.svn_document(document, raw, "dos")
					if not valid then
						return finish(
							nil,
							why or err or "Unsupported blame line format: SVN and the preview use different lines"
						)
					end
				end
				finish(raw, err)
			end))
		else
			task:add(backend.blame_lines_async(target.path, finish, {
				root = root,
				contents = contents,
				text = target.text or (capture and capture.text),
				preview = target.text ~= nil,
				profile = capture and capture.profile,
				line_start = target.first,
				line_end = target.last,
			}))
		end
	end
	if target.snapshot then
		load(require("lazyvcs.backends." .. target.snapshot.vcs), target.snapshot.root)
	else
		task:add(backends.resolve_async(target.path, function(backend, root, err)
			if not task:is_active() then
				return
			end
			if not backend then
				return task:finish(nil, err)
			end
			load(backend, root)
		end))
	end
	return task
end
function M._test_reset_legacy_git()
	for executable in pairs(legacy_git) do
		legacy_git[executable] = nil
	end
end

return M
