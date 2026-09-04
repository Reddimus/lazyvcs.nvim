#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90}"
NVIM_VERSION="${NVIM_VERSION:-v0.12.4}"
NVIM_SHA256="${NVIM_SHA256-012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628}"

if ! command -v docker >/dev/null 2>&1; then
	printf 'docker is required for the native E2E test\n' >&2
	exit 1
fi

ARTIFACT_DIR="${E2E_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/lazyvcs-native-e2e.XXXXXX")}"
mkdir -p "${ARTIFACT_DIR}"

docker run --rm -i \
	-e "NVIM_VERSION=${NVIM_VERSION}" \
	-e "NVIM_SHA256=${NVIM_SHA256}" \
	-v "${REPO_ROOT}:/work/lazyvcs.nvim:ro" \
	-v "${ARTIFACT_DIR}:/artifacts" \
	"${UBUNTU_IMAGE}" bash -s <<'CONTAINER'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TERM=xterm-256color

apt-get update >/artifacts/apt.log
apt-get install -y --no-install-recommends ca-certificates curl git gzip locales python3 python3-pexpect subversion tar >/artifacts/packages.log
locale-gen en_US.UTF-8 >/dev/null

archive=/tmp/nvim.tar.gz
base="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}"
curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
	"${base}/nvim-linux-x86_64.tar.gz" -o "${archive}"
if [ -n "${NVIM_SHA256}" ]; then
	printf '%s  %s\n' "${NVIM_SHA256}" "${archive}" | sha256sum --check -
fi
mkdir -p /opt/nvim
tar -C /opt/nvim --strip-components=1 -xzf "${archive}"
ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
nvim --version | sed -n '1,5p' >/artifacts/nvim-version.log

export HOME=/tmp/lazyvcs-native/home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"
export XDG_CACHE_HOME="${HOME}/.cache"
mkdir -p "${XDG_CONFIG_HOME}/nvim" "${XDG_DATA_HOME}" "${XDG_STATE_HOME}" "${XDG_CACHE_HOME}"

cat >"${XDG_CONFIG_HOME}/nvim/init.lua" <<'LUA'
vim.opt.runtimepath:prepend("/work/lazyvcs.nvim")
vim.cmd.runtime("plugin/lazyvcs.lua")
require("lazyvcs").setup({
  source_control = {
    ui = "native",
    show_clean = true,
    remote_refresh = "manual",
    confirm_mutations = false,
  },
})
LUA

workspace=/tmp/lazyvcs-native/workspace
repo="${workspace}/team-a/integrated-solutions-rdk-webserver"
mkdir -p "${repo}"
git -C "${repo}" init >/dev/null
printf 'changed from native e2e\n' >"${repo}/changed.txt"

# Discovery is asynchronous: the sidebar's first frame reads
# "Discovering repositories..." and the rows arrive after it, so the buffer
# has to be sampled once discovery has settled rather than immediately.
nvim --headless \
	"+lua require('lazyvcs').source_control_open({ path = '${workspace}' }); local state = require('lazyvcs.source_control.native')._state(); assert(state and vim.api.nvim_buf_is_valid(state.bufnr)); assert(vim.wait(60000, function() return state.lazyvcs_discovering ~= true and state.lazyvcs_repo_specs ~= nil end, 25), 'discovery did not finish'); local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), '\n'); assert(text:match('integrated%-solutions'), text)" \
	"+checkhealth lazyvcs" \
	"+qa" >/artifacts/native-smoke.log 2>&1

cat >/tmp/lazyvcs-pty-smoke.py <<'PY'
import os
import pathlib
import time

import pexpect

workspace = os.environ["LAZYVCS_E2E_WORKSPACE"]
artifact_dir = pathlib.Path("/artifacts")
env = os.environ.copy()
env.update({
    "TERM": "xterm-256color",
    "COLUMNS": "120",
    "LINES": "40",
})

child = pexpect.spawn(
    "nvim",
    ["--clean", "-u", os.path.join(env["XDG_CONFIG_HOME"], "nvim", "init.lua")],
    cwd=workspace,
    env=env,
    dimensions=(40, 120),
    encoding="utf-8",
    timeout=30,
)

def ex(command):
    child.send("\x1b")
    child.sendline(":" + command)

def wait_file(name):
    path = artifact_dir / name
    for _ in range(80):
        if path.exists():
            return path.read_text(encoding="utf-8").strip()
        time.sleep(0.1)
    raise AssertionError(f"missing artifact {path}")

# Sidebar rendering is coalesced and scheduled, so the width does not change
# during the keypress that triggers it. Sampling immediately after `child.send`
# reads the pre-render width, so wait inside Neovim for the width itself to
# settle rather than sleeping for an arbitrary interval. `settle` is a Lua
# comparison against the previous width; on timeout the current width is still
# recorded and the assertion below reports the real value.
def write_width(name, settle="~= nil"):
    ex(
        "lua local function w() "
        "local s = require('lazyvcs.source_control.native')._state(); "
        "if not (s and s.winid and vim.api.nvim_win_is_valid(s.winid)) then return -1 end; "
        "return vim.api.nvim_win_get_width(s.winid) end "
        f"vim.wait(8000, function() return w() {settle} end, 50); "
        f"vim.fn.writefile({{tostring(w())}}, '/artifacts/{name}')"
    )
    return int(wait_file(name))

try:
    ex("LazyVCS sidebar open " + workspace)
    child.expect("integrated", timeout=30)

    before = write_width("pty-width-before.txt")
    child.send("e")
    after = write_width("pty-width-after.txt", settle=f"> {before}")
    child.send("e")
    restored = write_width("pty-width-restored.txt", settle=f"== {before}")

    if not after > before:
        raise AssertionError(f"expected e to expand sidebar: before={before} after={after}")
    if restored != before:
        raise AssertionError(f"expected second e to restore width: before={before} restored={restored}")
finally:
    child.sendline(":qa!")
    child.expect(pexpect.EOF, timeout=30)
PY

LAZYVCS_E2E_WORKSPACE="${workspace}" python3 /tmp/lazyvcs-pty-smoke.py >/artifacts/pty-smoke.log 2>&1
CONTAINER

printf 'lazyvcs native E2E artifacts: %s\n' "${ARTIFACT_DIR}"
