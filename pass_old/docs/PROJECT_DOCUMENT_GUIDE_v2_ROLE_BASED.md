# OpenShell 專案文件導讀（依角色分類版 v2）

> 本文件是「依角色」的閱讀導航，目標是讓你在不同工作情境下，用最短路徑找到必讀文件。  
> 注意：此導讀**不取代**全量索引版文件；它是「精選閱讀路線」。

## 使用方式（先選角色，再照路線讀）

- **開發者（Developer）**：你要改程式、加功能、修 bug、跑測試。
- **維運（Ops / SRE）**：你要部署 gateway、維持 cluster 健康、排障。
- **安全（Security / Compliance）**：你要理解 threat model、policy 及認證邊界，並能做審查。

---

## Developer 路線（改程式 / 送 PR）

### 你要先讀的 10 份（優先順序）

1. `README.md`  
   **用途：** 專案入口與產品定位。  
   **總結：** 先理解 OpenShell 由 gateway/sandbox/policy/router 組成，並從 quickstart 建立心智模型。

2. `CONTRIBUTING.md`  
   **用途：** 貢獻規範與開發環境。  
   **總結：** 你會用 `mise` 跑建置/測試/CI；也會遇到 vouch、DCO、Conventional Commits 的規範。

3. `AGENTS.md`  
   **用途：** 本 repo 對 agent 協作的「總規約」。  
   **總結：** 了解專案是 agent-first，並掌握 workflow chain 與文件更新要求。

4. `TESTING.md`  
   **用途：** 測試入口與測試布局。  
   **總結：** 你會用 `mise run test / e2e / ci`；知道 Rust/Python/E2E 測試各放哪裡。

5. `STYLEGUIDE.md`  
   **用途：** 程式碼/CLI 輸出風格。  
   **總結：** 了解 license header、lint/format 與 CLI 排版慣例，避免 PR 來回修格式。

6. `architecture/README.md`  
   **用途：** 架構總覽入口。  
   **總結：** 先用高層視角看清楚 gateway / sandbox / policy / inference 的邊界。

7. `architecture/gateway.md`  
   **用途：** gateway 深入設計。  
   **總結：** 改 server/gRPC/persistence/watch/log bus/SSH tunnel 時必讀。

8. `architecture/sandbox.md`  
   **用途：** sandbox 深入設計（核心）。  
   **總結：** 改 proxy/OPA/L7/netns/identity/log push/錯誤模型時必讀。

9. `docs/reference/policy-schema.md`  
   **用途：** policy YAML 欄位字典。  
   **總結：** 你需要知道 `network_policies`、endpoint 欄位、rules/access、binaries 等語意與驗證規則。

10. `architecture/security-policy.md`  
   **用途：** policy 行為觸發器與實作邏輯。  
   **總結：** 釐清「L4 允許」與「L7 檢查」怎麼被 `protocol/enforcement/access/rules/allowed_ips` 觸發。

### 常見任務 → 對應文件

- **要改 CLI 行為 / flags**
  - `docs/get-started/quickstart.md`（使用者觀點）
  - `docs/sandboxes/manage-sandboxes.md`（操作觀點）
  - `docs/sandboxes/manage-gateways.md`
  - `docs/sandboxes/manage-providers.md`

- **要改 policy / proxy / L7**
  - `architecture/sandbox.md`
  - `architecture/security-policy.md`
  - `docs/sandboxes/policies.md`
  - `docs/reference/policy-schema.md`

- **要改 inference routing**
  - `docs/inference/index.md`
  - `docs/inference/configure.md`
  - `architecture/inference-routing.md`
  - `crates/openshell-router/README.md`（crate 邊界）

---

## Ops / SRE 路線（部署 / 排障 / 穩定性）

### 你要先讀的 10 份（優先順序）

1. `docs/get-started/quickstart.md`  
   **用途：** 最短上手部署。  
   **總結：** 先能在 local/remote 起一套可用環境。

2. `docs/sandboxes/manage-gateways.md`  
   **用途：** gateway 部署與生命週期管理。  
   **總結：** 你會用 `gateway start/stop/destroy/add/select/info/login`。

3. `docs/sandboxes/manage-sandboxes.md`  
   **用途：** sandbox 操作與監控。  
   **總結：** 你要會 create/connect/logs/forward/upload/download/delete。

4. `docs/sandboxes/policies.md`  
   **用途：** policy 迭代與 deny 診斷。  
   **總結：** 你會用 log 中的 host/binary/method/path 來修 policy，並熱更新驗證。

