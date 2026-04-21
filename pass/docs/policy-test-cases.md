# Policy 測試案例清單

- `c01` L4 allow/deny（`host + port` basic network policy）
- `c02` L7 `access: read-only`（`enforce`）
- `c03` L7 `access: read-write`（`enforce`）
- `c04` L7 `access: full`（`enforce`）
- `c05` L7 explicit `rules`（method + path）
- `c06` `enforcement: audit` behavior
- `c07` `tls: skip` behavior
- `c08` binary wildcard path matching
- `c09` host wildcard matching（`*.github.com`）
- `c10` multi-port endpoint（`ports`）
- `c11` `allowed_ips` invalid loopback rejection
- `c12` hostless `allowed_ips` schema acceptance

## 參考來源對應

- `docs/reference/policy-schema.md`
- `architecture/security-policy.md`
- `docs/tutorials/first-network-policy.md`
- `docs/sandboxes/policies.md`
- `.agents/skills/generate-sandbox-policy/examples.md`

## Artifact 匯出（policy-validation-20260420t082754z）

### 概要

- `pass/artifacts/policy-validation-20260420t082754z/policies`：各案例（`c01`~`c12`）生成的測試輸入策略
- `pass/artifacts/policy-validation-20260420t082754z/raw`：執行證據（preflight logs、policy 套用輸出、HTTP 探測結果）
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.plain.txt`：移除 ANSI 的輸出，方便 diff/CI 解析
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.request.txt`：HTTP 探測實際執行命令快照
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.result.json`：結構化 HTTP 探測診斷（`http_code`、`curl_exit_code`、`policy_decision_hint`）

### `policies/`

- `bootstrap.yaml`：sandbox 啟動用基礎策略；包含檔案系統/程序設定，`network_policies: {}`
- `c01_l4.yaml`：L4 allow/deny 基線；允許 `/usr/bin/curl` 連線 `api.github.com:443`
- `c02_l7_readonly.yaml`：L7 `access: read-only` + `enforcement: enforce`
- `c03_l7_readwrite.yaml`：L7 `access: read-write` + `enforcement: enforce`
- `c04_l7_full.yaml`：L7 `access: full` + `enforcement: enforce`
- `c05_rules.yaml`：明確 L7 規則；只允許 `GET /zen` 與 `GET /meta`
- `c06_audit.yaml`：L7 `access: read-only` + `enforcement: audit`
- `c07_tls_skip.yaml`：含 `tls: skip` 行為的 endpoint
- `c08_binary_wildcard.yaml`：以 `"/usr/bin/*"` 驗證 binary wildcard 比對
- `c09_host_wildcard.yaml`：以 `"*.github.com"` 驗證 host wildcard 比對
- `c10_multi_port.yaml`：以 `ports: [443, 8443]` 驗證多埠 endpoint
- `c11_allowed_ips_linklocal.yaml`：`allowed_ips` 包含 link-local `169.254.169.254/32`（仍必須被阻擋）
- `c12_hostless_allowed_ips.yaml`：無 host endpoint 的 schema 接受性（`port + allowed_ips`）

### `raw/`

#### 流程與摘要檔

- `run.log`：端到端時間軸（preflight -> `c01`~`c12` -> 完成 -> 清理）
- `summary.txt`：案例摘要；`c01`~`c12` 皆記錄為 PASS
- `ssh_config_policy-matrix-20260420t082754z`：透過 `openshell ssh-proxy` 執行 sandbox 指令時的 SSH 設定檔
- `preflight_status.txt`：gateway 健康檢查輸出（`Connected`、server URL、version）
- `preflight_sandbox_create.txt`：sandbox 建立進度、映像拉取紀錄與最終 `ready`
- `preflight_sandbox_list.txt`：sandbox list 輪詢結果，確認目標 sandbox 為 `Ready`

#### 各案例 policy 套用檔（`cXX_policy_set.txt`）

- `c01_policy_set.txt`：Policy version `2` submitted/loaded（hash `6598006a1fcd`）
- `c02_policy_set.txt`：Policy version `3` submitted/loaded（hash `65f78a782791`）
- `c03_policy_set.txt`：Policy version `4` submitted/loaded（hash `d9cfff1591c5`）
- `c04_policy_set.txt`：Policy version `5` submitted/loaded（hash `3dc6fa7eea6e`）
- `c05_policy_set.txt`：Policy version `6` submitted/loaded（hash `d08217f37218`）
- `c06_policy_set.txt`：Policy version `7` submitted/loaded（hash `2f70f19b44eb`）
- `c07_policy_set.txt`：Policy version `8` submitted/loaded（hash `df13e67a6845`）
- `c08_policy_set.txt`：Policy version `9` submitted/loaded（hash `26ce6705ab70`）
- `c09_policy_set.txt`：Policy version `10` submitted/loaded（hash `0dce99e68b19`）
- `c10_policy_set.txt`：Policy version `11` submitted/loaded（hash `4d549a4e6377`）
- `c11_policy_set.txt`：Policy version `12` submitted/loaded（hash `0e3cd16e8cc9`）
- `c12_policy_set.txt`：Policy version `13` submitted/loaded（hash `c883f558d5aa`）

#### 各案例 HTTP/結果證據

- `c01_allow.txt`：`200`（允許 host）
- `c01_deny_other_host.txt`：`000` + `CONNECT tunnel failed, response 403`（拒絕非允許 host）
- `c02_allow_get.txt`：`200`（read-only 下允許 GET）
- `c02_deny_post.txt`：`403`（read-only + enforce 下拒絕 POST）
- `c03_post_not_policy_denied.txt`：`401`（上游拒絕，非 policy `403`）
- `c03_delete_denied.txt`：`403`（read-write 預設下拒絕 DELETE）
- `c04_delete_not_policy_denied.txt`：`404`（非 policy `403`，確認 full access 直通）
- `c05_allow_specific.txt`：`200`（規則列出的 path 允許）
- `c05_deny_unlisted.txt`：`403`（未列出 path 拒絕）
- `c06_post_audit.txt`：`401`（audit 模式不會強制 policy `403`）
- `c07_allow_l4_with_skip.txt`：`200`（`tls: skip` 情境成功）
- `c08_allow_curl_by_wildcard.txt`：`200`（binary wildcard 生效）
- `c09_allow_api_github.txt`：`200`（host wildcard 包含 `api.github.com`）
- `c09_deny_httpbin.txt`：`000` + `CONNECT tunnel failed, response 403`（wildcard 外部網域被拒）
- `c10_allow_443.txt`：`200`（multi-port policy 含 `443`）
- `c11_linklocal_still_blocked.txt`：`403`（link-local 維持阻擋）
- `c12_policy_set_invalid_schema.txt`：負向 schema 驗證；無效 policy 必須被 `openshell policy set` 拒絕

#### 結構化 probe artifacts

- 每個 HTTP 檢查步驟都會同時產生三種檔案：
  - `<case>_<step>.txt`：原始 curl 輸出（狀態碼與可能的 curl 錯誤訊息）
  - `<case>_<step>.request.txt`：在 sandbox 中實際執行的完整命令
  - `<case>_<step>.result.json`：正規化 machine-readable 結果，包含：
    - `http_code`
    - `curl_exit_code`（可由 curl 錯誤輸出解析時）
    - `policy_decision_hint`
    - `raw_output_file`
