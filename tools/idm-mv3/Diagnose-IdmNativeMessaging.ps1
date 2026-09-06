#Requires -Version 5.1
<#
.SYNOPSIS
    Check every link in the IDM native messaging chain and report which one is broken.

.DESCRIPTION
    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files with the system ANSI
    codepage unless the file carries a UTF-8 BOM, which corrupts non-ASCII text and breaks
    quote pairing. Keeping the script in ASCII makes it immune to that.

    The chain Chrome walks on Windows:

      manifest.json declares the nativeMessaging permission
        -> extension code calls connectNative("<host name>")
        -> Chrome reads HKCU/HKLM\Software\Google\Chrome\NativeMessagingHosts\<host name>
        -> opens the JSON file that key's default value points at (must be UTF-8, no BOM)
        -> JSON "name" must equal the host name, "type" must be stdio
        -> the executable named by "path" must exist
        -> allowed_origins must contain chrome-extension://<extension id>/  (trailing slash!)
        -> Chrome launches the executable

    Break any link and the host process never appears.

.EXAMPLE
    .\Diagnose-IdmNativeMessaging.ps1 -ExtensionDir 'C:\Users\win\idm_ext\extracted'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [string]$IdmDir,
    [string]$ExtensionId,
    [string[]]$HostNames
)

$ErrorActionPreference = 'Continue'

# This script targets Windows: it reads and writes the Windows registry, which is where
# Chrome looks for native messaging hosts. Fail fast with a clear message elsewhere,
# instead of emitting a wall of "drive HKCU does not exist" errors.
# ($PSVersionTable.Platform does not exist on Windows PowerShell 5.1, so this is a no-op there.)
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw "This script only runs on Windows (it needs the Windows registry). Detected platform: $($PSVersionTable.Platform)"
}

$script:Problems = New-Object System.Collections.ArrayList

function Write-Head($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "  [ OK ] $t" -ForegroundColor Green }
function Write-Bad($t, $fix) {
    Write-Host "  [FAIL] $t" -ForegroundColor Red
    if ($fix) { Write-Host "         -> $fix" -ForegroundColor Yellow }
    [void]$script:Problems.Add($t)
}
function Write-Note($t) { Write-Host "  [note] $t" -ForegroundColor DarkYellow }
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
    try {
        $enc = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$enc.GetString($b)
    }
    catch { return 'not valid UTF-8 (looks like GBK/ANSI)' }
    return $null
}

Write-Host ''
Write-Host '########  IDM native messaging diagnostics  ########' -ForegroundColor White

# ---------------------------------------------------------------- 1. manifest
Write-Head '1. Extension manifest.json'

if (-not (Test-Path -LiteralPath $ExtensionDir)) { Write-Bad "extension directory not found: $ExtensionDir"; return }
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
Write-Info "extension directory: $ExtensionDir"

$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Bad "manifest.json not found in $ExtensionDir"; return }

$manifest = $null
try { $manifest = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json }
catch { Write-Bad "manifest.json failed to parse: $($_.Exception.Message)"; return }

Write-Info "name=$($manifest.name)  version=$($manifest.version)  manifest_version=$($manifest.manifest_version)"

