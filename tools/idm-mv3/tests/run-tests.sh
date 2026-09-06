#!/usr/bin/env bash
# Regression tests for the idm-mv3 toolkit.
#
# Runs on Linux/macOS with PowerShell 7 (pwsh) installed:
#   Ubuntu:  curl -sSLO https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/p/powershell/powershell_7.6.5-1.deb_amd64.deb
#            dpkg -i powershell_7.6.5-1.deb_amd64.deb
#
# What it covers:
#   - every .ps1 parses with the real PowerShell parser (the failure mode that broke v1)
#   - every .ps1 is pure ASCII with a UTF-8 BOM (so PS 5.1 cannot mis-decode it)
#   - Get-CrxKey derives the documented extension ID from synthetic CRX2 and CRX3
#   - Get-CrxKey -PatchManifest writes valid UTF-8-no-BOM JSON and preserves other keys
#   - Convert-ManifestToMv3 produces a correct MV3 manifest (17 assertions)
#   - the Windows-only scripts refuse to run off-Windows with a clear message
#
# What it CANNOT cover (needs a real Windows box):
#   registry reads/writes, Scripting.FileSystemObject 8.3 short paths,
#   Get-Process against Windows process names, and whether Chrome actually
#   launches the native host.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v pwsh >/dev/null || { echo "pwsh not found"; exit 2; }
echo "pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"

# ---------------------------------------------------------------- 1. parse + encoding
echo; echo "== 1. parse and encoding =="
for f in "$ROOT"/*.ps1; do
  n="$(basename "$f")"
  if pwsh -NoProfile -Command "
      \$e=\$null; \$null=[System.Management.Automation.Language.Parser]::ParseFile('$f',[ref]\$null,[ref]\$e)
      if (\$e.Count) { \$e | ForEach-Object { \"line \$(\$_.Extent.StartLineNumber): \$(\$_.Message)\" }; exit 1 }" ; then
    ok "parses: $n"
  else
    bad "parses: $n"
  fi
  python3 - "$f" "$n" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
bom=d.startswith(b'\xef\xbb\xbf')
body_ascii=all(b<128 for b in (d[3:] if bom else d))
print(("  PASS  " if (bom and body_ascii) else "  FAIL  ")+"ASCII body + UTF-8 BOM: "+sys.argv[2])
sys.exit(0 if (bom and body_ascii) else 1)
PY
  [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
done

# ---------------------------------------------------------------- fixtures
python3 - "$WORK" <<'PY'
import hashlib, struct, sys, os, json
w=sys.argv[1]
def varint(n):
    o=bytearray()
    while True:
        b=n&0x7F; n>>=7
        o.append(b|0x80 if n else b)
        if not n: return bytes(o)
def fb(num,p): return varint((num<<3)|2)+varint(len(p))+p
pub=bytes(range(256))*2+b'DER-SPKI-STANDIN'; sig=b'\xAA'*256
cid=hashlib.sha256(pub).digest()[:16]
hdr=fb(2, fb(1,pub)+fb(2,sig))+fb(10000, fb(1,cid))
open(f'{w}/test3.crx','wb').write(b'Cr24'+struct.pack('<I',3)+struct.pack('<I',len(hdr))+hdr+b'PK\x03\x04')
open(f'{w}/test2.crx','wb').write(b'Cr24'+struct.pack('<I',2)+struct.pack('<I',len(pub))+struct.pack('<I',len(sig))+pub+sig+b'PK\x03\x04')
open(f'{w}/expected_id.txt','w').write(''.join(chr(97+int(c,16)) for c in hashlib.sha256(pub).hexdigest()[:32]))
os.makedirs(f'{w}/ext', exist_ok=True)
json.dump({
 "manifest_version":2,"name":"IDM Integration Module","version":"6.42.18.3",
 "permissions":["nativeMessaging","webRequest","webRequestBlocking","downloads",
                "contextMenus","cookies","tabs","<all_urls>","http://*/*","https://*/*"],
 "background":{"scripts":["a.js","background.js"],"persistent":True},
 "browser_action":{"default_icon":"icon.png","default_title":"IDM"},
 "content_security_policy":"script-src 'self' 'unsafe-eval' https://evil.example.com; object-src 'self'",
 "web_accessible_resources":["res1.js","res2.png"],
 "update_url":"https://clients2.google.com/service/update2/crx"},
 open(f'{w}/ext/manifest.json','w'), indent=2)
open(f'{w}/ext/background.js','w').write("chrome.runtime.connectNative('com.internetdownloadmanager.pdmbehavior');")
open(f'{w}/ext/a.js','w').write("var helper = 1;")
os.makedirs(f'{w}/idm', exist_ok=True)
for n in ('IDMMsgHost.exe','IDMan.exe'): open(f'{w}/idm/{n}','wb').write(b'MZ')
PY
EXPECTED="$(cat "$WORK/expected_id.txt")"

