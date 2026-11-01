#!/usr/bin/env bash
# One-shot readiness report for the two-node deployment: weights, image, fabric,
# rank labels, pods, and the served model. Read-only. Reports every prerequisite
# and points at the first one that is not ready.
#
# The Sparks are reached over SSH because their kubelets are usually unreachable
# from the API server (:10250), so `kubectl logs/exec` may not work either.
#
# Usage: scripts/verify-dsv41.sh --leader user@host --worker user@host [options]
#   --leader / --worker USER@HOST  SSH targets (or env LEADER_SSH / WORKER_SSH)
#   --leader-fabric-ip IP          REQUIRED (chart topology.fabric.masterAddr)
#   --worker-fabric-ip IP          REQUIRED (chart topology.fabric.workerAddr)
#   --fabric-if NAME               REQUIRED (chart topology.fabric.interface)
#   --rdma-dev NAME[,NAME]         REQUIRED (chart topology.fabric.rdmaDevice; every device is checked)
#   --root PATH                    REQUIRED: the root scripts/prepare-model.sh filled (chart weights.hostPath.*)
#   --model NAME                   served model name (default DeepSeek-V4.1-Flash-1017)
#   --image-ref TEXT               substring identifying the image in `crictl images` (optional)
#   --rank-label-key KEY           default node.tensorfold/rank
#   -n NAMESPACE                   default tensorfold
#   --api-url URL                  default http://<leader host>:8888
#   --watch [SECONDS]              refresh until Ctrl-C (default 30)
#   --bench                        also run ib_write_bw across the fabric
# Env: the REQUIRED values above may also be set as env vars; API_KEY (bearer token for /v1 when auth is enabled)
set -euo pipefail

LEADER_SSH="${LEADER_SSH:-}"
WORKER_SSH="${WORKER_SSH:-}"
LEADER_FABRIC_IP="${LEADER_FABRIC_IP:-}"
WORKER_FABRIC_IP="${WORKER_FABRIC_IP:-}"
FABRIC_IF="${FABRIC_IF:-}"
RDMA_DEV="${RDMA_DEV:-}"
MODEL_ROOT="${MODEL_ROOT:-}"
SERVED_MODEL="${SERVED_MODEL:-DeepSeek-V4.1-Flash-1017}"
IMAGE_REF="${IMAGE_REF:-dsv41-flash-1017-tensorfold}"
RANK_KEY="${RANK_KEY:-node.tensorfold/rank}"
NAMESPACE="${NAMESPACE:-tensorfold}"
API_URL="${API_URL:-}"
WATCH="${WATCH:-0}"
WATCH_INTERVAL="${WATCH_INTERVAL:-30}"
BENCH="${BENCH:-0}"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --leader) LEADER_SSH="${2:?}"; shift 2 ;;
    --worker) WORKER_SSH="${2:?}"; shift 2 ;;
    --leader-fabric-ip) LEADER_FABRIC_IP="${2:?}"; shift 2 ;;
    --worker-fabric-ip) WORKER_FABRIC_IP="${2:?}"; shift 2 ;;
    --fabric-if) FABRIC_IF="${2:?}"; shift 2 ;;
    --rdma-dev) RDMA_DEV="${2:?}"; shift 2 ;;
    --root) MODEL_ROOT="${2:?}"; shift 2 ;;
    --model) SERVED_MODEL="${2:?}"; shift 2 ;;
    --image-ref) IMAGE_REF="${2:?}"; shift 2 ;;
    --rank-label-key) RANK_KEY="${2:?}"; shift 2 ;;
    -n) NAMESPACE="${2:?}"; shift 2 ;;
    --api-url) API_URL="${2:?}"; shift 2 ;;
    --watch) WATCH=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WATCH_INTERVAL="$2"; shift; fi; shift ;;
    --bench) BENCH=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${LEADER_SSH}" && -n "${WORKER_SSH}" && -n "${LEADER_FABRIC_IP}" && -n "${WORKER_FABRIC_IP}" &&
  -n "${FABRIC_IF}" && -n "${RDMA_DEV}" && -n "${MODEL_ROOT}" ]] || {
  echo "error: --leader --worker --leader-fabric-ip --worker-fabric-ip --fabric-if --rdma-dev --root are required" >&2
  usage >&2
  exit 2
}
LEADER_HOST="${LEADER_SSH##*@}"
API_URL="${API_URL:-http://${LEADER_HOST}:8888}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
else
  BOLD='' DIM='' GREEN='' YELLOW='' RED='' RESET=''
