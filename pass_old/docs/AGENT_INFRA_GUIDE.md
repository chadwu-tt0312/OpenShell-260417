# OpenShell Agent 基礎設施文件導讀

> 本文件聚焦「OpenShell 這個 repo 內，為了 agent-first 開發而存在的基礎設施文件」。  
> 目標是讓你快速理解：**skill（技能）、persona（子代理）、模板、以及 CI/工作流**之間如何串起來。

## 讀者與範圍

- **適合誰：**
  - 你想把 AI agent 納入日常開發流程（triage / spike / build / docs / review）。
  - 你要新增或調整一個 skill、或想確保 agent-infra 沒有 drift。
  - 你要理解「為什麼這個 repo 的 issue/PR 有一堆規範與 gate」。

- **不包含：**
  - OpenShell runtime 本身的 sandbox/gateway 內部實作細節（那是 `architecture/` 的範圍）。

---

## 一、最高優先：總規約與貢獻流程

- `AGENTS.md`  
  **用途：** agent 在本 repo 的主要規約與工作鏈（workflow chain）。  
  **總結：** 這份是「agent-first」制度的 root；包含 commit 規範、測試要求、文件更新規則、安全邊界、以及 skills 的定位。

- `CONTRIBUTING.md`  
  **用途：** 人類貢獻者與 agent 協作的規範。  
  **總結：** 定義 vouch 機制、issue/PR 習慣、以及要求「你必須理解你送出去的 code」。

---

## 二、Skills（`.agents/skills/`）— 可被 harness 載入的操作手冊

> 這個目錄的每個 `SKILL.md` 是「可重用流程」：描述何時用、前置條件、與標準輸出格式。  
> 你把它們想成「agent 的 runbook/playbook」。

### 2.1 核心 skill（最常用）

- `.agents/skills/openshell-cli/SKILL.md`（搭配 `.agents/skills/openshell-cli/cli-reference.md`）  
  **用途：** CLI 全流程操作與常見工作流。  
  **總結：** 讓 agent 能用一致方式管理 gateway/sandbox/provider/policy/inference。

- `.agents/skills/debug-openshell-cluster/SKILL.md`  
  **用途：** cluster 啟動或健康問題的標準排查流程。  
  **總結：** 給出固定診斷順序與指令，避免「到處亂試」。

- `.agents/skills/debug-inference/SKILL.md`  
  **用途：** `inference.local` 與外部 inference 設定失敗排查。  
  **總結：** 聚焦 base URL、provider record、host 可達性、sandbox 端到端 probe。

- `.agents/skills/generate-sandbox-policy/SKILL.md`（搭配 `.agents/skills/generate-sandbox-policy/examples.md`）  
  **用途：** 從需求產生 policy（L4/L7、private IP、不同 detail tier）。  
  **總結：** 把「人話需求」轉成可套用的 YAML policy，並提供驗證/警告準則。

### 2.2 貢獻/治理型 skill（issue/PR 流程）

- `.agents/skills/triage-issue/SKILL.md`  
  **用途：** 對 incoming issue 做分類、診斷、與路由。  
  **總結：** 將 issue 導入 spike/build pipeline；強調 `state:*` label gate。

- `.agents/skills/create-spike/SKILL.md`  
  **用途：** 針對不明確問題做 codebase investigation 並產出結構化 issue。  
  **總結：** 把「想法」變成可建置的工程 issue（含技術證據與方案）。

- `.agents/skills/build-from-issue/SKILL.md`  
  **用途：** 依 issue 推進 plan→（人類核准）→實作。  
  **總結：** 明確區分 plan/review-ready/agent-ready 的狀態機，避免 agent 直接動手造成風險。

- `.agents/skills/create-github-issue/SKILL.md`、`.agents/skills/create-github-pr/SKILL.md`  
  **用途：** 以一致格式建立 issue/PR。  
  **總結：** 強制符合模板欄位，降低 maintainer review 成本。

- `.agents/skills/watch-github-actions/SKILL.md`  
  **用途：** 監看 GitHub Actions。  
  **總結：** 給出查看 run、job logs、rerun 的標準操作。

- `.agents/skills/update-docs/SKILL.md`  
  **用途：** 從 commits 回推需要更新的 docs。  
  **總結：** 適合發版前、或一段時間文件落後時做補齊。

- `.agents/skills/sync-agent-infra/SKILL.md`  
  **用途：** 偵測並修正 agent-infra drift。  
  **總結：** 當你新增/改名 skill、調整 workflow chain、或變更架構表時，這份是一致性檢查入口。

