#!/usr/bin/env bash
set -euo pipefail

# 建立並驗證 ocode-api sandbox（使用 opencode provider）
# 用法：
#   export OPENCODE_API_KEY='你的_key'
#   ./pass/setup-ocode-api.sh
#
# 可選環境變數：
#   SANDBOX_NAME   預設: ocode-api
#   FORWARD_PORT   預設: 4096
#   DELETE_EXISTING 預設: 1（1=先刪除同名 sandbox，0=保留）

SANDBOX_NAME="${SANDBOX_NAME:-ocode-api}"
FORWARD_PORT="${FORWARD_PORT:-4096}"
DELETE_EXISTING="${DELETE_EXISTING:-1}"
PROVIDER_NAME="opencode"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: command not found: $cmd" >&2
    exit 1
  fi
}

pick_credential_key() {
  if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
    echo "OPENCODE_API_KEY"
    return 0
  fi
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "OPENROUTER_API_KEY"
    return 0
  fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    echo "OPENAI_API_KEY"
    return 0
  fi
  return 1
}

main() {
  require_cmd openshell
  require_cmd grep

  echo "[1/7] Check gateway status..."
  openshell status >/dev/null

  local credential_key
  if ! credential_key="$(pick_credential_key)"; then
    echo "ERROR: missing credentials. Set one of:" >&2
    echo "  - OPENCODE_API_KEY" >&2
    echo "  - OPENROUTER_API_KEY" >&2
    echo "  - OPENAI_API_KEY" >&2
    exit 1
  fi
  echo "[2/7] Using credential env key: ${credential_key}"

  echo "[3/7] Create or update provider '${PROVIDER_NAME}'..."
  if ! openshell provider create --name "${PROVIDER_NAME}" --type opencode --credential "${credential_key}"; then
    openshell provider update "${PROVIDER_NAME}" --credential "${credential_key}"
  fi

  if [[ "${DELETE_EXISTING}" == "1" ]]; then
    echo "[4/7] Delete existing sandbox '${SANDBOX_NAME}' if present..."
    openshell sandbox delete "${SANDBOX_NAME}" || true
  else
    echo "[4/7] Skip delete existing sandbox (DELETE_EXISTING=${DELETE_EXISTING})"
  fi

  echo "[5/7] Create sandbox '${SANDBOX_NAME}'..."
  openshell sandbox create --name "${SANDBOX_NAME}" --provider "${PROVIDER_NAME}" --forward "${FORWARD_PORT}" -- opencode

  echo "[6/7] Verify sandbox is reachable..."
  openshell sandbox get "${SANDBOX_NAME}" >/dev/null

  echo "[7/7] Verify forward port ${FORWARD_PORT} exists..."
  if openshell forward list | grep -Eq "(^|[^0-9])${FORWARD_PORT}([^0-9]|$)"; then
    echo "OK: forward port ${FORWARD_PORT} is active."
  else
    echo "WARN: forward port ${FORWARD_PORT} not found in 'openshell forward list' output." >&2
    echo "      Please run: openshell forward list" >&2
  fi

  echo "Done."
  echo "Sandbox: ${SANDBOX_NAME}"
  echo "Connect : openshell sandbox connect ${SANDBOX_NAME}"
}

main "$@"
