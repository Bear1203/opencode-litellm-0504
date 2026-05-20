# litellm-sync.ps1
#
# 從 LiteLLM 取得可用模型清單,merge 到使用者的 opencode.json
# (只更新 provider.<id> 區塊,其他設定原樣保留),並把 API token 寫入
# 獨立檔案讓 opencode.json 用 {file:...} 引用。
#
# Env 變數:
#   LITELLM_BASE_URL       (必填) LiteLLM server URL
#   LITELLM_API_KEY        (必填) Bearer token (或從 LITELLM_KEY_FILE 讀)
#   LITELLM_PROVIDER_ID    (預設 litellm)
#   LITELLM_PROVIDER_NAME  (預設 LiteLLM)
#   LITELLM_TIMEOUT        (預設 10) HTTP timeout (秒)
#   LITELLM_LOG_FILE       (預設 %LOCALAPPDATA%\opencode\litellm-sync.log)
#   OPENCODE_CONFIG_FILE   (預設 %APPDATA%\opencode\opencode.json)
#   LITELLM_KEY_FILE       (預設 %APPDATA%\opencode\litellm-key)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ============================================================================
# 解析環境變數
# ============================================================================
$BaseUrl      = if ($env:LITELLM_BASE_URL)     { $env:LITELLM_BASE_URL }     else { '' }
$ApiKey       = if ($env:LITELLM_API_KEY)      { $env:LITELLM_API_KEY }      else { '' }
$ProviderId   = if ($env:LITELLM_PROVIDER_ID)  { $env:LITELLM_PROVIDER_ID }  else { 'litellm' }
$ProviderName = if ($env:LITELLM_PROVIDER_NAME){ $env:LITELLM_PROVIDER_NAME }else { 'LiteLLM' }
$TimeoutSec   = if ($env:LITELLM_TIMEOUT)      { [int]$env:LITELLM_TIMEOUT } else { 10 }

$ConfigFile = if ($env:OPENCODE_CONFIG_FILE) { $env:OPENCODE_CONFIG_FILE } else { Join-Path $env:APPDATA 'opencode\opencode.json' }
$KeyFile    = if ($env:LITELLM_KEY_FILE)     { $env:LITELLM_KEY_FILE }     else { Join-Path $env:APPDATA 'opencode\litellm-key' }
$LogFile    = if ($env:LITELLM_LOG_FILE)     { $env:LITELLM_LOG_FILE }     else { Join-Path $env:LOCALAPPDATA 'opencode\litellm-sync.log' }

foreach ($d in @((Split-Path -Parent $LogFile), (Split-Path -Parent $ConfigFile), (Split-Path -Parent $KeyFile))) {
    if ($d -and -not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Msg)
    $line = "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')] [litellm-sync] $Msg"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    [Console]::Error.WriteLine($line)
}

# ============================================================================
# 取得 API key (env 沒給就讀 KEY_FILE)
# ============================================================================
if (-not $ApiKey -and (Test-Path -LiteralPath $KeyFile)) {
    $ApiKey = (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8) -replace "`r?`n$", ''
}

if (-not $BaseUrl) { Write-Log 'ERROR: LITELLM_BASE_URL 未設定'; exit 1 }
if (-not $ApiKey)  { Write-Log "ERROR: LITELLM_API_KEY 未設定 (env 變數或 $KeyFile 都沒有)"; exit 1 }

$BaseUrl = $BaseUrl.TrimEnd('/')

# ============================================================================
# 1. 取得模型清單
# ============================================================================
$modelsUrl = "$BaseUrl/v1/models"
Write-Log "GET $modelsUrl"

try {
    $resp = Invoke-RestMethod `
        -Uri $modelsUrl `
        -Headers @{ Authorization = "Bearer $ApiKey" } `
        -TimeoutSec $TimeoutSec `
        -ErrorAction Stop
} catch {
    Write-Log "ERROR: API 沒有回應或回應錯誤: $($_.Exception.Message)"
    Write-Log '       請檢查 LITELLM_BASE_URL / LITELLM_API_KEY 是否正確,以及網路連線'
    exit 1
}

if (-not $resp -or -not $resp.data) {
    Write-Log 'ERROR: API 回應沒有 data 欄位'
    exit 1
}

