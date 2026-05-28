# opencode-litellm installer (Windows / PowerShell)
#
# 一般安裝:
#   irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
#
# 解除安裝 / 自訂安裝: 透過環境變數控制 (iex 不能直接帶 param,故走 env)
#   $env:OPENCODE_LITELLM_UNINSTALL = '1'   # 移除程式檔 (保留 env / key)
#   $env:OPENCODE_LITELLM_PURGE     = '1'   # 連同 env / key / log 一起移除
#   $env:OPENCODE_LITELLM_PREFIX    = 'C:\path'  # 覆寫安裝路徑 (預設 %LOCALAPPDATA%\opencode-litellm)
#   $env:OPENCODE_LITELLM_REPO      = 'https://...' # 覆寫下載來源
#   $env:OPENCODE_LITELLM_LOCALSRC  = 'C:\src' # 從本機目錄安裝 (開發用)
#   接著: irm <url>/install.ps1 | iex
#   用完後記得 Remove-Item Env:OPENCODE_LITELLM_* 清掉

$ErrorActionPreference = 'Stop'

# 從 env 讀控制旗標 (取代以前的 param(...),讓 `irm | iex` 可用)
$Uninstall = [bool]$env:OPENCODE_LITELLM_UNINSTALL
$Purge     = [bool]$env:OPENCODE_LITELLM_PURGE
$Prefix    = $env:OPENCODE_LITELLM_PREFIX
$LocalSrc  = $env:OPENCODE_LITELLM_LOCALSRC

$DefaultRepo = 'https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main'
$RepoRawBase = if ($env:OPENCODE_LITELLM_REPO) { $env:OPENCODE_LITELLM_REPO } else { $DefaultRepo }
$Version = '0.1.0'

# 路徑配置
#   程式檔 (我們的 wrapper):  %LOCALAPPDATA%\opencode-litellm\{bin,lib}
#   opencode 設定 / log:      %USERPROFILE%\.config\opencode\
#       opencode 讀的 global config 路徑就是 ~/.config/opencode/opencode.json,
#       所有 LiteLLM 周邊 (env / key / log / slash commands) 都放這
if (-not $Prefix) { $Prefix = Join-Path $env:LOCALAPPDATA 'opencode-litellm' }
$BinDir      = Join-Path $Prefix 'bin'
$LibDir      = Join-Path $Prefix 'lib'
$ConfigDir   = Join-Path $env:USERPROFILE '.config\opencode'
$CommandsDir = Join-Path $ConfigDir 'commands'
$CacheDir    = $ConfigDir
$EnvFile     = Join-Path $ConfigDir 'litellm.env'

function Write-Info  { param([string]$Msg) Write-Host "[install] $Msg" }
function Write-Ok    { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }

function Test-Command {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# 下載 / 複製檔案。文字檔強制以 UTF-8 with BOM 寫入,
# 避免 PowerShell 5.1 讀無 BOM 的 .ps1 時把中文當系統 ANSI (Big5) 亂碼。
function Fetch-File {
    param([string]$RelPath, [string]$Dest)

    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if ($LocalSrc) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $LocalSrc $RelPath))
    } else {
        $resp = Invoke-WebRequest -Uri "$RepoRawBase/$RelPath" -UseBasicParsing
        $bytes = $resp.Content
        if ($bytes -is [string]) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($bytes)
        }
    }

    $textExt = @('.ps1', '.psm1', '.md', '.env', '.json', '.txt', '.example')
    $ext = [System.IO.Path]::GetExtension($Dest).ToLower()
    $name = [System.IO.Path]::GetFileName($Dest).ToLower()
    $isText = ($textExt -contains $ext) -or ($name -like '*.env*')

    if ($isText -and $bytes.Length -ge 1) {
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $bom = [byte[]](0xEF, 0xBB, 0xBF)
            $bytes = $bom + $bytes
        }
    }

    [System.IO.File]::WriteAllBytes($Dest, $bytes)
}

