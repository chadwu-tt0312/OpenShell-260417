# OpenShell Sandbox 操作 Runbook（本機）

本文件提供本機（WSL/Linux）環境的標準操作流程，目標是快速、可重複地完成 sandbox 建立、連線、觀測與清理。

## TO-DO List（執行順序）

- [ ] 啟動或確認 gateway 可用
- [ ] 建立 sandbox 並指定 OpenCode
- [ ] 確認 sandbox 狀態、可連線、可查日誌
- [ ] （可選）開啟 port forward 暴露服務
- [ ] 任務結束後清理 sandbox

## 0. 前置條件

- Docker daemon 已啟動
- `openshell` CLI 可用（`openshell --help`）
- 如需 OpenCode provider，自行準備 `OPENAI_API_KEY` 或 `OPENROUTER_API_KEY`

## 1. 啟動 Gateway

```bash
openshell gateway start
openshell status
```

預期：

- `openshell status` 顯示 gateway healthy
- 若尚未啟動 gateway，後續 `sandbox create` 也會自動 bootstrap

## 2. 建立 Sandbox（OpenCode）

### 最小建立

```bash
openshell sandbox create --name ocode-dev -- opencode
```

### 建立時同時上傳工作目錄

```bash
openshell sandbox create --name ocode-dev --upload .:/sandbox -- opencode
```

### 建立時同時開啟 API 轉發（例如 4096）

```bash
openshell sandbox create --name ocode-api --forward 4096 -- opencode
```

## 3. 連線與觀測

```bash
openshell sandbox list
openshell sandbox get ocode-dev
openshell sandbox connect ocode-dev
openshell logs ocode-dev --tail
```

常用觀測選項：

```bash
openshell logs ocode-dev --tail --source sandbox --level warn
openshell term
```

## 4. 檔案傳遞（非 bind mount）

> OpenShell 目前標準做法是 upload/download，不是 host bind mount。

```bash
# 上傳本機檔案到 sandbox
openshell sandbox upload ocode-dev ./src /sandbox/src

# 從 sandbox 下載結果回本機
openshell sandbox download ocode-dev /sandbox/output ./local-output
```

## 5. Port Forward 操作

```bash
openshell forward start 4096 ocode-api -d
openshell forward list
openshell forward stop 4096 ocode-api
```

## 6. 清理

```bash
openshell sandbox delete ocode-dev
openshell sandbox delete ocode-api
```

若 gateway 狀態異常可重建：

```bash
openshell gateway start --recreate
```

## 7. 常見失敗與快速判斷

- `connection refused`：通常是 Docker 未啟動或 gateway 尚未 healthy
- `sandbox create` 卡住：先看 `openshell status` 與 `openshell doctor logs --tail`
- 服務無法從本機打通：確認 `forward list` 有對應埠，且服務真的在 sandbox 內啟動
