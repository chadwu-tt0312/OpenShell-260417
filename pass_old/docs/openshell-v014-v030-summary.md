# OpenShell v0.0.14 → v0.0.30 差異摘要與生產落地評估

> 分析日期：2026-04-16 | 本地工作區：≈ v0.0.15 (346 commits) | Upstream：v0.0.30 (429 commits)

---

## 版本差距

本地工作區落後 upstream **13 個 release**（v0.0.15 ~ v0.0.30），約 83 commits。其中 v0.0.17、v0.0.18、v0.0.27 被跳過，未發布。

## 關鍵變更一覽

| 類別 | 版本 | 摘要 |
|------|------|------|
| **安全** | v0.0.22 | 外部審計修復 OS-15~OS-23（9 項安全發現）、13 CVE 修補、seccomp 強化 |
| **安全** | v0.0.29 | Two-phase Landlock 修正權限排序、seccomp denylist 強化、SSRF + inference policy 強化 |
| **安全** | v0.0.30 | Network policy 新增 deny rules、禁用 child core dumps |
| **安全** | v0.0.19 | CWE-444 HTTP request smuggling 防護、L7 擴展至 forward proxy |
| **架構** | v0.0.26 | **openshell-vm (MicroVM)**：libkrun 微虛擬機 gateway，VM-level 隔離取代 Docker container |
| **架構** | v0.0.30 | ComputeDriver trait 抽象，解耦 Kubernetes 依賴 |
| **架構** | v0.0.28 | openshell-prover：z3 形式驗證引擎 |
| **功能** | v0.0.25 | OCSF v1.7.0 結構化稽核日誌整合 |
| **功能** | v0.0.22 | Gateway 狀態跨重啟持久化 |
| **功能** | v0.0.20 | CDI 標準 GPU injection |

## 安全影響結論

**必須升級。** v0.0.22 的外部審計修復與 v0.0.29 的 Landlock/seccomp 強化解決了實際可被利用的隔離缺陷。停留在 v0.0.15 意味著：

- Landlock 權限排序錯誤可能導致檔案系統隔離失效
- seccomp 缺少對危險 syscall 的封鎖
- 13 個已知 CVE 未修補
- SSRF 防護存在繞過路徑

## 生產落地結論（K8s + 萬人規模）

**不能直接使用。** OpenShell 官方聲明為 "Alpha software — single-player mode"。

| 面向 | 現狀 | 生產需求 |
|------|------|---------|
| 擴展性 | Single-node (K3s in Docker) | HA + 水平擴展 |
| 多租戶 | 無 RBAC / namespace 隔離 | 萬人級別租戶隔離 |
| 資料庫 | SQLite（無併發） | PostgreSQL cluster |
| 稽核 | OCSF crate 尚未完整接入 | 完整 audit trail |

**推薦策略**：抽離安全元件（Landlock、seccomp、OPA/Rego、OCSF）整合至自建平台。低耦合元件可直接重用，HTTP proxy + L7 層需重寫。

---

*完整分析見 [openshell-v014-v030-full-report.md](./openshell-v014-v030-full-report.md)*
