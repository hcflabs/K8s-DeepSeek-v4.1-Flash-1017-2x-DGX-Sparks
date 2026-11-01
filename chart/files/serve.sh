#!/usr/bin/env bash
# ============================================================================
# serve.sh - Kubernetes entrypoint for DeepSeek-V4.1-Flash-1017 on TensorFold
# ============================================================================
# Ported from upstream start.sh (MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks).
# Rank 0 runs `tensorfold-native serve` (the API); rank 1 runs `tf-dsv41-lanes`,
# which connects to rank 0's rendezvous port and retries for TF_DS_CONNECT_S
# seconds (zig/patches/0037: rank 0 opens the port before its weights load, so
# no beacon is needed). The flags and variables are upstream's, one for one.
#
# Besides the launch, this script carries upstream's two memory guards (a Spark's
# GPU shares its memory with the host; a rank that takes it all freezes the node):
#   - before the launch: wait up to TENSORFOLD_MIN_AVAIL_WAIT_S for
#     TENSORFOLD_MIN_AVAIL_GIB available (MemAvailable plus parked per-CPU pages,
#     as the engine counts them), else exit (the pod restarts);
#   - while it runs: memguard. Kill the engine when MemAvailable stays under
#     TENSORFOLD_MEMGUARD_GIB for TENSORFOLD_MEMGUARD_HOLD_S, or falls under
#     TENSORFOLD_MEMGUARD_HARD_GIB twice in a row.
# Rank 1 also watches rank 0's /health once it has answered: when it stops
# answering, rank 1 exits too, so both pods restart and pair again (rank 0
# already exits with status 75 when rank 1 goes away).
#
# Env: set by the chart (see templates/_helpers.tpl). TENSORFOLD_CHECK_ALL=1
# prints the command and exits.
set -euo pipefail

RANK="${TENSORFOLD_NODE_RANK:?TENSORFOLD_NODE_RANK must be set}"
ROOT="${TENSORFOLD_ROOT:-/models}"
MASTER_ADDR="${TENSORFOLD_MASTER_ADDR:?TENSORFOLD_MASTER_ADDR must be set}"
MASTER_PORT="${TENSORFOLD_MASTER_PORT:-29620}"
API_PORT="${TENSORFOLD_API_PORT:-8888}"
SERVED_NAME="${TENSORFOLD_SERVED_MODEL_NAME:-DeepSeek-V4.1-Flash-1017}"
CONTEXT="${TENSORFOLD_CONTEXT:-1048576}"
POOL="${TENSORFOLD_POOL:-}"
PARALLEL="${TENSORFOLD_PARALLEL:-4}"
MAX_TOKENS="${TENSORFOLD_MAX_TOKENS:-32768}"
THINKING="${TENSORFOLD_THINKING:-1}"
REASONING_EFFORT="${TENSORFOLD_REASONING_EFFORT:-}"
THINKING_BUDGET="${TENSORFOLD_THINKING_BUDGET:-}"
TEMPERATURE="${TENSORFOLD_TEMPERATURE:-1.0}"
TOP_P="${TENSORFOLD_TOP_P:-0.95}"
TOP_K="${TENSORFOLD_TOP_K:-20}"
DRAFTS="${TENSORFOLD_DRAFTS:-1}"
ROUND_ROWS="${TENSORFOLD_ROUND_ROWS:-}"
RDMA="${TENSORFOLD_RDMA:-1}"
RDMA_DEVICES="${TENSORFOLD_RDMA_DEVICES:-}"
GRAPHS="${TENSORFOLD_GRAPHS:-1}"
GRAPH_CAP="${TENSORFOLD_GRAPH_CAP:-128}"
SIDE="${TENSORFOLD_SIDE:-1}"
PREFETCH="${TENSORFOLD_PREFETCH:-1}"
ENGRAM_AIO="${TENSORFOLD_ENGRAM_AIO:-1}"
RANK1_PROFILE="${TENSORFOLD_RANK1_PROFILE:-0}"
EXTRA_ARGS="${TENSORFOLD_EXTRA_ARGS:-}"
API_KEYS="${TENSORFOLD_API_KEYS:-}"
MIN_AVAIL_GIB="${TENSORFOLD_MIN_AVAIL_GIB:-112}"
MIN_AVAIL_WAIT_S="${TENSORFOLD_MIN_AVAIL_WAIT_S:-120}"
MEMGUARD_GIB="${TENSORFOLD_MEMGUARD_GIB:-2.5}"
MEMGUARD_HOLD_S="${TENSORFOLD_MEMGUARD_HOLD_S:-4}"
MEMGUARD_HARD_GIB="${TENSORFOLD_MEMGUARD_HARD_GIB:-1}"
LEADER_WATCH_S="${TENSORFOLD_LEADER_WATCH_S:-60}"
DRY_RUN="${TENSORFOLD_CHECK_ALL:-}"
unset TENSORFOLD_API_KEYS

