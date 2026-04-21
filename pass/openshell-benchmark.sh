#!/usr/bin/env bash
set -euo pipefail

# OpenShell opencode serve benchmark
# ----------------------------------
# Scenario N=1 與 N=3：每個 sandbox 各自跑一輪 Q1+Q2，量測冷啟動耗時、
# 對話耗時、RAM/Disk 佔用，產出結構化報告 (report.json + report.md)。
#
# 設計依據：pass_old/openshell-validate.sh（既有 opencode serve + 兩題 QA 流程）
# 以及 pass_old/qa-realtime-policy.yaml（已含 mcp.exa.ai:443 L7 規則）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="${SCRIPT_DIR}/artifacts"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${ARTIFACT_ROOT}/benchmark-${RUN_ID}"

# ------------- Defaults -------------
MODEL="opencode/minimax-m2.5-free"
POLICY_FILE="${SCRIPT_DIR}/benchmark-policy.yaml"
BASE_PORT=4096
NAME_PREFIX="bench"
SCENARIOS="n1,n3"
KEEP="false"
RUN_EGRESS_PROBE="true"
EGRESS_ONLY="false"
AUTH_USER="${AUTH_USER:-}"
AUTH_PASS="${AUTH_PASS:-}"
CURL_AUTH_ARGS=()

# 可調整的 timeout/poll 參數
CURL_CONNECT_TIMEOUT_SEC="${CURL_CONNECT_TIMEOUT_SEC:-10}"
CURL_MAX_TIME_SEC="${CURL_MAX_TIME_SEC:-180}"
HEALTH_WAIT_RETRY="${HEALTH_WAIT_RETRY:-90}"   # 90 * 2s = 180s 上限
HEALTH_WAIT_SLEEP="${HEALTH_WAIT_SLEEP:-2}"

# 端點固定值（opencode serve 預設）
GLOBAL_HEALTH_PATH="/global/health"
DOC_PATH="/doc"

# 會在 runtime 決定的 per-scenario 陣列
declare -a SB_NAMES=()

# ------------- Usage -------------
usage() {
  cat <<EOF
Usage: bash pass/openshell-benchmark.sh [options]

Options:
  --model <full_id>         預設模型 (default: opencode/minimax-m2.5-free)
  --policy <file>           網路 policy 檔 (default: pass/benchmark-policy.yaml)
  --base-port <port>        N=3 會使用 <base>, <base>+1, <base>+2 (default: 4096)
  --name-prefix <str>       sandbox 命名前綴 (default: bench)
  --scenarios <list>        要跑的 scenario 逗號列表，支援 n1 / n3 (default: n1,n3)
  --auth-user <user>        opencode serve Basic Auth 使用者名稱 (可選)
  --auth-pass <pass>        opencode serve Basic Auth 密碼 (可選)
  --skip-egress             跳過外網可達性驗證階段 (egress probe)
  --egress-only             只跑 egress probe，不跑 n1/n3 scenario
  --keep                    結束不自動刪除 sandbox
  -h, --help                顯示本說明

Environment:
  AUTH_USER / AUTH_PASS     與 --auth-user / --auth-pass 等效
  CURL_CONNECT_TIMEOUT_SEC  curl --connect-timeout 秒數 (default: 10)
  CURL_MAX_TIME_SEC         curl --max-time 秒數 (default: 180)
  HEALTH_WAIT_RETRY         /global/health 輪詢次數 (default: 90)
  HEALTH_WAIT_SLEEP         /global/health 輪詢間隔秒 (default: 2)

輸出：
  pass/artifacts/benchmark-<run-id>/
    run.log                 全程執行軌跡
    report.json             所有 metric 原始值
    report.md               bullet 列表報告
    policy-snapshot.yaml    使用的 policy 備份
    <sandbox_name>/         每個 sandbox 的原始資料
EOF
}

# ------------- Argument parsing -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --policy) POLICY_FILE="$2"; shift 2 ;;
    --base-port) BASE_PORT="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --scenarios) SCENARIOS="$2"; shift 2 ;;
    --auth-user) AUTH_USER="$2"; shift 2 ;;
    --auth-pass) AUTH_PASS="$2"; shift 2 ;;
    --skip-egress) RUN_EGRESS_PROBE="false"; shift ;;
    --egress-only) EGRESS_ONLY="true"; shift ;;
    --keep) KEEP="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "${AUTH_USER}" || -n "${AUTH_PASS}" ]]; then
  if [[ -z "${AUTH_USER}" || -z "${AUTH_PASS}" ]]; then
    echo "Both --auth-user and --auth-pass are required together." >&2
    exit 1
  fi
  CURL_AUTH_ARGS=(-u "${AUTH_USER}:${AUTH_PASS}")
fi

if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "Policy file not found: ${POLICY_FILE}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
cp "${POLICY_FILE}" "${OUT_DIR}/policy-snapshot.yaml"

# ------------- Logging -------------
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${OUT_DIR}/run.log"
}

log_only() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${OUT_DIR}/run.log"
}

