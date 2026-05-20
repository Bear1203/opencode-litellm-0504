# opencode-litellm installer (Windows / PowerShell)
#
# 一般使用 (PowerShell):
#   irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex
#
# 帶參數 (irm | iex 不能直接帶參數,改用下載後執行):
#   & ([scriptblock]::Create((irm https://.../install.ps1))) -Uninstall
#   或
#   irm https://.../install.ps1 -OutFile install.ps1 ; .\install.ps1 -Uninstall
#
# 旗標:
#   -Uninstall     移除已安裝檔案 (保留 litellm.env / litellm-key)
#   -Purge         連同 litellm.env / litellm-key / log 一起刪除
#   -Prefix DIR    覆寫 bin 安裝路徑 (預設 %LOCALAPPDATA%\opencode-litellm)
#   -Repo URL      覆寫下載來源 (預設使用 GitHub raw)
#   -LocalSrc DIR  從本機目錄安裝 (開發 / 測試用,跳過下載)
#   -Help          顯示說明

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Purge,
    [string]$Prefix,
    [string]$Repo,
    [string]$LocalSrc,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 設定區: 預設下載來源
# 使用者可用 -Repo 旗標或 OPENCODE_LITELLM_REPO 環境變數覆寫
# ============================================================================
$DefaultRepo = 'https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main'
$RepoRawBase = if ($Repo) { $Repo } elseif ($env:OPENCODE_LITELLM_REPO) { $env:OPENCODE_LITELLM_REPO } else { $DefaultRepo }
$Version = '0.1.0'

# ============================================================================
# 路徑慣例 (Windows)
#   bin / lib    %LOCALAPPDATA%\opencode-litellm\{bin,lib}
#   config       %APPDATA%\opencode\
#   cache / log  %LOCALAPPDATA%\opencode\
# ============================================================================
if (-not $Prefix) {
    $Prefix = Join-Path $env:LOCALAPPDATA 'opencode-litellm'
}
$BinDir     = Join-Path $Prefix 'bin'
$LibDir     = Join-Path $Prefix 'lib'
$ConfigDir  = Join-Path $env:APPDATA 'opencode'
$CommandsDir= Join-Path $ConfigDir 'commands'
$CacheDir   = Join-Path $env:LOCALAPPDATA 'opencode'
$EnvFile    = Join-Path $ConfigDir 'litellm.env'

# 紀錄安裝流程中是否曾修改 User PATH,用於最後統一提示重開 terminal
$script:PathModified = $false

# ============================================================================
# 輸出工具
# ============================================================================
function Write-Info  { param([string]$Msg) Write-Host "[install] $Msg" }
function Write-Ok    { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }

function Show-Help {
    @"
opencode-litellm installer (Windows / PowerShell)

用法:
  irm https://raw.githubusercontent.com/Bear1203/opencode-litellm-0504/main/install.ps1 | iex

下載後執行 (帶旗標):
  irm <url>/install.ps1 -OutFile install.ps1
  .\install.ps1                # 安裝
  .\install.ps1 -Uninstall     # 移除程式檔 (保留 env / key)
  .\install.ps1 -Purge         # 連同 env / key / log 一起移除
  .\install.ps1 -Prefix DIR    # 覆寫安裝路徑 (預設 %LOCALAPPDATA%\opencode-litellm)
  .\install.ps1 -Repo URL      # 覆寫下載來源
  .\install.ps1 -LocalSrc DIR  # 從本機目錄安裝 (開發用)
  .\install.ps1 -Help          # 顯示本說明
"@
}

if ($Help) { Show-Help; return }