DATA="${ROOT}/data"
KIT="${ROOT}/kit/kit"

log() { echo "[tensorfold rank=${RANK}] $(date -u +%T) $*"; }
die() { log "FATAL: $*"; exit 1; }

# ── 1. inputs written by scripts/prepare-model.sh and the prepare init container ──
[[ "${RANK}" == 0 || "${RANK}" == 1 ]] || die "TENSORFOLD_NODE_RANK is 0 or 1, not ${RANK}"
[[ -s "${DATA}/dsv41_token_map.json" ]] || die "no token map in ${DATA}: did the prepare init container run?"
compgen -G "${DATA}/rank-cache/rank${RANK}of2-*.bin" >/dev/null || die "no weight file for rank ${RANK} in ${DATA}/rank-cache"
[[ -d "${KIT}/aot" ]] || die "no kit at ${KIT}"
[[ -n "${RDMA_DEVICES}" || "${RDMA}" == 0 ]] || die "TENSORFOLD_RDMA_DEVICES is empty with RDMA on"

# ── 2. the command ──
if [[ "${RANK}" == 0 ]]; then
  export TF_TP_WORLD=2 TF_TP_MASTER="${MASTER_ADDR}" TF_TP_PORT="${MASTER_PORT}"
  export TF_DS_RANK_CACHE="${DATA}/rank-cache" TF_DS_KIT="${KIT}" TENSORFOLD_CUDA_KERNELS="${KIT}/aot"
  export TF_DS_ENGRAM="${ROOT}/engram" TF_DS_TOKEN_MAP="${DATA}/dsv41_token_map.json"
  export TF_DS_GRAPHS="${GRAPHS}" TF_DS_GRAPH_CAP="${GRAPH_CAP}" TF_DS_HC_SIDE="${SIDE}"
  export TF_DS_L2_PREFETCH="${PREFETCH}" TF_DS_ENGRAM_AIO="${ENGRAM_AIO}"
  [[ "${RDMA}" == 0 ]] || export TF_RDMA_DEVICES="${RDMA_DEVICES}"
  CMD=(tensorfold-native serve "${DATA}/model" --backend cuda --host 0.0.0.0 --port "${API_PORT}" --name "${SERVED_NAME}"
       --context "${CONTEXT}" --parallel "${PARALLEL}" --max-tokens "${MAX_TOKENS}"
       --temperature "${TEMPERATURE}" --top-p "${TOP_P}" --top-k "${TOP_K}")
  if [[ "${THINKING}" == 1 ]]; then CMD+=(--thinking); else CMD+=(--no-thinking); fi
  [[ -z "${REASONING_EFFORT}" ]] || CMD+=(--reasoning-effort "${REASONING_EFFORT}")
  [[ -z "${THINKING_BUDGET}" ]] || CMD+=(--thinking-budget "${THINKING_BUDGET}")
  # drafts off on rank 0 as on rank 1 (a follower without the drafter refuses a drafted round)
  [[ "${DRAFTS}" == 1 ]] || CMD+=(--no-drafts)
  if [[ -n "${API_KEYS}" ]]; then
    # --api-key-file: one key a line. The secret holds them space-separated.
    keyfile="${TENSORFOLD_RUN_DIR:-/run/tensorfold}/api-keys"
    mkdir -p "${keyfile%/*}"
    (umask 077; tr -s ' \t' '\n\n' <<<"${API_KEYS}" | sed '/^$/d' >"${keyfile}")
    CMD+=(--api-key-file "${keyfile}")
    log "API key required on /v1 ($(wc -l <"${keyfile}") key(s))"
  else
    log "WARN: the API is open (no auth secret)"
  fi
  # shellcheck disable=SC2206
  EXTRA=(${EXTRA_ARGS})
  CMD+=(${EXTRA[@]+"${EXTRA[@]}"})
