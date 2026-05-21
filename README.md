# opencode-litellm (Windows 版)

把自建 [LiteLLM](https://github.com/BerriAI/litellm) server 的所有可用模型整合進 [opencode](https://opencode.ai)。
設定一次完成後**直接打 `opencode` 就能用**——模型清單與 token 都已寫入 `opencode.json`。

Windows / PowerShell 5.1+ 專用,無需 WSL、無需 Python。

---

## 快速開始

在 **PowerShell**(建議 Windows Terminal)執行:

```powershell
# 1. 安裝 (沒裝 opencode 會自動下載;PATH 自動寫入)
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex

# 2. 開新的 Terminal 視窗讓 PATH 生效

# 3. 首次啟動,引導你輸入 API key / URL,自動同步模型
opencode-litellm

# 4. 之後直接用 opencode
opencode
```

桌面會多一個 `opencode-litellm.bat`,**那是雙擊跑「設定 / 健檢」用的**,不是啟動 opencode 用的。

> 若 PowerShell 執行原則阻擋腳本:`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` 後再執行 `irm | iex`。

---

## 指令

```powershell
opencode-litellm                # 啟動 opencode (首次自動引導 + 同步)
opencode-litellm sync           # 重新同步模型清單
opencode-litellm config         # 修改 API key / URL / provider name
opencode-litellm doctor         # 檢查環境狀態
```

opencode TUI 內也可以打 `/litellm-sync` 或 `/litellm-doctor`。

---

## 設定

設定存在 `%APPDATA%\opencode\litellm.env`,API token 單獨存在 `%APPDATA%\opencode\litellm-key`(NTFS ACL 設為僅本人可讀)。

| 變數 | 必填 | 預設 | 說明 |
|---|:-:|---|---|
| `LITELLM_API_KEY` | ✓ | — | LiteLLM Bearer token (存於 `litellm-key`,不寫入 env) |
| `LITELLM_BASE_URL` | ✓ | — | LiteLLM server URL |
| `LITELLM_PROVIDER_ID` | | `litellm` | opencode provider id |
| `LITELLM_PROVIDER_NAME` | | `LiteLLM` | opencode 選單顯示名稱 |
| `LITELLM_TIMEOUT` | | `10` | `/v1/models` HTTP timeout (秒) |

---

## 重新安裝 / 解除安裝

本工具沒有升級流程,有變動請**解除安裝再重裝**。透過環境變數控制安裝行為:

```powershell
# 解除安裝 (連 env / token / log 一起刪)
$env:OPENCODE_LITELLM_PURGE = '1'
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
Remove-Item Env:OPENCODE_LITELLM_PURGE

# 重裝
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
```

| 環境變數 | 用途 |
|---|---|
| `OPENCODE_LITELLM_UNINSTALL=1` | 移除程式檔,保留 `litellm.env` / `litellm-key` |
| `OPENCODE_LITELLM_PURGE=1` | 連同 env / token / log 一起刪除 |
| `OPENCODE_LITELLM_PREFIX=C:\path` | 覆寫安裝路徑 (預設 `%LOCALAPPDATA%\opencode-litellm`) |

> 兩種模式都不會動 `opencode.json`(內含其他 provider 設定);要清 `provider.litellm` 區塊請手動編輯。

---

## 疑難排解

第一步先跑 `opencode-litellm doctor`。

| 症狀 | 解法 |
|---|---|
| `opencode-litellm` 找不到 | PATH 未生效,**關閉所有 Terminal 重開** |
| 401 / 403 / 模型清單空 | `opencode-litellm config` 修正 key 或 URL |
| `opencode.json` 解析失敗 | sync 為了不破壞既有設定會中止,請修正或刪除該檔後重試 |
| 看詳細日誌 | `Get-Content -Tail 50 $env:LOCALAPPDATA\opencode\litellm-sync.log` |
