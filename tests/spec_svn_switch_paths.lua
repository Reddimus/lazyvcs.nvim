return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local switch = require("lazyvcs.source_control.switch")
	local util = require("lazyvcs.util")
	local function segment(name)
		return (name:gsub("[^A-Za-z0-9%-%._~]", function(c)
			return string.format("%%%02X", c:byte())
		end))
	end
	local function fixture(name, project, suffix)
		assert(vim.fn.executable("svnadmin") == 1, "svnadmin is required")
		local dir = h.tempdir()
		local repository = dir .. "/" .. name
		h.exec({ "svnadmin", "create", repository }, dir)
		local url = h.file_url(repository)
		local layout = url .. (project ~= "" and "/" .. segment(project) or "")
		h.exec({
			"svn",
			"mkdir",
			"--parents",
			layout .. "/trunk",
			layout .. "/branches",
			layout .. "/tags",
			"-m",
			"layout",
		}, dir)
		local seed = dir .. "/seed"
		vim.fn.mkdir(seed .. (suffix ~= "" and "/" .. suffix or ""), "p")
		h.write_file(seed .. (suffix ~= "" and "/" .. suffix or "") .. "/sample.txt", "trunk\n")
		h.exec({ "svn", "import", seed, layout .. "/trunk", "-m", "Seed fixture" }, dir)
		local root = dir .. "/wc"
		local tail = suffix ~= "" and "/" .. segment(suffix) or ""
		h.exec({ "svn", "checkout", util.svn_target(layout .. "/trunk" .. tail), root }, dir)
		return { root = root, vcs = "svn", name = "wc", layout = layout, tail = tail, url = url }
	end
	local function copy(repo, kind, name)
		local url = repo.layout .. "/" .. kind .. "/" .. segment(name)
		h.exec(
			{ "svn", "copy", util.svn_target(repo.layout .. "/trunk"), util.svn_target(url), "-m", "Copy fixture" },
			repo.root
		)
		return url .. repo.tail
	end
	local function runner(repo)
		return function(args, _, done)
			return util.system_start(args, { cwd = repo.root }, done)
		end
	end
	local function collect(repo)
		local result, failure, finished
		switch.collect_async(repo, runner(repo), function(value, err)
			result, failure, finished = value, err, true
		end)
		wait(function()
			return finished
		end, "SVN collection did not finish", 15000)
		assert(result, failure)
		return result
	end
	local function target(context, kind, name)
		for _, item in ipairs(context.items) do
			if item.target_kind == kind and item.target_name == name then
				return item
			end
		end
		error("Missing SVN target: " .. kind .. "/" .. name)
	end
	local function pick(repo, kind, name, manual)
		local finished, failure, mutations = false, nil, 0
		switch.open_async(repo, {
			select = function(items, _, done)
				if manual then
					return done(items[1])
				end
				done(target({ items = items }, kind, name))
			end,
			input = function(_, done)
				done(manual)
			end,
			after_mutation = function()
				mutations, finished = mutations + 1, true
			end,
			notify = function(message, level)
				finished = true
				if level ~= vim.log.levels.INFO then
					failure = message
				end
			end,
		}, runner(repo))
		wait(function()
			return finished
		end, "SVN switch did not finish", 15000)
		assert(not failure, failure)
		return mutations
	end
	local function current(repo)
		return util.trim(h.exec({ "svn", "info", "--show-item", "url", util.svn_target(repo.root) }, repo.root))
	end
	return {
		{
			"test_source_control_svn_switch_literal_segments",
			function()
				local repo = fixture("repository", "project % space", "sub % space")
				local names = { "release%20x", "release x", "%", "a@b", "café ✓" }
				for _, kind in ipairs({ "branches", "tags" }) do
					local urls = {}
					for _, name in ipairs(names) do
						local url = copy(repo, kind, name)
						urls[name] = url
						local peer = h.tempdir()
						h.exec({ "svn", "checkout", util.svn_target(url), peer }, repo.root)
						h.write_file(peer .. "/sample.txt", kind .. ":" .. name .. "\n")
						h.exec({ "svn", "commit", "-m", "Set target contents", util.svn_target(peer) }, peer)
						vim.fn.delete(peer, "rf")
					end
					local target_kind = kind == "branches" and "branch" or "tag"
					for _, name in ipairs(names) do
						assert(pick(repo, target_kind, name) == 1)
						assert(
							vim.fn.readfile(repo.root .. "/sample.txt")[1] == kind .. ":" .. name,
							"SVN switched to a different literal name: " .. kind .. "/" .. name
						)
						local expected = util.trim(
							h.exec({ "svn", "info", "--show-item", "url", util.svn_target(urls[name]) }, repo.root)
						)
						assert(current(repo) == expected, "SVN working-copy URL changed literal target")
						local item = target(collect(repo), target_kind, name)
						assert(item.target_url == urls[name], "generated target double-encoded the root or suffix")
						assert(item.current, "literal current target was not marked")
						assert(pick(repo, target_kind, name) == 0, "current literal target mutated again")
					end
				end
				assert(
					require("lazyvcs.backends.svn_url").encode_segment("a/b%\\c") == "a%2Fb%25%5Cc",
					"segment encoder converted a literal path"
				)
				local branch = repo.layout .. "/branches/" .. segment("a@b") .. repo.tail
				for _, peg in ipairs({ "@", "@HEAD" }) do
					assert(pick(repo, nil, nil, branch .. peg) == 1)
					assert(vim.fn.readfile(repo.root .. "/sample.txt")[1] == "branches:a@b", "manual peg input changed")
				end
			end,
		},
		{
			"test_source_control_svn_switch_layout_is_repository_relative",
			function()
				for _, name in ipairs({ "trunk", "branches", "tags" }) do
					local repo = fixture(name, "project space", "sub space")
					local branch, tag = copy(repo, "branches", "feature"), copy(repo, "tags", "release")
					local context = collect(repo)
					assert(
						target(context, "branch", "feature").target_url == branch,
						"branch URL escaped repository layout"
					)
					assert(target(context, "tag", "release").target_url == tag, "tag URL escaped repository layout")
					assert(target(context, "trunk", "trunk").target_url == repo.layout .. "/trunk" .. repo.tail)
					assert(pick(repo, "branch", "feature") == 1)
					assert(current(repo) == branch, "wrong repository-relative switch URL")
					assert(pick(repo, "tag", "release") == 1)
					assert(current(repo) == tag)
					h.cleanup()
				end
				local at_repo = fixture("repository", "project @ space", "")
				local at_branch = copy(at_repo, "branches", "feature")
				assert(
					target(collect(at_repo), "branch", "feature").target_url
						== util.trim(
							h.exec({ "svn", "info", "--show-item", "url", util.svn_target(at_branch) }, at_repo.root)
						),
					"layout enumeration lost literal @"
				)
				assert(pick(at_repo, "branch", "feature") == 1)
				for _, root in ipairs({ "", "file:///repo", "file:///elsewhere" }) do
					local commands, result = {}, nil
					switch.collect_async({ root = h.tempdir(), vcs = "svn", name = "mismatch" }, function(args, _, done)
						commands[#commands + 1] = args
						done({
							stdout = '<info><entry kind="dir" revision="1"><url>file:///repo-other/trunk</url><repository><root>'
								.. root
								.. "</root></repository></entry></info>",
						})
					end, function(value)
						result = value
					end)
					assert(
						result and #commands == 1 and #result.items == 1,
						"inconsistent repository root triggered guessed enumeration"
					)
				end
			end,
		},
	}
end
