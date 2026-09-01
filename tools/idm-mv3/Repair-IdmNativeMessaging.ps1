#Requires -Version 5.1
<#
.SYNOPSIS
    修复 IDM Native Messaging 链路：注册表登记 + 独立的 host manifest + 中文路径规避。

.DESCRIPTION
    做三件 Diagnose 脚本查出来的事：

    1. 在 %LOCALAPPDATA%\IDMNativeHost\ 下写一份【我们自己的】host manifest。
       为什么不用 IDM 目录里那份：IDM 启动时会重写自己那份 JSON，
       把 allowed_origins 刷回官方 ID —— 手工加的扩展 ID 就这么被吃掉了。
       放到 IDM 不知道的路径，它就永远不会被覆盖。

    2. 把注册表 HKCU\Software\Google\Chrome\NativeMessagingHosts\<host> 指向这份 JSON。
       Chrome 在 Windows 上只认注册表，不扫描目录 —— 这一步不做，JSON 写得再对也没用。

    3. IDM 装在中文路径下时，JSON 里的 path 自动改写成 8.3 短路径（纯 ASCII），
       彻底规避编码问题。

    全部只写 HKCU，不需要管理员权限。

.EXAMPLE
    .\Repair-IdmNativeMessaging.ps1 `
        -ExtensionDir 'C:\Users\win\Doubao\chats\2026-09-01\new-chat-4\idm_ext\extracted' `
        -IdmDir 'E:\下载软件\IDM 6.42 免安装版\IDM 6.42 免安装版\IDM'

.EXAMPLE
    # 顺便把 IDMan.exe 登记到注册表，解决 IDMMsgHost 找不到 IDM 主程序（"Cannot launch IDM"）
    .\Repair-IdmNativeMessaging.ps1 -ExtensionDir '...' -IdmDir '...' -RegisterIdmExePath
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [Parameter(Mandatory = $true)][string]$IdmDir,
    [string]$HostName = 'com.internetdownloadmanager.pdmbehavior',
    [string[]]$ExtraExtensionIds = @(),
    [string]$OutputDir = (Join-Path $env:LOCALAPPDATA 'IDMNativeHost'),
    [switch]$RegisterIdmExePath,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($t) { Write-Host ''; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "   [OK] $t" -ForegroundColor Green }
function Write-Warn2($t) { Write-Host "   [!!] $t" -ForegroundColor Yellow }

function Test-IsAscii([string]$s) {
    if (-not $s) { return $true }
    foreach ($c in $s.ToCharArray()) { if ([int][char]$c -gt 127) { return $false } }
    return $true
}

function Get-ShortPath([string]$Path) {
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $fso.GetFile($Path).ShortPath }
        return $fso.GetFolder($Path).ShortPath
    }
    catch { return $null }
}

function Get-ExtensionIdFromKey([string]$Base64Key) {
    $pk = [Convert]::FromBase64String($Base64Key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($pk) } finally { $sha.Dispose() }
    $hex = -join ($digest[0..15] | ForEach-Object { $_.ToString('x2') })
    return -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32($_, 16)) })
}

Write-Host ''
Write-Host '########  修复 IDM Native Messaging  ########' -ForegroundColor White

# ---------------------------------------------------------------- 校验输入
Write-Step '校验路径'
if (-not (Test-Path -LiteralPath $ExtensionDir)) { throw "扩展目录不存在: $ExtensionDir" }
if (-not (Test-Path -LiteralPath $IdmDir)) { throw "IDM 目录不存在: $IdmDir" }
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$IdmDir = (Resolve-Path -LiteralPath $IdmDir).Path

$msgHost = Join-Path $IdmDir 'IDMMsgHost.exe'
if (-not (Test-Path -LiteralPath $msgHost)) { throw "IDMMsgHost.exe 不在 $IdmDir" }
Write-Ok "IDMMsgHost.exe: $msgHost"

$idman = Join-Path $IdmDir 'IDMan.exe'
if (Test-Path -LiteralPath $idman) { Write-Ok "IDMan.exe: $idman" } else { Write-Warn2 "IDMan.exe 不在 $IdmDir" }

# ---------------------------------------------------------------- 确定扩展 ID
Write-Step '确定扩展 ID'
$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json 不存在: $manifestPath" }
$manifest = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json

$ids = New-Object System.Collections.Generic.List[string]
if ($manifest.PSObject.Properties.Name -contains 'key' -and $manifest.key) {
    $idFromKey = Get-ExtensionIdFromKey $manifest.key
    $ids.Add($idFromKey)
    Write-Ok "manifest 里有 key，ID 固定为 $idFromKey"
}
else {
    Write-Warn2 'manifest.json 里没有 "key"，扩展 ID 会随目录路径变化。'
    Write-Warn2 ("强烈建议先跑: .\Get-CrxKey.ps1 -CrxPath '...\IDMGCExt.crx' -PatchManifest '" + $manifestPath + "'")
    Write-Warn2 '否则每次换目录都要重新跑本脚本。'
}
foreach ($e in $ExtraExtensionIds) {
    $t = $e.Trim()
    if ($t -and -not $ids.Contains($t)) { $ids.Add($t) }
}
if ($ids.Count -eq 0) {
    throw '没有任何扩展 ID 可用。先跑 Get-CrxKey.ps1 -PatchManifest 固定 ID，或用 -ExtraExtensionIds 从 chrome://extensions 复制 ID 传进来。'
}