# ------------- Cleanup -------------
cleanup() {
  local exit_code=$?
  if [[ "${KEEP}" == "true" ]]; then
    log "KEEP=true, skip sandbox cleanup."
    exit "${exit_code}"
  fi
  if [[ "${#SB_NAMES[@]}" -gt 0 ]]; then
    log "Cleaning up sandboxes: ${SB_NAMES[*]}"
    for sb in "${SB_NAMES[@]}"; do
      openshell sandbox delete "${sb}" >/dev/null 2>&1 || true
    done
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# ------------- Helpers (復用自 pass_old/openshell-validate.sh) -------------
port_in_use() {
  local p="$1"
  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "[:.]${p}\$"
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
  local retry="${2:-${HEALTH_WAIT_RETRY}}"
  local sleep_sec="${3:-${HEALTH_WAIT_SLEEP}}"
  local code=""
  for _ in $(seq 1 "${retry}"); do
    code="$(http_code "${url}")"
    if [[ "${code}" != "000" ]]; then
      echo "${code}"
      return 0
    fi
    sleep "${sleep_sec}"
  done
  return 1
}

wait_global_health_200() {
  # 等到 /global/health 真的回 200（不是任意非 000）才算 ready
  local url="$1"
  local retry="${2:-${HEALTH_WAIT_RETRY}}"
  local sleep_sec="${3:-${HEALTH_WAIT_SLEEP}}"
  for _ in $(seq 1 "${retry}"); do
    if curl -sf "${CURL_AUTH_ARGS[@]}" "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_sec}"
  done
  return 1
}

now_ms() {
  # monotonic-ish epoch ms (date +%s.%N 不是真的 monotonic，但在單一 host 上夠用)
  local s
  s="$(date +%s.%N)"
  # 轉換成整數 ms
  awk -v t="${s}" 'BEGIN{printf "%.0f\n", t*1000}'
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

  raw_text="${raw_text//\\n/ }"
  raw_text="${raw_text//\\r/ }"
  raw_text="${raw_text//\\t/ }"
  raw_text="${raw_text//\\\"/\"}"
  raw_text="${raw_text//\\\\/\\}"
  echo "${raw_text}"
}

json_escape() {
  # 把字串轉成 JSON safe 字元（雙引號、反斜線、控制字元）
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# record_http_post_json <label> <url> <payload> <outdir>
#   成功回 200/201 -> 0；其餘 -> 1
#   elapsed_ms 寫到 <outdir>/<label>.ms
record_http_post_json() {
  local label="$1"
  local url="$2"
  local payload="$3"
  local outdir="$4"
  local body_file="${outdir}/${label}.json"
  local code_file="${outdir}/${label}.code"
  local ms_file="${outdir}/${label}.ms"
  local code t0 t1

  t0="$(now_ms)"
  code="$(curl -sS "${CURL_AUTH_ARGS[@]}" \
    --connect-timeout "${CURL_CONNECT_TIMEOUT_SEC}" --max-time "${CURL_MAX_TIME_SEC}" \
    -o "${body_file}" -w "%{http_code}" \
    -X POST "${url}" -H "Content-Type: application/json" -d "${payload}" 2>/dev/null || echo "000")"
  t1="$(now_ms)"
  echo "${code}" > "${code_file}"
  echo "$((t1 - t0))" > "${ms_file}"

  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    return 0
  fi
  return 1
}

# ------------- 資源量測 -------------
# resolve_container_id <sandbox_name> <outfile>
#   把「最像」這個 sandbox 的 docker container id 寫到 outfile（單行 id 或空）
resolve_container_id() {
  local name="$1"
  local outfile="$2"
  : > "${outfile}"

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  local id
  # 1) 先試全名比對
  id="$(docker ps --no-trunc --format '{{.ID}}\t{{.Names}}' 2>/dev/null \
    | awk -v n="${name}" 'index($2, n) { print $1; exit }' || true)"
  if [[ -z "${id}" ]]; then
    # 2) 試 openshell 常見命名 pattern
    id="$(docker ps --no-trunc --format '{{.ID}}\t{{.Names}}' 2>/dev/null \
      | awk -v n="${name}" '/openshell-sandbox-/ && index($2, n) { print $1; exit }' || true)"
  fi
  if [[ -z "${id}" ]]; then
    # 3) label 反查
    id="$(docker ps --no-trunc \
      --filter "label=openshell.sandbox.name=${name}" \
      --format '{{.ID}}' 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "${id}" ]]; then
    echo "${id}" > "${outfile}"
    return 0
  fi
  return 1
}

# to_mb_human <value>
#   把多種來源的記憶體/磁碟字串統一成 "X.X MB"。
#   支援格式：純 bytes (108495537)、kB (17512kB)、Mi/MiB (132Mi/132MiB)、
#            Gi/GiB (1.5GiB)、MB/GB；以及 "200MiB / 4GiB" 之類 docker 多段值（取第一段）。
#   失敗或 unavailable 回傳 "n/a"。
to_mb_human() {
  local v="${1:-}"
  if [[ -z "${v}" || "${v}" == "unavailable" || "${v}" == "n/a" ]]; then
    echo "n/a"
    return
  fi
  # 取第一個 whitespace token，剝除 "/", "(", 千分位逗號
  local token
  token="$(awk '{print $1}' <<<"${v}" | tr -d ',()')"
  awk -v s="${token}" 'BEGIN{
    n=""; u="";
    if (match(s, /^[0-9]+\.?[0-9]*/)) {
      n = substr(s, RSTART, RLENGTH) + 0;
      u = tolower(substr(s, RSTART+RLENGTH));
    } else { print "n/a"; exit }
    mb = -1;
    if (u=="" || u=="b")                               mb = n / 1048576;
    else if (u=="k" || u=="kb" || u=="kib")            mb = n / 1024;
    else if (u=="m" || u=="mb" || u=="mi" || u=="mib") mb = n;
    else if (u=="g" || u=="gb" || u=="gi" || u=="gib") mb = n * 1024;
    else if (u=="t" || u=="tb" || u=="ti" || u=="tib") mb = n * 1024 * 1024;
    if (mb < 0) { print "n/a"; exit }
    printf "%.1f MB\n", mb;
  }'
}

# docker_stats_snapshot <container_id> <outfile>
docker_stats_snapshot() {
  local cid="$1"
  local outfile="$2"
  if [[ -z "${cid}" ]] || ! command -v docker >/dev/null 2>&1; then
    echo "mem_usage=unavailable" > "${outfile}"
    echo "cpu_pct=unavailable" >> "${outfile}"
    return 1
  fi
  local line
  line="$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "${cid}" 2>/dev/null || true)"
  if [[ -z "${line}" ]]; then
    echo "mem_usage=unavailable" > "${outfile}"
    echo "cpu_pct=unavailable" >> "${outfile}"
    return 1
  fi
  local mem_part cpu_part
  mem_part="${line%%|*}"  # 形如 "200MiB / 4GiB"，取第一段交給 to_mb_human
  cpu_part="${line##*|}"
  {
    echo "mem_usage=$(to_mb_human "${mem_part}")"
    echo "mem_raw=${mem_part}"
    echo "cpu_pct=${cpu_part}"
  } > "${outfile}"
  return 0
}

# kubectl_pod_metrics <sandbox_name> <outfile>
#   透過 openshell doctor exec 取得 k3s pod 的 mem/cpu。
#   優先順序：kubectl top pod → kubectl exec cat /proc/1/status (VmRSS)
#   輸出：mem_usage=, cpu_pct=, mem_source=kubectl_top|proc_status|unavailable
kubectl_pod_metrics() {
  local name="$1"
  local outfile="$2"
  local raw mem cpu

  raw="$(openshell doctor exec -- kubectl top pod -n openshell "${name}" --no-headers 2>/dev/null | head -n 1 || true)"
  if [[ -n "${raw}" ]]; then
    # 欄位：NAME  CPU(cores)  MEMORY(bytes)，例如："bench-n1-0   15m   132Mi"
    cpu="$(awk '{print $2}' <<<"${raw}")"
    mem="$(awk '{print $3}' <<<"${raw}")"
    if [[ -n "${mem}" && -n "${cpu}" ]]; then
      {
        echo "mem_usage=$(to_mb_human "${mem}")"
        echo "mem_raw=${mem}"
        echo "cpu_pct=${cpu}"
        echo "mem_source=kubectl_top"
      } > "${outfile}"
      return 0
    fi
  fi

  # metrics-server 不可用時：讀取 pod PID 1 的 VmRSS
  local vmrss
  vmrss="$(openshell doctor exec -- kubectl exec -n openshell "${name}" -- cat /proc/1/status 2>/dev/null \
    | awk '/^VmRSS:/ {printf "%s%s", $2, $3}' || true)"
  if [[ -n "${vmrss}" ]]; then
    {
      echo "mem_usage=$(to_mb_human "${vmrss}")"
      echo "mem_raw=${vmrss}"
      echo "cpu_pct=unavailable"
      echo "mem_source=proc_status"
    } > "${outfile}"
    return 0
  fi

  {
    echo "mem_usage=unavailable"
    echo "cpu_pct=unavailable"
    echo "mem_source=unavailable"
  } > "${outfile}"
  return 1
}

# kubectl_pod_disk <sandbox_name> <outfile>
#   量測 sandbox 內 /sandbox 與 /tmp 的磁碟用量。
#   輸出：disk_sandbox_bytes=, disk_tmp_bytes=, disk_size=<human>, disk_source=du|unavailable
kubectl_pod_disk() {
  local name="$1"
  local outfile="$2"
  local out
  out="$(openshell doctor exec -- kubectl exec -n openshell "${name}" -- sh -lc 'du -sb /sandbox /tmp 2>/dev/null' 2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    local sandbox_b tmp_b
    sandbox_b="$(awk '$2=="/sandbox" {print $1}' <<<"${out}")"
    tmp_b="$(awk '$2=="/tmp" {print $1}' <<<"${out}")"
    sandbox_b="${sandbox_b:-0}"
    tmp_b="${tmp_b:-0}"
    local total=$((sandbox_b + tmp_b))
    local sandbox_mb tmp_mb total_mb
    sandbox_mb="$(to_mb_human "${sandbox_b}")"
    tmp_mb="$(to_mb_human "${tmp_b}")"
    total_mb="$(to_mb_human "${total}")"
    {
      echo "disk_sandbox_bytes=${sandbox_b}"
      echo "disk_tmp_bytes=${tmp_b}"
      echo "disk_total_bytes=${total}"
      echo "disk_size=${total_mb} (sandbox=${sandbox_mb}, tmp=${tmp_mb})"
      echo "disk_source=du"
    } > "${outfile}"
    return 0
  fi
  {
    echo "disk_size=unavailable"
    echo "disk_source=unavailable"
  } > "${outfile}"
  return 1
}

# docker_size_snapshot <container_id> <outfile>
#   docker ps --size 的 SIZE 欄位（格式：『123MB (virtual 1.2GB)』）
docker_size_snapshot() {
  local cid="$1"
  local outfile="$2"
  if [[ -z "${cid}" ]] || ! command -v docker >/dev/null 2>&1; then
    echo "disk_size=unavailable" > "${outfile}"
    return 1
  fi
  local line
  line="$(docker ps --size --no-trunc --format '{{.ID}}|{{.Size}}' 2>/dev/null \
    | awk -F'|' -v id="${cid}" 'index($1, id) == 1 { print $2; exit }' || true)"
  if [[ -z "${line}" ]]; then
    echo "disk_size=unavailable" > "${outfile}"
    return 1
  fi
  # docker ps --size 形式："145MB (virtual 1.2GB)"，到 to_mb_human 取第一段轉成 MB
  {
    echo "disk_size=$(to_mb_human "${line}")"
    echo "disk_raw=${line}"
  } > "${outfile}"
  return 0
}

# resource_snapshot <name> <tag> <sb_dir>
#   tag: steady | post_qa
resource_snapshot() {
  local name="$1"
  local tag="$2"
  local sb_dir="$3"

  local cid_file="${sb_dir}/container_id.txt"
  if [[ ! -s "${cid_file}" ]]; then
    resolve_container_id "${name}" "${cid_file}" || true
  fi
  local cid
  cid="$(cat "${cid_file}" 2>/dev/null || true)"

  local stats_file="${sb_dir}/stats_${tag}.env"
  local size_file="${sb_dir}/size_${tag}.env"
  docker_stats_snapshot "${cid}" "${stats_file}" || true
  docker_size_snapshot "${cid}" "${size_file}" || true

  # docker 路徑失敗（sandbox 是 k3s pod）就 fallback 到 kubectl
  if grep -q '^mem_usage=unavailable' "${stats_file}" 2>/dev/null; then
    kubectl_pod_metrics "${name}" "${stats_file}" || true
  else
    echo "mem_source=docker_stats" >> "${stats_file}"
  fi
  if grep -q '^disk_size=unavailable' "${size_file}" 2>/dev/null; then
    kubectl_pod_disk "${name}" "${size_file}" || true
  else
    echo "disk_source=docker_ps_size" >> "${size_file}"
  fi

  # 保留 openshell sandbox get 原始輸出，供後續人工核對
  openshell sandbox get "${name}" >"${sb_dir}/sandbox_get_${tag}.txt" 2>&1 || true
}

# collect_l7_denies <name> <outfile>
#   從 openshell logs --level warn 擷取 action=deny / l7_decision=deny 行數
collect_l7_denies() {
  local name="$1"
  local outfile="$2"
  local raw="${outfile%.count}.log"
  openshell logs "${name}" --source sandbox --level warn --since 10m \
    >"${raw}" 2>&1 || true
  local l4 l7 exa_allow exa_deny
  l4="$(grep -c 'action=deny' "${raw}" 2>/dev/null || true)"; l4="${l4:-0}"
  l7="$(grep -c 'l7_decision=deny' "${raw}" 2>/dev/null || true)"; l7="${l7:-0}"
  exa_allow="$(grep -cE 'dst_host=mcp\.exa\.ai.*l7_decision=allow|l7_decision=allow.*dst_host=mcp\.exa\.ai' "${raw}" 2>/dev/null || true)"
  exa_allow="${exa_allow:-0}"
  exa_deny="$(grep -cE 'dst_host=mcp\.exa\.ai.*l7_decision=deny|l7_decision=deny.*dst_host=mcp\.exa\.ai' "${raw}" 2>/dev/null || true)"
  exa_deny="${exa_deny:-0}"
  {
    echo "deny_l4=${l4}"
    echo "deny_l7=${l7}"
    echo "exa_allow=${exa_allow}"
    echo "exa_deny=${exa_deny}"
  } > "${outfile}"
}

# ------------- 單一 sandbox lifecycle -------------
# run_sandbox_lifecycle <scenario> <name> <port>
#   輸出：<OUT_DIR>/<name>/metrics.env
#   欄位：scenario, name, port, status, t_boot_ms, t_qa1_ms, t_qa2_ms, q1_text, q2_text,
#         mem_steady, mem_post_qa, disk_steady, disk_post_qa, deny_l4, deny_l7, exa_allow, exa_deny
run_sandbox_lifecycle() {
  local scenario="$1"
  local name="$2"
  local port="$3"
  local sb_dir="${OUT_DIR}/${name}"
  mkdir -p "${sb_dir}"

  local metrics="${sb_dir}/metrics.env"
  {
    echo "scenario=${scenario}"
    echo "name=${name}"
    echo "port=${port}"
    echo "status=pending"
  } > "${metrics}"

  log "[${name}] scenario=${scenario} port=${port} model=${MODEL}"

  local model_json
  printf -v model_json '{"$schema":"https://opencode.ai/config.json","model":"%s"}' "${MODEL}"
  local serve_cmd
  serve_cmd="OPENCODE_CONFIG_CONTENT='${model_json}' opencode serve --hostname 127.0.0.1 --port ${port}"

  # 背景啟動 sandbox（long-running，會佔住 process 直到 sandbox 被刪除）
  local t_create_start t_ready
  t_create_start="$(now_ms)"
  (
    openshell sandbox create \
      --policy "${POLICY_FILE}" \
      --name "${name}" \
      --auto-providers \
      --forward "${port}" \
      -- sh -lc "${serve_cmd}"
  ) >"${sb_dir}/create.log" 2>&1 &
  local create_pid=$!
  echo "${create_pid}" > "${sb_dir}/create.pid"

  # 給 create 一點時間（Docker pull / pod schedule）再檢查是否還活著
  sleep 2
  if ! kill -0 "${create_pid}" >/dev/null 2>&1; then
    log "[${name}] FAIL: sandbox create exited early (see ${sb_dir}/create.log)"
    sed -i 's/^status=pending/status=boot_failed/' "${metrics}"
    echo "t_boot_ms=-1" >> "${metrics}"
    echo "t_qa1_ms=-1" >> "${metrics}"
    echo "t_qa2_ms=-1" >> "${metrics}"
    return 1
  fi

  local health_url="http://localhost:${port}${GLOBAL_HEALTH_PATH}"
  log "[${name}] waiting /global/health at ${health_url}"
  if ! wait_global_health_200 "${health_url}"; then
    log "[${name}] FAIL: /global/health not reachable"
    sed -i 's/^status=pending/status=health_failed/' "${metrics}"
    echo "t_boot_ms=-1" >> "${metrics}"
    echo "t_qa1_ms=-1" >> "${metrics}"
    echo "t_qa2_ms=-1" >> "${metrics}"
    return 1
  fi
  t_ready="$(now_ms)"
  local t_boot_ms=$((t_ready - t_create_start))
  echo "t_boot_ms=${t_boot_ms}" >> "${metrics}"
  log "[${name}] PASS: /global/health ready in ${t_boot_ms} ms"

  curl -sf "${CURL_AUTH_ARGS[@]}" "${health_url}" \
    >"${sb_dir}/global_health.json" 2>/dev/null || true

  # Snapshot A (steady-state)
  resource_snapshot "${name}" "steady" "${sb_dir}"

  # Session + Q1 + Q2
  local session_url="http://localhost:${port}/session"
  if ! record_http_post_json "session_create" "${session_url}" '{"title":"benchmark"}' "${sb_dir}"; then
    log "[${name}] FAIL: create session"
    sed -i 's/^status=pending/status=session_failed/' "${metrics}"
    echo "t_qa1_ms=-1" >> "${metrics}"
    echo "t_qa2_ms=-1" >> "${metrics}"
    return 1
  fi
  local session_id
  session_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "${sb_dir}/session_create.json" | head -n 1)"
  if [[ -z "${session_id}" ]]; then
    log "[${name}] FAIL: cannot parse session id"
    sed -i 's/^status=pending/status=session_parse_failed/' "${metrics}"
    echo "t_qa1_ms=-1" >> "${metrics}"
    echo "t_qa2_ms=-1" >> "${metrics}"
    return 1
  fi
  echo "session_id=${session_id}" >> "${metrics}"

  local msg_url="http://localhost:${port}/session/${session_id}/message"
  local q1_text='請直接回答：你目前使用的是哪個模型？只回答模型名稱。'
  local q2_text='請使用工具實際從 GitHub (https://github.com/NVIDIA/OpenShell) 抓取，回答 NVIDIA/OpenShell 倉庫預設分支最新一次 commit 的 SHA 前 8 碼與提交時間 (UTC ISO8601)。請以「sha=<8碼> committed_at=<時間>」的單行格式回答；若工具不可用請明確說明失敗原因，不要憑記憶或猜測。'
  local q1_payload q2_payload
  q1_payload="$(printf '{"parts":[{"type":"text","text":"%s"}]}' "$(json_escape "${q1_text}")")"
  q2_payload="$(printf '{"parts":[{"type":"text","text":"%s"}]}' "$(json_escape "${q2_text}")")"

  local qa1_status qa2_status
  log "[${name}] Q1: ${q1_text}"
  if record_http_post_json "qa_q1" "${msg_url}" "${q1_payload}" "${sb_dir}"; then
    qa1_status="ok"
  else
    qa1_status="fail"
  fi
  echo "t_qa1_ms=$(cat "${sb_dir}/qa_q1.ms" 2>/dev/null || echo -1)" >> "${metrics}"
  local q1_ans=""
  q1_ans="$(extract_first_text_from_response "${sb_dir}/qa_q1.json" || true)"
  echo "qa1_status=${qa1_status}" >> "${metrics}"
  # 保留 raw 字串（extract_first_text_from_response 已去除實體換行），
  # JSON 化在 metrics_env_to_json 統一做一次 json_escape 以避免雙重轉義。
  printf 'q1_text=%s\n' "${q1_ans}" >> "${metrics}"
  log "[${name}] A1: ${q1_ans:-<empty>}"

  log "[${name}] Q2: ${q2_text}"
  if record_http_post_json "qa_q2" "${msg_url}" "${q2_payload}" "${sb_dir}"; then
    qa2_status="ok"
  else
    qa2_status="fail"
  fi
  echo "t_qa2_ms=$(cat "${sb_dir}/qa_q2.ms" 2>/dev/null || echo -1)" >> "${metrics}"
  local q2_ans=""
  q2_ans="$(extract_first_text_from_response "${sb_dir}/qa_q2.json" || true)"
  echo "qa2_status=${qa2_status}" >> "${metrics}"
  printf 'q2_text=%s\n' "${q2_ans}" >> "${metrics}"
  log "[${name}] A2: ${q2_ans:-<empty>}"

  # Snapshot B (post-QA)
  resource_snapshot "${name}" "post_qa" "${sb_dir}"

  # L7 deny 統計
  collect_l7_denies "${name}" "${sb_dir}/deny.count"

  sed -i 's/^status=pending/status=ok/' "${metrics}"
  log "[${name}] DONE"
  return 0
}

