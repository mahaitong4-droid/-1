#Requires -Version 5.1
<#
.SYNOPSIS
    IDM Native Messaging 全链路诊断：一次跑完，直接指出断在哪一环。

.DESCRIPTION
    Chrome 在 Windows 上启动 native messaging host 的完整链路是：

      扩展 manifest 有 nativeMessaging 权限
        -> 扩展代码调用 connectNative("<host 名>")
        -> Chrome 查注册表 HKCU/HKLM\Software\Google\Chrome\NativeMessagingHosts\<host 名>
        -> 读该键默认值指向的 JSON 文件（必须 UTF-8 无 BOM）
        -> JSON 里 name 必须与 host 名一致、type=stdio
        -> JSON 里 path 指向的 exe 必须存在
        -> JSON 里 allowed_origins 必须含 chrome-extension://<扩展ID>/（结尾斜杠不能少）
        -> Chrome 启动该 exe

    任何一环断了，进程都不会出现。本脚本逐环检查并打印结论。

.EXAMPLE
    .\Diagnose-IdmNativeMessaging.ps1 -ExtensionDir 'C:\Users\win\Doubao\chats\2026-09-01\new-chat-4\idm_ext\extracted'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [string]$IdmDir,
    [string]$ExtensionId,
    [string]$HostName
)

$ErrorActionPreference = 'Continue'
$script:Problems = New-Object System.Collections.ArrayList

function Write-Head($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Bad($t, $fix) {
    Write-Host "  [FAIL] $t" -ForegroundColor Red
    if ($fix) { Write-Host "         -> $fix" -ForegroundColor Yellow }
    [void]$script:Problems.Add($t)
}
function Write-Warn2($t) { Write-Host "  [WARN] $t" -ForegroundColor DarkYellow }
function Write-Info($t) { Write-Host "  [ .. ] $t" -ForegroundColor Gray }

function Test-IsAscii([string]$s) {
    if (-not $s) { return $true }
    foreach ($c in $s.ToCharArray()) { if ([int][char]$c -gt 127) { return $false } }
    return $true
}

function Get-FileEncodingIssue([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return 'UTF-8 BOM' }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return 'UTF-16 LE BOM' }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return 'UTF-16 BE BOM' }
    # 严格 UTF-8 解码，失败说明是 GBK/ANSI 存的
    try {
        $enc = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$enc.GetString($b)
    }
    catch { return 'not-UTF8 (疑似 GBK/ANSI)' }
    return $null
}

Write-Host ''
Write-Host '########  IDM Native Messaging 诊断  ########' -ForegroundColor White

# ---------------------------------------------------------------- 1. 扩展 manifest
Write-Head '1. 扩展 manifest.json'

if (-not (Test-Path -LiteralPath $ExtensionDir)) {
    Write-Bad "扩展目录不存在: $ExtensionDir"
    return
}
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
Write-Info "扩展目录: $ExtensionDir"

$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Bad "manifest.json 不存在于 $ExtensionDir"
    return
}

$manifest = $null
try { $manifest = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json }
catch { Write-Bad "manifest.json 解析失败: $($_.Exception.Message)"; return }

Write-Info "name = $($manifest.name)  version = $($manifest.version)  manifest_version = $($manifest.manifest_version)"

