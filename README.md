# opencode-litellm

把自建 [LiteLLM](https://github.com/BerriAI/litellm) server 的所有可用模型整合進 [opencode](https://opencode.ai)。
設定一次完成後**直接打 `opencode` 就能用**——模型清單與 token 都已寫入 `opencode.json`。

支援 **Windows** (PowerShell 5.1+,無需 WSL / Python) 與 **macOS** (bash,不需 Homebrew;唯一相依的 `jq` 會自動下載獨立執行檔)。

---

## 快速開始

### Windows

在 **PowerShell**(建議 Windows Terminal)執行:

```powershell
# 1. 安裝 (沒裝 opencode 會自動下載;PATH 自動寫入)
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex

# 2. 首次啟動,引導你輸入 API Key,自動同步模型
opencode-litellm

# 3. 之後直接用 opencode
opencode
```

> 若 PowerShell 執行原則阻擋腳本:`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` 後再執行 `irm | iex`。

### macOS

在 **Terminal** 執行:

```bash
# 1. 安裝 (沒裝 opencode 會用官方腳本自動裝;PATH 寫入 ~/.zshrc)
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash

# 2. 開新終端機 (或 source ~/.zshrc) 讓 PATH 生效,再首次啟動引導輸入 API Key
opencode-litellm

# 3. 之後直接用 opencode
opencode
```

> 唯一相依的 `jq` 會在安裝時自動下載對應架構的獨立執行檔(放在程式目錄下,不動到系統),**不需要 Homebrew**。若你系統已裝過 `jq`(含 Homebrew 版)會優先沿用。

---

## 指令

```powershell
opencode-litellm                # 啟動 opencode (首次自動引導 + 同步)
opencode-litellm sync           # 重新同步模型清單
opencode-litellm config         # 修改 API Key
opencode-litellm doctor         # 檢查環境狀態
```

opencode TUI 內也可以打 `/litellm-sync` 或 `/litellm-doctor`。

> 注意:`sync` / `config` / `doctor` 跑的是**本機磁碟上的 `.ps1`**。
> 上游有更新時,**先重跑 `irm ... install.ps1 | iex` 才會拉到新版**。

---

## 設定

設定存在 `litellm.env`,API token 單獨存在 `litellm-key`(權限收緊為僅本人可讀:Windows 用 ACL,macOS 用 `chmod 600`)。兩者都在 opencode 的 config 資料夾:

- Windows:`%USERPROFILE%\.config\opencode\`
- macOS:`~/.config/opencode/`

> 注意:opencode 官方 global config 路徑就是 `~/.config/opencode/opencode.json`,我們所有 LiteLLM 周邊都放在這個資料夾下統一管理(兩平台相同)。

| 變數 | 必填 | 預設 | 說明 |
|---|:-:|---|---|
| `LITELLM_API_KEY` | ✓ | — | LiteLLM Bearer token (存於 `litellm-key`,不寫入 env) |
| `LITELLM_BASE_URL` | | `https://litellm-server.pic-ai.work` | LiteLLM server URL (自動套用預設) |
| `LITELLM_PROVIDER_ID` | | `litellm` | opencode provider id |
| `LITELLM_PROVIDER_NAME` | | `PIC-Litellm` | opencode 選單顯示名稱 (固定值) |
| `LITELLM_TIMEOUT` | | `10` | `/v1/models` HTTP timeout (秒) |

---

## 重新安裝 / 解除安裝

本工具沒有升級流程,有變動請**解除安裝再重裝**。

**Windows** 透過環境變數控制(`irm | iex` 不能帶參數):

```powershell
# 解除安裝 (連 env / token / log 一起刪)
$env:OPENCODE_LITELLM_PURGE = '1'
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
Remove-Item Env:OPENCODE_LITELLM_PURGE

# 重裝
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
```

**macOS** 可用旗標或環境變數:

```bash
# 解除安裝 (連 env / token / log 一起刪)
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --purge

# 只移除程式檔、保留設定: 把 --purge 換成 --uninstall

# 重裝
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
```

| 環境變數 | 用途 |
|---|---|
| `OPENCODE_LITELLM_UNINSTALL=1` | 移除程式檔,保留 `litellm.env` / `litellm-key`(macOS 亦可用 `--uninstall`) |
| `OPENCODE_LITELLM_PURGE=1` | 連同 env / token / log 一起刪除(macOS 亦可用 `--purge`) |
| `OPENCODE_LITELLM_PREFIX=<path>` | 覆寫安裝路徑 (Windows 預設 `%LOCALAPPDATA%\opencode-litellm`,macOS 預設 `~/.local/share/opencode-litellm`) |

> 兩種模式都不會動 `opencode.json`(內含其他 provider 設定);要清 `provider.litellm` 區塊請手動編輯。

---

## 疑難排解

第一步先跑 `opencode-litellm doctor`。

| 症狀 | 解法 |
|---|---|
| `opencode-litellm` 找不到 | PATH 未生效,**關閉所有 Terminal 重開**(macOS 也可 `source ~/.zshrc`) |
| 401 / 403 / 模型清單空 | `opencode-litellm config` 修正 API Key |
| `opencode.json` 解析失敗 | sync 為了不破壞既有設定會中止,請修正或刪除該檔後重試 |
| macOS 提示無法取得 `jq` | 通常是網路擋了 GitHub 下載;可自行 `brew install jq`(有的話 sync 會沿用),或確認能連到 github.com 後重跑 `opencode-litellm sync` |
| 看詳細日誌 (Windows) | `Get-Content -Tail 50 $env:USERPROFILE\.config\opencode\litellm-sync.log` |
| 看詳細日誌 (macOS) | `tail -50 ~/.config/opencode/litellm-sync.log` |
