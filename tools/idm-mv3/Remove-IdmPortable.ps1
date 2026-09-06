#Requires -Version 5.1
<#
.SYNOPSIS
    Remove a portable ("green" / no-installer) IDM build and its leftovers.

.DESCRIPTION
    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files with the system ANSI
    codepage unless the file carries a UTF-8 BOM, which corrupts non-ASCII text and breaks
    quote pairing.

    A portable IDM has no uninstaller, so removing it means deleting the folder and cleaning
    the traces it left behind. This script is DRY RUN BY DEFAULT: it prints exactly what it
    would do and changes nothing until you pass -Execute.

    Registry keys are exported to a backup folder before anything is deleted.

    Two things are only ever REPORTED, never modified, because they need admin rights and a
    mistake there has a wide blast radius:
      - hosts file entries pointing IDM's licence domains at nowhere
      - firewall rules blocking IDMan.exe
    Both are left for you to remove by hand; the script prints what it found. They only
    matter if you later install the official IDM build.

.EXAMPLE
    .\Remove-IdmPortable.ps1 -IdmDir 'E:\Downloads\IDM 6.42 portable'

.EXAMPLE
    .\Remove-IdmPortable.ps1 -IdmDir 'E:\Downloads\IDM 6.42 portable' -Execute
#>
[CmdletBinding()]
param(
    [string]$IdmDir,
    [string]$BackupDir,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

# This script targets Windows: it reads and writes the Windows registry.
# ($PSVersionTable.Platform does not exist on Windows PowerShell 5.1, so this is a no-op there.)
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    throw "This script only runs on Windows (it needs the Windows registry). Detected platform: $($PSVersionTable.Platform)"
}

if (-not $BackupDir) { $BackupDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'idm-backup' }

function Write-Step($t) { Write-Host ''; Write-Host ">> $t" -ForegroundColor Cyan }
function Write-Act($t) { Write-Host "   [ACT ] $t" -ForegroundColor Yellow }
function Write-Ok($t) { Write-Host "   [OK  ] $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "   [note] $t" -ForegroundColor DarkYellow }

Write-Host ''
Write-Host '########  Remove portable IDM  ########' -ForegroundColor White
if (-not $Execute) { Write-Host 'DRY RUN - nothing will be changed. Add -Execute to apply.' -ForegroundColor Magenta }

# ---------------------------------------------------------------- 1. backup
Write-Step '1. Back up registry keys'
$toBackup = @(
    'HKCU\Software\DownloadManager',
    'HKCU\Software\Internet Download Manager',
    'HKCU\Software\Google\Chrome\NativeMessagingHosts',
    'HKCU\Software\Microsoft\Edge\NativeMessagingHosts',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
)
if ($Execute) {
    $null = New-Item -ItemType Directory -Path $BackupDir -Force
    foreach ($k in $toBackup) {
        $file = Join-Path $BackupDir (($k -replace '[\\ ]', '_') + '.reg')
        & reg.exe export $k $file /y 2>$null | Out-Null
    }
    Write-Ok "backed up to $BackupDir"
}
else {
    Write-Act "would export $($toBackup.Count) registry keys to $BackupDir"
}

# ---------------------------------------------------------------- 2. processes
Write-Step '2. Stop IDM processes'
$names = 'IDMan', 'IDMMsgHost', 'IDMIntegrator64', 'IDMIntegrator', 'IEMonitor', 'IDMGrHlp'
$found = $false
foreach ($n in $names) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) {
        $found = $true
        Write-Act "$n (PID $($p.Id -join ', '))"
        if ($Execute) { $p | Stop-Process -Force; Write-Ok "$n stopped" }
    }
}
if (-not $found) { Write-Ok 'no IDM process running' }

# ---------------------------------------------------------------- 3. autostart
Write-Step '3. Remove autostart entries'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$props = Get-ItemProperty -LiteralPath $run -ErrorAction SilentlyContinue
$hit = $false
if ($props) {
    foreach ($prop in $props.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue }
        if ($prop.Name -match 'IDM' -or "$($prop.Value)" -match 'IDMan\.exe') {
            $hit = $true
            Write-Act "$run -> $($prop.Name) = $($prop.Value)"
            if ($Execute) { Remove-ItemProperty -LiteralPath $run -Name $prop.Name -Force; Write-Ok "removed $($prop.Name)" }
        }
    }
}
if (-not $hit) { Write-Ok 'no IDM autostart entry' }