$perms = @()
if ($manifest.permissions) { $perms += $manifest.permissions }
if ($perms -contains 'nativeMessaging') {
    Write-Ok 'manifest 声明了 nativeMessaging 权限'
}
else {
    Write-Bad 'manifest.permissions 里没有 "nativeMessaging"' `
        '加进 permissions 数组。MV3 转换时最容易把它和 URL 权限一起挪到 host_permissions 而丢失。'
}

if ($manifest.manifest_version -eq 3) {
    if ($manifest.background.service_worker) {
        Write-Ok "background.service_worker = $($manifest.background.service_worker)"
    }
    else {
        Write-Bad 'MV3 但 background.service_worker 没配' '改成 { "service_worker": "sw-shim.js" }'
    }
}

if ($manifest.PSObject.Properties.Name -contains 'update_url') {
    Write-Warn2 'manifest 里有 update_url，unpacked 加载时建议删掉，避免 Chrome 尝试用商店版覆盖'
}

# 扩展 ID：优先用 key 反推，其次用命令行传入
if ($manifest.PSObject.Properties.Name -contains 'key' -and $manifest.key) {
    try {
        $pk = [Convert]::FromBase64String($manifest.key)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($pk) } finally { $sha.Dispose() }
        $hex = -join ($digest[0..15] | ForEach-Object { $_.ToString('x2') })
        $derivedId = -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32($_, 16)) })
        Write-Ok "manifest 里有 key，扩展 ID 已固定为: $derivedId"
        if (-not $ExtensionId) { $ExtensionId = $derivedId }
        elseif ($ExtensionId -ne $derivedId) {
            Write-Warn2 "你传入的 ID ($ExtensionId) 与 key 推导出的 ID ($derivedId) 不一致，以 key 为准"
            $ExtensionId = $derivedId
        }
    }
    catch { Write-Bad "manifest.key 不是合法 base64: $($_.Exception.Message)" }
}
else {
    Write-Bad 'manifest.json 里没有 "key" 字段' `
        '这意味着扩展 ID 是按目录路径现算的，换目录就变。跑 Get-CrxKey.ps1 -PatchManifest 把官方公钥写回去，ID 就固定成官方 ID，IDM 自带白名单直接命中。'
}

if (-not $ExtensionId) {
    Write-Warn2 '没有扩展 ID，后面的白名单比对会跳过。请到 chrome://extensions 复制 ID 后用 -ExtensionId 重跑。'
}
else {
    Write-Info "本次比对使用的扩展 ID: $ExtensionId"
}

# ---------------------------------------------------------------- 2. host 名
Write-Head '2. 扩展代码里请求的 native host 名'

$hostNames = New-Object System.Collections.Generic.HashSet[string]
if ($HostName) { [void]$hostNames.Add($HostName) }

$jsFiles = Get-ChildItem -LiteralPath $ExtensionDir -Recurse -Filter '*.js' -File -ErrorAction SilentlyContinue
foreach ($f in $jsFiles) {
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($m in [regex]::Matches($content, '(?:connectNative|sendNativeMessage)\s*\(\s*[''"]([^''"]+)[''"]')) {
        [void]$hostNames.Add($m.Groups[1].Value)
    }
}

if ($hostNames.Count -eq 0) {
    Write-Bad '在扩展 JS 里没找到 connectNative/sendNativeMessage 调用' `
        '要么 MV3 转换时 background 脚本没被正确引入，要么代码被压缩成了动态拼接的字符串。用 -HostName 手工指定，IDM 通常是 com.internetdownloadmanager.pdmbehavior'
}
else {
    foreach ($h in $hostNames) { Write-Ok "扩展会连接: $h" }
}

# ---------------------------------------------------------------- 3. 注册表
Write-Head '3. 注册表（Chrome 找 host 的唯一入口）'

$regRoots = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKLM:\Software\Google\Chrome\NativeMessagingHosts',
    'HKLM:\Software\Wow6432Node\Google\Chrome\NativeMessagingHosts',
    'HKCU:\Software\Chromium\NativeMessagingHosts',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
)

$foundManifests = New-Object System.Collections.ArrayList
foreach ($hn in $hostNames) {
    $anyHit = $false
    foreach ($root in $regRoots) {
        $key = Join-Path $root $hn
        if (Test-Path -LiteralPath $key) {
            $val = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
            if ($val) {
                Write-Ok "$key = $val"
                [void]$foundManifests.Add([PSCustomObject]@{ Host = $hn; Key = $key; Path = $val })
                $anyHit = $true
            }
            else {
                Write-Bad "$key 存在但默认值为空" '默认值必须是 host manifest JSON 的完整路径'
            }
        }
    }
    if (-not $anyHit) {
        Write-Bad "注册表里完全没有 '$hn' 的登记项" `
            "这就是 IDMMsgHost.exe 从不启动的直接原因 —— Chrome 在 Windows 上不扫描目录，只查注册表。跑 Repair-IdmNativeMessaging.ps1 修。"
    }
}