### 2.3 安全相關 skill

- `.agents/skills/review-security-issue/SKILL.md`、`.agents/skills/fix-security-issue/SKILL.md`  
  **用途：** security issue 的 review→fix pipeline。  
  **總結：** 強制 `topic:security` 與 `state:agent-ready` gate，避免誤修或公開洩漏。

---

## 三、Agent Personas（`.claude/agents/` 與 `.opencode/agents/`）

> 這些通常是「子代理 persona 定義」，描述其工作偏好與輸出格式。  
> 目標是把不同任務（架構文件、資深審查）切給不同 agent 角色。

- `.claude/agents/arch-doc-writer.md`、`.opencode/agents/arch-doc-writer.md`  
  **用途：** 架構文件同步更新的專用 persona。  
  **總結：** 將 code 變更同步反映到 `architecture/` 文件（偏「文件一致性」）。

- `.claude/agents/principal-engineer-reviewer.md`、`.opencode/agents/principal-engineer-reviewer.md`  
  **用途：** 高標準設計/程式審查 persona。  
  **總結：** 在 plan 或大型 PR review 前，用更嚴格的角度抓設計風險與長期維護成本。

> 註：`.claude/agent-memory/*` 這類通常是 persona 的偏好記錄/摘要，屬於 agent 操作層資料；是否要納入正式文件，取決於你是否要把它當「規格」而不是「偏好」。

---

## 四、GitHub 模板與工作流（`.github/`）

> 這一層是「治理落地」：把 vouch、DCO、docs build、release 等規則放進 CI。

### 4.1 模板

- `.github/PULL_REQUEST_TEMPLATE.md`  
  **用途：** PR 必填結構（Summary/Changes/Testing/Checklist）。  
  **總結：** 讓 PR review 有固定資訊密度與可追蹤性。

- `.github/ISSUE_TEMPLATE/*`  
  **用途：** issue 類型化與必填欄位。  
  **總結：** 尤其 bug template 通常要求附 agent diagnostic，符合 agent-first gate。

- `.github/DISCUSSION_TEMPLATE/vouch-request.yml`、`.github/VOUCHED.td`  
  **用途：** vouch 機制與名單。  
  **總結：** 控制外部貢獻者的信任建立流程，降低低品質 AI 產出造成的維護負擔。

### 4.2 Workflows（高頻）

- `.github/workflows/vouch-check.yml`、`.github/workflows/vouch-command.yml`  
  **用途：** 自動化 vouch gate 與 `/vouch` 指令更新名單。  
  **總結：** 保證未 vouch 的外部 PR 被 gate。

- `.github/workflows/dco.yml`  
  **用途：** DCO 簽署檢查。  
  **總結：** 確保 commit message 具備 Signed-off-by。

- `.github/workflows/docs-build.yml`、`.github/workflows/docs-preview-pr.yml`  
  **用途：** 文件建置與 PR 預覽。  
  **總結：** 強化「文件跟著改」的工程紀律。

- `.github/workflows/branch-checks.yml`、`.github/workflows/ci-image.yml`、`.github/workflows/docker-build.yml`  
  **用途：** 分支檢查、CI 映像、容器 build。  
  **總結：** 把 build/test/release 的關鍵步驟制度化。

---

## 五、文件寫作規範（`docs/CONTRIBUTING.md`）

- `docs/CONTRIBUTING.md`  
  **用途：** 文件風格與 MyST frontmatter 規範。  
  **總結：** 明確禁止 LLM 常見的「空話/過度 bold/emoji」等模式，確保技術文件可信度。

---

## 六、TO-DO List（你要做 agent-infra 變更時）

- [ ] **新增或改名 skill**：同步更新交叉引用（通常會牽涉 `CONTRIBUTING.md`、`AGENTS.md`、部分 docs/架構表），並跑一次一致性檢查思路（可參照 `.agents/skills/sync-agent-infra/SKILL.md`）。
- [ ] **新增 persona**：在 `.claude/agents/` 與 `.opencode/agents/`（若兩邊都用）保持對稱，並明確寫出適用場景與輸出格式。
- [ ] **調整 issue/PR gate**：同時檢查 `.github/workflows/*` 與模板是否一致，避免「規範寫了但 CI 沒 enforce」或反之。
- [ ] **文件變更**：遵循 `docs/CONTRIBUTING.md`，並確保 docs build lane 會過。