# 把目錄加進 User PATH。直接寫 registry 以保留 REG_EXPAND_SZ 型別。
function Add-ToUserPath {
    param([string]$Dir)

    $regKey = 'HKCU:\Environment'
    $current = ''
    try {
        $current = (Get-ItemProperty -Path $regKey -Name 'Path' -ErrorAction Stop).Path
    } catch {
        $current = ''
    }

    $parts = if ($current) { $current.Split(';') | Where-Object { $_ } } else { @() }
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\'), $Dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Write-Info "PATH 已含 $Dir,跳過"
            return
        }
    }

    $newPath = if ($current) { "$current;$Dir" } else { $Dir }
    $regType = if ($current -match '%[^%]+%') { 'ExpandString' } else { 'String' }
    Set-ItemProperty -Path $regKey -Name 'Path' -Value $newPath -Type $regType

    # 通知 Explorer 等程式環境變數已更新
    try {
        $sig = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        $native = Add-Type -MemberDefinition $sig -Name 'NativeMethods' -Namespace 'Win32Helper' -PassThru -ErrorAction SilentlyContinue
        if ($native) {
            $result = [UIntPtr]::Zero
            [void]$native::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
        }
    } catch { }

    $env:PATH = "$env:PATH;$Dir"
    Write-Ok "已將 $Dir 寫入 User PATH"
}

# 自動安裝 opencode (從 GitHub Releases 下載 zip 解壓)
function Install-Opencode {
    Write-Info '找不到 opencode 指令,將自動從 GitHub Releases 下載安裝...'

    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $assetName = if ($arch -match 'ARM64') { 'opencode-windows-arm64.zip' } else { 'opencode-windows-x64.zip' }

    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/anomalyco/opencode/releases/latest' `
            -Headers @{ 'User-Agent' = 'opencode-litellm-installer' } -ErrorAction Stop
        $tag = $rel.tag_name
        Write-Info "最新版本: $tag"
    } catch {
        Write-Err "無法查詢 opencode 最新版本: $($_.Exception.Message)"
        Write-Err '請手動安裝: https://github.com/anomalyco/opencode/releases'
        return
    }

    $downloadUrl = "https://github.com/anomalyco/opencode/releases/download/$tag/$assetName"
    $opencodeBin = Join-Path $env:USERPROFILE '.opencode\bin'
    $tmpZip = Join-Path $env:TEMP "opencode-$([guid]::NewGuid().ToString('N')).zip"

    Write-Info "下載 $downloadUrl"
    try {
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        } finally {
            $ProgressPreference = $prev
        }
    } catch {
        Write-Err "下載失敗: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        return
    }

    if (-not (Test-Path -LiteralPath $opencodeBin)) {
        New-Item -ItemType Directory -Path $opencodeBin -Force | Out-Null
    }

    Write-Info "解壓到 $opencodeBin"
    try {
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $opencodeBin -Force -ErrorAction Stop
    } catch {
        Write-Err "解壓失敗: $($_.Exception.Message)"
        return
    } finally {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    }

    $opencodeExe = Join-Path $opencodeBin 'opencode.exe'
    if (-not (Test-Path -LiteralPath $opencodeExe)) {
        # 部分 release 可能多套一層資料夾
        $nested = Get-ChildItem -LiteralPath $opencodeBin -Recurse -Filter 'opencode.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nested) {
            $opencodeBin = Split-Path -Parent $nested.FullName
            $opencodeExe = $nested.FullName
        } else {
            Write-Warn2 "解壓後找不到 opencode.exe,請檢查 $opencodeBin"
            return
        }
    }
    Add-ToUserPath -Dir $opencodeBin
    Write-Ok "opencode 已安裝: $opencodeExe"
}

