#!/usr/bin/env bash
# Build the engine image (zig/Dockerfile + zig/patches: Mia's patch series on
# BertholomusAI's TensorFold dsv41 branch) on an arm64 host with Docker, usually
# one of the Sparks, then push it to a registry and/or import it into k3s's
# containerd on the GPU nodes. Run from your workstation; the build host is
# reached over SSH and gets only zig/ (the same build context upstream's
# prepare.sh makes).
#
# Usage: scripts/build-image.sh [options] user@build-host
#   --push              push to IMAGE_REPOSITORY (scripts/image.env) as the tag of
#                       scripts/image-tag.sh. Needs GHCR_TOKEN (write:packages),
#                       sent over stdin, and GHCR_USER (default: the repo owner)
#   --import user@host  docker save | k3s ctr images import on that node (repeat
#                       for both Sparks; the build host can be one of them)
#   --rebuild           docker build --no-cache
#   --dry-run           print the plan and stop
#   -h, --help
# Env: MIN_AVAIL_GIB (default 40): refuse to build when the build host has less
#      memory available. Two Zig builds and nvcc on a Spark that also serves a
#      model can freeze it (unified memory). FORCE=1 skips the check.
#
# The image is ~25 GB and the base image (nvcr.io/nvidia/pytorch) is pulled on
# the build host first. Both ranks must run the identical image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/image.env
source "${ROOT}/scripts/image.env"

PUSH=0
REBUILD=0
DRY=0
IMPORTS=()
BUILD_HOST=""
MIN_AVAIL_GIB="${MIN_AVAIL_GIB:-40}"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    --import) IMPORTS+=("${2:?--import needs user@host}"); shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) [[ -z "${BUILD_HOST}" ]] || { echo "one build host only" >&2; exit 2; }; BUILD_HOST="$1"; shift ;;
  esac