# ------------- Scenario 執行 -------------
resolve_port_for_index() {
  local want="$1"
  local chosen
  if port_in_use "${want}"; then
    chosen="$(pick_free_port "$((want + 1))" 100 || true)"
    if [[ -z "${chosen}" ]]; then
      log "FAIL: no free port near ${want}"
      return 1
    fi
    log "Port ${want} busy; using ${chosen} instead."
    echo "${chosen}"
    return 0
  fi
  echo "${want}"
  return 0
}

# ------------- Egress probe -------------
# scenario_egress_probe
#   獨立於 LLM 的外網可達性驗證：在輕量 sandbox 內直接 curl 打三個目標 host，
#   證明 benchmark-policy.yaml 下的 policy + proxy + DNS 通路是否可用。
#   產出：
#     <OUT_DIR>/egress-probe/sandbox_output.txt  sandbox 全部 stdout
#     <OUT_DIR>/egress-probe/probe.env           所有 label_method/url/code/body_size 欄位
#     <OUT_DIR>/egress-probe/summary.env         exchangerate_code / rate_bot_code / mcp_exa_code
scenario_egress_probe() {
  log "=== Egress Probe (independent of LLM) ==="
  local probe_name="${NAME_PREFIX}-egress"
  local probe_dir="${OUT_DIR}/egress-probe"
  mkdir -p "${probe_dir}"

  # quoted heredoc：內容完全不展開，inner shell 收到字面上的 $label / $code
  local probe_cmd
  read -r -d '' probe_cmd <<'PROBE_SH' || true
set +e
probe() {
  label="$1"
  method="$2"
  url="$3"
  body_file=/tmp/body_${label}
  code=$(curl -sS -o "${body_file}" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -X "${method}" "${url}" 2>/dev/null || echo 000)
  size=$(wc -c <"${body_file}" 2>/dev/null | tr -d ' ')
  echo "${label}_method=${method}"
  echo "${label}_url=${url}"
  echo "${label}_code=${code}"
  echo "${label}_body_size=${size:-0}"
  # 輸出 body 前 400 字元（debug/報告用；可能含二進位要先 strip）
  head -c 400 "${body_file}" 2>/dev/null | tr -d '\000' | tr -d '\r' \
    | awk -v lbl="${label}" 'BEGIN{printf "%s_body_head=", lbl} {gsub(/\\/,"\\\\"); gsub(/\n/," "); printf "%s", $0} END{print ""}'
}
echo PROBE_START
probe exchangerate GET  "https://api.exchangerate.host/latest?base=USD&symbols=TWD"
probe rate_bot     GET  "https://rate.bot.com.tw/xrt/flcsv/0/day"
probe mcp_exa      POST "https://mcp.exa.ai/mcp"
probe github_repo  GET  "https://github.com/NVIDIA/OpenShell"
echo PROBE_DONE
PROBE_SH

  SB_NAMES+=("${probe_name}")
  log "[egress] spawning probe sandbox: ${probe_name}"

  local t0 t1
  t0="$(now_ms)"
  if ! openshell sandbox create \
      --policy "${POLICY_FILE}" \
      --name "${probe_name}" \
      --no-auto-providers \
      -- sh -lc "${probe_cmd}" \
      >"${probe_dir}/sandbox_output.txt" 2>&1; then
    log "[egress] WARN: sandbox create exit non-zero (see sandbox_output.txt)"
  fi
  t1="$(now_ms)"
  log "[egress] probe sandbox finished in $((t1 - t0)) ms"

  # 立即刪除 probe sandbox（benchmark scenario 才是主秀）
  if [[ "${KEEP}" != "true" ]]; then
    openshell sandbox delete "${probe_name}" >/dev/null 2>&1 || true
    local -a remain=()
    for x in "${SB_NAMES[@]+"${SB_NAMES[@]}"}"; do
      [[ "${x}" == "${probe_name}" ]] && continue
      remain+=("${x}")
    done
    SB_NAMES=("${remain[@]+"${remain[@]}"}")
  fi

  # 解析 probe 輸出：抓 label_<field>= 行，ANSI 先剝除
  local probe_env="${probe_dir}/probe.env"
  sed 's/\x1b\[[0-9;]*m//g' "${probe_dir}/sandbox_output.txt" \
    | grep -E '^(exchangerate|rate_bot|mcp_exa|github_repo)_(method|url|code|body_size|body_head)=' \
    > "${probe_env}" || true

  # 彙整 summary
  local summary="${probe_dir}/summary.env"
  local ex_code rb_code mc_code gh_code
  ex_code="$(awk -F'=' '$1=="exchangerate_code"{print $2}' "${probe_env}" | tail -n 1)"
  rb_code="$(awk -F'=' '$1=="rate_bot_code"{print $2}' "${probe_env}" | tail -n 1)"
  mc_code="$(awk -F'=' '$1=="mcp_exa_code"{print $2}' "${probe_env}" | tail -n 1)"
  gh_code="$(awk -F'=' '$1=="github_repo_code"{print $2}' "${probe_env}" | tail -n 1)"
  ex_code="${ex_code:-000}"
  rb_code="${rb_code:-000}"
  mc_code="${mc_code:-000}"
  gh_code="${gh_code:-000}"
  {
    echo "exchangerate_code=${ex_code}"
    echo "rate_bot_code=${rb_code}"
    echo "mcp_exa_code=${mc_code}"
    echo "github_repo_code=${gh_code}"
    echo "probe_elapsed_ms=$((t1 - t0))"
  } > "${summary}"

  # 判定：網路通的門檻為「非 000 且非 403」（403 代表 policy_denied）
  egress_verdict_from_code() {
    local c="$1"
    if [[ "${c}" == "000" ]]; then echo "unreachable"; return; fi
    if [[ "${c}" == "403" ]]; then echo "policy_denied"; return; fi
    echo "ok"
  }
  local ex_verdict rb_verdict mc_verdict gh_verdict
  ex_verdict="$(egress_verdict_from_code "${ex_code}")"
  rb_verdict="$(egress_verdict_from_code "${rb_code}")"
  mc_verdict="$(egress_verdict_from_code "${mc_code}")"
  gh_verdict="$(egress_verdict_from_code "${gh_code}")"
  {
    echo "exchangerate_verdict=${ex_verdict}"
    echo "rate_bot_verdict=${rb_verdict}"
    echo "mcp_exa_verdict=${mc_verdict}"
    echo "github_repo_verdict=${gh_verdict}"
  } >> "${summary}"

  log "[egress] exchangerate: HTTP ${ex_code} (${ex_verdict})"
  log "[egress] rate_bot:     HTTP ${rb_code} (${rb_verdict})"
  log "[egress] mcp.exa.ai:   HTTP ${mc_code} (${mc_verdict})"
  log "[egress] api.github:   HTTP ${gh_code} (${gh_verdict})"
}

