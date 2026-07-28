local M = {}

local function item_text(item)
	if type(item) == "table" then
		return item.label or item.text or item.name or item.path or tostring(item)
	end
	return tostring(item)
end

function M.select(items, opts, on_choice)
	opts = opts or {}
	local ok_snacks, snacks_select = pcall(require, "snacks.picker.select")
	if ok_snacks and snacks_select and type(snacks_select.select) == "function" then
		return snacks_select.select(items, {
			prompt = opts.prompt,
			format_item = opts.format_item or item_text,
			snacks = opts.snacks,
		}, on_choice)
	end

	local ok_fzf, fzf = pcall(require, "fzf-lua")
	if ok_fzf and fzf and type(fzf.fzf_exec) == "function" then
		local lookup = {}
		local entries = {}
		for index, item in ipairs(items) do
			local text = opts.format_item and opts.format_item(item) or item_text(item)
			local id = string.format("%08d", index)
			entries[#entries + 1] = id .. "\t" .. text
			lookup[id] = item
		end
		return fzf.fzf_exec(entries, {
			prompt = opts.prompt or "Select> ",
			fzf_opts = { ["--delimiter"] = "\t", ["--with-nth"] = "2.." },
			actions = {
				["default"] = function(selected)
					local value = selected and selected[1]
					local id = value and value:match("^(%d+)\t")
					on_choice(id and lookup[id] or nil)
				end,
			},
		})
	end

	return vim.ui.select(items, {
		prompt = opts.prompt,
		format_item = opts.format_item or item_text,
	}, on_choice)
end

return M
