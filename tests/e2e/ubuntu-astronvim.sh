#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90}"
NVIM_VERSION="${NVIM_VERSION:-v0.12.4}"
NVIM_SHA256="${NVIM_SHA256:-012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628}"
ASTRONVIM_TEMPLATE_REF="${ASTRONVIM_TEMPLATE_REF:-49a7161b776f8bc6c23508819ea1ad4e7b359bee}"
ASTRONVIM_VERSION="${ASTRONVIM_VERSION:-6.0.5}"
ASTRONVIM_COMMIT="${ASTRONVIM_COMMIT-35966a16caefeb8f3a9dcb1a91f89ada8f3edc77}"
KEEP_E2E_HOME="${KEEP_E2E_HOME:-}"

if ! command -v docker >/dev/null 2>&1; then
	printf 'docker is required for the AstroNvim E2E test\n' >&2
	exit 1
fi

if [ -n "${E2E_ARTIFACT_DIR:-}" ]; then
	ARTIFACT_DIR="${E2E_ARTIFACT_DIR}"
	mkdir -p "${ARTIFACT_DIR}"
else
	ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lazyvcs-astronvim-e2e.XXXXXX")"
fi

printf 'lazyvcs AstroNvim native E2E\n'
printf '  repo:      %s\n' "${REPO_ROOT}"
printf '  image:     %s\n' "${UBUNTU_IMAGE}"
printf '  nvim:      %s\n' "${NVIM_VERSION}"
printf '  artifacts: %s\n' "${ARTIFACT_DIR}"

docker run --rm -i \
	-e "NVIM_VERSION=${NVIM_VERSION}" \
	-e "NVIM_SHA256=${NVIM_SHA256}" \
	-e "ASTRONVIM_TEMPLATE_REF=${ASTRONVIM_TEMPLATE_REF}" \
	-e "ASTRONVIM_VERSION=${ASTRONVIM_VERSION}" \
	-e "ASTRONVIM_COMMIT=${ASTRONVIM_COMMIT}" \
	-e "KEEP_E2E_HOME=${KEEP_E2E_HOME}" \
	-v "${REPO_ROOT}:/work/lazyvcs.nvim:ro" \
	-v "${ARTIFACT_DIR}:/artifacts" \
	"${UBUNTU_IMAGE}" bash -s <<'CONTAINER'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TERM=xterm-256color

log() {
	printf '\n==> %s\n' "$*"
}

run_logged() {
	local name="$1"
	shift
	log "$name"
	if ! "$@" >"/artifacts/${name}.log" 2>&1; then
		printf '\n%s failed; first 220 log lines:\n' "$name" >&2
		sed -n '1,220p' "/artifacts/${name}.log" >&2 || true
		return 1
	fi
}

install_nvim() {
	local base="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}"
	local archive="/tmp/nvim.tar.gz"
	local asset="nvim-linux-x86_64.tar.gz"

	curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
		"${base}/${asset}" -o "${archive}"
	if [ -n "${NVIM_SHA256}" ]; then
		printf '%s  %s\n' "${NVIM_SHA256}" "${archive}" | sha256sum --check -
	fi

	mkdir -p /opt/nvim
	tar -C /opt/nvim --strip-components=1 -xzf "${archive}"
	ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
	nvim --version | sed -n '1,3p'
}

log "install ubuntu packages"
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates \
	build-essential \
	curl \
	fd-find \
	git \
	gzip \
	locales \
	ripgrep \
	subversion \
	tar \
	unzip \
	util-linux \
	xz-utils
locale-gen en_US.UTF-8 >/dev/null

log "install neovim"
install_nvim

export HOME=/tmp/lazyvcs-e2e/home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_CACHE_HOME="${HOME}/.cache"

rm -rf "${HOME}"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_STATE_HOME}" "${XDG_CACHE_HOME}"

git config --global init.defaultBranch main
git config --global user.name "lazyvcs e2e"
git config --global user.email "lazyvcs-e2e@example.invalid"
git config --global advice.detachedHead false

