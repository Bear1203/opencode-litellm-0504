#!/usr/bin/env bash
# opencode-litellm installer (macOS / bash)
#
# 一般安裝:
#   curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
#
# 解除安裝 / 自訂安裝: 用旗標或環境變數皆可
#   curl -fsSL <url>/install.sh | bash -s -- --uninstall   # 移除程式檔 (保留 env / key)
#   curl -fsSL <url>/install.sh | bash -s -- --purge       # 連同 env / key / log 一起移除
#   環境變數 (與 Windows 版對齊):
#     OPENCODE_LITELLM_UNINSTALL=1
#     OPENCODE_LITELLM_PURGE=1
#     OPENCODE_LITELLM_PREFIX=/path       覆寫安裝路徑 (預設 ~/.local/share/opencode-litellm)
#     OPENCODE_LITELLM_REPO=https://...   覆寫下載來源
#     OPENCODE_LITELLM_LOCALSRC=/src      從本機目錄安裝 (開發用)

set -euo pipefail

UNINSTALL="${OPENCODE_LITELLM_UNINSTALL:-}"
PURGE="${OPENCODE_LITELLM_PURGE:-}"
PREFIX="${OPENCODE_LITELLM_PREFIX:-}"
LOCALSRC="${OPENCODE_LITELLM_LOCALSRC:-}"

# 旗標覆寫 env
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --purge)     PURGE=1 ;;
    esac
done

DEFAULT_REPO='https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main'
REPO="${OPENCODE_LITELLM_REPO:-$DEFAULT_REPO}"
VERSION='0.1.0'

# 路徑配置
#   程式檔 (我們的 wrapper):  ~/.local/share/opencode-litellm/{bin,lib}
#   PATH 進入點 (symlink):    ~/.local/bin/opencode-litellm
#   opencode 設定 / log:      ~/.config/opencode/  (opencode 官方 global config 位置)
[ -z "$PREFIX" ] && PREFIX="$HOME/.local/share/opencode-litellm"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib"
CONFIG_DIR="$HOME/.config/opencode"
COMMANDS_DIR="$CONFIG_DIR/commands"
ENV_FILE="$CONFIG_DIR/litellm.env"
KEY_FILE="$CONFIG_DIR/litellm-key"
LOG_FILE="$CONFIG_DIR/litellm-sync.log"
PATH_BIN="$HOME/.local/bin"
PATH_LINK="$PATH_BIN/opencode-litellm"

c_reset=$'\033[0m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
info()  { printf '[install] %s\n' "$1"; }
ok()    { printf '%s%s%s\n' "$c_green" "$1" "$c_reset"; }
warn2() { printf '%s%s%s\n' "$c_yellow" "$1" "$c_reset"; }
err()   { printf '%s%s%s\n' "$c_red" "$1" "$c_reset"; }

fetch_file() {
    # $1 = repo 相對路徑, $2 = 目標
    local rel="$1" dest="$2" destdir
    destdir="$(dirname "$dest")"
    [ -d "$destdir" ] || mkdir -p "$destdir"
    if [ -n "$LOCALSRC" ]; then
        cp "$LOCALSRC/$rel" "$dest"
    else
        curl -fsSL "$REPO/$rel" -o "$dest"
    fi
}

install_opencode() {
    info '找不到 opencode 指令,將以官方安裝腳本安裝...'
    if curl -fsSL https://opencode.ai/install | bash; then
        ok 'opencode 已安裝'
    else
        err '自動安裝 opencode 失敗。'
        err '請手動安裝: https://opencode.ai/docs/  (例如 brew install anomalyco/tap/opencode)'
    fi
}

# 確保 jq 可用: PATH 已有就不動;否則下載對應架構的獨立執行檔到 $BIN_DIR/jq。
# 不加進 PATH,只給我們的 sync 內部使用 (sync 會用同一顆),不污染使用者環境。
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        info "jq 已在 PATH ($(command -v jq)),沿用"
        return 0
    fi
    if [ -x "$BIN_DIR/jq" ]; then
        info "已有私有 jq ($BIN_DIR/jq),沿用"
        return 0
    fi
    if [ "$(uname -s)" != 'Darwin' ]; then
        warn2 "非 macOS,略過下載 jq;sync 時將改由 Homebrew 或 PATH 上的 jq 處理"
        return 0
    fi
    local arch asset url tmp
    arch="$(uname -m)"
    case "$arch" in
        arm64|aarch64) asset='jq-macos-arm64' ;;
        x86_64|amd64)  asset='jq-macos-amd64' ;;
        *) warn2 "未知架構 $arch,略過下載 jq (sync 會再試一次)"; return 0 ;;
    esac
    url="https://github.com/jqlang/jq/releases/latest/download/$asset"
    info "下載 jq ($asset)..."
    mkdir -p "$BIN_DIR"
    tmp="$BIN_DIR/.jq.tmp.$$"
    if curl -fsSL "$url" -o "$tmp" && [ -s "$tmp" ]; then
        chmod +x "$tmp"
        mv -f "$tmp" "$BIN_DIR/jq"
        ok "jq 已安裝: $BIN_DIR/jq"
    else
        rm -f "$tmp"
        warn2 "jq 下載失敗,首次 sync 時會再自動嘗試一次"
    fi
}

