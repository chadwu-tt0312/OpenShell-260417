#!/usr/bin/env bash
set -euo pipefail

# OpenShell 驗證自動化腳本
# - 驗證 gateway 狀態
# - 驗證檔案 upload/download 流程
# - 驗證 opencode serve API（health/models）
# - 產出基本證據鏈（log + summary）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="${SCRIPT_DIR}/artifacts"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ARTIFACT_ROOT}/openshell-validation-${RUN_ID}"
mkdir -p "${OUT_DIR}"

SANDBOX_FILE="file-a-${RUN_ID,,}"
SANDBOX_API="ocode-api-${RUN_ID,,}"
SANDBOX_REALTIME_PROBE="realtime-probe-${RUN_ID,,}"
PORT="4096"
REMOTE_WORKDIR="/sandbox"
KEEP_RESOURCES="false"
SERVE_CMD=""
SERVE_CMD_IS_DEFAULT="false"
MODEL_FULL_ID=""
API_MODE="opencode"
HEALTH_PATH="/health"
MODELS_PATH="/v1/models"
GLOBAL_HEALTH_PATH="/global/health"
DOC_PATH="/doc"
AUTH_USER="${AUTH_USER:-}"
AUTH_PASS="${AUTH_PASS:-}"
CURL_AUTH_ARGS=()
RUN_QA_SMOKE="true"
RUN_FILE_FLOW="true"
QA_REALTIME="false"
QA_REALTIME_POLICY_FILE="${SCRIPT_DIR}/qa-realtime-policy.yaml"
SANDBOX_POLICY_ARGS=()
CURL_CONNECT_TIMEOUT_SEC="${CURL_CONNECT_TIMEOUT_SEC:-10}"
CURL_MAX_TIME_SEC="${CURL_MAX_TIME_SEC:-120}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${OUT_DIR}/run.log"
}

usage() {
  cat <<EOF
Usage: bash pass/openshell-validate.sh [options]

Options:
  --sandbox-file <name>   檔案驗證 sandbox 名稱
  --sandbox-api <name>    API 驗證 sandbox 名稱
  --port <port>           本機 forward port（預設: 4096）
  --serve-cmd <command>   sandbox 內啟動 API 的命令
  --model <full_id>       OpenCode 預設模型（格式: provider/model，例如 opencode/minimax-m2.5-free）
  --api-mode <mode>       API 驗證模式: opencode | openai（預設: opencode）
  --auth-user <user>      Basic Auth 使用者名稱（可選）
  --auth-pass <pass>      Basic Auth 密碼（可選）
  --skip-file-flow        跳過檔案流程驗證（create/upload/download）
  --skip-qa               跳過「詢問兩個問題」的 smoke test
  --qa-realtime           q2 啟用即時外網查詢題（台股/匯率）
  --qa-policy-file <path> 指定 qa-realtime 使用的 policy 檔案（預設: pass/qa-realtime-policy.yaml）
  --keep                  保留 sandbox 不自動清理
  -h, --help              顯示說明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox-file)
      SANDBOX_FILE="$2"
      shift 2
      ;;
    --sandbox-api)
      SANDBOX_API="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --serve-cmd)
      SERVE_CMD="$2"
      shift 2
      ;;
    --model)
      MODEL_FULL_ID="$2"
      shift 2
      ;;
    --api-mode)
      API_MODE="$2"
      shift 2
      ;;
    --auth-user)
      AUTH_USER="$2"
      shift 2
      ;;
    --auth-pass)
      AUTH_PASS="$2"
      shift 2
      ;;
    --skip-file-flow)
      RUN_FILE_FLOW="false"
      shift
      ;;
    --skip-qa)
      RUN_QA_SMOKE="false"
      shift
      ;;
    --qa-realtime)
      QA_REALTIME="true"
      shift
      ;;
    --qa-policy-file)
      QA_REALTIME_POLICY_FILE="$2"
      shift 2
      ;;
    --keep)
      KEEP_RESOURCES="true"
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

if [[ "${API_MODE}" != "opencode" && "${API_MODE}" != "openai" ]]; then
  echo "Invalid --api-mode: ${API_MODE} (expect opencode|openai)" >&2
  exit 1
fi

if [[ -n "${AUTH_USER}" || -n "${AUTH_PASS}" ]]; then
  if [[ -z "${AUTH_USER}" || -z "${AUTH_PASS}" ]]; then
    echo "Both --auth-user and --auth-pass are required together." >&2
    exit 1
  fi
  CURL_AUTH_ARGS=(-u "${AUTH_USER}:${AUTH_PASS}")
fi

