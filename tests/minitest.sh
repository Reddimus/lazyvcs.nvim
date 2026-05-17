#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MINI_TEST_PATH="${MINI_TEST_PATH:-${REPO_ROOT}/deps/mini.nvim}"

if [ ! -d "${MINI_TEST_PATH}/.git" ]; then
	mkdir -p "$(dirname "${MINI_TEST_PATH}")"
	git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim "${MINI_TEST_PATH}"
fi

MINI_TEST_PATH="${MINI_TEST_PATH}" nvim --headless -u NONE -l "${REPO_ROOT}/tests/minitest.lua"
