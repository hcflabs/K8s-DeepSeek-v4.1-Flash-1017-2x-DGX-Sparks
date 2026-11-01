#!/usr/bin/env bash
# Syntax-check every embedded script (serve.sh, wait-for-worker.sh, and all
# scripts under scripts/). Exit non-zero if any file fails to parse.
#
#   scripts/check-anchors.sh
set -euo pipefail

CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/../chart" && pwd)"
FILES="${CHART}/files"

rc=0

# Python syntax check
while IFS= read -r -d '' f; do
  python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "${f}" \
    || { echo "[FAIL] ${f#"${FILES}"/}" >&2; rc=1; }
done < <(find "${FILES}" -type f -name '*.py' -print0 2>/dev/null || true)

# Shell syntax check
while IFS= read -r -d '' f; do
  bash -n "${f}" || { echo "[FAIL] ${f#"${FILES}"/}" >&2; rc=1; }
done < <(find "${FILES}" -type f -name '*.sh' -print0 2>/dev/null || true)

[[ "${rc}" -eq 0 ]] && echo "syntax: all embedded scripts parse"
exit "${rc}"