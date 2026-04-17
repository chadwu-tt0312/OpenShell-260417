# OpenShell POC（內網完全禁止 TLS）安全機制落地評估與實作參考

> 目標：在「完全隔離、**完全禁止 TLS（含 HTTPS/mTLS）**、對外僅允許 HTTP」的廠內環境，分階段完成 OpenShell POC：先證明可用，再逐步達到可稽核、可追溯、可證明（以合理語義）之安全性。
>
> 優先序：**Confidentiality（防資料外洩） > Availability（不中斷）**  
> 部署：Kubernetes（K8s），已具備私有 registry  
> LLM：Azure-like API，但 **OpenAI 相容**，認證 header **固定為 `api-key`**  
> 「可證明」語句：**可證明 egress 只到允許端點 + 可稽核**

---

## 0. TL;DR（先講硬邊界與你能「證明」的範圍）

- **沒有 TLS，就無法在「傳輸層」證明 Confidentiality（機密性）**：你無法用密碼學方式證明「封包內容只有端點雙方能看」。
- 在你的限制下，POC 能合理主張與驗證的是：
  - **可證明 egress 只到允許端點**（fail-closed、不可繞過）
  - **可稽核/可追溯**（每筆請求與設定變更皆有證據鏈）
- 但必須明確聲明做不到的部分：
  - **無法證明跨節點/跨網段的資料在傳輸中不會被側錄或竄改**（除非把資料面限制在同節點/loopback，或導入其他等效保護機制）

---

## 1. 為什麼「沒有 TLS 就無法在傳輸層證明 Confidentiality」（詳細）

這句話的關鍵在「**證明（provable）**」：不是說「一定會外洩」，而是指你**缺少能提供可驗證安全性保證的機制**。TLS 提供的並不是行為約定，而是可被第三方檢驗的密碼學屬性。

### 1.1 Threat model 最小假設（企業內網合理對手）

若要在傳輸層宣稱 Confidentiality，你至少要能抵抗以下任一類對手：

- **被動側錄者（passive observer）**：能看到封包（SPAN/mirror port、網路 TAP、交換器 ACL 誤設、被植入的監控探針、同 L2 廣播域惡意主機、或節點上的特權程式）。
- **中間人（MITM, active attacker）**：能攔截並修改封包或做重導（ARP spoofing、路由注入、DNS 污染、L7 proxy 劫持、service mesh/代理被濫用、或任一節點被入侵後做轉送）。

在 K8s 內網，額外常見的是：

- **同節點特權者**：能讀取 veth/bridge/iptables/nftables 觀測點、或抓取 conntrack/pcap。
- **網路設備/監控平台**：為了可觀測性而合法部署，但同樣意味著「內容可被讀取」。

### 1.2 沒有 TLS 時，攻擊面是結構性的

若你的應用層傳輸是明文 HTTP：

- **被動側錄**：封包 payload 直接可讀。這不是「設定」能避免的，而是通訊協定層級的事實。
- **主動竄改**：攻擊者可修改請求/回應內容而不被偵測（例如把 model 改掉、把 prompt 注入、把回應置換、插入惡意指令），除非你在應用層額外做完整性校驗。

### 1.3 「沒有 TLS」不只影響 Confidentiality，也影響你能否做出可稽核的證據鏈

你要求「可稽核、可追溯、可證明」。這些都依賴兩件事：

- **端點身分可驗證（endpoint authentication）**：我連到的真的是「那個 inference/router/gateway」，而不是被換成別人。
- **資料不可被無痕竄改（integrity）**：傳輸中沒被改，或被改一定能被偵測。

TLS（含 mTLS）提供的正是：

- **機密性**：對被動側錄者不可讀
- **完整性**：對中間人竄改可偵測
- **端點認證**：透過憑證鏈驗證服務端（mTLS 再加上 client 身分）

沒有 TLS 時，你可能仍能「寫 audit log」，但你**很難證明 audit log 所描述的請求/回應「真的是那次網路交換」**，因為：

- 內容可被中間人改掉而不留痕
- 你以為呼叫到 A，但實際是 B（DNS/路由/代理被換）

### 1.4 為什麼「只能走 HTTP」會直接踩到 OpenAI `api-key` 的風險點

在 OpenAI 相容 API 中，`api-key` 通常是**長期 bearer secret**（誰拿到誰就能用）。在 HTTP 明文傳輸下：

- **任何能側錄的人都能取得 api-key**，之後離線重放（replay）或改用自己的客戶端呼叫。
- 你就算限制「agent egress 只到允許端點」，也擋不住「別的內網對手」拿到 key 後改從其他位置打你的 LLM。

因此在禁 TLS 的前提下，要把風險壓到可接受，你通常必須做「替代控制」來縮短 secret 的有效範圍，例如：

- **把 `api-key` 變成短效 token**（以時間窗/nonce 綁定，搭配 server 端驗證）
- **把推論 access 變成 mTLS 以外的可驗證身分**（例如請求簽章：HMAC/Ed25519；或在內網使用硬體/節點身分）

