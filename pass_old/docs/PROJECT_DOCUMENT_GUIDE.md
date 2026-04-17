# OpenShell 專案文件導讀

> 本文件已排除 `pass/` 目錄內容，聚焦專案正式文件。

## 導讀目標

- 快速建立專案全貌，降低初次進入成本。
- 以「用途 + 一句總結」方式，讓每份文件可快速判斷是否需要深入閱讀。
- 提供建議閱讀順序，避免一開始陷入過深細節。

## 建議閱讀順序

1. `README.md`
2. `docs/get-started/quickstart.md`
3. `docs/sandboxes/*.md`
4. `docs/reference/policy-schema.md`
5. `architecture/README.md`
6. `architecture/system-architecture.md`
7. `architecture/gateway.md`
8. `architecture/sandbox.md`
9. `examples/*`

---

## 一、根目錄核心文件

- `README.md`  
  **用途：** 專案入口與產品定位。  
  **總結：** 說明 OpenShell 是 agent sandbox runtime，包含 quickstart、核心能力、保護層、關鍵指令與延伸連結。

- `CONTRIBUTING.md`  
  **用途：** 開發者貢獻規範。  
  **總結：** 定義 agent-first 貢獻流程、vouch 機制、建置/測試流程與 PR/commit 規範。

- `AGENTS.md`  
  **用途：** AI agent 在此專案內的執行規範。  
  **總結：** 說明 workflow chain、架構路徑、文件更新要求與安全邊界。

- `SECURITY.md`  
  **用途：** 安全漏洞回報流程。  
  **總結：** 規範漏洞需走 NVIDIA PSIRT 私下通報，不經 GitHub issue。

- `TESTING.md`  
  **用途：** 測試架構與執行方式。  
  **總結：** 說明 unit/integration/e2e 位置、命名慣例與 `mise` 測試命令。

- `STYLEGUIDE.md`  
  **用途：** 程式碼與 CLI 輸出風格規範。  
  **總結：** 定義 license header、fmt/lint 建議流程與 CLI 排版風格。

- `CLAUDE.md`  
  **用途：** agent 指令入口。  
  **總結：** 僅轉址到 `AGENTS.md`，不含額外規範。

---

## 二、使用者文件（`docs/`）

### 2.1 入口與概念

- `docs/index.md`  
  **用途：** 官方文件首頁。  
  **總結：** 聚合 About、Get Started、Tutorials、Reference 導覽入口。

- `docs/about/overview.md`  
  **用途：** 產品目的與風險控制總覽。  
  **總結：** 說明 OpenShell 的風險模型與四層防護設計。

- `docs/about/architecture.md`  
  **用途：** 高階架構介紹。  
  **總結：** 以使用者角度解釋 gateway/sandbox/policy/router 與 request flow。

- `docs/about/supported-agents.md`  
  **用途：** 支援 agent 清單。  
  **總結：** 列出各 agent 的來源、預設政策覆蓋與使用條件。

- `docs/about/release-notes.md`  
  **用途：** 版本變更入口。  
  **總結：** 導向 releases、比較頁、merged PR 與 commit log。

### 2.2 入門與教學

- `docs/get-started/quickstart.md`  
  **用途：** 最短上手流程。  
  **總結：** 安裝 CLI、建立第一個 sandbox，並提供常見部署入口。

- `docs/tutorials/index.md`  
  **用途：** 教學索引。  
  **總結：** 依場景串接 policy、GitHub、Ollama、LM Studio 教學。

- `docs/tutorials/first-network-policy.md`  
  **用途：** 第一個 network policy 教學。  
  **總結：** 示範 default-deny、L7 規則與 hot-reload。

- `docs/tutorials/github-sandbox.md`  
  **用途：** GitHub push 權限調整教學。  
  **總結：** 演示 fail->診斷->改 policy->驗證的完整迭代流程。

- `docs/tutorials/inference-ollama.md`  
  **用途：** Ollama 推論整合教學。  
  **總結：** 涵蓋社群 sandbox 與 host-level 兩種實作路徑。

- `docs/tutorials/local-inference-lmstudio.md`  
  **用途：** LM Studio 本地推論教學。  
  **總結：** 說明 OpenAI/Anthropic 兩種協議在 `inference.local` 的配置方法。

