#!/usr/bin/env bash
set -euo pipefail

# OpenShell mount 端到端驗證腳本
# - 預設執行 build -> test -> mount validate -> general validate
# - 驗證 sandbox 內 /workspace/data 會依 OPEN_SHELL_WORKSPACE_USER_DATAPATH 切換

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${SCRIPT_DIR}/artifacts/mount-validation-${RUN_ID}"
mkdir -p "${ARTIFACT_DIR}"

BASE_DEFAULT="${SCRIPT_DIR}"
USER_DEFAULT="user01"
DATAPATH_A_DEFAULT="slk_dataUser01"
DATAPATH_B_DEFAULT="slk_data"
# IMAGE_DEFAULT="ghcr.io/nvidia/openshell/sandbox:latest"
IMAGE_DEFAULT="ghcr.io/nvidia/openshell-community/sandboxes/base:latest"

WORKSPACE_BASE="${OPEN_SHELL_WORKSPACE_BASE:-${BASE_DEFAULT}}"
WORKSPACE_USER="${OPEN_SHELL_WORKSPACE_USER:-${USER_DEFAULT}}"
DATAPATH_A="${OPEN_SHELL_WORKSPACE_USER_DATAPATH_A:-${DATAPATH_A_DEFAULT}}"
DATAPATH_B="${OPEN_SHELL_WORKSPACE_USER_DATAPATH_B:-${DATAPATH_B_DEFAULT}}"
SANDBOX_IMAGE="${OPEN_SHELL_SANDBOX_IMAGE:-${IMAGE_DEFAULT}}"
RECREATE_GATEWAY="${RECREATE_GATEWAY:-false}"
RUN_BUILD="${RUN_BUILD:-true}"
RUN_TEST="${RUN_TEST:-true}"
RUN_GENERAL_VALIDATE="${RUN_GENERAL_VALIDATE:-true}"
GENERAL_VALIDATE_ARGS="${GENERAL_VALIDATE_ARGS:-"--skip-qa"}"
RUN_BUILD_CLUSTER_IMAGE="${RUN_BUILD_CLUSTER_IMAGE:-false}"
CLUSTER_IMAGE_OVERRIDE="${CLUSTER_IMAGE_OVERRIDE:-}"
AUTO_CLUSTER_TAG="${AUTO_CLUSTER_TAG:-}"
STRICT_DEV_IMAGES="${STRICT_DEV_IMAGES:-false}"
GATEWAY_NAME="${GATEWAY_NAME:-openshell}"
OPENSHELL_BIN="${OPENSHELL_BIN:-openshell}"
CURRENT_GATEWAY_DATAPATH="${CURRENT_GATEWAY_DATAPATH:-}"

SANDBOX_A="mount-a-${RUN_ID,,}"
SANDBOX_B="mount-b-${RUN_ID,,}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${ARTIFACT_DIR}/run.log"
}

ensure_workspace_symlinks() {
  (
    cd "${SCRIPT_DIR}"
    ln -sfn "data" "slk_data"
    ln -sfn "data_user01" "slk_dataUser01"
  )
}

retarget_workspace_datapath_a_to_user02_if_symlink() {
  (
    cd "${SCRIPT_DIR}"
    # 只在 datapath A 是 symlink 時才重指向；若是實體目錄（如 data_user01）則保持原狀。
    if [[ -L "${DATAPATH_A}" ]]; then
      ln -sfn "data_user02" "${DATAPATH_A}"
      echo "retargeted ${DATAPATH_A} -> data_user02"
    else
      echo "skip retarget: ${DATAPATH_A} is not a symlink"
    fi
  )
}

restore_workspace_symlinks() {
  (
    cd "${SCRIPT_DIR}"
    ln -sfn "data" "slk_data"
    ln -sfn "data_user01" "slk_dataUser01"
  )
}