# ============================================================================
# 工具函式
# ============================================================================
function Test-Command {
    param([string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-Command {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if (-not (Test-Command $n)) {
            Write-Err "缺少必要指令: $n"
            throw "Missing dependency: $n"
        }
    }
}

# 下載 / 複製檔案
function Fetch-File {
    param(
        [string]$RelPath,
        [string]$Dest
    )
    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    if ($LocalSrc) {
        $src = Join-Path $LocalSrc $RelPath
        Copy-Item -LiteralPath $src -Destination $Dest -Force
    } else {
        $url = "$RepoRawBase/$RelPath"
        Invoke-WebRequest -Uri $url -OutFile $Dest -UseBasicParsing
    }
}

# 把目錄加進 User PATH (重複時跳過)
# 直接寫 registry 以保留 REG_EXPAND_SZ 型別 (避免 %USERPROFILE% 等被展開後寫死)
function Add-ToUserPath {
    param([string]$Dir)

    $regKey = 'HKCU:\Environment'
    $current = ''
    try {
        $item = Get-ItemProperty -Path $regKey -Name 'Path' -ErrorAction Stop
        $current = $item.Path
    } catch {
        $current = ''
    }

    $parts = @()
    if ($current) { $parts = $current.Split(';') | Where-Object { $_ } }
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\'), $Dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            Write-Info "PATH 已含 $Dir,跳過寫入 User PATH"
            return
        }
    }

    $newPath = if ($current) { "$current;$Dir" } else { $Dir }

    # 用 REG_EXPAND_SZ 保留 %VAR% 形式
    $regType = if ($current -match '%[^%]+%') { 'ExpandString' } else { 'String' }
    Set-ItemProperty -Path $regKey -Name 'Path' -Value $newPath -Type $regType

    # 通知系統環境變數已變更 (新開的 process 才會抓到,但讓 Explorer 等也立刻知道)
    try {
        $sig = @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        $native = Add-Type -MemberDefinition $sig -Name 'NativeMethods' -Namespace 'Win32Helper' -PassThru -ErrorAction SilentlyContinue
        if ($native) {
            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2
            $result = [UIntPtr]::Zero
            [void]$native::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', $SMTO_ABORTIFHUNG, 5000, [ref]$result)
        }
    } catch {
        # 廣播失敗不影響安裝結果
    }

    # 當前 session 也立即生效
    $env:PATH = "$env:PATH;$Dir"
    $script:PathModified = $true
    Write-Ok "已將 $Dir 寫入 User PATH"
}

# 判斷 CPU 架構,回傳對應 release asset 名稱
function Get-OpencodeAssetName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch -Regex ($arch) {
        'ARM64' { return 'opencode-windows-arm64.zip' }
        'AMD64|x86_64' { return 'opencode-windows-x64.zip' }
        default {
            Write-Warn2 "未知架構 $arch,預設使用 x64"
            return 'opencode-windows-x64.zip'
        }
    }
}

# 從 GitHub Releases 抓最新 release 的 tag (例: v1.15.5)
function Get-LatestOpencodeTag {
    $api = 'https://api.github.com/repos/anomalyco/opencode/releases/latest'
    try {
        # GitHub API 要求 User-Agent
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'opencode-litellm-installer' } -ErrorAction Stop
        return $rel.tag_name
    } catch {
        throw "無法查詢 opencode 最新版本 ($api): $($_.Exception.Message)"
    }
}

# 自動安裝 opencode (從 GitHub Releases 下載 zip 解壓)
# 官方沒有提供 install.ps1,改成直接抓 zip 解壓 + 寫 PATH
function Install-Opencode {
    Write-Info '找不到 opencode 指令,將自動從 GitHub Releases 下載安裝...'
    Write-Info '  目標路徑: %USERPROFILE%\.opencode\bin'

    $tag = $null
    try {
        $tag = Get-LatestOpencodeTag
        Write-Info "最新版本: $tag"
    } catch {
        Write-Err $_.Exception.Message
        Write-Err '請手動安裝: https://github.com/anomalyco/opencode/releases'
        return
    }

    $assetName = Get-OpencodeAssetName
    $downloadUrl = "https://github.com/anomalyco/opencode/releases/download/$tag/$assetName"
    $opencodeBin = Join-Path $env:USERPROFILE '.opencode\bin'

    Write-Info "下載 $downloadUrl"
    $tmpZip = Join-Path $env:TEMP "opencode-$([guid]::NewGuid().ToString('N')).zip"
    try {
        # 大檔下載 -ProgressPreference SilentlyContinue 可顯著加速
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpZip -UseBasicParsing -ErrorAction Stop
        } finally {
            $ProgressPreference = $prev
        }
    } catch {
        Write-Err "下載失敗: $($_.Exception.Message)"
        Write-Err "  URL: $downloadUrl"
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
    if (Test-Path -LiteralPath $opencodeExe) {
        Add-ToUserPath -Dir $opencodeBin
        Write-Ok "✓ opencode 已安裝: $opencodeExe"
    } else {
        # 部分 release 可能多套一層資料夾
        $nested = Get-ChildItem -LiteralPath $opencodeBin -Recurse -Filter 'opencode.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nested) {
            $opencodeBin = Split-Path -Parent $nested.FullName
            Add-ToUserPath -Dir $opencodeBin
            Write-Ok "✓ opencode 已安裝: $($nested.FullName)"
        } else {
            Write-Warn2 "解壓後找不到 opencode.exe,請檢查 $opencodeBin"
        }
    }
}

