#!/usr/bin/env bash
# litellm-sync.sh
# 從 LiteLLM /v1/models 取得可用模型,輸出 OpenCode provider config (JSON to stdout)
# 失敗時自動 fallback 到 cache。
#
# Env:
#   LITELLM_BASE_URL   required (e.g. https://litellm.example.com)
#   LITELLM_API_KEY    required (Bearer token)
#   LITELLM_PROVIDER_ID default: litellm
#   LITELLM_PROVIDER_NAME default: "LiteLLM"
#   LITELLM_CACHE_FILE default: ~/.cache/opencode/litellm-models.json
#   LITELLM_TIMEOUT    default: 5 (curl --max-time)
#   LITELLM_LOG_FILE   default: ~/.cache/opencode/litellm-sync.log

set -euo pipefail

BASE_URL="${LITELLM_BASE_URL:-}"
API_KEY="${LITELLM_API_KEY:-}"
PROVIDER_ID="${LITELLM_PROVIDER_ID:-litellm}"
PROVIDER_NAME="${LITELLM_PROVIDER_NAME:-LiteLLM}"
CACHE_FILE="${LITELLM_CACHE_FILE:-$HOME/.cache/opencode/litellm-models.json}"
TIMEOUT="${LITELLM_TIMEOUT:-5}"
LOG_FILE="${LITELLM_LOG_FILE:-$HOME/.cache/opencode/litellm-sync.log}"

mkdir -p "$(dirname "$CACHE_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '[%s] [litellm-sync] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

if [[ -z "$BASE_URL" ]]; then
  log "ERROR: LITELLM_BASE_URL not set"
  exit 1
fi

if [[ -z "$API_KEY" ]]; then
  log "WARN: LITELLM_API_KEY not set; trying cache only"
fi

# 嘗試打 API,把 raw model id 列表存進 RAW_IDS_JSON (像 ["a","b",...])
RAW_IDS_JSON=""
if [[ -n "$API_KEY" ]]; then
  RESP="$(curl -fsS --max-time "$TIMEOUT" \
    -H "Authorization: Bearer $API_KEY" \
    "$BASE_URL/v1/models" 2>/dev/null || true)"

  if [[ -n "$RESP" ]]; then
    # 用 python3 解析 OpenAI 格式 {"data":[{"id":"..."}]}
    RAW_IDS_JSON="$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ids = sorted({m["id"] for m in d.get("data", []) if isinstance(m, dict) and "id" in m})
    print(json.dumps(ids))
except Exception:
    pass
' 2>/dev/null || true)"
  fi
fi

# Fallback:打不通或解析失敗就用 cache
if [[ -z "$RAW_IDS_JSON" || "$RAW_IDS_JSON" == "[]" ]]; then
  if [[ -f "$CACHE_FILE" ]]; then
    log "API unreachable, using cache: $CACHE_FILE"
    RAW_IDS_JSON="$(cat "$CACHE_FILE")"
  else
    log "ERROR: API unreachable and no cache available; emitting empty model list"
    RAW_IDS_JSON="[]"
  fi
else
  # 成功:更新 cache
  printf '%s' "$RAW_IDS_JSON" > "$CACHE_FILE"
  COUNT="$(printf '%s' "$RAW_IDS_JSON" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')"
  log "Synced $COUNT models from $BASE_URL"
fi

# 把 model id 列表轉成 OpenCode 設定片段
python3 - "$PROVIDER_ID" "$PROVIDER_NAME" "$BASE_URL" <<PY
import sys, json, os
ids_json = """$RAW_IDS_JSON"""
provider_id, provider_name, base_url = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ids = json.loads(ids_json)
except Exception:
    ids = []

models = {}
for mid in ids:
    # 顯示名稱:把斜線後段拿來做友善名稱
    short = mid.split("/", 1)[-1] if "/" in mid else mid
    models[mid] = {"name": short}

cfg = {
    "\$schema": "https://opencode.ai/config.json",
    "provider": {
        provider_id: {
            "npm": "@ai-sdk/openai-compatible",
            "name": provider_name,
            "options": {
                "baseURL": base_url.rstrip("/") + "/v1",
                "apiKey": "{env:LITELLM_API_KEY}"
            },
            "models": models
        }
    }
}
print(json.dumps(cfg, indent=2, ensure_ascii=False))
PY
