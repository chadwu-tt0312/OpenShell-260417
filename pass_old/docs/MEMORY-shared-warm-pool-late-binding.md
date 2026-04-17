# MEMORY: Shared warm pool + late binding

## 背景
- 目前流程透過 `OPEN_SHELL_WORKSPACE_USER_DATAPATH` 搭配 gateway recreate 切換資料目錄。
- 單次「切換 data 目錄 + 建立 sandbox」約需 2 分鐘上下，難以支援大量 user 的低延遲啟動。
- 目標是支援「總 user 上萬、同時活躍數百」時，仍可快速啟動 sandbox。

## 核心設計
- 採用 **Shared warm pool**，而非 per-user 常駐池。
- 採用 **late binding**，在 sandbox 建立/分配當下才綁定 user data path。
- gateway 盡量常駐，不因 user 切換而重建。

## 為什麼要定義成 SLO
- 不以「每次都 < 3 秒」當硬性承諾，改用分位數目標（P50/P95/P99）衡量真實體驗。
- 可同時管理平均體驗與尾延遲，避免只看平均數掩蓋尖峰問題。

## 建議 SLO（第一版）
- `P50 sandbox startup < 1.5s`
- `P95 sandbox startup < 3.0s`
- `P99 sandbox startup < 6.0s`
- `Warm pool hit rate >= 95%`（一般流量窗口）
- `Late binding path resolution + mount + auth <= 1.5s`（95th）

## 名詞定義
- **SLO（Service Level Objective）**：服務可用性/效能的可量測目標。
- **SLI（Service Level Indicator）**：實際量測指標，例如 startup latency。
- **SLA（Service Level Agreement）**：對外契約承諾，通常基於 SLO。

## 容量與調度策略
- 預設 warm pool: `500`（可動態調整，不是固定上限）。
- 依近 5~15 分鐘流量自動擴縮，避免池子長期過大或被打空。
- 分層池化：
  - hot pool：可立即分配。
  - warm pool：半就緒，能快速補位。
- 超量時採 queue + admission control，避免系統雪崩。

## 安全與隔離
- user-to-path 映射由 server 端授權，不信任 client 直接傳 path。
- path 必須做 canonicalization 與 traversal 防護。
- 掛載策略優先使用固定 base + per-user subpath。

## 落地 TO-DO
- [ ] 定義並落地 SLI 指標（startup latency、pool hit rate、queue depth、bind latency）
- [ ] 實作 late binding（sandbox create/allocate 時綁定 user data）
- [ ] 導入 shared warm pool（預設 500，支援 autoscaling）
- [ ] 補上 queue/admission control 與 timeout fallback
- [ ] 建立壓測場景：穩態 300、尖峰 800、突發 1200
- [ ] 依壓測結果調整 pool、資源配置與 SLO 門檻

## 驗收標準
- 在「平常活躍數量幾百」情境下，達成 `P95 < 3s`。
- 在尖峰情境下，系統保持可預期退化（排隊或回應啟動中），不出現全面超時。
- 監控面板可即時觀測 SLO 達成率與尾延遲變化。