# ---------------------------------------------------------------- 2. CRX parsing
echo; echo "== 2. CRX parsing and extension ID =="
for v in 3 2; do
  got="$(pwsh -NoProfile -File "$ROOT/Get-CrxKey.ps1" -CrxPath "$WORK/test$v.crx" 2>/dev/null \
         | grep -oE '[a-p]{32}' | head -1)"
  [ "$got" = "$EXPECTED" ] && ok "CRX$v -> $got" || bad "CRX$v -> got '$got' expected '$EXPECTED'"
done

# ---------------------------------------------------------------- 3. PatchManifest
echo; echo "== 3. Get-CrxKey -PatchManifest =="
pwsh -NoProfile -File "$ROOT/Get-CrxKey.ps1" -CrxPath "$WORK/test3.crx" \
     -PatchManifest "$WORK/ext/manifest.json" >/dev/null 2>&1
python3 - "$WORK/ext/manifest.json" "$EXPECTED" <<'PY'
import sys,json,hashlib,base64
b=open(sys.argv[1],'rb').read()
assert not b.startswith(b'\xef\xbb\xbf'), "host/ext manifest must NOT have a BOM"
m=json.loads(b.decode('utf-8'))
assert 'key' in m and m['name']=='IDM Integration Module'
h=hashlib.sha256(base64.b64decode(m['key'])).hexdigest()[:32]
assert ''.join(chr(97+int(c,16)) for c in h)==sys.argv[2]
PY
[ $? -eq 0 ] && ok "key written, JSON valid, no BOM, ID round-trips" || bad "PatchManifest"

# ---------------------------------------------------------------- 4. MV2 -> MV3
echo; echo "== 4. Convert-ManifestToMv3 =="
pwsh -NoProfile -File "$ROOT/Convert-ManifestToMv3.ps1" -ExtensionDir "$WORK/ext" >/dev/null 2>&1
python3 - "$WORK/ext/manifest.json" "$WORK/ext/sw-shim.js" <<'PY'
import sys,json,os
m=json.load(open(sys.argv[1],encoding='utf-8')); bad=[]
def c(l,v):
    print(("  PASS  " if v else "  FAIL  ")+l)
    if not v: bad.append(l)
p=m.get('permissions',[]); h=m.get('host_permissions',[])
c("manifest_version == 3", m.get('manifest_version')==3)
c("nativeMessaging stays in permissions", 'nativeMessaging' in p)
c("nativeMessaging not in host_permissions", 'nativeMessaging' not in h)
c("URL patterns moved to host_permissions", {'<all_urls>','http://*/*','https://*/*'}<=set(h))
c("no URL patterns left in permissions", not any('://' in x or x=='<all_urls>' for x in p))
c("webRequestBlocking dropped", 'webRequestBlocking' not in p)
c("storage added", 'storage' in p); c("alarms added", 'alarms' in p)
c("background.service_worker", m.get('background',{}).get('service_worker')=='sw-shim.js')
c("browser_action -> action", 'action' in m and 'browser_action' not in m)
csp=m.get('content_security_policy')
c("CSP object form", isinstance(csp,dict))
c("CSP unsafe-eval stripped", 'unsafe-eval' not in json.dumps(csp))
c("CSP remote source stripped", 'evil.example.com' not in json.dumps(csp))
w=m.get('web_accessible_resources')
c("WAR object array", isinstance(w,list) and w and isinstance(w[0],dict))
c("update_url removed", 'update_url' not in m)
c("key preserved", 'key' in m)
s=open(sys.argv[2],encoding='utf-8').read() if os.path.exists(sys.argv[2]) else ''
c("sw-shim.js installed with original script order", "const BACKGROUND_SCRIPTS = ['a.js', 'background.js'];" in s)
sys.exit(1 if bad else 0)
PY
if [ $? -eq 0 ]; then PASS=$((PASS+17)); else FAIL=$((FAIL+1)); fi

# ---------------------------------------------------------------- 5. platform guard
echo; echo "== 5. Windows-only scripts refuse to run off-Windows =="
for s in Diagnose-IdmNativeMessaging Setup-IdmIntegration; do
  args=(-ExtensionDir "$WORK/ext")
  [ "$s" = "Setup-IdmIntegration" ] && args+=(-IdmDir "$WORK/idm" -WhatIfOnly)
  out="$(pwsh -NoProfile -File "$ROOT/$s.ps1" "${args[@]}" 2>&1)"
  if echo "$out" | grep -q 'only runs on Windows'; then ok "$s.ps1 fails fast with a clear message"
  else bad "$s.ps1 did not emit the platform guard message"; fi
done

echo; echo "=============================="
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
