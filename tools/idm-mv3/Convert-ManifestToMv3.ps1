#Requires -Version 5.1
<#
.SYNOPSIS
    把 MV2 的 manifest.json 正确转成 MV3，并装好 service worker 兼容层。

.DESCRIPTION
    手工做 MV2->MV3 转换时最容易踩的几个坑，这里一次性处理掉：

      * permissions 里的 URL 匹配串必须挪到 host_permissions，
        但 nativeMessaging 这种 API 权限必须【留在】permissions —— 一起挪走就没法连 native host 了，
        这正是"扩展能加载、就是连不上 IDM"的典型原因。
      * background.scripts -> background.service_worker，
        并把原脚本列表写进 sw-shim.js，由它用 importScripts 保持经典全局作用域。
      * browser_action / page_action -> action
      * content_security_policy 由字符串改为对象，并去掉 MV3 禁止的 unsafe-eval / 远程脚本源
      * web_accessible_resources 由字符串数组改为对象数组
      * 补上 storage / alarms 权限（sw-shim.js 的 localStorage 模拟和保活要用）
      * 删掉 update_url，避免 Chrome 拿商店版覆盖本地解压版

    原 manifest.json 会备份为 manifest.json.mv2.bak。

.EXAMPLE
    .\Convert-ManifestToMv3.ps1 -ExtensionDir 'C:\...\idm_ext\extracted'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($t) { Write-Host ''; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "   [OK] $t" -ForegroundColor Green }
function Write-Warn2($t) { Write-Host "   [!!] $t" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $ExtensionDir)) { throw "扩展目录不存在: $ExtensionDir" }
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json 不存在: $manifestPath" }

$m = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json
Write-Host ''
Write-Host "扩展: $($m.name)  版本: $($m.version)  当前 manifest_version: $($m.manifest_version)" -ForegroundColor White

$backgroundScripts = @('background.js')

# ---------------------------------------------------------------- background
Write-Step 'background'
if ($m.background) {
    if ($m.background.scripts) {
        $backgroundScripts = @($m.background.scripts)
        Write-Ok "原 background.scripts: $($backgroundScripts -join ', ')"
    }
    elseif ($m.background.page) {
        Write-Warn2 "原来是 background.page ($($m.background.page))，无法自动转换。"
        Write-Warn2 '请手工打开该 HTML，把里面 <script src=...> 的顺序抄进 sw-shim.js 的 BACKGROUND_SCRIPTS。'
    }
    elseif ($m.background.service_worker) {
        Write-Ok "已经是 service_worker: $($m.background.service_worker)"
        if ($m.background.service_worker -ne 'sw-shim.js') {
            $backgroundScripts = @($m.background.service_worker)
            Write-Warn2 "将改为由 sw-shim.js 引入 $($m.background.service_worker)"
        }
        else {
            $shimPath = Join-Path $ExtensionDir 'sw-shim.js'
            if (Test-Path -LiteralPath $shimPath) {
                $existing = Get-Content -Raw -LiteralPath $shimPath
                $mm = [regex]::Match($existing, "BACKGROUND_SCRIPTS\s*=\s*\[([^\]]*)\]")
                if ($mm.Success) {
                    $backgroundScripts = @([regex]::Matches($mm.Groups[1].Value, "['""]([^'""]+)['""]") | ForEach-Object { $_.Groups[1].Value })
                    Write-Ok "沿用 sw-shim.js 里已配置的: $($backgroundScripts -join ', ')"
                }
            }
        }
    }
}
foreach ($s in $backgroundScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $ExtensionDir $s))) {
        Write-Warn2 "脚本不存在: $s —— sw-shim.js 会在 importScripts 时报错"
    }
}
$m | Add-Member -NotePropertyName 'background' -NotePropertyValue ([PSCustomObject]@{ service_worker = 'sw-shim.js' }) -Force
Write-Ok 'background = { "service_worker": "sw-shim.js" }'

