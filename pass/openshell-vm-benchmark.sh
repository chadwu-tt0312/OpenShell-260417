#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# openshell-vm-benchmark.sh
# ─────────────────────────────────────────────────────────────────────────────
# 使用 openshell-vm (libkrun microVM) 機制執行的資源與時序 benchmark。
# 骨架沿用 pass/openshell-benchmark.sh 的 now_ms / json_escape / to_mb_human /
# emit_report_* 結構，但資料來源改為：
#   Guest 層：透過 `openshell-vm --name <inst> exec -- <cmd>` (vsock agent)
#   Host  層：ps 對 openshell-vm 主行程、du 對 instance rootfs + state disk
#
# 實驗場景：
#   S1  Cold boot      清空 instance → launch → 量測 Ready 時間
#   S2  Guest steady   /proc/meminfo、loadavg、df、kubectl get pods/top
#   S3  Host steady    libkrun 主行程 RSS、rootfs 目錄 du、state disk 實佔
#   S4  Workload       部署 busybox pod → exec → delete（記錄每 op 毫秒）
#   S5  Guest post     重拍 guest snapshot
#   S6  Host post      重拍 host snapshot
#   S7  Warm boot      SIGTERM → 重啟同 instance → 量測是否更快
#
# 用法：
#   ./pass/openshell-vm-benchmark.sh
#   SKIP_BUILD=1 ./pass/openshell-vm-benchmark.sh
#   SKIP_WARM=1 ./pass/openshell-vm-benchmark.sh          # 不跑 warm-boot
#   SKIP_WORKLOAD=1 ./pass/openshell-vm-benchmark.sh      # 不跑 busybox workload
#   INSTANCE_NAME=mybench ./pass/openshell-vm-benchmark.sh
#   KEEP_INSTANCE=1 ./pass/openshell-vm-benchmark.sh      # 保留 instance 供人工檢驗
#   BOOT_TIMEOUT=300 ./pass/openshell-vm-benchmark.sh
#   EXEC_TIMEOUT=180 ./pass/openshell-vm-benchmark.sh   # guest kubectl 較慢時加大
#   WORKLOAD_READY_TIMEOUT=180 ./pass/openshell-vm-benchmark.sh  # workload 等待 Pod Running 秒數
#   WORKLOAD_NODE_READY_TIMEOUT=120 ./pass/openshell-vm-benchmark.sh  # workload 前等待 k3s node Ready 秒數
#   POST_SHUTDOWN_WAIT=180 ./pass/openshell-vm-benchmark.sh  # warm 前等待 lock 釋放秒數
#
# 產出：
#   pass/artifacts/vm-benchmark-<ts>/
#     run.log
#     metrics.env                # 全部 KEY=VALUE
#     report.json                # 結構化
#     report.md                  # bullet 風格報告（對標 openshell-benchmark.sh）
#     raw/                       # 每個步驟的 stdout/stderr
#     console-cold.log           # Cold boot 時的 VM console 輸出
#     console-warm.log           # Warm boot 時的 VM console 輸出
#     stderr-cold.log / stderr-warm.log

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# 參數與路徑
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dt%H%M%Sz)"
OUT_DIR="${SCRIPT_DIR}/artifacts/vm-benchmark-${RUN_ID}"
RAW_DIR="${OUT_DIR}/raw"
METRICS="${OUT_DIR}/metrics.env"

INSTANCE_NAME="${INSTANCE_NAME:-bench-${RUN_ID}}"
GATEWAY_PORT="${GATEWAY_PORT:-30051}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-45}"
# k3s / kubectl 在冷啟後常超過 60s；過短會讓 workload 與 snapshot 量到逾時邊界
EXEC_TIMEOUT="${EXEC_TIMEOUT:-180}"
WORKLOAD_READY_TIMEOUT="${WORKLOAD_READY_TIMEOUT:-180}"
WORKLOAD_NODE_READY_TIMEOUT="${WORKLOAD_NODE_READY_TIMEOUT:-120}"

SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_WARM="${SKIP_WARM:-0}"
SKIP_WORKLOAD="${SKIP_WORKLOAD:-0}"
KEEP_INSTANCE="${KEEP_INSTANCE:-0}"

OPENSHELL_VM_BIN="${OPENSHELL_VM_BIN:-${REPO_ROOT}/target/debug/openshell-vm}"
RUNTIME_DIR="${OPENSHELL_VM_RUNTIME_DIR:-${REPO_ROOT}/target/debug/openshell-vm.runtime}"

# instance rootfs / state disk 預設路徑（與 lib.rs::default_state_disk_path 對齊）
XDG_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}"
INST_BASE="${XDG_DATA}/openshell/openshell-vm"

VM_PID=""
VM_STDERR=""
# shutdown_vm 寫入（勿用 $(shutdown_vm) 包一層：會在子 shell 跑，行為不一致）
SHUTDOWN_LAST_MS="0"

mkdir -p "${RAW_DIR}"
: > "${METRICS}"

# ═══════════════════════════════════════════════════════════════════════════
# 共通工具（沿用 openshell-benchmark.sh 風格）
# ═══════════════════════════════════════════════════════════════════════════

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${OUT_DIR}/run.log"
}