log "install AstroNvim template"
git -C "${XDG_CONFIG_HOME}" init nvim
git -C "${XDG_CONFIG_HOME}/nvim" remote add origin https://github.com/AstroNvim/template
git -C "${XDG_CONFIG_HOME}/nvim" fetch --depth 1 origin "${ASTRONVIM_TEMPLATE_REF}"
git -C "${XDG_CONFIG_HOME}/nvim" checkout --detach FETCH_HEAD
test "$(git -C "${XDG_CONFIG_HOME}/nvim" rev-parse HEAD)" = "${ASTRONVIM_TEMPLATE_REF}"
rm -rf "${XDG_CONFIG_HOME}/nvim/.git"
rm -f "${XDG_CONFIG_HOME}/nvim/lazy-lock.json"
sed -i "s/version = \"\\^6\"/version = \"${ASTRONVIM_VERSION}\"/" \
	"${XDG_CONFIG_HOME}/nvim/lua/lazy_setup.lua"

mkdir -p "${XDG_CONFIG_HOME}/nvim/lua/plugins"
cat >"${XDG_CONFIG_HOME}/nvim/lua/plugins/lazyvcs.lua" <<'LUA'
return {
  {
    dir = "/work/lazyvcs.nvim",
    name = "lazyvcs.nvim",
    main = "lazyvcs",
    dependencies = {
      { "lewis6991/gitsigns.nvim", optional = true },
      { "folke/snacks.nvim", optional = true },
      { "ibhagwan/fzf-lua", optional = true },
      { "CopilotC-Nvim/CopilotChat.nvim", optional = true },
    },
    cmd = { "LazyVCS" },
    event = { "BufReadPre", "BufNewFile" },
    keys = {
      { "<leader>vs", "<cmd>LazyVCS sidebar toggle<cr>", desc = "Toggle VCS sidebar" },
    },
    opts = {
      source_control = {
        enabled = true,
        ui = "auto",
        scan_depth = 3,
        show_clean = true,
        remote_refresh = "manual",
        remote_refresh_interval_ms = 60000,
      },
    },
  },
}
LUA

run_logged lazy-sync timeout 360s nvim --headless "+Lazy! sync" "+qa"
if [ -n "${ASTRONVIM_COMMIT}" ]; then
	grep -q "\"AstroNvim\":.*\"commit\": \"${ASTRONVIM_COMMIT}\"" \
		"${XDG_CONFIG_HOME}/nvim/lazy-lock.json"
fi
cp "${XDG_CONFIG_HOME}/nvim/lazy-lock.json" /artifacts/astronvim-lazy-lock.json
run_logged plugin-registration timeout 180s nvim --headless "+Lazy! sync" \
	"+lua local plugin = require('lazy.core.config').plugins['lazyvcs.nvim']; assert(plugin and plugin.dir == '/work/lazyvcs.nvim', 'lazyvcs.nvim is not registered from the mounted plugin path')" \
	"+qa"
run_logged checkhealth timeout 180s nvim --headless "+checkhealth lazyvcs" "+qa"

WORKSPACE=/tmp/lazyvcs-e2e-workspace
SVN_REPO=/tmp/lazyvcs-e2e-svn-store
rm -rf "${WORKSPACE}" "${SVN_REPO}"
mkdir -p "${WORKSPACE}/git-repo"

log "create source-control fixtures"
git -C "${WORKSPACE}/git-repo" init -b main >/dev/null
printf 'staged from e2e\n' >"${WORKSPACE}/git-repo/staged.txt"
git -C "${WORKSPACE}/git-repo" add staged.txt
printf 'untracked from e2e\n' >"${WORKSPACE}/git-repo/untracked.txt"

svnadmin create "${SVN_REPO}"
svn checkout "file://${SVN_REPO}" "${WORKSPACE}/svn-repo" --quiet
printf 'svn added from e2e\n' >"${WORKSPACE}/svn-repo/added.txt"
svn add "${WORKSPACE}/svn-repo/added.txt" --quiet

