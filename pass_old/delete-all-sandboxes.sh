#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
YES=0

usage() {
  cat <<'EOF'
用法：
  ./pass/delete-all-sandboxes.sh [--dry-run] [--yes]

說明：
  - 預設會列出 sandbox 清單，並要求互動式確認後才會刪除
  - --dry-run 只列出清單，不刪除
  - --yes     不互動，直接刪除（危險）

實作：
  使用 openshell sandbox delete --all 一次刪除目前 gateway 的所有 sandbox。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v openshell >/dev/null 2>&1; then
  echo "ERROR: command not found: openshell" >&2
  exit 1
fi

echo "[1/3] Check gateway status..."
openshell status >/dev/null

echo "[2/3] Current sandboxes (names)..."
if ! openshell sandbox list --names; then
  echo "ERROR: failed to list sandboxes" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY_RUN=1: skip delete."
  exit 0
fi

if [[ "${YES}" != "1" ]]; then
  echo
  echo "即將刪除【全部】sandboxes（目前 gateway）。"
  echo -n "請輸入 DEL 以確認："
  read -r confirm
  if [[ "${confirm}" != "DEL" ]]; then
    echo "取消（未確認）。"
    exit 1
  fi
fi

echo "[3/3] Deleting all sandboxes..."
openshell sandbox delete --all

echo "Done."
