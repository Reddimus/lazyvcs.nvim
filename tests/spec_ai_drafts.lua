return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops = require("lazyvcs.source_control.ops")
	local ai = require("lazyvcs.source_control.ai")
	local input = require("lazyvcs.source_control.input")
	local util = require("lazyvcs.util")
	local native = require("lazyvcs.source_control.native")
	local function guarded(fn)
		return function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				source_control = { confirm_mutations = false },
			})
			local generate, open, notify = ai.generate, input.open, util.notify
			local calls, notices, states = {}, {}, {}
			---@diagnostic disable-next-line: duplicate-set-field
			ai.generate = function(repo, done)
				local request = { repo = repo, done = done, cancelled = 0 }
				function request:cancel()
					self.cancelled = self.cancelled + 1
					self.done(nil, "obsolete cancellation")
				end
				calls[#calls + 1] = request
				return request
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(message)
				notices[#notices + 1] = message
			end
			local function state_for(root)
				root = root or h.tempdir()
				local repo = { root = root, vcs = "git", name = "repo", counts = { staged = 1, local_changes = 1 } }
				local state =
					{ path = root, lazyvcs_repo_cache = { [root] = repo }, lazyvcs_commit_drafts = {}, renders = 0 }
				state.lazyvcs_render = function()
					state.renders = state.renders + 1
				end
				states[#states + 1] = state
				return state, { path = root }, repo
			end
			local ok, err = xpcall(function()
				fn(calls, notices, state_for)
			end, debug.traceback)
			pcall(native.close)
			for _, state in ipairs(states) do
				if ops.cancel_commit_generations then
					ops.cancel_commit_generations(state)
				end
			end
			ai.generate, input.open, util.notify = generate, open, notify
			assert(ok, err)
		end
	end
	local function submit(state, node, value)
		---@diagnostic disable-next-line: duplicate-set-field
		input.open = function(_, _, _, done)
			done(value)
		end
		ops.edit_commit_message(state, node)
	end
	local function native_state()
		local f = h.make_git_fixture()
		local state = native.open({ path = f.root })
		wait(function()
			return not state.lazyvcs_discovering
		end, "sidebar discovery did not finish", 15000)
		state.lazyvcs_commit_drafts = {}
		state.lazyvcs_repo_cache[f.root] = { root = f.root, vcs = "git", name = "repo" }
		return state, { path = f.root }, f
	end
	return {
		{
			"test_source_control_ai_newest_request_owns_draft",
			guarded(function(calls, notices, state_for)
				local state, node, repo = state_for()
				ops.generate_commit_message(state, node)
				ops.generate_commit_message(state, node)
				assert(calls[1].cancelled == 1, "superseded AI request was not cancelled")
				calls[2].done("newer")
				local renders = state.renders
				calls[1].done("older")
				calls[1].done(nil, "stale failure")
				assert(state.lazyvcs_commit_drafts[repo.root] == "newer", "older AI response replaced newer draft")
				assert(state.renders == renders and #notices == 0, "obsolete AI callback affected UI")
			end),
		},
		{
			"test_source_control_ai_preserves_submitted_draft",
			guarded(function(calls, _, state_for)
				local state, node, repo = state_for()
				for _, text in ipairs({ "manual draft", "manual draft" }) do
					ops.generate_commit_message(state, node)
					submit(state, node, text)
					calls[#calls].done("generated")
					assert(state.lazyvcs_commit_drafts[repo.root] == text, "AI replaced submitted draft")
					assert(calls[#calls].cancelled == 1, "submission did not cancel AI request")
				end
			end),
		},
		{
			"test_source_control_ai_commit_clear_invalidates_pending",
			guarded(function(calls, _, state_for)
				local f = h.make_git_fixture()
				h.exec({ "git", "add", "sample.txt" }, f.root)
				local state, node = state_for(f.root)
				state.lazyvcs_commit_drafts[f.root] = "manual commit"
				ops.generate_commit_message(state, node)
				ops.commit_repo(state, node)
				wait(function()
					return not require("lazyvcs.state").get_repo_job(f.root)
				end, "commit did not finish", 15000)
				calls[1].done("obsolete")
				assert(state.lazyvcs_commit_drafts[f.root] == "", "late AI response repopulated committed draft")
			end),
		},
		{
			"test_source_control_ai_close_cancels_generation",
			guarded(function(calls, notices)
				local state, node, f = native_state()
				ops.generate_commit_message(state, node)
				native.close()
				calls[1].done("late")
				assert(
					calls[1].cancelled == 1 and state.lazyvcs_commit_drafts[f.root] == nil,
					"sidebar close retained AI generation"
				)
				assert(#notices == 0, "closed generation reported an error")
			end),
		},
		{
			"test_source_control_ai_path_change_cancels_generation",
			guarded(function(calls)
				local state, node, f = native_state()
				ops.generate_commit_message(state, node)
				native.open({ path = h.tempdir() })
				calls[1].done("late")
				assert(
					calls[1].cancelled == 1 and not state.lazyvcs_commit_drafts[f.root],
					"sidebar path change retained AI generation"
				)
			end),
		},
		{
			"test_source_control_ai_explicit_cancel_stops_provider",
			guarded(function(calls, _, state_for)
				local state, node, repo = state_for()
				ops.generate_commit_message(state, node)
				ops.cancel_repo(state, node)
				calls[1].done("late")
				assert(
					calls[1].cancelled == 1 and not state.lazyvcs_commit_drafts[repo.root],
					"repository cancel retained AI provider"
				)
				ops.generate_commit_message(state, node)
				ops.cancel(repo.root, { all_owners = true })
				assert(calls[2].cancelled == 1, "command cancellation retained AI provider")
			end),
		},
		{
			"test_source_control_ai_synchronous_completion_detaches_handle",
			guarded(function(calls, _, state_for)
				local state, node, repo = state_for()
				local generate = ai.generate
				---@diagnostic disable-next-line: duplicate-set-field
				ai.generate = function(target, done)
					local task = generate(target, done)
					done("synchronous")
					return task
				end
				ops.generate_commit_message(state, node)
				assert(state.lazyvcs_commit_drafts[repo.root] == "synchronous")
				assert(calls[1].cancelled == 1, "finished request handle remained attached")
				ai.generate = generate
				ops.generate_commit_message(state, node)
				calls[1].done("obsolete")
				ops.cancel_repo(state, node)
				assert(calls[2].cancelled == 1, "obsolete callback detached newer handle")
			end),
		},
		{
			"test_source_control_ai_state_and_root_ownership",
			guarded(function(calls, _, state_for)
				local a, node, repo = state_for()
				local b = state_for(repo.root)
				local other = h.tempdir()
				a.lazyvcs_repo_cache[other] = { root = other, vcs = "git", name = "other" }
				ops.generate_commit_message(a, node)
				ops.generate_commit_message(b, node)
				ops.generate_commit_message(a, { path = other })
				submit(a, node, "manual")
				calls[1].done("obsolete")
				calls[2].done("state B")
				calls[3].done("root C")
				assert(a.lazyvcs_commit_drafts[repo.root] == "manual", "state/root draft ownership missing")
				assert(b.lazyvcs_commit_drafts[repo.root] == "state B" and a.lazyvcs_commit_drafts[other] == "root C")
			end),
		},
	}
end
