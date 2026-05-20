# opencode-litellm — 把 LiteLLM 模型清單整合進 opencode (Windows / PowerShell)
#
# 用法 (詳見 -Help):
#   opencode-litellm                啟動 opencode (首次會引導設定 + 同步模型)
#   opencode-litellm sync           重新同步模型清單到 opencode.json
#   opencode-litellm config         互動式修改 API key / URL
#   opencode-litellm doctor         檢查環境設定狀態
#   opencode-litellm --version      顯示版本
#   opencode-litellm --help         顯示說明

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 常數 & 路徑
# ============================================================================
$VERSION              = '0.1.0'
$PLACEHOLDER_KEY      = 'sk-please-replace-me'
$PLACEHOLDER_URL      = 'https://litellm.example.com'
$DEFAULT_PROVIDER_NAME = 'LiteLLM'

# 允許用環境變數覆寫 (給測試用)
$ConfigDir   = if ($env:LITELLM_CONFIG_DIR)  { $env:LITELLM_CONFIG_DIR }  else { Join-Path $env:APPDATA      'opencode' }
$CacheDir    = if ($env:LITELLM_CACHE_DIR)   { $env:LITELLM_CACHE_DIR }   else { Join-Path $env:LOCALAPPDATA 'opencode' }
$EnvFile     = if ($env:LITELLM_ENV_FILE)    { $env:LITELLM_ENV_FILE }    else { Join-Path $ConfigDir 'litellm.env' }
$ConfigFile  = if ($env:OPENCODE_CONFIG_FILE){ $env:OPENCODE_CONFIG_FILE } else { Join-Path $ConfigDir 'opencode.json' }
$KeyFile     = if ($env:LITELLM_KEY_FILE)    { $env:LITELLM_KEY_FILE }    else { Join-Path $ConfigDir 'litellm-key' }

# Sync 腳本: 跟自己同一個安裝樹下的 lib 資料夾
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$DefaultSync = Join-Path (Split-Path -Parent $ScriptDir) 'lib\litellm-sync.ps1'
$SyncScript  = if ($env:LITELLM_SYNC_SCRIPT) { $env:LITELLM_SYNC_SCRIPT } else { $DefaultSync }

# ============================================================================
# 輸出工具
# ============================================================================
function Write-LInfo { param([string]$Msg) Write-Host "[opencode-litellm] $Msg" }
function Write-LWarn { param([string]$Msg) Write-Host "[opencode-litellm] WARN: $Msg" -ForegroundColor Yellow }
function Write-LErr  { param([string]$Msg) Write-Host "[opencode-litellm] ERROR: $Msg" -ForegroundColor Red }
function Write-LOk   { param([string]$Msg) Write-Host "[opencode-litellm] OK $Msg" -ForegroundColor Green }

# ============================================================================
# .env 讀寫
#   檔案格式: KEY=VALUE 一行一筆,# 開頭為註解
# ============================================================================
function Read-EnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        if ($trim.StartsWith('#')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $trim.Substring(0, $idx).Trim()
        $v = $trim.Substring($idx + 1).Trim()
        # 去除可能的兩端引號
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $result[$k] = $v
    }
    return $result
}

function Ensure-EnvFile {
    if (Test-Path -LiteralPath $EnvFile) { return }
    $dir = Split-Path -Parent $EnvFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $template = @'
# opencode-litellm 設定檔 (KEY=VALUE,不要寫 shell 語法)
#
# API key 不存在這裡,只存在 %APPDATA%\opencode\litellm-key。
# 改 key 請執行: opencode-litellm config

LITELLM_BASE_URL=https://litellm.example.com

# === 可選 ===
# LITELLM_PROVIDER_ID=litellm
LITELLM_PROVIDER_NAME=LiteLLM
# LITELLM_TIMEOUT=10
'@
    Set-Content -LiteralPath $EnvFile -Value $template -Encoding UTF8
}

# 寫入 / 更新 .env 的單一 KEY=VALUE,保留註解
function Update-EnvKey {
    param([string]$Key, [string]$Value)
    Ensure-EnvFile
    $lines = Get-Content -LiteralPath $EnvFile
    $updated = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=") {
            $updated = $true
            "$Key=$Value"
        } elseif ($line -match "^\s*#\s*$([regex]::Escape($Key))\s*=") {
            $updated = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $updated) {
        $newLines = @($newLines) + "$Key=$Value"
    }
    Set-Content -LiteralPath $EnvFile -Value $newLines -Encoding UTF8
}