log_only() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${OUT_DIR}/run.log"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

now_ms() {
  local s; s="$(date +%s.%N)"
  awk -v t="${s}" 'BEGIN{printf "%.0f\n", t*1000}'
}

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# 把 byte/KB/MiB/GB/... 統一成 "X.X MB"
to_mb_human() {
  local v="${1:-}"
  if [[ -z "${v}" || "${v}" == "unavailable" || "${v}" == "n/a" ]]; then
    echo "n/a"; return
  fi
  local token
  token="$(awk '{print $1}' <<<"${v}" | tr -d ',()')"
  awk -v s="${token}" 'BEGIN{
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

# 記錄到 metrics.env（K=V，重複時取最後）
put() {
  local key="$1"; shift
  local val="$*"
  echo "${key}=${val}" >> "${METRICS}"
}

# 讀 metrics.env 最後一筆
get() {
  local key="$1"
  awk -F'=' -v k="${key}" '$1==k { v=$0; sub(/^[^=]*=/, "", v) } END { print v }' "${METRICS}"
}

# 跨平台 timeout
timed_run() {
  local secs="$1"; shift
  if has_cmd timeout; then
    # --foreground：避免 openshell-vm 已退出但子程序尚未收斂時，timeout 對殘留 process group 送 SIGTERM 而誤回 143
    if timeout --foreground 1s true 2>/dev/null; then
      timeout --foreground --preserve-status "${secs}s" "$@"
    else
      timeout --preserve-status "${secs}s" "$@"
    fi
  elif has_cmd gtimeout; then
    if gtimeout --foreground 1s true 2>/dev/null; then
      gtimeout --foreground --preserve-status "${secs}s" "$@"
    else
      gtimeout --preserve-status "${secs}s" "$@"
    fi
  else
    "$@" &
    local pid=$!
    ( sleep "${secs}" && kill -TERM "${pid}" 2>/dev/null ) &
    local watchdog=$!
    wait "${pid}"
    local rc=$?
    kill "${watchdog}" 2>/dev/null || true
    return ${rc}
  fi
}

# TCP 可達輪詢
wait_for_tcp() {
  local host="$1" port="$2" timeout_s="$3"
  local deadline=$(( $(date +%s) + timeout_s ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    if has_cmd nc; then
      nc -z -w 2 "${host}" "${port}" 2>/dev/null && return 0
    else
      (exec 3<>/dev/tcp/"${host}"/"${port}") 2>/dev/null && { exec 3<&-; return 0; }
    fi
    sleep 1
  done
  return 1
}

# 幫 run_cmd 寫到 raw/<label>.txt 並回原 rc
run_cmd() {
  local label="$1"; shift
  local out="${RAW_DIR}/${label}.txt"
  {
    echo "# cmd: $*"
    echo "# time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
  } > "${out}"
  local rc=0
  "$@" >>"${out}" 2>&1 || rc=$?
  {
    echo "---"
    echo "# exit_code: ${rc}"
  } >> "${out}"
  return ${rc}
}

# 讀 run_cmd artifact 的 body（第一個 --- 到第二個 ---）
raw_body() {
  local file="$1"
  awk '''
    /^---$/ {dash++; next}
    dash==1 {print}
    dash>=2 {exit}
  ''' "${file}"
}

raw_last_body_line() {
  local file="$1"
  raw_body "${file}" | awk '''NF{line=$0} END{print line}'''
}

# VM guest 端執行（vsock）；輸出寫到 raw/<label>.txt
vm_exec() {
  local label="$1"; shift
  run_cmd "${label}" timed_run "${EXEC_TIMEOUT}" \
    "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" exec -- "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# Trap cleanup
# ═══════════════════════════════════════════════════════════════════════════

shutdown_vm() {
  [[ -z "${VM_PID:-}" ]] && { SHUTDOWN_LAST_MS="0"; return 0; }
  kill -0 "${VM_PID}" 2>/dev/null || { VM_PID=""; SHUTDOWN_LAST_MS="0"; return 0; }

  log "shutdown: SIGTERM VM host pid=${VM_PID}"
  local t0 t1
  t0="$(now_ms)"
  kill -TERM "${VM_PID}" 2>/dev/null || true
  local waited=0
  while kill -0 "${VM_PID}" 2>/dev/null && [[ ${waited} -lt ${SHUTDOWN_TIMEOUT} ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "${VM_PID}" 2>/dev/null; then
    log "shutdown: SIGKILL VM host pid=${VM_PID} (timeout)"
    kill -KILL "${VM_PID}" 2>/dev/null || true
    wait "${VM_PID}" 2>/dev/null || true
  else
    wait "${VM_PID}" 2>/dev/null || true
  fi
  t1="$(now_ms)"
  SHUTDOWN_LAST_MS="$((t1 - t0))"
  log "shutdown: done in ${SHUTDOWN_LAST_MS} ms"
  VM_PID=""
}

# 與 exec.rs::vm_lock_path 對齊：instances/<name>/rootfs-vm.lock
instance_dir() {
  find "${INST_BASE}" -maxdepth 3 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1
}

# Warm boot 前確保無殘留 openshell-vm、且 rootfs flock 已釋放（避免「另一行程仍占用 rootfs」）
wait_for_vm_release_after_shutdown() {
  local max_s="${1:-120}"
  local deadline inst_dir lock waited pids
  deadline=$(( $(date +%s) + max_s ))
  waited=0

  inst_dir="$(instance_dir)"
  lock=""
  if [[ -n "${inst_dir}" ]]; then
    lock="${inst_dir}/rootfs-vm.lock"
  fi

  while [[ $(date +%s) -lt ${deadline} ]]; do
    pids=""
    if has_cmd pgrep; then
      pids="$(pgrep -f "openshell-vm.*--name ${INSTANCE_NAME}" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    fi
    local lock_busy=0
    if [[ -n "${lock}" && -e "${lock}" ]] && has_cmd flock; then
      flock -n "${lock}" -c true 2>/dev/null || lock_busy=1
    fi

    if [[ -z "${pids}" && ${lock_busy} -eq 0 ]]; then
      log "post-shutdown: rootfs lock 與 openshell-vm 行程已就緒（${waited}s）"
      return 0
    fi

    # 首輪後若仍有殘留行程，補送 SIGTERM（父程序已關但子程序／fork 邊角）
    if [[ ${waited} -ge 3 && -n "${pids}" ]]; then
      log "post-shutdown: 殘留 openshell-vm PID=${pids}，送 SIGTERM"
      local pid
      for pid in ${pids}; do
        kill -TERM "${pid}" 2>/dev/null || true
      done
    fi

    waited=$((waited + 1))
    sleep 1
  done

  log "WARN: post-shutdown 等待逾時（${max_s}s），pids=${pids:-none} lock=${lock:-n/a}"
  return 0
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${VM_PID:-}" ]]; then
    shutdown_vm >/dev/null || true
  fi

  if has_cmd pgrep; then
    local leftover
    leftover="$(pgrep -af "gvproxy" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "${leftover}" ]]; then
      log "cleanup: kill leftover gvproxy PIDs: ${leftover}"
      echo "${leftover}" | xargs -r kill -TERM 2>/dev/null || true
    fi
  fi

  if [[ "${KEEP_INSTANCE}" != "1" ]]; then
    local inst_dir
    inst_dir="$(find "${INST_BASE}" -maxdepth 3 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1)"
    if [[ -n "${inst_dir}" ]]; then
      log "cleanup: remove instance dir ${inst_dir}"
      rm -rf "${inst_dir}" 2>>"${OUT_DIR}/run.log" || true
    fi
  fi

  emit_report_json || true
  emit_report_md || true
  log "benchmark done: exit=${rc}"
  log "report: ${OUT_DIR}/report.md"
  exit ${rc}
}
trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# Preflight + 建置
# ═══════════════════════════════════════════════════════════════════════════

preflight() {
  log "=== Preflight ==="
  local uname_s uname_m
  uname_s="$(uname -s)"; uname_m="$(uname -m)"
  log "OS=${uname_s} ARCH=${uname_m}"
  put host_os "${uname_s}"
  put host_arch "${uname_m}"

  case "${uname_s}" in
    Linux)
      if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        put precheck_kvm "ok"
      else
        put precheck_kvm "fail"
        log "WARN: /dev/kvm 無法存取（請加入 kvm 群組）"
      fi
      ;;
    Darwin)
      put precheck_kvm "n/a (macOS Hypervisor.framework)"
      ;;
  esac

  # 記錄 host 總資源供對照
  if [[ -r /proc/meminfo ]]; then
    local host_mem_kb
    host_mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    put host_total_mem_mb "$(awk -v k="${host_mem_kb}" 'BEGIN{printf "%.0f", k/1024}')"
  fi
  if [[ -r /proc/cpuinfo ]]; then
    put host_cpu_count "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"
  elif has_cmd sysctl; then
    put host_cpu_count "$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
  fi
}

ensure_built() {
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    log "SKIP_BUILD=1, 跳過建置"
    return
  fi

  if [[ -x "${OPENSHELL_VM_BIN}" ]] && [[ -d "${RUNTIME_DIR}" ]]; then
    log "build: binary + runtime 皆存在"
    return
  fi

  if ! has_cmd mise; then
    log "FAIL: 缺少 mise 且 binary 不存在，無法自動建置"
    put build_status "fail"
    exit 1
  fi

  log "build: mise run vm:setup"
  (cd "${REPO_ROOT}" && run_cmd "build-setup" mise run vm:setup) || {
    log "FAIL: vm:setup 失敗"
    put build_status "fail_setup"; exit 1
  }
  log "build: mise run vm:build"
  (cd "${REPO_ROOT}" && run_cmd "build-binary" mise run vm:build) || {
    log "FAIL: vm:build 失敗"
    put build_status "fail_build"; exit 1
  }
  put build_status "ok"
}

ensure_rootfs_ready() {
  log "precheck: validating rootfs availability"

  if ! run_cmd "precheck-rootfs" timed_run "${EXEC_TIMEOUT}" \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" prepare-rootfs; then
    log "FAIL: rootfs precheck failed before benchmark start"
    log "      binary=${OPENSHELL_VM_BIN}"
    log "      runtime_dir=${RUNTIME_DIR}"
    log "      instance_base=${INST_BASE}"
    log "      建議先執行以下任一方案後重跑："
    log "      1) ${OPENSHELL_VM_BIN} --name ${INSTANCE_NAME} prepare-rootfs"
    log "      2) (repo) mise run vm:rootfs -- --base && mise run vm:build"
    log "      3) (repo) ./crates/openshell-vm/scripts/build-rootfs.sh <output_dir>"
    log "      ---- precheck-rootfs stderr (最近 20 行) ----"
    awk 'BEGIN{buf=20} {line[NR%buf]=$0} END {start=(NR>buf?NR-buf+1:1); for(i=start;i<=NR;i++) print line[i%buf]}' \
      "${RAW_DIR}/precheck-rootfs.txt" | tee -a "${OUT_DIR}/run.log" || true
    put precheck_rootfs "fail"
    put overall_status "fail_rootfs_precheck"
    exit 1
  fi

  local rootfs_path
  rootfs_path="$(awk '
    /^# /{next}
    /^---$/{next}
    /^$/{next}
    {last=$0}
    END{print last}
  ' "${RAW_DIR}/precheck-rootfs.txt" | tr -d "\r")"
  if [[ -z "${rootfs_path}" || ! -d "${rootfs_path}" ]]; then
    log "FAIL: rootfs precheck succeeded but returned invalid path: ${rootfs_path:-<empty>}"
    log "      請先確認 rootfs 生成流程："
    log "      - ${OPENSHELL_VM_BIN} --name ${INSTANCE_NAME} prepare-rootfs"
    log "      - 或 mise run vm:rootfs -- --base && mise run vm:build"
    put precheck_rootfs "fail_invalid_path"
    put overall_status "fail_rootfs_precheck"
    exit 1
  fi

  local missing=()
  for f in bin etc srv/openshell-vm-init.sh; do
    [[ -e "${rootfs_path}/${f}" ]] || missing+=("${f}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "FAIL: rootfs layout incomplete: missing ${missing[*]}"
    log "      rootfs_path=${rootfs_path}"
    log "      建議重建 rootfs：mise run vm:rootfs -- --base"
    put precheck_rootfs "fail_incomplete_layout"
    put overall_status "fail_rootfs_precheck"
    exit 1
  fi

  log "precheck: rootfs ready at ${rootfs_path}"
  put precheck_rootfs "ok"
  put precheck_rootfs_path "${rootfs_path}"
}

# ═══════════════════════════════════════════════════════════════════════════
# VM launch / relaunch
# ═══════════════════════════════════════════════════════════════════════════

# launch_vm <tag: cold|warm>
launch_vm() {
  local tag="$1"
  local stderr="${OUT_DIR}/stderr-${tag}.log"
  local stdout="${OUT_DIR}/stdout-${tag}.log"
  VM_STDERR="${stderr}"

  log "[${tag}] launching VM (instance=${INSTANCE_NAME}, port=${GATEWAY_PORT})"
  local t0 t1 t_tcp
  t0="$(now_ms)"
  "${OPENSHELL_VM_BIN}" \
    --name "${INSTANCE_NAME}" \
    -p "${GATEWAY_PORT}:${GATEWAY_PORT}" \
    >"${stdout}" 2>"${stderr}" &
  VM_PID=$!
  echo "${VM_PID}" > "${OUT_DIR}/vm-${tag}.pid"

  # TCP 可達是第一個里程碑
  if wait_for_tcp 127.0.0.1 "${GATEWAY_PORT}" "${BOOT_TIMEOUT}"; then
    t_tcp="$(now_ms)"
    put "t_boot_${tag}_tcp_ms" "$((t_tcp - t0))"
    log "[${tag}] TCP :${GATEWAY_PORT} ready in $((t_tcp - t0)) ms"
  else
    put "t_boot_${tag}_tcp_ms" "-1"
    log "[${tag}] FAIL: TCP :${GATEWAY_PORT} 逾時 (${BOOT_TIMEOUT}s)"
    log "[${tag}] ---- 最近 stderr ----"
    tail -30 "${stderr}" | tee -a "${OUT_DIR}/run.log" || true
    return 1
  fi

  # 等到 stderr 出現 "Ready [" (libkrun 全鏈路 ready) 或 fallback 以 TCP 為準
  local ready_deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  local ready_found=0
  while [[ $(date +%s) -lt ${ready_deadline} ]]; do
    if grep -qE 'Ready \[|Bootstrap complete|Warm boot' "${stderr}" 2>/dev/null; then
      ready_found=1; break
    fi
    sleep 1
  done
  t1="$(now_ms)"
  put "t_boot_${tag}_ready_ms" "$((t1 - t0))"
  if [[ ${ready_found} -eq 1 ]]; then
    log "[${tag}] Ready 行出現，總耗時 $((t1 - t0)) ms"
    put "boot_${tag}_status" "ready"
  else
    log "[${tag}] WARN: 未見 Ready 字樣，以 TCP 為準"
    put "boot_${tag}_status" "tcp_only"
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Guest / Host snapshot
# ═══════════════════════════════════════════════════════════════════════════

# snapshot_guest <tag: steady|post_workload>
snapshot_guest() {
  local tag="$1"
  log "[guest/${tag}] snapshot"

  # meminfo
  if vm_exec "g_${tag}_meminfo" cat /proc/meminfo; then
    local mem_total_kb mem_avail_kb mem_used_kb
    mem_total_kb="$(awk '/^MemTotal:/ {print $2}' "${RAW_DIR}/g_${tag}_meminfo.txt" 2>/dev/null)"
    mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' "${RAW_DIR}/g_${tag}_meminfo.txt" 2>/dev/null)"
    if [[ -n "${mem_total_kb}" && -n "${mem_avail_kb}" ]]; then
      mem_used_kb=$((mem_total_kb - mem_avail_kb))
      put "guest_${tag}_mem_total_mb" "$(awk -v k="${mem_total_kb}" 'BEGIN{printf "%.0f", k/1024}')"
      put "guest_${tag}_mem_avail_mb" "$(awk -v k="${mem_avail_kb}" 'BEGIN{printf "%.0f", k/1024}')"
      put "guest_${tag}_mem_used_mb"  "$(awk -v k="${mem_used_kb}"  'BEGIN{printf "%.0f", k/1024}')"
    fi
  else
    put "guest_${tag}_mem_total_mb" "n/a"
  fi

  # loadavg
  if vm_exec "g_${tag}_loadavg" cat /proc/loadavg; then
    local la
    la="$(grep -Ev '^(#|---|$)' "${RAW_DIR}/g_${tag}_loadavg.txt" | tail -1 | awk '{print $1","$2","$3}')"
    put "guest_${tag}_loadavg" "${la:-n/a}"
  fi

  # df —— rootfs (virtio-fs) + state disk 掛載
  if vm_exec "g_${tag}_df" df -Pm /; then
    local used_mb avail_mb
    used_mb="$(raw_body "${RAW_DIR}/g_${tag}_df.txt" | awk 'NR==2 {print $3}' 2>/dev/null)"
    avail_mb="$(raw_body "${RAW_DIR}/g_${tag}_df.txt" | awk 'NR==2 {print $4}' 2>/dev/null)"
    put "guest_${tag}_root_used_mb"  "${used_mb:-n/a}"
    put "guest_${tag}_root_avail_mb" "${avail_mb:-n/a}"
  fi
  # state disk 常見掛載於 /var/lib/rancher/k3s 或自訂點 — 以 df 列表一次抓
  vm_exec "g_${tag}_df_all" df -hT || true

  # k3s 節點 / pods — best-effort
  if vm_exec "g_${tag}_nodes" k3s kubectl get nodes -o wide; then
    if grep -qE '\bReady\b' "${RAW_DIR}/g_${tag}_nodes.txt"; then
      put "guest_${tag}_k3s_node" "Ready"
    else
      put "guest_${tag}_k3s_node" "NotReady"
    fi
  else
    put "guest_${tag}_k3s_node" "exec_failed"
  fi

  vm_exec "g_${tag}_pods_all"  k3s kubectl get pods -A -o wide || true
  vm_exec "g_${tag}_top_nodes" k3s kubectl top nodes --no-headers || true
  vm_exec "g_${tag}_top_pods"  k3s kubectl top pods -A --no-headers || true
}

# 尋找該 instance 的 host-side VM 行程（openshell-vm 主行程）
find_vm_host_pid() {
  if [[ -n "${VM_PID:-}" ]] && kill -0 "${VM_PID}" 2>/dev/null; then
    echo "${VM_PID}"
    return 0
  fi
  if has_cmd pgrep; then
    pgrep -f "openshell-vm.*--name ${INSTANCE_NAME}" 2>/dev/null | head -1
  fi
}

# snapshot_host <tag>
snapshot_host() {
  local tag="$1"
  log "[host/${tag}] snapshot"

  local pid; pid="$(find_vm_host_pid)"
  if [[ -n "${pid}" ]]; then
    # ps 欄位：pid, rss(kB), pcpu, etime, comm, args
    local line rss_kb pcpu etime
    line="$(ps -o pid=,rss=,pcpu=,etime=,comm= -p "${pid}" 2>/dev/null | awk '{$1=$1; print}')"
    rss_kb="$(awk '{print $2}' <<<"${line}")"
    pcpu="$(awk   '{print $3}' <<<"${line}")"
    etime="$(awk  '{print $4}' <<<"${line}")"
    put "host_${tag}_pid" "${pid}"
    put "host_${tag}_mem" "$(to_mb_human "${rss_kb}k")"
    put "host_${tag}_cpu_pct" "${pcpu:-n/a}"
    put "host_${tag}_etime" "${etime:-n/a}"
    echo "${line}" > "${RAW_DIR}/h_${tag}_ps.txt"

    # child threads (libkrun vCPU threads) count
    if [[ -d "/proc/${pid}/task" ]]; then
      local nthreads; nthreads="$(ls -1 "/proc/${pid}/task" 2>/dev/null | wc -l | tr -d ' ')"
      put "host_${tag}_threads" "${nthreads}"
    fi
  else
    put "host_${tag}_pid" "n/a"
    put "host_${tag}_mem" "n/a"
    put "host_${tag}_cpu_pct" "n/a"
  fi

  # gvproxy 子行程 RSS
  if has_cmd pgrep; then
    local gvpid gv_rss
    gvpid="$(pgrep -n gvproxy 2>/dev/null || true)"
    if [[ -n "${gvpid}" ]]; then
      gv_rss="$(ps -o rss= -p "${gvpid}" 2>/dev/null | tr -d ' ')"
      put "host_${tag}_gvproxy_pid" "${gvpid}"
      put "host_${tag}_gvproxy_mem" "$(to_mb_human "${gv_rss}k")"
    fi
  fi

  # Instance 目錄實佔（rootfs 解壓 + state disk sparse 實際用量）
  local inst_dir
  inst_dir="$(find "${INST_BASE}" -maxdepth 3 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1)"
  if [[ -n "${inst_dir}" ]]; then
    put "host_${tag}_instance_dir" "${inst_dir}"
    # du -sb：實佔 byte（含 sparse 僅算 allocated block）
    local inst_bytes
    inst_bytes="$(du -sb "${inst_dir}" 2>/dev/null | awk '{print $1}')"
    put "host_${tag}_instance_bytes" "${inst_bytes:-0}"
    put "host_${tag}_instance_size"  "$(to_mb_human "${inst_bytes:-0}")"

    # 各檔案分別看（rootfs/、rootfs-state.raw）
    local rootfs_b state_b console_b
    rootfs_b="$(du -sb "${inst_dir}/rootfs" 2>/dev/null | awk '{print $1}')"
    state_b="$(du -sb "${inst_dir}/rootfs-state.raw" 2>/dev/null | awk '{print $1}')"
    console_b="$(du -sb "${inst_dir}/rootfs-console.log" 2>/dev/null | awk '{print $1}')"
    put "host_${tag}_rootfs_size"  "$(to_mb_human "${rootfs_b:-0}")"
    put "host_${tag}_state_size"   "$(to_mb_human "${state_b:-0}")"
    put "host_${tag}_console_size" "$(to_mb_human "${console_b:-0}")"
    # state.raw 的 apparent（宣告容量，預設 32 GiB）與實佔
    if [[ -f "${inst_dir}/rootfs-state.raw" ]]; then
      local apparent
      apparent="$(stat -c %s "${inst_dir}/rootfs-state.raw" 2>/dev/null \
        || stat -f %z "${inst_dir}/rootfs-state.raw" 2>/dev/null)"
      put "host_${tag}_state_apparent" "$(to_mb_human "${apparent:-0}")"
    fi

    {
      echo "# instance dir"
      ls -lah "${inst_dir}" 2>/dev/null
      echo "# du -sh children"
      du -sh "${inst_dir}"/* 2>/dev/null
    } > "${RAW_DIR}/h_${tag}_inst.txt"
  else
    put "host_${tag}_instance_dir" "n/a"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Workload —— 部署 / exec / 刪除 busybox pod
# ═══════════════════════════════════════════════════════════════════════════

run_workload() {
  if [[ "${SKIP_WORKLOAD}" == "1" ]]; then
    log "SKIP_WORKLOAD=1，跳過 busybox workload"
    return
  fi
  log "=== Workload: busybox pod lifecycle ==="

  # 先等 k3s node Ready，避免 workload 一開始就落在 cluster 尚未就緒的空窗
  local node_ready_deadline=$(( $(date +%s) + WORKLOAD_NODE_READY_TIMEOUT ))
  local node_ready=0
  while [[ $(date +%s) -lt ${node_ready_deadline} ]]; do
    if run_cmd "w_nodes_ready" timed_run 12 \
         "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" exec -- \
         k3s kubectl get nodes --no-headers; then
      if raw_body "${RAW_DIR}/w_nodes_ready.txt" | grep -qE '\bReady\b'; then
        node_ready=1
        break
      fi
    fi
    sleep 2
  done
  if [[ ${node_ready} -ne 1 ]]; then
    log "workload: k3s node 未在 ${WORKLOAD_NODE_READY_TIMEOUT}s 內 Ready，略過 pod lifecycle"
    put "workload_status" "node_not_ready"
    put "t_workload_create_ms" "-1"
    put "t_workload_ready_ms" "-1"
    put "t_workload_exec_ms" "-1"
    put "t_workload_delete_ms" "-1"
    return
  fi

  # 用「pod on the fly」—— 不等 rootfs 先 pull，直接用已內建的 busybox image
  local pod_name="bench-busybox"

  local t0 t1
  t0="$(now_ms)"
  vm_exec "w_pod_run" k3s kubectl run "${pod_name}" \
    --image=busybox --restart=Never --command -- sh -c 'sleep 600' || true
  t1="$(now_ms)"
  put "t_workload_create_ms" "$((t1 - t0))"
  log "workload: create = $((t1 - t0)) ms"

  # 等 Pod Running（可調 WORKLOAD_READY_TIMEOUT；image pull 慢時建議拉高）
  local ready_deadline=$(( $(date +%s) + WORKLOAD_READY_TIMEOUT ))
  local ready=0
  local last_phase="unknown"
  while [[ $(date +%s) -lt ${ready_deadline} ]]; do
    if run_cmd "w_pod_phase" timed_run 12 \
         "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" exec -- \
         k3s kubectl get pod "${pod_name}" -o jsonpath='{.status.phase}'; then
      local phase
      phase="$(raw_last_body_line "${RAW_DIR}/w_pod_phase.txt" | tr -d '\r ' || true)"
      last_phase="${phase:-unknown}"
      if [[ "${phase}" == "Running" ]]; then
        ready=1; break
      fi
    fi
    sleep 2
  done
  local t2; t2="$(now_ms)"
  put "t_workload_ready_ms" "$((t2 - t0))"
  if [[ ${ready} -eq 1 ]]; then
    log "workload: pod Running @ $((t2 - t0)) ms"
    put "workload_status" "running"
  else
    log "workload: pod 未達 Running（timeout=${WORKLOAD_READY_TIMEOUT}s, last_phase=${last_phase}）"
    put "workload_status" "not_running"
    # 補充診斷：常見是 image pull / CNI / scheduling 問題
    vm_exec "w_pod_describe" k3s kubectl describe pod "${pod_name}" || true
    vm_exec "w_pod_events" k3s kubectl get events --sort-by=.lastTimestamp -A | tail -60 || true
  fi

  # exec echo，量測 kubectl exec 延遲
  local t3 t4
  t3="$(now_ms)"
  vm_exec "w_pod_exec" k3s kubectl exec "${pod_name}" -- sh -c 'echo hello && uname -a' || true
  t4="$(now_ms)"
  put "t_workload_exec_ms" "$((t4 - t3))"
  log "workload: exec = $((t4 - t3)) ms"

  # 刪除
  local t5 t6
  t5="$(now_ms)"
  vm_exec "w_pod_delete" k3s kubectl delete pod "${pod_name}" --grace-period=0 --force || true
  t6="$(now_ms)"
  put "t_workload_delete_ms" "$((t6 - t5))"
  log "workload: delete = $((t6 - t5)) ms"
}

# ═══════════════════════════════════════════════════════════════════════════
# Report —— JSON + Markdown（沿用 openshell-benchmark 的風格）
# ═══════════════════════════════════════════════════════════════════════════

emit_report_json() {
  local json="${OUT_DIR}/report.json"
  {
    echo -n "{"
    echo -n "\"run_id\":\"${RUN_ID}\","
    echo -n "\"instance\":\"$(json_escape "${INSTANCE_NAME}")\","
    echo -n "\"binary\":\"$(json_escape "${OPENSHELL_VM_BIN}")\","
    echo -n "\"runtime_dir\":\"$(json_escape "${RUNTIME_DIR}")\","
    echo -n "\"gateway_port\":${GATEWAY_PORT},"
    echo -n "\"metrics\":{"
    local first=1
    if [[ -f "${METRICS}" ]]; then
      while IFS='=' read -r k v; do
        [[ -z "${k}" || "${k}" == \#* ]] && continue
        if [[ ${first} -eq 1 ]]; then first=0; else echo -n ","; fi
        # 可以解析成整數的放原值
        case "${k}" in
          t_*|host_total_mem_mb|host_cpu_count|host_*_threads|guest_*_mb|host_*_bytes|gateway_port)
            if [[ "${v}" =~ ^-?[0-9]+$ ]]; then
              printf '"%s":%s' "${k}" "${v}"
            else
              printf '"%s":"%s"' "${k}" "$(json_escape "${v}")"
            fi
            ;;
          *)
            printf '"%s":"%s"' "${k}" "$(json_escape "${v}")"
            ;;
        esac
      done < "${METRICS}"
    fi
    echo -n "}}"
  } > "${json}"
}

emit_report_md() {
  local md="${OUT_DIR}/report.md"
  {
    echo "# openshell-vm Benchmark"
    echo
    echo "- Run ID: \`${RUN_ID}\`"
    echo "- Instance: \`${INSTANCE_NAME}\`"
    echo "- Binary: \`${OPENSHELL_VM_BIN}\`"
    echo "- Runtime dir: \`${RUNTIME_DIR}\`"
    echo "- Artifact dir: \`${OUT_DIR}\`"
    echo "- Host: $(get host_os) / $(get host_arch)，RAM=$(get host_total_mem_mb) MB，CPU=$(get host_cpu_count) cores"
    echo
    echo "## 時序指標 (Timing)"
    echo
    echo "| Phase | 指標 | 值 (ms) |"
    echo "|---|---|---|"
    echo "| Cold boot  | TCP :${GATEWAY_PORT} 可達    | $(get t_boot_cold_tcp_ms) |"
    echo "| Cold boot  | stderr \"Ready\"            | $(get t_boot_cold_ready_ms) |"
    echo "| Warm boot  | TCP :${GATEWAY_PORT} 可達    | $(get t_boot_warm_tcp_ms) |"
    echo "| Warm boot  | stderr \"Ready\"            | $(get t_boot_warm_ready_ms) |"
    echo "| Workload   | kubectl run                 | $(get t_workload_create_ms) |"
    echo "| Workload   | pod Running                 | $(get t_workload_ready_ms) |"
    echo "| Workload   | kubectl exec                | $(get t_workload_exec_ms) |"
    echo "| Workload   | kubectl delete              | $(get t_workload_delete_ms) |"
    echo
    echo "## Guest 資源 (VM 內 /proc、k3s 觀點)"
    echo
    echo "| 指標 | steady | post_workload |"
    echo "|---|---|---|"
    echo "| Mem total (MB)     | $(get guest_steady_mem_total_mb)     | $(get guest_post_workload_mem_total_mb) |"
    echo "| Mem used  (MB)     | $(get guest_steady_mem_used_mb)      | $(get guest_post_workload_mem_used_mb) |"
    echo "| Mem avail (MB)     | $(get guest_steady_mem_avail_mb)     | $(get guest_post_workload_mem_avail_mb) |"
    echo "| loadavg (1/5/15)   | $(get guest_steady_loadavg)          | $(get guest_post_workload_loadavg) |"
    echo "| rootfs used (MB)   | $(get guest_steady_root_used_mb)     | $(get guest_post_workload_root_used_mb) |"
    echo "| rootfs avail (MB)  | $(get guest_steady_root_avail_mb)    | $(get guest_post_workload_root_avail_mb) |"
    echo "| k3s node 狀態      | $(get guest_steady_k3s_node)         | $(get guest_post_workload_k3s_node) |"
    echo
    echo "## Host 資源 (openshell-vm 行程、instance 目錄)"
    echo
    echo "| 指標 | steady | post_workload |"
    echo "|---|---|---|"
    echo "| openshell-vm PID   | $(get host_steady_pid)               | $(get host_post_workload_pid) |"
    echo "| RSS (MB)           | $(get host_steady_mem)               | $(get host_post_workload_mem) |"
    echo "| CPU (%)            | $(get host_steady_cpu_pct)           | $(get host_post_workload_cpu_pct) |"
    echo "| vCPU threads       | $(get host_steady_threads)           | $(get host_post_workload_threads) |"
    echo "| gvproxy RSS        | $(get host_steady_gvproxy_mem)       | $(get host_post_workload_gvproxy_mem) |"
    echo "| Instance 目錄實佔  | $(get host_steady_instance_size)     | $(get host_post_workload_instance_size) |"
    echo "| - rootfs/          | $(get host_steady_rootfs_size)       | $(get host_post_workload_rootfs_size) |"
    echo "| - state.raw 實佔   | $(get host_steady_state_size)        | $(get host_post_workload_state_size) |"
    echo "| - state.raw 宣告   | $(get host_steady_state_apparent)    | $(get host_post_workload_state_apparent) |"
    echo "| - console.log      | $(get host_steady_console_size)      | $(get host_post_workload_console_size) |"
    echo
    echo "## Workload 狀態"
    echo
    echo "- busybox pod: \`$(get workload_status)\`"
    echo
    echo "## Artifacts"
    echo
    echo "- metrics.env：\`${METRICS}\`"
    echo "- raw/：每步指令輸出"
    echo "- stderr-cold.log / stderr-warm.log：VM 啟動訊息"
    echo "- stdout-cold.log / stdout-warm.log：VM stdout"
  } > "${md}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main scenario 編排
# ═══════════════════════════════════════════════════════════════════════════

scenario_cold() {
  log "=== S1: Cold boot ==="
  # 確保 instance 不存在（真 cold）
  local existing
  existing="$(find "${INST_BASE}" -maxdepth 3 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1)"
  if [[ -n "${existing}" ]]; then
    log "cold: 移除舊 instance ${existing}"
    rm -rf "${existing}"
  fi
  launch_vm "cold"
}

scenario_warm() {
  if [[ "${SKIP_WARM}" == "1" ]]; then
    log "SKIP_WARM=1，跳過 warm-boot 量測"
    return
  fi
  log "=== S7: Warm boot ==="
  shutdown_vm
  put "t_shutdown_ms" "${SHUTDOWN_LAST_MS:-0}"
  sleep 2
  wait_for_vm_release_after_shutdown "${POST_SHUTDOWN_WAIT:-120}"
  launch_vm "warm"
}

main() {
  log "openshell-vm benchmark 啟動 (run_id=${RUN_ID})"
  log "輸出目錄: ${OUT_DIR}"

  preflight
  ensure_built
  ensure_rootfs_ready

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    log "FAIL: binary 不存在 ${OPENSHELL_VM_BIN}"
    put overall_status "fail_no_binary"
    exit 1
  fi

  scenario_cold || { put overall_status "fail_cold_boot"; exit 1; }

  log "--- steady-state snapshot ---"
  snapshot_guest "steady"
  snapshot_host  "steady"

  run_workload

  log "--- post-workload snapshot ---"
  snapshot_guest "post_workload"
  snapshot_host  "post_workload"

  scenario_warm || { put overall_status "fail_warm_boot"; exit 1; }

  put overall_status "ok"
  log "benchmark 完成"
}

main "$@"
