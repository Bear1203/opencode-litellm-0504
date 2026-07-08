#!/usr/bin/env bash
# litellm-sync.sh (macOS / bash)
#
# 從 LiteLLM 取得可用模型清單,merge 到使用者的 opencode.json,
# 並把 API token 寫入獨立檔案讓 opencode.json 用 {file:...} 引用。
#
# 讀取的環境變數:
#   LITELLM_BASE_URL       (必填) LiteLLM server URL
#   LITELLM_API_KEY        (必填) Bearer token,沒給就讀 LITELLM_KEY_FILE
#   LITELLM_PROVIDER_ID    (預設 litellm)
#   LITELLM_PROVIDER_NAME  (預設 PIC-Litellm)
#   LITELLM_TIMEOUT        (預設 10) HTTP timeout 秒數
#   OPENCODE_CONFIG_FILE   (預設 ~/.config/opencode/opencode.json)
#   LITELLM_KEY_FILE       (預設 ~/.config/opencode/litellm-key)
#   LITELLM_LOG_FILE       (預設 ~/.config/opencode/litellm-sync.log)

set -euo pipefail

OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
BASE_URL="${LITELLM_BASE_URL:-}"
API_KEY="${LITELLM_API_KEY:-}"
PROVIDER_ID="${LITELLM_PROVIDER_ID:-litellm}"
PROVIDER_NAME="${LITELLM_PROVIDER_NAME:-PIC-Litellm}"
TIMEOUT_SEC="${LITELLM_TIMEOUT:-10}"
CONFIG_FILE="${OPENCODE_CONFIG_FILE:-$OPENCODE_CONFIG_DIR/opencode.json}"
KEY_FILE="${LITELLM_KEY_FILE:-$OPENCODE_CONFIG_DIR/litellm-key}"
LOG_FILE="${LITELLM_LOG_FILE:-$OPENCODE_CONFIG_DIR/litellm-sync.log}"

for d in "$(dirname "$LOG_FILE")" "$(dirname "$CONFIG_FILE")" "$(dirname "$KEY_FILE")"; do
    [ -n "$d" ] && [ ! -d "$d" ] && mkdir -p "$d"
done

log() {
    local line
    line="[$(date '+%Y-%m-%dT%H:%M:%S%z')] [litellm-sync] $1"
    printf '%s\n' "$line" >>"$LOG_FILE"
    printf '%s\n' "$line" >&2
}

# 任何未預期的錯誤都留下 log,避免 "sync 失敗但沒看到原因"
trap 'log "FATAL: 於第 $LINENO 行以非零狀態結束"' ERR

# jq 是 merge 的必要工具。解析順序: PATH → 我們自己裝的私有 jq → 下載獨立檔 → brew。
# 私有 jq 放程式目錄下,不加進 PATH,純內部使用不污染環境。
PRIV_BIN="${OPENCODE_LITELLM_BIN:-$HOME/.local/share/opencode-litellm/bin}"
JQ=''

# 下載對應架構的 jq 獨立執行檔 (單一 Mach-O binary,無依賴、不需 sudo)
download_jq() {
    # 只在 macOS 抓 jq-macos-* (Linux 會拿到不能執行的 Mach-O,交給 brew 兜底)
    [ "$(uname -s)" = 'Darwin' ] || { log "WARN: 非 macOS ($(uname -s)),略過下載 jq"; return 1; }
    local arch asset url tmp
    arch="$(uname -m)"
    case "$arch" in
        arm64|aarch64) asset='jq-macos-arm64' ;;
        x86_64|amd64)  asset='jq-macos-amd64' ;;
        *) log "WARN: 未知架構 $arch,無法下載 jq 獨立檔"; return 1 ;;
    esac
    url="https://github.com/jqlang/jq/releases/latest/download/$asset"
    log "下載 jq ($asset)..."
    mkdir -p "$PRIV_BIN"
    tmp="$PRIV_BIN/.jq.tmp.$$"
    if curl -fsSL "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        chmod +x "$tmp"
        mv -f "$tmp" "$PRIV_BIN/jq"
        return 0
    fi
    rm -f "$tmp"
    log "WARN: jq 下載失敗 ($url)"
    return 1
}

resolve_jq() {
    if command -v jq >/dev/null 2>&1; then JQ="$(command -v jq)"; return 0; fi
    if [ -x "$PRIV_BIN/jq" ]; then JQ="$PRIV_BIN/jq"; return 0; fi
    log '找不到 jq,嘗試下載獨立檔...'
    if download_jq; then JQ="$PRIV_BIN/jq"; return 0; fi
    if command -v brew >/dev/null 2>&1; then
        log '改以 Homebrew 安裝 jq...'
        if brew install jq >&2 && command -v jq >/dev/null 2>&1; then JQ="$(command -v jq)"; return 0; fi
    fi
    return 1
}

