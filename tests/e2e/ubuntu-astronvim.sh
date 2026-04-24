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

printf 'lazyvcs AstroNvim E2E\n'
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
      "lewis6991/gitsigns.nvim",
      { "nvim-neo-tree/neo-tree.nvim", branch = "v3.x" },
    },
    cmd = {
      "LazyVcsDiffOpen",
      "LazyVcsDiffClose",
      "LazyVcsDiffToggle",
      "LazyVcsDiffRefresh",
      "LazyVcsRevertHunk",
      "LazyVcsNextHunk",
      "LazyVcsPrevHunk",
      "LazyVcsSourceControlProfile",
      "VcsLiveDiffOpen",
    },
    opts = {
      source_control = {
        enabled = true,
        scan_depth = 3,
        show_clean = true,
        remote_refresh = "on_open",
        remote_refresh_interval_ms = 60000,
        selector_label = "VCS",
        background = {
          git_workers = 4,
          svn_workers = 1,
          status_timeout_ms = 30000,
          remote_timeout_ms = 30000,
          switch_timeout_ms = 30000,
          mutation_timeout_ms = 0,
          history_limit = 100,
        },
      },
    },
  },
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    opts = function(_, opts)
      local icon = "󰊢 "
      local ok, astroui = pcall(require, "astroui")
      if ok then
        icon = astroui.get_icon("Git", 1, true)
      end

      opts.sources = opts.sources or {}
      local function ensure_source(source)
        for _, item in ipairs(opts.sources) do
          if item == source then
            return
          end
        end
        opts.sources[#opts.sources + 1] = source
      end

      ensure_source("git_status")
      ensure_source("lazyvcs.source_control")

      opts.source_selector = opts.source_selector or {}
      opts.source_selector.sources = opts.source_selector.sources or {}
      local replaced = false
      for index, item in ipairs(opts.source_selector.sources) do
        if item.source == "git_status" then
          opts.source_selector.sources[index] = {
            source = "lazyvcs_source_control",
            display_name = icon .. "VCS",
          }
          replaced = true
        end
      end
      if not replaced then
        opts.source_selector.sources[#opts.source_selector.sources + 1] = {
          source = "lazyvcs_source_control",
          display_name = icon .. "VCS",
        }
      end
    end,
  },
}
LUA

run_logged lazy-sync timeout 360s nvim --headless "+Lazy! sync" "+qa"
run_logged plugin-registration timeout 180s nvim --headless "+Lazy! sync" \
	"+lua local plugin = require('lazy.core.config').plugins['lazyvcs.nvim']; assert(plugin and plugin.dir == '/work/lazyvcs.nvim', 'lazyvcs.nvim is not registered from the mounted plugin path')" \
	"+qa"
run_logged dependency-contract timeout 60s bash -lc '
	set -Eeuo pipefail
	neo_tree="${XDG_DATA_HOME}/nvim/lazy/neo-tree.nvim"
	printf "neo-tree branch: "
	git -C "${neo_tree}" branch --show-current || true
	printf "neo-tree head: "
	git -C "${neo_tree}" rev-parse --short HEAD
	test -f "${neo_tree}/lua/neo-tree/ui/renderer.lua"
'
run_logged checkhealth timeout 180s nvim --headless "+checkhealth lazyvcs" "+checkhealth neo-tree" "+qa"

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

cat >/tmp/lazyvcs-source-control-smoke-body.lua <<'LUA'
local workspace = assert(vim.env.LAZYVCS_E2E_WORKSPACE, "missing LAZYVCS_E2E_WORKSPACE")
local plugin_root = "/work/lazyvcs.nvim"
local lazy_root = assert(vim.env.XDG_DATA_HOME, "missing XDG_DATA_HOME") .. "/nvim/lazy"

local function add_runtime(path)
  vim.opt.runtimepath:append(path)
  package.path = table.concat({
    path .. "/lua/?.lua",
    path .. "/lua/?/init.lua",
    package.path,
  }, ";")
end

vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

