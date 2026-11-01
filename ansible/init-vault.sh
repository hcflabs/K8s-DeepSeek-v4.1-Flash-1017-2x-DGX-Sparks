#!/usr/bin/env bash
#
# One-time setup: writes the EXISTING cluster's k3s join token into an
# ansible-vault encrypted group_vars file (vault_k3s_token). Sparks join an
# existing cluster, so the token comes from the control plane:
#   sudo cat /var/lib/rancher/k3s/server/node-token     (on a server node)
#
# Then run playbooks with --vault-password-file .vault_pass (or --ask-vault-pass).
#
# Usage: K3S_TOKEN=<token> ./init-vault.sh     (or you will be prompted)
# Safe to re-run: never overwrites an existing vault password or vars file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_PASS_FILE="${HERE}/.vault_pass"
VAULT_VARS_DIR="${HERE}/group_vars/all"
VAULT_VARS_FILE="${VAULT_VARS_DIR}/vault.yml"

command -v ansible-vault >/dev/null 2>&1 || {
  echo "Error: ansible-vault not found. Install ansible-core >= 2.15 first." >&2
  exit 1
}

mkdir -p "${VAULT_VARS_DIR}"

if [[ -f "${VAULT_PASS_FILE}" ]]; then
  echo "Vault password file already exists at ${VAULT_PASS_FILE}, reusing it."
else
  openssl rand -base64 48 >"${VAULT_PASS_FILE}"
  chmod 600 "${VAULT_PASS_FILE}"
  echo "Generated ${VAULT_PASS_FILE} (git-ignored). Back it up; it decrypts the token."
fi

if [[ -f "${VAULT_VARS_FILE}" ]]; then
  echo "${VAULT_VARS_FILE} already exists, leaving it untouched. Delete it to re-enter the token."
  exit 0
fi

TOKEN="${K3S_TOKEN:-}"
if [[ -z "${TOKEN}" ]]; then
  read -r -s -p "Existing cluster k3s join token: " TOKEN
  echo
fi
[[ -n "${TOKEN}" ]] || { echo "Error: empty token" >&2; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
printf -- '---\nvault_k3s_token: "%s"\n' "${TOKEN}" >"${TMP}"

ansible-vault encrypt --vault-password-file "${VAULT_PASS_FILE}" --output "${VAULT_VARS_FILE}" "${TMP}"
echo "Encrypted token written to ${VAULT_VARS_FILE} (safe to commit)."
