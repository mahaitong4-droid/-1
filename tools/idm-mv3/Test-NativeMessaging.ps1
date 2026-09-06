#Requires -Version 5.1
<#
.SYNOPSIS
    List and validate every native messaging host registered for Chrome / Edge / Chromium.

.DESCRIPTION
    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files with the system ANSI
    codepage unless the file carries a UTF-8 BOM, which corrupts non-ASCII text and breaks
    quote pairing.

    Download managers (FDM, IDM, XDM, Motrix, ...) all take over browser downloads through
    the same mechanism: a native messaging host registered in the Windows registry. On
    Windows the registry is the ONLY place Chrome looks - it does not scan directories.

    This script is browser- and vendor-neutral. It enumerates what is actually registered
    and checks each entry end to end:
      - the JSON the registry points at exists and parses
      - it is UTF-8 without a BOM (Chrome rejects a BOM)
      - its "name" matches the registry key name (a mismatch reads as "host not found")
      - "type" is stdio and the executable in "path" exists
      - every allowed_origins entry has the required trailing slash

    Read-only: it never writes anything.

.EXAMPLE
    # after installing FDM, confirm its host registered correctly
    .\Test-NativeMessaging.ps1

.EXAMPLE
    .\Test-NativeMessaging.ps1 -Filter fdm
#>
[CmdletBinding()]
param(
    [string]$Filter
)

$ErrorActionPreference = 'Continue'

# This script targets Windows: it reads the Windows registry.
# ($PSVersionTable.Platform does not exist on Windows PowerShell 5.1, so this is a no-op there.)
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw "This script only runs on Windows (it needs the Windows registry). Detected platform: $($PSVersionTable.Platform)"
}

function Write-Ok($t) { Write-Host "    [ OK ] $t" -ForegroundColor Green }
function Write-Bad($t) { Write-Host "    [FAIL] $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "    [note] $t" -ForegroundColor DarkYellow }

$roots = [ordered]@{
    'Chrome   (HKCU)' = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts'
    'Chrome   (HKLM)' = 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts'
    'Chrome   (WOW64)' = 'HKLM:\SOFTWARE\Wow6432Node\Google\Chrome\NativeMessagingHosts'
    'Edge     (HKCU)' = 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
    'Edge     (HKLM)' = 'HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts'
    'Chromium (HKCU)' = 'HKCU:\Software\Chromium\NativeMessagingHosts'
}

Write-Host ''
Write-Host '########  Registered native messaging hosts  ########' -ForegroundColor White

$total = 0
$problems = 0

foreach ($label in $roots.Keys) {
    $root = $roots[$label]
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $children = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) { continue }

    Write-Host ''
    Write-Host "=== $label" -ForegroundColor Cyan

    foreach ($child in $children) {
        $name = $child.PSChildName
        if ($Filter -and $name -notmatch $Filter) { continue }
        $total++

        $jsonPath = (Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue).'(default)'
        Write-Host "  $name" -ForegroundColor White
        Write-Host "    -> $jsonPath" -ForegroundColor Gray

        if (-not $jsonPath) { Write-Bad 'registry default value is empty'; $problems++; continue }
        if (-not (Test-Path -LiteralPath $jsonPath)) { Write-Bad 'the JSON it points at does not exist'; $problems++; continue }

        $bytes = [System.IO.File]::ReadAllBytes($jsonPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            Write-Bad 'JSON has a UTF-8 BOM; Chrome will reject it'
            $problems++
        }

        $doc = $null
        try { $doc = (Get-Content -Raw -LiteralPath $jsonPath -Encoding UTF8) | ConvertFrom-Json }
        catch { Write-Bad "JSON does not parse: $($_.Exception.Message)"; $problems++; continue }

        if ($doc.name -eq $name) { Write-Ok "name matches the registry key" }
        else { Write-Bad "name in JSON is '$($doc.name)' but the key is '$name' (reads as host-not-found)"; $problems++ }

        if ($doc.type -eq 'stdio') { Write-Ok 'type = stdio' }
        else { Write-Bad "type is '$($doc.type)', must be stdio"; $problems++ }

        $exe = $doc.path
        if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) {
            $exe = Join-Path (Split-Path -Parent $jsonPath) $exe
        }
        if ($exe -and (Test-Path -LiteralPath $exe)) { Write-Ok "executable exists: $exe" }
        else { Write-Bad "executable missing: $exe"; $problems++ }

        $origins = @()
        if ($doc.allowed_origins) { $origins += $doc.allowed_origins }
        if ($origins.Count -eq 0) { Write-Bad 'allowed_origins is empty'; $problems++ }
        else {
            $badSlash = @($origins | Where-Object { $_ -notmatch '/$' })
            if ($badSlash.Count -gt 0) {
                foreach ($o in $badSlash) { Write-Bad "allowed_origins entry has no trailing slash: $o"; $problems++ }
            }
            Write-Ok "allowed_origins: $($origins.Count) entry(s)"
            foreach ($o in $origins) { Write-Host "           $o" -ForegroundColor Gray }
        }
    }
}

Write-Host ''
if ($total -eq 0) {
    Write-Host 'No native messaging host is registered.' -ForegroundColor Red
    Write-Host 'On Windows this is the only way Chrome finds a host, so no extension can reach a' -ForegroundColor Yellow
    Write-Host 'download manager until something registers one. A proper installer does this for you.' -ForegroundColor Yellow
}
else {
    Write-Host "Checked $total host(s); $problems problem(s)." -ForegroundColor $(if ($problems) { 'Red' } else { 'Green' })
}

Write-Host ''
Write-Host '=== Download manager processes ===' -ForegroundColor Cyan
$procNames = 'fdm', 'fdmd', 'IDMan', 'IDMMsgHost', 'xdman', 'motrix', 'aria2c', 'Thunder'
$any = $false
foreach ($n in $procNames) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $any = $true; Write-Host ("  {0,-14} PID {1}" -f $p[0].ProcessName, ($p.Id -join ', ')) }
}
if (-not $any) { Write-Note 'none running (start your download manager before testing the browser side)' }

Write-Host ''
Write-Host 'Next: open the extension Service Worker console and run, for each host name above:' -ForegroundColor Yellow
Write-Host "  chrome.runtime.sendNativeMessage('<host name>', {}, r => console.log(r, chrome.runtime.lastError && chrome.runtime.lastError.message))"
Write-Host ''