usage() {
  cat <<EOF
Usage: bash pass/openshell-mount-validate.sh [options]

Options:
  --skip-build             跳過 mise run build
  --skip-test              跳過 mise run test
  --skip-general-validate  跳過 pass/openshell-validate.sh
  --general-validate-args  傳遞給 openshell-validate.sh 的參數字串
  --build-cluster-image    執行 mise run docker:build:cluster
  --cluster-image <ref>    設定 OPENSHELL_CLUSTER_IMAGE（例如 ghcr.io/...:0.0.15）
  --auto-cluster-tag <tag> 自動設定 IMAGE_TAG，build 後改 tag 並設定 OPENSHELL_CLUSTER_IMAGE
  --strict-dev-images      僅允許本機 dev image + push mode；否則直接失敗
  --gateway-name <name>    指定 gateway 名稱（預設: openshell）
  --recreate-gateway       重建 gateway 套用 mount 相關 env
  -h, --help               顯示說明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      RUN_BUILD="false"
      shift
      ;;
    --skip-test)
      RUN_TEST="false"
      shift
      ;;
    --skip-general-validate)
      RUN_GENERAL_VALIDATE="false"
      shift
      ;;
    --general-validate-args)
      GENERAL_VALIDATE_ARGS="$2"
      shift 2
      ;;
    --build-cluster-image)
      RUN_BUILD_CLUSTER_IMAGE="true"
      shift
      ;;
    --cluster-image)
      CLUSTER_IMAGE_OVERRIDE="$2"
      shift 2
      ;;
    --auto-cluster-tag)
      AUTO_CLUSTER_TAG="$2"
      shift 2
      ;;
    --strict-dev-images)
      STRICT_DEV_IMAGES="true"
      shift
      ;;
    --gateway-name)
      GATEWAY_NAME="$2"
      shift 2
      ;;
    --recreate-gateway)
      RECREATE_GATEWAY="true"
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

run_step() {
  local label="$1"
  shift
  local out_file="${ARTIFACT_DIR}/${label}.txt"
  log "RUN: $*"
  if "$@" >"${out_file}" 2>&1; then
    log "PASS: ${label}"
    return 0
  fi
  log "FAIL: ${label} (see ${out_file})"
  return 1
}

