#Requires -Version 5.1
<#
.SYNOPSIS
    All-in-one setup for IDM Chrome extension native messaging. Single self-contained file.

.DESCRIPTION
    ASCII-only on purpose. Windows PowerShell 5.1 decodes .ps1 files using the system
    ANSI codepage unless the file has a UTF-8 BOM. On a Chinese Windows install that is
    GBK, which corrupts non-ASCII characters and breaks quote pairing, producing cascades
    of "unexpected token" parse errors. Keeping every script byte in ASCII makes the file
    immune to that no matter how it is transferred (git clone, curl, copy-paste, chat).

    What this does, in order:
      1. Finds IDMMsgHost.exe / IDMan.exe in the IDM directory.
      2. Extracts the public key from the .crx and writes it into manifest.json as "key",
         pinning the extension ID to the official one (optional but strongly recommended).
      3. Scans the extension's JS for connectNative/sendNativeMessage to learn the real
         native host name, and unions that with the known candidates.
      4. Writes one host manifest JSON per host name into %LOCALAPPDATA%\IDMNativeHost\,
         deliberately outside the IDM directory so IDM cannot overwrite allowed_origins.
      5. Registers each JSON in HKCU for Chrome / Chromium / Edge. On Windows this
         registry entry is the ONLY way Chrome locates a native messaging host; it does
         not scan directories.
      6. Registers IDMan.exe under HKCU\Software\DownloadManager so IDMMsgHost.exe can
         find the IDM main process.
      7. Re-reads everything back and prints a verification report.

    Only HKCU is written. No administrator rights required.