# 把 token 寫到 KeyFile (原子寫入)
function Write-KeyFile {
    param([string]$Value)
    $dir = Split-Path -Parent $KeyFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$KeyFile.tmp.$(Get-Random)"
    # 寫入「無 BOM、無結尾換行」的純文字,避免 token 比對失敗
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $Value, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $KeyFile -Force

    # 限制只有當前使用者可讀 (Windows ACL)
    try {
        $acl = Get-Acl -LiteralPath $KeyFile
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $KeyFile -AclObject $acl
    } catch {
        Write-LWarn "無法設定 $KeyFile 的 ACL (僅本人可讀): $($_.Exception.Message)"
    }
}

# 從舊版 env 把 LITELLM_API_KEY 搬到 KeyFile 並從 env 移除
function Migrate-EnvKeyToFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return }
    $envMap = Read-EnvFile -Path $EnvFile
    if (-not $envMap.ContainsKey('LITELLM_API_KEY')) { return }
    $envKey = $envMap['LITELLM_API_KEY']
    if (-not $envKey -or $envKey -eq $PLACEHOLDER_KEY) { return }

    $hasKey = (Test-Path -LiteralPath $KeyFile) -and ((Get-Item -LiteralPath $KeyFile).Length -gt 0)
    if (-not $hasKey) {
        Write-LInfo "偵測到舊版設定: 將 API key 從 $EnvFile 搬到 $KeyFile (更安全)"
        Write-KeyFile -Value $envKey
    } else {
        Write-LInfo "偵測到舊版設定: $EnvFile 含 LITELLM_API_KEY,將其移除 (KeyFile 已有 token)"
    }

    # 從 env 移除 LITELLM_API_KEY 行
    $lines = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -notmatch '^\s*LITELLM_API_KEY\s*=' }
    Set-Content -LiteralPath $EnvFile -Value $lines -Encoding UTF8
    Write-LOk "遷移完成,API key 現在只存在 $KeyFile"
}

# ============================================================================
# 載入當前設定到 script scope 變數
# ============================================================================
function Load-Config {
    $envMap = if (Test-Path -LiteralPath $EnvFile) { Read-EnvFile -Path $EnvFile } else { @{} }

    # env 變數 (process) > .env 檔
    $script:LITELLM_BASE_URL      = if ($env:LITELLM_BASE_URL)      { $env:LITELLM_BASE_URL }      elseif ($envMap.ContainsKey('LITELLM_BASE_URL'))      { $envMap['LITELLM_BASE_URL'] }      else { '' }
    $script:LITELLM_PROVIDER_ID   = if ($env:LITELLM_PROVIDER_ID)   { $env:LITELLM_PROVIDER_ID }   elseif ($envMap.ContainsKey('LITELLM_PROVIDER_ID'))   { $envMap['LITELLM_PROVIDER_ID'] }   else { 'litellm' }
    $script:LITELLM_PROVIDER_NAME = if ($env:LITELLM_PROVIDER_NAME) { $env:LITELLM_PROVIDER_NAME } elseif ($envMap.ContainsKey('LITELLM_PROVIDER_NAME')) { $envMap['LITELLM_PROVIDER_NAME'] } else { $DEFAULT_PROVIDER_NAME }
    $script:LITELLM_TIMEOUT       = if ($env:LITELLM_TIMEOUT)       { $env:LITELLM_TIMEOUT }       elseif ($envMap.ContainsKey('LITELLM_TIMEOUT'))       { $envMap['LITELLM_TIMEOUT'] }       else { '10' }

    # API key: env 變數優先,否則讀 KeyFile,再否則讀 .env (相容舊版)
    if ($env:LITELLM_API_KEY) {
        $script:LITELLM_API_KEY = $env:LITELLM_API_KEY
    } elseif (Test-Path -LiteralPath $KeyFile) {
        $script:LITELLM_API_KEY = (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8) -replace "`r?`n$", ''
    } elseif ($envMap.ContainsKey('LITELLM_API_KEY')) {
        $script:LITELLM_API_KEY = $envMap['LITELLM_API_KEY']
    } else {
        $script:LITELLM_API_KEY = ''
    }

    # 給 sync 腳本用
    $env:LITELLM_BASE_URL      = $script:LITELLM_BASE_URL
    $env:LITELLM_API_KEY       = $script:LITELLM_API_KEY
    $env:LITELLM_PROVIDER_ID   = $script:LITELLM_PROVIDER_ID
    $env:LITELLM_PROVIDER_NAME = $script:LITELLM_PROVIDER_NAME
    $env:LITELLM_TIMEOUT       = $script:LITELLM_TIMEOUT
    $env:LITELLM_KEY_FILE      = $KeyFile
    $env:OPENCODE_CONFIG_FILE  = $ConfigFile
}

