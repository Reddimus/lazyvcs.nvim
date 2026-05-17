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
      "LazyVcsDiffClose",
      "LazyVcsDiffToggle",
      "LazyVcsDiffRefresh",
      "LazyVcsRevertHunk",
      "LazyVcsNextHunk",
      "LazyVcsPrevHunk",
      "LazyVcsSignsRefresh",
      "LazyVcsBlame",
      "LazyVcsBlameSplit",
      "LazyVcsBlameClear",
      "LazyVcsLineLog",
      "LazyVcsPreviewDiff",
      "LazyVcsRevertBuffer",
      "LazyVcsFiles",
      "LazyVcsSourceControlOpen",
      "LazyVcsSourceControlClose",
      "LazyVcsSourceControlToggle",
      "LazyVcsSourceControlRefresh",
      "LazyVcsSourceControlProfile",
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
  assert(vim.fn.exists(":LazyVcsSourceControlProfile") == 2, "LazyVcsSourceControlProfile command missing")
  assert(vim.fn.exists(":LazyVcsBlame") == 2, "LazyVcsBlame command missing")
  assert(vim.fn.exists(":LazyVcsBlameSplit") == 2, "LazyVcsBlameSplit command missing")
  assert(vim.fn.exists(":LazyVcsBlameClear") == 2, "LazyVcsBlameClear command missing")
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

if [ -n "${KEEP_E2E_HOME}" ]; then
	cp -a "${HOME}" /artifacts/home
fi

log "complete"
printf 'Artifacts written to /artifacts\n'
CONTAINER

printf '\nContainer E2E completed. Artifacts: %s\n' "${ARTIFACT_DIR}"