$perms = @()
if ($manifest.permissions) { $perms += $manifest.permissions }
if ($perms -contains 'nativeMessaging') { Write-Ok 'manifest declares the nativeMessaging permission' }
else {
    Write-Bad 'manifest.permissions does not contain "nativeMessaging"' `
        'Add it back. MV2->MV3 conversion often moves it into host_permissions together with the URL patterns, which silently disables native messaging.'
}

if ($manifest.manifest_version -eq 3) {
    if ($manifest.background.service_worker) { Write-Ok "background.service_worker = $($manifest.background.service_worker)" }
    else { Write-Bad 'manifest_version is 3 but background.service_worker is missing' 'Set background to { "service_worker": "sw-shim.js" }' }
}

if ($manifest.PSObject.Properties.Name -contains 'update_url') {
    Write-Note 'manifest has update_url; remove it for an unpacked extension so Chrome does not try to replace it with a store build'
}

if (($manifest.PSObject.Properties.Name -contains 'key') -and $manifest.key) {
    try {
        $pk = [Convert]::FromBase64String($manifest.key)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($pk) } finally { $sha.Dispose() }
        $hex = -join ($digest[0..15] | ForEach-Object { $_.ToString('x2') })
        $derivedId = -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32($_, 16)) })
        Write-Ok "manifest has a key; extension ID is pinned to $derivedId"
        if (-not $ExtensionId) { $ExtensionId = $derivedId }
        elseif ($ExtensionId -ne $derivedId) {
            Write-Note "supplied ID ($ExtensionId) differs from the key-derived ID ($derivedId); using the key-derived one"
            $ExtensionId = $derivedId
        }
    }
    catch { Write-Bad "manifest.key is not valid base64: $($_.Exception.Message)" }
}
else {
    Write-Bad 'manifest.json has no "key" field' `
        'Without it the extension ID is derived from the directory path and changes whenever the extension moves. Run Setup-IdmIntegration.ps1 -CrxPath ... to pin it to the official ID.'
}

if (-not $ExtensionId) { Write-Note 'no extension ID available; the allowed_origins comparison will be skipped. Pass -ExtensionId <id from chrome://extensions>.' }
else { Write-Info "comparing against extension ID: $ExtensionId" }

# ---------------------------------------------------------------- 2. host names
Write-Head '2. Native host name requested by the extension'

$names = New-Object System.Collections.Generic.List[string]
if ($HostNames) { foreach ($h in $HostNames) { if ($h -and -not $names.Contains($h)) { $names.Add($h) } } }

$detected = New-Object System.Collections.Generic.List[string]
$jsFiles = Get-ChildItem -LiteralPath $ExtensionDir -Recurse -Filter '*.js' -File -ErrorAction SilentlyContinue
foreach ($f in $jsFiles) {
    $content = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($m in [regex]::Matches($content, '(?:connectNative|sendNativeMessage)\s*\(\s*[''"]([^''"]+)[''"]')) {
        $v = $m.Groups[1].Value
        if (-not $detected.Contains($v)) { $detected.Add($v) }
    }
}

if ($detected.Count -gt 0) {
    foreach ($d in $detected) { Write-Ok "found in extension code: $d"; if (-not $names.Contains($d)) { $names.Add($d) } }
}
else {
    Write-Bad 'no connectNative/sendNativeMessage call found in the extension JS' `
        'Either the background script is not being loaded after the MV3 conversion, or the code is minified and builds the name at runtime. Checking the known candidates instead.'
}
foreach ($cand in @('com.internetdownloadmanager.pdmbehavior', 'com.tonec.idm')) {
    if (-not $names.Contains($cand)) { $names.Add($cand); Write-Info "also checking candidate: $cand" }
}

# ---------------------------------------------------------------- 3. registry
Write-Head '3. Registry (the only way Chrome finds a host on Windows)'

$regRoots = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKLM:\Software\Google\Chrome\NativeMessagingHosts',
    'HKLM:\Software\Wow6432Node\Google\Chrome\NativeMessagingHosts',
    'HKCU:\Software\Chromium\NativeMessagingHosts',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
)

$foundManifests = New-Object System.Collections.ArrayList
$anyRegistered = $false
foreach ($hn in $names) {
    $anyHit = $false
    foreach ($root in $regRoots) {
        $key = Join-Path $root $hn
        if (Test-Path -LiteralPath $key) {
            $val = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).'(default)'
            if ($val) {
                Write-Ok "$key = $val"
                [void]$foundManifests.Add([PSCustomObject]@{ Host = $hn; Key = $key; Path = $val })
                $anyHit = $true; $anyRegistered = $true
            }
            else { Write-Bad "$key exists but its default value is empty" 'The default value must be the full path to the host manifest JSON' }
        }
    }
    if (-not $anyHit) { Write-Info "not registered: $hn" }
}
if (-not $anyRegistered) {
    Write-Bad 'none of the candidate host names is registered anywhere' `
        'This alone explains why IDMMsgHost.exe never starts: on Windows Chrome does not scan directories, it only reads these registry keys. Run Setup-IdmIntegration.ps1.'
}

