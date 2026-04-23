### OpenShell 安全防護機制：廠內落地可行性評估與架構實踐報告

#### 1\. 專案背景與核心防護體系分析

在企業將 AI Agent 導入生產流程的過程中，Agent 被賦予了檔案讀寫、指令執行與 API 呼叫的特權。然而，這種高度靈活性也帶來了致命的資安隱患：AI 可能因惡意提示詞（Prompt Injection）導致機敏原始碼外洩、SSH 金鑰遭竊取，或在封閉網路中發起非預期的外部連線。OpenShell 的核心價值在於建構一個「AI Agent 專屬防火牆」。它不僅是一個沙箱（Sandbox），更是一個深度整合 Linux 核心安全特性（LSM、BPF）的治理框架。根據 Source Context 的技術分析，OpenShell 透過四層防禦體系實施縱深防禦，將「Natural Language（政策意圖）」精準轉化為「Code Entity（核心執行）」的強制約束：

##### OpenShell 四層防禦體系概覽

|防護層級|執行機制|生效時機|策略特性|  
|--|--|--|--|
|檔案系統 (Filesystem)|Landlock LSM  (ABI V1)|靜態 / 預執行|建立後不可變，阻斷對非授權路徑（如 SSH Keys）的讀寫 |
|程序 (Process)|Seccomp BPF  (SYS\_socket)|靜態 / 預執行|建立後不可變，限制系統呼叫，防範權限提升與核心攻擊 |
|網路 (Network)|HTTP Proxy \+ OPA  (Rego 引擎)|動態 / 熱重載|執行中可更新，精確控管 L4/L7 流量（Method/Path 級別）|  
|推理 (Inference)|Privacy Router  (inference.local)|動態 / 熱重載|攔截推理請求，執行憑證剝離與自動注入，防止 API Key 外流  |

**「So What?」策略分析：**  這種「靜態與動態分離」的架構對廠內維運至關重要。靜態層（Landlock/Seccomp）在沙箱啟動前即鎖死核心介面，確保執行環境的基座安全；而動態層（Network/Inference）允許資安人員在不重啟 Agent 任務的情況下，即時收緊違規請求。這意味著一旦偵測到異常行為，系統能 **瞬間阻斷其網路存取而不終止程序** ，完整保留 Agent 的「犯罪現場（Forensic State）」以供事後審計。若無法分離這兩種策略，企業將被迫在「安全性」與「任務連續性」之間做痛苦的二選一。

---

#### 2\. OpenShell 測試結果總結與驗證分析

為了評估 OpenShell 在實際資源受限環境中的穩定度，我們針對其 v0.0.14 至 v0.0.30 的演進版本進行了壓測，特別是針對 v0.0.26 引入 MicroVM 架構後的性能表現。

##### 關鍵數據萃取

* **資源占用驗證：**  
  * **記憶體 (RAM)：**  穩態下單一 Pod 的實際占用為  **351MB** （含 k3s sidecar 與監控開銷）。僅觀察單一二進位程序（17.5MB）會低估基礎設施成本，廠內部署須以 351MB 為基準計算併發容量。  
  * **磁碟占用：**  Sandbox 檔案系統約占用  **108MB** 。  
* **啟動效能：**  
  * **冷啟動 (Cold Boot)：**  受環境引導與套件裝載影響，首個 Sandbox 約需  **77 秒** ，後續冷啟動介於 10 至 80 秒。  
  * **熱啟動 (Warm Boot)：**  透過 Snapshot 與重用機制，就緒時間可縮短至  **7 至 9 秒** ，滿足生產環境對 Agent 即時響應的需求。  
* **Policy 驗證 (c01-c12 測試矩陣)：**  
  * 實測證實 L4/L7 攔截完全生效。例如：在 read-only 模式下發起 POST 請求會立即觸發 403 Forbidden。

##### 核心發現：Egress Probe 與「LLM 幻覺」驗證

測試中發現了極具警示意義的現象（SHA-8/3bc8e444 案例）：當模型被要求抓取 GitHub SHA 碼時，模型在對話中編造了看似正確的雜湊值（3bc8e444），但透過  **Egress Probe**  審計發現，該 Sandbox 實際上並未發起任何網路呼叫（allow=0, deny=0）。這證明了若無物理層級的網路稽核，Agent 可能會以「幻覺」欺騙使用者，而 OpenShell 的 Egress Probe 是判斷 Agent 任務真實性的唯一基準。

**技術預警：**  在廠內主機環境測試中，我們觀測到特定核心報錯：“FailedCreatePodSandBox ... error mounting "mqueue" ... no such device.”。這顯示若宿主機核心未編譯 CONFIG\_POSIX\_MQUEUE，OpenShell 的預設 Pod 隔離將失效。這類硬體依賴是落地前必須排除的技術瓶頸。

---

#### 3\. 目標達成分析 (1)：廠內「直接改來用」的可行性評估

**結論：OpenShell 目前處於 Alpha 階段（Single-player mode），直接套用於生產線具備高成本風險，建議採取「架構參考」策略。**

