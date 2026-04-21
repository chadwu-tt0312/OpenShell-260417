# Openshell-vm vs Docker comparison
_Exported on 2026/4/21 at 15:39:12 [GMT+8] from Cursor (3.2.0-pre.48.patch.0)_

---

**User**

openshell-vm vs Docker 有何差異? 為何會在 v0.0.26 版本中新增這一項功能 ?
請提供一份完整對比與說明文件

---

**Cursor**

我已收集足夠脈絡。以下是建立完整對比文件的計畫：

**TO-DO List**
- [x] 蒐集 openshell-vm 架構（libkrun / gvproxy / virtio-fs / vsock / state disk）
- [x] 確認 v0.0.26 引入脈絡（PR #611，+10,972 行，56 檔）
- [x] 比對既有 Docker gateway 架構與差異
- [ ] 輸出 `pass/docs/openshell-vm-vs-docker.md`（繁中、Mermaid、Top-down）

已完成文件建立。

## 產出位置

`pass/docs/openshell-vm-vs-docker.md`（291 行，含 Mermaid 架構圖 2 份、完整對比表 6 份）

## 文件結構（Top-down）

| 章節 | 重點 |
|---|---|
| **1. Overview** | Mermaid 比較 Docker 與 MicroVM 執行模型；一句話結論：Docker 共用 host kernel、MicroVM 帶獨立 guest kernel |
| **2. 為何 v0.0.26 新增** | 五個動機：安全（VM-level 隔離）、消除 Docker daemon SPOF、macOS 原生、單一 binary、state disk crash recovery |
| **3. 架構對比** | 19 項完整對比表（隔離邊界 / hypervisor / 網路 / port-forward / 資源 / 冷啟動等） |
| **4. 為何不用 Kata/Firecracker/gVisor** | libkrun 的四項獨特契合（雙平台 FFI / dlopen / virtio-fs / 自訂 kernel） |
| **5. 生產適用性** | 正面影響、限制風險、適用場景決策表 |
| **6. 安裝使用對照** | `install.sh` vs `install-vm.sh` |
| **7. 效能參考** | 引用 `pass/artifacts/vm-benchmark-*` 實測數據 |
| **8. 結論** | 三維度決策（隔離需求 / 平台 / 資源預算） |
| **9. 延伸閱讀** | PR #611 / README / benchmark / test script |

## 核心論點

1. `openshell-vm` **不是**取代 Docker 作為容器 runtime，而是**以 hypervisor 邊界取代容器邊界**的 gateway 部署模型
2. v0.0.26 引入 libkrun 的關鍵決定因素：**macOS HVF + Linux KVM 雙平台 FFI**，這是 Kata / Firecracker / gVisor 都無法同時滿足的
3. 適用場景清楚劃分：企業 K8s 多租戶 → 維持 Docker；單機高安全 / macOS 開發 / edge → 採 MicroVM

相關歷史脈絡可見 [openshell-vm 功能說明與測試 script](b51f8f0a-e0bd-47d6-bd25-f41a0e60f63c)（早前我們已建立 `pass/test-openshell-vm.sh`）。

---

**User**

為何不直接用 Kata Containers / Firecracker？ 中的 "需 Kubernetes runtime class 整合，部署複雜；目標為多租戶 K8s" 請詳細說明。

---

**Cursor**

你問得很準，這句話其實在講 **Kata 的定位與 OpenShell v0.0.26 要解的問題不同**。

## 先講結論

「不直接用 Kata Containers」不是因為 Kata 不好，而是因為：

- Kata 主要是 **Kubernetes 多租戶叢集**場景的 VM-based container runtime
- OpenShell v0.0.26 的 `openshell-vm` 主要目標是 **單機 gateway（dev/edge）快速落地**、減少外部依賴（尤其 Docker daemon）
- 若改用 Kata，會把部署重心從「一個可執行檔就能跑」變成「先整合整個 K8s runtime stack」

---

## 「需 Kubernetes runtime class 整合，部署複雜」是什麼意思？

Kata 在 K8s 不是直接 `binary run`，而是要走這條鏈：

`Kubernetes -> CRI (containerd/CRI-O) -> RuntimeClass -> kata runtime -> hypervisor`

你通常需要做這些事：

- 安裝並設定 `containerd` 或 `CRI-O`
- 安裝 `kata-runtime` 與對應 hypervisor（QEMU/Cloud Hypervisor/Firecracker 變體）
- 在節點配置 `RuntimeClass`（例如 `kata`）
- 調整 Pod Spec，指定 `runtimeClassName: kata`
- 驗證 CNI、storage、CSI、GPU plugin、監控 sidecar 在 Kata VM 內是否相容
- 處理節點異質性（不是每台 node 都支援 nested virt、KVM、SEV/TDX 等）

這些步驟在大型 K8s 叢集合理，但對「我要快速把 OpenShell gateway 跑起來」會變成很重的前置成本。

---

## 為什麼說 Kata 目標是「多租戶 K8s」？

Kata 的核心價值是：

- 在同一個 K8s 叢集中，讓不同租戶 Pod 有 **更強隔離（每 Pod/每 sandbox VM）**
- 保留 K8s 原生操作模式（Deployment、HPA、Service Mesh、Admission、Policy）
- 用 RuntimeClass 對部分 workload 套用更強隔離，不必全叢集改造

換句話說，Kata 是「**K8s 叢集內的強隔離 runtime 選項**」，不是「單一應用自帶 VM runtime」。

---

## 對 OpenShell v0.0.26 來說，Kata 會帶來哪些不匹配？

- **目標不匹配**：OpenShell 想要的是「單機可啟動的 MicroVM gateway」，不是「把 gateway 當 Pod 丟進既有 K8s」
- **依賴增加**：會重新引入大量平台依賴（CRI、RuntimeClass、節點設定），違反 `openshell-vm` 的單一 binary 設計方向
- **開發體驗下降**：本機 dev（尤其 macOS）要先建一套可用 K8s + Kata 鏈路，門檻比 `mise run vm` 高很多
- **可攜性問題**：不同環境的 container runtime、CNI、GPU、kernel feature 會造成更多矩陣測試成本

---

## 跟 Firecracker 的差異（補充）

Firecracker 很強，但偏向：

- AWS 生態最佳化（microVM for serverless）
- Linux-first；本機跨平台（特別 macOS 原生）整合成本高
- 需要你自己補齊較多「平台層 glue code」

而 OpenShell 當時選 `libkrun` 的關鍵是：**同時覆蓋 Linux KVM + macOS HVF，且可用 FFI 直接嵌入 Rust flow**。

---

如果你要，我可以再補一版「**Kata 方案在 OpenShell 的實作藍圖**」（含 RuntimeClass YAML、節點需求、風險矩陣、導入成本估算），讓你可以直接拿去做架構評審。