5. `docs/reference/gateway-auth.md`  
   **用途：** gateway 認證模式與憑證檔案布局。  
   **總結：** 排查連線問題時，先確認 mTLS/edge/plaintext 模式與本機憑證狀態。

6. `docs/reference/support-matrix.md`  
   **用途：** 支援矩陣與需求。  
   **總結：** 釐清平台/版本/Kernel 能力（Landlock、seccomp）等硬限制。

7. `architecture/system-architecture.md`  
   **用途：** 全系統通訊拓撲。  
   **總結：** 排障時用來定位「哪一段鏈路」出問題（CLI↔gateway、gateway↔k8s、sandbox↔proxy 等）。

8. `architecture/gateway-security.md`  
   **用途：** PKI/mTLS/SSH tunnel 安全模型。  
   **總結：** 你會遇到憑證、secret、tunnel、handshake 等問題，這份是深水區指南。

9. `architecture/gateway-single-node.md`  
   **用途：** 單節點 bootstrap 流程。  
   **總結：** 當 cluster 起不來、或重建/復原時，這份提供可對照的序列與 end-state。

10. `crates/openshell-cli/src/doctor_llm_prompt.md`  
   **用途：** gateway/cluster 診斷腳本化提示。  
   **總結：** 等同「標準診斷 runbook」，用來快速收斂問題類型（k3s、pods、DNS、image、PKI）。

### 常見問題 → 讀哪裡

- **CLI 連不到 gateway**
  - `docs/reference/gateway-auth.md`
  - `docs/sandboxes/manage-gateways.md`
  - `architecture/gateway-deploy-connect.md`

- **sandbox create 卡住 / error**
  - `docs/sandboxes/manage-sandboxes.md`
  - `architecture/gateway.md`（watch / phase / event）
  - `architecture/sandbox.md`（啟動序列與 fail-closed 點）

- **policy deny 很多，不知道怎麼修**
  - `docs/sandboxes/policies.md`
  - `docs/reference/policy-schema.md`
  - `architecture/security-policy.md`

---

## Security 路線（審查 / 威脅模型 / policy 與認證邊界）

### 你要先讀的 10 份（優先順序）

1. `docs/about/overview.md`  
   **用途：** 威脅與控制總覽。  
   **總結：** 用「風險→控制」表快速理解 OpenShell 想防什麼。

2. `docs/about/architecture.md`  
   **用途：** 高階 request flow。  
   **總結：** 先掌握資料面與控制面，才能判斷控制點與信任邊界。

3. `architecture/system-architecture.md`  
   **用途：** 全系統拓撲與資料流。  
   **總結：** 審查時用來定位每條資料流是否被正確截斷/記錄/認證。

4. `architecture/gateway-security.md`  
   **用途：** gateway 的 PKI/mTLS/edge/tunnel 威脅模型。  
   **總結：** 對外邊界（auth boundary）與可接受的 trust assumptions 在這裡。

5. `docs/reference/gateway-auth.md`  
   **用途：** 操作層面的認證模式說明。  
   **總結：** 確認實際部署時憑證/edge token 的儲存與解析優先序。

6. `architecture/security-policy.md`  
   **用途：** policy 語言與行為觸發器規格。  
   **總結：** 這份是 policy 相關審查的基準文件（L4/L7/SSRF/allowed_ips）。

7. `docs/reference/policy-schema.md`  
   **用途：** policy 欄位字典與約束。  
   **總結：** 審查 policy 是否過寬、是否可被濫用、是否符合驗證約束。

8. `architecture/sandbox.md`  
   **用途：** sandbox 真正如何 enforce。  
   **總結：** 包含 Landlock/seccomp/netns、/proc identity binding、TOFU hash、SSRF 阻擋與 bypass detection。

9. `docs/sandboxes/policies.md`  
   **用途：** policy 迭代工作流（含 audit/enforce）。  
   **總結：** 審查流程時通常會要求 audit 先行、再逐步 enforce。

10. `SECURITY.md`  
   **用途：** 漏洞回報流程。  
   **總結：** 明確規範不在 GitHub 公開回報 vulnerability。

---

## TO-DO List（下一步你可選）

- [ ] 指定你目前主要角色（Developer / Ops / Security）與目標（例如「要改 policy」、「要改 CLI」、「要上線 remote gateway」）。
- [ ] 我可以依你的目標，從此 v2 導讀再切出「**15 份必讀最小集合**」與「**90 分鐘上手閱讀順序**」。
- [ ] 如果你要把導讀文件變成可維護的「自動掃描清單」，我也可以加一個腳本去檢查新增文件是否被納入（但這會涉及額外工程改動）。