# ============================================================================
# 狀態檢查
# ============================================================================
function Test-ApiKey  { return ($script:LITELLM_API_KEY -and $script:LITELLM_API_KEY -ne $PLACEHOLDER_KEY) }
function Test-BaseUrl { return ($script:LITELLM_BASE_URL -and $script:LITELLM_BASE_URL -ne $PLACEHOLDER_URL) }
function Test-Url     { param([string]$Url) return ($Url -match '^https?://\S+$') }

function Test-ConfigHasProvider {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }
    try {
        $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    $provId = $script:LITELLM_PROVIDER_ID
    if (-not $cfg.provider) { return $false }
    $prov = $cfg.provider.$provId
    if (-not $prov) { return $false }
    $models = $prov.models
    if (-not $models) { return $false }
    # PSCustomObject 需檢查 properties
    return (($models.PSObject.Properties | Measure-Object).Count -gt 0)
}

function Require-Credentials {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        Write-LErr "找不到 sync 腳本: $SyncScript"
        Write-LErr '請重新執行安裝: irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex'
        return $false
    }
    if (-not (Test-ApiKey) -or -not (Test-BaseUrl)) {
        Write-LErr 'LITELLM_API_KEY 或 LITELLM_BASE_URL 尚未設定。'
        Write-LInfo "執行 'opencode-litellm config' 以互動式設定 (推薦)。"
        return $false
    }
    return $true
}

# ============================================================================
# 互動式輸入
# ============================================================================
function Mask-Key {
    param([string]$Key)
    if ($Key.Length -gt 10) {
        return "$($Key.Substring(0,6))...$($Key.Substring($Key.Length - 2, 2))"
    } else {
        return '******'
    }
}

function Prompt-ApiKey {
    param([switch]$AllowKeep)
    while ($true) {
        if ($AllowKeep -and (Test-ApiKey)) {
            $prompt = "新的 LITELLM_API_KEY (Enter 保留 $(Mask-Key $script:LITELLM_API_KEY))"
        } else {
            $prompt = 'LITELLM_API_KEY (你的 LiteLLM API key)'
        }
        $input = Read-Host $prompt
        if (-not $input) {
            if ($AllowKeep) { return }
            Write-LWarn '不能為空,請重新輸入 (或 Ctrl+C 中止)'
            continue
        }
        Write-KeyFile -Value $input
        $script:LITELLM_API_KEY = $input
        $env:LITELLM_API_KEY = $input
        Write-LOk "已儲存 LITELLM_API_KEY -> $KeyFile"
        return
    }
}

function Prompt-BaseUrl {
    param([switch]$AllowKeep)
    while ($true) {
        if ($AllowKeep -and (Test-BaseUrl)) {
            $prompt = "新的 LITELLM_BASE_URL (Enter 保留 $($script:LITELLM_BASE_URL))"
        } else {
            $prompt = 'LITELLM_BASE_URL (例如 https://litellm.example.com)'
        }
        $input = Read-Host $prompt
        if (-not $input) {
            if ($AllowKeep) { return }
            Write-LWarn '不能為空,請重新輸入 (或 Ctrl+C 中止)'
            continue
        }
        $input = $input.TrimEnd('/')
        if (-not (Test-Url $input)) {
            Write-LWarn 'URL 必須以 http:// 或 https:// 開頭,請重新輸入'
            continue
        }
        Update-EnvKey -Key 'LITELLM_BASE_URL' -Value $input
        $script:LITELLM_BASE_URL = $input
        $env:LITELLM_BASE_URL = $input
        Write-LOk '已儲存 LITELLM_BASE_URL'
        return
    }
}

function Prompt-ProviderName {
    param([switch]$AllowKeep)
    $current = if ($script:LITELLM_PROVIDER_NAME) { $script:LITELLM_PROVIDER_NAME } else { $DEFAULT_PROVIDER_NAME }
    if ($AllowKeep) {
        $prompt = "新的 LITELLM_PROVIDER_NAME (opencode 選單顯示名稱,Enter 保留 $current)"
    } else {
        $prompt = "LITELLM_PROVIDER_NAME (opencode 選單顯示名稱,Enter 套用預設 $DEFAULT_PROVIDER_NAME)"
    }
    $input = Read-Host $prompt
    if (-not $input) {
        if ($AllowKeep) { return }
        $input = $DEFAULT_PROVIDER_NAME
    }
    Update-EnvKey -Key 'LITELLM_PROVIDER_NAME' -Value $input
    $script:LITELLM_PROVIDER_NAME = $input
    $env:LITELLM_PROVIDER_NAME = $input
    Write-LOk "已儲存 LITELLM_PROVIDER_NAME ($input)"
}

