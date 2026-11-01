#!/usr/bin/env bash
# k8s-only smoke test, through a kubectl port-forward to the Service (no SSH, no
# pod exec): /health, the served model id in /v1/models, the window from
# /tokenize (the only place the engine reports it), and one short chat reply
# through both ranks (upstream start.sh's step 5). Exit 0 = healthy.
#
# Usage: scripts/smoke-dsv41.sh [-n NAMESPACE] [-s SERVICE] [--model NAME] [--context N]
# Env: API_KEY (bearer token if auth is enabled), LOCAL_PORT (default 18888)
set -euo pipefail

NAMESPACE=tensorfold
SERVICE=dsv41-flash-1017-tensorfold
MODEL=DeepSeek-V4.1-Flash-1017
CONTEXT=""
PORT="${LOCAL_PORT:-18888}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAMESPACE="${2:?}"; shift 2 ;;
    -s) SERVICE="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --context) CONTEXT="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE}" "${PORT}:8888" >/dev/null 2>&1 &
PF=$!
trap 'kill ${PF} 2>/dev/null || true' EXIT
URL="http://127.0.0.1:${PORT}"
for _ in $(seq 1 20); do
  curl -fsS -o /dev/null --max-time 2 "${URL}/health" 2>/dev/null && break
  sleep 1
done
curl -fsS -o /dev/null --max-time 5 "${URL}/health" || { echo "FAIL: /health did not answer (not ready?)" >&2; exit 1; }
echo "OK: /health"

auth=()
[[ -z "${API_KEY:-}" ]] || auth=(-H "Authorization: Bearer ${API_KEY}")
body="$(curl -fsS --max-time 10 ${auth[@]+"${auth[@]}"} "${URL}/v1/models")" ||
  { echo "FAIL: /v1/models did not answer (API_KEY needed?)" >&2; exit 1; }
python3 -c 'import json,sys; sys.exit(0 if any(d.get("id") == sys.argv[1] for d in json.load(sys.stdin)["data"]) else 1)' \
  "${MODEL}" <<<"${body}" || { echo "FAIL: ${MODEL} not in /v1/models: ${body:0:200}" >&2; exit 1; }
echo "OK: ${MODEL} in /v1/models"

tok="$(curl -fsS --max-time 10 ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' \
  -d '{"messages": [{"role": "user", "content": "hi"}]}' "${URL}/tokenize" 2>/dev/null || true)"
[[ -n "${tok}" ]] || tok='{}'
window="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("max_model_len", ""))' <<<"${tok}" 2>/dev/null || true)"
if [[ -n "${CONTEXT}" && "${window}" != "${CONTEXT}" ]]; then
  echo "FAIL: the window is ${window:-unknown}, want ${CONTEXT}" >&2; exit 1
fi
echo "OK: window ${window:-unknown} tokens"

reply="$(curl -fsS --max-time 300 ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' "${URL}/v1/chat/completions" \
  -d "{\"model\": \"${MODEL}\", \"max_tokens\": 16, \"temperature\": 0, \"chat_template_kwargs\": {\"enable_thinking\": false}, \"messages\": [{\"role\": \"user\", \"content\": \"Reply with OK.\"}]}")" ||
  { echo "FAIL: the chat request failed" >&2; exit 1; }
python3 -c '
import json, sys
r = json.load(sys.stdin); c = (r["choices"][0]["message"].get("content") or "").strip()
assert c, "no reply text"
assert len(c) < 8 or len(set(c)) > 2, "one repeated character"
print("OK: chat reply %r, %s tokens" % (c[:40], r["usage"]["completion_tokens"]))' <<<"${reply}" ||
  { echo "FAIL: bad chat reply: ${reply:0:200}" >&2; exit 1; }
