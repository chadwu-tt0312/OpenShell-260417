# OpenShell 專案最新情況（2026-03-27，會話收尾版）

## Top-down 概述

- 專案主體仍是 `Rust workspace + Python 包裝層`，核心流程維持 `CLI -> Gateway -> Sandbox -> Router/Policy`。
- `pass/` 目前聚焦在「內網禁 TLS」POC，已形成從策略說明到 inference probe 驗收腳本的完整鏈路。
- Phase 1 的方向已收斂為 `HTTP-only` + `OpenAI-compatible (Ollama)`，安全聲明以「可證明 egress 收斂 + 可稽核」為主。

## 目前已完成項目（依 `pass/` 文件）

- `pass/poc-no-tls-internal-network.md`
  - 已定義禁 TLS 場景下的威脅模型、可證明邊界、Phase 1/2 策略。
  - 已明確採用 `api-key` 作為固定認證 header。
- `pass/phase1-inference-probe.sh`
  - 已提供 bash 版 inference probe 測試（預設 `mode=sandbox`，可不帶參數直接執行），覆蓋：
    - `POST /v1/chat/completions` 預期 200
    - `POST /v1/responses` 預期 403（chat-only）
  - 已記錄每個案例耗時與首次/二次執行時間差（`timing_summary.startup_comparison`）。
  - 會輸出 `pass/phase1-inference-probe-report.json`，可作為驗收證據。
- `pass/project-architecture-quickstart.md`
  - 已建立新人快速理解專案的架構總覽與閱讀路徑。

## 當前觀察與定位結論

- 連線面已打通：
  - `openshell provider create --name ollama-dev --type openai --config OPENAI_BASE_URL=http://192.168.31.180:11434/v1` 成功
  - `openshell inference set --provider ollama-dev --model llama3.2:latest` 成功
  - `POST /v1/chat/completions` 經 `inference.local` 可回 200
- 目前唯一未過項目：`POST /v1/responses` 預期 403，但實測回 200。
- 已定位根因：程式碼先前沒有實際讀取 `OPENSHELL_INFERENCE_CHAT_ONLY`，因此 chat-only 不會生效。
- 已完成修補：`crates/openshell-sandbox/src/l7/inference.rs`
  - `default_patterns()` 現在會依 `OPENSHELL_INFERENCE_CHAT_ONLY` 切換 chat-only 白名單
  - 已新增對應單元測試

## 建議下一步（Implementation TO-DO）

- [ ] 重新啟動或重建 gateway/runtime，並在啟動層注入 `OPENSHELL_INFERENCE_CHAT_ONLY=true`。
- [ ] 重跑 `openshell inference set --provider ollama-dev --model llama3.2:latest`（保險同步）。
- [ ] 執行 `bash pass/phase1-inference-probe.sh`（預設 sandbox 模式）。
- [ ] 驗收目標：`chat/completions=200` 且 `responses=403`。
- [ ] 產出最終驗收證據：`pass/phase1-inference-probe-report.json`（含 timing 指標）。
