# OpenCode 最小可用 API 測試清單（curl 版）

此清單目標是用最少指令確認 `opencode serve` 在 OpenShell sandbox 轉發後可用。

## TO-DO List

- [ ] 確認 server 可達（非 000）
- [ ] 驗證 OpenAPI 文件入口可讀（`/doc`）
- [ ] 驗證健康檢查（`/global/health`）
- [ ] 驗證核心資源 API（`/project/current`、`/config`、`/provider`）
- [ ] 驗證 session 流程（list/create/get）
- [ ] 驗證 message API 可回應

## 0) 前置設定

```bash
BASE_URL="http://localhost:4096"

# 若你有設定 OPENCODE_SERVER_PASSWORD，請填入；否則留空字串
SERVER_USERNAME="${SERVER_USERNAME:-opencode}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"

# 無密碼模式
AUTH_ARGS=()

# Basic Auth 模式（若 SERVER_PASSWORD 不為空）
if [ -n "$SERVER_PASSWORD" ]; then
  AUTH_ARGS=(-u "${SERVER_USERNAME}:${SERVER_PASSWORD}")
fi
```

## 1) 基礎連通性

```bash
curl -s -o /dev/null -w "GET / => HTTP %{http_code}\n" "${AUTH_ARGS[@]}" "${BASE_URL}/"
```

預期：
- 不是 `000`（`200/401/403/404` 都代表服務可連通）

## 2) OpenAPI 文件

```bash
curl -s -o /dev/null -w "GET /doc => HTTP %{http_code}\n" "${AUTH_ARGS[@]}" "${BASE_URL}/doc"
```

預期：
- `200`（部分部署可能回 `3xx`，也可接受）

## 3) 健康檢查

```bash
curl -s "${AUTH_ARGS[@]}" "${BASE_URL}/global/health"
```

預期：
- `{"healthy":true,"version":"..."}` 類似結構

## 4) 核心只讀 API

```bash
curl -s -o /dev/null -w "GET /project/current => HTTP %{http_code}\n" "${AUTH_ARGS[@]}" "${BASE_URL}/project/current"
curl -s -o /dev/null -w "GET /config => HTTP %{http_code}\n" "${AUTH_ARGS[@]}" "${BASE_URL}/config"
curl -s -o /dev/null -w "GET /provider => HTTP %{http_code}\n" "${AUTH_ARGS[@]}" "${BASE_URL}/provider"
```

預期：
- 多數環境為 `200`
- 若 `401/403`，通常是認證未帶或權限策略限制

## 5) Session 最小流程

### 5.1 列出 session

```bash
curl -s "${AUTH_ARGS[@]}" "${BASE_URL}/session"
```

### 5.2 建立 session

```bash
SESSION_JSON="$(curl -s "${AUTH_ARGS[@]}" -X POST "${BASE_URL}/session" \
  -H "Content-Type: application/json" \
  -d '{"title":"smoke-test"}')"

echo "${SESSION_JSON}"
SESSION_ID="$(echo "${SESSION_JSON}" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
echo "SESSION_ID=${SESSION_ID}"
```

預期：
- 建立成功回傳含 `id` 的 JSON

### 5.3 讀取 session 詳細

```bash
curl -s "${AUTH_ARGS[@]}" "${BASE_URL}/session/${SESSION_ID}"
```

## 6) Message 最小流程

```bash
curl -s "${AUTH_ARGS[@]}" -X POST "${BASE_URL}/session/${SESSION_ID}/message" \
  -H "Content-Type: application/json" \
  -d '{
    "parts":[{"type":"text","text":"Reply with OK only."}]
  }'
```

預期：
- 回傳 message JSON（若 provider/model 未配置，可能回 4xx/5xx，需先補 provider）

## 7) 清理（可選）

```bash
curl -s "${AUTH_ARGS[@]}" -X DELETE "${BASE_URL}/session/${SESSION_ID}"
```

## 8) 常見失敗判讀

- `HTTP 000`：服務未啟動或 port forward 未建立
- `401/403`：通常是 server 開了 auth，但請求沒帶 Basic Auth
- `404`：路徑版本不一致，優先檢查 `${BASE_URL}/doc`
- `5xx`：後端 provider / model / runtime 問題，先看 server log