cat >/tmp/lazyvcs-source-control-smoke.lua <<'LUA'
local ok, err = xpcall(function()
  local workspace = assert(vim.env.LAZYVCS_E2E_WORKSPACE, "missing LAZYVCS_E2E_WORKSPACE")
  assert(vim.fn.exists(":LazyVCS") == 2, "LazyVCS command missing")

  -- The whole surface is one command with subcommand completion; the legacy
  -- per-action and svnsigns-compatibility commands are gone.
  local complete = require("lazyvcs.commands")._complete
  local top_level = complete("", "LazyVCS ")
  for _, name in ipairs({ "blame", "diff", "hunk", "sidebar", "signs", "files", "profile" }) do
    assert(vim.tbl_contains(top_level, name), "missing subcommand completion: " .. name)
  end
  assert(vim.tbl_contains(complete("", "LazyVCS blame "), "split"), "missing 'blame split' completion")
  for _, gone in ipairs({ ":LazyVcsBlame", ":LazyVCSBlame", ":SvnBlame", ":VcsLiveDiffOpen" }) do
    assert(vim.fn.exists(gone) == 0, "legacy command should be removed: " .. gone)
  end

  require("lazyvcs").source_control_open({ path = workspace })
  local state = assert(require("lazyvcs.source_control.native")._state(), "missing native source-control state")
  assert(vim.api.nvim_buf_is_valid(state.bufnr), "native source-control buffer is invalid")

  -- Repository discovery is asynchronous, so the sidebar's first frame reads
  -- "Discovering repositories..." and the rows arrive afterwards. Reading the
  -- buffer straight after `source_control_open` asserted against that first
  -- frame. The Subversion repository in this fixture makes the wait real: it
  -- spawns `svn info` as well as `git rev-parse`.
  assert(vim.wait(60000, function()
    return state.lazyvcs_discovering ~= true and state.lazyvcs_repo_specs ~= nil
  end, 25), "repository discovery did not finish")

  local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
  assert(text:match("Repositories %(2%)"), text)
  assert(text:match("git%-repo"), text)
  assert(text:match("svn%-repo"), text)
  assert(not pcall(require, "lazyvcs.source_control.init"), "removed Neo-tree adapter module should not load")
  require("lazyvcs").source_control_close()
end, debug.traceback)

if not ok then
  print(err)
  vim.cmd("cquit 1")
end

vim.cmd("qa")
LUA

run_logged source-control-smoke env LAZYVCS_E2E_WORKSPACE="${WORKSPACE}" \
	timeout 180s nvim --headless "+luafile /tmp/lazyvcs-source-control-smoke.lua"

SVN_NAV_REPO=/tmp/lazyvcs-e2e-svn-nav-store
SVN_NAV_WC=/tmp/lazyvcs-e2e-svn-nav-wc
rm -rf "${SVN_NAV_REPO}" "${SVN_NAV_WC}"
svnadmin create "${SVN_NAV_REPO}"
svn checkout "file://${SVN_NAV_REPO}" "${SVN_NAV_WC}" --quiet
printf 'one\ntwo\nthree\n' >"${SVN_NAV_WC}/alpha.cpp"
printf 'red\nblue\ngreen\n' >"${SVN_NAV_WC}/beta.cpp"
svn add "${SVN_NAV_WC}/alpha.cpp" "${SVN_NAV_WC}/beta.cpp" --quiet
svn commit "${SVN_NAV_WC}" -m "initial" --quiet
printf 'one\nchanged\nthree\n' >"${SVN_NAV_WC}/alpha.cpp"
printf 'red\nblue\namber\n' >"${SVN_NAV_WC}/beta.cpp"
printf 'new\nfile\n' >"${SVN_NAV_WC}/added.cpp"
svn add "${SVN_NAV_WC}/added.cpp" --quiet
printf 'scratch\nfile\n' >"${SVN_NAV_WC}/scratch.cpp"

cat >/tmp/lazyvcs-buffer-nav-smoke.lua <<'LUA'
local result_path = "/tmp/lazyvcs-buffer-nav-result"
local log_path = "/tmp/lazyvcs-buffer-nav-state.log"

local last_label = "start"

local function append_log(msg)
  local f = assert(io.open(log_path, "a"))
  f:write(os.date("%H:%M:%S"), " ", msg, "\n")
  f:close()
end

local timers = {}
local function stop_timers()
  for _, t in ipairs(timers) do
    pcall(function()
      t:stop()
      t:close()
    end)
  end
  timers = {}
end

local finished = false
local function finish(ok, msg)
  if finished then
    return
  end
  finished = true
  stop_timers()
  append_log((ok and "RESULT OK " or "RESULT FAIL ") .. msg)
  vim.fn.writefile({ (ok and "OK " or "FAIL ") .. msg }, result_path)
  vim.cmd("qa!")
end