scenario_n1() {
  log "=== Scenario N=1 ==="
  local name="${NAME_PREFIX}-n1-0"
  local port
  port="$(resolve_port_for_index "${BASE_PORT}")" || return 1
  SB_NAMES+=("${name}")
  run_sandbox_lifecycle "n1" "${name}" "${port}" || true

  # N=1 結束後立刻刪除，讓 N=3 開始時乾淨
  if [[ "${KEEP}" != "true" ]]; then
    log "[${name}] deleting sandbox to free resources for next scenario"
    openshell sandbox delete "${name}" >/dev/null 2>&1 || true
    # 從 SB_NAMES 移除（避免 trap cleanup 重複處理）
    local -a remain=()
    for x in "${SB_NAMES[@]}"; do
      [[ "${x}" == "${name}" ]] && continue
      remain+=("${x}")
    done
    SB_NAMES=("${remain[@]+"${remain[@]}"}")
  fi
}

scenario_n3() {
  log "=== Scenario N=3 (parallel) ==="
  local -a names=()
  local -a ports=()
  local i
  for i in 0 1 2; do
    local n="${NAME_PREFIX}-n3-${i}"
    local p want=$((BASE_PORT + i))
    p="$(resolve_port_for_index "${want}")" || return 1
    names+=("${n}")
    ports+=("${p}")
    SB_NAMES+=("${n}")
  done

  # 並行跑三個 sandbox lifecycle
  local -a pids=()
  for i in 0 1 2; do
    (
      run_sandbox_lifecycle "n3" "${names[$i]}" "${ports[$i]}" || true
    ) &
    pids+=("$!")
  done

  log "N=3 launched pids: ${pids[*]}"
  local pid
  for pid in "${pids[@]}"; do
    wait "${pid}" || true
  done
  log "N=3 all three sandboxes finished"
}

