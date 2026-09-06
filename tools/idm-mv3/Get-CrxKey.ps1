#Requires -Version 5.1
<#
.SYNOPSIS
    Extract the public key from a .crx, derive the official extension ID, and optionally
    write the key into manifest.json.

.DESCRIPTION
    ASCII-only on purpose: Windows PowerShell 5.1 decodes .ps1 files with the system ANSI
    codepage unless the file carries a UTF-8 BOM, which corrupts non-ASCII text and breaks
    quote pairing.

    When Chrome loads an unpacked extension whose manifest.json has no "key", it derives
    the extension ID by hashing the extension directory's absolute path - so the ID changes
    whenever the directory changes. IDM's bundled native messaging allowlist only contains
    the official ID.

    Writing the .crx header's original public key into manifest.json as "key" makes the
    unpacked extension load under exactly the official ID, so IDM's own allowlist matches
    and there is nothing to maintain by hand.

    Handles both CRX2 and CRX3.

.EXAMPLE
    .\Get-CrxKey.ps1 -CrxPath 'E:\IDM\IDMGCExt.crx'

.EXAMPLE
    .\Get-CrxKey.ps1 -CrxPath 'E:\IDM\IDMGCExt.crx' -PatchManifest 'C:\idm_ext\extracted\manifest.json'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CrxPath,
    [string]$PatchManifest
)

$ErrorActionPreference = 'Stop'

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

if (-not (Test-Path -LiteralPath $CrxPath)) { throw "CRX not found: $CrxPath" }
$bytes = [System.IO.File]::ReadAllBytes($CrxPath)
if ($bytes.Length -lt 16) { throw 'CRX file too small' }

$magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
if ($magic -ne 'Cr24') { throw "not a CRX file (magic '$magic', expected 'Cr24')" }

$version = [System.BitConverter]::ToUInt32($bytes, 4)
$publicKey = $null

if ($version -eq 2) {
    $pubLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
    if ($pubLen -le 0 -or (16 + $pubLen) -gt $bytes.Length) { throw 'bad CRX2 public key length' }
    $publicKey = [byte[]]($bytes[16..(16 + $pubLen - 1)])
}
elseif ($version -eq 3) {
    $headerLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
    if ($headerLen -le 0 -or (12 + $headerLen) -gt $bytes.Length) { throw 'bad CRX3 header length' }
    $header = [byte[]]($bytes[12..(12 + $headerLen - 1)])
    $proof = Get-ProtobufBytesField -Buffer $header -FieldNumber 2    # sha256_with_rsa
    if ($null -eq $proof) { throw 'CRX3 header has no sha256_with_rsa block' }
    $publicKey = Get-ProtobufBytesField -Buffer $proof -FieldNumber 1 # public_key
    if ($null -eq $publicKey) { throw 'CRX3 signature block has no public_key' }
}
else { throw "unsupported CRX version: $version" }

$b64 = [Convert]::ToBase64String($publicKey)
$extId = Get-ExtensionIdFromPublicKey -PublicKey $publicKey

Write-Host ''
Write-Host "CRX format    : CRX$version" -ForegroundColor Cyan
Write-Host "key length    : $($publicKey.Length) bytes"
Write-Host "extension ID  : $extId" -ForegroundColor Green
Write-Host "allowed origin: chrome-extension://$extId/" -ForegroundColor Green
Write-Host ''
Write-Host 'Add this line inside the top-level object of manifest.json:' -ForegroundColor Yellow
Write-Host "  `"key`": `"$b64`","
Write-Host ''

if ($PatchManifest) {
    if (-not (Test-Path -LiteralPath $PatchManifest)) { throw "manifest not found: $PatchManifest" }
    $text = [System.IO.File]::ReadAllText($PatchManifest, [System.Text.Encoding]::UTF8)
    $null = $text | ConvertFrom-Json    # validate before touching it

    $backup = "$PatchManifest.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        [System.IO.File]::Copy($PatchManifest, $backup)
        Write-Host "backed up original manifest -> $backup"
    }

    $obj = $text | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'key') {
        if ($obj.key -eq $b64) { Write-Host 'manifest.json already carries the correct key.' -ForegroundColor Green }
        else {
            $text = $text -replace '"key"\s*:\s*"[^"]*"', ('"key": "' + $b64 + '"')
            [System.IO.File]::WriteAllText($PatchManifest, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host 'replaced the key in manifest.json with the CRX public key.' -ForegroundColor Green
        }
    }
    else {
        $idx = $text.IndexOf('{')
        if ($idx -lt 0) { throw 'manifest.json has no opening brace' }
        $text = $text.Substring(0, $idx + 1) + "`r`n  `"key`": `"$b64`"," + $text.Substring($idx + 1)
        [System.IO.File]::WriteAllText($PatchManifest, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host 'wrote key into manifest.json (UTF-8 no BOM).' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host 'Next: chrome://extensions -> Reload on this extension, and confirm the ID is now:' -ForegroundColor Yellow
    Write-Host "  $extId" -ForegroundColor Green
}

[PSCustomObject]@{
    CrxVersion  = $version
    ExtensionId = $extId
    Key         = $b64
    Origin      = "chrome-extension://$extId/"
}