# ============================================================================
# 主要動作
# ============================================================================
function Do-Install {
    # PowerShell 內建 Invoke-WebRequest / ConvertFrom-Json,所以不需要 python / curl
    # 只檢查必須的 PowerShell 版本
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Err "需要 PowerShell 5.1 或更新版本 (目前: $($PSVersionTable.PSVersion))"
        throw 'Unsupported PowerShell version'
    }

    if (-not (Test-Command 'opencode')) {
        Install-Opencode
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
    Write-Info "  desktop   -> opencode-litellm.bat (雙擊啟動器)"

    foreach ($d in @($BinDir, $LibDir, $ConfigDir, $CommandsDir, $CacheDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    # 主程式 .ps1 放 lib (不放 bin),避免 PATHEXT 讓 PowerShell 優先匹配到 .ps1 而觸發 ExecutionPolicy
    Fetch-File -RelPath 'bin/opencode-litellm.ps1'              -Dest (Join-Path $LibDir 'opencode-litellm.ps1')
    Fetch-File -RelPath 'lib/litellm-sync.ps1'                  -Dest (Join-Path $LibDir 'litellm-sync.ps1')
    Fetch-File -RelPath 'config/commands/litellm-sync.md'       -Dest (Join-Path $CommandsDir 'litellm-sync.md')
    Fetch-File -RelPath 'config/commands/litellm-doctor.md'     -Dest (Join-Path $CommandsDir 'litellm-doctor.md')

    # 清掉舊版裝在 bin 的 .ps1 (升級時避免 PATHEXT 問題復發)
    $oldPs1 = Join-Path $BinDir 'opencode-litellm.ps1'
    if (Test-Path -LiteralPath $oldPs1) {
        Remove-Item -LiteralPath $oldPs1 -Force -ErrorAction SilentlyContinue
    }

    # 建立 .cmd shim 在 bin (PATH 上只看到 .cmd,PowerShell / cmd 都能直接打 opencode-litellm)
    $cmdShim = Join-Path $BinDir 'opencode-litellm.cmd'
    $shimContent = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$LibDir\opencode-litellm.ps1" %*
"@
    Set-Content -LiteralPath $cmdShim -Value $shimContent -Encoding ASCII

    # 額外在桌面建立雙擊啟動器 (含 pause,給滑鼠雙擊用)
    # 已存在就不覆蓋,避免洗掉使用者自己的修改
    $desktopDir = [Environment]::GetFolderPath('Desktop')
    if ($desktopDir -and (Test-Path -LiteralPath $desktopDir)) {
        $desktopBat = Join-Path $desktopDir 'opencode-litellm.bat'
        if (-not (Test-Path -LiteralPath $desktopBat)) {
            $batContent = @"
@echo off
REM opencode-litellm 雙擊啟動器
REM 跑完不會自動關閉,可看到訊息
powershell -NoProfile -ExecutionPolicy Bypass -File "$LibDir\opencode-litellm.ps1" %*
pause
"@
            Set-Content -LiteralPath $desktopBat -Value $batContent -Encoding ASCII
            Write-Info "已建立桌面雙擊啟動器: $desktopBat"
        } else {
            Write-Info "保留既有桌面啟動器: $desktopBat"
        }
    }

    # env 檔: 已存在就不覆蓋,避免洗掉使用者填好的 key;不存在則用範本建立
    if (Test-Path -LiteralPath $EnvFile) {
        Write-Info "保留既有 $EnvFile"
    } else {
        Fetch-File -RelPath 'config/litellm.env.example' -Dest $EnvFile
    }

    Write-Host ''
    Write-Ok "✓ 安裝完成 (version $Version)"
    Write-Ok "  二進位路徑: $BinDir\opencode-litellm.cmd"
    Write-Host ''

    # PATH 設定:自動寫入 User PATH
    Add-ToUserPath -Dir $BinDir

    if ($script:PathModified) {
        Write-Warn2 ''
        Write-Warn2 '================================================================'
        Write-Warn2 '  下一步: 請開啟新的 PowerShell / Terminal 視窗 (PATH 已更新)'
        Write-Warn2 '================================================================'
        Write-Warn2 ''
        Write-Warn2 '  目前這個 session 的 PATH 已暫時更新,但要讓所有新視窗都生效,'
        Write-Warn2 '  建議關閉本視窗並重新開啟 Terminal / PowerShell。'
        Write-Warn2 ''
    }

    Write-Ok '================================================================'
    Write-Ok '  接下來'
    Write-Ok '================================================================'
    Write-Ok ''
    Write-Ok '  1) 首次啟動 (會引導你輸入 LiteLLM API key 和 URL):'
    Write-Ok '       opencode-litellm'
    Write-Ok ''
    Write-Ok '  2) 完成後可直接使用 opencode (模型清單與 token 已寫入 config):'
    Write-Ok '       opencode'
    Write-Ok ''
    Write-Ok '  其他常用指令:'
    Write-Ok '       opencode-litellm sync       # 重新同步模型清單'
    Write-Ok '       opencode-litellm config     # 修改 API key / URL'
    Write-Ok '       opencode-litellm doctor     # 檢查當前環境設定狀態'
    Write-Ok ''
}

function Do-Uninstall {
    param([switch]$DoPurge)

    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $files = @(
        (Join-Path $BinDir 'opencode-litellm.ps1'),      # 舊版位置 (升級殘留)
        (Join-Path $BinDir 'opencode-litellm.cmd'),
        (Join-Path $LibDir 'opencode-litellm.ps1'),
        (Join-Path $LibDir 'litellm-sync.ps1'),
        (Join-Path $CommandsDir 'litellm-sync.md'),
        (Join-Path $CommandsDir 'litellm-doctor.md')
    )
    if ($desktopDir) {
        $files += (Join-Path $desktopDir 'opencode-litellm.bat')
    }
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            Write-Info "移除 $f"
            Remove-Item -LiteralPath $f -Force
        }
    }

    # 嘗試清空空資料夾 (bin/lib/Prefix)
    foreach ($d in @($BinDir, $LibDir, $Prefix)) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) {
            Remove-Item -LiteralPath $d -Force
        }
    }

    if ($DoPurge) {
        $keyFile = Join-Path $ConfigDir 'litellm-key'
        $logFile = Join-Path $CacheDir 'litellm-sync.log'
        Write-Info "purge: 移除 $EnvFile / $keyFile / $logFile"
        foreach ($f in @($EnvFile, $keyFile, $logFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        Write-Warn2 "保留 $ConfigDir\opencode.json 不動 (內含使用者其他 provider / 設定)。"
        Write-Warn2 '若要清除 provider.litellm 區塊請手動編輯該檔。'
    } else {
        Write-Info '保留設定 / token / log (用 -Purge 可一併刪除)'
    }
    Write-Ok '✓ 已移除'
}

# ============================================================================
# Dispatch
# ============================================================================
if ($Purge) {
    Do-Uninstall -DoPurge
} elseif ($Uninstall) {
    Do-Uninstall
} else {
    Do-Install
}