# ---------------------------------------------------------------- 4. host manifest JSON
Write-Head '4. host manifest JSON 内容'

if ($foundManifests.Count -eq 0) {
    Write-Warn2 '没有可检查的 JSON（注册表没指向任何文件），跳过'
}

foreach ($fm in $foundManifests) {
    Write-Host "  --- $($fm.Path)"
    if (-not (Test-Path -LiteralPath $fm.Path)) {
        Write-Bad "注册表指向的 JSON 不存在: $($fm.Path)" '路径写错了，或文件被 IDM 便携版清理掉了'
        continue
    }

    $encIssue = Get-FileEncodingIssue -Path $fm.Path
    if ($encIssue) {
        Write-Bad "JSON 编码有问题: $encIssue" `
            'Chrome 只接受 UTF-8 无 BOM。路径里有中文时用记事本另存为 ANSI 会直接让 Chrome 解析失败/取到乱码路径。'
    }
    else { Write-Ok 'JSON 编码为 UTF-8 无 BOM' }

    $hj = $null
    try { $hj = (Get-Content -Raw -LiteralPath $fm.Path -Encoding UTF8) | ConvertFrom-Json }
    catch { Write-Bad "JSON 解析失败: $($_.Exception.Message)"; continue }

    if ($hj.name -eq $fm.Host) { Write-Ok "name 与注册表键名一致: $($hj.name)" }
    else { Write-Bad "JSON 里 name='$($hj.name)' 与注册表键名 '$($fm.Host)' 不一致" '两者必须逐字符相同，否则 Chrome 报 host not found' }

    if ($hj.type -eq 'stdio') { Write-Ok 'type = stdio' }
    else { Write-Bad "type='$($hj.type)'，必须是 stdio" }

    $exe = $hj.path
    if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) {
        $exe = Join-Path (Split-Path -Parent $fm.Path) $exe
    }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        Write-Ok "path 指向的可执行文件存在: $exe"
        if (-not (Test-IsAscii $exe)) {
            Write-Bad "host 可执行文件路径含非 ASCII 字符: $exe" `
                '中文路径 + 非 UTF-8 的 JSON 是这类问题的高发组合。Repair 脚本会自动改写成 8.3 短路径规避。'
        }
    }
    else {
        Write-Bad "path 指向的可执行文件不存在: $exe" 'IDM 便携版换过目录时最常见'
    }

    $origins = @()
    if ($hj.allowed_origins) { $origins += $hj.allowed_origins }
    if ($origins.Count -eq 0) {
        Write-Bad 'allowed_origins 为空' '必须至少含一条 chrome-extension://<扩展ID>/'
    }
    else {
        foreach ($o in $origins) {
            if ($o -notmatch '/$') { Write-Bad "allowed_origins 条目结尾缺少斜杠: $o" '必须写成 chrome-extension://xxxx/ ，少一个斜杠就永远匹配不上' }
        }
        if ($ExtensionId) {
            $want = "chrome-extension://$ExtensionId/"
            if ($origins -contains $want) { Write-Ok "白名单命中当前扩展 ID: $want" }
            else {
                Write-Bad "白名单里没有当前扩展 ID ($want)" `
                    "现有条目: $($origins -join ', ')"
            }
        }
    }
}

# ---------------------------------------------------------------- 5. IDM 本体
Write-Head '5. IDM 本体'

if (-not $IdmDir -and $foundManifests.Count -gt 0) {
    $p = $foundManifests[0].Path
    $IdmDir = Split-Path -Parent $p
}
if ($IdmDir -and (Test-Path -LiteralPath $IdmDir)) {
    Write-Info "IDM 目录: $IdmDir"
    foreach ($n in @('IDMan.exe', 'IDMMsgHost.exe')) {
        $p = Join-Path $IdmDir $n
        if (Test-Path -LiteralPath $p) { Write-Ok "$n 存在" } else { Write-Bad "$n 不在 $IdmDir" }
    }
    if (-not (Test-IsAscii $IdmDir)) {
        Write-Warn2 "IDM 目录含中文: $IdmDir —— 本身不致命，但要求 host manifest 必须是严格 UTF-8"
    }
}
else {
    Write-Warn2 '没有确定 IDM 目录，用 -IdmDir 指定可做更多检查'
}

$idmProc = Get-Process -Name 'IDMan' -ErrorAction SilentlyContinue
if ($idmProc) { Write-Ok "IDMan.exe 正在运行 (PID $($idmProc[0].Id))" }
else { Write-Bad 'IDMan.exe 没在运行' 'IDMMsgHost 需要把下载交给 IDM 主进程。测试 native messaging 时先把 IDM 开着。' }

$hostProc = Get-Process -Name 'IDMMsgHost' -ErrorAction SilentlyContinue
if ($hostProc) { Write-Info "IDMMsgHost.exe 当前在运行 (PID $($hostProc[0].Id)) —— 说明 Chrome 已经成功拉起过它" }
else { Write-Info 'IDMMsgHost.exe 当前不在运行（只有 Chrome 连接时它才存在，属正常现象）' }

$dmKey = 'HKCU:\Software\DownloadManager'
if (Test-Path -LiteralPath $dmKey) {
    Write-Ok "$dmKey 存在（IDM 各组件互相定位靠它）"
    $expath = (Get-ItemProperty -LiteralPath $dmKey -ErrorAction SilentlyContinue).ExePath
    if ($expath) { Write-Info "ExePath = $expath" }
    else { Write-Warn2 'ExePath 值不存在。便携版常见，IDMMsgHost 可能因此找不到 IDMan.exe，表现就是「Cannot launch IDM」。' }
}
else {
    Write-Bad "$dmKey 不存在" `
        '便携版没在注册表登记自己。IDMMsgHost.exe 即使被拉起，也可能因为找不到 IDMan.exe 而直接退出 —— 这正对应「Cannot launch IDM」这句提示。先手工运行一次 IDMan.exe 让它自建注册表。'
}

# ---------------------------------------------------------------- 汇总
Write-Head '结论'
if ($script:Problems.Count -eq 0) {
    Write-Host '  链路各环都正常。' -ForegroundColor Green
    Write-Host '  若扩展仍报错，到 chrome://extensions 点该扩展的 Service Worker，在控制台执行：' -ForegroundColor Yellow
}
else {
    Write-Host "  发现 $($script:Problems.Count) 个问题：" -ForegroundColor Red
    $i = 1
    foreach ($p in $script:Problems) { Write-Host "   $i. $p" -ForegroundColor Red; $i++ }
    Write-Host ''
    Write-Host '  修复：.\Repair-IdmNativeMessaging.ps1 -ExtensionDir "..." -IdmDir "..."' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  另外强烈建议在 Service Worker 控制台跑一次这句，Chrome 的原始报错最能说明问题：' -ForegroundColor Yellow
}

$probeHost = if ($hostNames.Count -gt 0) { @($hostNames)[0] } else { 'com.internetdownloadmanager.pdmbehavior' }
Write-Host ''
Write-Host "    chrome.runtime.sendNativeMessage('$probeHost', {}, r => console.log('resp:', r, 'err:', chrome.runtime.lastError && chrome.runtime.lastError.message))" -ForegroundColor White
Write-Host ''
Write-Host '  报错字符串对应的病根：' -ForegroundColor Yellow
Write-Host '    "Specified native messaging host not found."        -> 注册表没登记 / 键名与 JSON 的 name 不一致 / JSON 路径不存在'
Write-Host '    "Access to the specified native messaging host is forbidden." -> 扩展 ID 不在 allowed_origins（或缺结尾斜杠）/ 没有 nativeMessaging 权限'
Write-Host '    "Failed to start native messaging host."            -> JSON 里 path 不可执行 / 路径编码错乱 / 权限不足'
Write-Host '    "Native host has exited."                           -> exe 拉起来了但自己退了 -> 是 IDM 侧问题（找不到 IDMan.exe），不是 Chrome 侧'
Write-Host ''
