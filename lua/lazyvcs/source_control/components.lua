local common = require("neo-tree.sources.common.components")
local util = require("lazyvcs.util")

local M = {}
local strwidth = vim.api.nvim_strwidth

local function component(text, highlight)
	return {
		text = text,
		highlight = highlight,
	}
end

local function is_disabled(node)
	return node and node.extra and node.extra.disabled
end

local function pick_highlight(node, default_highlight)
	if is_disabled(node) then
		return "LazyVcsDisabled"
	end
	return default_highlight
end

local function truncate_left(text, max_len)
	if not text or strwidth(text) <= max_len then
		return text or ""
	end
	if max_len <= 3 then
		return text:sub(-max_len)
	end
	return "..." .. text:sub(-(max_len - 3))
end

local function fit_right_text(text, max_width, opts)
	opts = opts or {}
	local min_width = opts.min_width or 1
	local align = opts.align or "right"
	if not text or text == "" or max_width < min_width then
		return nil
	end

	local display = text
	if strwidth(display) > max_width then
		if align == "left" then
			display = truncate_left(display, max_width)
		else
			display = util.truncate(display, max_width)
		end
	end
	local used = strwidth(display)
	if used < min_width then
		return nil
	end
	return display
end

local function compact_sync_text(sync)
	local text = sync and sync.text or ""
	local status = sync and sync.status or ""
	if text == "" then
		return ""
	end
	if status == "publish" then
		return "Pub"
	end
	return text:gsub("%s+", "")
end

local function repo_count_text(counts)
	local local_changes = counts and counts.local_changes or 0
	if local_changes <= 0 then
		return ""
	end
	return tostring(local_changes)
end

local function status_text_for_width(sync, counts, max_width)
	local count_text = repo_count_text(counts)
	local full = sync and sync.text or ""
	local compact = compact_sync_text(sync)

	if full ~= "" and strwidth(full) <= max_width then
		return full
	end
	if compact ~= "" and strwidth(compact) <= max_width then
		return compact
	end
	if count_text ~= "" and strwidth(count_text) <= max_width then
		return count_text
	end
	return nil
end

local function compose_right_meta(primary, primary_hl, sync, counts, remaining_width, opts)
	opts = opts or {}
	local min_primary = opts.min_primary or 8
	local gap_width = 1
	local available = math.max(0, (remaining_width or 0) - gap_width)
	local status = status_text_for_width(sync, counts, available)
	if not primary or primary == "" then
		if not status then
			return nil
		end
		return component(" " .. status, sync.highlight or "Comment")
	end

	if status then
		local status_width = strwidth(status)
		local primary_budget = available - status_width - 1
		if primary_budget >= min_primary then
			local display = fit_right_text(primary, primary_budget, { min_width = min_primary, align = "left" })
			if display then
				return {
					{
						text = " " .. display .. " ",
						highlight = primary_hl,
						no_next_padding = true,
					},
					{
						text = status,
						highlight = sync.highlight or "Comment",
						no_padding = true,
					},
				}
			end
		end
		return component(" " .. status, sync.highlight or "Comment")
	end

	local display = fit_right_text(primary, available, { min_width = min_primary, align = "left" })
	if not display then
		return nil
	end
	return component(" " .. display, primary_hl)
end

M.icon = function(config, node)
	local hl = config.highlight or "Directory"
	if node.type == "repo_selector" or node.type == "repo_changes" then
		local vcs = node.extra and node.extra.vcs or "git"
		if vcs == "svn" then
			return component("󰘦 ", pick_highlight(node, "Keyword"))
		end
		return component("󰊢 ", pick_highlight(node, "Keyword"))
	end
	if node.type == "view_section" then
		return component("󰉋 ", pick_highlight(node, "Comment"))
	end
	if node.type == "commit_input" then
		return component("󰏫 ", pick_highlight(node, "DiagnosticHint"))
	end
	if node.type == "action_button" then
		return component("󰒓 ", pick_highlight(node, "DiagnosticInfo"))
	end
	if node.type == "section" then
		return component("󰉋 ", pick_highlight(node, "Comment"))
	end
	if node.type == "folder" then
		return component(" ", pick_highlight(node, "Directory"))
	end
	if node.type == "message" then
		return component("󰍩 ", pick_highlight(node, "Comment"))
	end
	return component("󰈙 ", pick_highlight(node, hl))
