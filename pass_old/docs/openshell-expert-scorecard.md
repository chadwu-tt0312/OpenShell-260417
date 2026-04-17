# OpenShell 專家級評分體系（Top 0.1% 視角）

此文件提供在「外部 Dispatcher + OpenShell sandbox + OpenAI-compatible API」場景下的高標準判斷框架。

## TO-DO List（導入順序）

- [ ] 先定義 SLO 與 Error Budget（先定義再測試）
- [ ] 建立 Failure-first 測試清單（先測最容易失敗路徑）
- [ ] 強制採證據鏈紀錄（每次測試可重現）
- [ ] 用分層 Scorecard 進行 go/no-go 決策

## 1) 高水平思路：先切面、後優化

頂尖團隊會先拆成四個面向，再做優化，避免混因：

- Control Plane：建立、刪除、狀態同步
- Data Plane：API 請求成功率、延遲、錯誤碼
- File Plane：檔案新鮮度與一致性
- Observability Plane：可觀測性與排障時間

## 2) 判斷標準：SLO 與 Error Budget

建議初始 SLO（可按業務調整）：

- Provisioning：`create -> ready` p95 < 120 秒
- API 可用性：成功率 >= 99.9%
- API 延遲：`/health` p95 < 300ms（本機可放寬）
- File Freshness：upload 後 5 秒內可在 sandbox 讀到
- Recycle：delete/recreate 成功率 >= 99%，p95 < 180 秒

Error Budget（例）：

- 每日 API 失敗率允許 0.1%
- 每 100 次 recycle 允許 <= 1 次失敗（需根因追蹤）

## 3) Failure-first 測試策略

先測最可能破壞使用者體驗的路徑：

1. forward 中斷再恢復（最常見）
2. 短時間連續 create/delete（資源競爭）
3. 大檔/大量小檔 upload（I/O 壓力）
4. API burst（瞬間流量）
5. Dispatcher 狀態與 OpenShell 狀態不一致（邏輯風險）

## 4) 證據鏈（Evidence Chain）要求

每個案例都必須可回放：

- 命令與參數（完整）
- 起訖時間戳（UTC）
- 回應碼與延遲（含 p50/p95）
- sandbox 狀態快照（`sandbox get/list`）
- logs 摘要（`openshell logs ... --source sandbox --level warn`）
- fail 時的最小重現步驟（MRE）

## 5) 分層評分（Scorecard）

| 層級 | 評估重點 | 通過門檻 |
|---|---|---|
| L1 Correctness | 能建、能連、能回 API、可傳檔 | 全部功能可用 |
| L2 Stability | 長時間與重複操作不退化 | 連續測試達標 |
| L3 Resilience | 故障注入後可恢復 | 恢復成功率達標 |
| L4 Operability | 排障效率、告警可讀性 | MTTR 在目標內 |

建議打分（每層 0~25，總分 100）：

- 90~100：可上生產（仍需持續監控）
- 75~89：可上預發/灰度
- <75：先修復關鍵缺陷再推進

## 6) Go / No-Go 決策規則（簡版）

- Go：L1~L3 全通過，且總分 >= 90
- Conditional Go：總分 80~89，但有明確緩解與回滾方案
- No-Go：任一關鍵 SLO 未達、或證據鏈不完整

## 7) 與本專案文件對位

- 操作流程：`pass/openshell-sandbox-runbook.md`
- 驗證案例：`pass/openshell-validation-matrix.md`
- 本文件：決策與評分標準（不取代測試案例）