local function dump(label)
  last_label = label
  local state = require("lazyvcs.state")
  local live = state.current()
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    wins[#wins + 1] = string.format(
      "%d:%d:%s:diff=%s",
      winid,
      bufnr,
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"),
      tostring(vim.wo[winid].diff)
    )
  end
  append_log(string.format(
    "%s curwin=%d curbuf=%d name=%s live=%s base=%s wins=[%s]",
    label,
    vim.api.nvim_get_current_win(),
    vim.api.nvim_get_current_buf(),
    vim.api.nvim_buf_get_name(0),
    live and live.source_path or "nil",
    live and live.base_label or "nil",
    table.concat(wins, ", ")
  ))
end

-- The plugin performs buffer transfers inside `vim.schedule` callbacks. Polling
-- with a blocking `vim.wait` from within another scheduled callback can starve
-- exactly that work, so every wait here yields to the event loop via defer_fn
-- and the whole driver is written as a callback chain instead of straight-line
-- code with blocking waits.
local function wait_for(label, timeout_ms, predicate, on_ready)
  local deadline = vim.uv.now() + timeout_ms
  local function poll()
    if finished then
      return
    end
    local ok, ready = pcall(predicate)
    if ok and ready then
      return on_ready()
    end
    if vim.uv.now() >= deadline then
      dump("timeout at " .. label)
      return finish(false, label)
    end
    vim.defer_fn(poll, 50)
  end
  poll()
end

