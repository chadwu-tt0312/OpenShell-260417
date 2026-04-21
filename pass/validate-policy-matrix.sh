#!/usr/bin/env bash
set -euo pipefail

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date -u +%Y%m%dt%H%M%Sz)"
RUN_ROOT="${SCRIPT_DIR}/artifacts/policy-validation-${TS}"
RAW_DIR="${RUN_ROOT}/raw"
POLICY_DIR="${RUN_ROOT}/policies"
REPORT_FILE="${RUN_ROOT}/policy-validation-report.md"

SANDBOX_NAME="${SANDBOX_NAME:-policy-matrix-${TS}}"
KEEP_SANDBOX="${KEEP_SANDBOX:-false}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

mkdir -p "${RAW_DIR}" "${POLICY_DIR}"

log() {
  local msg="$1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${msg}" | tee -a "${RAW_DIR}/run.log"
}

record_pass() {
  local case_id="$1"
  local detail="$2"
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "- ${case_id}: PASS - ${detail}" >> "${RAW_DIR}/summary.txt"
}

record_fail() {
  local case_id="$1"
  local detail="$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "- ${case_id}: FAIL - ${detail}" >> "${RAW_DIR}/summary.txt"
}

write_policy_file() {
  local file="$1"
  cat > "${file}"
}

