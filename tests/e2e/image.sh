#!/usr/bin/env bash
# Sourced by the container E2E scripts.
#
# Anonymous pulls from shared CI runners hit registry rate and data limits. A
# digest-pinned image has the same content on every mirror of the Docker
# Official Images, so try the pinned reference first, then the same digest on
# other mirrors. Unpinned references are used as given.

# shellcheck disable=SC2034 # Callers read LAZYVCS_PULLED_IMAGE.
LAZYVCS_PULLED_IMAGE=""

pull_pinned_image() {
	local image="$1" digest name candidates=() candidate attempt
	if [[ "${image}" != *@sha256:* ]]; then
		LAZYVCS_PULLED_IMAGE="${image}"
		return 0
	fi
	digest="${image##*@}"
	name="${image%@*}"
	name="${name%%:*}"
	name="${name##*/}"
	candidates=("${image}" "mirror.gcr.io/library/${name}@${digest}" "docker.io/library/${name}@${digest}")
	# A cached copy of the pinned digest needs no registry access.
	for candidate in "${candidates[@]}"; do
		if docker image inspect "${candidate}" >/dev/null 2>&1; then
			LAZYVCS_PULLED_IMAGE="${candidate}"
			return 0
		fi
	done
	for candidate in "${candidates[@]}"; do
		for attempt in 1 2 3; do
			if docker pull --quiet "${candidate}" >/dev/null; then
				LAZYVCS_PULLED_IMAGE="${candidate}"
				return 0
			fi
			printf 'pull %s failed (attempt %d)\n' "${candidate}" "${attempt}" >&2
			sleep $((attempt * 5))
		done
	done
	printf 'could not pull %s from any mirror\n' "${image}" >&2
	return 1
}