else
  # rank 1 takes the round's settings as flags only (tf-dsv41-lanes reads no TF_DS_GRAPHS & co.); its pool is rank 0's
  # context (or POOL) and its streams rank 0's: with other values the two ranks wait on each other.
  CMD=(tf-dsv41-lanes "${ROOT}/checkpoint" "${DATA}/rank-cache" 1 2 "${MASTER_ADDR}" "${MASTER_PORT}" "${KIT}"
       --engram "${ROOT}/engram" --token-map "${DATA}/dsv41_token_map.json"
       --pool "${POOL:-${CONTEXT}}" --streams "${PARALLEL}" --drafts "${DRAFTS}" --graphs "${GRAPHS}"
       --side "${SIDE}" --prefetch "${PREFETCH}" --aio "${ENGRAM_AIO}")
  [[ "${GRAPHS}" == 0 ]] || CMD+=(--graph-cap "${GRAPH_CAP}")
  [[ -z "${ROUND_ROWS}" ]] || CMD+=(--round-rows "${ROUND_ROWS}")
  [[ "${RANK1_PROFILE}" == 0 ]] || CMD+=(--profile "${RANK1_PROFILE}")
  [[ "${RDMA}" == 0 ]] || CMD+=(--rdma "${RDMA_DEVICES}")
fi
# both ranks, alike (zig/patches/0008)
if [[ -n "${POOL}" ]]; then export TF_DS_POOL="${POOL}" TF_DS_WINDOW="${CONTEXT}"; fi
[[ -z "${ROUND_ROWS}" ]] || export TF_DS_ROUND_ROWS="${ROUND_ROWS}"
export TF_DS_STREAMS="${PARALLEL}"

log "exec: ${CMD[*]}"
log "env: $(env | grep -E '^(TF_|TENSORFOLD_CUDA|NCCL_)' | LC_ALL=C sort | tr '\n' ' ')"
if [[ -n "${DRY_RUN}" ]]; then log "check-all: not launching"; exit 0; fi

# ── 3. memory available before the launch ──
# The engine's own count (upstream scripts/memavail.sh, GLM 0119): MemAvailable plus the pages parked on the per-CPU
# free lists beyond their resting level, at most MemTotal. Prints GiB with one decimal.
mem_avail_gib() {
  local pg; pg=$(getconf PAGESIZE 2>/dev/null || echo 4096)
  awk -v page="${pg}" -v zfile=/proc/zoneinfo '
    FILENAME != zfile { if ($1 == "MemTotal:") total = $2 * 1024; else if ($1 == "MemAvailable:") avail = $2 * 1024; next }
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == "pagesets") { listed = 1; next }
      if (listed && substr($0, 1, 4) != "    " && substr($0, 1, 10) != "  vm stats") { listed = 0; next }
      if (!listed) next
      n = split(t, w, /[ \t]+/)
      if (w[1] != "count:" && w[1] != "high_min:") next
      if (n < 2 || w[2] !~ /^[0-9]+$/) { bad = 1; next }
      if (w[1] == "count:") count += w[2]; else rest += w[2] }
    END { parked = 0
      if (!bad && count > 0) { resting = rest > 0 ? rest * page : 536870912; parked = count * page - resting; if (parked < 0) parked = 0 }
      a = avail + parked; if (total > 0 && a > total) a = total
      printf "%.1f\n", a / 1073741824 }' /proc/meminfo /proc/zoneinfo 2>/dev/null
}
if (( MIN_AVAIL_GIB > 0 )); then
  deadline=$((SECONDS + MIN_AVAIL_WAIT_S))
  while :; do
    have=$(mem_avail_gib)
    awk -v a="${have}" -v m="${MIN_AVAIL_GIB}" 'BEGIN { exit !(a >= m) }' && break
    if (( SECONDS >= deadline )); then
      die "only ${have} GiB available on this node, ${MIN_AVAIL_GIB} GiB needed (the weights plus the engine's reserve). Free memory (another GPU workload?) or lower memory.minAvailGiB at your own risk: a rank that takes all the memory freezes the Spark"
    fi
    log "waiting for memory: ${have} of ${MIN_AVAIL_GIB} GiB available"
    sleep 5
  done
  log "memory: ${have} GiB available (${MIN_AVAIL_GIB} needed)"
