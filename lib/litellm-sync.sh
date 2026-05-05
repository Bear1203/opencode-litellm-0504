#!/usr/bin/env bash
# litellm-sync.sh
#
# 從 LiteLLM 取得可用模型清單,merge 到使用者的 opencode.json
# (只更新 provider.<id> 區塊,其他設定原樣保留),並把 API token 寫入
# 獨立檔案讓 opencode.json 用 {file:...} 引用。
#
# Env 變數:
#   LITELLM_BASE_URL       (必填) LiteLLM server URL
#   LITELLM_API_KEY        (必填) Bearer token
#   LITELLM_PROVIDER_ID    (預設 litellm)
#   LITELLM_PROVIDER_NAME  (預設 "LiteLLM")
#   LITELLM_TIMEOUT        (預設 10) curl --max-time
#   LITELLM_LOG_FILE       (預設 ~/.cache/opencode/litellm-sync.log)
#   OPENCODE_CONFIG_FILE   (預設 ~/.config/opencode/opencode.json)
#   LITELLM_KEY_FILE       (預設 ~/.config/opencode/litellm-key)

set -euo pipefail

BASE_URL="${LITELLM_BASE_URL:-}"
API_KEY="${LITELLM_API_KEY:-}"
PROVIDER_ID="${LITELLM_PROVIDER_ID:-litellm}"
PROVIDER_NAME="${LITELLM_PROVIDER_NAME:-LiteLLM}"
TIMEOUT="${LITELLM_TIMEOUT:-10}"
LOG_FILE="${LITELLM_LOG_FILE:-$HOME/.cache/opencode/litellm-sync.log}"
CONFIG_FILE="${OPENCODE_CONFIG_FILE:-$HOME/.config/opencode/opencode.json}"
KEY_FILE="${LITELLM_KEY_FILE:-$HOME/.config/opencode/litellm-key}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$CONFIG_FILE")" "$(dirname "$KEY_FILE")"

log() {
  printf '[%s] [litellm-sync] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

# 若環境變數沒給 API key,從 KEY_FILE 讀 (新版設計: token 只存 KEY_FILE)
if [[ -z "$API_KEY" && -f "$KEY_FILE" ]]; then
  API_KEY="$(cat "$KEY_FILE" 2>/dev/null || true)"
fi

# --- 必要條件 ---------------------------------------------------------------
[[ -n "$BASE_URL" ]] || { log "ERROR: LITELLM_BASE_URL 未設定"; exit 1; }
[[ -n "$API_KEY"  ]] || { log "ERROR: LITELLM_API_KEY 未設定 (env 變數或 $KEY_FILE 都沒有)"; exit 1; }

# --- 1. 取得模型清單 --------------------------------------------------------
log "GET $BASE_URL/v1/models"
RESP="$(curl -fsS --max-time "$TIMEOUT" \
  -H "Authorization: Bearer $API_KEY" \
  "$BASE_URL/v1/models" 2>/dev/null || true)"

if [[ -z "$RESP" ]]; then
  log "ERROR: API 沒有回應 (請檢查 LITELLM_BASE_URL / LITELLM_API_KEY 是否正確,以及網路連線)"
  exit 1
fi

# --- 2. 寫入 key 檔 ---------------------------------------------------------
# opencode.json 用 {file:...} 引用,使用者直接打 opencode 也能拿到 token
umask 077
printf '%s' "$API_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
log "API key 已寫入 $KEY_FILE (0600)"

# --- 3. 解析模型清單並 merge 到 opencode.json -------------------------------
# Python 區塊負責: 解析 API 回應 → 讀既有 config → merge → 原子寫入 → 印出模型數
COUNT="$(
  RESP="$RESP" \
  PROVIDER_ID="$PROVIDER_ID" \
  PROVIDER_NAME="$PROVIDER_NAME" \
  BASE_URL="$BASE_URL" \
  CONFIG_FILE="$CONFIG_FILE" \
  KEY_FILE="$KEY_FILE" \
  python3 <<'PY'
import json, os, sys, tempfile

# --- 解析 API 回應 ---
try:
    data = json.loads(os.environ["RESP"])
    ids = sorted({
        m["id"] for m in data.get("data", [])
        if isinstance(m, dict) and isinstance(m.get("id"), str)
    })
except (json.JSONDecodeError, TypeError) as e:
    sys.stderr.write(f"[litellm-sync] ERROR: 解析模型清單失敗: {e}\n")
    sys.exit(1)

if not ids:
    sys.stderr.write("[litellm-sync] ERROR: 模型清單為空,放棄寫入\n")
    sys.exit(1)

provider_id   = os.environ["PROVIDER_ID"]
provider_name = os.environ["PROVIDER_NAME"]
base_url      = os.environ["BASE_URL"].rstrip("/")
config_file   = os.environ["CONFIG_FILE"]
key_file      = os.environ["KEY_FILE"]

# 把家目錄下的 key file 路徑改寫成 ~/... 形式 (可讀性 & 可攜性)
home = os.path.expanduser("~")
key_ref = "~" + key_file[len(home):] if key_file.startswith(home + "/") else key_file

# --- 讀取既有 opencode.json (只 merge 不覆蓋) ---
config = {}
if os.path.exists(config_file):
    try:
        with open(config_file, encoding="utf-8") as f:
            text = f.read().strip()
        if text:
            config = json.loads(text)
            if not isinstance(config, dict):
                sys.stderr.write(f"[litellm-sync] WARN: {config_file} 不是 JSON object,將整個重建\n")
                config = {}
    except json.JSONDecodeError as e:
        sys.stderr.write(f"[litellm-sync] ERROR: {config_file} JSON 解析失敗: {e}\n")
        sys.stderr.write("[litellm-sync]        為避免破壞既有設定,中止寫入。請修正或刪除該檔後再試。\n")
        sys.exit(1)

config.setdefault("$schema", "https://opencode.ai/config.json")

# --- 組 provider.<id> 區塊 ---
models = {mid: {"name": mid.split("/", 1)[-1] if "/" in mid else mid} for mid in ids}

config.setdefault("provider", {})[provider_id] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": provider_name,
    "options": {
        "baseURL": base_url + "/v1",
        "apiKey": "{file:" + key_ref + "}",
    },
    "models": models,
}

# --- 原子寫入 ---
config_dir = os.path.dirname(config_file) or "."
fd, tmp_path = tempfile.mkstemp(prefix=".opencode-", suffix=".json", dir=config_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, config_file)
except Exception:
    try: os.unlink(tmp_path)
    except OSError: pass
    raise

# 印到 stdout,讓 bash 用 $(...) 接住
print(len(models))
PY
)"

if [[ -z "$COUNT" ]]; then
  log "ERROR: sync 過程失敗 (詳情見上方訊息)"
  exit 1
fi

log "已同步 $COUNT 個模型 → $CONFIG_FILE (provider.$PROVIDER_ID)"