##### 落地障礙分析

1. **網路協議衝突：**  OpenShell 預設強制使用  **mTLS**  進行 Gateway 與 Sandbox 通訊。廠內封閉網路通常封鎖 443 端口，或缺乏動態憑證簽發（cert-manager）支援，導致內建通訊邏輯直接失效。  
2. **gvproxy**  **的監控盲點(only VM)：**  openshell-vm 依賴 gvproxy 作為使用者態網路棧（User-mode network stack）。雖然這避免了對宿主機 iptables 的污染，但它會導致流量繞過標準的宿主機網路審計工具（如 Snort 或廠內防火牆），增加資安監測的困難度。  
3. **環境相依性(only VM)：**  除了上述 mqueue 缺失問題，libcap-ng-dev 的依賴與鏡像拉取（ghcr.io）在無外網環境下均需全面重整。

##### 解決方案路徑

* **協議降級：**  修改 Gateway 源碼，將監聽端口改為 80 並關閉 TLS 驗證（適用於受物理保護的內網區）。  
* **DNS 劫持：**  透過廠內 DNS 將 api.openshell.internal 指向本地 Gateway IP。  
* **鏡像重定向：**  將 ghcr.io 的映像檔遷移至廠內私有倉庫（如 Harbor），並修改啟動腳本的拉取路徑。

**「So What?」分析：**  直接「魔改」Alpha 版程式碼會導致後續升級極端困難。我們建議擷取其核心安全邏輯，但在廠內成熟的 K8s 或虛擬化體系中實施。

---

#### 4\. 目標達成分析 (2)：OpenShell 架構轉化與落實方法

針對無法直接套用的限制，企業應拆解 OpenShell 的設計模式，構建自主可控的安全運作環境：

##### (1) 隔離環境選型：MicroVM (libkrun) vs. Docker

廠內高安全需求場景應參考 openshell-vm 的設計。

* **技術優勢：**  Docker 與宿主機共用核心，一旦發生容器逃逸（Container Escape），整個主機皆會失守。參考  **libkrun**  的做法提供「獨立 Guest Kernel」，即使 AI Agent 觸發核心漏洞，其損害也會被限制在 MicroVM 邊界內。 **這是說服廠務經理與資安主管的最強技術賣點。**
> 但是此機制在 ：OpenShell 專案中有一些問題尚未解決。例如: `gvproxy 的監控盲點`

##### (2) 動態 L7 策略落地 (OPA/Rego)

參考其 Sidecar 代理模式，將流量導向 OPA 引擎。這能實現針對企業內部系統的精細化控管，例如：允許 Agent GET 生產看板資料，但禁止 POST 更改機台設定參數。

##### (3) 隱私路由 (Privacy Router) 與憑證隔離

參考其 inference.local 攔截模式。

* **實務方法：**  實施「憑證剝離與注入」。Agent 在沙箱內不持有任何真實的 API Key，所有推理請求皆被引導至主機側的 Router，由 Router 自動注入企業憑證。這能確保即便 Agent 被駭，企業的 AI 帳戶權限也不會外流。

##### (4) 存儲隔離與持久化

參考其 state.raw 的 block-level 設計，為每個 Agent 分配獨立的區塊層級存儲，並結合 SQLite 自癒機制，確保 Agent 在遭遇突發斷電或崩潰後仍能保持工作環境的原子性。

#### 5\. 總結與落地建議

OpenShell 從 v0.0.14 演進至 v0.0.30，特別是 v0.0.26 引入的 libkrun 架構，展示了從「開發工具」向「企業級安全網關」邁進的趨勢。在廠內落地 AI 安全，建議採取「觀測先行、逐步收緊」的戰略。
> 向「企業級安全網關」邁進的趨勢。依然還只是趨勢，尚須邁進。

##### 階段性落地行動建議

1. **環境整備 (Week 1)：**  
    * 修復核心依賴，確保宿主機支援 mqueue 與 libcap-ng-dev（修正 mount: no such device 報錯）。  
    * 建置廠內私有鏡像倉庫與 DNS 映射環境。  
2. **策略定義 (Week 4)：**  
    * 優先建立  **靜態檔案系統權限清單 (Landlock)** ，鎖死對 /etc 或用戶主目錄的存取。  
    * 基於業務需求定義 L4/L7 網路白名單。  
3. **觀測優先 (Ongoing)：**  
    * **關鍵建議：**  初期部署建議採用  **Audit**  **模式**  而非 Enforce 模式。在此模式下，OPA 引擎會記錄違規（l7\_decision=deny）但允許流量通過。這能讓維運團隊在不中斷生產線的前提下，觀察 Agent 的真實行為特徵，待策略優化後再切換至強制模式。
> 落地行動建議：單純是 AI 的幻覺。個人不覺得能實行。

**最終結論：**  OpenShell 提供了一份卓越的 AI 安全藍圖。企業應借鑒其利用 Linux 核心特性（Landlock/Seccomp）搭配應用層代理（OPA/Router）的縱深防禦架構，構建自主、可審計且高強度的 AI Agent 執行環境。
