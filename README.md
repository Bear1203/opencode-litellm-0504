# opencode-litellm

把 LiteLLM server 的所有可用模型動態注入 [opencode](https://opencode.ai) 的小工具。

每次啟動 `opencode-litellm` 時:

1. 打 `$LITELLM_BASE_URL/v1/models` 拉最新模型清單
2. 動態組成 OpenCode provider 設定 (使用 `@ai-sdk/openai-compatible`)
3. 透過 `OPENCODE_CONFIG_CONTENT` 環境變數注入 opencode
4. 失敗時自動 fallback 到本機 cache,斷網也能用

---

## TL;DR (3 步驟)

```bash
# 1. 安裝
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash

# 2. 填入你的 API key 和 LiteLLM server URL (必做!)
${EDITOR:-vi} ~/.config/opencode/litellm.env

# 3. 啟動
opencode-litellm
```

如果第 3 步出現 `command not found`,跳到 [PATH 設定](#步驟-2-把-localbin-加到-path-如果還沒加過)。

---

## 需求

- Linux (bash 4+)
- `curl`、`python3`
- 已安裝 [opencode](https://opencode.ai)
- 一組可用的 LiteLLM API key 與 server URL (向 admin 索取)

---

## 步驟 1: 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
```

執行後會落地三個檔案:

| 檔案 | 路徑 | 用途 |
|---|---|---|
| wrapper 指令 | `~/.local/bin/opencode-litellm` | 你之後直接呼叫的指令 |
| sync 腳本 | `~/.config/opencode/litellm-sync.sh` | 拉模型清單用 |
| 設定範本 | `~/.config/opencode/litellm.env` (`chmod 600`) | **下一步要編輯的檔案** |

> 重跑這條指令 = 升級。`litellm.env` 不會被覆寫。

---

## 步驟 2: 把 ~/.local/bin 加到 PATH (如果還沒加過)

先檢查:

```bash
echo $PATH | tr ':' '\n' | grep -F "$HOME/.local/bin"
```

有輸出就跳過這步。沒輸出的話:

```bash
# Bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

# Zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

驗證:

```bash
which opencode-litellm
# 應該印出 /home/<you>/.local/bin/opencode-litellm
```

---

## 步驟 3: 填寫設定檔 (必做)

打開設定檔:

```bash
${EDITOR:-vi} ~/.config/opencode/litellm.env
```

預設內容長這樣:

```bash
LITELLM_API_KEY=sk-please-replace-me
LITELLM_BASE_URL=https://litellm.example.com

# LITELLM_PROVIDER_ID=litellm
# LITELLM_PROVIDER_NAME=LiteLLM
```

**你必須改的兩行:**

| 變數 | 改成什麼 |
|---|---|
| `LITELLM_API_KEY` | 你的 API key (向 admin 索取,通常 `sk-` 開頭) |
| `LITELLM_BASE_URL` | LiteLLM server URL,例如 `https://litellm.your-company.internal` |

改完範例:

```bash
LITELLM_API_KEY=sk-abc123def456...
LITELLM_BASE_URL=https://litellm.your-company.internal
```

> **注意**: 這個檔案只能寫 `KEY=VALUE` 格式,不要加 `export` 或其他 shell 語法。
>
> **不想用 .env**? 改用環境變數也可以,當前 shell 的 export 優先序最高:
> ```bash
> export LITELLM_API_KEY=sk-...
> export LITELLM_BASE_URL=https://...
> ```

---

## 步驟 4: 啟動

```bash
opencode-litellm                   # = opencode (TUI)
opencode-litellm run "hello"       # = opencode run "hello"
```

進入 opencode 後在模型選單會看到 `LiteLLM` provider,底下列出所有你這把 key 能用的模型。

如果看到下列錯誤訊息,代表你還沒做步驟 3:

```
[opencode-litellm] ERROR: LITELLM_API_KEY is not set or still the placeholder value.
[opencode-litellm] ERROR: LITELLM_BASE_URL is not set or still the placeholder value.
```

---

## 進階: 自訂 provider 顯示名稱

如果不想看到 `LiteLLM`,可以在 `litellm.env` 取消註解這兩行並改成你想要的:

```bash
LITELLM_PROVIDER_ID=my-llm        # opencode 內部 id (建議小寫無空白)
LITELLM_PROVIDER_NAME=My LLM      # 選單上顯示的名稱
```

改完直接重啟 `opencode-litellm` 即可。

---

## 環境變數總覽

| 變數 | 預設 | 說明 |
|---|---|---|
| `LITELLM_API_KEY` | (必填) | LiteLLM Bearer token |
| `LITELLM_BASE_URL` | (必填) | LiteLLM server URL,例如 `https://litellm.example.com` |
| `LITELLM_PROVIDER_ID` | `litellm` | opencode provider id |
| `LITELLM_PROVIDER_NAME` | `LiteLLM` | provider 顯示名稱 |
| `LITELLM_TIMEOUT` | `5` | curl 拉模型清單的 timeout (秒) |
| `LITELLM_CACHE_FILE` | `~/.cache/opencode/litellm-models.json` | 模型清單 cache 路徑 |
| `LITELLM_LOG_FILE` | `~/.cache/opencode/litellm-sync.log` | 同步 log 路徑 |
| `LITELLM_ENV_FILE` | `~/.config/opencode/litellm.env` | .env 檔路徑 |

---

## 升級

```bash
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
```

不會覆寫 `litellm.env`,你的 key 會保留。

---

## 解除安裝

```bash
# 保留 litellm.env 與 cache (萬一以後想再裝)
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --uninstall

# 連 .env、cache、log 一起刪除
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --purge
```

---

## 疑難排解

### `opencode-litellm: command not found`

`~/.local/bin` 不在 PATH。回去做 [步驟 2](#步驟-2-把-localbin-加到-path-如果還沒加過)。

### `ERROR: LITELLM_API_KEY is not set or still the placeholder value`

範本 key 沒改。回去做 [步驟 3](#步驟-3-填寫設定檔-必做)。

### `ERROR: LITELLM_BASE_URL is not set or still the placeholder value`

範本 URL 沒改。回去做 [步驟 3](#步驟-3-填寫設定檔-必做)。

### 進到 opencode 但模型選單空空 / 出現 401

可能是 key 錯、URL 錯,或網路打不通。看 log:

```bash
tail -n 20 ~/.cache/opencode/litellm-sync.log
```

也可以手動跑 sync 腳本看詳細訊息:

```bash
~/.config/opencode/litellm-sync.sh > /dev/null
# stderr 會印 "Synced N models" 或具體錯誤原因
```

### 模型清單看起來是舊的

代表這次啟動時打 LiteLLM API 失敗,用了 cache。看 log 會有:

```
API unreachable, using cache: ...
```

server 復原後下次啟動 `opencode-litellm` 會自動更新。

### 完全離線時還能用嗎

可以,只要有過至少一次成功同步、cache 還在就行。沒 cache 的話模型清單會是空的,但 opencode 仍能啟動。

---

## 工作原理 (給好奇的人)

`opencode-litellm` 是個 wrapper:

```
opencode-litellm
    │
    ├─ source ~/.config/opencode/litellm.env
    ├─ guard: key 與 URL 不能是 placeholder
    ├─ litellm-sync.sh ─→ GET $BASE_URL/v1/models
    │       │
    │       ├─ 成功 → 更新 cache,組 JSON config
    │       └─ 失敗 → 讀 cache,組 JSON config
    │
    ├─ export OPENCODE_CONFIG_CONTENT="<JSON>"
    ├─ export LITELLM_API_KEY
    └─ exec opencode "$@"
            │
            └─ opencode 把 OPENCODE_CONFIG_CONTENT 跟 ~/.config/opencode/opencode.json 合併
```

`OPENCODE_CONFIG_CONTENT` 內容大致是:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.example.com/v1",
        "apiKey": "{env:LITELLM_API_KEY}"
      },
      "models": {
        "azure_ai/claude-opus-4-7": {"name": "claude-opus-4-7"},
        "...": {"name": "..."}
      }
    }
  }
}
```

---

## 檔案結構 (repo 內)

```
opencode-litellm/
├── install.sh                  # 安裝/升級/解除安裝腳本
├── bin/opencode-litellm        # wrapper,自動 source .env 後 exec opencode
├── lib/litellm-sync.sh         # 從 LiteLLM 拉模型清單,輸出 opencode config JSON
├── config/litellm.env.example  # 設定範本
├── VERSION
└── README.md
```