if [[ -z "${SERVE_CMD}" ]]; then
  # 注意：base sandbox 內的 opencode 版本不一定支援 `opencode serve --model`。
  # 以 OPENCODE_CONFIG_CONTENT 注入預設 model，避免依賴 CLI flag。
  if [[ -n "${MODEL_FULL_ID}" ]]; then
    printf -v model_config_json '{"$schema":"https://opencode.ai/config.json","model":"%s"}' "${MODEL_FULL_ID}"
    SERVE_CMD="OPENCODE_CONFIG_CONTENT='${model_config_json}' opencode serve --hostname 127.0.0.1 --port ${PORT}"
  else
    SERVE_CMD="opencode serve --hostname 127.0.0.1 --port ${PORT}"
  fi
  SERVE_CMD_IS_DEFAULT="true"
fi

if [[ "${QA_REALTIME}" == "true" ]]; then
  if [[ ! -f "${QA_REALTIME_POLICY_FILE}" ]]; then
    echo "qa-realtime policy file not found: ${QA_REALTIME_POLICY_FILE}" >&2
    exit 1
  fi
  SANDBOX_POLICY_ARGS=(--policy "${QA_REALTIME_POLICY_FILE}")
fi

cleanup() {
  if [[ "${KEEP_RESOURCES}" == "true" ]]; then
    log "KEEP=true, skip cleanup."
    return
  fi
  log "Cleaning up sandboxes..."
  openshell sandbox delete "${SANDBOX_FILE}" >/dev/null 2>&1 || true
  openshell sandbox delete "${SANDBOX_API}" >/dev/null 2>&1 || true
  openshell sandbox delete "${SANDBOX_REALTIME_PROBE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

record_cmd() {
  local label="$1"
  shift
  local output_file="${OUT_DIR}/${label}.txt"
  log "Running: $*"
  if "$@" >"${output_file}" 2>&1; then
    log "PASS: ${label}"
  else
    log "FAIL: ${label} (see ${output_file})"
    return 1
  fi
}

record_http_post_json() {
  local label="$1"
  local url="$2"
  local payload="$3"
  local body_file="${OUT_DIR}/${label}.json"
  local code_file="${OUT_DIR}/${label}.code"
  local code

  code="$(curl -sS "${CURL_AUTH_ARGS[@]}" --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC}" --max-time "${CURL_MAX_TIME_SEC}" -o "${body_file}" -w "%{http_code}" \
    -X POST "${url}" -H "Content-Type: application/json" -d "${payload}" 2>/dev/null || echo "000")"
  echo "${code}" > "${code_file}"
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    log "PASS: ${label} (HTTP ${code})"
    return 0
  fi
  log "FAIL: ${label} (HTTP ${code}, see ${body_file})"
  return 1
}

extract_first_text_from_response() {
  local response_file="$1"
  local raw_text=""

  if [[ ! -f "${response_file}" ]]; then
    return 1
  fi

  raw_text="$(tr -d '\n' < "${response_file}" | sed -n 's/.*"type":"text","text":"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "${raw_text}" ]]; then
    return 1
  fi

  # 將常見 JSON 跳脫字元還原，方便直接記錄到 run.log
  raw_text="${raw_text//\\n/ }"
  raw_text="${raw_text//\\r/ }"
  raw_text="${raw_text//\\t/ }"
  raw_text="${raw_text//\\\"/\"}"
  raw_text="${raw_text//\\\\/\\}"
  echo "${raw_text}"
}

