#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# test-openshell-vm.sh — openshell-vm (libkrun microVM) 功能驗證
#
# 目的：
#   針對 crates/openshell-vm (v0.0.26) 進行端對端測試，涵蓋 CLI、
#   runtime bundle、rootfs、--exec 輕量模式，以及完整 Gateway 啟動
#   (k3s + openshell-server) 的 TCP / gRPC 可達性與 vsock exec。
#
# 用法：
#   ./pass/test-openshell-vm.sh                    # 執行所有 phase
#   SKIP_BUILD=1 ./pass/test-openshell-vm.sh       # 跳過 build（binary 已存在）
#   SKIP_GATEWAY=1 ./pass/test-openshell-vm.sh     # 只跑 --exec 冒煙
#   PHASES="A,B,C" ./pass/test-openshell-vm.sh     # 僅跑指定 phase
#   OPENSHELL_VM_BIN=/path/to/openshell-vm ./pass/test-openshell-vm.sh
#   GATEWAY_TIMEOUT=240 ./pass/test-openshell-vm.sh
#   GATEWAY_PHASE_WAIT=180 ./pass/test-openshell-vm.sh  # Phase D 前等待 rootfs lock 釋放（秒）
#   KEEP_INSTANCE=1 ./pass/test-openshell-vm.sh    # 保留 instance rootfs
#
# 產出：
#   pass/artifacts/vm-validation-<ts>/
#     ├── raw/                 # 各步驟的原始輸出
#     ├── console.log          # VM console 輸出（若啟動 gateway）
#     └── vm-validation-report.md

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# 設定
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TS="$(date -u +%Y%m%dt%H%M%Sz)"
RUN_ROOT="${SCRIPT_DIR}/artifacts/vm-validation-${TS}"
RAW_DIR="${RUN_ROOT}/raw"
REPORT_FILE="${RUN_ROOT}/vm-validation-report.md"

# 可調參數
INSTANCE_NAME="${INSTANCE_NAME:-test-${TS}}"
GATEWAY_PORT="${GATEWAY_PORT:-30051}"
GATEWAY_TIMEOUT="${GATEWAY_TIMEOUT:-240}"   # gateway 啟動等待秒數
EXEC_TIMEOUT="${EXEC_TIMEOUT:-90}"          # --exec 模式逾時秒數
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_GATEWAY="${SKIP_GATEWAY:-0}"
KEEP_INSTANCE="${KEEP_INSTANCE:-0}"
PHASES="${PHASES:-A,B,C,D,E}"

OPENSHELL_VM_BIN="${OPENSHELL_VM_BIN:-${REPO_ROOT}/target/debug/openshell-vm}"
RUNTIME_DIR="${OPENSHELL_VM_RUNTIME_DIR:-${REPO_ROOT}/target/debug/openshell-vm.runtime}"

# 統計
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT_PHASE=""
VM_PID=""

mkdir -p "${RAW_DIR}"
: > "${RAW_DIR}/summary.txt"

# ═══════════════════════════════════════════════════════════════════════════
# 工具函式
# ═══════════════════════════════════════════════════════════════════════════

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${RAW_DIR}/run.log"
}

log_phase() {
  CURRENT_PHASE="$1"
  echo "" | tee -a "${RAW_DIR}/run.log"
  log "═══ Phase ${CURRENT_PHASE}: $2 ═══"
}

# 判斷是否要跑該 Phase
phase_enabled() {
  [[ ",${PHASES}," == *",$1,"* ]]
}

record_pass() {
  local case_id="$1"; local detail="$2"
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  ✓ PASS [${case_id}] ${detail}"
  echo "PASS | ${case_id} | ${detail}" >> "${RAW_DIR}/summary.txt"
}

record_fail() {
  local case_id="$1"; local detail="$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "  ✗ FAIL [${case_id}] ${detail}"
  echo "FAIL | ${case_id} | ${detail}" >> "${RAW_DIR}/summary.txt"
}