.EXAMPLE
    .\Setup-IdmIntegration.ps1 `
        -ExtensionDir 'C:\Users\win\idm_ext\extracted' `
        -IdmDir 'E:\XiaZai\IDM 6.42\IDM' `
        -CrxPath 'E:\XiaZai\IDM 6.42\IDM\IDMGCExt.crx'

.EXAMPLE
    # Preview every change without touching disk or registry
    .\Setup-IdmIntegration.ps1 -ExtensionDir '...' -IdmDir '...' -WhatIfOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExtensionDir,
    [Parameter(Mandatory = $true)][string]$IdmDir,
    [string]$CrxPath,
    [string[]]$HostNames,
    [string[]]$ExtraExtensionIds = @(),
    [string]$OutputDir,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

# This script targets Windows: it reads and writes the Windows registry, which is where
# Chrome looks for native messaging hosts. Fail fast with a clear message elsewhere,
# instead of emitting a wall of "drive HKCU does not exist" errors.
# ($PSVersionTable.Platform does not exist on Windows PowerShell 5.1, so this is a no-op there.)
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw "This script only runs on Windows (it needs the Windows registry). Detected platform: $($PSVersionTable.Platform)"
}

# LOCALAPPDATA only exists on Windows, so resolve the default after the guard above.
if (-not $OutputDir) { $OutputDir = Join-Path $env:LOCALAPPDATA 'IDMNativeHost' }


function Write-Step($t) { Write-Host ''; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "   [OK]   $t" -ForegroundColor Green }
function Write-Bad($t) { Write-Host "   [FAIL] $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "   [note] $t" -ForegroundColor Yellow }

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

function Read-Varint {
    param([byte[]]$Buffer, [ref]$Offset)
    $result = [uint64]0
    $shift = 0
    while ($true) {
        if ($Offset.Value -ge $Buffer.Length) { throw 'protobuf varint out of range' }
        $b = $Buffer[$Offset.Value]
        $Offset.Value++
        $result = $result -bor ([uint64]($b -band 0x7F) -shl $shift)
        if (($b -band 0x80) -eq 0) { break }
        $shift += 7
        if ($shift -gt 63) { throw 'protobuf varint too long' }
    }
    return $result
}

function Get-ProtobufBytesField {
    param([byte[]]$Buffer, [int]$FieldNumber)
    $i = 0
    while ($i -lt $Buffer.Length) {
        $tag = Read-Varint -Buffer $Buffer -Offset ([ref]$i)
        $field = [int]($tag -shr 3)
        $wire = [int]($tag -band 7)
        if ($wire -eq 0) { [void](Read-Varint -Buffer $Buffer -Offset ([ref]$i)) }
        elseif ($wire -eq 1) { $i += 8 }
        elseif ($wire -eq 5) { $i += 4 }
        elseif ($wire -eq 2) {
            $len = [int](Read-Varint -Buffer $Buffer -Offset ([ref]$i))
            if ($field -eq $FieldNumber) {
                if ($len -eq 0) { return , ([byte[]]@()) }
                return , ([byte[]]($Buffer[$i..($i + $len - 1)]))
            }
            $i += $len
        }
        else { throw "unsupported protobuf wire type: $wire" }
    }
    return $null
}

function Get-ExtensionIdFromPublicKey {
    param([byte[]]$PublicKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($PublicKey) } finally { $sha.Dispose() }
    $hex = -join ($digest[0..15] | ForEach-Object { $_.ToString('x2') })
    # Chrome maps each hex digit 0-f onto the letters a-p
    return -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32($_, 16)) })
}

function Get-CrxPublicKey {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 16) { throw 'CRX file too small' }
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne 'Cr24') { throw "not a CRX file (magic '$magic', expected 'Cr24')" }
    $version = [System.BitConverter]::ToUInt32($bytes, 4)
    if ($version -eq 2) {
        $pubLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
        if ($pubLen -le 0 -or (16 + $pubLen) -gt $bytes.Length) { throw 'bad CRX2 public key length' }
        return , ([byte[]]($bytes[16..(16 + $pubLen - 1)]))
    }
    elseif ($version -eq 3) {
        $headerLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
        if ($headerLen -le 0 -or (12 + $headerLen) -gt $bytes.Length) { throw 'bad CRX3 header length' }
        $header = [byte[]]($bytes[12..(12 + $headerLen - 1)])
        $proof = Get-ProtobufBytesField -Buffer $header -FieldNumber 2   # sha256_with_rsa
        if ($null -eq $proof) { throw 'CRX3 header has no sha256_with_rsa block' }
        $pk = Get-ProtobufBytesField -Buffer $proof -FieldNumber 1       # public_key
        if ($null -eq $pk) { throw 'CRX3 signature block has no public_key' }
        return , $pk
    }
    throw "unsupported CRX version: $version"
}

Write-Host ''
Write-Host '########  IDM native messaging setup  ########' -ForegroundColor White
if ($WhatIfOnly) { Write-Host 'PREVIEW MODE - nothing will be written' -ForegroundColor Magenta }

# ---------------------------------------------------------------- 1. paths
Write-Step '1. Locating IDM'
if (-not (Test-Path -LiteralPath $ExtensionDir)) { throw "extension directory not found: $ExtensionDir" }
if (-not (Test-Path -LiteralPath $IdmDir)) { throw "IDM directory not found: $IdmDir" }
$ExtensionDir = (Resolve-Path -LiteralPath $ExtensionDir).Path
$IdmDir = (Resolve-Path -LiteralPath $IdmDir).Path

$msgHost = Join-Path $IdmDir 'IDMMsgHost.exe'
if (-not (Test-Path -LiteralPath $msgHost)) { throw "IDMMsgHost.exe not found in $IdmDir" }
Write-Ok "IDMMsgHost.exe : $msgHost"

$idman = Join-Path $IdmDir 'IDMan.exe'
if (Test-Path -LiteralPath $idman) { Write-Ok "IDMan.exe      : $idman" }
else { Write-Note "IDMan.exe not found in $IdmDir - portable layouts sometimes differ" }

# ---------------------------------------------------------------- 2. extension ID
Write-Step '2. Pinning the extension ID'
$manifestPath = Join-Path $ExtensionDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest.json not found: $manifestPath" }

if ($CrxPath) {
    if (-not (Test-Path -LiteralPath $CrxPath)) { throw "CRX not found: $CrxPath" }
    $pk = Get-CrxPublicKey -Path $CrxPath
    $b64 = [Convert]::ToBase64String($pk)
    Write-Ok "extracted public key from CRX ($($pk.Length) bytes)"

    $text = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
    $null = $text | ConvertFrom-Json      # validate before touching it
    $obj = $text | ConvertFrom-Json
    if (($obj.PSObject.Properties.Name -contains 'key') -and ($obj.key -eq $b64)) {
        Write-Ok 'manifest.json already carries the correct key'
    }
    elseif ($WhatIfOnly) {
        Write-Note 'would write "key" into manifest.json'
    }
    else {
        $backup = "$manifestPath.bak"
        if (-not (Test-Path -LiteralPath $backup)) { [System.IO.File]::Copy($manifestPath, $backup) }
        if ($obj.PSObject.Properties.Name -contains 'key') {
            $text = $text -replace '"key"\s*:\s*"[^"]*"', ('"key": "' + $b64 + '"')
        }
        else {
            $idx = $text.IndexOf('{')
            if ($idx -lt 0) { throw 'manifest.json has no opening brace' }
            $text = $text.Substring(0, $idx + 1) + "`r`n  `"key`": `"$b64`"," + $text.Substring($idx + 1)
        }
        [System.IO.File]::WriteAllText($manifestPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok 'wrote "key" into manifest.json (UTF-8 no BOM); backup at manifest.json.bak'
    }
}