# ------------- 報告 -------------
# 讀取 metrics.env（line-based KEY=VALUE，VALUE 已 json_escape）
# 轉成 JSON 片段的 bash 函式
metrics_env_to_json() {
  local env_file="$1"
  local key val first=1
  echo -n "{"
  while IFS='=' read -r key val; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      echo -n ","
    fi
    # 數值欄位保持 raw；其他欄位視為字串
    case "${key}" in
      t_boot_ms|t_qa1_ms|t_qa2_ms|port|deny_l4|deny_l7|exa_allow|exa_deny)
        if [[ "${val}" =~ ^-?[0-9]+$ ]]; then
          printf '"%s":%s' "${key}" "${val}"
        else
          printf '"%s":"%s"' "${key}" "$(json_escape "${val}")"
        fi
        ;;
      *)
        printf '"%s":"%s"' "${key}" "$(json_escape "${val}")"
        ;;
    esac
  done < "${env_file}"
  echo -n "}"
}

read_env_value() {
  # 讀 env 檔中某個 key 的值（最後一筆）
  local file="$1" key="$2"
  if [[ ! -f "${file}" ]]; then
    echo ""
    return
  fi
  awk -F'=' -v k="${key}" '$1==k { v=$0; sub(/^[^=]*=/, "", v) } END { print v }' "${file}"
}

