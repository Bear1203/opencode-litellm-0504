# litellm-sync.ps1
#
# 從 LiteLLM 取得可用模型清單,merge 到使用者的 opencode.json,
# 並把 API token 寫入獨立檔案讓 opencode.json 用 {file:...} 引用。
#
# 讀取的環境變數:
#   LITELLM_BASE_URL       (必填) LiteLLM server URL
#   LITELLM_API_KEY        (必填) Bearer token,沒給就讀 LITELLM_KEY_FILE
#   LITELLM_PROVIDER_ID    (預設 litellm)
#   LITELLM_PROVIDER_NAME  (預設 LiteLLM)
#   LITELLM_TIMEOUT        (預設 10) HTTP timeout 秒數
#   OPENCODE_CONFIG_FILE   (預設 %USERPROFILE%\.config\opencode\opencode.json)
#   LITELLM_KEY_FILE       (預設 %USERPROFILE%\.config\opencode\litellm-key)
#   LITELLM_LOG_FILE       (預設 %USERPROFILE%\.config\opencode\litellm-sync.log)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BaseUrl      = if ($env:LITELLM_BASE_URL)     { $env:LITELLM_BASE_URL }     else { '' }
$ApiKey       = if ($env:LITELLM_API_KEY)      { $env:LITELLM_API_KEY }      else { '' }
$ProviderId   = if ($env:LITELLM_PROVIDER_ID)  { $env:LITELLM_PROVIDER_ID }  else { 'litellm' }
$ProviderName = if ($env:LITELLM_PROVIDER_NAME){ $env:LITELLM_PROVIDER_NAME }else { 'LiteLLM' }
$TimeoutSec   = if ($env:LITELLM_TIMEOUT)      { [int]$env:LITELLM_TIMEOUT } else { 10 }

$OpencodeConfigDir = Join-Path $env:USERPROFILE '.config\opencode'
$ConfigFile = if ($env:OPENCODE_CONFIG_FILE) { $env:OPENCODE_CONFIG_FILE } else { Join-Path $OpencodeConfigDir 'opencode.json' }
$KeyFile    = if ($env:LITELLM_KEY_FILE)     { $env:LITELLM_KEY_FILE }     else { Join-Path $OpencodeConfigDir 'litellm-key' }
$LogFile    = if ($env:LITELLM_LOG_FILE)     { $env:LITELLM_LOG_FILE }     else { Join-Path $OpencodeConfigDir 'litellm-sync.log' }

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

# 全域 trap: 捕捉所有未處理的 terminating error,確保訊息一定會印出 stderr + log
# 避免 "sync 失敗 exit 1 但沒看到原因" 的情況
trap {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log "       at: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    if ($_.ScriptStackTrace) { Write-Log "       stack: $($_.ScriptStackTrace -replace "`r?`n", ' | ')" }
    exit 1
}

# API key: env 沒給時讀 KeyFile
if (-not $ApiKey -and (Test-Path -LiteralPath $KeyFile)) {
    $ApiKey = (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8) -replace "`r?`n$", ''
}

if (-not $BaseUrl) { Write-Log 'ERROR: LITELLM_BASE_URL 未設定'; exit 1 }
if (-not $ApiKey)  { Write-Log "ERROR: LITELLM_API_KEY 未設定 (env 變數或 $KeyFile 都沒有)"; exit 1 }

$BaseUrl = $BaseUrl.TrimEnd('/')

# 1. 取得模型清單
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

# 2. 寫入 key 檔 (無 BOM、無結尾換行,並用 icacls 把 DACL 收緊為僅本人可讀)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($KeyFile, $ApiKey, $utf8NoBom)

# 用 icacls 而非 Set-Acl: Set-Acl 在某些情境會嘗試動到 SACL,觸發 SeSecurityPrivilege 缺權限。
# icacls 只動 DACL,一般使用者就可執行。
try {
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $null = & icacls.exe $KeyFile /inheritance:r /grant:r "${userId}:(F)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN: icacls 設定 $KeyFile 權限失敗 (exit $LASTEXITCODE),token 仍寫入但權限可能寬鬆"
    }
} catch {
    Write-Log "WARN: 設定 $KeyFile 權限失敗: $($_.Exception.Message)"
}
Write-Log "API key 已寫入 $KeyFile"

# 3. 解析模型清單並 merge 到 opencode.json (只動 provider.<id>,其他設定原樣保留)
$modelIds = @($resp.data | Where-Object { $_.id -is [string] } | ForEach-Object { $_.id } | Sort-Object -Unique)
if (-not $modelIds -or $modelIds.Count -eq 0) {
    Write-Log 'ERROR: 模型清單為空,放棄寫入'
    exit 1
}

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

# 在 PSCustomObject 上設定屬性 (有就覆蓋,沒就 Add-Member)
function Set-Prop {
    param([Parameter(Mandatory)]$Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties[$Name]) {
        $Obj.$Name = $Value
    } else {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

if (-not $config.PSObject.Properties['$schema']) {
    Set-Prop -Obj $config -Name '$schema' -Value 'https://opencode.ai/config.json'
}
if (-not $config.PSObject.Properties['provider']) {
    Set-Prop -Obj $config -Name 'provider' -Value ([PSCustomObject]@{})
}
$provider = $config.provider

$modelsObj = [PSCustomObject]@{}
foreach ($mid in $modelIds) {
    # 模型清單顯示名稱直接用 LiteLLM 回的原始 id,不做任何裁切
    Set-Prop -Obj $modelsObj -Name $mid -Value ([PSCustomObject]@{ name = $mid })
}

# key file 路徑改寫成 ~ 開頭 (opencode 支援的相對路徑)
# 注意: 不能用 $home (那是 PowerShell 唯讀的 automatic variable,賦值會 throw)
$userHome = $env:USERPROFILE
$keyRef = if ($KeyFile.StartsWith($userHome + '\', [StringComparison]::OrdinalIgnoreCase) -or $KeyFile.StartsWith($userHome + '/', [StringComparison]::OrdinalIgnoreCase)) {
    '~' + $KeyFile.Substring($userHome.Length).Replace('\', '/')
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

# 預設 model: 若 config 頂層還沒設,把它指向 LiteLLM 排序後的第一個模型,
# 讓使用者啟動 opencode 後預設選的就是 LiteLLM 而不是 OpenAI 等內建 provider。
# 使用者手動改過後就不會被覆蓋。
if (-not $config.PSObject.Properties['model']) {
    $defaultModel = "$ProviderId/$($modelIds[0])"
    Set-Prop -Obj $config -Name 'model' -Value $defaultModel
    Write-Log "預設模型: $defaultModel"
}

# 4. 原子寫入 (PowerShell 5.1 的 ConvertTo-Json 會 escape < > & ',順手還原)
$json = $config | ConvertTo-Json -Depth 20
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
