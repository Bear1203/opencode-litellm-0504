# opencode-litellm

把自建 [LiteLLM](https://github.com/BerriAI/litellm) server 的所有可用模型整合進 [opencode](https://opencode.ai),
讓你直接在 opencode 中使用團隊內部的 LLM 閘道。

設定一次完成後,**直接打 `opencode` 就能用**——模型清單與 token 都已寫入 opencode.json。

---

## 快速開始

```bash
# 1. 安裝 (沒裝 opencode 會問你要不要自動裝;PATH 自動寫入 ~/.bashrc)
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash

# 2. 重新載入 shell (或關閉重開 terminal)
source ~/.bashrc

# 3. 啟動 — 首次會引導輸入 LiteLLM API key 和 URL,接著自動同步模型清單
opencode-litellm

# 4. 之後直接打 opencode 即可
opencode
```

---

## 需求

- Linux / macOS (bash 4+)
- `curl`、`python3`
- [opencode](https://opencode.ai) — 安裝程式偵測不到時會問你是否自動安裝(預設 Y)

---

## 指令

```bash
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

第一次跑 `opencode-litellm` 會互動引導,設定會存到 `~/.config/opencode/litellm.env`。
日後想修改有三種方式 (任選):

1. `opencode-litellm config` — 互動式 (推薦)
2. 直接編輯 `~/.config/opencode/litellm.env`
3. 在 shell 中 `export LITELLM_API_KEY=...; export LITELLM_BASE_URL=...`

| 變數 | 必填 | 預設 | 說明 |
|---|:-:|---|---|
| `LITELLM_API_KEY` | ✓ | — | LiteLLM Bearer token |
| `LITELLM_BASE_URL` | ✓ | — | LiteLLM server URL (例如 `https://litellm.example.com`) |
| `LITELLM_PROVIDER_ID` | | `litellm` | opencode 中的 provider id |
| `LITELLM_PROVIDER_NAME` | | `LiteLLM` | opencode 選單上顯示的名稱 (可用 `opencode-litellm config` 互動修改) |
| `LITELLM_TIMEOUT` | | `10` | 取模型清單時的 curl timeout (秒) |

---

## 工作原理

```
opencode-litellm                            (首次 / 設定變動時才會打 API)
  ├─ 載入 ~/.config/opencode/litellm.env
  ├─ 沒設定 → 互動引導,寫入 .env
  ├─ opencode.json 還沒有 provider.<id> → 呼叫 sync
  │     ├─ GET $BASE_URL/v1/models
  │     ├─ 把 token 寫入 ~/.config/opencode/litellm-key (mode 600)
  │     └─ Merge 模型清單到 ~/.config/opencode/opencode.json
  │           provider.<id>.options.apiKey = "{file:~/.config/opencode/litellm-key}"
  └─ exec opencode

opencode                                    (日常使用,完全離線)
  └─ 讀 opencode.json → 透過 {file:...} 自動注入 token → 啟動
```

> 同步後設定都已就緒,使用者打 `opencode`、`opencode run "hi"`、`opencode serve` 都能直接用。
> 模型有更新時跑 `opencode-litellm sync` 即可,不會重複呼叫 API。

---

## 升級

重跑安裝指令即可,`litellm.env` 與 `litellm-key` 不會被覆寫:

```bash
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
```

## 解除安裝

```bash
# 移除程式檔案,保留設定
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --uninstall

# 連同 .env / token / log 一併刪除 (opencode.json 不主動動)
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --purge
```

---

## 疑難排解

任何問題第一步都先跑 `opencode-litellm doctor`,它會逐項檢查並給你修正指令。

| 症狀 | 解法 |
|---|---|
| `command not found: opencode-litellm` | `~/.local/bin` 不在 PATH;`source ~/.bashrc` 或重開 terminal |
| `command not found: opencode` | opencode 沒裝 / 不在 PATH;`opencode-litellm doctor` 會給安裝指令 |
| 401 / 403 / 模型清單空 | 跑 `opencode-litellm config` 修正 key 或 URL |
| 模型清單舊了想刷新 | `opencode-litellm sync` |
| `opencode.json` 解析失敗 | 為避免破壞既有設定 sync 會中止,請修正或刪除該檔後重試 |
| 看詳細日誌 | `tail -n 50 ~/.cache/opencode/litellm-sync.log` |

---

## 安全性

- `litellm-key` 是純文字 token,權限會自動設為 `0600`(只有自己能讀)
- `.env` 也是 `0600`
- `opencode.json` 中只放 `{file:...}` 引用,不含明文 token,可放心提交到 git (但不建議,因為內含內部 server URL)