# ============================================================================
# 子指令
# ============================================================================
function Run-Sync {
    if (-not (Require-Credentials)) { return 1 }
    Write-LInfo "同步 LiteLLM 模型清單 -> $ConfigFile"
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript
        $rc = $LASTEXITCODE
    } catch {
        Write-LErr "同步失敗: $($_.Exception.Message)"
        return 1
    }
    if ($rc -eq 0) {
        Write-LOk '同步完成'
        return 0
    } else {
        Write-LErr "同步失敗 (exit $rc),詳情請見 $CacheDir\litellm-sync.log"
        Write-LInfo "若 URL 或 token 錯誤,執行 'opencode-litellm config' 修正後重試"
        return 1
    }
}

function Run-Config {
    Write-LInfo '重新設定 LiteLLM 連線資訊'
    Write-Host ''
    Ensure-EnvFile
    Prompt-ApiKey  -AllowKeep
    Write-Host ''
    Prompt-BaseUrl -AllowKeep
    Write-Host ''
    Prompt-ProviderName -AllowKeep
    Write-Host ''
    Write-LInfo '套用新設定並同步模型...'
    Write-Host ''
    return (Run-Sync)
}

function Run-Doctor {
    $issues = 0
    Write-Host '[opencode-litellm] 環境檢查'
    Write-Host ''

    Write-Host -NoNewline '  opencode 指令       : '
    $oc = Get-Command 'opencode' -ErrorAction SilentlyContinue
    if ($oc) { Write-Host "OK $($oc.Source)" -ForegroundColor Green }
    else     { Write-Host 'MISSING 找不到 (scoop install opencode / choco install opencode / npm install -g opencode-ai)' -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  litellm-sync.ps1    : '
    if (Test-Path -LiteralPath $SyncScript) { Write-Host "OK $SyncScript" -ForegroundColor Green }
    else { Write-Host "MISSING $SyncScript" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  litellm.env         : '
    if (Test-Path -LiteralPath $EnvFile) {
        Write-Host "OK $EnvFile" -ForegroundColor Green
        $em = Read-EnvFile -Path $EnvFile
        if ($em.ContainsKey('LITELLM_API_KEY')) {
            Write-Host "      `u{2517} WARN 偵測到 LITELLM_API_KEY 寫在 env 裡 (跑 'opencode-litellm config' 會自動搬到 $KeyFile)" -ForegroundColor Yellow
        }
    } elseif ((Test-ApiKey) -and (Test-BaseUrl)) {
        Write-Host 'INFO 不存在 (但環境變數已 export,可運作)'
    } else {
        Write-Host "MISSING 不存在 (跑 'opencode-litellm config' 即可建立)" -ForegroundColor Red
        $issues++
    }

    Write-Host -NoNewline '  LITELLM_API_KEY     : '
    if (Test-ApiKey) { Write-Host "OK 已設定 ($(Mask-Key $script:LITELLM_API_KEY))" -ForegroundColor Green }
    else { Write-Host "MISSING 未設定 (跑 'opencode-litellm config')" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  LITELLM_BASE_URL    : '
    if (Test-BaseUrl) { Write-Host "OK $($script:LITELLM_BASE_URL)" -ForegroundColor Green }
    else { Write-Host "MISSING 未設定 (跑 'opencode-litellm config')" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  LITELLM_PROVIDER_NAME : '
    Write-Host "OK $($script:LITELLM_PROVIDER_NAME) (opencode 選單顯示名稱)" -ForegroundColor Green

    Write-Host -NoNewline '  opencode.json       : '
    if (Test-ConfigHasProvider) {
        Write-Host "OK $ConfigFile (含 provider.$($script:LITELLM_PROVIDER_ID))" -ForegroundColor Green
    } else {
        Write-Host "MISSING 缺 provider.$($script:LITELLM_PROVIDER_ID) (跑 'opencode-litellm sync')" -ForegroundColor Red
        $issues++
    }

    Write-Host -NoNewline '  litellm-key (token) : '
    if (Test-Path -LiteralPath $KeyFile) {
        Write-Host "OK $KeyFile" -ForegroundColor Green
    } else {
        Write-Host "MISSING 不存在 (跑 'opencode-litellm sync' 即可建立)" -ForegroundColor Red
        $issues++
    }

    Write-Host ''
    if ($issues -eq 0) {
        Write-LOk "一切正常,可以直接打 'opencode' 或 'opencode-litellm' 啟動。"
        return 0
    } else {
        Write-LErr "發現 $issues 個問題,請依上面提示修正。"
        return 1
    }
}

function Run-FirstTimeSetupIfNeeded {
    if ((Test-ApiKey) -and (Test-BaseUrl)) { return }

    Write-LInfo '尚未完成設定,請依序輸入:'
    Write-Host ''
    if (-not (Test-ApiKey))  { Prompt-ApiKey  }
    Write-Host ''
    if (-not (Test-BaseUrl)) { Prompt-BaseUrl }
    Write-Host ''
    Prompt-ProviderName
    Write-Host ''
    Write-LInfo '設定完成,繼續啟動...'
    Write-Host ''
}

function Show-Help {
    @"
opencode-litellm v$VERSION  (Windows / PowerShell)

用法:
  opencode-litellm                   啟動 opencode (首次會引導設定 + 同步模型)
  opencode-litellm <opencode args>   參數會原樣傳給 opencode (如 'run "hello"')

子指令:
  sync          重新同步 LiteLLM 模型清單到 opencode.json
  config        互動式修改 LITELLM_API_KEY / LITELLM_BASE_URL / LITELLM_PROVIDER_NAME 後重新同步
  doctor        檢查環境與設定狀態
  --help, -h    顯示本說明
  --version     顯示版本

設定檔:
  $EnvFile       (LITELLM_BASE_URL / LITELLM_PROVIDER_NAME 等非機密設定)
  $KeyFile        (純 API token,opencode.json 用 {file:...} 引用)
  $ConfigFile    (opencode 主設定,含 provider.$($script:LITELLM_PROVIDER_ID))

詳細文件: https://github.com/Bear1203/opencode-litellm-0504
"@
}

# ============================================================================
# 主流程
# ============================================================================
Load-Config

$first = if ($Arguments -and $Arguments.Count -gt 0) { $Arguments[0] } else { '' }
$rest  = if ($Arguments -and $Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }

# 舊版 → 新版資料遷移 (env 內含 LITELLM_API_KEY 時搬到 KeyFile)
# help / version 不需要動到設定,可略過
switch -Regex ($first) {
    '^(-h|--help|help|--version|version)$' { }
    default { Migrate-EnvKeyToFile; Load-Config }
}

switch -Regex ($first) {
    '^sync$'                    { exit (Run-Sync) }
    '^(config|configure)$'      { exit (Run-Config) }
    '^(doctor|check|status)$'   { exit (Run-Doctor) }
    '^(-h|--help|help)$'        { Show-Help; exit 0 }
    '^(--version|version)$'     { Write-Host "opencode-litellm v$VERSION"; exit 0 }
}

# 正常啟動路徑
Run-FirstTimeSetupIfNeeded

if (-not (Test-ConfigHasProvider)) {
    Write-LInfo '首次啟動,先取得模型清單...'
    if ((Run-Sync) -ne 0) {
        Write-LErr '無法取得模型清單,中止啟動。'
        Write-LInfo '修正設定後請執行: opencode-litellm config'
        exit 1
    }
}

if (-not (Get-Command 'opencode' -ErrorAction SilentlyContinue)) {
    Write-Host @"
[opencode-litellm] ERROR: 找不到 opencode 指令。

可能原因 / 解法:
  1. 還沒安裝 opencode (任選一種方式)
       scoop install opencode
       choco install opencode
       npm install -g opencode-ai
       或從 https://github.com/anomalyco/opencode/releases 下載 opencode-windows-x64.zip
  2. 已安裝但不在 PATH (本工具自動安裝時會放到 %USERPROFILE%\.opencode\bin)
       將該資料夾加入使用者 PATH 後重新開啟 Terminal

模型清單與 token 已寫入,opencode 上線後即可直接使用,不必再跑此 wrapper。
"@ -ForegroundColor Red
    exit 127
}

# 把參數原樣傳給 opencode
if ($Arguments -and $Arguments.Count -gt 0) {
    & opencode @Arguments
} else {
    & opencode
}
exit $LASTEXITCODE