fi

FIRST_PROBLEM=""
ok() { printf '%s\n' "  ${GREEN}ok${RESET}      $*"; }
warn() { printf '%s\n' "  ${YELLOW}pending${RESET} $*"; [[ -n "${FIRST_PROBLEM}" ]] || FIRST_PROBLEM="$*"; }
bad() { printf '%s\n' "  ${RED}problem${RESET} $*"; [[ -n "${FIRST_PROBLEM}" ]] || FIRST_PROBLEM="$*"; }
note() { printf '%s\n' "  ${DIM}$*${RESET}"; }
heading() { printf '\n%s\n' "${BOLD}$*${RESET}"; }

# -n: never read stdin. Callers loop with `while read ... < <(nodes)`, and an
# ssh that reads stdin swallows the remaining node lines (only leader checked).
on_node() { ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$1" "$2" 2>/dev/null; }
nodes() { printf '%s\n' "leader:${LEADER_SSH}:${WORKER_FABRIC_IP}:${LEADER_FABRIC_IP}" "worker:${WORKER_SSH}:${LEADER_FABRIC_IP}:${WORKER_FABRIC_IP}"; }

run_checks() {
  heading "Weights (${MODEL_ROOT})"
  local name ssh_t peer _ out
  while IFS=: read -r name ssh_t peer _; do
    out="$(on_node "${ssh_t}" "
      R=${MODEL_ROOT}
      [ -f \$R/checkpoint/model.safetensors.index.json ] && echo \"checkpoint \$(du -sbL \$R/checkpoint | cut -f1)\" || echo 'checkpoint missing'
      for f in model-00047-of-00048.safetensors model-00048-of-00048.safetensors; do [ -f \$R/engram/\$f ] && echo \"engram \$(stat -c %s \$R/engram/\$f)\" || echo 'engram missing'; done
      [ -f \$R/kit/kit/MANIFEST ] && echo 'kit ok' || echo 'kit missing'
      ls \$R/data/rank-cache/ 2>/dev/null | grep -E '^rank[01]of2-.*\.bin$' | sed 's/^/rankfile /' || true")" ||
      { bad "${name}: unreachable over SSH"; continue; }
    if grep -q '^checkpoint missing' <<<"${out}"; then bad "${name}: no checkpoint in ${MODEL_ROOT}/checkpoint (run scripts/prepare-model.sh)"
    else ok "${name}: checkpoint $(awk '/^checkpoint/ {printf "%.1f GiB", $2 / 1073741824}' <<<"${out}")"; fi
    sizes="$(awk '/^engram/ {print $2}' <<<"${out}" | tr '\n' ' ')"
    if [[ "${sizes}" == "101535150936 101537926640 " ]]; then ok "${name}: Engram's two shards, full size"
    else bad "${name}: Engram's shards incomplete (${sizes:-none}; re-run scripts/prepare-model.sh)"; fi
    grep -q '^kit ok' <<<"${out}" && ok "${name}: kit" || bad "${name}: no kit (run scripts/prepare-model.sh)"
    local want_rank=0; [[ "${name}" == worker ]] && want_rank=1
    if grep -q "^rankfile rank${want_rank}of2-" <<<"${out}"; then ok "${name}: rank ${want_rank} weight file"
    else warn "${name}: no rank ${want_rank} weight file yet (the prepare init container writes it on first start)"; fi
  done < <(nodes)

  heading "Container image (${IMAGE_REF})"
  local name ssh_t found
  while IFS=: read -r name ssh_t _p _m; do
    found="$(on_node "${ssh_t}" "sudo k3s crictl images --digests 2>/dev/null | grep -c '${IMAGE_REF}' || true")" || found=0
    if [[ "${found:-0}" -gt 0 ]]; then
      ok "${name}: present in containerd"
    else
      warn "${name}: not pulled yet (kubelet pulls ~25 GB on first start, or import it: scripts/build-image.sh --import)"
    fi
  done < <(nodes)

  heading "Fabric (${FABRIC_IF} / ${RDMA_DEV})"
  local name ssh_t peer _ out addr state ping_rc
  while IFS=: read -r name ssh_t peer _; do
    out="$(on_node "${ssh_t}" "
      ip -4 -brief address show ${FABRIC_IF} 2>/dev/null | awk '{print \$3}'
      for d in ${RDMA_DEV//,/ }; do printf '%s ' \"\$(awk '{print \$NF}' /sys/class/infiniband/\$d/ports/1/state 2>/dev/null || echo missing)\"; done; echo
      ping -c 1 -W 2 -I ${FABRIC_IF} ${peer} >/dev/null 2>&1 && echo up || echo down")" ||
      { bad "${name}: unreachable over SSH"; continue; }
    addr="$(sed -n 1p <<<"${out}")"
    state="$(sed -n 2p <<<"${out}")"
    ping_rc="$(sed -n 3p <<<"${out}")"
    if [[ -n "${addr}" && "${addr}" != "down" ]]; then
      ok "${name}: ${addr} on ${FABRIC_IF}"
    else
      bad "${name}: no address on ${FABRIC_IF}"
    fi
    local dev i=0 devs st
    read -r -a devs <<<"${RDMA_DEV//,/ }"
    read -r -a st <<<"${state}"
    for dev in "${devs[@]}"; do
      if [[ "${st[i]:-}" == "ACTIVE" ]]; then
        ok "${name}: RDMA ${dev} is ACTIVE"
      else
        bad "${name}: RDMA ${dev} is ${st[i]:-missing} (NCCL skips it, or falls back to TCP)"
      fi
      i=$((i + 1))
    done
    if [[ "${ping_rc}" == "up" ]]; then
      ok "${name}: can reach ${peer} over ${FABRIC_IF}"
    else
      bad "${name}: cannot ping ${peer} over ${FABRIC_IF}"
    fi
  done < <(nodes)

  heading "Kubernetes"
  if ! kubectl get nodes -l "${RANK_KEY}" -o name 2>/dev/null | grep -q .; then
    warn "no nodes labeled with ${RANK_KEY}"
  else
    for n in $(kubectl get nodes -l "${RANK_KEY}" -o name 2>/dev/null); do
      node_name="${n#node/}"
      # jsonpath needs the dots in a label key escaped (node.tensorfold/rank).
      rank="$(kubectl get "${n}" -o jsonpath="{.metadata.labels.${RANK_KEY//./\\.}}" 2>/dev/null)"
      if [[ -n "${rank}" ]]; then
        ok "${node_name}: rank=${rank}"
      else
        bad "${node_name}: ${RANK_KEY}=${rank:-<empty>}"
      fi
    done
  fi

  heading "Pods"
  local pods
  pods="$(kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null)" || true
  if [[ -z "${pods}" ]]; then
    warn "no pods in namespace ${NAMESPACE}"
  else
    echo "${pods}"
  fi

  heading "API (${API_URL}/v1/models)"
  auth=()
  [[ -z "${API_KEY:-}" ]] || auth=(-H "Authorization: Bearer ${API_KEY}")
  body="$(curl -fsS --max-time 10 ${auth[@]+"${auth[@]}"} "${API_URL}/v1/models" 2>/dev/null)" || true
  if [[ -z "${body}" ]]; then
    warn "API not reachable at ${API_URL}"
  elif echo "${body}" | python3 -c "
import json, sys
m = sys.argv[1]
sys.exit(0 if any(d.get('id') == m for d in json.load(sys.stdin)['data']) else 1)
" "${SERVED_MODEL}"; then
    ok "${SERVED_MODEL} served"
  else
    bad "API responded but model mismatch: ${body:0:200}"
  fi

  if [[ -n "${FIRST_PROBLEM}" ]]; then
    echo
    echo "${BOLD}First problem:${RESET} ${FIRST_PROBLEM}"
    return 1
  fi
  return 0
}

if [[ "${WATCH}" -eq 1 ]]; then
  while true; do
    clear 2>/dev/null || true
    echo "=== verify-dsv41.sh @ $(date) === (${WATCH_INTERVAL}s refresh, Ctrl-C to stop)"
    run_checks || true
    sleep "${WATCH_INTERVAL}"
  done
else
  run_checks
fi