build_egress_json() {
  # 讀 OUT_DIR/egress-probe/summary.env，若不存在回傳 null
  local summary="${OUT_DIR}/egress-probe/summary.env"
  if [[ ! -f "${summary}" ]]; then
    echo "null"
    return
  fi
  local ex_code rb_code mc_code ex_v rb_v mc_v elapsed
  ex_code="$(read_env_value "${summary}" exchangerate_code)"
  rb_code="$(read_env_value "${summary}" rate_bot_code)"
  mc_code="$(read_env_value "${summary}" mcp_exa_code)"
  ex_v="$(read_env_value "${summary}" exchangerate_verdict)"
  rb_v="$(read_env_value "${summary}" rate_bot_verdict)"
  mc_v="$(read_env_value "${summary}" mcp_exa_verdict)"
  elapsed="$(read_env_value "${summary}" probe_elapsed_ms)"
  local gh_code gh_v
  gh_code="$(read_env_value "${summary}" github_repo_code)"
  gh_v="$(read_env_value "${summary}" github_repo_verdict)"
  printf '{"exchangerate_code":%s,"exchangerate_verdict":"%s","rate_bot_code":%s,"rate_bot_verdict":"%s","mcp_exa_code":%s,"mcp_exa_verdict":"%s","github_repo_code":%s,"github_repo_verdict":"%s","elapsed_ms":%s}' \
    "${ex_code:-0}" "$(json_escape "${ex_v:-unknown}")" \
    "${rb_code:-0}" "$(json_escape "${rb_v:-unknown}")" \
    "${mc_code:-0}" "$(json_escape "${mc_v:-unknown}")" \
    "${gh_code:-0}" "$(json_escape "${gh_v:-unknown}")" \
    "${elapsed:-0}"
}