# ---------------------------------------------------------------- 4. native messaging
Write-Step '4. Remove native messaging registrations'
$roots = @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts',
    'HKCU:\Software\Chromium\NativeMessagingHosts',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts'
)
$hit = $false
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($child in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $val = (Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction SilentlyContinue).'(default)'
        $isIdm = $child.PSChildName -match 'internetdownloadmanager|tonec|idm' -or "$val" -match 'IDM'
        if ($isIdm) {
            $hit = $true
            Write-Act "$($child.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -> $val"
            if ($Execute) { Remove-Item -LiteralPath $child.PSPath -Recurse -Force; Write-Ok "removed $($child.PSChildName)" }
        }
    }
}
if (-not $hit) { Write-Ok 'no IDM native messaging registration' }

# ---------------------------------------------------------------- 5. config keys
Write-Step '5. Remove IDM config keys'
$hit = $false
foreach ($k in @('HKCU:\Software\DownloadManager', 'HKCU:\Software\Internet Download Manager')) {
    if (Test-Path -LiteralPath $k) {
        $hit = $true
        Write-Act $k
        if ($Execute) { Remove-Item -LiteralPath $k -Recurse -Force; Write-Ok "removed $k" }
    }
}
if (-not $hit) { Write-Ok 'no IDM config key' }

# ---------------------------------------------------------------- 6. folders
Write-Step '6. Remove folders'
$folders = @()
if ($IdmDir) { $folders += $IdmDir }
$folders += (Join-Path $env:APPDATA 'IDM')
$folders += (Join-Path $env:LOCALAPPDATA 'IDMNativeHost')
$hit = $false
foreach ($p in $folders) {
    if ($p -and (Test-Path -LiteralPath $p)) {
        $hit = $true
        $mb = 0
        try {
            $mb = (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum / 1MB
        }
        catch { }
        Write-Act ("{0}  ({1:N1} MB)" -f $p, $mb)
        if ($Execute) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Ok "removed $p" }
    }
}
if (-not $hit) { Write-Ok 'no IDM folder found' }
if (-not $IdmDir) { Write-Note 'no -IdmDir given, so the portable folder itself was not touched' }

# ---------------------------------------------------------------- 7. report only
Write-Step '7. Crack leftovers (REPORTED ONLY - needs admin to fix)'
$hostsFile = Join-Path $env:windir 'System32\drivers\etc\hosts'
$hostsHits = @()
if (Test-Path -LiteralPath $hostsFile) {
    $hostsHits = @(Select-String -LiteralPath $hostsFile -Pattern 'internetdownloadmanager|tonec' -ErrorAction SilentlyContinue)
}
if ($hostsHits.Count -gt 0) {
    Write-Note 'hosts file contains IDM-related lines:'
    foreach ($h in $hostsHits) { Write-Host "        line $($h.LineNumber): $($h.Line)" }
    Write-Note 'Open the hosts file as administrator and delete (or comment out) those lines.'
}
else { Write-Ok 'hosts file clean' }

$fw = @()
try {
    $fw = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'IDM|Internet Download' })
}
catch { }
if ($fw.Count -gt 0) {
    Write-Note 'firewall rules found:'
    foreach ($r in $fw) { Write-Host "        $($r.DisplayName)  [$($r.Direction)/$($r.Action)/Enabled=$($r.Enabled)]" }
    Write-Note 'Remove them from an elevated PowerShell:'
    Write-Note "  Get-NetFirewallRule | Where-Object DisplayName -match 'IDM|Internet Download' | Remove-NetFirewallRule"
}
else { Write-Ok 'no IDM firewall rule' }

Write-Host ''
if ($Execute) {
    Write-Host 'Done. Restart Chrome, then run Test-NativeMessaging.ps1 to confirm nothing IDM is left.' -ForegroundColor Cyan
    Write-Host "Registry backup: $BackupDir" -ForegroundColor Cyan
}
else {
    Write-Host 'Dry run finished. Re-run with -Execute to apply the actions marked [ACT].' -ForegroundColor Magenta
}
Write-Host ''
