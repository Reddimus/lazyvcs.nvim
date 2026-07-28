#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -ne 3 ]; then
	printf 'usage: %s VERSION SHA256 PREFIX\n' "$0" >&2
	exit 2
fi

version="$1"
expected_sha="$2"
prefix="$3"
os="$(uname -s)"
arch="$(uname -m)"

case "${os}/${arch}" in
	Linux/x86_64)
		asset="nvim-linux-x86_64.tar.gz"
		;;
	Darwin/x86_64)
		asset="nvim-macos-x86_64.tar.gz"
		;;
	Darwin/arm64)
		asset="nvim-macos-arm64.tar.gz"
		;;
	*)
		printf 'unsupported Neovim test platform: %s/%s\n' "${os}" "${arch}" >&2
		exit 2
		;;
esac

archive="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/${asset}"
url="https://github.com/neovim/neovim/releases/download/${version}/${asset}"
curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
	"${url}" --output "${archive}"

if command -v sha256sum >/dev/null 2>&1; then
	printf '%s  %s\n' "${expected_sha}" "${archive}" | sha256sum --check -
else
	actual_sha="$(shasum -a 256 "${archive}" | awk '{print $1}')"
	if [ "${actual_sha}" != "${expected_sha}" ]; then
		printf 'checksum mismatch for %s: expected %s, got %s\n' \
			"${asset}" "${expected_sha}" "${actual_sha}" >&2
		exit 1
	fi
fi

mkdir -p "${prefix}"
tar -C "${prefix}" --strip-components=1 -xzf "${archive}"

if [ -n "${GITHUB_PATH:-}" ]; then
	printf '%s/bin\n' "${prefix}" >>"${GITHUB_PATH}"
else
	printf '%s/bin\n' "${prefix}"
fi