emit_report_json() {
  local json_file="${OUT_DIR}/report.json"
  local first=1
  local egress_json
  egress_json="$(build_egress_json)"
  {
    echo -n "{\"run_id\":\"${RUN_ID}\",\"model\":\"$(json_escape "${MODEL}")\",\"policy\":\"$(json_escape "${POLICY_FILE}")\",\"egress_probe\":${egress_json},\"sandboxes\":["
    for sb in "${OUT_DIR}"/*/; do
      [[ -d "${sb}" ]] || continue
      local m="${sb}metrics.env"
      [[ -f "${m}" ]] || continue

      # 補齊 deny count
      local deny_file="${sb}deny.count"
      if [[ -f "${deny_file}" ]]; then
        while IFS= read -r ln; do
          # 只附加尚未出現於 metrics 的欄位
          local k="${ln%%=*}"
          grep -q "^${k}=" "${m}" || echo "${ln}" >> "${m}"
        done < "${deny_file}"
      fi

      # 補齊 stats/size 為平面欄位
      local stag
      for stag in steady post_qa; do
        local s_file="${sb}stats_${stag}.env"
        if [[ -f "${s_file}" ]]; then
          local mem cpu mem_src
          mem="$(read_env_value "${s_file}" mem_usage)"
          cpu="$(read_env_value "${s_file}" cpu_pct)"
          mem_src="$(read_env_value "${s_file}" mem_source)"
          grep -q "^mem_${stag}=" "${m}" || echo "mem_${stag}=${mem}" >> "${m}"
          grep -q "^cpu_${stag}=" "${m}" || echo "cpu_${stag}=${cpu}" >> "${m}"
          grep -q "^mem_source_${stag}=" "${m}" || echo "mem_source_${stag}=${mem_src:-unknown}" >> "${m}"
        fi
        local sz_file="${sb}size_${stag}.env"
        if [[ -f "${sz_file}" ]]; then
          local sz disk_src
          sz="$(read_env_value "${sz_file}" disk_size)"
          disk_src="$(read_env_value "${sz_file}" disk_source)"
          grep -q "^disk_${stag}=" "${m}" || echo "disk_${stag}=${sz}" >> "${m}"
          grep -q "^disk_source_${stag}=" "${m}" || echo "disk_source_${stag}=${disk_src:-unknown}" >> "${m}"
        fi
      done

      if [[ "${first}" -eq 1 ]]; then
        first=0
      else
        echo -n ","
      fi
      metrics_env_to_json "${m}"
    done
    echo -n "]}"
  } > "${json_file}"
  log "Report JSON: ${json_file}"
}

emit_report_md() {
  local md="${OUT_DIR}/report.md"
  {
    echo "# OpenShell opencode serve Benchmark"
    echo
    echo "- Run ID: \`${RUN_ID}\`"
    echo "- Model: \`${MODEL}\`"
    echo "- Policy: \`${POLICY_FILE}\`"
    echo "- Artifact dir: \`${OUT_DIR}\`"
    echo
    echo "## 外網可達性驗證 (egress probe)"
    echo
    local summary_file="${OUT_DIR}/egress-probe/summary.env"
    if [[ -f "${summary_file}" ]]; then
      local ex_c rb_c mc_c gh_c ex_v rb_v mc_v gh_v el
      ex_c="$(read_env_value "${summary_file}" exchangerate_code)"
      rb_c="$(read_env_value "${summary_file}" rate_bot_code)"
      mc_c="$(read_env_value "${summary_file}" mcp_exa_code)"
      gh_c="$(read_env_value "${summary_file}" github_repo_code)"
      ex_v="$(read_env_value "${summary_file}" exchangerate_verdict)"
      rb_v="$(read_env_value "${summary_file}" rate_bot_verdict)"
      mc_v="$(read_env_value "${summary_file}" mcp_exa_verdict)"
      gh_v="$(read_env_value "${summary_file}" github_repo_verdict)"
      el="$(read_env_value "${summary_file}" probe_elapsed_ms)"
      echo "- \`GET  https://api.exchangerate.host/latest?base=USD&symbols=TWD\` → HTTP ${ex_c} (${ex_v})"
      echo "- \`GET  https://rate.bot.com.tw/xrt/flcsv/0/day\` → HTTP ${rb_c} (${rb_v})"
      echo "- \`POST https://mcp.exa.ai/mcp\` → HTTP ${mc_c} (${mc_v})"
      echo "- \`GET  https://github.com/NVIDIA/OpenShell\` → HTTP ${gh_c} (${gh_v})"
      echo "- Probe 整體耗時：${el} ms（含 sandbox 冷啟動）"
      echo
      echo "> verdict 判讀：\`ok\`=網路通；\`policy_denied\`=policy 擋；\`unreachable\`=DNS/proxy 連不上。"
    else
      echo "- (未執行 egress probe 或 summary 缺失)"
    fi
    echo
    echo "## Sandbox 結果（依啟動順序）"
    echo
    for sb in "${OUT_DIR}"/*/; do
      [[ -d "${sb}" ]] || continue
      local m="${sb}metrics.env"
      [[ -f "${m}" ]] || continue
      local name scenario port status t_boot t_q1 t_q2
      local mem_s mem_p disk_s disk_p deny_l4 deny_l7 exa_allow exa_deny q1 q2
      name="$(read_env_value "${m}" name)"
      scenario="$(read_env_value "${m}" scenario)"
      port="$(read_env_value "${m}" port)"
      status="$(read_env_value "${m}" status)"
      t_boot="$(read_env_value "${m}" t_boot_ms)"
      t_q1="$(read_env_value "${m}" t_qa1_ms)"
      t_q2="$(read_env_value "${m}" t_qa2_ms)"
      mem_s="$(read_env_value "${m}" mem_steady)"
      mem_p="$(read_env_value "${m}" mem_post_qa)"
      disk_s="$(read_env_value "${m}" disk_steady)"
      disk_p="$(read_env_value "${m}" disk_post_qa)"
      deny_l4="$(read_env_value "${m}" deny_l4)"
      deny_l7="$(read_env_value "${m}" deny_l7)"
      exa_allow="$(read_env_value "${m}" exa_allow)"
      exa_deny="$(read_env_value "${m}" exa_deny)"
      q1="$(read_env_value "${m}" q1_text)"
      q2="$(read_env_value "${m}" q2_text)"

      local mem_src_s mem_src_p disk_src_s disk_src_p
      mem_src_s="$(read_env_value "${m}" mem_source_steady)"
      mem_src_p="$(read_env_value "${m}" mem_source_post_qa)"
      disk_src_s="$(read_env_value "${m}" disk_source_steady)"
      disk_src_p="$(read_env_value "${m}" disk_source_post_qa)"
      echo "- Sandbox \`${name}\` (scenario=${scenario}, port=${port}, status=${status})"
      echo "  - 時間：boot=${t_boot} ms, qa1=${t_q1} ms, qa2=${t_q2} ms"
      echo "  - 資源（steady）：mem=${mem_s:-n/a} [src=${mem_src_s:-n/a}], disk=${disk_s:-n/a} [src=${disk_src_s:-n/a}]"
      echo "  - 資源（post_qa）：mem=${mem_p:-n/a} [src=${mem_src_p:-n/a}], disk=${disk_p:-n/a} [src=${disk_src_p:-n/a}]"
      echo "  - Policy deny：l4_deny=${deny_l4:-0}, l7_deny=${deny_l7:-0}"
      echo "  - mcp.exa.ai 觀察：allow=${exa_allow:-0}, deny=${exa_deny:-0}"
      echo "  - Q1 答覆摘要：${q1:-<empty>}"
      echo "  - Q2 答覆摘要：${q2:-<empty>}"
    done
    echo
    echo "## 併發聚合（N=3）"
    echo
    # 只加總 scenario=n3
    local total_ok=0 sum_boot=0 sum_q1=0 sum_q2=0 cnt=0 max_boot=0
    for sb in "${OUT_DIR}"/*/; do
      [[ -d "${sb}" ]] || continue
      local m="${sb}metrics.env"
      [[ -f "${m}" ]] || continue
      local sc st b q1 q2
      sc="$(read_env_value "${m}" scenario)"
      st="$(read_env_value "${m}" status)"
      [[ "${sc}" == "n3" ]] || continue
      cnt=$((cnt + 1))
      [[ "${st}" == "ok" ]] && total_ok=$((total_ok + 1))
      b="$(read_env_value "${m}" t_boot_ms)"; [[ "${b}" =~ ^[0-9]+$ ]] || b=0
      q1="$(read_env_value "${m}" t_qa1_ms)"; [[ "${q1}" =~ ^[0-9]+$ ]] || q1=0
      q2="$(read_env_value "${m}" t_qa2_ms)"; [[ "${q2}" =~ ^[0-9]+$ ]] || q2=0
      sum_boot=$((sum_boot + b))
      sum_q1=$((sum_q1 + q1))
      sum_q2=$((sum_q2 + q2))
      [[ "${b}" -gt "${max_boot}" ]] && max_boot="${b}"
    done
    if [[ "${cnt}" -gt 0 ]]; then
      local mean_boot=$((sum_boot / cnt))
      local mean_q1=$((sum_q1 / cnt))
      local mean_q2=$((sum_q2 / cnt))
      echo "- 成功數：${total_ok}/${cnt}"
      echo "- boot：mean=${mean_boot} ms, max=${max_boot} ms"
      echo "- qa1：mean=${mean_q1} ms"
      echo "- qa2：mean=${mean_q2} ms"
    else
      echo "- (未執行 N=3 或無樣本)"
    fi
  } > "${md}"
  log "Report MD: ${md}"
}

# ------------- Main -------------
main() {
  log "Benchmark starting"
  log "Output: ${OUT_DIR}"
  log "Model: ${MODEL}"
  log "Policy: ${POLICY_FILE}"

  # Gateway 健康檢查
  if ! openshell status >"${OUT_DIR}/gateway_status.txt" 2>&1; then
    log "FAIL: openshell status failed (see gateway_status.txt)"
    exit 1
  fi

  if [[ "${RUN_EGRESS_PROBE}" == "true" ]]; then
    scenario_egress_probe || true
  else
    log "Skip egress probe by --skip-egress"
  fi

  if [[ "${EGRESS_ONLY}" == "true" ]]; then
    log "Egress-only mode: skipping n1/n3 scenarios"
  else
    local want
    for want in ${SCENARIOS//,/ }; do
      case "${want}" in
        n1) scenario_n1 || true ;;
        n3) scenario_n3 || true ;;
        *)
          log "WARN: unknown scenario '${want}'，略過"
          ;;
      esac
    done
  fi

  emit_report_json
  emit_report_md

  log "Benchmark done. See ${OUT_DIR}/report.md"
}

main "$@"
