#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_POLICY="${SCRIPT_DIR}/qa-realtime-policy.yaml"
POLICY_FILE="${DEFAULT_POLICY}"
KEEP_SANDBOX="false"
SANDBOX_NAME="policy-check-$(date -u +%Y%m%d%H%M%S)"
ARTIFACT_ROOT="${SCRIPT_DIR}/artifacts"
OUT_DIR="${ARTIFACT_ROOT}/policy-validation-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUT_DIR}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${OUT_DIR}/run.log"
}

usage() {
  cat <<EOF
Usage: bash pass/validate-qa-realtime-policy.sh [options]

Options:
  --policy <path>         要驗證的 policy YAML 路徑（預設: pass/qa-realtime-policy.yaml）
  --sandbox-name <name>   sandbox 名稱（預設: policy-check-<timestamp>）
  --keep                  驗證後保留 sandbox（預設會刪除）
  -h, --help              顯示說明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy)
      POLICY_FILE="$2"
      shift 2
      ;;
    --sandbox-name)
      SANDBOX_NAME="$2"
      shift 2
      ;;
    --keep)
      KEEP_SANDBOX="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

cleanup() {
  if [[ "${KEEP_SANDBOX}" == "true" ]]; then
    log "KEEP=true, skip cleanup."
    return
  fi
  log "Cleaning up sandbox: ${SANDBOX_NAME}"
  openshell sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "Policy file not found: ${POLICY_FILE}" >&2
  exit 1
fi

log "Artifacts: ${OUT_DIR}"
log "Policy file: ${POLICY_FILE}"
log "Sandbox name: ${SANDBOX_NAME}"

log "Checking gateway status..."
openshell status > "${OUT_DIR}/gateway_status.txt" 2>&1

log "Creating sandbox with policy and probing TWSE + FX + Exa reachability..."
if openshell sandbox create \
  --name "${SANDBOX_NAME}" \
  --policy "${POLICY_FILE}" \
  --auto-providers \
  -- sh -lc "curl -fsS 'https://www.twse.com.tw/' >/tmp/twse.html && curl -fsS 'https://api.exchangerate.host/latest?base=USD&symbols=TWD' >/tmp/fx.json && EXA_CODE=\$(curl -sS -o /tmp/exa.txt -w '%{http_code}' 'https://api.exa.ai/' || echo '000') && echo exa_http_code=\${EXA_CODE} >/tmp/exa.code && [ \"\${EXA_CODE}\" != '000' ] && echo 'probe_ok'" \
  > "${OUT_DIR}/create_and_probe.txt" 2>&1; then
  log "PASS: policy loaded and probes succeeded"
else
  log "FAIL: policy validation/probe failed (see ${OUT_DIR}/create_and_probe.txt)"
  exit 1
fi

log "Collecting sandbox metadata..."
openshell sandbox get "${SANDBOX_NAME}" > "${OUT_DIR}/sandbox_get.txt" 2>&1 || true
openshell logs "${SANDBOX_NAME}" --source sandbox --level warn --since 10m > "${OUT_DIR}/sandbox_logs_warn.txt" 2>&1 || true

log "Validation complete."