function Do-Install {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Err "需要 PowerShell 5.1 或更新版本 (目前: $($PSVersionTable.PSVersion))"
        throw 'Unsupported PowerShell version'
    }

    if (-not (Test-Command 'opencode')) {
        Install-Opencode
    }

    # 清理舊版 (<= 2026-05-21) 殘留: 之前裝在 %APPDATA%\opencode\ 的 LiteLLM 設定,
    # opencode 不會讀這個位置 (它讀 ~/.config/opencode/)。直接搬移到新位置。
    $legacyConfigDir = Join-Path $env:APPDATA 'opencode'
    if (Test-Path -LiteralPath $legacyConfigDir) {
        if (-not (Test-Path -LiteralPath $ConfigDir)) {
            New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        }
        $migrations = @(
            @{ Old = (Join-Path $legacyConfigDir 'litellm.env');                 New = (Join-Path $ConfigDir 'litellm.env') }
            @{ Old = (Join-Path $legacyConfigDir 'litellm-key');                 New = (Join-Path $ConfigDir 'litellm-key') }
            @{ Old = (Join-Path $legacyConfigDir 'opencode.json');               New = (Join-Path $ConfigDir 'opencode.json') }
            @{ Old = (Join-Path $legacyConfigDir 'commands\litellm-sync.md');    New = (Join-Path $CommandsDir 'litellm-sync.md') }
            @{ Old = (Join-Path $legacyConfigDir 'commands\litellm-doctor.md');  New = (Join-Path $CommandsDir 'litellm-doctor.md') }
        )
        foreach ($m in $migrations) {
            if ((Test-Path -LiteralPath $m.Old) -and -not (Test-Path -LiteralPath $m.New)) {
                $newDir = Split-Path -Parent $m.New
                if (-not (Test-Path -LiteralPath $newDir)) {
                    New-Item -ItemType Directory -Path $newDir -Force | Out-Null
                }
                Write-Info "搬移舊路徑: $($m.Old) -> $($m.New)"
                Move-Item -LiteralPath $m.Old -Destination $m.New -Force
            }
        }
        # 順手清掉舊 log
        $legacyLog = Join-Path $env:LOCALAPPDATA 'opencode\litellm-sync.log'
        if (Test-Path -LiteralPath $legacyLog) {
            Write-Info "移除舊 log: $legacyLog"
            Remove-Item -LiteralPath $legacyLog -Force -ErrorAction SilentlyContinue
        }
    }

    if ($LocalSrc) {
        Write-Info "本機來源: $LocalSrc"
    } else {
        Write-Info "下載來源: $RepoRawBase"
    }

    Write-Info '安裝目標:'
    Write-Info "  bin       -> $BinDir\opencode-litellm.cmd"
    Write-Info "  lib       -> $LibDir\opencode-litellm.ps1, litellm-sync.ps1"
    Write-Info "  env       -> $EnvFile"
    Write-Info "  commands  -> $CommandsDir\litellm-{sync,doctor}.md"

    foreach ($d in @($BinDir, $LibDir, $ConfigDir, $CommandsDir, $CacheDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    # 主程式 .ps1 放 lib (不放 bin) 避免 PATHEXT 讓 PowerShell 優先匹配到 .ps1 而觸發 ExecutionPolicy
    Fetch-File -RelPath 'bin/opencode-litellm.ps1'          -Dest (Join-Path $LibDir 'opencode-litellm.ps1')
    Fetch-File -RelPath 'lib/litellm-sync.ps1'              -Dest (Join-Path $LibDir 'litellm-sync.ps1')
    Fetch-File -RelPath 'config/commands/litellm-sync.md'   -Dest (Join-Path $CommandsDir 'litellm-sync.md')
    Fetch-File -RelPath 'config/commands/litellm-doctor.md' -Dest (Join-Path $CommandsDir 'litellm-doctor.md')

    # .cmd shim 在 bin (PATH 上只看到 .cmd,任何 shell 直接打 opencode-litellm)
    $cmdShim = Join-Path $BinDir 'opencode-litellm.cmd'
    $shimContent = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$LibDir\opencode-litellm.ps1" %*
"@
    Set-Content -LiteralPath $cmdShim -Value $shimContent -Encoding ASCII

    # env 檔: 已存在就不覆蓋
    if (Test-Path -LiteralPath $EnvFile) {
        Write-Info "保留既有 $EnvFile"
    } else {
        Fetch-File -RelPath 'config/litellm.env.example' -Dest $EnvFile
    }

    Add-ToUserPath -Dir $BinDir

    Write-Host ''
    Write-Ok "安裝完成 (version $Version)"
    Write-Ok "  進入點: $BinDir\opencode-litellm.cmd"
    Write-Host ''

    Write-Ok '接下來:'
    Write-Ok '  1) 首次啟動 (會引導輸入 LiteLLM API Key):'
    Write-Ok '       opencode-litellm'
    Write-Ok '  2) 完成後可直接使用 opencode:'
    Write-Ok '       opencode'
    Write-Ok ''
    Write-Ok '  其他常用指令:'
    Write-Ok '       opencode-litellm help       # 完整說明 (含 opencode TUI 常用指令)'
    Write-Ok '       opencode-litellm sync       # 重新同步模型清單'
    Write-Ok '       opencode-litellm config     # 修改 API Key'
    Write-Ok '       opencode-litellm doctor     # 檢查環境狀態'
}

function Do-Uninstall {
    param([switch]$DoPurge)

    $files = @(
        (Join-Path $BinDir 'opencode-litellm.cmd'),
        (Join-Path $LibDir 'opencode-litellm.ps1'),
        (Join-Path $LibDir 'litellm-sync.ps1'),
        (Join-Path $CommandsDir 'litellm-sync.md'),
        (Join-Path $CommandsDir 'litellm-doctor.md')
    )

    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            Write-Info "移除 $f"
            Remove-Item -LiteralPath $f -Force
        }
    }

    foreach ($d in @($BinDir, $LibDir, $Prefix)) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) {
            Remove-Item -LiteralPath $d -Force
        }
    }

    # 順手清掉舊版 (<= 2026-05-21) 留在 %APPDATA%\opencode\ 的 LiteLLM 殘留檔
    $legacyConfigDir = Join-Path $env:APPDATA 'opencode'
    $legacyCacheDir  = Join-Path $env:LOCALAPPDATA 'opencode'
    $legacyFiles = @(
        (Join-Path $legacyConfigDir 'litellm.env'),
        (Join-Path $legacyConfigDir 'litellm-key'),
        (Join-Path $legacyConfigDir 'commands\litellm-sync.md'),
        (Join-Path $legacyConfigDir 'commands\litellm-doctor.md'),
        (Join-Path $legacyCacheDir  'litellm-sync.log')
    )
    foreach ($f in $legacyFiles) {
        if (Test-Path -LiteralPath $f) {
            Write-Info "移除舊路徑殘留: $f"
            Remove-Item -LiteralPath $f -Force
        }
    }

    if ($DoPurge) {
        $keyFile = Join-Path $ConfigDir 'litellm-key'
        $logFile = Join-Path $CacheDir 'litellm-sync.log'
        Write-Info "purge: 移除 $EnvFile / $keyFile / $logFile"
        foreach ($f in @($EnvFile, $keyFile, $logFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        Write-Warn2 "保留 $ConfigDir\opencode.json 不動 (內含使用者其他設定)。"
        Write-Warn2 '若要清除 provider.litellm 區塊請手動編輯該檔。'
    } else {
        Write-Info '保留設定 / token / log (設 $env:OPENCODE_LITELLM_PURGE = 1 可一併刪除)'
    }
    Write-Ok '已移除'
}

if ($Purge) {
    Do-Uninstall -DoPurge
} elseif ($Uninstall) {
    Do-Uninstall
} else {
    Do-Install
}