> 這些做法可以在「不使用 TLS」的前提下提供「完整性/身分」的一部分，但仍不提供傳輸機密性。

### 1.5 為什麼「loopback/同節點」可能是例外（你目前的假設）

你目前假設「可能不會連 loopback 都被政策禁止」。若資料面能被限制在：

- **同 Pod 內 loopback**（`127.0.0.1`）或
- **同節點、且不出實體網卡**（例如透過 hostNetwork/Unix domain socket/同節點 CNI 路徑）

那麼你可以把「傳輸層」的威脅面縮小：外部網路側錄者不再是主要對手，剩下的是「同節點特權者」。此時你能更合理地把安全主張改為：

- **可證明 agent 不可繞過本機 TCB（proxy/router）**，且
- **可稽核每次請求**。

但仍要注意：同節點 root/特權容器仍可側錄 loopback/veth，所以「完全機密」仍然不能靠傳輸層證明，只是對手模型縮小了。

---

## 2. 你的已知前提（本文件後續以此推導）

- 對外（跨節點/跨網段）**一律只能走 HTTP**
- 對內（先不限定）：先假設 **loopback/同節點可以使用任意通訊方式**（包含 TLS 是否被允許仍未定）
- Azure-like API：**OpenAI 相容**
- 認證 header：**固定為 `api-key`**
- 「可證明」語句：**可證明 egress 只到允許端點 + 可稽核**

---

## 3. 兩種 image 的區別與作用（工作環境 vs 安全關鍵路徑）

你看到的兩份 Dockerfile（或兩類 image）通常屬於不同責任層：

### 3.1 「sandbox 內部工作環境」基底 image（給 agent 跑程式用）

這類 image 的目的，是提供 agent 在 sandbox 裡執行工作所需的 runtime/工具鏈，例如：

- 語言 runtime（Python/Node/Java 等）、常用 CLI 工具（git/curl/jq）
- 依你公司需求預裝 SDK、CA bundle（若允許）、內網工具

特性：

- **不應被當作安全邊界**：即便你把它做得很乾淨，agent 在裡面仍是「可執行任意程式碼」的威脅主體。
- **可做二次開發**：加工具、改預設設定、加內網套件 mirror，通常風險在「供應鏈」與「擴大可用工具」。

影響範圍：

- 影響可用性（agent 能做什麼）與供應鏈風險（image 內容是否可被污染）
- **不直接決定 egress 能不能被繞過**（那是 proxy/namespace/policy 決定的）

### 3.2 「監督/代理/路由」安全關鍵路徑的 image（TCB）

這類 image/元件承擔的是 Out-of-Process 防護的核心（TCB），例如：

- **Sandbox proxy / L7 攔截**（決定能不能對外連、能不能只走 inference.local）
- **Privacy Router（openshell-router）**（決定怎麼分流、怎麼注入 auth、怎麼重寫 model）
- **Supervisor（openshell-sandbox）**（控制 sandbox lifecycle、策略執行、與 gateway 交換路由/設定）
- **Gateway（openshell-server）**（控制面：下發設定、provider/route 管理、審計/驗證邏輯）

特性：

- **這裡的修改會改變威脅模型與安全聲明**：因為它就是你要「可證明」的那條路徑。
- 必須做到 **fail-closed**、最小攻擊面、可觀測/可審計、祕密遮罩。

影響範圍：

- 直接決定「惡意 agent 能不能出得去」
- 直接決定「你能不能產生可稽核/可追溯的證據」

### 3.3 你要怎麼用這個區分來做 POC

- **Phase 1 可用**：先允許工作環境 image 比較「重」（工具多），但 TCB 必須先能跑且可觀測。
- **Phase 2 可審計地安全**：反過來，工作環境 image 要收斂（減少可用工具與外連手段），TCB 要加強審計與不可繞過性。

---

## 4. 現況（以本 repo 程式碼可見內容為準）

- 共享 image build graph 在 `deploy/docker/Dockerfile.images`：
  - `gateway` image：封裝 `openshell-server`
  - `cluster` image：封裝 k3s/helm/k9s 與 `openshell-sandbox` supervisor binary
  - `supervisor-output`：只輸出 supervisor binary
- 推論路由的設計核心（現行版本）是 `inference.local` 單一入口（詳見 `architecture/inference-routing.md`）

---

## 5. 禁 TLS 的落地策略（分階段）

### 5.1 Phase 1（先可用）

目標：先讓系統在「對外只允許 HTTP」下跑起來，並保持後續可收斂到可審計。

- **資料面入口改為顯式 HTTP**（建議）：`http://inference.local/v1/...`
- router 對 upstream（內網 OpenAI 相容 LLM）以 HTTP 呼叫
- 基本審計：至少記錄 route、model、protocol、狀態碼、延遲、payload bytes、request hash

### 5.2 Phase 2（可審計地安全）

目標：把「可證明 egress 只到允許端點 + 可稽核」做到可驗收。

