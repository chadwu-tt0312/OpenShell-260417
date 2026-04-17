# OpenShell 專案文件導讀（Security / Compliance v3）

> 目標：把 v2 的 Security 路線再縮成  
> 1) **15 份必讀最小集合**（Minimal Set），以及  
> 2) **90 分鐘上手閱讀順序**（含時間切片與閱讀目標）。  
>
> 假設：你要做的是 **security / compliance 審查與風險評估**，而不是立即修改程式碼。

---

## A) 15 份必讀最小集合（Security Minimal-15）

> 這 15 份文件的設計是：能回答審查時最常見的 5 類問題：  
> **(1)** 系統邊界與資料流、**(2)** 連線/認證模型、**(3)** policy 語意與驗證、  
> **(4)** sandbox 的實際 enforce 機制、**(5)** 支援限制與通報流程。

### A1. 系統全貌（3）

1. `docs/about/overview.md`  
   **你要帶走：** 威脅→控制的對照表（OpenShell 打算防哪些常見 agent 風險）。

2. `docs/about/architecture.md`  
   **你要帶走：** request flow 的高階路徑（控制面/資料面分工，哪些地方會介入/阻斷）。

3. `architecture/system-architecture.md`  
   **你要帶走：** 全系統通訊拓撲與信任邊界（CLI↔gateway↔sandbox↔external）。

### A2. Gateway 認證與邊界（4）

4. `docs/reference/gateway-auth.md`  
   **你要帶走：** mTLS / edge JWT / plaintext 三模式；CLI 解析優先序；憑證/token 的本機檔案布局。

5. `architecture/gateway-security.md`  
   **你要帶走：** PKI、secret 分發、SSH tunnel 認證與 threat model（「哪些有被認證」「哪些刻意不認證」）。

6. `architecture/gateway-deploy-connect.md`  
   **你要帶走：** 連線模式的實際資料流與差異（尤其 edge-authenticated 的 WebSocket tunnel）。

7. `docs/sandboxes/manage-gateways.md`  
   **你要帶走：** 實務部署/註冊/切換 gateway 的操作面與安全選項（`--plaintext`、`--disable-gateway-auth` 的使用情境）。

### A3. Policy（語言、Schema、實務迭代）（4）

8. `architecture/security-policy.md`  
   **你要帶走：** policy「行為觸發器」：L4/L7/SSRF/`allowed_ips`/forward proxy；static vs dynamic 更新邊界。

9. `docs/reference/policy-schema.md`  
   **你要帶走：** 欄位字典與驗證限制（什麼會被拒絕、什麼只是 warning）。

10. `docs/sandboxes/policies.md`  
    **你要帶走：** audit→enforce 的建議迭代流程與 deny log 的證據鏈。

11. `docs/reference/default-policy.md`  
    **你要帶走：** 預設 policy 對常見 agent 的覆蓋程度（哪些必須補 policy 才能用）。

### A4. Sandbox 實際 enforce（2）

12. `architecture/sandbox.md`  
    **你要帶走：** sandbox 的 defense-in-depth 細節：Landlock/seccomp/netns、/proc identity binding、TOFU、SSRF、bypass detection、log streaming。

13. `docs/sandboxes/index.md`  
    **你要帶走：** sandbox/gateway 概念與 lifecycle；保護層的「何時生效、是否可 hot-reload」。

### A5. 推論路由（Inference）與資料外送風險（1）

14. `architecture/inference-routing.md`  
    **你要帶走：** `inference.local` 為「明示路由」，control plane（gateway）與 data plane（sandbox）分工；credential 注入與 model rewrite 的邊界。

### A6. 限制與通報（1）

15. `docs/reference/support-matrix.md` + `SECURITY.md`（同一個閱讀單元）  
    **你要帶走：**
    - 支援限制（Kernel 能力：Landlock/seccomp；平台狀態），哪些限制會影響安全主張。  
    - 漏洞通報流程（不要在 GitHub 公開回報）。

> 備註：第 15 點是「兩份文件合讀」，因為它們通常在審查報告中會同時被引用（限制與通報）。

---

## B) 90 分鐘上手閱讀順序（Security 90-min Onboarding）

> 原則：先建立「可用的審查框架」，再深入細節。  
> 每段都附「閱讀目標」，你可以用它來寫審查筆記或做合規對照。

### 0–10 分鐘：定位與威脅模型入口（10m）

- 讀 `docs/about/overview.md`
- **目標：**
  - 列出你最關心的 3 個風險（例如 data exfiltration、credential theft、unauthorized API usage）。
  - 對照它提供的 controls，標記「需要證據」的控制點（稍後在架構/實作文件找證據）。

### 10–25 分鐘：高階架構與資料流（15m）

- 讀 `docs/about/architecture.md`
- **目標：**
  - 畫出（或在腦中建立）控制面 vs 資料面的分界：哪些事情在 gateway 做、哪些在 sandbox 做。
  - 確認「policy 評估」在 request flow 的位置（L4 / L7）。

### 25–40 分鐘：全系統拓撲與 trust boundaries（15m）

- 讀 `architecture/system-architecture.md`（看圖為主）
- **目標：**
  - 明確標出：CLI↔gateway、gateway↔K8s、sandbox↔proxy、proxy↔external 的鏈路。
  - 列出 2–3 個「最怕被繞過」的關卡（例如 direct egress、private IP SSRF、未授權 tunnel）。

### 40–60 分鐘：Gateway 認證與隧道模型（20m）

- 先讀 `docs/reference/gateway-auth.md`（操作/檔案布局/優先序）  
- 再讀 `architecture/gateway-security.md`（威脅模型與保護邏輯）
- **目標：**
  - 釐清「誰被認證」「用什麼材料被認證」（client cert / edge token / plaintext）。
  - 釐清 SSH tunnel 的認證與 handshake 機制（以及它刻意不做什麼）。

### 60–80 分鐘：Policy 的語意與行為觸發器（20m）

- 先讀 `architecture/security-policy.md`（行為觸發器）  
- 再讀 `docs/reference/policy-schema.md`（欄位與驗證）
- **目標：**
  - 把 policy 分成 static（不可熱改）與 dynamic（可熱改）並能說出原因。
  - 釐清這些關鍵：`protocol: rest` 才會啟動 L7、`enforcement: audit/enforce` 差異、SSRF 的預設封鎖與 `allowed_ips` 的例外。

### 80–90 分鐘：把「審查可操作」落地（10m）

- 快速掃 `docs/sandboxes/policies.md`（deny→修 policy→驗證）  
- **目標：**
  - 確認系統提供「可觀測證據」：deny log 至少包含 host/port/binary，L7 還包含 method/path。
  - 寫下你要在審查報告中要求的最小證據：policy YAML + deny log 範例 + 允許後的 allow log。

---

## C) TO-DO List（你用這份 v3 做 Security 審查時）

- [ ] 先決定你的審查範圍：只審「policy & egress」，或包含「gateway auth & tunnel」與「inference.local」。
- [ ] 用 B 的 90 分鐘流程做一輪筆記，輸出 1 頁「控制點/證據表」。
- [ ] 若要深入驗證實作一致性：加讀 `architecture/sandbox.md`（尤其 SSRF、identity binding、bypass detection、log streaming 章節）。