done
[[ -n "${BUILD_HOST}" ]] || { echo "error: give the build host (user@host)" >&2; usage >&2; exit 2; }
[[ "${PUSH}" -eq 1 || ${#IMPORTS[@]} -gt 0 ]] || echo "note: neither --push nor --import: the image stays on ${BUILD_HOST} only" >&2

HASH="$("${ROOT}/scripts/image-tag.sh" --hash)"
TAG="${TAG_BASE}-${HASH}"
IMAGE="${IMAGE_REPOSITORY}:${TAG}"
GHCR_USER="${GHCR_USER:-$(echo "${IMAGE_REPOSITORY#ghcr.io/}" | cut -d/ -f1)}"

echo "image:       ${IMAGE}"
echo "pins:        TensorFold ${TF_REF:0:12}, inputs ${INPUTS_REF:0:12}, Zig ${ZIG_VERSION}, ${BASE_IMAGE}"
echo "patches:     $(find "${ROOT}/zig/patches" -name '*.patch' | wc -l | tr -d ' ') engine, $(find "${ROOT}/zig/patches-inputs" -name '*.patch' | wc -l | tr -d ' ') inputs"
echo "build host:  ${BUILD_HOST}"
echo "push:        $([[ "${PUSH}" -eq 1 ]] && echo yes || echo no)"
echo "import into: ${IMPORTS[*]:-none}"
[[ "${DRY}" -eq 0 ]] || exit 0
if [[ "${PUSH}" -eq 1 && -z "${GHCR_TOKEN:-}" ]]; then
  echo "error: --push needs GHCR_TOKEN (a token with write:packages)" >&2
  exit 2
fi

ssh_q() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }

if [[ "${FORCE:-0}" != 1 ]]; then
  avail="$(ssh_q "${BUILD_HOST}" "awk '/^MemAvailable:/ {printf \"%d\", \$2 / 1048576}' /proc/meminfo")"
  if (( avail < MIN_AVAIL_GIB )); then
    echo "error: ${BUILD_HOST} has ${avail} GiB available, ${MIN_AVAIL_GIB} GiB wanted for the build." >&2
    echo "       Stop the model it serves first (a build on a loaded Spark can freeze it), or FORCE=1." >&2
    exit 1
  fi
fi

# The build context upstream's prepare.sh makes: the Dockerfile and both patch dirs.
CTX="\$HOME/.cache/dsv41-image-build/${HASH}"
echo "==> copying the build context to ${BUILD_HOST}:${CTX}"
ssh_q "${BUILD_HOST}" "rm -rf ${CTX} && mkdir -p ${CTX}/zig"
tar -C "${ROOT}" -cf - zig/Dockerfile zig/patches zig/patches-inputs |
  ssh_q "${BUILD_HOST}" "tar -C ${CTX} -xf - && mv ${CTX}/zig/Dockerfile ${CTX}/Dockerfile"

nocache=""
[[ "${REBUILD}" -eq 0 ]] || nocache="--no-cache"
echo "==> building ${IMAGE} on ${BUILD_HOST} (two Zig builds, ~6 min on a Spark)"
ssh_q "${BUILD_HOST}" "set -e
  have=\$(docker image inspect -f '{{index .Config.Labels \"tf.patches\"}}' '${IMAGE}' 2>/dev/null || true)
  if [ '${REBUILD}' = 0 ] && [ \"\$have\" = '${HASH}' ]; then echo 'already built'; exit 0; fi
  docker image inspect '${BASE_IMAGE}' >/dev/null 2>&1 || docker pull '${BASE_IMAGE}'
  docker build ${nocache} -t '${IMAGE}' -f ${CTX}/Dockerfile \
    --build-arg BASE_IMAGE='${BASE_IMAGE}' --build-arg TF_REPO='${TF_REPO}' --build-arg TF_REF='${TF_REF}' \
    --build-arg INPUTS_REF='${INPUTS_REF}' --build-arg ZIG_VERSION='${ZIG_VERSION}' \
    --build-arg ZIG_SHA256='${ZIG_SHA256}' --build-arg ZIG_MIRRORS='${ZIG_MIRRORS}' \
    --build-arg PATCHES_HASH='${HASH}' \
    --label org.opencontainers.image.source=https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks \
    ${CTX}
  [ \"\$(docker image inspect -f '{{index .Config.Labels \"tf.patches\"}}' '${IMAGE}')\" = '${HASH}' ]
  rm -rf ${CTX}"

if [[ "${PUSH}" -eq 1 ]]; then
  echo "==> pushing ${IMAGE}"
  # A throwaway docker config, so no registry credential stays on the build host.
  printf '%s\n' "${GHCR_TOKEN}" | ssh_q "${BUILD_HOST}" "set -e
    d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT
    DOCKER_CONFIG=\$d docker login '${IMAGE_REPOSITORY%%/*}' -u '${GHCR_USER}' --password-stdin >/dev/null
    DOCKER_CONFIG=\$d docker push '${IMAGE}'
    docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' '${IMAGE}' | grep -m1 '^${IMAGE_REPOSITORY}@' | cut -d@ -f2"
fi

for h in "${IMPORTS[@]}"; do
  echo "==> importing ${IMAGE} into k3s containerd on ${h}"
  if [[ "${h}" == "${BUILD_HOST}" ]]; then
    ssh_q "${h}" "docker save '${IMAGE}' | sudo k3s ctr -n k8s.io images import -"
  else
    ssh_q "${BUILD_HOST}" "docker save '${IMAGE}'" | ssh_q "${h}" "sudo k3s ctr -n k8s.io images import -"
  fi
  ssh_q "${h}" "sudo k3s crictl images | grep -q '${TAG}'" || { echo "error: ${h} does not list ${TAG}" >&2; exit 1; }
done

echo "done: ${IMAGE}"
echo "chart: image.repository=${IMAGE_REPOSITORY} image.tag=${TAG} (imported images need image.pullPolicy IfNotPresent, the default)"