cleanup() {
  if [[ "${KEEP_SANDBOX}" == "true" ]]; then
    log "KEEP_SANDBOX=true, skip cleanup."
    return
  fi
  log "Cleaning sandbox ${SANDBOX_NAME}"
  openshell sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_cmd() {
  local case_id="$1"
  local step="$2"
  shift 2
  local out="${RAW_DIR}/${case_id}_${step}.txt"
  if "$@" >"${out}" 2>&1; then
    write_plain_output "${out}"
    return 0
  fi
  write_plain_output "${out}"
  return 1
}

write_plain_output() {
  local source_file="$1"
  local plain_file="${source_file%.txt}.plain.txt"
  python3 - <<'PY' "${source_file}" "${plain_file}"
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
text = source.read_bytes().decode("utf-8", "replace")
plain = re.sub(r"\x1B\[[0-?]*[ -/]*[@-~]", "", text)
target.write_text(plain, encoding="utf-8")
PY
}

extract_curl_exit_code() {
  local path="$1"
  python3 - <<'PY' "$path"
import re, sys
data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
m = re.search(r"curl: \((\d+)\)", data)
print(m.group(1) if m else "")
PY
}

build_policy_decision_hint() {
  local http_code="$1"
  local curl_exit="$2"
  if [[ "${http_code}" == "000" && -n "${curl_exit}" ]]; then
    echo "policy_deny_or_tunnel_block"
    return
  fi
  if [[ "${http_code}" == "403" ]]; then
    echo "policy_or_upstream_forbidden"
    return
  fi
  if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "allowed"
    return
  fi
  echo "upstream_or_other_error"
}

write_http_result_json() {
  local case_id="$1"
  local step="$2"
  local out_file="$3"
  local http_code="$4"
  local curl_exit="$5"
  local decision_hint="$6"
  local request_file="${RAW_DIR}/${case_id}_${step}.request.txt"
  local result_file="${RAW_DIR}/${case_id}_${step}.result.json"
  python3 - <<'PY' "$case_id" "$step" "$out_file" "$http_code" "$curl_exit" "$decision_hint" "$request_file" "$result_file"
import json
import pathlib
import sys

case_id, step, raw_output_file, http_code, curl_exit_code, hint, request_file, result_file = sys.argv[1:]
request_path = pathlib.Path(request_file)
payload = {
    "case_id": case_id,
    "step": step,
    "http_code": http_code,
    "curl_exit_code": int(curl_exit_code) if curl_exit_code else None,
    "policy_decision_hint": hint,
    "request_file": request_file,
    "raw_output_file": raw_output_file,
    "request_command": request_path.read_text(encoding="utf-8").strip() if request_path.exists() else "",
}
pathlib.Path(result_file).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

run_http_probe() {
  local case_id="$1"
  local step="$2"
  local url="$3"
  local method="$4"
  local body="${5:-}"
  local out_file="${RAW_DIR}/${case_id}_${step}.txt"
  local request_file="${RAW_DIR}/${case_id}_${step}.request.txt"
  local cmd
  if [[ -n "${body}" ]]; then
    cmd="curl -sS --http1.1 -o /dev/null -w '%{http_code}' --max-time 20 -X ${method} '${url}' -H 'Content-Type: application/json' -d '${body}'"
  else
    cmd="curl -sS --http1.1 -o /dev/null -w '%{http_code}' --max-time 20 -X ${method} '${url}'"
  fi
  printf "%s\n" "${cmd}" > "${request_file}"
  sandbox_exec "${case_id}" "${step}" "${cmd}" > "${out_file}" 2>&1 || true
  write_plain_output "${out_file}"

  local http_code
  http_code="$(first_http_code "${out_file}")"
  local curl_exit_code
  curl_exit_code="$(extract_curl_exit_code "${out_file}")"
  local decision_hint
  decision_hint="$(build_policy_decision_hint "${http_code}" "${curl_exit_code}")"
  write_http_result_json "${case_id}" "${step}" "${out_file}" "${http_code}" "${curl_exit_code}" "${decision_hint}"

  printf "%s" "${http_code}"
}

sandbox_exec() {
  local case_id="$1"
  local step="$2"
  local cmd="$3"
  local cfg="${RAW_DIR}/ssh_config_${SANDBOX_NAME}"
  openshell sandbox ssh-config "${SANDBOX_NAME}" > "${cfg}" 2>"${RAW_DIR}/${case_id}_${step}_sshcfg.err"
  local ssh_host
  ssh_host="$(awk '/^Host / {print $2; exit}' "${cfg}")"
  ssh -F "${cfg}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20 \
    "${ssh_host}" "${cmd}"
}

apply_policy() {
  local case_id="$1"
  local policy_file="$2"
  run_cmd "${case_id}" "policy_set" openshell policy set "${SANDBOX_NAME}" --policy "${policy_file}" --wait
}

expect_http_code_any() {
  local case_id="$1"
  local step="$2"
  local url="$3"
  local method="$4"
  shift 4
  local expected_codes=("$@")
  local got
  got="$(run_http_probe "${case_id}" "${step}" "${url}" "${method}")"
  for code in "${expected_codes[@]}"; do
    if [[ "${got}" == "${code}" ]]; then
      return 0
    fi
  done
  return 1
}

first_http_code() {
  local path="$1"
  python3 - <<'PY' "$path"
import re, sys
p = sys.argv[1]
data = open(p, "rb").read().decode("utf-8", "replace")
m = re.search(r"([0-9]{3})", data)
print(m.group(1) if m else "")
PY
}

expect_http_code() {
  local case_id="$1"
  local step="$2"
  local url="$3"
  local method="$4"
  local expected="$5"
  local body="${6:-}"
  local got
  got="$(run_http_probe "${case_id}" "${step}" "${url}" "${method}" "${body}")"
  [[ "${got}" == "${expected}" ]]
}

expect_not_http_code() {
  local case_id="$1"
  local step="$2"
  local url="$3"
  local method="$4"
  local forbidden="$5"
  local got
  got="$(run_http_probe "${case_id}" "${step}" "${url}" "${method}")"
  [[ "${got}" != "${forbidden}" ]]
}

bootstrap_policy_file() {
  local file="${POLICY_DIR}/bootstrap.yaml"
  cat > "${file}" <<'YAML'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies: {}
YAML
  echo "${file}"
}

run_case() {
  local case_id="$1"
  local title="$2"
  shift 2
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  log "Running ${case_id}: ${title}"
  if "$@"; then
    record_pass "${case_id}" "${title}"
    return 0
  fi
  record_fail "${case_id}" "${title}"
  return 1
}

base_policy_prefix() {
  cat <<'YAML'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
YAML
}

case_l4_allow_deny() {
  local file="${POLICY_DIR}/c01_l4.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_l4:
    name: github_l4
    endpoints:
      - host: api.github.com
        port: 443
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c01" "${file}" || return 1
  expect_http_code "c01" "allow" "https://api.github.com/zen" "GET" "200" || return 1
  # deny 可能以 403 或連線失敗(000) 呈現，視 curl/網路狀態而定
  expect_http_code_any "c01" "deny_other_host" "https://httpbin.org/get" "GET" "403" "000" || return 1
}

case_l7_read_only() {
  local file="${POLICY_DIR}/c02_l7_readonly.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_ro:
    name: github_ro
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-only
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c02" "${file}" || return 1
  expect_http_code "c02" "allow_get" "https://api.github.com/zen" "GET" "200" || return 1
  expect_http_code "c02" "deny_post" "https://api.github.com/user/repos" "POST" "403" '{"name":"openshell-policy-test"}' || return 1
}

case_l7_read_write() {
  local file="${POLICY_DIR}/c03_l7_readwrite.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_rw:
    name: github_rw
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-write
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c03" "${file}" || return 1
  # 未帶 token 的 POST 會到 upstream 拒絕(401/422)，重點是不能被 policy 403 擋下。
  expect_not_http_code "c03" "post_not_policy_denied" "https://api.github.com/user/repos" "POST" "403" || return 1
  expect_http_code "c03" "delete_denied" "https://api.github.com/user/repos" "DELETE" "403" || return 1
}

case_l7_full() {
  local file="${POLICY_DIR}/c04_l7_full.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_full:
    name: github_full
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: full
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c04" "${file}" || return 1
  expect_not_http_code "c04" "delete_not_policy_denied" "https://api.github.com/user/repos" "DELETE" "403" || return 1
}

case_explicit_rules() {
  local file="${POLICY_DIR}/c05_rules.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_rules:
    name: github_rules
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        rules:
          - allow:
              method: GET
              path: "/zen"
          - allow:
              method: GET
              path: "/meta"
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c05" "${file}" || return 1
  expect_http_code "c05" "allow_specific" "https://api.github.com/zen" "GET" "200" || return 1
  expect_http_code_any "c05" "deny_unlisted" "https://api.github.com/user" "GET" "403" "000" || return 1
}

case_enforcement_audit() {
  local file="${POLICY_DIR}/c06_audit.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_audit:
    name: github_audit
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: audit
        access: read-only
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c06" "${file}" || return 1
  # POST 在 audit 模式不應被 policy 403，會由 upstream 決定(通常 401/404/422)。
  expect_not_http_code "c06" "post_audit" "https://api.github.com/user/repos" "POST" "403" || return 1
}

case_tls_skip() {
  local file="${POLICY_DIR}/c07_tls_skip.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_tls_skip:
    name: github_tls_skip
    endpoints:
      - host: api.github.com
        port: 443
        tls: skip
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c07" "${file}" || return 1
  expect_http_code "c07" "allow_l4_with_skip" "https://api.github.com/zen" "GET" "200" || return 1
}

case_binary_wildcard() {
  local file="${POLICY_DIR}/c08_binary_wildcard.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_bin_wild:
    name: github_bin_wild
    endpoints:
      - host: api.github.com
        port: 443
    binaries:
      - { path: "/usr/bin/*" }
YAML
  } > "${file}"
  apply_policy "c08" "${file}" || return 1
  expect_http_code "c08" "allow_curl_by_wildcard" "https://api.github.com/zen" "GET" "200" || return 1
}

case_host_wildcard() {
  local file="${POLICY_DIR}/c09_host_wildcard.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_host_wild:
    name: github_host_wild
    endpoints:
      - host: "*.github.com"
        port: 443
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c09" "${file}" || return 1
  expect_http_code "c09" "allow_api_github" "https://api.github.com/zen" "GET" "200" || return 1
  expect_http_code_any "c09" "deny_httpbin" "https://httpbin.org/get" "GET" "403" "000" || return 1
}

case_multi_port() {
  local file="${POLICY_DIR}/c10_multi_port.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  github_multi_port:
    name: github_multi_port
    endpoints:
      - host: api.github.com
        ports: [443, 8443]
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c10" "${file}" || return 1
  expect_http_code "c10" "allow_443" "https://api.github.com/zen" "GET" "200" || return 1
}

case_allowed_ips_always_blocked_linklocal() {
  local file="${POLICY_DIR}/c11_allowed_ips_linklocal.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  metadata_service:
    name: metadata_service
    endpoints:
      - host: 169.254.169.254
        port: 80
        allowed_ips:
          - "169.254.169.254/32"
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c11" "${file}" || return 1
  # 文件宣稱 loopback/link-local 永遠封鎖；即便 allowlist 也不能放行
  expect_http_code_any "c11" "linklocal_still_blocked" "http://169.254.169.254/latest/meta-data/" "GET" "403" "000"
}

case_hostless_allowed_ips_schema() {
  local file="${POLICY_DIR}/c12_hostless_allowed_ips.yaml"
  {
    base_policy_prefix
    cat <<'YAML'
  private_hostless:
    name: private_hostless
    endpoints:
      - port: 8080
        allowed_ips:
          - "10.0.5.0/24"
    binaries:
      - { path: /usr/bin/curl }
YAML
  } > "${file}"
  apply_policy "c12" "${file}" || return 1

  local invalid_file="${POLICY_DIR}/c12_hostless_allowed_ips_invalid.yaml"
  cat > "${invalid_file}" <<'YAML'
version: invalid
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  private_hostless_invalid:
    name: private_hostless_invalid
    endpoints:
      - port: 8080
        allowed_ips:
          - "10.0.5.0/24"
    binaries:
      - { path: /usr/bin/curl }
YAML

  if run_cmd "c12" "policy_set_invalid_schema" openshell policy set "${SANDBOX_NAME}" --policy "${invalid_file}" --wait; then
    return 1
  fi
  return 0
}

generate_report() {
  local status="PASS"
  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    status="FAIL"
  fi

  {
    echo "# OpenShell Policy Validation Report"
    echo
    echo "- Generated at (UTC): ${TS}"
    echo "- Sandbox: ${SANDBOX_NAME}"
    echo "- Artifacts directory: \`${RUN_ROOT}\`"
    echo "- Final status: **${status}**"
    echo
    echo "## Coverage (docs + examples)"
    echo
    echo "- L4 allow/deny"
    echo "- L7 access presets: read-only / read-write / full"
    echo "- L7 explicit rules"
    echo "- enforcement: enforce / audit"
    echo "- tls: skip behavior"
    echo "- Binary wildcard matching"
    echo "- Host wildcard matching"
    echo "- Multi-port endpoint via \`ports\`"
    echo "- allowed_ips cannot bypass link-local block"
    echo "- Hostless allowed_ips schema acceptance"
    echo
    echo "## Result Summary"
    echo
    echo "- Total: ${TOTAL_COUNT}"
    echo "- Passed: ${PASS_COUNT}"
    echo "- Failed: ${FAIL_COUNT}"
    echo
    echo "## Case-by-case"
    echo
    if [[ -f "${RAW_DIR}/summary.txt" ]]; then
      cat "${RAW_DIR}/summary.txt"
    else
      echo "- No summary generated."
    fi
    echo
    echo "## Raw Artifacts"
    echo
    echo "- Run log: \`${RAW_DIR}/run.log\`"
    echo "- Command outputs: \`${RAW_DIR}/*.txt\`"
    echo "- ANSI-stripped outputs: \`${RAW_DIR}/*.plain.txt\`"
    echo "- Request command snapshots: \`${RAW_DIR}/*.request.txt\`"
    echo "- Structured HTTP probe results: \`${RAW_DIR}/*.result.json\`"
    echo "- Generated policy files: \`${POLICY_DIR}/*.yaml\`"
  } > "${REPORT_FILE}"
}

main() {
  log "Run root: ${RUN_ROOT}"
  log "Checking gateway health"
  run_cmd "preflight" "status" openshell status || {
    log "Gateway unhealthy"
    exit 1
  }

  log "Creating sandbox ${SANDBOX_NAME}"
  local bootstrap
  bootstrap="$(bootstrap_policy_file)"
  openshell sandbox create --name "${SANDBOX_NAME}" --keep --no-auto-providers --policy "${bootstrap}" -- sh -lc "echo ready && sleep 3600" \
    > "${RAW_DIR}/preflight_sandbox_create.txt" 2>&1 &
  local create_pid=$!
  local attempts=0
  local ready="false"
  while [[ ${attempts} -lt 60 ]]; do
    if openshell sandbox list > "${RAW_DIR}/preflight_sandbox_list.txt" 2>&1 && rg -q "${SANDBOX_NAME}.*Ready" "${RAW_DIR}/preflight_sandbox_list.txt"; then
      ready="true"
      break
    fi
    sleep 2
    attempts=$((attempts + 1))
  done
  kill "${create_pid}" >/dev/null 2>&1 || true
  wait "${create_pid}" >/dev/null 2>&1 || true

  if [[ "${ready}" != "true" ]]; then
    log "Failed to create sandbox"
    exit 1
  fi

  write_plain_output "${RAW_DIR}/preflight_sandbox_create.txt"
  write_plain_output "${RAW_DIR}/preflight_sandbox_list.txt"

  run_case "c01" "L4 allow/deny" case_l4_allow_deny || true
  run_case "c02" "L7 read-only preset" case_l7_read_only || true
  run_case "c03" "L7 read-write preset" case_l7_read_write || true
  run_case "c04" "L7 full preset" case_l7_full || true
  run_case "c05" "L7 explicit rules" case_explicit_rules || true
  run_case "c06" "Enforcement audit behavior" case_enforcement_audit || true
  run_case "c07" "TLS skip L4 passthrough behavior" case_tls_skip || true
  run_case "c08" "Binary wildcard matching" case_binary_wildcard || true
  run_case "c09" "Host wildcard matching" case_host_wildcard || true
  run_case "c10" "Multi-port endpoint support" case_multi_port || true
  run_case "c11" "allowed_ips cannot bypass link-local block" case_allowed_ips_always_blocked_linklocal || true
  run_case "c12" "Hostless allowed_ips schema acceptance" case_hostless_allowed_ips_schema || true

  generate_report

  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    log "Validation completed with failures. Report: ${REPORT_FILE}"
    exit 1
  fi

  log "Validation completed successfully. Report: ${REPORT_FILE}"
}

main "$@"
