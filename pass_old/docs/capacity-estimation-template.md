# 容量估算模板（Shared warm pool + late binding）

## 使用目的
- 估算 Shared warm pool 初始大小與自動擴縮上下界。
- 以 SLO 導向（P50/P95/P99）驗證是否可達成「大多數 user 快速啟動」。
- 在變更流量或基礎設施時，可快速重算容量。

## 1) 輸入參數（先填這張）

| 參數 | 符號 | 單位 | 範例 | 說明 |
|---|---|---:|---:|---|
| 平均到達率 | `lambda_avg` | req/s | 8 | 平常每秒啟動請求 |
| 尖峰到達率 | `lambda_peak` | req/s | 25 | 尖峰每秒啟動請求 |
| 平均使用時長 | `T_hold_avg` | s | 900 | sandbox 被占用平均秒數 |
| P95 使用時長 | `T_hold_p95` | s | 1800 | 長尾占用時間 |
| 冷啟動耗時（P95） | `T_cold_p95` | s | 45 | 未命中 warm pool 時耗時 |
| 熱啟動耗時（P95） | `T_warm_p95` | s | 2.2 | 命中 warm pool 時耗時 |
| late binding 耗時（P95） | `T_bind_p95` | s | 1.0 | auth + path + mount |
| 目標 warm hit rate | `H_target` | % | 95 | 一般流量窗口目標 |
| 安全係數（平常） | `S_avg` | 倍 | 1.2 | 吸收抖動 |
| 安全係數（尖峰） | `S_peak` | 倍 | 1.3 | 吸收突發 |
| 單節點可承載 sandbox | `C_node` | 個 | 120 | 依 CPU/RAM/IO 實測 |
| 節點數量 | `N_node` | 個 | 8 | 可用節點 |

---

## 2) 核心公式

### 2.1 併發需求估算（Little's Law）
- 平常併發需求：
  - `L_avg = lambda_avg * T_hold_avg`
- 尖峰併發需求：
  - `L_peak = lambda_peak * T_hold_avg`

### 2.2 warm pool 建議值
- 平常建議池：
  - `Pool_avg = ceil(L_avg * S_avg)`
- 尖峰建議池：
  - `Pool_peak = ceil(L_peak * S_peak)`

### 2.3 叢集硬上限（資源上限）
- `Pool_max_by_cluster = C_node * N_node`

> 實務上需滿足：`Pool_peak <= Pool_max_by_cluster`。  
> 否則必須擴節點、降每個 sandbox 配額、或接受排隊。

### 2.4 3 秒目標可行性快速檢查
- 若 `T_warm_p95 <= 3` 且 `H_target >= 95%`，通常可達 `P95 < 3s`。
- 若 `T_bind_p95 > 1.5`，即使池夠大也容易超標（先優化 late binding）。

---

## 3) 建議輸出欄位（計算後填）

| 輸出項目 | 結果 |
|---|---:|
| `L_avg` |  |
| `L_peak` |  |
| `Pool_avg`（最低常駐） |  |
| `Pool_peak`（尖峰目標） |  |
| `Pool_max_by_cluster`（資源上限） |  |
| 建議 `pool_min` |  |
| 建議 `pool_target` |  |
| 建議 `pool_max` |  |
| 是否可達 `P95 < 3s` |  |
| 主要風險 |  |

---

## 4) Autoscaling 建議（可直接套用）

- `pool_min = Pool_avg`
- `pool_target = round((Pool_avg + Pool_peak) / 2)`
- `pool_max = min(Pool_peak, Pool_max_by_cluster)`

### 觸發條件（範例）
- Scale out：
  - `queue_depth > 0` 持續 30 秒，或
  - `warm_hit_rate < 95%` 持續 5 分鐘，或
  - `startup_p95 > 3s` 持續 5 分鐘
- Scale in：
  - `warm_hit_rate > 99%` 且 `idle_ratio > 40%` 持續 15 分鐘

---

## 5) 一頁式範例（可替換數字）

- 假設：
  - `lambda_avg = 8 req/s`
  - `lambda_peak = 25 req/s`
  - `T_hold_avg = 60 s`（短任務情境）
  - `S_avg = 1.2`
  - `S_peak = 1.3`
  - `C_node = 120`
  - `N_node = 8`
- 計算：
  - `L_avg = 8 * 60 = 480`
  - `L_peak = 25 * 60 = 1500`
  - `Pool_avg = ceil(480 * 1.2) = 576`
  - `Pool_peak = ceil(1500 * 1.3) = 1950`
  - `Pool_max_by_cluster = 120 * 8 = 960`
- 解讀：
  - 目前硬上限 960 < 1950，尖峰一定排隊或超時。
  - 若要維持 `P95 < 3s`，需擴容或降低同時啟動需求（排隊、配額、節流）。

---

## 6) 驗收與壓測模板

### 壓測情境
- 穩態：`lambda=avg` 連續 30 分鐘
- 尖峰：`lambda=peak` 連續 10 分鐘
- 突發：從 0 突增到 `1.5 * lambda_peak`，持續 3 分鐘

### 驗收門檻（建議）
- `startup_p50 < 1.5s`
- `startup_p95 < 3s`
- `startup_p99 < 6s`
- `warm_hit_rate >= 95%`（穩態）
- 無大面積 timeout / error burst

---

## 7) TO-DO（每次容量重算必做）
- [ ] 更新最新流量資料（avg/peak）
- [ ] 更新最新 sandbox 占用時間分佈（avg/p95）
- [ ] 更新 late binding 與 startup latency 的實測值
- [ ] 重算 `pool_min/target/max`
- [ ] 跑三種壓測並比對 SLO
- [ ] 將結果回填至本文件並記錄版本日期