fi

# Upstream runs every rank with --ulimit stack=67108864. Kubernetes has no per-pod ulimit.
if ulimit -s 65536 2>/dev/null; then log "stack limit: $(ulimit -s) KiB"
else log "WARN: could not raise the stack limit to 64 MiB (hard limit $(ulimit -Hs))"; fi

# ── 4. launch and supervise ──
"${CMD[@]}" &
ENGINE=$!
trap 'kill -TERM "${ENGINE}" 2>/dev/null || true' TERM INT

memguard() {
  local floor_kb hard_kb hold_us a now since=0 hard_low=0
  floor_kb=$(awk -v g="${MEMGUARD_GIB}" 'BEGIN { printf "%d", g * 1048576 }')
  hard_kb=$(awk -v g="${MEMGUARD_HARD_GIB}" 'BEGIN { printf "%d", g * 1048576 }')
  hold_us=$(awk -v h="${MEMGUARD_HOLD_S}" 'BEGIN { printf "%d", h * 1000000 }')
  log "memguard: floor ${MEMGUARD_GIB} GiB for ${MEMGUARD_HOLD_S} s, hard floor ${MEMGUARD_HARD_GIB} GiB"
  while kill -0 "${ENGINE}" 2>/dev/null; do
    sleep 0.25
    a=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
    now=${EPOCHREALTIME/./}
    if (( a >= floor_kb )); then
      (( since == 0 )) || log "memguard: under the floor for $(( (now - since) / 1000 )) ms and recovered: no kill"
      since=0; hard_low=0; continue
    fi
    (( since )) || since=${now}
    if (( a < hard_kb )); then hard_low=$((hard_low + 1)); else hard_low=0; fi
    if (( hard_low < 2 && now - since < hold_us )); then continue; fi
    kill -KILL "${ENGINE}" 2>/dev/null || true
    log "memguard: MemAvailable $(( a / 1024 )) MiB under the floor: killed the engine"
    ps -eo rss,pid,comm --sort=-rss 2>/dev/null | head -6 | sed 's/^/    /'
    return
  done
}
if awk -v g="${MEMGUARD_GIB}" 'BEGIN { exit !(g > 0) }'; then memguard & fi

# rank 1: end with rank 0. Its /health is open even with an API key.
leader_watch() {
  local seen=0 fails=0 limit=$(( LEADER_WATCH_S / 5 ))
  while kill -0 "${ENGINE}" 2>/dev/null; do
    sleep 5
    if curl -fs -o /dev/null --max-time 4 "http://${MASTER_ADDR}:${API_PORT}/health"; then
      (( seen )) || log "rank 0 answers on ${MASTER_ADDR}:${API_PORT}: watching it"
      seen=1; fails=0
    elif (( seen )); then
      fails=$((fails + 1))
      if (( fails >= limit )); then
        log "rank 0 has not answered /health for ${LEADER_WATCH_S} s: ending rank 1 so the pair restarts"
        kill -TERM "${ENGINE}" 2>/dev/null || true
        sleep 15; kill -KILL "${ENGINE}" 2>/dev/null || true
        return
      fi
    fi
  done
}
if [[ "${RANK}" == 1 ]] && (( LEADER_WATCH_S > 0 )); then leader_watch & fi

code=0
wait "${ENGINE}" || code=$?
# a TERM trap returns from wait early: wait for the engine itself
while kill -0 "${ENGINE}" 2>/dev/null; do wait "${ENGINE}" || code=$?; done
log "engine exited with status ${code}"
(( code != 0 )) || code=1   # a rank that ends on its own is never healthy here: let the pod restart
exit "${code}"
