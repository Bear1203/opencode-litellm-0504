#!/usr/bin/env bash
# opencode-litellm — 把 LiteLLM 模型清單整合進 opencode (macOS / bash)
#
# 用法:
#   opencode-litellm                啟動 opencode (首次會引導設定 + 同步模型)
#   opencode-litellm sync           重新同步模型清單到 opencode.json
#   opencode-litellm config         互動式修改 API Key
#   opencode-litellm doctor         檢查環境設定狀態
#   opencode-litellm --help         顯示說明
#   opencode-litellm --version      顯示版本

set -euo pipefail

VERSION='0.1.0'
DEFAULT_PROVIDER_NAME='PIC-Litellm'
DEFAULT_BASE_URL='https://litellm-server.pic-ai.work'

# opencode 的 global config 路徑就是 ~/.config/opencode/opencode.json,
# 我們所有 LiteLLM 周邊檔 (env / key / log) 都放在同一個資料夾下統一管理。
CONFIG_DIR="$HOME/.config/opencode"
ENV_FILE="$CONFIG_DIR/litellm.env"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
KEY_FILE="$CONFIG_DIR/litellm-key"

# sync 腳本位於安裝後的 ../lib/ (wrapper 在 bin/)。用 symlink 也能正確解析。
SELF="${BASH_SOURCE[0]}"
while [ -h "$SELF" ]; do
    dir="$(cd -P "$(dirname "$SELF")" && pwd)"
    SELF="$(readlink "$SELF")"
    case "$SELF" in /*) ;; *) SELF="$dir/$SELF" ;; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
SYNC_SCRIPT="$(cd -P "$BIN_DIR/../lib" 2>/dev/null && pwd || echo "$BIN_DIR")/litellm-sync.sh"

# jq 位置: 優先用 PATH 的,其次用安裝時放在 bin/ 的私有 jq。
# 把 bin 目錄透過 OPENCODE_LITELLM_BIN 傳給 sync 子行程,讓兩邊找到同一顆。
export OPENCODE_LITELLM_BIN="$BIN_DIR"
find_jq() {
    if command -v jq >/dev/null 2>&1; then command -v jq; return 0; fi
    [ -x "$BIN_DIR/jq" ] && { printf '%s' "$BIN_DIR/jq"; return 0; }
    return 1
}

# 執行期會被 load_config 覆寫的變數
LITELLM_BASE_URL=''
LITELLM_PROVIDER_ID='litellm'
LITELLM_PROVIDER_NAME="$DEFAULT_PROVIDER_NAME"
LITELLM_TIMEOUT='10'
LITELLM_API_KEY=''

c_reset=$'\033[0m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
linfo() { printf '[opencode-litellm] %s\n' "$1"; }
lwarn() { printf '%s[opencode-litellm] WARN: %s%s\n' "$c_yellow" "$1" "$c_reset"; }
lerr()  { printf '%s[opencode-litellm] ERROR: %s%s\n' "$c_red" "$1" "$c_reset"; }
lok()   { printf '%s[opencode-litellm] OK %s%s\n' "$c_green" "$1" "$c_reset"; }

# .env 讀取: KEY=VALUE 一行一筆,# 開頭為註解。輸出 KEY<TAB>VALUE 供呼叫端解析。
read_env_value() {
    # $1 = key
    [ -f "$ENV_FILE" ] || return 0
    local line trim k v
    while IFS= read -r line || [ -n "$line" ]; do
        trim="${line#"${line%%[![:space:]]*}"}"
        case "$trim" in ''|'#'*) continue ;; esac
        case "$trim" in *=*) ;; *) continue ;; esac
        k="${trim%%=*}"; k="${k%"${k##*[![:space:]]}"}"
        [ "$k" = "$1" ] || continue
        v="${trim#*=}"; v="${v#"${v%%[![:space:]]*}"}"
        # 去除包住整個值的成對引號
        case "$v" in
            \"*\") v="${v#\"}"; v="${v%\"}" ;;
            \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
        printf '%s' "$v"
        return 0
    done <"$ENV_FILE"
}

ensure_env_file() {
    [ -f "$ENV_FILE" ] && return 0
    mkdir -p "$(dirname "$ENV_FILE")"
    cat >"$ENV_FILE" <<'EOF'
# opencode-litellm 設定檔 (KEY=VALUE,不要寫 shell 語法)
#
# API key 不存在這裡,只存在 ~/.config/opencode/litellm-key。
# 改 key 請執行: opencode-litellm config

LITELLM_BASE_URL=https://litellm-server.pic-ai.work
LITELLM_PROVIDER_NAME=PIC-Litellm

# === 可選 ===
# LITELLM_PROVIDER_ID=litellm
# LITELLM_TIMEOUT=10
EOF
}

update_env_key() {
    # $1 = key, $2 = value
    ensure_env_file
    local key="$1" value="$2" tmp updated=0
    tmp="$ENV_FILE.tmp.$$"
    : >"$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        if printf '%s' "$line" | grep -Eq "^[[:space:]]*#?[[:space:]]*$(printf '%s' "$key" | sed 's/[.[\*^$/]/\\&/g')[[:space:]]*="; then
            printf '%s=%s\n' "$key" "$value" >>"$tmp"
            updated=1
        else
            printf '%s\n' "$line" >>"$tmp"
        fi
    done <"$ENV_FILE"
    [ "$updated" -eq 0 ] && printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv -f "$tmp" "$ENV_FILE"
}

# 寫入 API token (無結尾換行,權限 600)
write_key_file() {
    local value="$1" tmp
    mkdir -p "$(dirname "$KEY_FILE")"
    tmp="$KEY_FILE.tmp.$$"
    (umask 077; printf '%s' "$value" >"$tmp")
    mv -f "$tmp" "$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || lwarn "無法設定 $KEY_FILE 權限"
}

load_config() {
    local v
    v="$(read_env_value LITELLM_BASE_URL)";      LITELLM_BASE_URL="${v:-}"
    v="$(read_env_value LITELLM_PROVIDER_ID)";   LITELLM_PROVIDER_ID="${v:-litellm}"
    v="$(read_env_value LITELLM_PROVIDER_NAME)"; LITELLM_PROVIDER_NAME="${v:-$DEFAULT_PROVIDER_NAME}"
    v="$(read_env_value LITELLM_TIMEOUT)";       LITELLM_TIMEOUT="${v:-10}"

    if [ -f "$KEY_FILE" ]; then
        LITELLM_API_KEY="$(cat "$KEY_FILE")"
    else
        LITELLM_API_KEY=''
    fi

    # 把設定 export 給 sync 子行程
    export LITELLM_BASE_URL LITELLM_API_KEY LITELLM_PROVIDER_ID \
           LITELLM_PROVIDER_NAME LITELLM_TIMEOUT
    export LITELLM_KEY_FILE="$KEY_FILE"
    export OPENCODE_CONFIG_FILE="$CONFIG_FILE"
}

test_api_key() { [ -n "$LITELLM_API_KEY" ]; }
# 視為「未設定」的 URL: 空字串 / 範例值
test_base_url() {
    case "$LITELLM_BASE_URL" in
        ''|'https://litellm.example.com'|'https://litellm.example.com/') return 1 ;;
        *) return 0 ;;
    esac
}

test_config_has_provider() {
    [ -f "$CONFIG_FILE" ] || return 1
    local jq; jq="$(find_jq)" || return 1
    "$jq" -e --arg id "$LITELLM_PROVIDER_ID" \
        '.provider[$id].models | (. != null) and (length > 0)' \
        "$CONFIG_FILE" >/dev/null 2>&1
}

get_config_default_model() {
    [ -f "$CONFIG_FILE" ] || return 1
    local jq; jq="$(find_jq)" || return 1
    "$jq" -re '.model // empty' "$CONFIG_FILE" 2>/dev/null
}

mask_key() {
    local k="$1"
    if [ "${#k}" -gt 10 ]; then
        printf '%s...%s' "${k:0:6}" "${k: -2}"
    else
        printf '******'
    fi
}

prompt_api_key() {
    # $1 = "keep" 允許 Enter 保留既有值
    local allow_keep="${1:-}" value
    while true; do
        if [ "$allow_keep" = "keep" ] && test_api_key; then
            printf '新的 LITELLM_API_KEY (Enter 保留 %s): ' "$(mask_key "$LITELLM_API_KEY")"
        else
            printf 'LITELLM_API_KEY (你的 LiteLLM API key,不能空白): '
        fi
        # -s 不回顯,避免 key 出現在畫面 / 終端記錄
        read -rs value; printf '\n'
        if [ -z "$value" ]; then
            if [ "$allow_keep" = "keep" ] && test_api_key; then return 0; fi
            lwarn '不能為空,請輸入你的 API key (或 Ctrl+C 中止)'
            continue
        fi
        write_key_file "$value"
        LITELLM_API_KEY="$value"; export LITELLM_API_KEY
        lok "已儲存 LITELLM_API_KEY -> $KEY_FILE"
        return 0
    done
}

ensure_base_url() {
    # 網址不讓使用者設定,直接套用預設值
    if ! test_base_url; then
        update_env_key LITELLM_BASE_URL "$DEFAULT_BASE_URL"
        LITELLM_BASE_URL="$DEFAULT_BASE_URL"; export LITELLM_BASE_URL
        lok "已套用 LITELLM_BASE_URL ($DEFAULT_BASE_URL)"
    fi
}

ensure_provider_name() {
    # 模型清單分類名稱固定為 PIC-Litellm,不讓使用者設定
    if [ "$LITELLM_PROVIDER_NAME" != "$DEFAULT_PROVIDER_NAME" ]; then
        update_env_key LITELLM_PROVIDER_NAME "$DEFAULT_PROVIDER_NAME"
        LITELLM_PROVIDER_NAME="$DEFAULT_PROVIDER_NAME"; export LITELLM_PROVIDER_NAME
        lok "已套用 LITELLM_PROVIDER_NAME ($DEFAULT_PROVIDER_NAME)"
    fi
}

require_credentials() {
    if [ ! -f "$SYNC_SCRIPT" ]; then
        lerr "找不到 sync 腳本: $SYNC_SCRIPT"
        lerr '請重新執行安裝: curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash'
        return 1
    fi
    if ! test_api_key || ! test_base_url; then
        lerr 'LITELLM_API_KEY 或 LITELLM_BASE_URL 尚未設定。'
        linfo "執行 'opencode-litellm config' 以互動式設定。"
        return 1
    fi
    return 0
}

run_sync() {
    require_credentials || return 1
    linfo "同步 LiteLLM 模型清單 -> $CONFIG_FILE"
    if bash "$SYNC_SCRIPT"; then
        lok '同步完成'
        return 0
    fi
    lerr "同步失敗,詳情請見 $CONFIG_DIR/litellm-sync.log"
    linfo "若 URL 或 token 錯誤,執行 'opencode-litellm config' 修正後重試"
    return 1
}

run_config() {
    linfo '重新設定 LiteLLM API Key'
    printf '\n'
    ensure_env_file
    ensure_base_url
    ensure_provider_name
    prompt_api_key keep
    printf '\n'
    linfo '套用新設定並同步模型...'
    printf '\n'
    run_sync
}

run_doctor() {
    local issues=0 oc
    printf '[opencode-litellm] 環境檢查\n\n'

    printf '  opencode 指令          : '
    if oc="$(command -v opencode 2>/dev/null)"; then printf '%sOK %s%s\n' "$c_green" "$oc" "$c_reset"
    else printf '%sMISSING 找不到 opencode%s\n' "$c_red" "$c_reset"; issues=$((issues+1)); fi

    printf '  litellm-sync.sh        : '
    if [ -f "$SYNC_SCRIPT" ]; then printf '%sOK %s%s\n' "$c_green" "$SYNC_SCRIPT" "$c_reset"
    else printf '%sMISSING %s%s\n' "$c_red" "$SYNC_SCRIPT" "$c_reset"; issues=$((issues+1)); fi

    printf '  jq                     : '
    if jqpath="$(find_jq)"; then printf '%sOK %s%s\n' "$c_green" "$jqpath" "$c_reset"
    else printf '%sMISSING (sync 會自動下載獨立檔)%s\n' "$c_yellow" "$c_reset"; fi

    printf '  litellm.env            : '
    if [ -f "$ENV_FILE" ]; then printf '%sOK %s%s\n' "$c_green" "$ENV_FILE" "$c_reset"
    else printf "%sMISSING 不存在 (跑 'opencode-litellm config' 即可建立)%s\n" "$c_red" "$c_reset"; issues=$((issues+1)); fi

    printf '  LITELLM_API_KEY        : '
    if test_api_key; then printf '%sOK 已設定 (%s)%s\n' "$c_green" "$(mask_key "$LITELLM_API_KEY")" "$c_reset"
    else printf "%sMISSING 未設定 (跑 'opencode-litellm config')%s\n" "$c_red" "$c_reset"; issues=$((issues+1)); fi

    printf '  LITELLM_BASE_URL       : '
    if test_base_url; then printf '%sOK %s%s\n' "$c_green" "$LITELLM_BASE_URL" "$c_reset"
    else printf "%sMISSING 未設定 (跑 'opencode-litellm config')%s\n" "$c_red" "$c_reset"; issues=$((issues+1)); fi

    printf '  LITELLM_PROVIDER_NAME  : '
    printf '%sOK %s%s\n' "$c_green" "$LITELLM_PROVIDER_NAME" "$c_reset"

    printf '  opencode.json          : '
    if test_config_has_provider; then printf '%sOK %s (含 provider.%s)%s\n' "$c_green" "$CONFIG_FILE" "$LITELLM_PROVIDER_ID" "$c_reset"
    else printf "%sMISSING 缺 provider.%s (跑 'opencode-litellm sync')%s\n" "$c_red" "$LITELLM_PROVIDER_ID" "$c_reset"; issues=$((issues+1)); fi

    printf '  預設模型 (model)       : '
    if dm="$(get_config_default_model)"; then printf '%sOK %s%s\n' "$c_green" "$dm" "$c_reset"
    else printf '%sINFO 未設定 (opencode 啟動時會用內建預設;跑 sync 會自動帶入)%s\n' "$c_yellow" "$c_reset"; fi

    printf '  litellm-key (token)    : '
    if [ -f "$KEY_FILE" ]; then printf '%sOK %s%s\n' "$c_green" "$KEY_FILE" "$c_reset"
    else printf "%sMISSING 不存在 (跑 'opencode-litellm config' 即可建立)%s\n" "$c_red" "$c_reset"; issues=$((issues+1)); fi

    printf '\n'
    if [ "$issues" -eq 0 ]; then
        lok "一切正常,可以直接打 'opencode' 啟動。"
        return 0
    fi
    lerr "發現 $issues 個問題,請依上面提示修正。"
    return 1
}

run_first_time_setup_if_needed() {
    ensure_env_file
    ensure_base_url
    ensure_provider_name
    if test_api_key; then return 0; fi
    linfo '設定 LiteLLM API Key'
    printf '\n'
    prompt_api_key
    printf '\n'
    linfo '設定完成,繼續啟動...'
    printf '\n'
}

show_help() {
    cat <<EOF
opencode-litellm v$VERSION  (macOS / bash)
LiteLLM 模型整合工具,把 LiteLLM 的所有模型清單同步進 opencode。

================================================================
本工具指令 (opencode-litellm ...)
================================================================
  opencode-litellm              啟動 opencode (首次自動引導 + 同步模型清單)
  opencode-litellm <args>       參數原樣傳給 opencode,例如:
                                  opencode-litellm run "hello"

  sync                          重新同步 LiteLLM 模型清單到 opencode.json
                                (新增 / 刪除模型後跑一次,opencode 重啟生效)
  config                        互動式修改 API Key
                                 (改完會自動 sync 一次)
  doctor                        檢查環境設定狀態 (找不到指令 / key 過期等)
  help, --help, -h              顯示本說明
  --version                     顯示版本

================================================================
opencode 本體常用 (在 TUI 內,輸入 / 開頭)
================================================================
換模型 / 看模型清單:
  /models                       開啟模型選單                  快捷鍵: Ctrl+X M

對話控制:
  /new                          開啟新對話 (清空當前)         快捷鍵: Ctrl+X N
  /sessions                     列出 / 切換歷史 session       快捷鍵: Ctrl+X L
  /compact                      壓縮當前對話 (context 滿時)   快捷鍵: Ctrl+X C
  /undo                         還原上一則訊息 (含檔案變更)   快捷鍵: Ctrl+X U
  /redo                         重做 (在 /undo 之後)          快捷鍵: Ctrl+X R
  /exit                         離開 opencode                 快捷鍵: Ctrl+X Q

訊息技巧:
  @檔案名                       插入檔案內容到對話 (fuzzy 搜尋)
  !指令                         在訊息開頭加 ! 直接執行 shell 指令

其他:
  /themes                       換 TUI 主題                   快捷鍵: Ctrl+X T
  /editor                       用外部編輯器寫長 prompt       快捷鍵: Ctrl+X E
  /share                        分享 session 連結
  /init                         產生 / 更新 AGENTS.md
  Ctrl+P                        開啟指令面板 (搜尋所有指令)

================================================================
看 token 使用量 / 費用
================================================================
  - opencode TUI 右下角會即時顯示「當前 session 的 tokens」
  - 累計用量與費用要去 LiteLLM 後台看 (LiteLLM 是 proxy,每次 call
    都會記在那邊;opencode 本身不收費也不統計)

================================================================
設定檔位置
================================================================
  $ENV_FILE
  $KEY_FILE  (僅本人可讀)
  $CONFIG_FILE  (opencode 主設定)

詳細文件: https://github.com/Bear1203/opencode-litellm-0504
opencode 官方文件: https://opencode.ai/docs/
EOF
}

# === 主流程 ===
load_config

first="${1:-}"
case "$first" in
    sync)                       run_sync; exit $? ;;
    config|configure)           run_config; exit $? ;;
    doctor|check|status)        run_doctor; exit $? ;;
    -h|--help|help)             show_help; exit 0 ;;
    --version|version)          printf 'opencode-litellm v%s\n' "$VERSION"; exit 0 ;;
esac

run_first_time_setup_if_needed

if ! test_config_has_provider; then
    linfo '首次啟動,先取得模型清單...'
    if ! run_sync; then
        lerr '無法取得模型清單,中止啟動。'
        linfo '修正設定後請執行: opencode-litellm config'
        exit 1
    fi
fi

if ! command -v opencode >/dev/null 2>&1; then
    lerr '找不到 opencode 指令。請重新執行安裝程式以自動安裝 opencode。'
    exit 127
fi

exec opencode "$@"