### 2.3 Sandbox / Gateway / Provider / Policy

- `docs/sandboxes/index.md`  
  **用途：** sandbox 與 gateway 概念頁。  
  **總結：** 定義 lifecycle、部署型態與預設 policy 層次。

- `docs/sandboxes/manage-sandboxes.md`  
  **用途：** sandbox 操作手冊。  
  **總結：** 涵蓋 create/connect/logs/forward/upload/download/delete 全流程。

- `docs/sandboxes/manage-gateways.md`  
  **用途：** gateway 佈署與管理手冊。  
  **總結：** 說明 local/remote/cloud 註冊、切換與排錯流程。

- `docs/sandboxes/manage-providers.md`  
  **用途：** 憑證 provider 管理。  
  **總結：** 說明 provider 建立、更新、掛載與支援類型。

- `docs/sandboxes/policies.md`  
  **用途：** policy 實作與迭代。  
  **總結：** 說明 static/dynamic 區分、hot-reload、deny 診斷與修正流程。

- `docs/sandboxes/community-sandboxes.md`  
  **用途：** 社群 sandbox 使用與投稿。  
  **總結：** 解釋 `--from` 來源解析與社群目錄規範。

### 2.4 Inference / Reference / Resources

- `docs/inference/index.md`  
  **用途：** inference routing 概念頁。  
  **總結：** 區分 `inference.local` 與一般外部 inference endpoint 的處理路徑。

- `docs/inference/configure.md`  
  **用途：** inference 路由設定手冊。  
  **總結：** 以 provider + model 建立 managed inference，並提供驗證步驟。

- `docs/reference/default-policy.md`  
  **用途：** 預設 policy 參考。  
  **總結：** 說明預設 policy 對不同 agent 的覆蓋程度。

- `docs/reference/policy-schema.md`  
  **用途：** policy 欄位字典。  
  **總結：** 完整定義 YAML 欄位、驗證限制與 endpoint/rules/binaries 語意。

- `docs/reference/gateway-auth.md`  
  **用途：** gateway 認證參考。  
  **總結：** 解釋 mTLS、edge JWT、plaintext 三種連線模式與憑證檔案布局。

- `docs/reference/support-matrix.md`  
  **用途：** 平台支援矩陣。  
  **總結：** 列出 OS/架構、Docker 版本、映像與 kernel 能力需求。

- `docs/resources/license.md`  
  **用途：** 授權說明。  
  **總結：** 指向 Apache 2.0 並內嵌 LICENSE。

- `docs/CONTRIBUTING.md`  
  **用途：** 文件撰寫與審閱規範。  
  **總結：** 定義 MyST/frontmatter、語氣風格與提交流程。

- `docs/_ext/json_output/README.md`  
  **用途：** 文件建置 extension 說明。  
  **總結：** 說明 Sphinx JSON 輸出功能、設定與效能優化參數。

---

## 三、架構文件（`architecture/`）

- `architecture/README.md`  
  **用途：** 架構總覽入口。  
  **總結：** 描述子系統關係並提供各架構文件索引。

- `architecture/system-architecture.md`  
  **用途：** 系統總拓撲。  
  **總結：** 視覺化呈現 CLI/gateway/sandbox/external 的通訊與責任分工。

- `architecture/gateway.md`  
  **用途：** gateway 深入設計。  
  **總結：** 詳述協定多工、gRPC 服務、儲存、watch/event bus 與 SSH tunnel。

- `architecture/gateway-security.md`  
  **用途：** gateway 安全設計。  
  **總結：** 說明 PKI、mTLS、secret 分發、連線驗證與威脅模型。

- `architecture/gateway-deploy-connect.md`  
  **用途：** gateway 連線模型。  
  **總結：** 解釋 gateway resolution 與 mTLS/edge/plaintext 連線路徑。

- `architecture/gateway-settings.md`  
  **用途：** 設定通道架構。  
  **總結：** 描述 global/sandbox 兩層設定合併規則與 global policy lifecycle。

- `architecture/gateway-single-node.md`  
  **用途：** 單節點 bootstrap 設計。  
  **總結：** 說明從啟動到可連線的完整部署序列。

