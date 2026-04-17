# Per-user Workspace Mount

## 目標

在同一份設定下，允許每次 sandbox 建立或使用時，將容器內 `/workspace/data` 指向不同使用者 workspace 目錄。

## 環境變數

- `OPEN_SHELL_WORKSPACE_BASE=./pass`
- `OPEN_SHELL_WORKSPACE_USER=user01`
- `OPEN_SHELL_WORKSPACE_USER_DATAPATH=data_user01`

## 行為

1. `openshell-bootstrap` 會在建立 cluster container 時，額外加入 Docker bind mount：
   - `<canonical(OPEN_SHELL_WORKSPACE_BASE)>:/opt/openshell/workspaces`
2. `openshell-server` 在建立 sandbox pod 時，會解析 workspace hostPath：
   - 優先 `${OPEN_SHELL_WORKSPACE_BASE}/${OPEN_SHELL_WORKSPACE_USER_DATAPATH}`
   - 否則 `${OPEN_SHELL_WORKSPACE_BASE}/${OPEN_SHELL_WORKSPACE_USER}_data`
   - 再否則 `${OPEN_SHELL_WORKSPACE_BASE}/data`
3. 解析到的目錄會 mount 到 sandbox agent 容器的 `/workspace/data`。

## 驗證（目錄指向辨識）

- `pass/data/data.txt` 應可讀到 `this is data dir`
- `pass/data_user01/data_user01.txt` 應可讀到 `this is data_user01 dir`

切換 `OPEN_SHELL_WORKSPACE_USER_DATAPATH` 後重新建立 sandbox，可確認 `/workspace/data` 對應來源已變更。
