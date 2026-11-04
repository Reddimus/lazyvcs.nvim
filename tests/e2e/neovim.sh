#!/usr/bin/env bash
# Shared by both Ubuntu E2E environments.
resolve_nvim_artifact() {
	local machine="${1:-$(uname -m)}"
	case "${machine}" in
		x86_64 | amd64)
			LAZYVCS_NVIM_ASSET=nvim-linux-x86_64.tar.gz
			LAZYVCS_NVIM_CHECKSUM=474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87
			;;
		aarch64 | arm64)
			LAZYVCS_NVIM_ASSET=nvim-linux-arm64.tar.gz
			LAZYVCS_NVIM_CHECKSUM=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
			;;
		*) printf 'Unsupported Neovim architecture: %s\n' "${machine}" >&2; return 1 ;;
	esac
	if [ "${NVIM_SHA256-auto}" != auto ]; then
		LAZYVCS_NVIM_CHECKSUM="${NVIM_SHA256}"
	elif [ "${NVIM_VERSION}" != v0.12.6 ]; then
		printf 'Set NVIM_SHA256 for %s (empty only for an unpinned canary)\n' "${NVIM_VERSION}" >&2
		return 1
	fi
}

install_nvim() {
	resolve_nvim_artifact || return
	local base="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}"
	local archive=/tmp/nvim.tar.gz
	curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
		"${base}/${LAZYVCS_NVIM_ASSET}" -o "${archive}" || return
	if [ -n "${LAZYVCS_NVIM_CHECKSUM}" ]; then
		printf '%s  %s\n' "${LAZYVCS_NVIM_CHECKSUM}" "${archive}" | sha256sum --check - || return
	fi
	mkdir -p /opt/nvim
	tar -C /opt/nvim --strip-components=1 -xzf "${archive}"
	ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
	nvim --version | sed -n '1,3p'
}
