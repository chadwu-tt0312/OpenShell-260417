# OpenShell 驗證矩陣（外部 Dispatcher + OpenAI-compatible API）

本文件將圖片中的 `ready -> assign -> recycle` 概念，對映到可在 OpenShell 本機環境量測的驗證案例。

## TO-DO List（執行）

- [ ] 驗證檔案傳遞流程（create-time upload、runtime upload、download）
- [ ] 驗證 OpenCode serve API（/health、/v1/models）
- [ ] 驗證 Dispatcher 對接路徑（ready/assign/recycle）
- [ ] 蒐集證據鏈（命令、時間戳、回應碼、logs）

## A. 檔案傳遞驗證（Upload/Download）

## A1. 建立時上傳

步驟：

```bash
openshell sandbox create --name file-a --upload .:/sandbox -- opencode
openshell sandbox connect file-a
ls -la /sandbox
```

驗收標準：

- 建立成功，且 `/sandbox` 可見上傳內容
- 若使用 `.gitignore`，被忽略檔案不會上傳（預期行為）

## A2. 執行中上傳（增量）

步驟：

```bash
echo "v1" > /tmp/probe.txt
openshell sandbox upload file-a /tmp/probe.txt /sandbox/probe.txt
openshell sandbox connect file-a
cat /sandbox/probe.txt
```

再更新一次：

```bash
echo "v2" > /tmp/probe.txt
openshell sandbox upload file-a /tmp/probe.txt /sandbox/probe.txt
openshell sandbox connect file-a
cat /sandbox/probe.txt
```

驗收標準：

- 第二次讀取結果為 `v2`
- upload 後檔案在合理秒級延遲內可讀

## A3. 下載回主機

步驟：

```bash
openshell sandbox download file-a /sandbox/probe.txt ./probe-from-sandbox.txt
cat ./probe-from-sandbox.txt
```

驗收標準：

- 本機下載內容與 sandbox 內一致

## B. OpenAI-compatible Serve API 驗證

## B1. 啟動與轉發

步驟：

```bash
openshell sandbox create --name ocode-api --forward 4096 -- opencode
openshell sandbox connect ocode-api
opencode serve --hostname 127.0.0.1 --port 4096
```

另開主機 terminal 驗證：

```bash
curl -sf http://localhost:4096/health
curl -sf http://localhost:4096/v1/models
```

驗收標準：

- `/health` 回應成功（2xx）
- `/v1/models` 回應成功且格式正確

## B2. 穩定性與恢復

步驟：

```bash
for i in $(seq 1 200); do curl -sf http://localhost:4096/health >/dev/null || echo "fail:$i"; done
openshell forward stop 4096 ocode-api
openshell forward start 4096 ocode-api -d
curl -sf http://localhost:4096/health
```

驗收標準：

- 連續檢查無錯誤（或錯誤率低於門檻）
- forward 重啟後服務可恢復

## C. 外部 Dispatcher 對接驗證（Ready / Assign / Recycle）

| 階段 | 驗證步驟 | 觀測點 | SLO（建議） |
|---|---|---|---|
| Ready | Dispatcher 呼叫建立 sandbox，直到可連線與 health pass | create->ready 延遲、`sandbox get` 狀態、health 成功 | p95 < 120s |
| Assign | Dispatcher 分配 sandbox URL 給 user，user 首次呼叫 API | 首次請求成功率、首包延遲 | 首次成功率 >= 99% |
| Recycle | 任務結束 delete/recreate，重新進入 ready | recycle 成功率、重建延遲 | 成功率 >= 99%，p95 < 180s |
| Consistency | 對帳 Dispatcher 狀態與 OpenShell 狀態 | 狀態落差筆數 | 0 筆不一致 |

## D. 證據鏈模板（每次測試都要留）

- 測試 ID：
- 測試時間（UTC）：
- Dispatcher request ID：
- OpenShell sandbox name：
- 執行命令：
- API 回應碼/延遲：
- `openshell sandbox get` 摘要：
- `openshell logs <name> --tail --source sandbox --level warn` 摘要：
- 結論（pass/fail）與原因：

## E. 清理

```bash
openshell sandbox delete file-a
openshell sandbox delete ocode-api
```