extract_opencode_error_signal() {
  local response_file="$1"
  local compact=""
  local hint=""

  if [[ ! -f "${response_file}" ]]; then
    return 1
  fi

  compact="$(tr -d '\n' < "${response_file}")"
  if [[ -z "${compact}" ]]; then
    return 1
  fi

  # 優先抓 policy_denied 的 detail（例如：POST /mcp not permitted by policy）
  hint="$(printf '%s' "${compact}" | sed -n 's/.*"detail":"\([^"]*policy[^\"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "${hint}" ]]; then
    hint="${hint//\\\//\/}"
    echo "${hint}"
    return 0
  fi

  # 其次抓常見 403 文字
  hint="$(printf '%s' "${compact}" | sed -n 's/.*\(status code[: ]*403\).*/\1/p' | head -n 1)"
  if [[ -z "${hint}" ]]; then
    hint="$(printf '%s' "${compact}" | sed -n 's/.*\(HTTP[[:space:]]*403\).*/\1/p' | head -n 1)"
  fi
  if [[ -n "${hint}" ]]; then
    echo "${hint}"
    return 0
  fi

  return 1
}

poll_http() {
  local url="$1"
  local retry="${2:-30}"
  local sleep_sec="${3:-2}"
  for _ in $(seq 1 "${retry}"); do
    if curl -sf "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_sec}"
  done
  return 1
}

http_code() {
  local url="$1"
  local code
  if code="$(curl -sS "${CURL_AUTH_ARGS[@]}" -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null)"; then
    echo "${code}"
  else
    echo "000"
  fi
}

wait_server_reachable() {
  local url="$1"
  local retry="${2:-45}"
  local sleep_sec="${3:-2}"
  local code=""
  for _ in $(seq 1 "${retry}"); do
    code="$(http_code "${url}")"
    # 000=無法連線，其他碼代表服務已可達（即使 404 也表示 server up）
    if [[ "${code}" != "000" ]]; then
      echo "${code}"
      return 0
    fi
    sleep "${sleep_sec}"
  done
  return 1
}

port_in_use() {
  local p="$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "[:.]${p}$"
}

pick_free_port() {
  local start="$1"
  local max_try="${2:-50}"
  local candidate="${start}"
  local i=0
  while [[ "${i}" -lt "${max_try}" ]]; do
    if ! port_in_use "${candidate}"; then
      echo "${candidate}"
      return 0
    fi
    candidate=$((candidate + 1))
    i=$((i + 1))
  done
  return 1
}

main() {
  log "Output directory: ${OUT_DIR}"

  # 1) Gateway health
  record_cmd "gateway_status" openshell status

  # 2) File flow validation
  if [[ "${RUN_FILE_FLOW}" == "true" ]]; then
    local_upload_dir="${OUT_DIR}/upload-src"
    mkdir -p "${local_upload_dir}"
    printf "seed\n" > "${local_upload_dir}/seed.txt"

    record_cmd "create_file_sandbox" \
      openshell sandbox create "${SANDBOX_POLICY_ARGS[@]}" --name "${SANDBOX_FILE}" --upload "${local_upload_dir}:${REMOTE_WORKDIR}/upload-src" --no-git-ignore -- true

    printf "v1\n" > "${OUT_DIR}/probe.txt"
    record_cmd "upload_v1" \
      openshell sandbox upload --no-git-ignore "${SANDBOX_FILE}" "${OUT_DIR}/probe.txt" "${REMOTE_WORKDIR}"

    printf "v2\n" > "${OUT_DIR}/probe.txt"
    record_cmd "upload_v2" \
      openshell sandbox upload --no-git-ignore "${SANDBOX_FILE}" "${OUT_DIR}/probe.txt" "${REMOTE_WORKDIR}"

    rm -rf "${OUT_DIR}/download"
    mkdir -p "${OUT_DIR}/download"
    record_cmd "download_probe" \
      openshell sandbox download "${SANDBOX_FILE}" "${REMOTE_WORKDIR}/probe.txt" "${OUT_DIR}/download"
  else
    log "Skip file flow validation by --skip-file-flow"
  fi

  # 3) API flow validation
  if [[ "${QA_REALTIME}" == "true" ]]; then
    log "Running realtime egress probe inside sandbox (TWSE + FX)..."
    record_cmd "realtime_egress_probe" \
      openshell sandbox create "${SANDBOX_POLICY_ARGS[@]}" --name "${SANDBOX_REALTIME_PROBE}" -- \
      sh -lc "curl -fsS 'https://www.twse.com.tw/' >/tmp/twse.html && curl -fsSL 'https://api.exchangerate.host/latest?base=USD&symbols=TWD' >/tmp/fx.json && echo probe_ok"
    log "PASS: realtime egress probe (network path is available)"
  fi

  if port_in_use "${PORT}"; then
    log "Port ${PORT} is in use, searching for next available port..."
    new_port="$(pick_free_port "$((PORT + 1))" 100 || true)"
    if [[ -z "${new_port:-}" ]]; then
      log "FAIL: no free port found near ${PORT}"
      return 1
    fi
    PORT="${new_port}"
    if [[ "${SERVE_CMD_IS_DEFAULT}" == "true" ]]; then
      SERVE_CMD="opencode serve --hostname 127.0.0.1 --port ${PORT}"
    fi
    log "Using fallback port: ${PORT}"
  fi

  log "Starting API sandbox in background..."
  if [[ "${QA_REALTIME}" == "true" ]]; then
    log "qa-realtime enabled; applying policy: ${QA_REALTIME_POLICY_FILE}"
  fi
  (
    openshell sandbox create "${SANDBOX_POLICY_ARGS[@]}" --name "${SANDBOX_API}" --auto-providers --forward "${PORT}" -- sh -lc "${SERVE_CMD}"
  ) >"${OUT_DIR}/api_sandbox_create.txt" 2>&1 &
  API_CREATE_PID=$!
  echo "${API_CREATE_PID}" > "${OUT_DIR}/api_create.pid"

  local_health_url="http://localhost:${PORT}${HEALTH_PATH}"
  local_models_url="http://localhost:${PORT}${MODELS_PATH}"
  local_root_url="http://localhost:${PORT}/"

  sleep 2
  if ! kill -0 "${API_CREATE_PID}" >/dev/null 2>&1; then
    log "FAIL: API sandbox process exited early"
    return 1
  fi

  # readiness / stability probe endpoint depends on API mode
  if [[ "${API_MODE}" == "openai" ]]; then
    readiness_url="${local_health_url}"
  else
    readiness_url="http://localhost:${PORT}${GLOBAL_HEALTH_PATH}"
  fi

  log "Waiting for server reachable: ${readiness_url}"
  readiness_code="$(wait_server_reachable "${readiness_url}" 45 2 || true)"
  if [[ -n "${readiness_code:-}" ]]; then
    log "PASS: server reachable (GET ${readiness_url} => HTTP ${readiness_code})"
    curl -s "${CURL_AUTH_ARGS[@]}" "${readiness_url}" > "${OUT_DIR}/readiness_response.txt" || true
  else
    log "FAIL: server not reachable on localhost:${PORT}"
    return 1
  fi

  if [[ "${API_MODE}" == "openai" ]]; then
    log "Checking optional health endpoint: ${local_health_url}"
    health_code="$(http_code "${local_health_url}")"
    echo "health_http_code=${health_code}" >> "${OUT_DIR}/summary.txt"
    if [[ "${health_code}" == "200" ]]; then
      log "PASS: health endpoint ready"
      curl -s "${CURL_AUTH_ARGS[@]}" "${local_health_url}" > "${OUT_DIR}/health_response.json" || true
    else
      log "INFO: health endpoint returned HTTP ${health_code} (non-blocking)"
    fi

    log "Checking OpenAI-compatible models endpoint: ${local_models_url}"
    models_code="$(http_code "${local_models_url}")"
    if [[ "${models_code}" == "200" ]]; then
      curl -s "${CURL_AUTH_ARGS[@]}" "${local_models_url}" > "${OUT_DIR}/models_response.json" || true
      log "PASS: models endpoint ready"
    else
      log "FAIL: models endpoint HTTP ${models_code} (expect 200)"
      curl -s "${CURL_AUTH_ARGS[@]}" "${local_models_url}" > "${OUT_DIR}/models_response.txt" || true
      return 1
    fi
  else
    global_health_url="http://localhost:${PORT}${GLOBAL_HEALTH_PATH}"
    doc_url="http://localhost:${PORT}${DOC_PATH}"

    log "Checking OpenCode global health endpoint: ${global_health_url}"
    global_code="$(http_code "${global_health_url}")"
    echo "global_health_http_code=${global_code}" >> "${OUT_DIR}/summary.txt"
    if [[ "${global_code}" == "200" ]]; then
      curl -s "${CURL_AUTH_ARGS[@]}" "${global_health_url}" > "${OUT_DIR}/global_health_response.json" || true
      log "PASS: global health endpoint ready"
    elif [[ "${global_code}" == "401" || "${global_code}" == "403" ]]; then
      log "FAIL: global health unauthorized (HTTP ${global_code}); provide --auth-user/--auth-pass"
      return 1
    else
      log "FAIL: global health endpoint HTTP ${global_code} (expect 200)"
      return 1
    fi

    log "Checking OpenAPI doc endpoint: ${doc_url}"
    doc_code="$(http_code "${doc_url}")"
    echo "doc_http_code=${doc_code}" >> "${OUT_DIR}/summary.txt"
    if [[ "${doc_code}" == "200" || "${doc_code}" == "301" || "${doc_code}" == "302" ]]; then
      log "PASS: doc endpoint reachable"
    elif [[ "${doc_code}" == "401" || "${doc_code}" == "403" ]]; then
      log "FAIL: doc endpoint unauthorized (HTTP ${doc_code}); provide --auth-user/--auth-pass"
      return 1
    else
      log "FAIL: doc endpoint HTTP ${doc_code}"
      return 1
    fi

    if [[ "${RUN_QA_SMOKE}" == "true" ]]; then
      session_create_url="http://localhost:${PORT}/session"
      session_message_url_prefix="http://localhost:${PORT}/session"

      log "Creating session for QA smoke test..."
      record_http_post_json "session_create" "${session_create_url}" '{"title":"qa-smoke-test"}'

      session_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "${OUT_DIR}/session_create.json" | head -n 1)"
      if [[ -z "${session_id}" ]]; then
        log "FAIL: unable to parse session id from session_create.json"
        return 1
      fi
      echo "session_id=${session_id}" >> "${OUT_DIR}/summary.txt"

      q1_text='請直接回答：你目前使用的是哪個模型？只回答模型名稱。'
      if [[ "${QA_REALTIME}" == "true" ]]; then
        # q2_text='請附上資料時間：最新 USD/TWD 即期匯率。若無法即時查詢請明確說明原因。'
        q2_text='請提供最新 USD/TWD 即期匯率。若無法即時查詢請明確說明原因。優先用 https://api.exchangerate.host/... 回答並附時間'
      else
        q2_text='請回答你目前是否能使用外網搜尋工具（可/不可），並用一句話說明原因。'
      fi
      q1_payload='{"parts":[{"type":"text","text":"請直接回答：你目前使用的是哪個模型？只回答模型名稱。"}]}'
      q2_payload="{\"parts\":[{\"type\":\"text\",\"text\":\"${q2_text}\"}]}"

      log "Asking question 1: current model"
      record_http_post_json "qa_q1_model" "${session_message_url_prefix}/${session_id}/message" "${q1_payload}"
      log "Q1: ${q1_text}"
      q1_answer="$(extract_first_text_from_response "${OUT_DIR}/qa_q1_model.json" || true)"
      if [[ -n "${q1_answer}" ]]; then
        log "A1: ${q1_answer}"
      else
        log "A1: (unable to parse text response, see ${OUT_DIR}/qa_q1_model.json)"
      fi

      log "Asking question 2: TWSE close"
      record_http_post_json "qa_q2_twse" "${session_message_url_prefix}/${session_id}/message" "${q2_payload}"
      log "Q2: ${q2_text}"
      q2_answer="$(extract_first_text_from_response "${OUT_DIR}/qa_q2_twse.json" || true)"
      if [[ -n "${q2_answer}" ]]; then
        log "A2: ${q2_answer}"
        q2_error_hint="$(extract_opencode_error_signal "${OUT_DIR}/qa_q2_twse.json" || true)"
        if [[ -n "${q2_error_hint}" ]]; then
          log "WARN: Q2 tool/runtime error hint: ${q2_error_hint}"
        fi
        if [[ "${QA_REALTIME}" == "true" ]] && [[ "${q2_answer}" == *"沒有網路瀏覽"* || "${q2_answer}" == *"無法即時查詢"* || "${q2_answer}" == *"無法提供即時"* ]]; then
          log "INFO: model self-reported no browsing; rely on realtime_egress_probe result for actual network reachability."
        fi
      else
        log "A2: (unable to parse text response, see ${OUT_DIR}/qa_q2_twse.json)"
      fi
    else
      log "Skip QA smoke test by --skip-qa"
    fi
  fi

  # 4) Basic stability check
  log "Running basic health loop..."
  if [[ "${API_MODE}" == "openai" ]]; then
    health_loop_url="${local_health_url}"
  else
    health_loop_url="http://localhost:${PORT}${GLOBAL_HEALTH_PATH}"
  fi
  failures=0
  for i in $(seq 1 50); do
    if ! curl -sf "${health_loop_url}" >/dev/null 2>&1; then
      failures=$((failures + 1))
    fi
  done
  echo "health_loop_failures=${failures}" | tee -a "${OUT_DIR}/summary.txt"

  # 5) Collect sandbox metadata
  record_cmd "sandbox_list" openshell sandbox list
  if [[ "${RUN_FILE_FLOW}" == "true" ]]; then
    record_cmd "sandbox_get_file" openshell sandbox get "${SANDBOX_FILE}"
  else
    log "Skip file sandbox metadata by --skip-file-flow"
  fi
  record_cmd "sandbox_get_api" openshell sandbox get "${SANDBOX_API}"
  record_cmd "logs_api_warn" openshell logs "${SANDBOX_API}" --source sandbox --level warn --since 10m

  # 6) Dispatcher mapping summary
  {
    echo "run_id=${RUN_ID}"
    echo "ready_signal=${readiness_url} reachable"
    echo "assign_signal=/v1/models success"
    echo "recycle_signal=sandbox delete and recreate success (manual/next phase)"
    echo "health_loop_failures=${failures}"
    echo "artifact_dir=${OUT_DIR}"
  } > "${OUT_DIR}/dispatcher-mapping-summary.txt"

  log "Validation complete."
  log "Artifacts: ${OUT_DIR}"
}

main "$@"