$manifest = (Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8) | ConvertFrom-Json
$ids = New-Object System.Collections.Generic.List[string]
if (($manifest.PSObject.Properties.Name -contains 'key') -and $manifest.key) {
    $idFromKey = Get-ExtensionIdFromPublicKey -PublicKey ([Convert]::FromBase64String($manifest.key))
    $ids.Add($idFromKey)
    Write-Ok "extension ID is pinned to $idFromKey"
}
elseif ($CrxPath -and $WhatIfOnly) {
    $ids.Add((Get-ExtensionIdFromPublicKey -PublicKey (Get-CrxPublicKey -Path $CrxPath)))
    Write-Note "extension ID would become $($ids[0])"
}
else {
    Write-Note 'manifest.json has no "key": the ID is derived from the directory path and'
    Write-Note 'will change whenever the extension is moved or re-extracted.'
    Write-Note 'Pass -CrxPath to pin it, or -ExtraExtensionIds to supply the current ID.'
}
foreach ($e in $ExtraExtensionIds) {
    $t = $e.Trim()
    if ($t -and -not $ids.Contains($t)) { $ids.Add($t) }
}
if ($ids.Count -eq 0) { throw 'No extension ID available. Pass -CrxPath (preferred) or -ExtraExtensionIds <id from chrome://extensions>.' }

$origins = @($ids | ForEach-Object { "chrome-extension://$_/" })
foreach ($o in $origins) { Write-Ok "allowed origin: $o" }

# ---------------------------------------------------------------- 3. host names
Write-Step '3. Determining the native host name'
$names = New-Object System.Collections.Generic.List[string]

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
    Write-Note 'no connectNative/sendNativeMessage call found in the extension JS.'
    Write-Note 'The code may be minified with the name built at runtime; falling back to known candidates.'
}

if ($HostNames) {
    foreach ($h in $HostNames) { if ($h -and -not $names.Contains($h)) { $names.Add($h) } }
}
# Both known candidates are registered. Registering a host name nothing connects to is
# harmless, and it removes the guesswork about which one this build actually uses.
foreach ($cand in @('com.internetdownloadmanager.pdmbehavior', 'com.tonec.idm')) {
    if (-not $names.Contains($cand)) { $names.Add($cand); Write-Note "also registering candidate: $cand" }
}

# ---------------------------------------------------------------- 4. exe path
Write-Step '4. Resolving the host executable path'
$hostExePath = $msgHost
if (-not (Test-IsAscii $msgHost)) {
    Write-Note 'IDM path contains non-ASCII characters; trying the 8.3 short path'
    $sp = Get-ShortPath $msgHost
    if ($sp -and (Test-IsAscii $sp) -and (Test-Path -LiteralPath $sp)) {
        $hostExePath = $sp
        Write-Ok "using short path: $hostExePath"
    }
    else {
        Write-Note 'no usable 8.3 short path (the volume may have 8.3 name creation disabled).'
        Write-Note 'Writing the original path; the JSON is emitted as strict UTF-8 without BOM,'
        Write-Note 'which normally works. If it still fails, move IDM to an ASCII-only path.'
    }
}
else { Write-Ok "path is pure ASCII: $hostExePath" }

# ---------------------------------------------------------------- 5+6. write and register
Write-Step '5. Writing host manifests and registry entries'
$regRoots = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKCU:\Software\Chromium\NativeMessagingHosts',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
)

