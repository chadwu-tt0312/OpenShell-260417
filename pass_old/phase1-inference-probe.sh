#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://inference.local}"
API_KEY="${API_KEY:-ollama-poc-key}"
MODEL="${MODEL:-llama3.2}"
OUT_FILE="${OUT_FILE:-pass/phase1-inference-probe-report.json}"
MODE="${MODE:-sandbox}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --out-file)
      OUT_FILE="$2"
      shift 2
      ;;
    *)
      echo "未知參數: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "缺少 curl，請先安裝。" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "缺少 python3，請先安裝。" >&2
  exit 2
fi

if [[ "$MODE" != "host" && "$MODE" != "sandbox" ]]; then
  echo "--mode 只支援 host 或 sandbox" >&2
  exit 2
fi

if [[ "$MODE" == "sandbox" ]] && ! command -v openshell >/dev/null 2>&1; then
  echo "sandbox 模式需要 openshell CLI。" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT_FILE")"

run_case_host() {
  local name="$1"
  local path="$2"
  local method="$3"
  local expected="$4"
  local body="$5"
  local started_at
  started_at="$(date -Iseconds)"
  local started_epoch_ms
  started_epoch_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

  local response_file
  response_file="$(mktemp)"
  local http_code
  http_code="$(curl -sS \
    -X "$method" \
    -H "Content-Type: application/json" \
    -H "api-key: $API_KEY" \
    -d "$body" \
    -o "$response_file" \
    -w "%{http_code}" \
    --max-time 30 \
    "${BASE_URL}${path}" 2>/dev/null || true)"

  local actual body_preview
  if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [[ "$http_code" != "000" ]]; then
    actual="$http_code"
    body_preview="$(python3 - <<'PY' "$response_file"
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
print(text[:280])
PY
)"
  else
    actual="-1"
    body_preview="Unable to connect to the remote server"
  fi
  rm -f "$response_file"

  local pass="false"
  if [[ "$actual" == "$expected" ]]; then
    pass="true"
  fi

  local ended_epoch_ms
  ended_epoch_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

  python3 - <<'PY' "$name" "$method" "$path" "$expected" "$actual" "$pass" "$started_at" "$body_preview" "$started_epoch_ms" "$ended_epoch_ms" "host"
import json
import sys
start_ms = int(sys.argv[9])
end_ms = int(sys.argv[10])
obj = {
    "name": sys.argv[1],
    "method": sys.argv[2],
    "path": sys.argv[3],
    "expected": [int(sys.argv[4])],
    "actual": int(sys.argv[5]),
    "pass": sys.argv[6].lower() == "true",
    "started_at": sys.argv[7],
    "body_preview": sys.argv[8],
    "timing": {
        "mode": sys.argv[11],
        "started_epoch_ms": start_ms,
        "ended_epoch_ms": end_ms,
        "duration_ms": end_ms - start_ms,
    },
}
print(json.dumps(obj, ensure_ascii=False))
PY
}

run_case_sandbox() {
  local name="$1"
  local path="$2"
  local method="$3"
  local expected="$4"
  local body="$5"
  local started_at
  started_at="$(date -Iseconds)"
  local started_epoch_ms
  started_epoch_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

  local output
  local marker="__HTTP_CODE__:"
  output="$(openshell sandbox create -- \
    curl -sS \
      -X "$method" \
      -H "Content-Type: application/json" \
      -H "api-key: $API_KEY" \
      -d "$body" \
      -w "\\n${marker}%{http_code}" \
      --max-time 30 \
      "$BASE_URL$path" 2>&1 || true)"

  local ended_epoch_ms
  ended_epoch_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

  python3 - <<'PY' "$name" "$method" "$path" "$expected" "$started_at" "$output" "$marker" "$started_epoch_ms" "$ended_epoch_ms"
import json
import re
import sys

name = sys.argv[1]
method = sys.argv[2]
path = sys.argv[3]
expected = int(sys.argv[4])
started_at = sys.argv[5]
output = sys.argv[6]
marker = sys.argv[7]
start_ms = int(sys.argv[8])
end_ms = int(sys.argv[9])

actual = -1
body_preview = output[:280]
sandbox_name = ""

name_match = re.search(r"Created sandbox:\s+([A-Za-z0-9_-]+)", output)
if name_match:
    sandbox_name = name_match.group(1)

code_match = re.search(re.escape(marker) + r"(\d{3})", output)
if code_match:
    actual = int(code_match.group(1))
    body_part = output.split(marker, 1)[0]
    body_lines = [
        line for line in body_part.splitlines()
        if not line.strip().startswith("Created sandbox:")
    ]
    body_preview = "\n".join(body_lines).strip()[:280]

obj = {
    "name": name,
    "method": method,
    "path": path,
    "expected": [expected],
    "actual": actual,
    "pass": actual == expected,
    "started_at": started_at,
    "body_preview": body_preview,
    "timing": {
        "mode": "sandbox",
        "started_epoch_ms": start_ms,
        "ended_epoch_ms": end_ms,
        "duration_ms": end_ms - start_ms,
    },
}
if sandbox_name:
    obj["sandbox_name"] = sandbox_name

print(json.dumps(obj, ensure_ascii=False))
PY
}