for _, dep in ipairs({
  "plenary.nvim",
  "nui.nvim",
  "neo-tree.nvim",
  "gitsigns.nvim",
}) do
  add_runtime(lazy_root .. "/" .. dep)
end

vim.cmd("runtime plugin/lazyvcs.lua")

require("lazyvcs").setup({
  source_control = {
    scan_depth = 3,
    show_clean = true,
    remote_refresh = "manual",
  },
})

assert(vim.fn.exists(":LazyVcsDiffOpen") == 2, "LazyVcsDiffOpen command missing")
assert(vim.fn.exists(":LazyVcsSourceControlProfile") == 2, "LazyVcsSourceControlProfile command missing")

local source = require("lazyvcs.source_control.init")
assert(source.name == "lazyvcs_source_control", "unexpected source name")

local model = require("lazyvcs.source_control.model")
local repos = model.discover(workspace, 3)
assert(#repos == 2, "expected two discovered repos, got " .. tostring(#repos))

local seen = {}
local state = {
  path = workspace,
  lazyvcs_show_clean = true,
  lazyvcs_repo_cache = {},
}

for _, repo in ipairs(repos) do
  seen[repo.vcs] = true
  local summary, summary_err = model.load_repo_summary(repo, {
    remote_refresh = false,
    status_timeout_ms = 30000,
    remote_timeout_ms = 30000,
  })
  assert(summary, repo.name .. " summary failed: " .. tostring(summary_err))
  assert(summary.summary_loaded == true, repo.name .. " summary did not mark loaded")
  assert(summary.counts.local_changes > 0, repo.name .. " should have local changes")

  local details, details_err = model.load_repo_details(repo, {
    remote_refresh = false,
    status_timeout_ms = 30000,
    remote_timeout_ms = 30000,
  })
  assert(details, repo.name .. " details failed: " .. tostring(details_err))
  assert(details.details_loaded == true, repo.name .. " details did not mark loaded")
  state.lazyvcs_repo_cache[repo.root] = details
end

assert(seen.git, "git repo not discovered")
assert(seen.svn, "svn repo not discovered")

local root = model.collect(state, {
  root = workspace,
  scan_depth = 3,
})
assert(root.extra.repo_count == 2, "collected root should expose two repos")

local components = require("lazyvcs.source_control.components")
local root_meta = components.root_meta({}, {
  type = "root",
  extra = {
    hydration_active = true,
    hydration_pending = 2,
  },
}, {}, 4)
assert(root_meta and root_meta.text == "󰑓", "refresh indicator should be one quiet icon")

local changes_meta = components.repo_changes_meta({}, {
  type = "repo_changes",
  name = "fixture",
  extra = {
    branch = " feature/example",
    counts = {},
    sync = { text = "", status = "synced", highlight = "Comment" },
  },
}, {}, 30)
assert(changes_meta and changes_meta.text:sub(1, 1) == " ", "branch metadata should keep a leading space")

print("lazyvcs source-control smoke ok")
LUA

cat >/tmp/lazyvcs-source-control-smoke.lua <<'LUA'
local ok, err = xpcall(function()
  dofile("/tmp/lazyvcs-source-control-smoke-body.lua")
end, debug.traceback)

if not ok then
  print(err)
  vim.cmd("cquit 1")
end

vim.cmd("qa")
LUA

run_logged source-control-smoke env LAZYVCS_E2E_WORKSPACE="${WORKSPACE}" \
	timeout 180s nvim --headless -u NONE "+luafile /tmp/lazyvcs-source-control-smoke.lua"

run_logged tty-smoke timeout 120s script -q -e -c \
	"env LAZYVCS_E2E_WORKSPACE='${WORKSPACE}' nvim '+Neotree source=lazyvcs_source_control dir=${WORKSPACE}' '+sleep 1500m' '+qa!'" \
	/artifacts/tty-smoke.typescript

if [ -n "${KEEP_E2E_HOME}" ]; then
	cp -a "${HOME}" /artifacts/home
fi

log "complete"
printf 'Artifacts written to /artifacts\n'
CONTAINER

printf '\nContainer E2E completed. Artifacts: %s\n' "${ARTIFACT_DIR}"
