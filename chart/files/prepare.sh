#!/usr/bin/env bash
# ============================================================================
# prepare.sh - init container: the rank's derived inputs, from the checkpoint
# ============================================================================
# Ported from upstream scripts/prepare.sh steps 4 and 5 (and 7 for rank 1). It
# runs in the serving image, on CPU, and needs no network: scripts/prepare-model.sh
# has already put checkpoint/, engram/ and kit/ under the root mounted at /models.
# Every step skips work already done, so a restart costs a few seconds.
#
#   kit/kit/rope-*.f32                       RoPE tables (make_rope.py, from config.json)
#   kit/kit/vision/gate_bias_vl.safetensors  the image routing bias (make_bias_vl.py)
#   kit/kit/MANIFEST                         every kit file checked by sha256
#   data/dsv41_token_map.json                Engram's token map (make_token_map.py)
#   data/rank-cache/rank<r>of2-<hash>.bin    this rank's weight file (~106 GB)
#   data/model/                              the folder rank 0 serves: the
#                                            checkpoint's files linked, plus the
#                                            chart's chat template
#
# Env (set by the chart): TENSORFOLD_NODE_RANK, TENSORFOLD_ROOT (default /models),
#   TENSORFOLD_CHAT_TEMPLATE (path of the template to serve), TENSORFOLD_VERIFY_KIT
#   ("1": check MANIFEST), TENSORFOLD_MIN_FREE_GIB (disk floor for the weight file)
set -euo pipefail

RANK="${TENSORFOLD_NODE_RANK:?TENSORFOLD_NODE_RANK must be set}"
ROOT="${TENSORFOLD_ROOT:-/models}"
TEMPLATE="${TENSORFOLD_CHAT_TEMPLATE:-/etc/tensorfold/chat_template.jinja}"
VERIFY_KIT="${TENSORFOLD_VERIFY_KIT:-1}"
MIN_FREE_GIB="${TENSORFOLD_MIN_FREE_GIB:-130}"
TOOLS=/opt/tensorfold/tools/inputs

CKPT="${ROOT}/checkpoint"
ENGRAM="${ROOT}/engram"
KIT="${ROOT}/kit/kit"
DATA="${ROOT}/data"

log() { echo "[prepare rank=${RANK}] $(date -u +%T) $*"; }
die() { log "FATAL: $*"; exit 1; }

[[ "${RANK}" == 0 || "${RANK}" == 1 ]] || die "TENSORFOLD_NODE_RANK is 0 or 1, not ${RANK}"
[[ -f "${CKPT}/model.safetensors.index.json" && -f "${CKPT}/config.json" ]] ||
  die "no checkpoint at ${CKPT} (run scripts/prepare-model.sh for this node)"
for f in config.json model.safetensors.index.json model-00047-of-00048.safetensors model-00048-of-00048.safetensors; do
  [[ -s "${ENGRAM}/${f}" ]] || die "Engram's ${f} is missing from ${ENGRAM} (run scripts/prepare-model.sh)"
done
[[ -f "${KIT}/MANIFEST" ]] || die "no kit at ${KIT} (run scripts/prepare-model.sh)"
[[ -f "${TEMPLATE}" ]] || die "chat template ${TEMPLATE} missing"
[[ -f "${ROOT}/checkpoint.ref" ]] && log "checkpoint: $(cat "${ROOT}/checkpoint.ref")"
mkdir -p "${DATA}/rank-cache"

# ── 1. the kit's RoPE tables and image routing bias ──
if [[ ! -s "${KIT}/rope-plain-cos.f32" || ! -s "${KIT}/rope-compressed-sin.f32" ]]; then
  log "making the kit's RoPE tables from the checkpoint's config"
  python3 "${TOOLS}/make_rope.py" "${CKPT}/config.json" "${KIT}" >/dev/null ||
    die "the RoPE tables do not match the kit's rope.json: the checkpoint's config differs from the one the kit was made for"
