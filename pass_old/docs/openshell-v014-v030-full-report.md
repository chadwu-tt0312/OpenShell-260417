# OpenShell v0.0.14 → v0.0.30 完整差異分析與生產落地評估

> 分析日期：2026-04-16
> 本地工作區：≈ v0.0.15（346 commits，HEAD = `f37b69b`）
> GitHub upstream：v0.0.30（429 commits，2026-04-15 發布）
> 來源：[NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)

---

## 目錄

1. [版本定位與差距](#1-版本定位與差距)
2. [逐版 Changelog 分析](#2-逐版-changelog-分析)
3. [重點專題：MicroVM Gateway (v0.0.26)](#3-重點專題microvm-gateway-v0026)
4. [安全機制深度分析](#4-安全機制深度分析)
5. [新增功能影響評估](#5-新增功能影響評估)
6. [生產環境落地分析（K8s + 萬人規模）](#6-生產環境落地分析k8s--萬人規模)
7. [安全元件抽離方案](#7-安全元件抽離方案)
8. [結論與建議](#8-結論與建議)

---

## 1. 版本定位與差距

### 1.1 本地工作區

本地 HEAD 為 `f37b69b feat(sandbox): auto-detect TLS and terminate unconditionally for credential injection (#544)`，此 commit 包含在 v0.0.15 release 中。Cargo workspace version 為 `0.0.0`（佔位，實際版號由 `git describe` + setuptools-scm 在建置時計算）。

### 1.2 Upstream

GitHub upstream 最新穩定版為 **v0.0.30**（2026-04-15），共 429 commits，24 個 release（含 2 個 pre-release：`dev` rolling 和 `vm-dev`）。

### 1.3 差距

跨越 **13 個穩定版 release**，約 **83 commits** 差距：

```
v0.0.15 → v0.0.16 → v0.0.19 → v0.0.20 → v0.0.21 → v0.0.22 →
v0.0.23 → v0.0.24 → v0.0.25 → v0.0.26 → v0.0.28 → v0.0.29 → v0.0.30
```

注意：v0.0.17、v0.0.18、v0.0.27 未發布（被跳過）。

---

## 2. 逐版 Changelog 分析

### v0.0.15（2026-03-24）— 安全強化批次 1

| PR | 類型 | 說明 |
|----|------|------|
| #548 | fix(security) | 安全強化批次 1（SEC-002 ~ SEC-010） |
| #544 | feat(sandbox) | 自動偵測 TLS 並無條件終止以注入 credential |
| #523 | fix(docker) | 預設啟用 dev-settings feature |
| #510 | fix(cli) | 刪除 sandbox 後清除 stale last-used 記錄 |

### v0.0.16（2026-03-25）— SSRF 強化

| PR | 類型 | 說明 |
|----|------|------|
| #598 | fix(sandbox) | 封鎖 unspecified addresses in SSRF guards |
| #571 | fix(sandbox,server) | 修正 chunk merge 重複 + OPA 變數碰撞 |
| #570 | fix(sandbox) | policy host 中的 literal IP 視為 implicit allowed_ips |
| #569 | fix(server) | 保留 redacted provider response 中的 credential key names |
| #572 | fix(ci) | 強化 CI image tool 安裝流程 |
| #547 | feat(tasks) | 新增 `cluster:gpu` task |

### v0.0.19（2026-03-31）— L7 擴展 + 效能

| PR | 類型 | 說明 |
|----|------|------|
| #666 | fix(proxy) | **L7 inspection 擴展至 forward proxy 路徑** |
| #671 | fix(l7) | **CWE-444 防護**：拒絕同時帶 CL 和 TE 的 inference 請求 |
| #677 | fix(sandbox) | per-path Landlock 錯誤處理（不再因單路徑失敗而放棄整個 ruleset） |
| #617 | feat(sandbox) | L7 query parameter matchers |
| #555 | perf(sandbox) | **Streaming SHA256 + spawn_blocking** 解決 identity 解析阻塞 |
| #672 | feat(inference) | 自訂 inference timeout |
| #687 | fix(sandbox) | per-SSH-channel PTY state tracking 修正 terminal resize |

### v0.0.20（2026-04-01）— CDI GPU + L7 credential 擴展

| PR | 類型 | 說明 |
|----|------|------|
| #495, #503 | feat(bootstrap,sandbox) | **CDI GPU injection** 取代舊版 Docker `--gpus` 路徑 |
| #708 | feat(sandbox) | **L7 credential injection 擴展**至 query params、Basic auth、URL paths |
| #715 | fix(sandbox) | 修正 `rewrite_forward_request` 中的 `Box::leak` memory leak |
| #700 | fix(bootstrap) | image push 透過 temp file 串流（防止 OOM） |
| #701 | fix(cluster) | 傳遞 resolv-conf 作為 kubelet arg + pin k3s image digest |

### v0.0.21（2026-04-02）— 安裝安全 + WebSocket

| PR | 類型 | 說明 |
|----|------|------|
| #724 | fix(install) | **安裝腳本 checksum 驗證強制化** + 驗證 redirect origin |
| #718 | fix(sandbox) | WebSocket 101 Switching Protocols frame relay |
| #714 | docs | 新增安全最佳實踐文件 |
| #713 | fix(cli) | CliProviderType enum 新增 Copilot variant |
| #710 | fix(sandbox/bootstrap) | GPU Landlock baseline paths 修正 |

### v0.0.22（2026-04-03）— 外部審計修復（最關鍵版本）

| PR | 類型 | 說明 |
|----|------|------|
| **#744** | **fix(security)** | **修復 9 項外部審計發現（OS-15 ~ OS-23）** |
| **#740** | **fix(sandbox)** | **seccomp 封鎖危險 syscalls** |
| **#736** | **fix(security)** | **容器依賴更新修復 10 個 CVE** |
| **#737** | **fix(security)** | **OSS 依賴更新修復 3 個高嚴重性 CVE** |
| #739, #488 | fix(bootstrap,server) | **Gateway 狀態跨重啟持久化** |
| #742 | test(e2e) | 以 Rust 替換 flaky Python live policy update 測試 |
| #694 | fix(cli) | sandbox upload 改為覆寫而非建立目錄 |

### v0.0.23（2026-04-06）— sandbox exec

| PR | 類型 | 說明 |
|----|------|------|
| #752 | feat(cli) | `sandbox exec` 子命令（TTY 支援）|

### v0.0.24（2026-04-07）— Proto 清理

| PR | 類型 | 說明 |
|----|------|------|
| #772 | chore(proto) | 移除未使用的 java_package 宣告 |

### v0.0.25（2026-04-08）— OCSF 結構化日誌

| PR | 類型 | 說明 |
|----|------|------|
| **#720** | **feat(sandbox)** | **OCSF v1.7.0 結構化日誌整合至 sandbox** |

### v0.0.26（2026-04-09）— MicroVM Gateway

| PR | 類型 | 說明 |
|----|------|------|
| **#611** | **feat(vm)** | **openshell-vm crate：libkrun MicroVM gateway**（+10,972 行，56 檔案） |
| #780 | docs(fern) | 文件遷移至 Fern 平台 |
| #777 | refactor(server) | grpc.rs 拆分為子模組 |
| #773 | ci(gpu) | GPU 測試 workflow 獨立化 |

### v0.0.28（2026-04-13）— z3 Prover

| PR | 類型 | 說明 |
|----|------|------|
| **#800** | **fix(docker)** | **openshell-prover 加入 Dockerfile + 提供 z3** |
| #806 | fix(vm) | 強化 build-libkrun.sh（x86_64 + PATH shadowing） |
| #805 | fix(cli) | dev wrapper 使用本地 z3 |
| #623 | test(sandbox) | 拆分 drop_privileges 測試以解除 non-root CI 阻塞 |

### v0.0.29（2026-04-14）— Landlock + seccomp 強化

| PR | 類型 | 說明 |
|----|------|------|
| **#810** | **fix(sandbox)** | **Two-phase Landlock** 修正權限排序 + enforcement 測試 |
| **#819** | **fix(sandbox)** | **seccomp denylist 強化 + SSRF + inference policy enforcement** |
| #815 | fix(sandbox) | always-blocked IPs 載入時驗證 + 豐富 denial logs + 過濾不可修復提案 |
| #774 | fix(sandbox) | **Symlink binary paths 解析** in network policy matching |
| #809 | fix(sandbox) | proxy 403/502 回應加入 JSON body + HTTP log URL 含 port |
| #824 | fix(cli) | 支援 plaintext gateway 註冊 |

### v0.0.30（2026-04-15）— Deny rules + ComputeDriver

| PR | 類型 | 說明 |
|----|------|------|
| **#822** | **feat(policy)** | **Network policy 新增 deny rules** |
| **#817, #839** | **refactor(server)** | **抽出 Kubernetes compute driver** + 以 in-process RPC 使用 |
| #821 | fix(sandbox) | **禁用 child core dumps** |
| #827 | fix(sandbox) | 保留 read_write 路徑的既有所有權 |
| #842 | fix(sandbox) | format_sse_error 跳脫控制字元 |
| #834 | fix(inference) | 防止大型 streaming response 靜默截斷 |

---

## 3. 重點專題：MicroVM Gateway (v0.0.26)

### 3.1 背景

v0.0.26 透過 PR [#611](https://github.com/NVIDIA/OpenShell/pull/611) 引入 `crates/openshell-vm/` crate（+10,972 / -61 行，56 檔案，26 commits），這是 v0.0.14→v0.0.30 之間**最重大的架構變革**。

它提供一個基於 **libkrun** 的微虛擬機 runtime，作為原有 Docker/K3s gateway 的替代部署方式。

### 3.2 libkrun 技術基礎

libkrun 是一個輕量級虛擬化函式庫：

- **macOS ARM64**：使用 Apple Hypervisor.framework（不需 root，需 codesign `com.apple.security.hypervisor` entitlement）
- **Linux x86_64/ARM64**：使用 KVM（需 `/dev/kvm` 存取權，通常需 `kvm` group）
- **virtio-fs**：host 目錄直接映射為 VM 根檔案系統（無需 disk image 轉換）
- **virtio-net**：透過 gvproxy 提供真實的 `eth0` 網路介面（guest IP 固定 `192.168.127.2`）
- **vsock**：host-guest 通訊通道，用於 exec agent 和 port forwarding

Runtime 元件以三個動態函式庫形式提供：

| 元件 | 用途 |
|------|------|
| `libkrunfw.so` / `.dylib` | 包含編譯好的 Linux kernel + virtio 裝置模型 |
| `libkrun.so` / `.dylib` | VM 生命週期管理 FFI API |
| `gvproxy` | 網路代理（virtio-net backend + port forwarding HTTP API） |

### 3.3 架構對比

```
Docker Gateway（原有架構）:
  Host → Docker Daemon → Docker Container → k3s (shared kernel) → Gateway → Sandbox Pods

MicroVM Gateway（v0.0.26+）:
  Host → openshell-vm binary → libkrun (KVM/HVF) → Guest Linux Kernel → k3s (in guest) → Gateway → Sandbox Pods
```

| 面向 | Docker Gateway | MicroVM Gateway |
|------|----------------|-----------------|
| **隔離邊界** | Container（共用 host kernel） | VM（獨立 guest kernel） |
| **Hypervisor** | 無 | KVM (Linux) / Hypervisor.framework (macOS) |
| **核心攻擊面** | Host kernel syscall 介面完全暴露 | Host kernel 僅透過 virtio 介面暴露（攻擊面小數個量級） |
| **網路** | Docker bridge / host network | gvproxy + virtio-net（`192.168.127.2`） |
| **檔案系統** | overlay2 / bind mount | virtio-fs（rootfs）+ 32 GiB sparse raw block image（state） |
| **啟動方式** | `docker run` | `fork()` + `krun_start_enter()` |
| **依賴** | Docker daemon | libkrun + libkrunfw + gvproxy（嵌入 binary，自解壓） |
| **平台支援** | Linux, macOS (Docker Desktop) | Linux (KVM), macOS ARM64 (HVF) |
| **狀態持久化** | Docker volume | Sparse raw block image (`/dev/vda`) |
| **Port forwarding** | Docker `-p` flag | gvproxy HTTP API expose |

### 3.4 技術實作細節

核心原始碼位於 `crates/openshell-vm/src/lib.rs`（2086 行），主要結構：

**VmConfig** — 配置結構體：
- `vcpus`: 預設 4
- `mem_mib`: 預設 8192 (8 GiB)
- `rootfs`: virtio-fs 根目錄路徑
- `port_map`: `["30051:30051"]` 映射 gateway gRPC port
- `net`: `NetBackend::Gvproxy` 為預設
- `state_disk`: 32 GiB sparse raw block image

**launch() 啟動流程**（13 步）：

1. 驗證 rootfs 存在（支援自嵌入 tarball 自動解壓）
2. Linux 上預檢 `/dev/kvm` 存取權（libkrun 無法處理此錯誤會 panic）
3. 取得 rootfs `flock` 獨佔鎖（OS 級，SIGKILL 也會自動釋放）
4. 偵測並恢復損壞的 kine (SQLite) 資料庫
5. 設定 `LD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH`
6. 透過 `libloading` FFI 動態載入 libkrun（非 build-time linkage）
7. 啟動 gvproxy（Linux: QEMU mode `SOCK_STREAM`；macOS: vfkit mode `SOCK_DGRAM`）
8. 配置 virtio-net + MAC 地址 (`5a:94:ef:e4:0c:ee`) + virtio 特性旗標
9. 設定 vsock port（exec agent 用 `VM_EXEC_VSOCK_PORT`）
10. `fork()` — child 呼叫 `krun_start_enter()`（永不回傳），parent 監控
11. 透過 gvproxy HTTP API 設定 port forwarding（exponential backoff 重試）
12. Bootstrap mTLS PKI：warm boot 複用已有憑證 / cold boot 從 VM exec agent 取回
13. gRPC health check 通過後印出 "Ready"

**網路後端實作**：

```
macOS: openshell-vm → gvproxy (-listen-vfkit unixgram://) → libkrun (krun_add_net_unixgram, SOCK_DGRAM + vfkit flag)
Linux: openshell-vm → gvproxy (-listen-qemu unix://)     → libkrun (krun_add_net_unixstream, SOCK_STREAM)
```

gvproxy 內部運行一個使用者態網路棧（gVisor netstack），guest 透過 DHCP 取得固定 IP `192.168.127.2`，host 透過 gvproxy HTTP API 設定 TCP port expose。

**State Disk**：
- 32 GiB sparse raw block image（`{rootfs_key}-state.raw`）
- Guest 可見為 `/dev/vda`（`block_id: "openshell-state"`）
- 用於 k3s 叢集狀態：kine DB、containerd images、Helm releases
- macOS 使用 `KRUN_SYNC_RELAXED`（HVF 效能考量），Linux 使用 `KRUN_SYNC_FULL`

**安全措施**：
- `secure_socket_base()` — 驗證 socket 目錄非 symlink 且 uid 一致（防止 symlink 攻擊）
- `is_process_named()` — kill stale gvproxy 前驗證 PID 對應程序名（防止 PID reuse 誤殺）
- `flock` 獨佔鎖防止並發 VM 啟動或 rootfs rebuild 衝突
- Runtime provenance logging（libkrunfw SHA256、kernel version、build timestamp）
- Cert drift detection — warm boot 時比對 host/guest CA cert，發現差異自動 re-sync

### 3.5 安裝與部署

```bash
# MicroVM variant 安裝
curl -fsSL https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install-vm.sh | sh

# 預建產物（self-extracting binary，嵌入 rootfs + runtime）
# Linux ARM64:  openshell-vm-aarch64-unknown-linux-gnu.tar.gz
# Linux x86_64: openshell-vm-x86_64-unknown-linux-gnu.tar.gz
# macOS ARM64:  openshell-vm-aarch64-apple-darwin.tar.gz

# Runtime 元件（另行發布）
# vm-runtime-linux-aarch64.tar.zst
# vm-runtime-linux-x86_64.tar.zst
# vm-runtime-darwin-aarch64.tar.zst
```

### 3.6 生產環境意義

**正面影響**：
- **VM-level 隔離** — 獨立 guest kernel，攻擊者需先 VM escape 才能觸及 host（比 container escape 難度高數個量級）
- **消除 Docker 依賴** — 移除 Docker daemon 作為 SPOF 和額外攻擊面
- **macOS 原生** — 開發者可在 Mac 上直接跑 gateway（不需 Docker Desktop license）
- **單一 binary** — runtime 嵌入 binary 自解壓，部署極簡化
- **Crash recovery** — state disk + kine DB corruption 自動偵測恢復

**限制與風險**：
- **Pre-release 狀態** — GitHub 標記為 `vm-dev`，尚未進入穩定 release 線
- **KVM 依賴** — Cloud VM nested virtualization 效能問題；部分雲環境不支援
- **資源開銷** — 預設 4 vCPU + 8 GiB RAM，遠高於 Docker container
- **不整合現有 K8s** — MicroVM 內部自帶 k3s，與現有生產 K8s cluster 為平行佈建
- **Single-instance** — 無 HA、無 multi-node 支援
- **gvproxy 可靠性** — gvproxy orphan cleanup 依賴 PID file + port scan fallback，非 100% 可靠

**結論**：MicroVM gateway 適用於開發環境和高安全單機場景，不適合直接用於萬人規模 K8s 生產環境。但其 VM-level 隔離理念值得在企業架構中參考（例如以 Kata Containers 或 Firecracker 實現類似邊界）。

---

## 4. 安全機制深度分析

### 4.1 四層防禦體系

OpenShell 的 sandbox 安全機制分為四個獨立層次，每一層在前一層失效時仍能提供保護：

```
Layer 1: Filesystem (Landlock LSM)
  ├─ read_only / read_write 路徑清單
  ├─ Landlock ABI V2，核心級別攔截
  └─ sandbox 建立時鎖定，不可熱更新

Layer 2: Process (seccomp-BPF)
  ├─ 封鎖 AF_PACKET / AF_BLUETOOTH / AF_VSOCK
  ├─ Proxy 模式：允許 AF_INET 但強制走 proxy
  ├─ 禁止 core dump (v0.0.30+)
  └─ prctl(PR_SET_NO_NEW_PRIVS)

Layer 3: Network (namespace + proxy + OPA)
  ├─ veth pair 隔離：10.200.0.1/24
  ├─ HTTP CONNECT proxy 攔截所有出站
  ├─ OPA/Rego per-binary policy 評估
  ├─ SSRF 防護：封鎖私有 IP + always-blocked IPs
  ├─ L7 inspection：REST API 層級控制
  ├─ Binary identity：SHA256 TOFU
  └─ deny rules (v0.0.30+)

Layer 4: Inference (routing + credential isolation)
  ├─ inference.local 攔截（繞過 OPA，專用路徑）
  ├─ Credential 隔離：sandbox 不見真實 API key
  └─ Per-protocol routing (OpenAI / Anthropic / NVIDIA)
```

### 4.2 v0.0.14→v0.0.30 安全演進時間軸

```
v0.0.15  SEC-002~SEC-010 安全強化批次 1
    │    自動 TLS 偵測 + credential injection
    ▼
v0.0.16  SSRF: 封鎖 unspecified addresses
    │    OPA 變數碰撞修正
    ▼
v0.0.19  CWE-444 HTTP request smuggling 防護
    │    L7 擴展至 forward proxy
    │    per-path Landlock 錯誤處理
    ▼
v0.0.20  L7 credential injection 擴展
    │    Memory leak 修復
    ▼
v0.0.21  安裝腳本 checksum 強制驗證
    │    WebSocket relay
    ▼
v0.0.22  ★ 外部審計修復 OS-15~OS-23（9 項）
    │    ★ seccomp 封鎖危險 syscalls
    │    ★ 10 CVE + 3 高嚴重 CVE 修補
    ▼
v0.0.28  z3 形式驗證引擎 (openshell-prover)
    ▼
v0.0.29  ★ Two-phase Landlock（權限排序修正）
    │    ★ seccomp denylist 強化
    │    ★ SSRF + inference policy 強化
    │    symlink binary path 解析
    │    always-blocked IPs 載入驗證
    ▼
v0.0.30  ★ Network policy deny rules
         禁用 child core dumps
         read_write 路徑所有權保留
```

標示 ★ 者為影響隔離有效性的關鍵修復。

### 4.3 關鍵漏洞修復細節

**外部審計（v0.0.22, PR #744）**：修復編號 OS-15 ~ OS-23，共 9 項安全發現。這是由外部安全公司進行的專業審計，修復涵蓋 sandbox 隔離、proxy 實作、gateway 認證等面向。

**Two-phase Landlock（v0.0.29, PR #810）**：原有實作在 `drop_privileges` 前未正確分離 supervisor 和 child 的 Landlock ruleset application，導致權限排序錯誤。修正後 supervisor 先 apply 自身 ruleset，再 fork child 並 apply 受限 ruleset。附帶 enforcement 測試確保正確性。

**seccomp 強化（v0.0.22 #740 + v0.0.29 #819）**：
- v0.0.22：封鎖先前遺漏的危險 syscalls
- v0.0.29：擴大 denylist 範圍，加入 SSRF 防護整合和 inference policy enforcement

**deny rules（v0.0.30, PR #822）**：Network policy 從純「允許清單」模式擴展為「允許 + 拒絕清單」。允許撰寫 `deny` 規則明確封鎖特定目標，即使其他規則可能允許。

### 4.4 實作與文件差異

在程式碼分析中發現一處與文件不一致的地方：

- `architecture/security-policy.md` 稱「不論模式都封鎖 AF_NETLINK」
- `crates/openshell-sandbox/src/sandbox/linux/seccomp.rs` 實際上在 Proxy 模式（`allow_inet == true`）時**未封鎖** `AF_NETLINK`，僅在 Block 模式（`allow_inet == false`）時才封鎖

報告以原始碼為準。

---

## 5. 新增功能影響評估

### 5.1 OCSF 結構化日誌（v0.0.25）

`openshell-ocsf` crate 實作 OCSF v1.7.0 標準，定義 8 個 event class：

| Event Class | ID | 用途 |
|------------|-----|------|
| Network Activity | 4001 | proxy 連線事件 |
| HTTP Activity | 4002 | L7 HTTP 請求/回應 |
| SSH Activity | 4007 | SSH 連線與認證 |
| Process Activity | 1007 | 行程啟動/終止 |
| Detection Finding | 2004 | 政策違規偵測 |
| Application Lifecycle | 6002 | sandbox 生命週期 |
| Device Config State Change | 5019 | 設定變更 |
| Base Event | 0 | 基礎事件 |

提供 `OcsfShorthandLayer`、`OcsfJsonlLayer` tracing layer、`ocsf_emit!` macro、JSONL 格式化輸出、schema validation。

**影響**：為企業合規稽核提供結構化事件基礎。目前 crate 已存在但尚未完整整合至所有 sandbox 執行路徑。

### 5.2 Gateway 狀態持久化（v0.0.22）

解決先前 gateway 重啟後 sandbox 記錄遺失的問題。sandbox state 現在持久化至資料庫（SQLite/Postgres），gateway 重啟後可恢復。

**影響**：生產環境基本需求，此前缺失使得任何 gateway 維護操作都會破壞 sandbox。

### 5.3 ComputeDriver 抽象（v0.0.30）

Gateway 內部的 Kubernetes 交互邏輯抽象為 `ComputeDriver` trait，以 in-process RPC surface 方式使用。

**影響**：為未來支援非 K8s 後端（如 MicroVM、remote container runtime、serverless）鋪路。降低了架構耦合度。

### 5.4 z3 形式驗證（v0.0.28）

`openshell-prover` crate 引入 z3 SAT solver，用於政策的形式驗證。

**影響**：可在 apply 前驗證政策無矛盾、無意外的開放路徑。對大規模部署中複雜政策的正確性保證至關重要。

---

## 6. 生產環境落地分析（K8s + 萬人規模）

### 6.1 能否直接使用？

**結論：不能。**

| 面向 | OpenShell 現狀 | 萬人生產需求 | 差距 |
|------|---------------|-------------|------|
| **定位** | Alpha, single-player mode | 多租戶生產平台 | 根本性差距 |
| **擴展** | Single-node (K3s in Docker) | HA + 水平擴展 | 無法水平擴展 |
| **多租戶** | 無 RBAC / namespace 隔離 | 嚴格租戶邊界 | 完全缺失 |
| **資料庫** | SQLite（預設）| PostgreSQL cluster | SQLite 無法併發 |
| **認證** | mTLS + edge token | OIDC / LDAP / SAML | 需要整合 |
| **稽核** | OCSF crate 存在但未完整接入 | 完整 audit trail | 需補完 |
| **配額** | 無 resource quota | Per-team / per-user quota | 完全缺失 |
| **監控** | 基礎 tracing + TUI | Prometheus / Grafana / alerting | 需要接入 |
| **Admission** | 無 Webhook | Policy admission control | 完全缺失 |

### 6.2 安全機制廠內覆現

OpenShell 的安全機制在企業環境中可以透過以下方式落地：

#### 6.2.1 Kernel 需求

| 機制 | 最低 kernel | 建議 kernel | 需要的 config |
|------|-----------|------------|--------------|
| Landlock | 5.13 (ABI V1) | 6.1+ (ABI V2) | `CONFIG_SECURITY_LANDLOCK` |
| seccomp-BPF | 3.17 | 5.x+ | `CONFIG_SECCOMP_FILTER` |
| Network namespace | 2.6.24 | 5.x+ | `CONFIG_NET_NS` |

#### 6.2.2 K8s Pod SecurityContext

Sandbox supervisor 需要以下能力：

```yaml
securityContext:
  capabilities:
    add:
      - SYS_ADMIN    # Landlock, mount
      - NET_ADMIN     # Network namespace, iptables
      - SYS_PTRACE    # /proc 讀取（identity resolution）
  seccompProfile:
    type: Unconfined  # Supervisor 自行管理 seccomp for child
```

Child（agent）process 則由 supervisor 施加限制，不需額外 K8s 層級設定。

#### 6.2.3 Gateway 部署改造

```
現有: openshell gateway start → Docker container → 內嵌 K3s → Gateway pod + Sandbox pods
生產: 直接部署至企業 K8s → Gateway Deployment/StatefulSet + Sandbox pods (同 cluster 或 dedicated node pool)
```

需要：
- 將 `openshell-server` 打包為獨立 container image，部署為 K8s Deployment
- 替換 SQLite 為 PostgreSQL
- 改寫 sandbox lifecycle 直接操作企業 K8s API（v0.0.30 的 ComputeDriver 抽象為此鋪路）
- 整合企業 PKI / cert-manager 替代自帶 mTLS

### 6.3 安全機制運作方式

企業落地時，OpenShell 安全機制的運作流程：

```
1. 管理員定義 YAML policy（filesystem + network + process 規則）
2. Gateway 儲存 policy 並關聯至 sandbox
3. Sandbox supervisor 啟動時透過 gRPC 取得 policy
4. Supervisor 施加 Landlock (filesystem) + seccomp (process) + netns (network)
5. Supervisor fork child（agent process）以受限權限執行
6. 所有出站流量經 HTTP CONNECT proxy → OPA 評估 → allow/deny
7. L7 inspection 層對特定 endpoint 做 HTTP 層級控制
8. 所有事件以 OCSF 格式記錄
```

---

## 7. 安全元件抽離方案

### 7.1 元件耦合度分析

| 元件 | 原始碼位置 | 抽離難度 | 外部依賴 | 可獨立使用 |
|------|-----------|---------|---------|-----------|
| **OPA/Rego engine** | `openshell-sandbox/src/opa.rs` + `data/sandbox-policy.rego` | 低 | `regorus` crate（純 Rust） | 是 — 嵌入任何 Rust 程式做 policy 決策 |
| **Landlock wrapper** | `openshell-sandbox/src/sandbox/linux/landlock.rs` | 低 | `landlock` crate + Linux kernel ≥ 5.13 | 是 — 任何需 FS 隔離的程式 |
| **seccomp filter** | `openshell-sandbox/src/sandbox/linux/seccomp.rs` | 低 | `seccomp-sys` crate | 是 — 任何需 syscall 過濾的程式 |
| **Network namespace** | `openshell-sandbox/src/sandbox/linux/netns.rs` | 中 | `ip` 命令 + `NET_ADMIN` cap | 半獨立 — 需配合 proxy 才有意義 |
| **Policy YAML schema** | `openshell-policy/src/lib.rs` | 低 | `openshell-core` proto types | 可 fork 移除 proto 依賴 |
| **HTTP CONNECT proxy** | `openshell-sandbox/src/proxy.rs` + `l7/` | 高 | 與 OPA, identity, inference, gRPC 緊密耦合 | 需大量重構 |
| **OCSF event model** | `openshell-ocsf/src/` | 低 | 獨立 crate，無外部依賴 | 是 — 直接作為 audit logging 函式庫 |
| **Binary identity/TOFU** | `openshell-sandbox/src/identity.rs` | 中 | `/proc` filesystem | 可在任何 Linux container 中重用 |
| **Bypass monitor** | `openshell-sandbox/src/bypass_monitor.rs` | 中 | `/dev/kmsg` + iptables | 可在有 `NET_ADMIN` 的環境重用 |

### 7.2 推薦抽離策略

**Phase 1 — 直接重用（低風險，1-2 週）**：

1. **regorus OPA engine** — 直接引入 `regorus` crate，移植 `sandbox-policy.rego` 規則，將 policy data 從 protobuf 改為自訂 JSON schema
2. **Landlock wrapper** — 複製 `landlock.rs`（~200 行），改為接受自訂 config struct 而非 OpenShell proto
3. **seccomp filter** — 複製 `seccomp.rs`（~150 行），依需求調整 denylist
4. **OCSF event model** — 直接依賴 `openshell-ocsf` crate 或 fork 使用

**Phase 2 — 適配整合（中風險，2-4 週）**：

5. **Network namespace** — 移植 `netns.rs`，改寫為配合自建 proxy 的 veth pair 設定
6. **Policy YAML schema** — Fork `openshell-policy`，移除 proto 依賴，改為純 serde 序列化
7. **Binary identity/TOFU** — 移植 `identity.rs` + `procfs.rs`，配合自建 proxy 的 process resolution

**Phase 3 — 重建（高風險，4-8 週）**：

8. **HTTP proxy + L7** — 以 OpenShell 的 `proxy.rs` 為參考架構，使用企業 HTTP proxy 框架（如 `pingora`、`hyper`）重建，整合 Phase 1 的 OPA engine
9. **Gateway lifecycle** — 在企業 K8s 上實作 sandbox CRD + operator
10. **Multi-tenant RBAC** — 整合企業 IAM，加入 namespace isolation + resource quotas

### 7.3 最小可行安全棧

如果只需 policy + process + filesystem 三層安全機制（不含完整 OpenShell runtime），最小可行棧為：

```rust
// 1. 載入政策
let policy = load_yaml_policy("sandbox-policy.yaml")?;

// 2. 建立 OPA 引擎
let opa = regorus::Engine::new();
opa.add_policy("sandbox.rego", REGO_RULES)?;
opa.add_data_json(policy_to_json(&policy))?;

// 3. Filesystem 隔離
apply_landlock(&policy.filesystem)?;  // ~200 行

// 4. Process 限制
apply_seccomp(&policy.process)?;      // ~150 行

// 5. Network 隔離（可選）
setup_network_namespace()?;            // ~300 行
start_proxy_with_opa(opa)?;           // 需自建或移植

// 6. Fork 受限 child
drop_privileges()?;
exec_child(command)?;
```

總計核心安全邏輯約 **650-800 行 Rust 程式碼**（不含 proxy），可在 1-2 週內移植完成。

---

## 8. 結論與建議

### 8.1 升級建議

**必須升級至 v0.0.30**。關鍵原因：
- v0.0.22 的外部審計修復（9 項安全發現）和 CVE 修補
- v0.0.29 的 Two-phase Landlock 修正（隔離失效風險）
- v0.0.30 的 deny rules（企業政策需求）

### 8.2 生產落地建議

1. **不建議直接部署 OpenShell 於萬人規模生產環境** — 產品定位為 alpha/single-player
2. **建議抽離安全元件**，分三階段整合至自建平台
3. **參考但不直接採用 MicroVM 架構** — 如需 VM-level 隔離，建議使用成熟方案（Kata Containers / Firecracker）
4. **優先實作 Phase 1 元件**（OPA + Landlock + seccomp + OCSF），這四個元件低耦合、高價值
5. **關注 ComputeDriver 抽象的演進** — v0.0.30 的 trait 抽象為未來插件化後端鋪路，可能在後續版本提供更好的企業整合點

### 8.3 風險矩陣

| 風險 | 機率 | 影響 | 緩解 |
|------|------|------|------|
| 停留在 v0.0.15 的安全漏洞被利用 | 高 | 嚴重 | 立即升級或 backport 安全修復 |
| MicroVM 引入新的攻擊面 | 低 | 中 | 不在生產使用 MicroVM variant |
| 抽離元件與上游版本 diverge | 中 | 中 | 建立自動化 upstream tracking |
| OpenShell 專案方向改變 | 低 | 低 | 已抽離的元件獨立演進 |

---

*簡潔版見 [openshell-v014-v030-summary.md](./openshell-v014-v030-summary.md)*
