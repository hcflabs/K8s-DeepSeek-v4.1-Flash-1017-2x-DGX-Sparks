#!/usr/bin/env bash
# Print the engine image tag for this checkout: <TAG_BASE>-<hash>. The hash is
# upstream config.sh's image_hash: zig/patches/*.patch, zig/patches-inputs/*.patch,
# zig/Dockerfile and the pins in scripts/image.env, in that order.
#
# Usage: scripts/image-tag.sh [--hash]   (--hash prints the hash only)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/image.env
source "${ROOT}/scripts/image.env"
sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
hash="$(
  cd "${ROOT}"
  export LC_ALL=C
  cat zig/patches/*.patch 2>/dev/null || true
  cat zig/patches-inputs/*.patch 2>/dev/null || true
  cat zig/Dockerfile
  echo "${TF_REPO} ${TF_REF} ${INPUTS_REF} zig-${ZIG_VERSION} ${ZIG_SHA256} ${BASE_IMAGE}"
)"
hash="$(printf '%s\n' "${hash}" | sha | cut -c1-12)"
if [[ "${1:-}" == "--hash" ]]; then echo "${hash}"; else echo "${TAG_BASE}-${hash}"; fi
