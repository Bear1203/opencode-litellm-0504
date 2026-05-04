# opencode-litellm

把 LiteLLM server 的所有可用模型動態注入 [opencode](https://opencode.ai) 的小工具。

每次啟動時自動打 `$LITELLM_BASE_URL/v1/models` 取得模型清單，透過 `OPENCODE_CONFIG_CONTENT` 注入 opencode。失敗時 fallback 到本機 cache，斷網也能用。

---

## 快速開始

```bash
# 1. 安裝
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash

# 2. 把 ~/.local/bin 加到 PATH (若還沒加過)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

# 3. 啟動 — 首次啟動會引導你輸入 API key 和 URL
opencode-litellm
```

---

## 需求

- Linux (bash 4+)
- `curl`、`python3`
- 已安裝 [opencode](https://opencode.ai)

---

## 設定

### 方式一：互動式 (推薦)

首次執行 `opencode-litellm` 時，若尚未設定，會直接提示你輸入 API key 和 URL，自動寫入 `~/.config/opencode/litellm.env`。

### 方式二：手動編輯

```bash
${EDITOR:-vi} ~/.config/opencode/litellm.env
```

| 變數 | 說明 |
|---|---|
| `LITELLM_API_KEY` | (必填) LiteLLM Bearer token |
| `LITELLM_BASE_URL` | (必填) LiteLLM server URL |
| `LITELLM_PROVIDER_ID` | (預設 `litellm`) opencode provider id |
| `LITELLM_PROVIDER_NAME` | (預設 `LiteLLM`) 選單顯示名稱 |

不想用 .env 的話，直接用 `export` 也可以：
```bash
export LITELLM_API_KEY=sk-...
export LITELLM_BASE_URL=https://...
```

---

## 使用

```bash
opencode-litellm                   # 啟動 TUI
opencode-litellm run "hello"       # 非互動模式
```

---

## 升級

重跑安裝指令即可，`litellm.env` 不會被覆寫：

```bash
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
```

---

## 解除安裝

```bash
# 保留設定與 cache
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --uninstall

# 全部清乾淨
curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash -s -- --purge
```

---

## 疑難排解

| 問題 | 解法 |
|---|---|
| `command not found` | `~/.local/bin` 不在 PATH，加到 `~/.bashrc` |
| 模型選單空空 / 401 | 檢查 key 和 URL，看 log: `tail ~/.cache/opencode/litellm-sync.log` |
| 模型清單是舊的 | 這次 API 呼叫失敗用了 cache，server 復原後下次啟動會自動更新 |

---

## 工作原理

```
opencode-litellm
    ├─ source ~/.config/opencode/litellm.env
    ├─ 偵測 placeholder → 互動式引導輸入 (僅首次)
    ├─ litellm-sync.sh ─→ GET $BASE_URL/v1/models
    │       ├─ 成功 → 更新 cache,組 JSON config
    │       └─ 失敗 → 讀 cache,組 JSON config
    ├─ export OPENCODE_CONFIG_CONTENT="<JSON>"
    └─ exec opencode "$@"
```
