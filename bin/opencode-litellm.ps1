# opencode-litellm — 把 LiteLLM 模型清單整合進 opencode (Windows / PowerShell)
#
# 用法:
#   opencode-litellm                啟動 opencode (首次會引導設定 + 同步模型)
#   opencode-litellm sync           重新同步模型清單到 opencode.json
#   opencode-litellm config         互動式修改 API key / URL
#   opencode-litellm doctor         檢查環境設定狀態
#   opencode-litellm --help         顯示說明
#   opencode-litellm --version      顯示版本

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

$VERSION               = '0.1.0'
$DEFAULT_PROVIDER_NAME = 'LiteLLM'
$DEFAULT_BASE_URL      = 'https://litellm-server.pic-ai.work'

$ConfigDir   = Join-Path $env:APPDATA      'opencode'
$CacheDir    = Join-Path $env:LOCALAPPDATA 'opencode'
$EnvFile     = Join-Path $ConfigDir 'litellm.env'
$ConfigFile  = Join-Path $ConfigDir 'opencode.json'
$KeyFile     = Join-Path $ConfigDir 'litellm-key'
$SyncScript  = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'litellm-sync.ps1'

function Write-LInfo { param([string]$Msg) Write-Host "[opencode-litellm] $Msg" }
function Write-LWarn { param([string]$Msg) Write-Host "[opencode-litellm] WARN: $Msg" -ForegroundColor Yellow }
function Write-LErr  { param([string]$Msg) Write-Host "[opencode-litellm] ERROR: $Msg" -ForegroundColor Red }
function Write-LOk   { param([string]$Msg) Write-Host "[opencode-litellm] OK $Msg" -ForegroundColor Green }

# .env 讀寫: KEY=VALUE 一行一筆,# 開頭為註解
function Read-EnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trim = $line.Trim()
        if (-not $trim -or $trim.StartsWith('#')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $trim.Substring(0, $idx).Trim()
        $v = $trim.Substring($idx + 1).Trim()
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

LITELLM_BASE_URL=https://litellm-server.pic-ai.work
LITELLM_PROVIDER_NAME=LiteLLM

# === 可選 ===
# LITELLM_PROVIDER_ID=litellm
# LITELLM_TIMEOUT=10
'@
    Set-Content -LiteralPath $EnvFile -Value $template -Encoding UTF8
}

function Update-EnvKey {
    param([string]$Key, [string]$Value)
    Ensure-EnvFile
    $lines = Get-Content -LiteralPath $EnvFile -Encoding UTF8
    $updated = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match "^\s*#?\s*$([regex]::Escape($Key))\s*=") {
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

# 寫入 API token (無 BOM + 無結尾換行,並設 ACL 僅本人可讀)
function Write-KeyFile {
    param([string]$Value)
    $dir = Split-Path -Parent $KeyFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$KeyFile.tmp.$(Get-Random)"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $Value, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $KeyFile -Force
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
        Write-LWarn "無法設定 $KeyFile 的 ACL: $($_.Exception.Message)"
    }
}

function Load-Config {
    $envMap = Read-EnvFile -Path $EnvFile

    $script:LITELLM_BASE_URL      = if ($envMap.ContainsKey('LITELLM_BASE_URL'))      { $envMap['LITELLM_BASE_URL'] }      else { '' }
    $script:LITELLM_PROVIDER_ID   = if ($envMap.ContainsKey('LITELLM_PROVIDER_ID'))   { $envMap['LITELLM_PROVIDER_ID'] }   else { 'litellm' }
    $script:LITELLM_PROVIDER_NAME = if ($envMap.ContainsKey('LITELLM_PROVIDER_NAME')) { $envMap['LITELLM_PROVIDER_NAME'] } else { $DEFAULT_PROVIDER_NAME }
    $script:LITELLM_TIMEOUT       = if ($envMap.ContainsKey('LITELLM_TIMEOUT'))       { $envMap['LITELLM_TIMEOUT'] }       else { '10' }

    $script:LITELLM_API_KEY = if (Test-Path -LiteralPath $KeyFile) {
        (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8) -replace "`r?`n$", ''
    } else { '' }

    # 把設定 export 給 sync 子行程
    $env:LITELLM_BASE_URL      = $script:LITELLM_BASE_URL
    $env:LITELLM_API_KEY       = $script:LITELLM_API_KEY
    $env:LITELLM_PROVIDER_ID   = $script:LITELLM_PROVIDER_ID
    $env:LITELLM_PROVIDER_NAME = $script:LITELLM_PROVIDER_NAME
    $env:LITELLM_TIMEOUT       = $script:LITELLM_TIMEOUT
    $env:LITELLM_KEY_FILE      = $KeyFile
    $env:OPENCODE_CONFIG_FILE  = $ConfigFile
}

