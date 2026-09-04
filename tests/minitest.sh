#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MINI_TEST_COMMIT="${MINI_TEST_COMMIT:-2df201d9b217bc0ad54e5d077fc4c228e6e4ef96}"
MINI_TEST_PATH="${MINI_TEST_PATH:-${REPO_ROOT}/deps/mini.nvim-v0.18.0}"

if [ ! -d "${MINI_TEST_PATH}/.git" ]; then
	mkdir -p "${MINI_TEST_PATH}"
	git -C "${MINI_TEST_PATH}" init
	git -C "${MINI_TEST_PATH}" remote add origin https://github.com/nvim-mini/mini.nvim
	git -C "${MINI_TEST_PATH}" fetch --depth 1 origin "${MINI_TEST_COMMIT}"
	git -C "${MINI_TEST_PATH}" checkout --detach FETCH_HEAD
fi

# The pin may name an annotated tag object rather than a commit, so dereference
# it before comparing; `checkout --detach FETCH_HEAD` always lands on a commit.
expected_commit="$(git -C "${MINI_TEST_PATH}" rev-parse "${MINI_TEST_COMMIT}^{commit}")"
actual_commit="$(git -C "${MINI_TEST_PATH}" rev-parse HEAD)"
if [ "${actual_commit}" != "${expected_commit}" ]; then
	printf 'mini.nvim must be pinned to %s (commit %s); found %s at %s\n' \
		"${MINI_TEST_COMMIT}" "${expected_commit}" "${actual_commit}" "${MINI_TEST_PATH}" >&2
	exit 1
fi

MINI_TEST_PATH="${MINI_TEST_PATH}" nvim --headless -u NONE -l "${REPO_ROOT}/tests/minitest.lua"
