# Policy Validation Hardening 摘要

## 目的

在不改變既有 `c01~c12` 測試語意前提下，強化 `pass/validate-policy-matrix.sh` 的可觀測性（observability）與可稽核性（auditability），讓每次驗證都能保留足夠的 machine-readable artifact 供 CI 與除錯使用。

## 變更範圍

- Script：`pass/validate-policy-matrix.sh`
- Docs：`pass/docs/policy-test-cases.md`

## 實作重點

### 1) HTTP probe 共用流程

- 新增 `run_http_probe()`，統一處理：
  - curl command 建構
  - sandbox 執行
  - raw output 產出
  - 結構化結果輸出
- 既有 assertion 函式：
  - `expect_http_code`
  - `expect_http_code_any`
  - `expect_not_http_code`
  已改由共用流程執行，外部介面與判定語意維持不變。

### 2) Request 與結構化結果 artifact

- 每個 HTTP 驗證步驟新增：
  - `raw/<case>_<step>.request.txt`
  - `raw/<case>_<step>.result.json`
- `result.json` 主要欄位：
  - `http_code`
  - `curl_exit_code`（可解析時）
  - `policy_decision_hint`
  - `request_file`
  - `raw_output_file`
  - `request_command`

### 3) `000 + curl error` 診斷強化

- 新增 `extract_curl_exit_code()` 解析 `curl: (N)`。
- 新增 `build_policy_decision_hint()` 產生判讀提示，例如：
  - `policy_deny_or_tunnel_block`
  - `policy_or_upstream_forbidden`
  - `allowed`
  - `upstream_or_other_error`

### 4) c12 負向 schema 測試

- 在 `case_hostless_allowed_ips_schema()` 新增負向子測試。
- 產生 `c12_hostless_allowed_ips_invalid.yaml`，使用明確型別錯誤（`version: invalid`）確保 parser 失敗。
- 驗證 `openshell policy set` 必須失敗，並保留證據：
  - `raw/c12_policy_set_invalid_schema.txt`
  - `raw/c12_policy_set_invalid_schema.plain.txt`

### 5) ANSI-stripped 純文字輸出

- 新增 `write_plain_output()`，對 `.txt` 生成對應 `.plain.txt`。
- 已套用於：
  - `run_cmd` 產生的 CLI output（如 `*_policy_set.txt`、`preflight_*.txt`）
  - HTTP probe raw output

### 6) 報告內容補強

- `policy-validation-report.md` 的 Raw Artifacts 區段新增：
  - `*.plain.txt`
  - `*.request.txt`
  - `*.result.json`

## 文件同步

`pass/docs/policy-test-cases.md` 已新增：

- 新 artifact 類型與用途說明
- `c12_policy_set_invalid_schema.txt` 負向測試說明
- Structured probe artifact 三件套（`.txt`/`.request.txt`/`.result.json`）說明

## 驗證結果（最新成功 run）

- Artifact root：`pass/artifacts/policy-validation-20260420t085231z`
- `summary.txt`：`c01~c12` 全部 PASS
- `policy-validation-report.md`：Final status = PASS
- Artifact 計數：
  - `*.result.json`：16
  - `*.request.txt`：16
  - `*.plain.txt`：32

## 已知調整紀錄

- 初版負向 schema 使用 CIDR (`10.0.5.0/33`) 在實際環境未觸發失敗，已改為明確型別錯誤以提高穩定性與可重現性。

## TO-DO（後續可選）

- [ ] 將 `result.json` 匯總為單一 index（例如 `raw/http-probe-index.json`），便於 CI 直接掃描。
- [ ] 在報告中加入每個 case 的 `request/result` 檔案連結清單。
- [ ] 對 `policy_decision_hint` 定義固定 enum 規格文件，避免後續欄位語意漂移。