- `architecture/sandbox.md`  
  **用途：** sandbox 核心實作說明。  
  **總結：** 最完整核心文件，涵蓋 OPA、L7、netns、identity、log streaming、錯誤模型。

- `architecture/sandbox-connect.md`  
  **用途：** sandbox 連線機制。  
  **總結：** 詳解 SSH tunnel、port forward、file sync 與 NSSH1 handshake。

- `architecture/sandbox-providers.md`  
  **用途：** provider 子系統設計。  
  **總結：** 說明 provider discovery、憑證注入流程與安全邊界。

- `architecture/sandbox-custom-containers.md`  
  **用途：** 自訂容器策略。  
  **總結：** 解釋 `--from` 解析、build flow、supervisor 接管與已知限制。

- `architecture/inference-routing.md`  
  **用途：** inference 路由設計。  
  **總結：** 說明 control plane/data plane 分工、route bundle 與 router rewrite 行為。

- `architecture/security-policy.md`  
  **用途：** policy 語言規格。  
  **總結：** 定義 schema、行為觸發器（L4/L7/forward proxy/`allowed_ips`）與更新模型。

- `architecture/policy-advisor.md`  
  **用途：** policy 建議系統。  
  **總結：** 描述 denial aggregation->proposal->approval 的人機協作流程。

- `architecture/tui.md`  
  **用途：** TUI 設計文件。  
  **總結：** 說明畫面結構、快捷鍵、資料刷新與目前缺口。

- `architecture/build-containers.md`  
  **用途：** 映像管理說明。  
  **總結：** 簡述 gateway/cluster/sandbox 映像角色與本地開發方式。

---

## 四、範例文件（`examples/`）

- `examples/gateway-deploy-connect.md`  
  **用途：** gateway 部署連線範例。  
  **總結：** 提供 local/remote/edge 三種部署的命令化示範。

- `examples/sandbox-policy-quickstart/README.md`  
  **用途：** policy 快速演示。  
  **總結：** 用最短流程展示 default-deny 到 L7 method/path 控制。

- `examples/private-ip-routing/README.md`  
  **用途：** private IP 放行示範。  
  **總結：** 演示 `allowed_ips` 如何在 SSRF 保護下有條件允許內網服務。

- `examples/local-inference/README.md`  
  **用途：** inference.local 路由範例。  
  **總結：** 示範 cluster 與 standalone 的 inference 路由驗證。

- `examples/policy-advisor/README.md`  
  **用途：** Policy Advisor CTF。  
  **總結：** 以關卡演示 deny 事件如何轉成可批准的 policy 建議。

- `examples/bring-your-own-container/README.md`  
  **用途：** BYOC 範例。  
  **總結：** 示範以自訂 Dockerfile 建 sandbox 並透過 port forwarding 對外服務。

- `examples/vscode-remote-sandbox.md`  
  **用途：** VS Code 遠端連線 sandbox。  
  **總結：** 用 `--editor vscode` 走 managed SSH include 快速開發。

- `examples/sync-files.md`  
  **用途：** sandbox 檔案同步。  
  **總結：** 說明 upload/download/sync 流程與 tar-over-SSH 原理。

- `examples/openclaw.md`  
  **用途：** OpenClaw sandbox 啟動。  
  **總結：** 提供快速與分步兩種啟動方式，含 port-forward 入口。

---

## 五、工程輔助文件

- `scripts/build-benchmark/README.md`  
  **用途：** 佈署建置效能驗證。  
  **總結：** 定義 cluster deploy fast-test 各場景與測試輸出設定。

- `crates/openshell-router/README.md`  
  **用途：** router crate 邊界說明。  
  **總結：** 說明 routing engine 責任與與 `openshell-server` 的分工契約。

- `crates/openshell-ocsf/schemas/ocsf/README.md`  
  **用途：** OCSF schema vendor 說明。  
  **總結：** 記錄離線驗證用 schema 版本、內容與更新指令。

---

## 維護建議

- 當新增/刪除文件時，優先更新本導讀對應章節與閱讀順序。
- 若文件用途重疊，保留一份「主文件」並在其他文件互相連結，避免知識分裂。
- 發版前可快速檢查 `docs/`、`architecture/`、`examples/` 是否有新檔未納入本導讀。