ensure_path() {
    # 確保 ~/.local/bin 在 PATH。已在就跳過,否則寫進 shell profile。
    case ":$PATH:" in
        *":$PATH_BIN:"*) info "PATH 已含 $PATH_BIN,跳過"; return 0 ;;
    esac
    local line="export PATH=\"$PATH_BIN:\$PATH\""
    local touched=0 f
    for f in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        # .zshrc 一定寫 (macOS 預設 zsh);其餘存在才追加,避免無謂建檔
        if [ "$f" = "$HOME/.zshrc" ] || [ -f "$f" ]; then
            if [ ! -f "$f" ] || ! grep -qF "$PATH_BIN" "$f" 2>/dev/null; then
                printf '\n# opencode-litellm\n%s\n' "$line" >>"$f"
                info "已將 PATH 寫入 $f"
            fi
            touched=1
        fi
    done
    [ "$touched" -eq 1 ] && warn2 "PATH 已更新,請重開終端機或執行: source ~/.zshrc"
    export PATH="$PATH_BIN:$PATH"
}

do_install() {
    if ! command -v opencode >/dev/null 2>&1; then
        install_opencode
    fi

    if [ -n "$LOCALSRC" ]; then info "本機來源: $LOCALSRC"; else info "下載來源: $REPO"; fi

    info '安裝目標:'
    info "  wrapper   -> $BIN_DIR/opencode-litellm"
    info "  lib       -> $LIB_DIR/litellm-sync.sh"
    info "  symlink   -> $PATH_LINK"
    info "  env       -> $ENV_FILE"
    info "  commands  -> $COMMANDS_DIR/litellm-{sync,doctor}.md"

    local d
    for d in "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR" "$COMMANDS_DIR" "$PATH_BIN"; do
        [ -d "$d" ] || mkdir -p "$d"
    done

    fetch_file 'bin/opencode-litellm.sh'          "$BIN_DIR/opencode-litellm"
    fetch_file 'lib/litellm-sync.sh'              "$LIB_DIR/litellm-sync.sh"
    fetch_file 'config/commands/litellm-sync.md'   "$COMMANDS_DIR/litellm-sync.md"
    fetch_file 'config/commands/litellm-doctor.md' "$COMMANDS_DIR/litellm-doctor.md"
    chmod +x "$BIN_DIR/opencode-litellm" "$LIB_DIR/litellm-sync.sh"

    # symlink 到 PATH 上;-f 覆蓋舊 link
    ln -sf "$BIN_DIR/opencode-litellm" "$PATH_LINK"

    # env 檔: 已存在就不覆蓋
    if [ -f "$ENV_FILE" ]; then
        info "保留既有 $ENV_FILE"
    else
        fetch_file 'config/litellm.env.example' "$ENV_FILE"
    fi

    ensure_jq
    ensure_path

    printf '\n'
    ok "安裝完成 (version $VERSION)"
    ok "  進入點: $PATH_LINK"
    printf '\n'
    ok '接下來:'
    ok '  1) 首次啟動 (會引導輸入 LiteLLM API Key):'
    ok '       opencode-litellm'
    ok '  2) 完成後可直接使用 opencode:'
    ok '       opencode'
    ok ''
    ok '  其他常用指令:'
    ok '       opencode-litellm help       # 完整說明 (含 opencode TUI 常用指令)'
    ok '       opencode-litellm sync       # 重新同步模型清單'
    ok '       opencode-litellm config     # 修改 API Key'
    ok '       opencode-litellm doctor     # 檢查環境狀態'
}

do_uninstall() {
    local do_purge="${1:-}"
    local f
    for f in "$BIN_DIR/opencode-litellm" "$BIN_DIR/jq" "$LIB_DIR/litellm-sync.sh" \
             "$COMMANDS_DIR/litellm-sync.md" "$COMMANDS_DIR/litellm-doctor.md" \
             "$PATH_LINK"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            info "移除 $f"
            rm -f "$f"
        fi
    done

    for d in "$BIN_DIR" "$LIB_DIR" "$PREFIX"; do
        if [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
            rmdir "$d" 2>/dev/null || true
        fi
    done

    if [ "$do_purge" = "purge" ]; then
        info "purge: 移除 $ENV_FILE / $KEY_FILE / $LOG_FILE"
        for f in "$ENV_FILE" "$KEY_FILE" "$LOG_FILE"; do
            [ -f "$f" ] && rm -f "$f"
        done
        warn2 "保留 $CONFIG_DIR/opencode.json 不動 (內含使用者其他設定)。"
        warn2 '若要清除 provider.litellm 區塊請手動編輯該檔。'
    else
        info '保留設定 / token / log (加 --purge 或設 OPENCODE_LITELLM_PURGE=1 可一併刪除)'
    fi
    ok '已移除'
}

if [ -n "$PURGE" ]; then
    do_uninstall purge
elif [ -n "$UNINSTALL" ]; then
    do_uninstall
else
    do_install
fi
