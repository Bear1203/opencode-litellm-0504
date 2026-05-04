#!/usr/bin/env bash
# opencode-litellm installer
#
# 用法:
#   curl -fsSL https://<your-host>/install.sh | bash
#   curl -fsSL https://<your-host>/install.sh | bash -s -- --uninstall
#
# 旗標:
#   --uninstall   移除已安裝檔案 (保留 litellm.env 與 cache)
#   --purge       連同 litellm.env、cache、log 一起刪除
#   --prefix DIR  覆寫 bin 安裝路徑 (預設 ~/.local/bin)
#   --repo URL    覆寫下載來源 (預設下面的 REPO_RAW_BASE)
#   --local DIR   從本機目錄安裝 (開發 / 測試用,跳過下載)

set -euo pipefail

# ============================================================================
# 設定區: 預設下載來源
# 使用者可用 --repo 旗標或 OPENCODE_LITELLM_REPO 環境變數覆寫
# ============================================================================
DEFAULT_REPO="https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main"
REPO_RAW_BASE="${OPENCODE_LITELLM_REPO:-$DEFAULT_REPO}"
VERSION="0.1.0"

# ============================================================================
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/opencode"
CACHE_DIR="$HOME/.cache/opencode"
ENV_FILE="$CONFIG_DIR/litellm.env"
LOCAL_SRC=""
ACTION="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) ACTION="uninstall"; shift ;;
    --purge)     ACTION="purge"; shift ;;
    --prefix)    INSTALL_PREFIX="$2"; shift 2 ;;
    --repo)      REPO_RAW_BASE="$2"; shift 2 ;;
    --local)     LOCAL_SRC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '[install] %s\n' "$*"; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      red "缺少必要指令: $c"
      exit 1
    }
  done
}

fetch() {
  # fetch <relative-path> <dest>
  local rel="$1" dest="$2"
  if [[ -n "$LOCAL_SRC" ]]; then
    cp "$LOCAL_SRC/$rel" "$dest"
  else
    curl -fsSL "$REPO_RAW_BASE/$rel" -o "$dest"
  fi
}

do_install() {
  require_cmd bash curl python3
  if ! command -v opencode >/dev/null 2>&1; then
    yellow "WARN: 找不到 opencode 指令。請先安裝 opencode (https://opencode.ai)"
  fi

  if [[ -n "$LOCAL_SRC" ]]; then
    info "本機來源: $LOCAL_SRC"
  else
    info "下載來源: $REPO_RAW_BASE"
  fi

  info "安裝目標:"
  info "  bin     → $INSTALL_PREFIX/opencode-litellm"
  info "  lib     → $CONFIG_DIR/litellm-sync.sh"
  info "  env     → $ENV_FILE"

  mkdir -p "$INSTALL_PREFIX" "$CONFIG_DIR" "$CACHE_DIR"

  fetch "bin/opencode-litellm"     "$INSTALL_PREFIX/opencode-litellm"
  fetch "lib/litellm-sync.sh"      "$CONFIG_DIR/litellm-sync.sh"
  chmod +x "$INSTALL_PREFIX/opencode-litellm" "$CONFIG_DIR/litellm-sync.sh"

  # env 檔: 已存在就不覆蓋,避免洗掉使用者填好的 key
  if [[ -f "$ENV_FILE" ]]; then
    info "保留既有 $ENV_FILE (未覆寫)"
  else
    fetch "config/litellm.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    yellow ""
    yellow "================================================================"
    yellow "  下一步: 編輯 $ENV_FILE 填入你的 LITELLM_API_KEY"
    yellow "================================================================"
  fi

  # PATH 檢查
  case ":$PATH:" in
    *":$INSTALL_PREFIX:"*) ;;
    *)
      yellow ""
      yellow "WARN: $INSTALL_PREFIX 不在 PATH 中,請加到 ~/.bashrc 或 ~/.zshrc:"
      yellow "  export PATH=\"$INSTALL_PREFIX:\$PATH\""
      ;;
  esac

  green ""
  green "✓ 安裝完成 (version $VERSION)"
  green "  使用: opencode-litellm"
}

do_uninstall() {
  local purge="${1:-}"
  info "移除 $INSTALL_PREFIX/opencode-litellm"
  rm -f "$INSTALL_PREFIX/opencode-litellm"
  info "移除 $CONFIG_DIR/litellm-sync.sh"
  rm -f "$CONFIG_DIR/litellm-sync.sh"

  if [[ "$purge" == "purge" ]]; then
    info "purge: 移除 $ENV_FILE"
    rm -f "$ENV_FILE"
    info "purge: 移除 $CACHE_DIR/litellm-models.json $CACHE_DIR/litellm-sync.log"
    rm -f "$CACHE_DIR/litellm-models.json" "$CACHE_DIR/litellm-sync.log"
  else
    info "保留 $ENV_FILE 與 cache (用 --purge 可一併刪除)"
  fi
  green "✓ 已移除"
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  purge)     do_uninstall purge ;;
esac
