#!/usr/bin/env bash
# Host-side downloads. Run from your workstation; SSHes to each Spark and puts
# everything a rank reads from the network into <models-dir>/<name> on BOTH
# nodes (local disk: Engram's tables read over NFS cost upstream most of a decode
# round, so there is no NFS mode here):
#
#   checkpoint/  Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw (196 GiB,
#                pinned revision; --eaq-v1-1 for the experimental v1.1 pack)
#   engram/      Engram's n-gram tables: shards 47 and 48 of the base model
#                deepseek-ai/DeepSeek-V4.1-Flash-1017, its index and config
#                (~203 GB, pinned revision, sizes checked against the model card)
#   kit/         BertholomusAI's kernel kit (git, pinned commit)
#   ablit/<rev>/ with --ablit: drowzeys' gated Keys overlay for EAQ v1 (~651 MiB,
#                pinned revision); the chart's ablit.enabled applies it
#
# The derived files (RoPE tables, the image routing bias, Engram's token map,
# the rank's ~106 GB weight file and the served folder) are written into data/
# by the chart's `prepare` init container on first start, with the image's own
# tools; that needs no Docker on the host. Total per node: ~505 GB.
#
# Usage: scripts/prepare-model.sh [options] user@host [user@host ...]
#
# Options:
#   --models-dir DIR   weights root on each node (REQUIRED, e.g. /node/models)
#   --name NAME        directory under DIR (default: DeepSeek-V4.1-Flash-1017)
#   --eaq-v1-1         the experimental EAQ v1.1 pack instead of v1 (recommended)
#   --ablit            also fetch the Keys overlay (needs HF_TOKEN from an account
#                      that accepted the terms of drowzeys/keys-DeepSeek-V4.1-Flash-1017-Abliterated;
#                      EAQ v1 only, so not with --eaq-v1-1)
#   --verify-sha       also sha256 Engram's two shards (minutes of reading 203 GB)
#   --dry-run          print what would run on each host and stop
#   -h, --help
#
# Env: HF_TOKEN (required with --ablit, else optional; sent to the host over stdin, never on a command line).
#
# Resumable: re-running continues a partial download and skips finished parts.
# The chart's weights.hostPath.* must point at <models-dir>/<name>.
set -euo pipefail

MODELS_DIR=""
NAME="DeepSeek-V4.1-Flash-1017"
EAQ_V1_1=0
ABLIT=0
VERIFY_SHA=0
DRY=0
HOSTS=()

# Pins: upstream scripts/config.sh at the commit in SYNC.md.
MODEL_V1="Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw"
MODEL_V1_REV="45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b"
MODEL_V11="Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1.1-2.9-bpw"
MODEL_V11_REV="aee640e2afba93be683bb5b9b420115fe7fbac20"
ENGRAM_ID="deepseek-ai/DeepSeek-V4.1-Flash-1017"
ENGRAM_REV="1bae0e1088993b9b82de08f59de5be5a34e42170"
ENGRAM_47="model-00047-of-00048.safetensors"
ENGRAM_48="model-00048-of-00048.safetensors"
ENGRAM_47_SIZE=101535150936
ENGRAM_48_SIZE=101537926640
ENGRAM_47_SHA=76a05106ece259be83d1bfea0dcb54f23377864ee60fd321690f35e6698a2af5
ENGRAM_48_SHA=9dc51433e195bc78b5ad846b68643cc0351d3b174e5e4309222d3b7402c83afd
ABLIT_ID="drowzeys/keys-DeepSeek-V4.1-Flash-1017-Abliterated"
ABLIT_REV="0bdc2036113c4fdda38ef6005b3cbc0bc0dfa0f0"
ABLIT_SIDECAR="exl3_wo_b_l10_35_mia29.safetensors"
KIT_REPO="https://github.com/bertholomus/deepseek-v4.1-tensorfold-tp2-2xgb10.git"
KIT_REF="abe07c7d509a0199cc7fec15263be2aa52ac652f"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models-dir) MODELS_DIR="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --eaq-v1-1) EAQ_V1_1=1; shift ;;
    --ablit) ABLIT=1; shift ;;
    --verify-sha) VERIFY_SHA=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