# ---------------------------------------------------------------- 4. host manifest
Write-Head '4. Host manifest JSON contents'

if ($foundManifests.Count -eq 0) { Write-Note 'nothing registered, so there is no JSON to inspect' }

foreach ($fm in $foundManifests) {
    Write-Host "  --- $($fm.Path)"
    if (-not (Test-Path -LiteralPath $fm.Path)) {
        Write-Bad "the JSON the registry points at does not exist: $($fm.Path)" 'Wrong path, or the file was removed'
        continue
    }

    $encIssue = Get-FileEncodingIssue -Path $fm.Path
    if ($encIssue) {
        Write-Bad "JSON encoding problem: $encIssue" `
            'Chrome accepts UTF-8 without BOM only. Saving as ANSI on a Chinese Windows install makes a non-ASCII path unreadable to Chrome.'
    }
    else { Write-Ok 'encoding is UTF-8 without BOM' }

    $hj = $null
    try { $hj = (Get-Content -Raw -LiteralPath $fm.Path -Encoding UTF8) | ConvertFrom-Json }
    catch { Write-Bad "JSON failed to parse: $($_.Exception.Message)"; continue }

    if ($hj.name -eq $fm.Host) { Write-Ok "name matches the registry key: $($hj.name)" }
    else { Write-Bad "JSON name='$($hj.name)' does not match registry key '$($fm.Host)'" 'They must be identical character for character, otherwise Chrome reports host not found' }

    if ($hj.type -eq 'stdio') { Write-Ok 'type = stdio' }
    else { Write-Bad "type='$($hj.type)', must be stdio" }

    $exe = $hj.path
    if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) { $exe = Join-Path (Split-Path -Parent $fm.Path) $exe }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        Write-Ok "executable exists: $exe"
        if (-not (Test-IsAscii $exe)) {
            Write-Bad "host executable path contains non-ASCII characters: $exe" `
                'Setup-IdmIntegration.ps1 rewrites this to the 8.3 short path automatically.'
        }
    }
    else { Write-Bad "executable does not exist: $exe" 'Most common after the portable IDM directory is moved' }

    $origins = @()
    if ($hj.allowed_origins) { $origins += $hj.allowed_origins }
    if ($origins.Count -eq 0) { Write-Bad 'allowed_origins is empty' 'It needs at least one chrome-extension://<id>/ entry' }
    else {
        foreach ($o in $origins) {
            if ($o -notmatch '/$') { Write-Bad "allowed_origins entry has no trailing slash: $o" 'It must be chrome-extension://xxxx/ - a missing slash never matches' }
        }
        if ($ExtensionId) {
            $want = "chrome-extension://$ExtensionId/"
            if ($origins -contains $want) { Write-Ok "allowed_origins covers the current extension ID: $want" }
            else { Write-Bad "allowed_origins does not contain $want" "present entries: $($origins -join ', ')" }
        }
    }
}

# ---------------------------------------------------------------- 5. IDM
Write-Head '5. IDM itself'