- **Egress 收斂與不可繞過**
  - 明確定義「允許端點」集合（最小化）
  - 對 agent 端的非預期外連一律 fail-closed
- **L7 白名單**
  - 只允許 OpenAI 相容必要 endpoints（如 `/v1/chat/completions`）
- **`api-key` 風險補強（在禁 TLS 下很關鍵）**
  - 最小可行：把 key 只存在 TCB、全程遮罩、嚴禁落地
  - 向可證明靠攏：引入短效 token 或請求簽章，降低側錄重放風險
- **審計不可竄改**
  - append-only/WORM 或導入外部 SIEM
  -（選配）用簽章鏈把事件串起來，降低「事後改 log」風險

---

## 6. Phase 1 實作狀態（本次已完成）

以下變更已在 `OpenShell-260324` 實作：

- **新增 `ollama` inference profile（HTTP + `api-key`）**
  - default base URL：`http://localhost:11434/v1`
  - auth header：`api-key`
  - protocol 白名單（Phase 1）：`openai_chat_completions`
- **Provider registry 新增 `ollama` 類型**
  - 可用 `OLLAMA_API_KEY` / `API_KEY` 作為 credential key source
- **Sandbox inference pattern 加入 Phase 1 白名單開關**
  - 環境變數：`OPENSHELL_INFERENCE_CHAT_ONLY=true|1`
  - 開啟後僅允許：`POST /v1/chat/completions`
- **安全強化：剝除 client 端 `api-key`**
  - 避免 client 送入 header 覆寫 route 端金鑰（僅使用 TCB 注入）

---

## 7. Phase 1 啟動方式（Ollama 版）

### 7.1 先啟動 Ollama（同主機）

```powershell
ollama serve
```

確認 API：

```powershell
curl http://localhost:11434/v1/models
```

### 7.2 建立 provider（`ollama`）

> 以下為概念流程，實際 CLI 參數請以 `openshell provider --help` 為準。

- provider type：`ollama`
- credential key：`OLLAMA_API_KEY`（若 Ollama 不驗證，可放內網約定值）
- config：`OLLAMA_BASE_URL=http://localhost:11434/v1`

### 7.3 設定 cluster inference（route = `inference.local`）

```powershell
openshell inference set --provider ollama-dev --model llama3.2
```

### 7.4 開啟 Phase 1 chat-only 白名單

```powershell
$env:OPENSHELL_INFERENCE_CHAT_ONLY="true"
```

### 7.5 驗證資料面（HTTP-only）

Agent 或測試客戶端請求：

```http
POST http://inference.local/v1/chat/completions
Content-Type: application/json
```

應得到成功回應；改打其他 path（例如 `/v1/responses`）應被拒絕（`403`）。

### 7.6 一鍵 Inference Probe 測試（bash 版）

新增腳本：`pass/phase1-inference-probe.sh`

用途：

- 驗證允許路徑：`POST /v1/chat/completions`（預期 `200`）
- 驗證拒絕路徑：`POST /v1/responses`（預期 `403`，在 chat-only mode）
- 產出 JSON 報告：`pass/phase1-inference-probe-report.json`
- 預設模式：`sandbox`（不帶參數可直接執行）

執行範例：

```bash
bash "pass/phase1-inference-probe.sh" \
  --base-url "http://inference.local" \
  --api-key "ollama-poc-key" \
  --model "llama3.2"
```

```bash
# 直接使用預設值（sandbox + https://inference.local）
bash "pass/phase1-inference-probe.sh"
```

若有失敗，腳本會以非 0 exit code 結束，方便接 CI / pipeline gate。

---

## 8. 測試與驗證結果（本次）

- 已新增/更新單元與整合測試覆蓋：
  - `ollama` profile + `api-key` auth
  - chat-only pattern 行為
  - `api-key` header sanitize
- **本機無 Rust toolchain（`cargo/rustc` 不存在）**，因此目前無法在此環境完成實際測試執行。
- 建議你在具備 Rust toolchain 的環境執行：
  - `cargo test -p openshell-core`
  - `cargo test -p openshell-providers`
  - `cargo test -p openshell-router`
  - `cargo test -p openshell-server inference::tests::resolve_managed_route_supports_ollama_profile`
  - `cargo test -p openshell-server inference::tests::upsert_cluster_route_verifies_ollama_with_api_key_header`
  - `cargo test -p openshell-sandbox l7::inference::tests::chat_only_mode_keeps_only_chat_completion_pattern`

---

## 9. 下一步實作 TO-DO（承接 Phase 1）

- [ ] 在你的執行環境安裝 Rust toolchain，跑完本文件第 8 章測試清單
- [ ] 啟動 `OPENSHELL_INFERENCE_CHAT_ONLY=true` 後執行 `pass/phase1-inference-probe.sh`
- [ ] 將 `pass/phase1-inference-probe-report.json` 納入 POC 驗收證據
- [ ] 補一條 egress 繞過測試（嘗試直連非允許 host，預期 fail-closed）
- [ ] 補最小審計稽核檢查（確認不含明文 `api-key`、有 request hash 與 status）