if (-not $WhatIfOnly -and -not (Test-Path -LiteralPath $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$written = New-Object System.Collections.ArrayList
foreach ($hn in $names) {
    $jsonPath = Join-Path $OutputDir "$hn.json"
    $doc = [ordered]@{
        name            = $hn
        description     = 'IDM Native Messaging Host'
        path            = $hostExePath
        type            = 'stdio'
        allowed_origins = $origins
    }
    $json = $doc | ConvertTo-Json -Depth 5

    if ($WhatIfOnly) {
        Write-Note "would write $jsonPath"
    }
    else {
        # UTF-8 WITHOUT BOM here: Chrome rejects a BOM in the host manifest.
        # (Note the opposite rule for .ps1 files - see the header comment.)
        [System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "wrote $jsonPath"
    }
    [void]$written.Add([PSCustomObject]@{ Host = $hn; Json = $jsonPath })

    foreach ($root in $regRoots) {
        $key = Join-Path $root $hn
        if ($WhatIfOnly) { Write-Note "would set $key = $jsonPath"; continue }
        if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
        Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $jsonPath
    }
    if (-not $WhatIfOnly) { Write-Ok "registered $hn for Chrome / Chromium / Edge (HKCU)" }
}

Write-Step '6. Registering the IDM main executable'
if (-not (Test-Path -LiteralPath $idman)) {
    Write-Note 'IDMan.exe not found, skipping'
}
elseif ($WhatIfOnly) {
    Write-Note "would set HKCU:\Software\DownloadManager\ExePath = $idman"
}
else {
    $dmKey = 'HKCU:\Software\DownloadManager'
    if (-not (Test-Path -LiteralPath $dmKey)) { $null = New-Item -Path $dmKey -Force }
    Set-ItemProperty -LiteralPath $dmKey -Name 'ExePath' -Value $idman
    Write-Ok "HKCU\Software\DownloadManager\ExePath = $idman"
    Write-Note 'IDM may rewrite this value on its next start; that is expected.'
}

# ---------------------------------------------------------------- 7. verify
Write-Step '7. Verification (reading everything back)'
if ($WhatIfOnly) {
    Write-Note 'preview mode, nothing to verify'
}
else {
    $problems = 0
    foreach ($w in $written) {
        if (-not (Test-Path -LiteralPath $w.Json)) { Write-Bad "missing: $($w.Json)"; $problems++; continue }

        $bytes = [System.IO.File]::ReadAllBytes($w.Json)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            Write-Bad "$($w.Json) has a UTF-8 BOM; Chrome will reject it"; $problems++
        }

        $back = $null
        try { $back = (Get-Content -Raw -LiteralPath $w.Json -Encoding UTF8) | ConvertFrom-Json }
        catch { Write-Bad "$($w.Json) does not parse as JSON"; $problems++; continue }

        if ($back.name -ne $w.Host) { Write-Bad "name mismatch in $($w.Json)"; $problems++ }
        if ($back.type -ne 'stdio') { Write-Bad "type is not stdio in $($w.Json)"; $problems++ }
        if (-not (Test-Path -LiteralPath $back.path)) { Write-Bad "path does not exist: $($back.path)"; $problems++ }
        foreach ($o in $origins) {
            if (@($back.allowed_origins) -notcontains $o) { Write-Bad "allowed_origins missing $o"; $problems++ }
        }

        $regKey = Join-Path 'HKCU:\Software\Google\Chrome\NativeMessagingHosts' $w.Host
        $regVal = (Get-ItemProperty -LiteralPath $regKey -ErrorAction SilentlyContinue).'(default)'
        if ($regVal -ne $w.Json) { Write-Bad "registry for $($w.Host) points at '$regVal'"; $problems++ }
    }
    if ($problems -eq 0) { Write-Ok "all $($written.Count) host registrations verified" }
    else { Write-Bad "$problems problem(s) found above" }
}

# ---------------------------------------------------------------- next steps
Write-Host ''
Write-Host 'Next steps, in this order:' -ForegroundColor Cyan
Write-Host '  1. Start IDMan.exe and leave it running.'
Write-Host '     In IDM: Options -> General -> enable "Advanced browser integration".'
Write-Host '  2. Load the extension: chrome://extensions -> Developer mode on ->'
Write-Host "     Load unpacked -> $ExtensionDir"
if ($ids.Count -gt 0) { Write-Host "     Confirm the ID shown is $($ids[0])" }
Write-Host '  3. Quit Chrome completely (check Task Manager for leftover chrome.exe), reopen it.'
Write-Host '     Native host registry entries are only read at browser startup.'
Write-Host '  4. chrome://extensions -> click "Service Worker" -> run this in the console:'
Write-Host ''
foreach ($hn in $names) {
    Write-Host "     chrome.runtime.sendNativeMessage('$hn', {}, r => console.log('$hn ->', r, chrome.runtime.lastError && chrome.runtime.lastError.message))" -ForegroundColor White
}
Write-Host ''
Write-Host '  Error strings and what they mean:' -ForegroundColor Yellow
Write-Host '    "Specified native messaging host not found."  -> registry / JSON path / name mismatch'
Write-Host '    "Access to the ... host is forbidden."        -> extension ID not in allowed_origins, or'
Write-Host '                                                    the manifest lacks the nativeMessaging permission'
Write-Host '    "Failed to start native messaging host."      -> path not executable, or path encoding broken'
Write-Host '    "Native host has exited."                     -> Chrome side is fine; IDM side is the problem'
Write-Host '    no error, a response comes back               -> the chain works'
Write-Host ''
