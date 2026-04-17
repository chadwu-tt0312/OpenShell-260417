#!/usr/bin/env bash
set -euo pipefail

SANDBOX="${1:-}"
if [[ -z "${SANDBOX}" ]]; then
  echo "Usage: $0 <sandbox-name>" >&2
  exit 2
fi

HOST="${HOST:-api.exa.ai}"
SINCE="${SINCE:-15m}"
LEVEL="${LEVEL:-info}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Pull both sources: L7 decisions may appear in either stream.
openshell logs "${SANDBOX}" --source gateway --source sandbox --level "${LEVEL}" --since "${SINCE}" >"$tmp" 2>&1 || true

echo "== Filter: dst_host=${HOST} (since=${SINCE}, level>=${LEVEL}) =="
echo

# If nothing matches the host filter, print a quick summary of recent L7 traffic
# to help discover the actual dst_host values.
if ! awk -v host="dst_host=${HOST}" 'index($0,"L7_REQUEST") && index($0,host) {found=1} END{exit found?0:1}' "$tmp"; then
  echo "## No L7_REQUEST lines matched dst_host=${HOST}"
  echo "## Recent L7 dst_host summary (top 20)"
  TMPFILE="$tmp" python3 - <<'PY'
import os
import re
from collections import Counter

path = os.environ["TMPFILE"]
lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()

host_re = re.compile(r"\bdst_host=([^\s]+)\b")

c = Counter()
for line in lines:
    if "L7_REQUEST" not in line:
        continue
    m = host_re.search(line)
    if m:
        c[m.group(1)] += 1

for host, n in c.most_common(20):
    print(f"{n:>4}  {host}")
PY
  # Replace placeholder with the tmp path (safe: no user-provided code).
  # We keep the heredoc single-quoted for safety and inject via environment.
  echo
  echo "Hint: rerun with HOST=<one of the hosts above> (and maybe a larger SINCE)"
fi

echo "## L7 decisions (all)"
awk -v host="dst_host=${HOST}" '
  index($0, "L7_REQUEST") && index($0, host) { print }
' "$tmp" || true
echo

echo "## L7 denies (likely policy blocks)"
awk -v host="dst_host=${HOST}" '
  index($0, host) &&
  (index($0, "l7_decision=deny") || index($0, "not permitted by policy")) {
    print
  }
' "$tmp" || true
echo

echo "## Extracted method/path (unique counts)"
TMPFILE="$tmp" python3 - <<'PY'
import os
import re
from collections import Counter

path = os.environ["TMPFILE"]
lines = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()

action_re = re.compile(r"\bl7_action=([A-Z]+)\b")
target_re = re.compile(r"\bl7_target=([^\s]+)\b")
deny_re   = re.compile(r"\bl7_deny_reason=\"([^\"]+)\"")

c = Counter()
samples = []

for line in lines:
    if "L7_REQUEST" not in line:
        continue
    if "l7_decision=deny" not in line and "not permitted by policy" not in line:
        continue
    a = action_re.search(line)
    t = target_re.search(line)
    if not a or not t:
        continue
    method = a.group(1)
    target = t.group(1)
    c[(method, target)] += 1
    d = deny_re.search(line)
    if d:
        samples.append((method, target, d.group(1)))

for (method, target), n in c.most_common():
    print(f"{n:>4}  {method} {target}")

if samples:
    print("\n## Sample deny reasons")
    for method, target, reason in samples[:10]:
        print(f"- {method} {target}  ->  {reason}")
PY