# ---------------------------------------------------------------- permissions
Write-Step 'permissions / host_permissions'
$apiPerms = New-Object System.Collections.Generic.List[string]
$hostPerms = New-Object System.Collections.Generic.List[string]

$existingHost = @()
if ($m.PSObject.Properties.Name -contains 'host_permissions') { $existingHost = @($m.host_permissions) }
foreach ($h in $existingHost) { if (-not $hostPerms.Contains($h)) { $hostPerms.Add($h) } }

$dropped = New-Object System.Collections.Generic.List[string]
foreach ($p in @($m.permissions)) {
    if (-not $p) { continue }
    $s = [string]$p
    if ($s -eq '<all_urls>' -or $s -match '://' -or $s -match '^\*') {
        if (-not $hostPerms.Contains($s)) { $hostPerms.Add($s) }
    }
    elseif ($s -eq 'webRequestBlocking') {
        $dropped.Add($s)
    }
    else {
        if (-not $apiPerms.Contains($s)) { $apiPerms.Add($s) }
    }
}

# 这三个是必须的：nativeMessaging 连 IDM，storage 撑 localStorage 模拟，alarms 撑 service worker 保活
foreach ($need in @('nativeMessaging', 'storage', 'alarms')) {
    if (-not $apiPerms.Contains($need)) { $apiPerms.Add($need); Write-Ok "补上缺失权限: $need" }
}

$m | Add-Member -NotePropertyName 'permissions' -NotePropertyValue ([string[]]$apiPerms) -Force
if ($hostPerms.Count -gt 0) {
    $m | Add-Member -NotePropertyName 'host_permissions' -NotePropertyValue ([string[]]$hostPerms) -Force
}
Write-Ok "permissions      = $($apiPerms -join ', ')"
Write-Ok "host_permissions = $($hostPerms -join ', ')"
if ($dropped.Count -gt 0) {
    Write-Warn2 "已移除 MV3 不支持的权限: $($dropped -join ', ')"
    Write-Warn2 'MV3 里 webRequest 只能观察不能拦截改写。IDM 主要靠观察请求头 + downloads 接管，通常够用；'
    Write-Warn2 '若确实需要拦截，得改用 declarativeNetRequest 重写，那是另一项工程。'
}

# ---------------------------------------------------------------- action
Write-Step 'browser_action / page_action -> action'
$actionSrc = $null
if ($m.PSObject.Properties.Name -contains 'browser_action') { $actionSrc = $m.browser_action; $m.PSObject.Properties.Remove('browser_action') }
elseif ($m.PSObject.Properties.Name -contains 'page_action') { $actionSrc = $m.page_action; $m.PSObject.Properties.Remove('page_action') }
if ($actionSrc) {
    $m | Add-Member -NotePropertyName 'action' -NotePropertyValue $actionSrc -Force
    Write-Ok '已转为 action'
}
elseif ($m.PSObject.Properties.Name -contains 'action') { Write-Ok 'action 已存在' }
else { Write-Ok '没有 action，跳过' }

# ---------------------------------------------------------------- CSP
Write-Step 'content_security_policy'
if ($m.PSObject.Properties.Name -contains 'content_security_policy') {
    $csp = $m.content_security_policy
    if ($csp -is [string]) {
        $clean = $csp -replace "'unsafe-eval'", '' -replace 'https://[^\s;]+', ''
        $clean = ($clean -replace '\s+', ' ').Trim()
        $m | Add-Member -NotePropertyName 'content_security_policy' -NotePropertyValue ([PSCustomObject]@{ extension_pages = $clean }) -Force
        Write-Ok "已转为对象形式: $clean"
        Write-Warn2 'MV3 禁止 unsafe-eval 和远程脚本源，已从 CSP 中剔除。'
    }
    else { Write-Ok '已经是对象形式' }
}
else { Write-Ok '没有自定义 CSP，跳过' }