CHAT_BODY="$(python3 - <<'PY' "$MODEL"
import json
import sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": "Say OK only."}],
    "stream": False
}, ensure_ascii=False))
PY
)"

RESPONSES_BODY="$(python3 - <<'PY' "$MODEL"
import json
import sys
print(json.dumps({
    "model": sys.argv[1],
    "input": "hello"
}, ensure_ascii=False))
PY
)"

if [[ "$MODE" == "sandbox" ]]; then
  CASE1="$(run_case_sandbox "allowed_chat_completions" "/v1/chat/completions" "POST" "200" "$CHAT_BODY")"
  CASE2="$(run_case_sandbox "denied_responses_endpoint" "/v1/responses" "POST" "403" "$RESPONSES_BODY")"
else
  CASE1="$(run_case_host "allowed_chat_completions" "/v1/chat/completions" "POST" "200" "$CHAT_BODY")"
  CASE2="$(run_case_host "denied_responses_endpoint" "/v1/responses" "POST" "403" "$RESPONSES_BODY")"
fi

python3 - <<'PY' "$BASE_URL" "$MODEL" "$MODE" "$CASE1" "$CASE2" "$OUT_FILE"
import json
import pathlib
import sys
from datetime import datetime, timezone

base_url = sys.argv[1]
model = sys.argv[2]
mode = sys.argv[3]
case1 = json.loads(sys.argv[4])
case2 = json.loads(sys.argv[5])
out_file = pathlib.Path(sys.argv[6])

results = [case1, case2]
passed = sum(1 for item in results if item.get("pass"))
durations = [item.get("timing", {}).get("duration_ms", 0) for item in results]

startup_comparison = {
    "first_case_name": results[0]["name"],
    "second_case_name": results[1]["name"],
    "first_case_duration_ms": durations[0],
    "second_case_duration_ms": durations[1],
    "delta_ms": durations[1] - durations[0],
    "ratio_second_over_first": round((durations[1] / durations[0]), 3) if durations[0] > 0 else None,
}

summary = {
    "mode": mode,
    "base_url": base_url,
    "model": model,
    "total": len(results),
    "passed": passed,
    "failed": len(results) - passed,
    "timing_summary": {
        "total_duration_ms": sum(durations),
        "average_case_duration_ms": round(sum(durations) / len(durations), 2) if durations else 0,
        "startup_comparison": startup_comparison,
    },
    "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
    "results": results,
}

out_file.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False))
PY

SUMMARY="$(python3 - <<'PY' "$OUT_FILE"
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
)"

PASSED="$(python3 - <<'PY' "$SUMMARY"
import json
import sys
print(json.loads(sys.argv[1])["passed"])
PY
)"
TOTAL="$(python3 - <<'PY' "$SUMMARY"
import json
import sys
print(json.loads(sys.argv[1])["total"])
PY
)"
FAILED="$(python3 - <<'PY' "$SUMMARY"
import json
import sys
print(json.loads(sys.argv[1])["failed"])
PY
)"

echo ""
echo "Phase 1 inference probe result:"
echo "- Mode: $MODE"
echo "- Base URL: $BASE_URL"
echo "- Passed: $PASSED/$TOTAL"
echo "- Report: $OUT_FILE"

python3 - <<'PY' "$SUMMARY"
import json
import sys
data = json.loads(sys.argv[1])
c = data["timing_summary"]["startup_comparison"]
print(f"- Timing: first={c['first_case_duration_ms']}ms, second={c['second_case_duration_ms']}ms, delta={c['delta_ms']}ms")
PY

if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  python3 - <<'PY' "$SUMMARY"
import json
import sys
data = json.loads(sys.argv[1])
for item in data["results"]:
    if not item["pass"]:
        expected = ",".join(str(x) for x in item["expected"])
        print(f"- {item['name']}: expected [{expected}], actual {item['actual']}")
PY
  exit 1
fi