normalize_workspace_base() {
  if [[ "${WORKSPACE_BASE}" != /* ]]; then
    WORKSPACE_BASE="$(realpath -m "${WORKSPACE_BASE}")"
  fi
}

gateway_start_env_prefix() {
  # Always pass workspace env through to gateway bootstrap so the cluster
  # container and server pod see the correct OPEN_SHELL_WORKSPACE_* values.
  # Also pass OPENSHELL_PUSH_IMAGES when set so local gateway images are imported
  # into in-cluster containerd (push mode).
  local datapath="${1:-${OPEN_SHELL_WORKSPACE_USER_DATAPATH:-}}"
  local -a prefix=(
    env
    "OPEN_SHELL_WORKSPACE_BASE=${WORKSPACE_BASE}"
    "OPEN_SHELL_WORKSPACE_USER=${WORKSPACE_USER}"
    "OPEN_SHELL_WORKSPACE_USER_DATAPATH=${datapath}"
  )
  if [[ -n "${OPENSHELL_CLUSTER_IMAGE:-}" ]]; then
    prefix+=("OPENSHELL_CLUSTER_IMAGE=${OPENSHELL_CLUSTER_IMAGE}")
  fi
  if [[ -n "${OPENSHELL_PUSH_IMAGES:-}" ]]; then
    prefix+=("OPENSHELL_PUSH_IMAGES=${OPENSHELL_PUSH_IMAGES}")
  fi
  echo "${prefix[@]}"
}

ensure_local_cluster_image_for_start() {
  local label="$1"
  if [[ "${OPENSHELL_CLUSTER_IMAGE:-}" == openshell/cluster:* ]]; then
    log "local cluster image detected (${OPENSHELL_CLUSTER_IMAGE}); rebuild before gateway start"
    run_step "${label}" mise run docker:build:cluster
  fi
}

detect_gateway_image() {
  local out_file="${ARTIFACT_DIR}/gateway_image_probe.txt"
  local pattern="openshell-cluster-${GATEWAY_NAME}"
  docker ps --filter "name=${pattern}" --format "{{.Names}}|{{.Image}}" > "${out_file}" 2>/dev/null || true
  if [[ ! -s "${out_file}" ]]; then
    log "gateway image probe: no running container matched name=${pattern}"
    return 0
  fi

  local first_line
  first_line="$(sed -n '1p' "${out_file}")"
  local container_name="${first_line%%|*}"
  local image_ref="${first_line#*|}"
  log "gateway image probe: container=${container_name}, image=${image_ref}"
}

setup_auto_cluster_image_if_needed() {
  if [[ -z "${AUTO_CLUSTER_TAG}" ]]; then
    return
  fi

  RUN_BUILD_CLUSTER_IMAGE="true"
  export IMAGE_TAG="${AUTO_CLUSTER_TAG}"
  run_step "cluster_image_tag" docker tag "openshell/cluster:${AUTO_CLUSTER_TAG}" "ghcr.io/nvidia/openshell/cluster:${AUTO_CLUSTER_TAG}"
  export OPENSHELL_CLUSTER_IMAGE="ghcr.io/nvidia/openshell/cluster:${AUTO_CLUSTER_TAG}"
  log "auto cluster image enabled: IMAGE_TAG=${IMAGE_TAG}, OPENSHELL_CLUSTER_IMAGE=${OPENSHELL_CLUSTER_IMAGE}"
}

ensure_dev_gateway_image_push_mode() {
  # 在本機 dev cluster image 場景下，若未設定 OPENSHELL_PUSH_IMAGES，
  # 會有機會回退到 registry 版本 gateway，造成 mount 行為偏差。
  if [[ "${OPENSHELL_CLUSTER_IMAGE:-}" == openshell/cluster:* ]] && [[ -z "${OPENSHELL_PUSH_IMAGES:-}" ]]; then
    export OPENSHELL_PUSH_IMAGES="openshell/gateway:dev"
    log "set OPENSHELL_PUSH_IMAGES=${OPENSHELL_PUSH_IMAGES} (default for local dev cluster image)"
  fi
}

enforce_strict_dev_images_if_enabled() {
  if [[ "${STRICT_DEV_IMAGES}" != "true" ]]; then
    return
  fi

  if [[ "${OPENSHELL_CLUSTER_IMAGE:-}" != openshell/cluster:* ]]; then
    log "FAIL: --strict-dev-images requires OPENSHELL_CLUSTER_IMAGE=openshell/cluster:* (current: ${OPENSHELL_CLUSTER_IMAGE:-<unset>})"
    exit 1
  fi
  if [[ "${OPENSHELL_PUSH_IMAGES:-}" != openshell/gateway:* ]]; then
    log "FAIL: --strict-dev-images requires OPENSHELL_PUSH_IMAGES=openshell/gateway:* (current: ${OPENSHELL_PUSH_IMAGES:-<unset>})"
    exit 1
  fi
}

cleanup() {
  log "cleanup sandboxes..."
  "${OPENSHELL_BIN}" sandbox delete "${SANDBOX_A}" >/dev/null 2>&1 || true
  "${OPENSHELL_BIN}" sandbox delete "${SANDBOX_B}" >/dev/null 2>&1 || true
  log "restore workspace symlinks..."
  restore_workspace_symlinks >/dev/null 2>&1 || true
}
trap cleanup EXIT

dump_local_sources() {
  log "dump local source files"
  if [[ -f "${SCRIPT_DIR}/data/data.txt" ]]; then
    cat "${SCRIPT_DIR}/data/data.txt" | tee "${ARTIFACT_DIR}/local_data.txt"
    echo | tee -a "${ARTIFACT_DIR}/local_data.txt" >/dev/null
  else
    log "WARN: missing ${SCRIPT_DIR}/data/data.txt"
  fi

  if [[ -f "${SCRIPT_DIR}/data_user01/data_user01.txt" ]]; then
    cat "${SCRIPT_DIR}/data_user01/data_user01.txt" | tee "${ARTIFACT_DIR}/local_data_user01.txt"
    echo | tee -a "${ARTIFACT_DIR}/local_data_user01.txt" >/dev/null
  else
    log "WARN: missing ${SCRIPT_DIR}/data_user01/data_user01.txt"
  fi
}

recreate_gateway_if_needed() {
  if [[ "${RECREATE_GATEWAY}" != "true" ]]; then
    return
  fi
  log "recreate gateway to apply mount env..."
  detect_gateway_image
  run_step "gateway_destroy" "${OPENSHELL_BIN}" gateway destroy --name "${GATEWAY_NAME}" || true
  ensure_local_cluster_image_for_start "build_cluster_image_gateway_recreate"
  # shellcheck disable=SC2207
  local -a prefix=( $(gateway_start_env_prefix "${OPEN_SHELL_WORKSPACE_USER_DATAPATH:-${DATAPATH_A}}") )
  run_step "gateway_start_recreate" "${prefix[@]}" "${OPENSHELL_BIN}" gateway start --name "${GATEWAY_NAME}" --recreate
  CURRENT_GATEWAY_DATAPATH="${OPEN_SHELL_WORKSPACE_USER_DATAPATH:-${DATAPATH_A}}"
  detect_gateway_image
}

# `openshell status` 常以 exit 0 結束，即使本機尚未設定 gateway（印出 No gateway configured）或
# 控制面無法連線（Disconnected / Error）。不可只用結束碼判斷。
gateway_control_plane_reachable() {
  local out
  out="$("${OPENSHELL_BIN}" status 2>&1)" || return 1
  if rg -q "No gateway configured" <<<"${out}"; then
    return 1
  fi
  if rg -q "Disconnected" <<<"${out}"; then
    return 1
  fi
  # gRPC health 失敗且 HTTP 亦非成功時會顯示 Error（仍可能是 exit 0）
  if rg -q "Status:.*Error" <<<"${out}"; then
    return 1
  fi
  rg -q "Connected" <<<"${out}"
}

ensure_gateway_running() {
  # The general validation expects a reachable gateway endpoint.
  if gateway_control_plane_reachable; then
    log "gateway status: reachable"
    return 0
  fi
  log "gateway status: not reachable, starting gateway..."
  ensure_local_cluster_image_for_start "build_cluster_image_gateway_start"
  # shellcheck disable=SC2207
  local -a prefix=( $(gateway_start_env_prefix "${OPEN_SHELL_WORKSPACE_USER_DATAPATH:-${DATAPATH_A}}") )
  run_step "gateway_start" "${prefix[@]}" "${OPENSHELL_BIN}" gateway start --name "${GATEWAY_NAME}"

  if gateway_control_plane_reachable; then
    log "gateway status: reachable after start"
    return 0
  fi

  log "gateway status: still not reachable, recreating gateway..."
  ensure_local_cluster_image_for_start "build_cluster_image_gateway_start_recreate_fallback"
  # shellcheck disable=SC2207
  local -a prefix=( $(gateway_start_env_prefix "${OPEN_SHELL_WORKSPACE_USER_DATAPATH:-${DATAPATH_A}}") )
  run_step "gateway_start_recreate_fallback" "${prefix[@]}" "${OPENSHELL_BIN}" gateway start --name "${GATEWAY_NAME}" --recreate
}

run_pipeline_if_needed() {
  if [[ -n "${AUTO_CLUSTER_TAG}" ]]; then
    RUN_BUILD_CLUSTER_IMAGE="true"
    export IMAGE_TAG="${AUTO_CLUSTER_TAG}"
    log "auto cluster tag requested: IMAGE_TAG=${IMAGE_TAG}"
  fi

  if [[ "${RUN_BUILD}" == "true" ]]; then
    run_step "build" mise run build
  else
    log "SKIP: build"
  fi

  if [[ "${RUN_TEST}" == "true" ]]; then
    # The Rust CLI integration tests use port 8080 for forwarding in at least one case.
    # A running local gateway also binds 8080, which can cause unrelated test failures.
    log "ensure gateway is stopped before tests (avoid port 8080 conflicts)..."
    "${OPENSHELL_BIN}" gateway destroy --name "${GATEWAY_NAME}" >/dev/null 2>&1 || true
    if ! run_step "test" mise run test; then
      log "retry: mise run test (one-shot flake retry)"
      sleep 2
      run_step "test_retry" mise run test
    fi
  else
    log "SKIP: test"
  fi

  if [[ "${RUN_BUILD_CLUSTER_IMAGE}" == "true" ]]; then
    run_step "build_cluster_image" mise run docker:build:cluster
  else
    log "SKIP: cluster image build"
  fi

  setup_auto_cluster_image_if_needed

  if [[ -n "${CLUSTER_IMAGE_OVERRIDE}" ]]; then
    export OPENSHELL_CLUSTER_IMAGE="${CLUSTER_IMAGE_OVERRIDE}"
    log "set OPENSHELL_CLUSTER_IMAGE=${OPENSHELL_CLUSTER_IMAGE}"
  else
    log "OPENSHELL_CLUSTER_IMAGE=${OPENSHELL_CLUSTER_IMAGE:-<unset>}"
  fi
  ensure_dev_gateway_image_push_mode
  enforce_strict_dev_images_if_enabled

  if [[ "${RUN_GENERAL_VALIDATE}" == "true" ]]; then
    ensure_gateway_running
    # shellcheck disable=SC2206
    local args=( ${GENERAL_VALIDATE_ARGS} )
    run_step "general_validate" bash "${SCRIPT_DIR}/openshell-validate.sh" "${args[@]}"
  else
    log "SKIP: general validate"
  fi
}

create_and_dump() {
  local sandbox_name="$1"
  local datapath="$2"
  local out_prefix="$3"

  export OPEN_SHELL_WORKSPACE_BASE="${WORKSPACE_BASE}"
  export OPEN_SHELL_WORKSPACE_USER="${WORKSPACE_USER}"
  export OPEN_SHELL_WORKSPACE_USER_DATAPATH="${datapath}"

  if [[ "${RECREATE_GATEWAY}" == "true" && "${CURRENT_GATEWAY_DATAPATH}" != "${datapath}" ]]; then
    log "recreate gateway with OPEN_SHELL_WORKSPACE_USER_DATAPATH=${datapath}"
    run_step "gateway_destroy_${out_prefix}" "${OPENSHELL_BIN}" gateway destroy --name "${GATEWAY_NAME}" || true
    ensure_local_cluster_image_for_start "build_cluster_image_${out_prefix}"
    # shellcheck disable=SC2207
    local -a prefix=( $(gateway_start_env_prefix "${datapath}") )
    run_step "gateway_start_${out_prefix}" "${prefix[@]}" "${OPENSHELL_BIN}" gateway start --name "${GATEWAY_NAME}" --recreate
    CURRENT_GATEWAY_DATAPATH="${datapath}"
    # Wait briefly for the gateway endpoint + mTLS bundle to settle.
    for _ in {1..20}; do
      if "${OPENSHELL_BIN}" status >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done
  fi

  log "create sandbox=${sandbox_name} with datapath=${datapath} and dump data dir"
  "${OPENSHELL_BIN}" sandbox delete "${sandbox_name}" >/dev/null 2>&1 || true

  # Note: `openshell sandbox create` is not idempotent for an existing name; calling it twice can
  # trigger persistence unique-constraint errors. Run the dump as the initial command instead.
  if ! "${OPENSHELL_BIN}" sandbox create --name "${sandbox_name}" --from "${SANDBOX_IMAGE}" --no-tty -- sh -lc \
    'if [ ! -d "/workspace/data" ]; then echo "DATA_DIR=<missing:/workspace/data>"; ls -la /workspace 2>/dev/null || true; ls -la /sandbox 2>/dev/null || true; exit 42; fi; DATA_DIR="/workspace/data"; echo "DATA_DIR=${DATA_DIR}"; ls -la "${DATA_DIR}" || true; echo "---"; for f in "${DATA_DIR}"/*; do [ -f "$f" ] && { echo "### $f"; cat "$f"; }; done; true' \
    2>&1 | tee "${ARTIFACT_DIR}/${out_prefix}.txt"; then
    # One-shot retry for occasional TLS handshake flake right after gateway recreate.
    if rg -q "tls handshake eof" "${ARTIFACT_DIR}/${out_prefix}.txt"; then
      log "retry sandbox create after tls handshake eof"
      sleep 2
      "${OPENSHELL_BIN}" sandbox create --name "${sandbox_name}" --from "${SANDBOX_IMAGE}" --no-tty -- sh -lc \
        'if [ ! -d "/workspace/data" ]; then echo "DATA_DIR=<missing:/workspace/data>"; ls -la /workspace 2>/dev/null || true; ls -la /sandbox 2>/dev/null || true; exit 42; fi; DATA_DIR="/workspace/data"; echo "DATA_DIR=${DATA_DIR}"; ls -la "${DATA_DIR}" || true; echo "---"; for f in "${DATA_DIR}"/*; do [ -f "$f" ] && { echo "### $f"; cat "$f"; }; done; true' \
        2>&1 | tee "${ARTIFACT_DIR}/${out_prefix}.txt"
    elif rg -q "DependenciesNotReady|provisioning timed out|failed to load flannel 'subnet.env'" "${ARTIFACT_DIR}/${out_prefix}.txt"; then
      log "retry sandbox create after cluster dependencies not ready; collect diagnostics first"
      "${OPENSHELL_BIN}" doctor check --name "${GATEWAY_NAME}" >"${ARTIFACT_DIR}/${out_prefix}_doctor_check.txt" 2>&1 || true
      "${OPENSHELL_BIN}" doctor exec -- kubectl get pods -A -o wide >"${ARTIFACT_DIR}/${out_prefix}_pods_before_retry.txt" 2>&1 || true
      "${OPENSHELL_BIN}" doctor logs --name "${GATEWAY_NAME}" --lines 200 >"${ARTIFACT_DIR}/${out_prefix}_doctor_logs_before_retry.txt" 2>&1 || true
      sleep 8
      "${OPENSHELL_BIN}" sandbox create --name "${sandbox_name}" --from "${SANDBOX_IMAGE}" --no-tty -- sh -lc \
        'if [ ! -d "/workspace/data" ]; then echo "DATA_DIR=<missing:/workspace/data>"; ls -la /workspace 2>/dev/null || true; ls -la /sandbox 2>/dev/null || true; exit 42; fi; DATA_DIR="/workspace/data"; echo "DATA_DIR=${DATA_DIR}"; ls -la "${DATA_DIR}" || true; echo "---"; for f in "${DATA_DIR}"/*; do [ -f "$f" ] && { echo "### $f"; cat "$f"; }; done; true' \
        2>&1 | tee "${ARTIFACT_DIR}/${out_prefix}.txt"
    fi
  fi

  if [[ ! -s "${ARTIFACT_DIR}/${out_prefix}.txt" ]]; then
    log "FAIL: ${out_prefix} is empty"
    exit 1
  fi
  if ! rg -q "^DATA_DIR=/workspace/data$" "${ARTIFACT_DIR}/${out_prefix}.txt"; then
    log "FAIL: ${out_prefix} missing DATA_DIR=/workspace/data marker"
    exit 1
  fi
}

download_from_sandbox() {
  local sandbox_name="$1"
  local sandbox_path="$2"
  local out_file="$3"
  local log_file="${out_file}.log"

  log "download from sandbox=${sandbox_name}: ${sandbox_path} -> ${out_file}"
  if "${OPENSHELL_BIN}" sandbox download "${sandbox_name}" "${sandbox_path}" "${out_file}" >"${log_file}" 2>&1; then
    return 0
  fi
  return 1
}

validate_dump_outputs() {
  local a_file="${ARTIFACT_DIR}/sandbox_a_dump.txt"
  local b_file="${ARTIFACT_DIR}/sandbox_b_dump.txt"

  if cmp -s "${a_file}" "${b_file}"; then
    log "FAIL: sandbox_a_dump and sandbox_b_dump are identical"
    exit 1
  fi

  if ! rg -q "this is data_user01 dir" "${a_file}"; then
    log "FAIL: sandbox_a_dump does not include data_user01 content"
    exit 1
  fi
  if ! rg -q "this is data dir" "${b_file}"; then
    log "FAIL: sandbox_b_dump does not include data content"
    exit 1
  fi
}

log "start mount validation"
normalize_workspace_base
log "artifact dir: ${ARTIFACT_DIR}"
log "workspace_base=${WORKSPACE_BASE}, workspace_user=${WORKSPACE_USER}"
log "datapath_a=${DATAPATH_A}, datapath_b=${DATAPATH_B}"
log "gateway_name=${GATEWAY_NAME}"
log "sandbox_image=${SANDBOX_IMAGE}"

run_pipeline_if_needed
ensure_workspace_symlinks
dump_local_sources
recreate_gateway_if_needed
ensure_gateway_running

create_and_dump "${SANDBOX_A}" "${DATAPATH_A}" "sandbox_a_dump"

log "retarget datapath_a (${DATAPATH_A}) -> data_user02 and re-check within same sandbox A"
retarget_workspace_datapath_a_to_user02_if_symlink | tee -a "${ARTIFACT_DIR}/run.log" >/dev/null

if download_from_sandbox "${SANDBOX_A}" "/workspace/data/data_user02.txt" "${ARTIFACT_DIR}/sandbox_a_data_user02.txt"; then
  if rg -q "this is data_user02 dir" "${ARTIFACT_DIR}/sandbox_a_data_user02.txt"; then
    log "RESULT: sandbox A mount changed after host symlink retarget (data_user02 visible)"
  else
    log "FAIL: sandbox A data_user02.txt downloaded but content mismatch"
    exit 1
  fi
else
  log "sandbox A could not download /workspace/data/data_user02.txt; verifying it still sees user01"
  if download_from_sandbox "${SANDBOX_A}" "/workspace/data/data_user01.txt" "${ARTIFACT_DIR}/sandbox_a_data_user01_after_retarget.txt"; then
    if rg -q "this is data_user01 dir" "${ARTIFACT_DIR}/sandbox_a_data_user01_after_retarget.txt"; then
      log "RESULT: sandbox A mount did NOT change after host symlink retarget (still data_user01)"
    else
      log "FAIL: sandbox A user01 verification after retarget failed (content mismatch)"
      exit 1
    fi
  else
    log "FAIL: sandbox A could not download either data_user02.txt or data_user01.txt after retarget"
    exit 1
  fi
fi

create_and_dump "${SANDBOX_B}" "${DATAPATH_B}" "sandbox_b_dump"
validate_dump_outputs

log "validation completed"
log "check artifacts:"
log "  - ${ARTIFACT_DIR}/local_data.txt"
log "  - ${ARTIFACT_DIR}/local_data_user01.txt"
log "  - ${ARTIFACT_DIR}/sandbox_a_dump.txt"
log "  - ${ARTIFACT_DIR}/sandbox_b_dump.txt"
log "  - ${ARTIFACT_DIR}/sandbox_a_data_user02.txt (or sandbox_a_data_user01_after_retarget.txt)"
log "  - ${ARTIFACT_DIR}/build.txt (if enabled)"
log "  - ${ARTIFACT_DIR}/test.txt (if enabled)"
log "  - ${ARTIFACT_DIR}/general_validate.txt (if enabled)"