# ============================================================================
# 2. 寫入 key 檔
# ============================================================================
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($KeyFile, $ApiKey, $utf8NoBom)
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
    Write-Log "WARN: 無法設定 $KeyFile 的 ACL (僅本人可讀): $($_.Exception.Message)"
}
Write-Log "API key 已寫入 $KeyFile"

# ============================================================================
# 3. 解析模型清單並 merge 到 opencode.json
# ============================================================================
$modelIds = @($resp.data | Where-Object { $_.id -is [string] } | ForEach-Object { $_.id } | Sort-Object -Unique)
if (-not $modelIds -or $modelIds.Count -eq 0) {
    Write-Log 'ERROR: 模型清單為空,放棄寫入'
    exit 1
}

# 讀取既有 opencode.json (只 merge 不覆蓋)
$config = $null
if (Test-Path -LiteralPath $ConfigFile) {
    try {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) {
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
        }
    } catch {
        Write-Log "ERROR: $ConfigFile JSON 解析失敗: $($_.Exception.Message)"
        Write-Log '       為避免破壞既有設定,中止寫入。請修正或刪除該檔後再試。'
        exit 1
    }
    if ($config -and ($config -isnot [PSCustomObject])) {
        Write-Log "WARN: $ConfigFile 不是 JSON object,將整個重建"
        $config = $null
    }
}
if (-not $config) {
    $config = [PSCustomObject]@{}
}

# ConvertFrom-Json 產生 PSCustomObject;以下用輔助函式設定屬性
function Set-Prop {
    param([Parameter(Mandatory)]$Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties[$Name]) {
        $Obj.$Name = $Value
    } else {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

# 確保 $schema 存在 (不覆蓋既有值)
if (-not $config.PSObject.Properties['$schema']) {
    Set-Prop -Obj $config -Name '$schema' -Value 'https://opencode.ai/config.json'
}

# 確保 provider 物件存在
if (-not $config.PSObject.Properties['provider']) {
    Set-Prop -Obj $config -Name 'provider' -Value ([PSCustomObject]@{})
}
$provider = $config.provider

# 組 models 字典
$modelsObj = [PSCustomObject]@{}
foreach ($mid in $modelIds) {
    $displayName = if ($mid.Contains('/')) { $mid.Substring($mid.IndexOf('/') + 1) } else { $mid }
    Set-Prop -Obj $modelsObj -Name $mid -Value ([PSCustomObject]@{ name = $displayName })
}

# 把 key file 路徑改寫成相對路徑 (用 ~ 開頭,opencode 支援)
$home = $env:USERPROFILE
$keyRef = if ($KeyFile.StartsWith($home + '\', [StringComparison]::OrdinalIgnoreCase) -or $KeyFile.StartsWith($home + '/', [StringComparison]::OrdinalIgnoreCase)) {
    '~' + $KeyFile.Substring($home.Length).Replace('\', '/')
} else {
    $KeyFile.Replace('\', '/')
}

$providerEntry = [PSCustomObject]@{
    npm     = '@ai-sdk/openai-compatible'
    name    = $ProviderName
    options = [PSCustomObject]@{
        baseURL = "$BaseUrl/v1"
        apiKey  = "{file:$keyRef}"
    }
    models  = $modelsObj
}

Set-Prop -Obj $provider -Name $ProviderId -Value $providerEntry

# ============================================================================
# 4. 原子寫入
# ============================================================================
$json = $config | ConvertTo-Json -Depth 20
# PowerShell 5.1 的 ConvertTo-Json 會把 < > & 轉成 unicode escape,順手還原
$json = $json -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&' -replace '\\u0027', "'"

$configDir = Split-Path -Parent $ConfigFile
$tmp = Join-Path $configDir (".opencode-{0}.json" -f ([guid]::NewGuid().ToString('N')))
try {
    [System.IO.File]::WriteAllText($tmp, ($json + "`r`n"), $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $ConfigFile -Force
} catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-Log "ERROR: 寫入 $ConfigFile 失敗: $($_.Exception.Message)"
    exit 1
}

Write-Log "已同步 $($modelIds.Count) 個模型 -> $ConfigFile (provider.$ProviderId)"
exit 0