fi
if [[ ! -s "${KIT}/vision/gate_bias_vl.safetensors" ]]; then
  log "making the image routing bias from the checkpoint's gate.bias_vl tensors"
  python3 "${TOOLS}/make_bias_vl.py" "${CKPT}" "${KIT}/vision/gate_bias_vl.safetensors.part" >/dev/null ||
    die "could not make the image routing bias: does the checkpoint hold the gates' bias_vl tensors?"
  mv -f "${KIT}/vision/gate_bias_vl.safetensors.part" "${KIT}/vision/gate_bias_vl.safetensors"
fi

# ── 2. every MANIFEST file by sha256 (the image bias is 1017's own: the one allowed to differ) ──
if [[ "${VERIFY_KIT}" == 1 ]]; then
  bad=0 n=0
  while read -r sum path; do
    n=$((n + 1))
    if [[ ! -f "${KIT}/${path}" ]]; then log "kit file missing: ${path}"; bad=1; continue; fi
    if [[ "$(sha256sum "${KIT}/${path}" | cut -d' ' -f1)" != "${sum}" ]]; then
      [[ "${path}" == vision/gate_bias_vl.safetensors ]] || { log "kit file differs: ${path}"; bad=1; }
    fi
  done <"${KIT}/MANIFEST"
  [[ "${bad}" == 0 ]] || die "the kit does not check out against ${KIT}/MANIFEST"
  log "kit: ${n} files match MANIFEST"
fi

# ── 3. Engram's token map ──
TM="${DATA}/dsv41_token_map.json"
if [[ ! -s "${TM}" ]]; then
  log "Engram's token map from the checkpoint's tokenizer"
  python3 "${TOOLS}/make_token_map.py" "${CKPT}" "${TM}.part" >/dev/null || die "make_token_map.py failed"
  mv -f "${TM}.part" "${TM}"
fi
tm="$(sha256sum "${TM}" | cut -d' ' -f1)"
want_tm="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token_map_sha256", ""))' "${KIT}/engram.json" 2>/dev/null || true)"
if [[ "${tm}" == "${want_tm}" ]]; then
  log "token map: the bytes the kit's Engram fixtures were recorded with"
else
  log "note: the token map (${tm:0:12}) differs from the kit's recorded one (${want_tm:0:12}); upstream accepts this for 1017"
fi

# ── 4. this rank's weight file (its name carries the index's hash) ──
want="$(tf-dsv41-rank-cache "${CKPT}" /tmp/rank-index "${RANK}" 2 --index-only | sha256sum | cut -c1-20)"
file="${DATA}/rank-cache/rank${RANK}of2-${want}.bin"
if [[ -f "${file}" ]]; then
  log "weight file ready: ${file##*/}"
else
  find "${DATA}/rank-cache" -maxdepth 1 -name "rank${RANK}of2-*.bin" -delete
  rm -f "${DATA}/rank-cache/.rank${RANK}of2.partial"
  free=$(df -B1 --output=avail "${DATA}/rank-cache" | tail -1)
  (( free > MIN_FREE_GIB * 1024 ** 3 )) ||
    die "$(( free / 1024 ** 3 )) GiB free for the weight file; it needs ~106 GB (floor ${MIN_FREE_GIB} GiB)"
  log "writing rank ${RANK}'s weight file from the checkpoint (~106 GB, a few minutes)"
  tf-dsv41-rank-cache "${CKPT}" "${DATA}/rank-cache" "${RANK}" 2 >/dev/null || die "tf-dsv41-rank-cache failed"
  [[ -f "${file}" ]] || die "tf-dsv41-rank-cache wrote no ${file##*/}"
  log "weight file written: ${file##*/}"
fi

# ── 5. the folder rank 0 serves: every checkpoint file linked, plus the chart's template ──
VIEW="${DATA}/model"
rm -rf "${VIEW}.new" && mkdir -p "${VIEW}.new"
for f in "${CKPT}"/*; do ln -s "../../checkpoint/${f##*/}" "${VIEW}.new/"; done
# Never write through a checkpoint's chat-template symlink.
rm -f "${VIEW}.new/chat_template.jinja"
cp "${TEMPLATE}" "${VIEW}.new/chat_template.jinja"
rm -rf "${VIEW}" && mv "${VIEW}.new" "${VIEW}"
[[ -s "${VIEW}/config.json" ]] || die "the served folder ${VIEW} does not reach the checkpoint"
log "served folder ready: ${VIEW}"
log "done"
