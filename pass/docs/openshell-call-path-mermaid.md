# OpenShell 呼叫路徑 Mermaid 圖（Python 工程師版）

> 目標：用「你會的 Python 心智模型」理解 OpenShell 在 Rust/Cargo workspace 中，從 CLI 到 Gateway/Sandbox/Policy/VM 的主要呼叫路徑。

## Top-down 總覽

OpenShell 的主路徑可以先拆成三層：

1. **入口層（CLI）**：你在終端輸入 `openshell ...`，由 `openshell-cli` 接命令與參數。  
2. **控制層（Gateway）**：`openshell-server` 負責控制面 API、狀態協調與生命週期管理。  
3. **執行與防護層（Sandbox + Policy + Router）**：`openshell-sandbox` 執行工作負載，`openshell-policy` 做限制，`openshell-router` 處理 inference routing。  

新版另有 **VM 執行模式**：透過 `openshell-vm` + `libkrun`，把 gateway 控制面放到 microVM 裡執行（更強隔離邊界）。

## 呼叫路徑（控制流）

```mermaid
flowchart TD
    U[User / Agent] --> C[openshell-cli]
    C --> CORE[openshell-core<br/>shared config/types/errors]
    C --> BOOT[openshell-bootstrap<br/>gateway bootstrap/deploy]
    C --> S[openshell-server<br/>gateway control plane]
    S --> SB[openshell-sandbox<br/>sandbox lifecycle]
    S --> P[openshell-policy<br/>fs/network/process/inference policy]
    S --> R[openshell-router<br/>privacy-aware inference routing]
    C --> TUI[openshell-tui<br/>terminal dashboard]
    S --> OCSF[openshell-ocsf<br/>security event format/bridge]

    subgraph VM_Mode[VM-backed Gateway Mode]
        VM[openshell-vm] --> KRUN[libkrun microVM runtime]
        KRUN --> K3S[k3s inside guest]
        K3S --> S
    end
```

## 呼叫路徑（資料流 / 請求流）

```mermaid
sequenceDiagram
    participant User as User/Agent
    participant CLI as openshell-cli
    participant GW as openshell-server
    participant SB as openshell-sandbox
    participant PO as openshell-policy
    participant RT as openshell-router
    participant Ext as External API/Model

    User->>CLI: openshell sandbox create / connect / policy set
    CLI->>GW: gRPC/HTTP control request
    GW->>SB: create/start sandbox runtime
    GW->>PO: load/apply policy
    User->>SB: agent runs command / app code
    SB->>PO: egress + process + fs checks
    alt inference.local or model route
        PO->>RT: forward allowed inference request
        RT->>Ext: call provider/model backend
    else normal outbound API
        SB->>Ext: call external API if policy allows
    end
    Ext-->>SB: response
    SB-->>User: command/result/log stream
```

## Rust/Cargo 對 Python 對照（快速版）

- `crate`：類似一個 Python package。  
- `Cargo.toml`：類似 `pyproject.toml` + build/test/dependency 設定。  
- `Cargo workspace`：類似 monorepo 多 package 管理（共享依賴與規範）。  
- `openshell-cli`：類似 Python 的 `typer/click` 入口程式，但用 Rust 實作。  
- `openshell-core`：類似共用 `common/` package（型別、錯誤、設定）。  

## TODO（你接下來可以怎麼讀）

- [ ] 先從 `crates/openshell-cli` 看 command parsing 與入口流程。  
- [ ] 再看 `crates/openshell-server` 理解控制面責任邊界。  
- [ ] 接著看 `crates/openshell-sandbox` + `crates/openshell-policy` 對應執行限制。  
- [ ] 最後看 `crates/openshell-vm`，理解 microVM 模式與 `libkrun` 的整合點。  