function Test-ApiKey  { return [bool]$script:LITELLM_API_KEY }
# 視為「未設定」的 URL: 空字串 / 範例值
function Test-BaseUrl {
    return ($script:LITELLM_BASE_URL -and `
            $script:LITELLM_BASE_URL -ne 'https://litellm.example.com' -and `
            $script:LITELLM_BASE_URL -ne 'https://litellm.example.com/')
}
function Test-Url { param([string]$Url) return ($Url -match '^https?://\S+$') }

function Test-ConfigHasProvider {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }
    try {
        $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    $prov = $cfg.provider.$($script:LITELLM_PROVIDER_ID)
    if (-not $prov -or -not $prov.models) { return $false }
    return (($prov.models.PSObject.Properties | Measure-Object).Count -gt 0)
}

function Require-Credentials {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        Write-LErr "找不到 sync 腳本: $SyncScript"
        Write-LErr '請重新執行安裝: irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex'
        return $false
    }
    if (-not (Test-ApiKey) -or -not (Test-BaseUrl)) {
        Write-LErr 'LITELLM_API_KEY 或 LITELLM_BASE_URL 尚未設定。'
        Write-LInfo "執行 'opencode-litellm config' 以互動式設定。"
        return $false
    }
    return $true
}

function Mask-Key {
    param([string]$Key)
    if ($Key.Length -gt 10) {
        return "$($Key.Substring(0,6))...$($Key.Substring($Key.Length - 2, 2))"
    }
    return '******'
}

function Prompt-ApiKey {
    param([switch]$AllowKeep)
    while ($true) {
        $prompt = if ($AllowKeep -and (Test-ApiKey)) {
            "新的 LITELLM_API_KEY (Enter 保留 $(Mask-Key $script:LITELLM_API_KEY))"
        } else {
            'LITELLM_API_KEY (你的 LiteLLM API key)'
        }
        $value = Read-Host $prompt
        if (-not $value) {
            if ($AllowKeep) { return }
            Write-LWarn '不能為空,請重新輸入 (或 Ctrl+C 中止)'
            continue
        }
        Write-KeyFile -Value $value
        $script:LITELLM_API_KEY = $value
        $env:LITELLM_API_KEY = $value
        Write-LOk "已儲存 LITELLM_API_KEY -> $KeyFile"
        return
    }
}

function Prompt-BaseUrl {
    param([switch]$AllowKeep)
    while ($true) {
        $prompt = if ($AllowKeep -and (Test-BaseUrl)) {
            "新的 LITELLM_BASE_URL (Enter 保留 $($script:LITELLM_BASE_URL))"
        } else {
            "LITELLM_BASE_URL (Enter 套用預設 $DEFAULT_BASE_URL)"
        }
        $value = Read-Host $prompt
        if (-not $value) {
            if ($AllowKeep) { return }
            $value = $DEFAULT_BASE_URL
        }
        $value = $value.TrimEnd('/')
        if (-not (Test-Url $value)) {
            Write-LWarn 'URL 必須以 http:// 或 https:// 開頭,請重新輸入'
            continue
        }
        Update-EnvKey -Key 'LITELLM_BASE_URL' -Value $value
        $script:LITELLM_BASE_URL = $value
        $env:LITELLM_BASE_URL = $value
        Write-LOk "已儲存 LITELLM_BASE_URL ($value)"
        return
    }
}

