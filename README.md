# opencode-litellm (Windows 版)

把自建 [LiteLLM](https://github.com/BerriAI/litellm) server 的所有可用模型整合進 [opencode](https://opencode.ai),
讓你直接在 opencode 中使用團隊內部的 LLM 閘道。

設定一次完成後,**直接打 `opencode` 就能用**——模型清單與 token 都已寫入 `opencode.json`。

> 本版本為 **Windows / PowerShell** 專用,使用 PowerShell 實作,無需 WSL、無需 Python。

---

## 快速開始

在 **PowerShell**(建議用 Windows Terminal)執行:

```powershell
# 1. 安裝 (沒裝 opencode 會問你要不要自動裝;PATH 自動寫入 User PATH)
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex

# 2. 開新的 PowerShell / Terminal 視窗 (讓 PATH 生效)

# 3. 啟動 — 首次會引導輸入 LiteLLM API key 和 URL,接著自動同步模型清單
opencode-litellm

# 4. 之後直接打 opencode 即可
opencode
```

> 如果你的 PowerShell 執行原則阻擋了腳本,可先在當前 session 放寬:
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
> 再執行上面的 `irm ... | iex`。安裝後產生的 `opencode-litellm.cmd` shim 內部會自動帶 `-ExecutionPolicy Bypass`,因此後續執行不會再受限。

---

## 需求

- Windows 10 / 11
- PowerShell 5.1+ (Windows 內建) 或 PowerShell 7
- [opencode](https://opencode.ai) — 安裝程式偵測不到時會問你是否自動安裝(預設 Y)

---

## 指令

```powershell
opencode-litellm                # 啟動 opencode (首次自動引導 + 同步)
opencode-litellm sync           # 重新同步模型清單到 opencode.json
opencode-litellm config         # 互動式修改 LITELLM_API_KEY / LITELLM_BASE_URL / LITELLM_PROVIDER_NAME
opencode-litellm doctor         # 檢查環境與設定狀態
opencode-litellm --help         # 完整說明
opencode-litellm --version      # 顯示版本
```

opencode TUI 內也可以直接呼叫:

```
/litellm-sync       重新同步模型 (重啟 opencode 後生效)
/litellm-doctor     檢查設定狀態
```

---

## 設定

第一次跑 `opencode-litellm` 會互動引導,設定會存到 `%APPDATA%\opencode\litellm.env`。
日後想修改有三種方式 (任選):

1. `opencode-litellm config` — 互動式 (推薦)
2. 直接編輯 `%APPDATA%\opencode\litellm.env`
3. 在 PowerShell 中 `$env:LITELLM_API_KEY = '...'; $env:LITELLM_BASE_URL = '...'`

| 變數 | 必填 | 預設 | 說明 |
|---|:-:|---|---|
| `LITELLM_API_KEY` | ✓ | — | LiteLLM Bearer token (只存於 `litellm-key` 檔,不寫入 env) |
| `LITELLM_BASE_URL` | ✓ | — | LiteLLM server URL (例如 `https://litellm.example.com`) |
| `LITELLM_PROVIDER_ID` | | `litellm` | opencode 中的 provider id |
| `LITELLM_PROVIDER_NAME` | | `LiteLLM` | opencode 選單上顯示的名稱 (可用 `opencode-litellm config` 互動修改) |
| `LITELLM_TIMEOUT` | | `10` | 取模型清單時的 HTTP timeout (秒) |

---

## 檔案路徑

| 用途 | 路徑 |
|---|---|
| 程式本體 | `%LOCALAPPDATA%\opencode-litellm\bin\opencode-litellm.ps1`<br>`%LOCALAPPDATA%\opencode-litellm\bin\opencode-litellm.cmd` (shim) |
| Sync 腳本 | `%LOCALAPPDATA%\opencode-litellm\lib\litellm-sync.ps1` |
| 設定檔 (非機密) | `%APPDATA%\opencode\litellm.env` |
| API token | `%APPDATA%\opencode\litellm-key` (僅本人可讀) |
| opencode 主設定 | `%APPDATA%\opencode\opencode.json` |
| Sync log | `%LOCALAPPDATA%\opencode\litellm-sync.log` |
| Slash commands | `%APPDATA%\opencode\commands\litellm-{sync,doctor}.md` |

---

## 工作原理

```
opencode-litellm                            (首次 / 設定變動時才會打 API)
  |- 載入 %APPDATA%\opencode\litellm.env
  |- 沒設定 -> 互動引導,寫入 .env
  |- opencode.json 還沒有 provider.<id> -> 呼叫 sync
  |     |- GET $BASE_URL/v1/models
  |     |- 把 token 寫入 %APPDATA%\opencode\litellm-key (ACL 僅本人可讀)
  |     +- Merge 模型清單到 %APPDATA%\opencode\opencode.json
  |           provider.<id>.options.apiKey = "{file:~/.config/opencode/litellm-key}"
  +- 呼叫 opencode

opencode                                    (日常使用,完全離線)
  +- 讀 opencode.json -> 透過 {file:...} 自動注入 token -> 啟動
```

> 同步後設定都已就緒,使用者打 `opencode`、`opencode run "hi"`、`opencode serve` 都能直接用。
> 模型有更新時跑 `opencode-litellm sync` 即可,不會重複呼叫 API。

---

## 升級

重跑安裝指令即可,`litellm.env` 與 `litellm-key` 不會被覆寫:

```powershell
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
```

## 解除安裝

`irm | iex` 不能直接帶參數,所以解除安裝請先下載再執行:

```powershell
# 移除程式檔案,保留設定
irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 -OutFile $env:TEMP\opencode-litellm-install.ps1
& $env:TEMP\opencode-litellm-install.ps1 -Uninstall

# 連同 .env / token / log 一併刪除 (opencode.json 不主動動)
& $env:TEMP\opencode-litellm-install.ps1 -Purge
```

或者直接手動刪除:`%LOCALAPPDATA%\opencode-litellm\` 整個資料夾。

---

## 疑難排解

任何問題第一步都先跑 `opencode-litellm doctor`,它會逐項檢查並給你修正指令。

| 症狀 | 解法 |
|---|---|
| `opencode-litellm` 無法辨識 | User PATH 未生效;**關閉所有 terminal 重新開啟**,或手動把 `%LOCALAPPDATA%\opencode-litellm\bin` 加入 User PATH |
| `opencode` 無法辨識 | opencode 沒裝 / 不在 PATH;`opencode-litellm doctor` 會給安裝指令 |
| `無法載入檔案 ... 因為這個系統上已停用指令碼執行` | 用 `opencode-litellm.cmd` shim 啟動 (預設安裝後就是這個);或執行 `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` |
| 401 / 403 / 模型清單空 | 跑 `opencode-litellm config` 修正 key 或 URL |
| 模型清單舊了想刷新 | `opencode-litellm sync` |
| `opencode.json` 解析失敗 | 為避免破壞既有設定 sync 會中止,請修正或刪除該檔後重試 |
| 看詳細日誌 | `Get-Content -Tail 50 $env:LOCALAPPDATA\opencode\litellm-sync.log` |

---

## 安全性

- `litellm-key` 是純文字 token,安裝時會用 NTFS ACL 設定為「只有自己能讀」
- `litellm.env` 與 `litellm-key` 都放在 `%APPDATA%\opencode\`,屬於使用者私有目錄
- `opencode.json` 中只放 `{file:...}` 引用,不含明文 token,可放心提交到 git (但不建議,因為內含內部 server URL)