# ---------------------------------------------------------------- web_accessible_resources
Write-Step 'web_accessible_resources'
if ($m.PSObject.Properties.Name -contains 'web_accessible_resources') {
    $war = @($m.web_accessible_resources)
    if ($war.Count -gt 0 -and ($war[0] -is [string])) {
        $newWar = @([PSCustomObject]@{ resources = [string[]]$war; matches = @('<all_urls>') })
        $m | Add-Member -NotePropertyName 'web_accessible_resources' -NotePropertyValue $newWar -Force
        Write-Ok "已转为对象数组形式（$($war.Count) 个资源）"
    }
    else { Write-Ok '已经是对象数组形式' }
}
else { Write-Ok '没有 web_accessible_resources，跳过' }

# ---------------------------------------------------------------- 杂项
Write-Step '杂项'
if ($m.PSObject.Properties.Name -contains 'update_url') {
    $m.PSObject.Properties.Remove('update_url')
    Write-Ok '已删除 update_url'
}
if ($m.PSObject.Properties.Name -contains 'key' -and $m.key) {
    Write-Ok 'key 存在，扩展 ID 会保持固定'
}
else {
    Write-Warn2 'manifest 里没有 "key"。先跑 Get-CrxKey.ps1 -PatchManifest 把 CRX 原始公钥写回去，'
    Write-Warn2 '否则扩展 ID 随目录路径变化，IDM 的 native host 白名单永远对不上。'
}
$m | Add-Member -NotePropertyName 'manifest_version' -NotePropertyValue 3 -Force
Write-Ok 'manifest_version = 3'

# ---------------------------------------------------------------- 落盘
Write-Step '写入'
$json = $m | ConvertTo-Json -Depth 20

if ($WhatIfOnly) {
    Write-Host '--- 将写入的 manifest.json ---' -ForegroundColor DarkGray
    Write-Host $json
    Write-Host ''
    Write-Host "--- sw-shim.js 的 BACKGROUND_SCRIPTS 将设为: $($backgroundScripts -join ', ') ---" -ForegroundColor DarkGray
    return
}

$backup = Join-Path $ExtensionDir 'manifest.json.mv2.bak'
if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $manifestPath -Destination $backup
    Write-Ok "已备份原 manifest -> $backup"
}
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "manifest.json 已写入（UTF-8 无 BOM）"

# 装 sw-shim.js 并写入脚本列表
$shimSrc = Join-Path $PSScriptRoot 'mv3\sw-shim.js'
$shimDst = Join-Path $ExtensionDir 'sw-shim.js'
if (-not (Test-Path -LiteralPath $shimSrc)) { throw "找不到 sw-shim.js: $shimSrc" }
$shim = Get-Content -Raw -LiteralPath $shimSrc
$listLiteral = '[' + (($backgroundScripts | ForEach-Object { "'" + $_ + "'" }) -join ', ') + ']'
# 按行替换而不是 regex 替换：.NET 的替换串里 $ 有特殊含义，文件名含 $ 时会被吃掉
$lines = $shim -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^const BACKGROUND_SCRIPTS = \[') {
        $lines[$i] = "const BACKGROUND_SCRIPTS = $listLiteral;"
    }
}
$shim = $lines -join "`r`n"
[System.IO.File]::WriteAllText($shimDst, $shim, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "sw-shim.js 已装入扩展目录，BACKGROUND_SCRIPTS = $listLiteral"

Write-Host ''
Write-Host '完成。接下来：' -ForegroundColor Cyan
Write-Host '  1. chrome://extensions -> 该扩展 -> 「重新加载」'
Write-Host '  2. 点开 Service Worker 控制台，确认没有红色报错，且能看到 [idm-shim] 已载入: ...'
Write-Host '  3. 跑 Repair-IdmNativeMessaging.ps1 处理注册表和 host manifest'
Write-Host ''
