#!/usr/bin/env bash
# opencode-litellm installer
#
# 一般使用:
#   curl -fsSL https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.sh | bash
#
# 旗標:
#   --uninstall    移除已安裝檔案 (保留 litellm.env / litellm-key)
#   --purge        連同 litellm.env / litellm-key / log 一起刪除
#   --prefix DIR   覆寫 bin 安裝路徑 (預設 ~/.local/bin)
#   --repo URL     覆寫下載來源 (預設使用上面的 GitHub raw)
#   --local DIR    從本機目錄安裝 (開發 / 測試用,跳過下載)
#   -h, --help     顯示本說明

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

# 紀錄安裝流程中是否曾修改 ~/.bashrc,用於最後統一提示 source
BASHRC_MODIFIED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) ACTION="uninstall"; shift ;;
    --purge)     ACTION="purge"; shift ;;
    --prefix)    INSTALL_PREFIX="$2"; shift 2 ;;
    --repo)      REPO_RAW_BASE="$2"; shift 2 ;;
    --local)     LOCAL_SRC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \?//'
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

# 把 dir 加入 ~/.bashrc 的 PATH (重複時跳過)
add_to_bashrc_path() {
  local dir="$1"
  local bashrc="$HOME/.bashrc"
  local line="export PATH=\"$dir:\$PATH\""

  [[ -f "$bashrc" ]] || touch "$bashrc"

  if grep -Fq "$dir" "$bashrc" 2>/dev/null; then
    info "PATH 已含 $dir,跳過寫入 ~/.bashrc"
    return 0
  fi

  {
    printf '\n# Added by opencode-litellm installer\n'
    printf '%s\n' "$line"
  } >> "$bashrc"
  BASHRC_MODIFIED=1
  green "已將 $dir 寫入 ~/.bashrc"
}

# 自動安裝 opencode (官方 install script)
install_opencode() {
  yellow "找不到 opencode 指令。"

  # 非互動環境 (pipe to bash 但 stdin 不是 tty) 一律預設 Y
  local answer="Y"
  if [[ -t 0 ]]; then
    printf '是否要自動安裝 opencode? [Y/n] '
    read -r answer || answer="Y"
    answer="${answer:-Y}"
  else
    info "非互動模式,預設自動安裝 opencode"
  fi

  case "$answer" in
    [Nn]|[Nn][Oo])
      yellow "略過 opencode 安裝。請日後自行至 https://opencode.ai 安裝。"
      return 0
      ;;
  esac

  info "下載並執行 opencode 官方安裝腳本: https://opencode.ai/install"
  if ! curl -fsSL https://opencode.ai/install | bash; then
    red "opencode 安裝失敗,請手動安裝: https://opencode.ai"
    return 1
  fi

  # 官方腳本預設裝到 ~/.opencode/bin/opencode
  local opencode_bin_dir="$HOME/.opencode/bin"
  if [[ -x "$opencode_bin_dir/opencode" ]]; then
    add_to_bashrc_path "$opencode_bin_dir"
    # 讓本次 session 也能找到 (給後續 require_cmd 等檢查用)
    export PATH="$opencode_bin_dir:$PATH"
    green "✓ opencode 已安裝: $opencode_bin_dir/opencode"
  else
    yellow "opencode 已安裝,但找不到預期路徑 $opencode_bin_dir/opencode"
    yellow "請確認安裝位置並自行加入 PATH"
  fi
}

