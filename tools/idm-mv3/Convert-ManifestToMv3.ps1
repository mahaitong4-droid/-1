#Requires -Version 5.1
<#
.SYNOPSIS
    Convert an MV2 manifest.json to MV3 correctly and install the service worker shim.

.DESCRIPTION
    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files with the system ANSI
    codepage unless the file carries a UTF-8 BOM, which corrupts non-ASCII text and breaks
    quote pairing.

    Handles the parts of an MV2->MV3 conversion that are easy to get wrong by hand:

      * URL match patterns move to host_permissions, but API permissions such as
        nativeMessaging must STAY in permissions. Moving nativeMessaging out is a common
        mistake and produces an extension that loads fine but can never reach IDM.
      * background.scripts -> background.service_worker, with the original script list
        handed to sw-shim.js, which importScripts them to preserve classic global scope.
      * browser_action / page_action -> action
      * content_security_policy string -> object, with unsafe-eval and remote script
        sources removed (MV3 forbids both)
      * web_accessible_resources string array -> object array
      * adds storage and alarms (needed by the shim's localStorage emulation and keepalive)
      * removes update_url so Chrome does not try to replace the local build

    The original file is backed up as manifest.json.mv2.bak.

.EXAMPLE
    .\Convert-ManifestToMv3.ps1 -ExtensionDir 'C:\idm_ext\extracted' -WhatIfOnly
    .\Convert-ManifestToMv3.ps1 -ExtensionDir 'C:\idm_ext\extracted'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step($t) { Write-Host ''; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "   [OK]   $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "   [note] $t" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $ExtensionDir)) { throw "extension directory not found: $ExtensionDir" }
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json not found: $manifestPath" }

$m = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json
Write-Host ''
Write-Host "extension: $($m.name)  version: $($m.version)  current manifest_version: $($m.manifest_version)" -ForegroundColor White

$backgroundScripts = @('background.js')

# ---------------------------------------------------------------- background
Write-Step 'background'
if ($m.background) {
    if ($m.background.scripts) {
        $backgroundScripts = @($m.background.scripts)
        Write-Ok "original background.scripts: $($backgroundScripts -join ', ')"
    }
    elseif ($m.background.page) {
        Write-Note "original is background.page ($($m.background.page)), which cannot be converted automatically."
        Write-Note 'Open that HTML and copy its <script src=...> order into BACKGROUND_SCRIPTS in sw-shim.js.'
    }
    elseif ($m.background.service_worker) {
        Write-Ok "already a service worker: $($m.background.service_worker)"
        if ($m.background.service_worker -ne 'sw-shim.js') {
            $backgroundScripts = @($m.background.service_worker)
            Write-Note "sw-shim.js will import $($m.background.service_worker)"
        }
        else {
            $shimPath = Join-Path $ExtensionDir 'sw-shim.js'
            if (Test-Path -LiteralPath $shimPath) {
                $existing = Get-Content -Raw -LiteralPath $shimPath
                $mm = [regex]::Match($existing, "BACKGROUND_SCRIPTS\s*=\s*\[([^\]]*)\]")
                if ($mm.Success) {
                    $backgroundScripts = @([regex]::Matches($mm.Groups[1].Value, "['""]([^'""]+)['""]") | ForEach-Object { $_.Groups[1].Value })
                    Write-Ok "keeping the list already configured in sw-shim.js: $($backgroundScripts -join ', ')"
                }
            }
        }
    }
}
foreach ($s in $backgroundScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $ExtensionDir $s))) {
        Write-Note "script not found: $s - sw-shim.js will fail at importScripts"
    }
}
$m | Add-Member -NotePropertyName 'background' -NotePropertyValue ([PSCustomObject]@{ service_worker = 'sw-shim.js' }) -Force
Write-Ok 'background = { "service_worker": "sw-shim.js" }'

# ---------------------------------------------------------------- permissions
Write-Step 'permissions / host_permissions'
$apiPerms = New-Object System.Collections.Generic.List[string]
$hostPerms = New-Object System.Collections.Generic.List[string]

if ($m.PSObject.Properties.Name -contains 'host_permissions') {
    foreach ($h in @($m.host_permissions)) { if ($h -and -not $hostPerms.Contains($h)) { $hostPerms.Add($h) } }
}

$dropped = New-Object System.Collections.Generic.List[string]
foreach ($p in @($m.permissions)) {
    if (-not $p) { continue }
    $s = [string]$p
    if ($s -eq '<all_urls>' -or $s -match '://' -or $s -match '^\*') {
        if (-not $hostPerms.Contains($s)) { $hostPerms.Add($s) }
    }
    elseif ($s -eq 'webRequestBlocking') { $dropped.Add($s) }
    else { if (-not $apiPerms.Contains($s)) { $apiPerms.Add($s) } }
}

foreach ($need in @('nativeMessaging', 'storage', 'alarms')) {
    if (-not $apiPerms.Contains($need)) { $apiPerms.Add($need); Write-Ok "added missing permission: $need" }
}

$m | Add-Member -NotePropertyName 'permissions' -NotePropertyValue ([string[]]$apiPerms) -Force
if ($hostPerms.Count -gt 0) { $m | Add-Member -NotePropertyName 'host_permissions' -NotePropertyValue ([string[]]$hostPerms) -Force }
Write-Ok "permissions      = $($apiPerms -join ', ')"
Write-Ok "host_permissions = $($hostPerms -join ', ')"
if ($dropped.Count -gt 0) {
    Write-Note "removed permissions MV3 does not support: $($dropped -join ', ')"
    Write-Note 'Under MV3 webRequest can observe but not block or rewrite. IDM mainly observes headers and'
    Write-Note 'takes over via the downloads API, which still works; true blocking needs declarativeNetRequest.'
}