$origins = @($ids | ForEach-Object { "chrome-extension://$_/" })
foreach ($o in $origins) { Write-Ok "白名单条目: $o" }

# ---------------------------------------------------------------- host 可执行路径
Write-Step '确定 host 可执行文件路径'
$hostExePath = $msgHost
if (-not (Test-IsAscii $msgHost)) {
    Write-Warn2 "IDM 路径含非 ASCII 字符，尝试改用 8.3 短路径"
    $sp = Get-ShortPath $msgHost
    if ($sp -and (Test-IsAscii $sp) -and (Test-Path -LiteralPath $sp)) {
        $hostExePath = $sp
        Write-Ok "使用短路径: $hostExePath"
    }
    else {
        Write-Warn2 '拿不到可用的 8.3 短路径（该卷可能禁用了 8.3 名称）。'
        Write-Warn2 '将写入原始中文路径 —— JSON 会以严格 UTF-8 无 BOM 写出，通常可用。'
        Write-Warn2 '若仍失败，把 IDM 便携版整个移到纯英文路径（如 D:\IDM）后重跑本脚本。'
    }
}
else { Write-Ok "路径为纯 ASCII: $hostExePath" }

# ---------------------------------------------------------------- 写 host manifest
Write-Step '写 host manifest'
$jsonPath = Join-Path $OutputDir "$HostName.json"
$hostManifest = [ordered]@{
    name            = $HostName
    description     = 'IDM Native Messaging Host'
    path            = $hostExePath
    type            = 'stdio'
    allowed_origins = $origins
}
$json = $hostManifest | ConvertTo-Json -Depth 5

if ($WhatIfOnly) {
    Write-Host '--- 将写入的 JSON ---' -ForegroundColor DarkGray
    Write-Host $json
}
else {
    if (-not (Test-Path -LiteralPath $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }
    # 必须 UTF-8 无 BOM：Chrome 不接受 BOM，中文路径用 ANSI 存会直接解析失败
    [System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "已写入 $jsonPath (UTF-8 无 BOM)"
}

# ---------------------------------------------------------------- 注册表
Write-Step '登记注册表（Chrome 找 host 的唯一入口）'
$regRoots = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKCU:\Software\Chromium\NativeMessagingHosts',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
)
foreach ($root in $regRoots) {
    $key = Join-Path $root $HostName
    if ($WhatIfOnly) { Write-Host "   将设置 $key = $jsonPath" -ForegroundColor DarkGray; continue }
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    $old = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
    if ($old -and $old -ne $jsonPath) {
        Write-Warn2 "覆盖原值: $old"
    }
    Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $jsonPath
    Write-Ok $key
}

# ---------------------------------------------------------------- IDM 主程序登记
if ($RegisterIdmExePath) {
    Write-Step '登记 IDMan.exe 路径（便携版通常缺这一项）'
    if (-not (Test-Path -LiteralPath $idman)) {
        Write-Warn2 "IDMan.exe 不存在，跳过"
    }
    elseif ($WhatIfOnly) {
        Write-Host "   将设置 HKCU:\Software\DownloadManager\ExePath = $idman" -ForegroundColor DarkGray
    }
    else {
        $dmKey = 'HKCU:\Software\DownloadManager'
        if (-not (Test-Path -LiteralPath $dmKey)) { $null = New-Item -Path $dmKey -Force }
        Set-ItemProperty -LiteralPath $dmKey -Name 'ExePath' -Value $idman
        Write-Ok "$dmKey\ExePath = $idman"
        Write-Warn2 'IDM 自己启动一次后可能会改写这个值，属正常。'
    }
}

# ---------------------------------------------------------------- 收尾
Write-Host ''
Write-Host '完成。接下来按顺序做：' -ForegroundColor Cyan
Write-Host '  1. 启动 IDMan.exe，保持运行'
Write-Host '  2. 完全退出 Chrome（任务管理器确认没有残留 chrome.exe），再重新打开'
Write-Host '     —— native host 的注册表项只在 Chrome 启动时读取，不重启不生效'
Write-Host '  3. chrome://extensions -> 该扩展 -> 点「Service Worker」打开控制台，执行：'
Write-Host ''
Write-Host "     chrome.runtime.sendNativeMessage('$HostName', {}, r => console.log('resp:', r, 'err:', chrome.runtime.lastError && chrome.runtime.lastError.message))" -ForegroundColor White
Write-Host ''
Write-Host '  4. 再跑一次 Diagnose-IdmNativeMessaging.ps1 确认全绿'
Write-Host ''
