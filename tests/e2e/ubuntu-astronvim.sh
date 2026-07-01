#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
NVIM_VERSION="${NVIM_VERSION:-v0.12.2}"
ASTRONVIM_TEMPLATE_REF="${ASTRONVIM_TEMPLATE_REF:-}"
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
	-e "ASTRONVIM_TEMPLATE_REF=${ASTRONVIM_TEMPLATE_REF}" \
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
	local asset

	for asset in nvim-linux-x86_64.tar.gz nvim-linux64.tar.gz; do
		if curl -fsSL "${base}/${asset}" -o "${archive}"; then
			break
		fi
	done

	if [ ! -s "${archive}" ]; then
		printf 'failed to download Neovim release %s\n' "${NVIM_VERSION}" >&2
		return 1
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
if [ -n "${ASTRONVIM_TEMPLATE_REF}" ]; then
	git clone --depth 1 --branch "${ASTRONVIM_TEMPLATE_REF}" \
		https://github.com/AstroNvim/template "${XDG_CONFIG_HOME}/nvim"
else
	git clone --depth 1 https://github.com/AstroNvim/template "${XDG_CONFIG_HOME}/nvim"
fi
rm -rf "${XDG_CONFIG_HOME}/nvim/.git"
rm -f "${XDG_CONFIG_HOME}/nvim/lazy-lock.json"

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
    cmd = {
      "LazyVcsDiffOpen",
      "LazyVCSDiffOpen",
      "LazyVcsDiffClose",
      "LazyVCSDiffClose",
      "LazyVcsDiffToggle",
      "LazyVCSDiffToggle",
      "LazyVcsDiffRefresh",
      "LazyVCSDiffRefresh",
      "LazyVcsRevertHunk",
      "LazyVCSRevertHunk",
      "LazyVcsNextHunk",
      "LazyVCSNextHunk",
      "LazyVcsPrevHunk",
      "LazyVCSPrevHunk",
      "LazyVcsSignsRefresh",
      "LazyVCSSignsRefresh",
      "LazyVcsBlame",
      "LazyVCSBlame",
      "LazyVcsBlameSplit",
      "LazyVCSBlameSplit",
      "LazyVcsBlameClear",
      "LazyVCSBlameClear",
      "LazyVcsLineLog",
      "LazyVCSLineLog",
      "LazyVcsPreviewDiff",
      "LazyVCSPreviewDiff",
      "LazyVcsRevertBuffer",
      "LazyVCSRevertBuffer",
      "LazyVcsFiles",
      "LazyVCSFiles",
      "LazyVcsSourceControlOpen",
      "LazyVCSSourceControlOpen",
      "LazyVcsSourceControlClose",
      "LazyVCSSourceControlClose",
      "LazyVcsSourceControlToggle",
      "LazyVCSSourceControlToggle",
      "LazyVcsSourceControlRefresh",
      "LazyVCSSourceControlRefresh",
      "LazyVcsSourceControlProfile",
      "LazyVCSSourceControlProfile",
      "VcsLiveDiffOpen",
      "SvnBlame",
      "SvnLog",
      "SvnPreview",
      "SvnRevert",
      "SvnResetHunk",
      "SvnFiles",
    },
    keys = {
      { "<leader>vs", "<cmd>LazyVcsSourceControlToggle<cr>", desc = "Toggle VCS sidebar" },
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
  assert(vim.fn.exists(":LazyVcsSourceControlToggle") == 2, "LazyVcsSourceControlToggle command missing")
  assert(vim.fn.exists(":LazyVCSSourceControlToggle") == 2, "LazyVCSSourceControlToggle command missing")
  assert(vim.fn.exists(":LazyVcsSourceControlProfile") == 2, "LazyVcsSourceControlProfile command missing")
  assert(vim.fn.exists(":LazyVCSSourceControlProfile") == 2, "LazyVCSSourceControlProfile command missing")
  assert(vim.fn.exists(":LazyVcsBlame") == 2, "LazyVcsBlame command missing")
  assert(vim.fn.exists(":LazyVCSBlame") == 2, "LazyVCSBlame command missing")
  assert(vim.fn.exists(":LazyVcsBlameSplit") == 2, "LazyVcsBlameSplit command missing")
  assert(vim.fn.exists(":LazyVCSBlameSplit") == 2, "LazyVCSBlameSplit command missing")
  assert(vim.fn.exists(":LazyVcsBlameClear") == 2, "LazyVcsBlameClear command missing")
  assert(vim.fn.exists(":LazyVCSBlameClear") == 2, "LazyVCSBlameClear command missing")
  assert(vim.fn.exists(":SvnBlame") == 2, "SvnBlame compatibility command missing")

  require("lazyvcs").source_control_open({ path = workspace })
  local state = assert(require("lazyvcs.source_control.native")._state(), "missing native source-control state")
  assert(vim.api.nvim_buf_is_valid(state.bufnr), "native source-control buffer is invalid")
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

local function append_log(msg)
  local f = assert(io.open(log_path, "a"))
  f:write(os.date("%H:%M:%S"), " ", msg, "\n")
  f:close()
end

local function finish(ok, msg)
  vim.fn.writefile({ (ok and "OK " or "FAIL ") .. msg }, result_path)
  vim.cmd("qa!")
end

local function dump(label)
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

local function assert_wait(ms, predicate, message)
  assert(vim.wait(ms, predicate, 50), message)
end

vim.schedule(function()
  local ok, err = xpcall(function()
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
    assert_wait(3000, function()
      return vim.t.bufs
        and vim.tbl_contains(vim.t.bufs, bufs.alpha)
        and vim.tbl_contains(vim.t.bufs, bufs.added)
        and vim.tbl_contains(vim.t.bufs, bufs.beta)
        and vim.tbl_contains(vim.t.bufs, bufs.scratch)
    end, "AstroNvim buffer list did not include all fixture buffers")
    vim.t.bufs = { bufs.alpha, bufs.added, bufs.beta, bufs.scratch }

    local actions = require("lazyvcs.actions")
    local state = require("lazyvcs.state")
    dump("before open")
    assert(actions.open(), "failed to open initial live diff")
    dump("after open")

    require("astrocore.buffer").nav(1)
    dump("after nav added immediate")
    assert_wait(3000, function()
      local live = state.current()
      return live and live.source_path == files.added and live.base_label == "EMPTY"
    end, "live diff did not transfer to SVN added file")
    dump("after nav added settled")

    require("astrocore.buffer").nav(1)
    dump("after nav beta immediate")
    assert_wait(3000, function()
      local live = state.current()
      return live and live.source_path == files.beta and live.base_label == "BASE"
    end, "live diff did not transfer back to tracked SVN file")
    dump("after nav beta settled")

    require("astrocore.buffer").nav(1)
    dump("after nav scratch immediate")
    assert_wait(3000, function()
      if state.current() ~= nil or #state.list() ~= 0 then
        return false
      end
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:match("^lazyvcs://") or vim.wo[winid].diff then
          return false
        end
      end
      return true
    end, "live diff did not close on unsupported SVN file")
    assert(state.current() == nil, "unsupported SVN file should close live diff")
    assert(#state.list() == 0, "unsupported SVN file should remove live diff sessions")
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local name = vim.api.nvim_buf_get_name(bufnr)
      assert(not name:match("^lazyvcs://"), "stale lazyvcs base window remained")
      assert(not vim.wo[winid].diff, "diff mode should be cleared after unsupported transfer")
    end
    dump("after nav scratch settled")
  end, debug.traceback)

  finish(ok, ok and "buffer navigation smoke passed" or tostring(err))
end)
LUA

buffer_nav_smoke() {
	local sock="/tmp/lazyvcs-buffer-nav.sock"
	local result="/tmp/lazyvcs-buffer-nav-result"
	local ui_log="/artifacts/buffer-nav-smoke-ui.log"
	local typescript="/artifacts/buffer-nav-smoke-ui.typescript"

	export LAZYVCS_E2E_SVN_NAV_WC="${SVN_NAV_WC}"
	rm -f "${sock}" "${result}" /tmp/lazyvcs-buffer-nav-state.log
	timeout 180s script -qefc \
		"nvim --listen '${sock}' '${SVN_NAV_WC}/alpha.cpp'" \
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
	for _ in $(seq 1 240); do
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