function Prompt-ProviderName {
    param([switch]$AllowKeep)
    $current = if ($script:LITELLM_PROVIDER_NAME) { $script:LITELLM_PROVIDER_NAME } else { $DEFAULT_PROVIDER_NAME }
    $prompt = if ($AllowKeep) {
        "新的 LITELLM_PROVIDER_NAME (opencode 選單顯示名稱,Enter 保留 $current)"
    } else {
        "LITELLM_PROVIDER_NAME (opencode 選單顯示名稱,Enter 套用預設 $DEFAULT_PROVIDER_NAME)"
    }
    $value = Read-Host $prompt
    if (-not $value) {
        if ($AllowKeep) { return }
        $value = $DEFAULT_PROVIDER_NAME
    }
    Update-EnvKey -Key 'LITELLM_PROVIDER_NAME' -Value $value
    $script:LITELLM_PROVIDER_NAME = $value
    $env:LITELLM_PROVIDER_NAME = $value
    Write-LOk "已儲存 LITELLM_PROVIDER_NAME ($value)"
}

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
    }
    Write-LErr "同步失敗 (exit $rc),詳情請見 $CacheDir\litellm-sync.log"
    Write-LInfo "若 URL 或 token 錯誤,執行 'opencode-litellm config' 修正後重試"
    return 1
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

    Write-Host -NoNewline '  opencode 指令          : '
    $oc = Get-Command 'opencode' -ErrorAction SilentlyContinue
    if ($oc) { Write-Host "OK $($oc.Source)" -ForegroundColor Green }
    else     { Write-Host 'MISSING 找不到 opencode' -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  litellm-sync.ps1       : '
    if (Test-Path -LiteralPath $SyncScript) { Write-Host "OK $SyncScript" -ForegroundColor Green }
    else { Write-Host "MISSING $SyncScript" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  litellm.env            : '
    if (Test-Path -LiteralPath $EnvFile) {
        Write-Host "OK $EnvFile" -ForegroundColor Green
    } else {
        Write-Host "MISSING 不存在 (跑 'opencode-litellm config' 即可建立)" -ForegroundColor Red
        $issues++
    }

    Write-Host -NoNewline '  LITELLM_API_KEY        : '
    if (Test-ApiKey) { Write-Host "OK 已設定 ($(Mask-Key $script:LITELLM_API_KEY))" -ForegroundColor Green }
    else { Write-Host "MISSING 未設定 (跑 'opencode-litellm config')" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  LITELLM_BASE_URL       : '
    if (Test-BaseUrl) { Write-Host "OK $($script:LITELLM_BASE_URL)" -ForegroundColor Green }
    else { Write-Host "MISSING 未設定 (跑 'opencode-litellm config')" -ForegroundColor Red; $issues++ }

    Write-Host -NoNewline '  LITELLM_PROVIDER_NAME  : '
    Write-Host "OK $($script:LITELLM_PROVIDER_NAME)" -ForegroundColor Green

    Write-Host -NoNewline '  opencode.json          : '
    if (Test-ConfigHasProvider) {
        Write-Host "OK $ConfigFile (含 provider.$($script:LITELLM_PROVIDER_ID))" -ForegroundColor Green
    } else {
        Write-Host "MISSING 缺 provider.$($script:LITELLM_PROVIDER_ID) (跑 'opencode-litellm sync')" -ForegroundColor Red
        $issues++
    }

    Write-Host -NoNewline '  litellm-key (token)    : '
    if (Test-Path -LiteralPath $KeyFile) {
        Write-Host "OK $KeyFile" -ForegroundColor Green
    } else {
        Write-Host "MISSING 不存在 (跑 'opencode-litellm config' 即可建立)" -ForegroundColor Red
        $issues++
    }

    Write-Host ''
    if ($issues -eq 0) {
        Write-LOk "一切正常,可以直接打 'opencode' 啟動。"
        return 0
    }
    Write-LErr "發現 $issues 個問題,請依上面提示修正。"
    return 1
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
  opencode-litellm <opencode args>   參數會原樣傳給 opencode

子指令:
  sync          重新同步 LiteLLM 模型清單到 opencode.json
  config        互動式修改 API key / URL / provider name 後重新同步
  doctor        檢查環境與設定狀態
  --help, -h    顯示本說明
  --version     顯示版本

設定檔:
  $EnvFile
  $KeyFile  (僅本人可讀)
  $ConfigFile  (opencode 主設定)
"@
}

# === 主流程 ===
Load-Config

$first = if ($Arguments -and $Arguments.Count -gt 0) { $Arguments[0] } else { '' }

switch -Regex ($first) {
    '^sync$'                    { exit (Run-Sync) }
    '^(config|configure)$'      { exit (Run-Config) }
    '^(doctor|check|status)$'   { exit (Run-Doctor) }
    '^(-h|--help|help)$'        { Show-Help; exit 0 }
    '^(--version|version)$'     { Write-Host "opencode-litellm v$VERSION"; exit 0 }
}

Run-FirstTimeSetupIfNeeded

if (-not (Test-ConfigHasProvider)) {
    Write-LInfo '首次啟動,先取得模型清單...'
    if ((Run-Sync) -ne 0) {
        Write-LErr '無法取得模型清單,中止啟動。'
        Write-LInfo "修正設定後請執行: opencode-litellm config"
        exit 1
    }
}

if (-not (Get-Command 'opencode' -ErrorAction SilentlyContinue)) {
    Write-LErr '找不到 opencode 指令。請重新執行安裝程式以自動安裝 opencode。'
    exit 127
}

if ($Arguments -and $Arguments.Count -gt 0) {
    & opencode @Arguments
} else {
    & opencode
}
exit $LASTEXITCODE