-- Heartbeat on the libuv loop. If these entries keep their queued= and written=
-- timestamps close together, the main loop is healthy. If they all flush at once
-- with old queued= stamps, vim.schedule was starved -- which, while libuv timers
-- kept firing, means Neovim was sitting on a modal prompt rather than busy.
local heartbeat = vim.uv.new_timer()
timers[#timers + 1] = heartbeat
local ticks = 0
heartbeat:start(2000, 2000, function()
  ticks = ticks + 1
  local tick, queued_at = ticks, os.date("%H:%M:%S")
  vim.schedule(function()
    append_log(string.format("heartbeat %d queued=%s checkpoint=%s", tick, queued_at, last_label))
  end)
end)

-- Global watchdog: the driver must always produce a verdict, even if a step
-- never calls back.
local watchdog = vim.uv.new_timer()
timers[#timers + 1] = watchdog
watchdog:start(90000, 0, function()
  vim.schedule(function()
    finish(false, "watchdog fired after 90s; last checkpoint: " .. last_label)
  end)
end)

local function main()
  vim.fn.writefile({}, log_path)
  local wc = assert(vim.env.LAZYVCS_E2E_SVN_NAV_WC, "missing LAZYVCS_E2E_SVN_NAV_WC")
  require("lazy").load({ plugins = { "lazyvcs.nvim" } })

  local files = {
    alpha = wc .. "/alpha.cpp",
    added = wc .. "/added.cpp",
    beta = wc .. "/beta.cpp",
    scratch = wc .. "/scratch.cpp",
  }
  local bufs = {}
  for _, key in ipairs({ "alpha", "added", "beta", "scratch" }) do
    vim.cmd.edit(vim.fn.fnameescape(files[key]))
    bufs[key] = vim.api.nvim_get_current_buf()
  end
  vim.api.nvim_set_current_buf(bufs.alpha)
  vim.t.bufs = { bufs.alpha, bufs.added, bufs.beta, bufs.scratch }

  local actions = require("lazyvcs.actions")
  local state = require("lazyvcs.state")

  local function no_stale_diff_windows()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.api.nvim_buf_get_name(bufnr):match("^lazyvcs://") or vim.wo[winid].diff then
        return false
      end
    end
    return true
  end

  dump("before open")
  -- actions.open resolves the backend off the UI thread and returns a
  -- cancellable task, not a session, so the diff is not live on return.
  -- Navigating before it completes deliberately abandons the open, so wait for
  -- the session to exist before driving buffer navigation.
  actions.open()
  wait_for("failed to open initial live diff", 15000, function()
    local live = state.current()
    return live ~= nil and live.source_path == files.alpha
  end, function()
    dump("after open")

    -- added.cpp is scheduled for addition in SVN: it has no BASE, so the live diff
    -- must reopen against an empty base.
    require("astrocore.buffer").nav(1)
    dump("after nav added immediate")
    wait_for("live diff did not transfer to SVN added file", 15000, function()
      local live = state.current()
      return live and live.source_path == files.added and live.base_label == "EMPTY"
    end, function()
      dump("after nav added settled")

      require("astrocore.buffer").nav(1)
      dump("after nav beta immediate")
      wait_for("live diff did not transfer back to tracked SVN file", 15000, function()
        local live = state.current()
        return live and live.source_path == files.beta and live.base_label == "BASE"
      end, function()
        dump("after nav beta settled")

        require("astrocore.buffer").nav(1)
        dump("after nav scratch immediate")
        wait_for("live diff did not close on unsupported SVN file", 15000, function()
          return state.current() == nil and #state.list() == 0 and no_stale_diff_windows()
        end, function()
          dump("after nav scratch settled")
          finish(true, "buffer navigation smoke passed")
        end)
      end)
    end)
  end)
end

-- Run on the main loop rather than inside a scheduled callback.
local ok, err = xpcall(main, debug.traceback)
if not ok then
  finish(false, tostring(err))
end
LUA

buffer_nav_smoke() {
	local sock="/tmp/lazyvcs-buffer-nav.sock"
	local result="/tmp/lazyvcs-buffer-nav-result"
	local ui_log="/artifacts/buffer-nav-smoke-ui.log"
	local typescript="/artifacts/buffer-nav-smoke-ui.typescript"

	export LAZYVCS_E2E_SVN_NAV_WC="${SVN_NAV_WC}"
	rm -f "${sock}" "${result}" /tmp/lazyvcs-buffer-nav-state.log
	# The pty must have a real size and Neovim must never open a modal prompt.
	#
	# `script` runs without a controlling terminal in CI, so the pty it allocates
	# has a degenerate size. With a ~0-row message area every message overflows and
	# Neovim stops at the hit-enter prompt, which blocks vim.schedule callbacks
	# while libuv timers keep running -- indistinguishable from a deadlock, and
	# intermittent because it depends on whether anything printed a message.
	# `stty` fixes the geometry; the --cmd flags remove the remaining modal
	# prompts (swapfile ATTENTION, hit-enter, more-prompt) so a stray message can
	# never wedge the run.
	timeout 180s script -qefc \
		"stty rows 60 cols 200; nvim \
			--cmd 'set noswapfile' \
			--cmd 'set shortmess+=aoOtTAIcF' \
			--cmd 'set nomore' \
			--cmd 'set cmdheight=10' \
			--listen '${sock}' '${SVN_NAV_WC}/alpha.cpp'" \
		"${typescript}" >"${ui_log}" 2>&1 &
	local nvim_pid=$!

	for _ in $(seq 1 120); do
		if [ -S "${sock}" ]; then
			break
		fi
		if ! kill -0 "${nvim_pid}" 2>/dev/null; then
			wait "${nvim_pid}" || true
			printf 'interactive AstroNvim exited before creating %s\n' "${sock}" >&2
			return 1
		fi
		sleep 0.25
	done
	if [ ! -S "${sock}" ]; then
		kill "${nvim_pid}" 2>/dev/null || true
		wait "${nvim_pid}" || true
		printf 'timed out waiting for interactive AstroNvim socket %s\n' "${sock}" >&2
		return 1
	fi

	nvim --server "${sock}" --remote-send '<Esc>:luafile /tmp/lazyvcs-buffer-nav-smoke.lua<CR>'
	for _ in $(seq 1 600); do
		if [ -f "${result}" ]; then
			break
		fi
		if ! kill -0 "${nvim_pid}" 2>/dev/null; then
			break
		fi
		sleep 0.25
	done

	if [ ! -f "${result}" ]; then
		kill "${nvim_pid}" 2>/dev/null || true
		wait "${nvim_pid}" || true
		printf 'interactive AstroNvim did not produce a buffer navigation result\n' >&2
		cat /tmp/lazyvcs-buffer-nav-state.log >&2 2>/dev/null || true
		return 1
	fi

	wait "${nvim_pid}" || true
	cat /tmp/lazyvcs-buffer-nav-state.log >&2 2>/dev/null || true
	if grep -q '^OK ' "${result}"; then
		return 0
	fi
	cat "${result}" >&2
	return 1
}

run_logged buffer-nav-smoke buffer_nav_smoke

if [ -n "${KEEP_E2E_HOME}" ]; then
	cp -a "${HOME}" /artifacts/home
fi

log "complete"
printf 'Artifacts written to /artifacts\n'
CONTAINER

printf '\nContainer E2E completed. Artifacts: %s\n' "${ARTIFACT_DIR}"
