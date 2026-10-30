local util = require("lazyvcs.util")
local M = {}
local attached, active, group

local function report(err)
	util.notify("Resession options: " .. tostring(err):gsub("%s+", " "), vim.log.levels.WARN)
end

local function finish(token)
	if active ~= token then
		return
	end
	active = nil
	local resumed, errors = require("lazyvcs.layout").finish_sessions_save(token)
	for _, session in ipairs(resumed) do
		local ok, err = pcall(require("lazyvcs.actions").resume_session_save, session)
		if not ok then
			errors[#errors + 1] = tostring(err)
		end
	end
	if #errors > 0 then
		report(table.concat(errors, "; "))
	end
end

local function pre_save(_, _, tab)
	if active then
		return
	end
	local token = {}
	active = token
	vim.schedule(util.safe_callback(function()
		finish(token)
	end))
	local ok, err = pcall(function()
		local sessions = {}
		for _, session in ipairs(require("lazyvcs.state").list()) do
			if not tab or session.tabpage == tab then
				sessions[#sessions + 1] = session
			end
		end
		require("lazyvcs.layout").prepare_sessions_save(sessions, token)
	end)
	if not ok then
		finish(token)
		report(err)
	end
end

local function post_save()
	if active then
		finish(active)
	end
end

pre_save, post_save = util.safe_callback(pre_save), util.safe_callback(post_save)

function M.setup(load_plugin)
	if attached then
		return true
	end
	-- Opening a live diff attaches save hooks for any available plugin loader.
	if load_plugin and package.loaded.resession == nil then
		pcall(require, "resession")
	end
	local resession = package.loaded.resession
	if
		type(resession) ~= "table"
		or type(resession.add_hook) ~= "function"
		or type(resession.remove_hook) ~= "function"
	then
		if not group then
			group = vim.api.nvim_create_augroup("LazyVCSResession", { clear = true })
			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = "LazyLoad",
				callback = util.safe_callback(function()
					if package.loaded.resession then
						M.setup()
					end
				end),
			})
		end
		return false
	end
	local added, err = pcall(function()
		resession.add_hook("pre_save", pre_save)
		resession.add_hook("post_save", post_save)
	end)
	if not added then
		if type(resession.remove_hook) == "function" then
			pcall(resession.remove_hook, "pre_save", pre_save)
			pcall(resession.remove_hook, "post_save", post_save)
		end
		report(err)
		return false
	end
	attached = resession
	return true
end

function M.teardown()
	post_save()
	if attached and type(attached.remove_hook) == "function" then
		pcall(attached.remove_hook, "pre_save", pre_save)
		pcall(attached.remove_hook, "post_save", post_save)
	end
	attached = nil
	if group then
		vim.api.nvim_del_augroup_by_id(group)
		group = nil
	end
end

return M