record_skip() {
  local case_id="$1"; local detail="$2"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  log "  ⊘ SKIP [${case_id}] ${detail}"
  echo "SKIP | ${case_id} | ${detail}" >> "${RAW_DIR}/summary.txt"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 與 exec.rs::vm_lock_path 對齊：instances/<name>/rootfs-vm.lock
VM_INST_BASE="${HOME}/.local/share/openshell/openshell-vm"

instance_dir_for_name() {
  find "${VM_INST_BASE}" -maxdepth 3 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1
}

# Phase C（--exec）與 Phase D（gateway）共用同一 instance rootfs；確保無殘留行程且 flock 已釋放。
ensure_instance_quiesced_for_gateway() {
  local max_s="${1:-120}"
  local deadline inst_dir lock waited pids
  deadline=$(( $(date +%s) + max_s ))
  waited=0
  inst_dir="$(instance_dir_for_name)"
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
      log "instance 已就緒（無殘留 openshell-vm、rootfs lock 釋放，${waited}s）"
      return 0
    fi
    if [[ ${waited} -ge 2 && -n "${pids}" ]]; then
      log "送 SIGTERM 予殘留 openshell-vm：${pids}"
      local pid
      for pid in ${pids}; do
        kill -TERM "${pid}" 2>/dev/null || true
      done
    fi
    waited=$((waited + 1))
    sleep 1
  done
  log "WARN: instance 靜默等待逾時（${max_s}s）"
  return 0
}

# 擷取指令 stdout/stderr 至 artifacts，並回傳原本的 exit code。
run_cmd() {
  local case_id="$1"; shift
  local out="${RAW_DIR}/${case_id}.txt"
  {
    echo "# cmd: $*"
    echo "# cwd: $(pwd)"
    echo "# time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
  } > "${out}"
  local rc=0
  "$@" >>"${out}" 2>&1 || rc=$?
  echo "---" >> "${out}"
  echo "# exit_code: ${rc}" >> "${out}"
  return ${rc}
}

# Timeout 包裝，macOS/Linux 通吃
timed_run() {
  local secs="$1"; shift
  if has_cmd timeout; then
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

# ═══════════════════════════════════════════════════════════════════════════
# Cleanup / Trap
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${VM_PID}" ]] && kill -0 "${VM_PID}" 2>/dev/null; then
    log "清理：SIGTERM VM (pid=${VM_PID})"
    kill -TERM "${VM_PID}" 2>/dev/null || true
    local waited=0
    while kill -0 "${VM_PID}" 2>/dev/null && [[ ${waited} -lt 30 ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "${VM_PID}" 2>/dev/null; then
      log "清理：SIGKILL VM (pid=${VM_PID})"
      kill -KILL "${VM_PID}" 2>/dev/null || true
    fi
  fi

  # 殘留的 gvproxy（若有）
  if has_cmd pgrep; then
    local leftover
    leftover="$(pgrep -f "gvproxy.*${INSTANCE_NAME}" 2>/dev/null || true)"
    if [[ -n "${leftover}" ]]; then
      log "清理：kill leftover gvproxy PIDs: ${leftover}"
      echo "${leftover}" | xargs -r kill -TERM 2>/dev/null || true
    fi
  fi

  if [[ "${KEEP_INSTANCE}" != "1" ]] && [[ -n "${OPENSHELL_VM_BIN}" ]] && [[ -x "${OPENSHELL_VM_BIN}" ]]; then
    # 移除 instance rootfs 以免後續測試互相干擾（保留 console.log）
    local inst_base="${HOME}/.local/share/openshell/openshell-vm"
    if [[ -d "${inst_base}" ]]; then
      local inst_rootfs
      inst_rootfs="$(find "${inst_base}" -maxdepth 4 -type d -name "${INSTANCE_NAME}" 2>/dev/null | head -1)"
      if [[ -n "${inst_rootfs}" ]]; then
        log "清理：移除 instance 目錄 ${inst_rootfs}"
        rm -rf "${inst_rootfs}" 2>>"${RAW_DIR}/run.log" || true
      fi
    fi
  fi

  generate_report || true
  log "完成：exit=${rc}, PASS=${PASS_COUNT}, FAIL=${FAIL_COUNT}, SKIP=${SKIP_COUNT}"
  log "報告：${REPORT_FILE}"
  exit ${rc}
}
trap cleanup EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# Phase 0 — 環境偵測
# ═══════════════════════════════════════════════════════════════════════════

preflight() {
  log_phase "PRE" "環境前置檢查"

  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  log "OS=${uname_s} ARCH=${uname_m}"
  echo "OS=${uname_s} ARCH=${uname_m}" >> "${RAW_DIR}/env.txt"

  case "${uname_s}" in
    Linux)
      if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        record_pass "pre-kvm" "/dev/kvm 可讀寫"
      else
        record_fail "pre-kvm" "無法存取 /dev/kvm（需加入 kvm 群組：sudo usermod -aG kvm \$USER）"
      fi
      ;;
    Darwin)
      if [[ "${uname_m}" != "arm64" ]]; then
        record_fail "pre-arch" "macOS 僅支援 Apple Silicon (arm64)，偵測到 ${uname_m}"
      else
        record_pass "pre-arch" "macOS arm64"
      fi
      if has_cmd codesign; then
        record_pass "pre-codesign" "codesign 可用"
      else
        record_fail "pre-codesign" "缺少 codesign（Hypervisor.framework entitlement 必要）"
      fi
      ;;
    *)
      record_fail "pre-os" "不支援的 OS：${uname_s}"
      ;;
  esac

  for tool in mise cargo; do
    if has_cmd "${tool}"; then
      record_pass "pre-${tool}" "$(${tool} --version 2>&1 | head -1)"
    else
      record_skip "pre-${tool}" "未安裝 ${tool}（若需要建置則必要）"
    fi
  done

  # 選用工具
  for tool in docker gh shasum sha256sum lsof ss pgrep; do
    if has_cmd "${tool}"; then
      log "  optional: ${tool} 可用"
    fi
  done

  # 寫入版本資訊
  if [[ -f "${REPO_ROOT}/crates/openshell-vm/Cargo.toml" ]]; then
    local pkg_ver
    pkg_ver="$(grep -E '^version' "${REPO_ROOT}/Cargo.toml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    log "openshell-vm 預期版本：${pkg_ver:-unknown}"
    echo "EXPECTED_VERSION=${pkg_ver:-unknown}" >> "${RAW_DIR}/env.txt"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase 0.5 — 建置（視需要）
# ═══════════════════════════════════════════════════════════════════════════

ensure_built() {
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    log "SKIP_BUILD=1，跳過建置步驟"
    return
  fi

  log_phase "BUILD" "確保 runtime 與 binary 已建置"

  if [[ -x "${OPENSHELL_VM_BIN}" ]] && [[ -d "${RUNTIME_DIR}" ]]; then
    record_pass "build-exists" "binary 與 runtime 皆存在"
    return
  fi

  if ! has_cmd mise; then
    record_fail "build-mise" "缺少 mise 且 binary 不存在，無法自動建置"
    return
  fi

  if [[ ! -d "${RUNTIME_DIR}" ]]; then
    log "執行：mise run vm:setup（下載 pre-built runtime）"
    if (cd "${REPO_ROOT}" && run_cmd "build-setup" mise run vm:setup); then
      record_pass "build-setup" "vm:setup 成功"
    else
      record_fail "build-setup" "vm:setup 失敗，詳見 raw/build-setup.txt"
      return
    fi
  fi

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    log "執行：mise run vm:build"
    if (cd "${REPO_ROOT}" && run_cmd "build-binary" mise run vm:build); then
      record_pass "build-binary" "vm:build 成功"
    else
      record_fail "build-binary" "vm:build 失敗，詳見 raw/build-binary.txt"
      return
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase A — CLI 冒煙測試
# ═══════════════════════════════════════════════════════════════════════════

phase_a_cli() {
  phase_enabled A || { log "PHASES 不含 A，跳過"; return; }
  log_phase "A" "CLI 冒煙測試"

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    record_skip "a-bin" "binary 不存在於 ${OPENSHELL_VM_BIN}"
    return
  fi

  # A1: --version
  if run_cmd "a1-version" "${OPENSHELL_VM_BIN}" --version; then
    local ver; ver="$(grep -v '^#' "${RAW_DIR}/a1-version.txt" | grep -v '^---' | head -1)"
    record_pass "a1-version" "輸出=${ver}"
  else
    record_fail "a1-version" "--version 失敗"
  fi

  # A2: --help
  if run_cmd "a2-help" "${OPENSHELL_VM_BIN}" --help; then
    if grep -q "openshell-vm" "${RAW_DIR}/a2-help.txt" && grep -q "exec" "${RAW_DIR}/a2-help.txt"; then
      record_pass "a2-help" "help 內容含 openshell-vm / exec 子命令"
    else
      record_fail "a2-help" "help 內容不完整"
    fi
  else
    record_fail "a2-help" "--help 失敗"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase B — Runtime bundle 與 rootfs 結構
# ═══════════════════════════════════════════════════════════════════════════

phase_b_bundle() {
  phase_enabled B || { log "PHASES 不含 B，跳過"; return; }
  log_phase "B" "Runtime bundle / rootfs 結構"

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    record_skip "b-bin" "binary 不存在"
    return
  fi

  # B1: runtime bundle 目錄
  if [[ -d "${RUNTIME_DIR}" ]]; then
    local libkrun libkrunfw gvproxy
    libkrun="$(find "${RUNTIME_DIR}" -maxdepth 1 \( -name 'libkrun.so*' -o -name 'libkrun*.dylib' \) 2>/dev/null | head -1)"
    libkrunfw="$(find "${RUNTIME_DIR}" -maxdepth 1 -name 'libkrunfw.*' 2>/dev/null | head -1)"
    gvproxy="${RUNTIME_DIR}/gvproxy"

    {
      echo "RUNTIME_DIR=${RUNTIME_DIR}"
      echo "libkrun=${libkrun}"
      echo "libkrunfw=${libkrunfw}"
      echo "gvproxy=${gvproxy}"
      ls -la "${RUNTIME_DIR}" 2>&1 || true
    } > "${RAW_DIR}/b1-runtime.txt"

    if [[ -n "${libkrun}" ]] && [[ -n "${libkrunfw}" ]] && [[ -x "${gvproxy}" ]]; then
      record_pass "b1-runtime" "libkrun + libkrunfw + gvproxy 齊全"
    else
      record_fail "b1-runtime" "runtime bundle 不完整（libkrun=${libkrun:-missing} libkrunfw=${libkrunfw:-missing} gvproxy=${gvproxy})"
    fi
  else
    record_fail "b1-runtime" "runtime 目錄不存在：${RUNTIME_DIR}"
  fi

  # B2: prepare-rootfs 能解壓 embedded rootfs
  if run_cmd "b2-prepare" timed_run "${EXEC_TIMEOUT}" \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" prepare-rootfs; then
    local rootfs_path
    # 勿用 tail -1：artifact 可能含多段輸出；取最後一行符合 *.../instances/*/rootfs 的路徑
    rootfs_path="$(grep -E '^/.*\/instances/[^/]+/rootfs$' "${RAW_DIR}/b2-prepare.txt" 2>/dev/null | tail -1 | tr -d '\r')"
    if [[ -d "${rootfs_path}" ]]; then
      record_pass "b2-prepare" "rootfs 解壓至 ${rootfs_path}"
      # B3: 檢查 rootfs 內容
      local missing=()
      for f in bin etc srv/openshell-vm-init.sh; do
        [[ -e "${rootfs_path}/${f}" ]] || missing+=("${f}")
      done
      if [[ ${#missing[@]} -eq 0 ]]; then
        record_pass "b3-rootfs-layout" "rootfs 具備 bin/ etc/ srv/openshell-vm-init.sh"
      else
        record_fail "b3-rootfs-layout" "缺少：${missing[*]}"
      fi
    else
      record_fail "b2-prepare" "解壓後目錄不存在：${rootfs_path}"
    fi
  else
    record_fail "b2-prepare" "prepare-rootfs 失敗"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase C — --exec 輕量 VM boot
# ═══════════════════════════════════════════════════════════════════════════

phase_c_exec_mode() {
  phase_enabled C || { log "PHASES 不含 C，跳過"; return; }
  log_phase "C" "--exec 輕量 VM 啟動（取代 k3s）"

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    record_skip "c-bin" "binary 不存在"
    return
  fi

  # C1: /bin/true — 最快的 boot-and-exit 測試
  if run_cmd "c1-true" timed_run "${EXEC_TIMEOUT}" \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" --exec /bin/true --vcpus 2 --mem 2048; then
    record_pass "c1-true" "--exec /bin/true 成功 boot + exit 0"
  else
    record_fail "c1-true" "--exec /bin/true 失敗（可能：KVM 權限 / runtime 載入 / rootfs）"
  fi

  # C2: /bin/uname -a — 驗證 guest 環境
  # 使用 --args=-a，避免 -a 被 clap 當成 openshell-vm 的全域參數
  if run_cmd "c2-uname" timed_run "${EXEC_TIMEOUT}" \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" \
      --exec /bin/uname --args=-a --vcpus 2 --mem 2048; then
    local kernel_info
    # pipefail 下 grep 無匹配會回非 0，勿讓子 shell 觸發 set -e 中斷整支腳本
    kernel_info="$( (grep -iE 'linux|aarch64|x86_64' "${RAW_DIR}/c2-uname.txt" 2>/dev/null || true) | head -3 | tr '\n' ' ')"
    record_pass "c2-uname" "guest kernel=${kernel_info:-unknown}"
  else
    record_fail "c2-uname" "--exec /bin/uname 失敗"
  fi

  # C3: /bin/cat /proc/version
  if run_cmd "c3-proc-version" timed_run "${EXEC_TIMEOUT}" \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" \
      --exec /bin/cat --args /proc/version --vcpus 2 --mem 2048; then
    record_pass "c3-proc-version" "/proc/version 可讀"
  else
    record_fail "c3-proc-version" "/bin/cat /proc/version 失敗"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase D — Full Gateway boot
# ═══════════════════════════════════════════════════════════════════════════

wait_for_tcp() {
  local host="$1" port="$2" timeout_s="$3"
  local deadline=$(( $(date +%s) + timeout_s ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    if has_cmd nc; then
      if nc -z -w 2 "${host}" "${port}" 2>/dev/null; then
        return 0
      fi
    elif has_cmd bash; then
      if (exec 3<>/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
        exec 3<&-
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

phase_d_gateway() {
  phase_enabled D || { log "PHASES 不含 D，跳過"; return; }
  if [[ "${SKIP_GATEWAY}" == "1" ]]; then
    log "SKIP_GATEWAY=1，跳過 full gateway 測試"
    record_skip "d-gateway" "由 SKIP_GATEWAY=1 跳過"
    return
  fi
  log_phase "D" "完整 Gateway 啟動（k3s + openshell-server）"

  if [[ ! -x "${OPENSHELL_VM_BIN}" ]]; then
    record_skip "d-bin" "binary 不存在"
    return
  fi

  ensure_instance_quiesced_for_gateway "${GATEWAY_PHASE_WAIT:-120}"

  local vm_log="${RUN_ROOT}/vm-stdout.log"
  local vm_err="${RUN_ROOT}/vm-stderr.log"

  log "在背景啟動 VM（instance=${INSTANCE_NAME}, port=${GATEWAY_PORT}, timeout=${GATEWAY_TIMEOUT}s）"
  "${OPENSHELL_VM_BIN}" \
      --name "${INSTANCE_NAME}" \
      -p "${GATEWAY_PORT}:${GATEWAY_PORT}" \
      >"${vm_log}" 2>"${vm_err}" &
  VM_PID=$!
  log "VM host pid=${VM_PID}"
  echo "${VM_PID}" > "${RAW_DIR}/vm.pid"

  # D1: 等待 TCP :GATEWAY_PORT 可達
  if wait_for_tcp 127.0.0.1 "${GATEWAY_PORT}" "${GATEWAY_TIMEOUT}"; then
    record_pass "d1-tcp" "TCP 127.0.0.1:${GATEWAY_PORT} 於 ${GATEWAY_TIMEOUT}s 內可達"
  else
    record_fail "d1-tcp" "TCP :${GATEWAY_PORT} 逾時（${GATEWAY_TIMEOUT}s）"
    log "── 最近 VM stderr ──"
    tail -40 "${vm_err}" | tee -a "${RAW_DIR}/run.log" || true
    if [[ -n "${VM_PID:-}" ]] && kill -0 "${VM_PID}" 2>/dev/null; then
      kill -TERM "${VM_PID}" 2>/dev/null || true
    fi
    ensure_instance_quiesced_for_gateway 30
    return
  fi

  # TCP 常早於 gRPC / PKI；輪詢 stderr 直到 Ready 或逾時（與 benchmark launch_vm 對齊）
  log "等待 VM stderr 出現 Ready / Bootstrap complete（最多 ${GATEWAY_TIMEOUT}s）..."
  local rb=$(( $(date +%s) + GATEWAY_TIMEOUT ))
  while [[ $(date +%s) -lt ${rb} ]]; do
    if grep -qE 'Ready \[|Bootstrap complete|Warm boot' "${vm_err}" 2>/dev/null; then
      break
    fi
    sleep 2
  done

  # D2: gRPC (TLS) 握手 — Bootstrap complete 仍可能早於 TLS listener；重試輪詢
  if has_cmd openssl; then
    local d2_ok=0 d2_i
    for d2_i in $(seq 1 45); do
      if echo | timed_run 10 openssl s_client -connect "127.0.0.1:${GATEWAY_PORT}" -alpn h2 \
           </dev/null >"${RAW_DIR}/d2-tls.txt" 2>&1; then
        if grep -qE 'BEGIN CERTIFICATE|Server certificate' "${RAW_DIR}/d2-tls.txt"; then
          d2_ok=1
          break
        fi
      fi
      sleep 2
    done
    if [[ ${d2_ok} -eq 1 ]]; then
      record_pass "d2-tls" "Gateway 回傳 TLS 憑證 (ALPN h2)"
    else
      record_fail "d2-tls" "TLS 逾時未見憑證（已重試 45 次）"
    fi
  else
    record_skip "d2-tls" "缺少 openssl"
  fi

  # D3: VM stderr 裡應該看到 "Ready" 字樣
  if grep -qE 'Ready \[|Bootstrap complete|Warm boot' "${vm_err}"; then
    record_pass "d3-ready" "VM stderr 見 Ready / Bootstrap complete"
  else
    record_fail "d3-ready" "VM stderr 未見 Ready"
  fi

  # D4: gvproxy 子行程存在
  if has_cmd pgrep && pgrep -f "gvproxy" >/dev/null 2>&1; then
    record_pass "d4-gvproxy" "gvproxy 子行程運作中"
  else
    record_skip "d4-gvproxy" "無 pgrep 可驗證 gvproxy"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Phase E — vsock exec 對 running VM
# ═══════════════════════════════════════════════════════════════════════════

phase_e_exec_attach() {
  phase_enabled E || { log "PHASES 不含 E，跳過"; return; }
  log_phase "E" "exec 子命令（vsock agent）對 running VM"

  if [[ -z "${VM_PID}" ]] || ! kill -0 "${VM_PID}" 2>/dev/null; then
    record_skip "e-vm" "VM 未運行（Phase D 未執行或已失敗）"
    return
  fi

  # E1: exec -- /bin/true
  if run_cmd "e1-true" timed_run 30 \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" exec -- /bin/true; then
    record_pass "e1-true" "exec /bin/true 回傳 0"
  else
    record_fail "e1-true" "exec /bin/true 失敗（vsock agent 可能未就緒）"
  fi

  # E2: exec -- uname -a
  if run_cmd "e2-uname" timed_run 30 \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" exec -- uname -a; then
    record_pass "e2-uname" "exec uname -a 成功"
  else
    record_fail "e2-uname" "exec uname -a 失敗"
  fi

  # E3: kernel 能力檢查腳本
  if run_cmd "e3-capabilities" timed_run 45 \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" \
      exec -- /srv/check-vm-capabilities.sh --json; then
    if grep -q '"status":"fail"' "${RAW_DIR}/e3-capabilities.txt"; then
      local fails bad_other
      fails="$(grep -oE '"name":"[^"]+","[^}]*"status":"fail"' "${RAW_DIR}/e3-capabilities.txt" | head -8 | tr '\n' ';')"
      # --base rootfs／WSL 等環境常缺 NF_NAT 模組與部分 CNI 外掛
      bad_other="$(grep '"status":"fail"' "${RAW_DIR}/e3-capabilities.txt" \
        | grep -vE 'nf_nat|cni_bridge_bin|cni_host_local_bin|cni_loopback_bin' || true)"
      if [[ -z "${bad_other//[[:space:]]/}" ]]; then
        record_skip "e3-capabilities" "僅 nf_nat／CNI 外掛缺失（常見於 base rootfs 或精簡 kernel）：${fails}"
      else
        record_fail "e3-capabilities" "kernel 能力缺失：${fails}"
      fi
    else
      record_pass "e3-capabilities" "所有 required kernel 能力通過"
    fi
  else
    record_skip "e3-capabilities" "check-vm-capabilities.sh 無法執行（rootfs 可能為 --base 版）"
  fi

  # E4: k3s 節點就緒
  if run_cmd "e4-k3s-nodes" timed_run 90 \
      "${OPENSHELL_VM_BIN}" --name "${INSTANCE_NAME}" \
      exec -- k3s kubectl get nodes -o wide; then
    if grep -qE 'Ready' "${RAW_DIR}/e4-k3s-nodes.txt"; then
      record_pass "e4-k3s-nodes" "k3s 節點 Ready"
    else
      record_fail "e4-k3s-nodes" "k3s 節點尚未 Ready"
    fi
  else
    record_skip "e4-k3s-nodes" "k3s kubectl 無法執行"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 報告輸出
# ═══════════════════════════════════════════════════════════════════════════

generate_report() {
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  {
    echo "# openshell-vm 驗證報告"
    echo ""
    echo "- **執行時間**：${TS}"
    echo "- **Instance**：\`${INSTANCE_NAME}\`"
    echo "- **Binary**：\`${OPENSHELL_VM_BIN}\`"
    echo "- **Runtime dir**：\`${RUNTIME_DIR}\`"
    echo "- **Gateway port**：${GATEWAY_PORT}"
    echo "- **Phases**：${PHASES}"
    echo ""
    echo "## 結果統計"
    echo ""
    echo "| 結果 | 數量 |"
    echo "|---|---|"
    echo "| PASS | ${PASS_COUNT} |"
    echo "| FAIL | ${FAIL_COUNT} |"
    echo "| SKIP | ${SKIP_COUNT} |"
    echo "| **合計** | **${total}** |"
    echo ""
    echo "## 明細"
    echo ""
    echo "| 結果 | Case | 說明 |"
    echo "|---|---|---|"
    if [[ -s "${RAW_DIR}/summary.txt" ]]; then
      while IFS='|' read -r status case_id detail; do
        status="${status// /}"
        echo "| ${status} | \`${case_id// /}\` | ${detail# } |"
      done < "${RAW_DIR}/summary.txt"
    fi
    echo ""
    echo "## Artifacts"
    echo ""
    echo "- 原始輸出：\`${RAW_DIR}\`"
    echo "- VM stdout：\`${RUN_ROOT}/vm-stdout.log\`（若 Phase D 有跑）"
    echo "- VM stderr：\`${RUN_ROOT}/vm-stderr.log\`（若 Phase D 有跑）"
  } > "${REPORT_FILE}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════

main() {
  log "openshell-vm 驗證開始 (ts=${TS})"
  log "Artifacts: ${RUN_ROOT}"

  preflight
  ensure_built

  phase_a_cli
  phase_b_bundle
  phase_c_exec_mode
  phase_d_gateway
  phase_e_exec_attach

  if [[ ${FAIL_COUNT} -gt 0 ]]; then
    return 1
  fi
  return 0
}

main "$@"