do_install() {
  require_cmd bash curl python3
  if ! command -v opencode >/dev/null 2>&1; then
    install_opencode || true
  fi

  if [[ -n "$LOCAL_SRC" ]]; then
    info "本機來源: $LOCAL_SRC"
  else
    info "下載來源: $REPO_RAW_BASE"
  fi

  info "安裝目標:"
  info "  bin       → $INSTALL_PREFIX/opencode-litellm"
  info "  lib       → $CONFIG_DIR/litellm-sync.sh"
  info "  env       → $ENV_FILE"
  info "  commands  → $CONFIG_DIR/commands/litellm-{sync,doctor}.md"

  mkdir -p "$INSTALL_PREFIX" "$CONFIG_DIR" "$CONFIG_DIR/commands" "$CACHE_DIR"

  fetch "bin/opencode-litellm"                "$INSTALL_PREFIX/opencode-litellm"
  fetch "lib/litellm-sync.sh"                 "$CONFIG_DIR/litellm-sync.sh"
  fetch "config/commands/litellm-sync.md"     "$CONFIG_DIR/commands/litellm-sync.md"
  fetch "config/commands/litellm-doctor.md"   "$CONFIG_DIR/commands/litellm-doctor.md"
  chmod +x "$INSTALL_PREFIX/opencode-litellm" "$CONFIG_DIR/litellm-sync.sh"

  # env 檔: 已存在就不覆蓋,避免洗掉使用者填好的 key;不存在則用範本建立
  # 使用者首次跑 opencode-litellm 會自動引導輸入 key/URL,這裡不另外提示。
  if [[ -f "$ENV_FILE" ]]; then
    info "保留既有 $ENV_FILE"
  else
    fetch "config/litellm.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi

  green ""
  green "✓ 安裝完成 (version $VERSION)"
  green "  二進位路徑: $INSTALL_PREFIX/opencode-litellm"
  green ""

  # PATH 設定:把 INSTALL_PREFIX 自動寫入 ~/.bashrc (若還沒在 PATH)
  if [[ -z "${LITELLM_SKIP_PATH_PROMPT:-}" ]]; then
    case ":$PATH:" in
      *":$INSTALL_PREFIX:"*) ;;  # 已在 PATH
      *) add_to_bashrc_path "$INSTALL_PREFIX" ;;
    esac
  fi

  # 統一提示: 若這次有修改過 ~/.bashrc,要使用者重新載入
  if [[ "$BASHRC_MODIFIED" == "1" ]]; then
    yellow ""
    yellow "================================================================"
    yellow "  下一步: 重新載入 shell 設定 (本次安裝有更新 ~/.bashrc)"
    yellow "================================================================"
    yellow ""
    yellow "  請執行下列其中一種方式讓 PATH 生效:"
    yellow ""
    yellow "    source ~/.bashrc"
    yellow ""
    yellow "  或是關閉 / 重新開啟 terminal"
    yellow ""
  fi

  # 完成後該怎麼用 (一律顯示)
  green "================================================================"
  green "  接下來"
  green "================================================================"
  green ""
  green "  1) 首次啟動 (會引導你輸入 LiteLLM API key 和 URL):"
  green "       opencode-litellm"
  green ""
  green "  2) 完成後可直接使用 opencode (模型清單與 token 已寫入 config):"
  green "       opencode"
  green ""
  green "  其他常用指令:"
  green "       opencode-litellm sync       # 重新同步模型清單 (新增/移除模型時)"
  green "       opencode-litellm config     # 修改 API key / URL"
  green "       opencode-litellm doctor     # 檢查當前環境設定狀態"
  green ""
}

do_uninstall() {
  local purge="${1:-}"

  # 程式檔案 (uninstall / purge 都會清)
  info "移除 $INSTALL_PREFIX/opencode-litellm"
  rm -f "$INSTALL_PREFIX/opencode-litellm"
  info "移除 $CONFIG_DIR/litellm-sync.sh"
  rm -f "$CONFIG_DIR/litellm-sync.sh"
  info "移除 $CONFIG_DIR/commands/litellm-{sync,doctor}.md"
  rm -f "$CONFIG_DIR/commands/litellm-sync.md" "$CONFIG_DIR/commands/litellm-doctor.md"

  if [[ "$purge" == "purge" ]]; then
    info "purge: 移除 $ENV_FILE / $CONFIG_DIR/litellm-key / $CACHE_DIR/litellm-sync.log"
    rm -f "$ENV_FILE" "$CONFIG_DIR/litellm-key" "$CACHE_DIR/litellm-sync.log"
    yellow "保留 $CONFIG_DIR/opencode.json 不動 (內含使用者其他 provider / 設定)。"
    yellow "若要清除 provider.litellm 區塊請手動編輯該檔。"
  else
    info "保留設定 / token / log (用 --purge 可一併刪除)"
  fi
  green "✓ 已移除"
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  purge)     do_uninstall purge ;;
esac