# ---------------------------------------------------------------- action
Write-Step 'browser_action / page_action -> action'
$actionSrc = $null
if ($m.PSObject.Properties.Name -contains 'browser_action') { $actionSrc = $m.browser_action; $m.PSObject.Properties.Remove('browser_action') }
elseif ($m.PSObject.Properties.Name -contains 'page_action') { $actionSrc = $m.page_action; $m.PSObject.Properties.Remove('page_action') }
if ($actionSrc) { $m | Add-Member -NotePropertyName 'action' -NotePropertyValue $actionSrc -Force; Write-Ok 'converted to action' }
elseif ($m.PSObject.Properties.Name -contains 'action') { Write-Ok 'action already present' }
else { Write-Ok 'no action, skipping' }

# ---------------------------------------------------------------- CSP
Write-Step 'content_security_policy'
if ($m.PSObject.Properties.Name -contains 'content_security_policy') {
    $csp = $m.content_security_policy
    if ($csp -is [string]) {
        $clean = $csp -replace "'unsafe-eval'", '' -replace 'https://[^\s;]+', ''
        $clean = ($clean -replace '\s+', ' ').Trim()
        $m | Add-Member -NotePropertyName 'content_security_policy' -NotePropertyValue ([PSCustomObject]@{ extension_pages = $clean }) -Force
        Write-Ok "converted to object form: $clean"
        Write-Note 'MV3 forbids unsafe-eval and remote script sources; both were stripped.'
    }
    else { Write-Ok 'already in object form' }
}
else { Write-Ok 'no custom CSP, skipping' }

# ---------------------------------------------------------------- web_accessible_resources
Write-Step 'web_accessible_resources'
if ($m.PSObject.Properties.Name -contains 'web_accessible_resources') {
    $war = @($m.web_accessible_resources)
    if ($war.Count -gt 0 -and ($war[0] -is [string])) {
        $newWar = @([PSCustomObject]@{ resources = [string[]]$war; matches = @('<all_urls>') })
        $m | Add-Member -NotePropertyName 'web_accessible_resources' -NotePropertyValue $newWar -Force
        Write-Ok "converted to object array form ($($war.Count) resources)"
    }
    else { Write-Ok 'already in object array form' }
}
else { Write-Ok 'no web_accessible_resources, skipping' }

# ---------------------------------------------------------------- misc
Write-Step 'misc'
if ($m.PSObject.Properties.Name -contains 'update_url') { $m.PSObject.Properties.Remove('update_url'); Write-Ok 'removed update_url' }
if (($m.PSObject.Properties.Name -contains 'key') -and $m.key) { Write-Ok 'key present, extension ID stays fixed' }
else {
    Write-Note 'manifest has no "key". Run Get-CrxKey.ps1 -PatchManifest (or Setup-IdmIntegration.ps1 -CrxPath)'
    Write-Note 'to pin the ID, otherwise it changes with the directory path and no allowlist can keep up.'
}
$m | Add-Member -NotePropertyName 'manifest_version' -NotePropertyValue 3 -Force
Write-Ok 'manifest_version = 3'

# ---------------------------------------------------------------- write
Write-Step 'writing'
$json = $m | ConvertTo-Json -Depth 20

if ($WhatIfOnly) {
    Write-Host '--- manifest.json that would be written ---' -ForegroundColor DarkGray
    Write-Host $json
    Write-Host ''
    Write-Host "--- sw-shim.js BACKGROUND_SCRIPTS would become: $($backgroundScripts -join ', ') ---" -ForegroundColor DarkGray
    return
}

$backup = Join-Path $ExtensionDir 'manifest.json.mv2.bak'
if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $manifestPath -Destination $backup
    Write-Ok "backed up original manifest -> $backup"
}
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok 'manifest.json written (UTF-8 no BOM)'

$shimSrc = Join-Path $PSScriptRoot 'mv3\sw-shim.js'
$shimDst = Join-Path $ExtensionDir 'sw-shim.js'
if (-not (Test-Path -LiteralPath $shimSrc)) { throw "sw-shim.js not found next to this script: $shimSrc" }
$shim = Get-Content -Raw -LiteralPath $shimSrc
$listLiteral = '[' + (($backgroundScripts | ForEach-Object { "'" + $_ + "'" }) -join ', ') + ']'
# Line replacement rather than regex replacement: in a .NET replacement string $ is special,
# so a filename containing $ would be silently mangled.
$lines = $shim -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^const BACKGROUND_SCRIPTS = \[') {
        $lines[$i] = "const BACKGROUND_SCRIPTS = $listLiteral;"
    }
}
$shim = $lines -join "`r`n"
[System.IO.File]::WriteAllText($shimDst, $shim, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "installed sw-shim.js, BACKGROUND_SCRIPTS = $listLiteral"

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. chrome://extensions -> Reload on this extension'
Write-Host '  2. Open its Service Worker console; there should be no red errors and you should see'
Write-Host '     [idm-shim] loaded: ...'
Write-Host '  3. Run Setup-IdmIntegration.ps1 to handle the registry and host manifest'
Write-Host ''