if ! resolve_jq; then
    log 'ERROR: 需要 jq 但無法取得 (下載失敗且無 Homebrew)。'
    log '       請檢查網路,或手動安裝 jq (brew install jq) 後重試。'
    exit 1
fi

# API key: env 沒給時讀 KeyFile
if [ -z "$API_KEY" ] && [ -f "$KEY_FILE" ]; then
    API_KEY="$(cat "$KEY_FILE")"
fi

if [ -z "$BASE_URL" ]; then log 'ERROR: LITELLM_BASE_URL 未設定'; exit 1; fi
if [ -z "$API_KEY" ]; then log "ERROR: LITELLM_API_KEY 未設定 (env 變數或 $KEY_FILE 都沒有)"; exit 1; fi

BASE_URL="${BASE_URL%/}"

# 1. 取得模型清單
MODELS_URL="$BASE_URL/v1/models"
log "GET $MODELS_URL"

if ! resp="$(curl -fsS --max-time "$TIMEOUT_SEC" -H "Authorization: Bearer $API_KEY" "$MODELS_URL")"; then
    log 'ERROR: API 沒有回應或回應錯誤'
    log '       請檢查 LITELLM_BASE_URL / LITELLM_API_KEY 是否正確,以及網路連線'
    exit 1
fi

if ! printf '%s' "$resp" | "$JQ" -e '.data' >/dev/null 2>&1; then
    log 'ERROR: API 回應沒有 data 欄位'
    exit 1
fi

# 2. 寫入 key 檔 (無結尾換行,並收緊權限為僅本人可讀)
(umask 077; printf '%s' "$API_KEY" >"$KEY_FILE")
chmod 600 "$KEY_FILE"
log "API key 已寫入 $KEY_FILE"

# 3. 解析模型清單 (全程用 jq,不進 bash 陣列 — macOS 內建 bash 3.2 沒有 mapfile)
models_json="$(printf '%s' "$resp" | "$JQ" -c '[.data[] | select(.id != null) | .id] | unique')"
model_count="$(printf '%s' "$models_json" | "$JQ" 'length')"
if [ "$model_count" -eq 0 ]; then
    log 'ERROR: 模型清單為空,放棄寫入'
    exit 1
fi

# 4. 讀既有 config (存在但解析失敗就中止,絕不覆蓋使用者設定)
if [ -s "$CONFIG_FILE" ]; then
    if ! existing="$("$JQ" . "$CONFIG_FILE" 2>/dev/null)"; then
        log "ERROR: $CONFIG_FILE JSON 解析失敗"
        log '       為避免破壞既有設定,中止寫入。請修正或刪除該檔後再試。'
        exit 1
    fi
else
    existing='{}'
fi

# key file 路徑改寫成 ~ 開頭 (opencode 支援的相對路徑)
case "$KEY_FILE" in
    "$HOME"/*) KEY_REF="~${KEY_FILE#"$HOME"}" ;;
    *)         KEY_REF="$KEY_FILE" ;;
esac

# 5. Merge:只動 provider.<id>、$schema (缺才補)、model (缺才補)。其餘原樣保留。
merged="$(printf '%s' "$existing" | "$JQ" \
    --arg id "$PROVIDER_ID" \
    --arg name "$PROVIDER_NAME" \
    --arg baseurl "$BASE_URL/v1" \
    --arg keyref "{file:$KEY_REF}" \
    --argjson models "$models_json" '
    (if has("$schema") then . else . + {"$schema": "https://opencode.ai/config.json"} end)
    | .provider = (.provider // {})
    | .provider[$id] = {
        npm: "@ai-sdk/openai-compatible",
        name: $name,
        options: { baseURL: $baseurl, apiKey: $keyref },
        models: ($models | map({ (.): { name: . } }) | add)
      }
    | (if has("model") then . else .model = ($id + "/" + $models[0]) end)
')"

# 6. 原子寫入
config_dir="$(dirname "$CONFIG_FILE")"
tmp="$config_dir/.opencode-$$-$RANDOM.json"
if printf '%s\n' "$merged" >"$tmp"; then
    mv -f "$tmp" "$CONFIG_FILE"
else
    rm -f "$tmp"
    log "ERROR: 寫入 $CONFIG_FILE 失敗"
    exit 1
fi

log "已同步 $model_count 個模型 -> $CONFIG_FILE (provider.$PROVIDER_ID)"
exit 0
