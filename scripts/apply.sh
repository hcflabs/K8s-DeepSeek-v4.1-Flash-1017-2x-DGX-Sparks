#!/usr/bin/env bash
# Bootstrap/apply: install the pinned NVIDIA device plugin, wait until
# nvidia.com/gpu is allocatable on the GPU nodes, then install/upgrade the
# serving chart. Plugin first, so no serving pod is scheduled before the GPU is
# advertised.
#
# Usage: scripts/apply.sh [-n NAMESPACE] [-r RELEASE] [-f values.yaml]... [--chart REF] [--version V] [--dry-run]
#   --chart   chart path or OCI ref (default: ./chart in this repo)
# Env: KUBECONFIG / kube context as usual; GPU_WAIT_SECONDS (default 300)
set -euo pipefail

PLUGIN_CHART_VERSION="0.19.3"
PLUGIN_NAMESPACE="gpu"
PLUGIN_RELEASE="nvidia-device-plugin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="tensorfold"
RELEASE="dsv41-flash-1017-tensorfold"
CHART="${HERE}/../chart"
CHART_VERSION=()
VALUES=()
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAMESPACE="${2:?}"; shift 2 ;;
    -r) RELEASE="${2:?}"; shift 2 ;;
    -f) VALUES+=(-f "${2:?}"); shift 2 ;;
    --chart) CHART="${2:?}"; shift 2 ;;
    --version) CHART_VERSION=(--version "${2:?}"); shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h | --help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

run() { if [[ "${DRY}" -eq 1 ]]; then echo "+ $*"; else "$@"; fi; }

echo "==> 1/3 NVIDIA device plugin ${PLUGIN_CHART_VERSION} (image v${PLUGIN_CHART_VERSION}, arm64)"
run helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update
run helm upgrade --install "${PLUGIN_RELEASE}" nvdp/nvidia-device-plugin \
  --version "${PLUGIN_CHART_VERSION}" -n "${PLUGIN_NAMESPACE}" --create-namespace \
  -f "${HERE}/nvidia-device-plugin-values.yaml" --wait --timeout 5m

echo "==> 2/3 waiting for nvidia.com/gpu to become allocatable"
if [[ "${DRY}" -eq 0 ]]; then
  deadline=$((SECONDS + ${GPU_WAIT_SECONDS:-300}))
  until [[ "$(kubectl get nodes -l nvidia.com/gpu.present=true \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' |
      grep -c '^[1-9]')" -ge 2 ]]; do
    if ((SECONDS > deadline)); then
      echo "ERROR: fewer than 2 GPU nodes advertise nvidia.com/gpu. Check 'kubectl -n ${PLUGIN_NAMESPACE} get pods'" >&2
      exit 1
    fi
    sleep 5
  done
  echo "    ok: two nodes advertise nvidia.com/gpu"
fi

echo "==> 3/3 serving chart (${RELEASE} in ${NAMESPACE})"
run helm upgrade --install "${RELEASE}" "${CHART}" ${CHART_VERSION[@]+"${CHART_VERSION[@]}"} \
  -n "${NAMESPACE}" --create-namespace ${VALUES[@]+"${VALUES[@]}"}