end

M.name = function(config, node)
	local highlight = config.highlight or "NeoTreeFileName"
	if node.type == "repo_selector" then
		local prefix = node.extra and node.extra.visible and "● " or "○ "
		if node.extra and node.extra.focused then
			prefix = "▸ "
		end
		return component(prefix .. node.name, pick_highlight(node, "Directory"))
	end
	if node.type == "repo_changes" then
		return component(node.name, pick_highlight(node, "Directory"))
	end
	if node.type == "view_section" then
		return component(node.name, pick_highlight(node, "Comment"))
	end
	if node.type == "commit_input" then
		local draft = node.extra and node.extra.draft or ""
		if draft == "" then
			return component(node.name, pick_highlight(node, "Comment"))
		end
		return component(node.name, pick_highlight(node, "String"))
	end
	if node.type == "action_button" then
		return component(node.name, pick_highlight(node, "Function"))
	end
	if node.type == "section" then
		return component(node.name, pick_highlight(node, "Comment"))
	end
	if node.type == "folder" then
		return component(node.name, pick_highlight(node, "Directory"))
	end
	if node.type == "message" then
		return component(node.name, pick_highlight(node, "Comment"))
	end
	return component(node.name, pick_highlight(node, highlight))
end

M.repo_selector_meta = function(_, node, _, remaining_width)
	if node.type ~= "repo_selector" then
		return nil
	end
	local path_label = node.extra and node.extra.path_label or ""
	local status = node.extra and node.extra.sync or {}
	local counts = node.extra and node.extra.counts or {}
	local width = remaining_width or 0
	local meta = compose_right_meta(path_label, pick_highlight(node, "Comment"), status, counts, width, {
		min_width = 8,
	})
	return meta
end

M.repo_changes_meta = function(_, node, _, remaining_width)
	if node.type ~= "repo_changes" then
		return nil
	end
	local branch = node.extra and node.extra.branch or ""
	local counts = node.extra and node.extra.counts or {}
	local sync = node.extra and node.extra.sync or {}
	local width = remaining_width or 0
	local meta = compose_right_meta(branch, pick_highlight(node, "Comment"), sync, counts, width, {
		min_primary = 8,
	})
	return meta
end

M.root_meta = function(_, node, _, remaining_width)
	if node.type ~= "root" then
		return nil
	end
	if not (node.extra and node.extra.hydration_active) then
		return nil
	end
	local pending = node.extra and node.extra.hydration_pending or 0
	if pending <= 0 then
		return nil
	end
	local label = fit_right_text("󰑓", remaining_width or 0, {
		min_width = 1,
		align = "left",
	})
	return label and component(label, "LazyVcsBusy") or nil
end

M.input_hint = function(_, node, _, remaining_width)
	if node.type ~= "commit_input" then
		return nil
	end
	if is_disabled(node) then
		local label = fit_right_text(node.extra and node.extra.busy_label or "Busy", remaining_width or 0, {
			min_width = 4,
			align = "left",
		})
		return label and component(label, "LazyVcsBusy") or nil
	end
	if node.extra and node.extra.show_input_action_button and node.extra.primary_label then
		local label = fit_right_text(node.extra.primary_label, remaining_width or 0, {
			min_width = 8,
			align = "left",
		})
		if not label then
			return nil
		end
		return component(label, pick_highlight(node, "Function"))
	end
	local draft = node.extra and node.extra.draft or ""
	if draft ~= "" then
		return component("Edit", pick_highlight(node, "Comment"))
	end
	return component("Input", pick_highlight(node, "Comment"))
end

M.change_status = function(_, node)
	if node.type ~= "file" then
		return nil
	end
	local kind = node.extra and node.extra.change_kind or "modified"
	local map = {
		modified = { "M", "DiagnosticWarn" },
		added = { "A", "DiagnosticOk" },
		deleted = { "D", "DiagnosticError" },
		untracked = { "U", "DiagnosticInfo" },
		conflict = { "!", "DiagnosticError" },
		renamed = { "R", "DiagnosticHint" },
		remote = { "↓", "DiagnosticInfo" },
	}
	local item = map[kind] or { util.truncate(kind, 1), "Comment" }
	return component(item[1], pick_highlight(node, item[2]))
end

return vim.tbl_deep_extend("force", common, M)