[[ -n "${MODELS_DIR}" ]] || { echo "error: --models-dir is required" >&2; usage >&2; exit 2; }
[[ ${#HOSTS[@]} -ge 1 ]] || { echo "error: give at least one user@host (normally both Sparks)" >&2; usage >&2; exit 2; }
[[ "${NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: --name is one directory name" >&2; exit 2; }

if [[ "${ABLIT}" -eq 1 ]]; then
  [[ "${EAQ_V1_1}" -eq 0 ]] || { echo "error: --ablit's overlay matches EAQ v1 only; drop --eaq-v1-1" >&2; exit 2; }
  [[ -n "${HF_TOKEN:-}" || "${DRY}" -eq 1 ]] || { echo "error: --ablit needs HF_TOKEN (the overlay is gated: https://huggingface.co/${ABLIT_ID})" >&2; exit 2; }
fi
if [[ "${EAQ_V1_1}" -eq 1 ]]; then MODEL="${MODEL_V11}"; MODEL_REV="${MODEL_V11_REV}"
else MODEL="${MODEL_V1}"; MODEL_REV="${MODEL_V1_REV}"; fi
ROOT="${MODELS_DIR%/}/${NAME}"

echo "root:        ${ROOT}   (chart: weights.hostPath.leader / .worker)"
echo "checkpoint:  ${MODEL} @${MODEL_REV:0:12} -> ${ROOT}/checkpoint"
echo "engram:      ${ENGRAM_ID} @${ENGRAM_REV:0:12} (${ENGRAM_47}, ${ENGRAM_48}) -> ${ROOT}/engram"
echo "kit:         ${KIT_REPO} @${KIT_REF:0:12} -> ${ROOT}/kit"
[[ "${ABLIT}" -eq 0 ]] || echo "ablit:       ${ABLIT_ID} @${ABLIT_REV:0:12} -> ${ROOT}/ablit/${ABLIT_REV}"

remote_script() {
  cat <<REMOTE
set -euo pipefail
export HF_HUB_ENABLE_HF_TRANSFER=0
[ -n "\${HF_TOKEN:-}" ] || unset HF_TOKEN
H=\$(hostname)
VENV="\$HOME/.cache/dsv41-flash-1017-tensorfold-venv"
if [ ! -x "\$VENV/bin/hf" ]; then
  mkdir -p "\$HOME/.cache"
  python3 -m venv "\$VENV"
  "\$VENV/bin/pip" -q install -U huggingface_hub
fi
HF="\$VENV/bin/hf"
sudo mkdir -p '${ROOT}'
sudo chown "\$(id -u):\$(id -g)" '${ROOT}'
mkdir -p '${ROOT}/checkpoint' '${ROOT}/engram' '${ROOT}/data'
# data/ is written by the root init container; keep it ours so a re-run can clean it.
sudo chown -R "\$(id -u):\$(id -g)" '${ROOT}/checkpoint' '${ROOT}/engram'

free=\$(df -B1 --output=avail '${ROOT}' | tail -1)
have=\$(du -sb '${ROOT}' | cut -f1)
need=\$(( 520 * 1024 * 1024 * 1024 ))
if [ \$(( free + have )) -lt \$need ]; then
  echo "[\$H] only \$(( free / 1073741824 )) GiB free under ${ROOT}; ~505 GB needed in all" >&2; exit 1
fi

echo "[\$H] checkpoint: ${MODEL} @${MODEL_REV:0:8} (196 GiB the first time; resumes)"
"\$HF" download '${MODEL}' --revision '${MODEL_REV}' --local-dir '${ROOT}/checkpoint' --max-workers 16 >/dev/null
test -f '${ROOT}/checkpoint/model.safetensors.index.json' || { echo "[\$H] checkpoint index missing" >&2; exit 1; }
test -f '${ROOT}/checkpoint/config.json' || { echo "[\$H] checkpoint config.json missing" >&2; exit 1; }

echo "[\$H] engram: ${ENGRAM_47}, ${ENGRAM_48} of ${ENGRAM_ID} @${ENGRAM_REV:0:8} (~203 GB the first time; resumes)"
"\$HF" download '${ENGRAM_ID}' --revision '${ENGRAM_REV}' --local-dir '${ROOT}/engram' --max-workers 8 \
  --include model.safetensors.index.json --include config.json --include '${ENGRAM_47}' --include '${ENGRAM_48}' >/dev/null
check() {
  f='${ROOT}/engram/'\$1; size=\$(stat -L -c %s "\$f" 2>/dev/null || echo 0)
  [ "\$size" = "\$2" ] || { echo "[\$H] \$f is \$size bytes, not the 1017 release's \$2: remove it and re-run" >&2; exit 1; }
  if [ '${VERIFY_SHA}' = 1 ]; then
    echo "[\$H] sha256 \$1"
    [ "\$(sha256sum "\$f" | cut -d' ' -f1)" = "\$3" ] || { echo "[\$H] \$f does not match the model card's sha256" >&2; exit 1; }
  fi
}
check '${ENGRAM_47}' '${ENGRAM_47_SIZE}' '${ENGRAM_47_SHA}'
check '${ENGRAM_48}' '${ENGRAM_48_SIZE}' '${ENGRAM_48_SHA}'
test -f '${ROOT}/engram/config.json' || { echo "[\$H] engram config.json missing" >&2; exit 1; }

K='${ROOT}/kit'
if [ ! -d "\$K/.git" ]; then
  echo "[\$H] kit: ${KIT_REPO} @${KIT_REF:0:8}"
  rm -rf "\$K"; git init -q "\$K"
  git -C "\$K" remote add origin '${KIT_REPO}'
  git -C "\$K" fetch -q --depth 1 origin '${KIT_REF}'
  git -C "\$K" checkout -q --detach FETCH_HEAD
fi
[ "\$(git -C "\$K" rev-parse HEAD)" = '${KIT_REF}' ] || { echo "[\$H] \$K is not at ${KIT_REF:0:8}: remove it and re-run" >&2; exit 1; }
test -f "\$K/kit/MANIFEST" || { echo "[\$H] \$K/kit/MANIFEST missing" >&2; exit 1; }
# The init container writes the RoPE tables and the image bias into kit/kit as root.
sudo chown -R "\$(id -u):\$(id -g)" "\$K"

if [ '${ABLIT}' = 1 ]; then
  A='${ROOT}/ablit/${ABLIT_REV}'
  echo "[\$H] ablit: ${ABLIT_ID} @${ABLIT_REV:0:8} (gated)"
  mkdir -p "\$A"
  "\$HF" download '${ABLIT_ID}' --revision '${ABLIT_REV}' --local-dir "\$A" \
    --include apply_mia29_wo_b_graft.py --include '${ABLIT_SIDECAR}' --include EXL3_MIA29_ABLIT_META.json --include README.md >/dev/null ||
    { echo "[\$H] cannot download the gated overlay: does HF_TOKEN's account have access at https://huggingface.co/${ABLIT_ID}?" >&2; exit 1; }
  for f in apply_mia29_wo_b_graft.py '${ABLIT_SIDECAR}' EXL3_MIA29_ABLIT_META.json; do
    test -s "\$A/\$f" || { echo "[\$H] overlay file \$f missing" >&2; exit 1; }
  done
fi

printf '%s\n' '${MODEL}@${MODEL_REV}' > '${ROOT}/checkpoint.ref'
echo "[\$H] done: \$(du -shL '${ROOT}' | cut -f1) in ${ROOT}"
REMOTE
}

if [[ "${DRY}" -eq 1 ]]; then
  for h in "${HOSTS[@]}"; do
    echo "--- would run on ${h} ---"
    remote_script
  done
  exit 0
fi

pids=()
for h in "${HOSTS[@]}"; do
  { printf '%s\n' "${HF_TOKEN:-}"; remote_script; } |
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${h}" 'IFS= read -r HF_TOKEN; export HF_TOKEN; bash -s' 2>&1 |
    sed "s|^|${h}: |" &
  pids+=($!)
done

rc=0
for p in "${pids[@]}"; do wait "${p}" || rc=1; done
[[ "${rc}" -eq 0 ]] && echo "all hosts complete" || echo "one or more hosts failed (re-run to resume)" >&2
exit "${rc}"
