#Requires -Version 5.1
<#
.SYNOPSIS
    从 .crx 提取扩展公钥，算出官方扩展 ID，并可直接写回 manifest.json 的 "key" 字段。

.DESCRIPTION
    Chrome 加载「已解压的扩展」时，如果 manifest.json 里没有 "key"，
    扩展 ID 是按【扩展目录的绝对路径】现场哈希出来的 —— 换个目录 ID 就变。
    而 IDM 自带的 native messaging host 白名单里只有官方那个 ID。

    把 .crx 头部的原始公钥写进 manifest.json 的 "key"，
    解压加载后 ID 会和官方 CRX 完全一致，IDM 的白名单原样命中，
    从此不需要再手工往 allowed_origins 里塞 ID。

    支持 CRX2 与 CRX3 两种格式。

.EXAMPLE
    .\Get-CrxKey.ps1 -CrxPath 'E:\下载软件\IDM 6.42 免安装版\IDM 6.42 免安装版\IDM\IDMGCExt.crx'

.EXAMPLE
    .\Get-CrxKey.ps1 -CrxPath '...\IDMGCExt.crx' -PatchManifest 'C:\...\idm_ext\extracted\manifest.json'
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
        if ($Offset.Value -ge $Buffer.Length) { throw 'protobuf varint 读越界' }
        $b = $Buffer[$Offset.Value]
        $Offset.Value++
        $result = $result -bor ([uint64]($b -band 0x7F) -shl $shift)
        if (($b -band 0x80) -eq 0) { break }
        $shift += 7
        if ($shift -gt 63) { throw 'protobuf varint 过长' }
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
        if ($wire -eq 0) {
            [void](Read-Varint -Buffer $Buffer -Offset ([ref]$i))
        }
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
        else {
            throw "不支持的 protobuf wire type: $wire"
        }
    }
    return $null
}

function Get-ExtensionIdFromPublicKey {
    param([byte[]]$PublicKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($PublicKey) } finally { $sha.Dispose() }
    $hex = -join ($digest[0..15] | ForEach-Object { $_.ToString('x2') })
    # Chrome 的 "mpdecimal" 映射: 十六进制位 0-f  ->  字母 a-p
    return -join ($hex.ToCharArray() | ForEach-Object { [char](97 + [Convert]::ToInt32($_, 16)) })
}

if (-not (Test-Path -LiteralPath $CrxPath)) { throw "找不到 CRX 文件: $CrxPath" }
$bytes = [System.IO.File]::ReadAllBytes($CrxPath)
if ($bytes.Length -lt 16) { throw 'CRX 文件太小，不是有效的 CRX' }

$magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
if ($magic -ne 'Cr24') { throw "不是 CRX 文件（magic = '$magic'，期望 'Cr24'）" }

$version = [System.BitConverter]::ToUInt32($bytes, 4)
$publicKey = $null

if ($version -eq 2) {
    $pubLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
    if ($pubLen -le 0 -or (16 + $pubLen) -gt $bytes.Length) { throw 'CRX2 头部公钥长度非法' }
    $publicKey = [byte[]]($bytes[16..(16 + $pubLen - 1)])
}
elseif ($version -eq 3) {
    $headerLen = [int][System.BitConverter]::ToUInt32($bytes, 8)
    if ($headerLen -le 0 -or (12 + $headerLen) -gt $bytes.Length) { throw 'CRX3 头部长度非法' }
    $header = [byte[]]($bytes[12..(12 + $headerLen - 1)])
    # CrxFileHeader.sha256_with_rsa = field 2 (AsymmetricKeyProof)
    $proof = Get-ProtobufBytesField -Buffer $header -FieldNumber 2
    if ($null -eq $proof) { throw 'CRX3 头部里没有 sha256_with_rsa 签名块' }
    # AsymmetricKeyProof.public_key = field 1
    $publicKey = Get-ProtobufBytesField -Buffer $proof -FieldNumber 1
    if ($null -eq $publicKey) { throw 'CRX3 签名块里没有 public_key' }
}
else {
    throw "不支持的 CRX 版本: $version"
}

$b64 = [Convert]::ToBase64String($publicKey)
$extId = Get-ExtensionIdFromPublicKey -PublicKey $publicKey

Write-Host ''
Write-Host "CRX 格式      : CRX$version" -ForegroundColor Cyan
Write-Host "公钥长度      : $($publicKey.Length) 字节"
Write-Host "官方扩展 ID   : $extId" -ForegroundColor Green
Write-Host "白名单条目应为: chrome-extension://$extId/" -ForegroundColor Green
Write-Host ''
Write-Host 'manifest.json 里加这一行（放在最外层大括号内任意位置）:' -ForegroundColor Yellow
Write-Host "  `"key`": `"$b64`","
Write-Host ''

if ($PatchManifest) {
    if (-not (Test-Path -LiteralPath $PatchManifest)) { throw "找不到 manifest: $PatchManifest" }
    $text = [System.IO.File]::ReadAllText($PatchManifest, [System.Text.Encoding]::UTF8)
    # 先验证是合法 JSON，避免把坏文件改得更坏
    $null = $text | ConvertFrom-Json

    $backup = "$PatchManifest.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        [System.IO.File]::Copy($PatchManifest, $backup)
        Write-Host "已备份原 manifest -> $backup"
    }

    $obj = $text | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'key') {
        if ($obj.key -eq $b64) {
            Write-Host 'manifest.json 里的 key 已经正确，无需改动。' -ForegroundColor Green
        }
        else {
            $text = $text -replace '"key"\s*:\s*"[^"]*"', ('"key": "' + $b64 + '"')
            [System.IO.File]::WriteAllText($PatchManifest, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host 'manifest.json 里的 key 已替换为 CRX 原始公钥。' -ForegroundColor Green
        }
    }
    else {
        $idx = $text.IndexOf('{')
        if ($idx -lt 0) { throw 'manifest.json 里找不到起始大括号' }
        $text = $text.Substring(0, $idx + 1) + "`r`n  `"key`": `"$b64`"," + $text.Substring($idx + 1)
        [System.IO.File]::WriteAllText($PatchManifest, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host 'key 已写入 manifest.json（UTF-8 无 BOM）。' -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '下一步：到 chrome://extensions 点该扩展的「重新加载」，确认 ID 变成:' -ForegroundColor Yellow
    Write-Host "  $extId" -ForegroundColor Green
}

[PSCustomObject]@{
    CrxVersion  = $version
    ExtensionId = $extId
    Key         = $b64
    Origin      = "chrome-extension://$extId/"
}