if (-not $IdmDir -and $foundManifests.Count -gt 0) {
    foreach ($fm in $foundManifests) {
        if (Test-Path -LiteralPath $fm.Path) {
            try {
                $hj = (Get-Content -Raw -LiteralPath $fm.Path -Encoding UTF8) | ConvertFrom-Json
                if ($hj.path -and (Test-Path -LiteralPath $hj.path)) { $IdmDir = Split-Path -Parent $hj.path; break }
            }
            catch { }
        }
    }
}
if ($IdmDir -and (Test-Path -LiteralPath $IdmDir)) {
    Write-Info "IDM directory: $IdmDir"
    foreach ($n in @('IDMan.exe', 'IDMMsgHost.exe')) {
        $p = Join-Path $IdmDir $n
        if (Test-Path -LiteralPath $p) { Write-Ok "$n present" } else { Write-Bad "$n missing from $IdmDir" }
    }
}
else { Write-Note 'IDM directory unknown; pass -IdmDir for more checks' }

$idmProc = Get-Process -Name 'IDMan' -ErrorAction SilentlyContinue
if ($idmProc) { Write-Ok "IDMan.exe is running (PID $($idmProc[0].Id))" }
else { Write-Bad 'IDMan.exe is not running' 'IDMMsgHost.exe hands downloads to the IDM main process. Start IDM before testing, and enable Options -> General -> Advanced browser integration.' }

$hostProc = Get-Process -Name 'IDMMsgHost' -ErrorAction SilentlyContinue
if ($hostProc) { Write-Info "IDMMsgHost.exe is running (PID $($hostProc[0].Id)) - Chrome has launched it successfully" }
else { Write-Info 'IDMMsgHost.exe is not running (normal: it only exists while Chrome holds a connection, and it exits immediately if it cannot reach IDM)' }

$dmKey = 'HKCU:\Software\DownloadManager'
if (Test-Path -LiteralPath $dmKey) {
    Write-Ok "$dmKey exists (IDM components locate each other through it)"
    $expath = (Get-ItemProperty -LiteralPath $dmKey -ErrorAction SilentlyContinue).ExePath
    if ($expath) { Write-Info "ExePath = $expath" }
    else { Write-Note 'ExePath value missing. Common with portable builds; IDMMsgHost.exe may fail to find IDMan.exe, which is exactly what "Cannot launch IDM" reports.' }
}
else {
    Write-Bad "$dmKey does not exist" `
        'The portable build never registered itself. IDMMsgHost.exe can start and then exit immediately because it cannot find IDMan.exe - that produces the "Cannot launch IDM" page. Run Setup-IdmIntegration.ps1, then start IDMan.exe once.'
}

# ---------------------------------------------------------------- summary
Write-Head 'Summary'
if ($script:Problems.Count -eq 0) {
    Write-Host '  Every link checks out.' -ForegroundColor Green
}
else {
    Write-Host "  $($script:Problems.Count) problem(s):" -ForegroundColor Red
    $i = 1
    foreach ($p in $script:Problems) { Write-Host "   $i. $p" -ForegroundColor Red; $i++ }
    Write-Host ''
    Write-Host '  Fix: .\Setup-IdmIntegration.ps1 -ExtensionDir "..." -IdmDir "..." -CrxPath "..."' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Run this in the Service Worker console - Chrome raw error is the most useful signal:' -ForegroundColor Yellow
Write-Host ''
foreach ($hn in $names) {
    Write-Host "    chrome.runtime.sendNativeMessage('$hn', {}, r => console.log('$hn ->', r, chrome.runtime.lastError && chrome.runtime.lastError.message))" -ForegroundColor White
}
Write-Host ''
Write-Host '  What each error means:' -ForegroundColor Yellow
Write-Host '    "Specified native messaging host not found."  -> registry missing / name mismatch / JSON path bad or unparseable'
Write-Host '    "Access to the ... host is forbidden."        -> ID not in allowed_origins (or trailing slash missing), or no nativeMessaging permission'
Write-Host '    "Failed to start native messaging host."      -> path not executable, encoding mangled, or permissions'
Write-Host '    "Native host has exited."                     -> the exe did start and quit: IDM-side problem, not Chrome-side'
Write-Host ''
