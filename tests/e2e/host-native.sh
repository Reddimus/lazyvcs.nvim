#!/usr/bin/env bash
# Exercise the native terminal UI on the current host without user config.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
PYTHON="${LAZYVCS_E2E_PYTHON:-python3}"
"${PYTHON}" -c 'import pexpect'
state="$(mktemp -d "${TMPDIR:-/tmp}/lazyvcs-host.XXXXXX")"
trap 'rm -rf -- "${state}"' EXIT
ARTIFACT_DIR="${E2E_ARTIFACT_DIR:-${REPO_ROOT}/artifacts/host-e2e}"
mkdir -p "${ARTIFACT_DIR}" "${state}/config/nvim"
export XDG_CONFIG_HOME="${state}/config" XDG_DATA_HOME="${state}/data"
export XDG_STATE_HOME="${state}/state" XDG_CACHE_HOME="${state}/cache"
export LAZYVCS_E2E_PLUGIN_ROOT="${REPO_ROOT}"
cat >"${XDG_CONFIG_HOME}/nvim/init.lua" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.LAZYVCS_E2E_PLUGIN_ROOT)
vim.cmd.runtime("plugin/lazyvcs.lua")
vim.g.mapleader = " "
vim.keymap.set("n", "<leader>vc", "<cmd>LazyVCS compare<cr>")
vim.keymap.set("n", "<leader>vC", "<cmd>LazyVCS compare base<cr>")
require("lazyvcs").setup({ source_control = { ui = "native", remote_refresh = "manual", confirm_mutations = false } })
LUA
nvim --version >"${ARTIFACT_DIR}/neovim-version.log"
svn --version --quiet >"${ARTIFACT_DIR}/svn-version.log"
"${PYTHON}" "${SCRIPT_DIR}/compare.py" "${ARTIFACT_DIR}/compare" >"${ARTIFACT_DIR}/compare.log" 2>&1
"${PYTHON}" "${SCRIPT_DIR}/blame.py" "${ARTIFACT_DIR}/blame" >"${ARTIFACT_DIR}/blame.log" 2>&1
printf 'Native host Compare and SVN blame E2E passed\n'
