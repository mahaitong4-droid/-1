# IDM 扩展 Native Messaging 排障工具包

针对 Chrome 152（已彻底移除 MV2）下手工加载 IDM Integration Module 后
扩展报 `Cannot launch IDM`、`IDMMsgHost.exe` 从不出现在进程列表的问题。

> **脚本正文全部是纯 ASCII**，中文说明只放在本文件里。
> 原因见下面第一节 —— 之前那一版脚本因为带中文注释而根本无法运行。

---

## 〇、先修这个：脚本跑不起来是编码问题（已修复）

第一版脚本在 PowerShell 5.1 下报大量 `表达式或语句中包含意外的标记`、
`字符串缺少终止符`，输出里能看到 `浣?background.service_worker 娌￠厤` 这类乱码。

**根因**：Windows PowerShell 5.1 读 `.ps1` 时，**文件没有 BOM 就按系统 ANSI 代码页解码**。
中文 Windows 上那是 GBK。UTF-8 编码的中文字节被按 GBK 解码后字节错位，
其中某些字节恰好落在引号位置，破坏了引号配对 —— 于是产生一连串级联语法错误。

注意这里有个**方向相反**的坑，两者不要混淆：

| 文件 | 要求 | 谁的规定 |
|---|---|---|
| `.ps1` 脚本 | UTF-8 **要带 BOM**（否则 PS 5.1 按 GBK 读） | Windows PowerShell 5.1 |
| native host `.json` | UTF-8 **不能带 BOM**（否则解析失败） | Chrome |

**本版的处理**：脚本正文改成纯 ASCII（英文提示），并额外加了 UTF-8 BOM。
两道保险 —— 即使经 `web.fetch`、剪贴板、聊天窗口转手把 BOM 弄丢了，
纯 ASCII 的内容在任何代码页下解码结果都一样，不会再坏。

---

## 一、结论：排查方向错了

`IDMMsgHost.exe` **从不被拉起**，说明 Chrome 压根没走到"启动 host"这一步。
之前的动作全部集中在改 JSON 里的 `allowed_origins` —— 但那是**最后一道**校验，
只有 Chrome 已经成功找到并解析了那份 JSON 才会用到它。

Windows 上 Chrome 查找 native messaging host 的路径**只有注册表**：

```
HKCU\Software\Google\Chrome\NativeMessagingHosts\<host 名>   (默认值 = JSON 的完整路径)
HKLM\Software\Google\Chrome\NativeMessagingHosts\<host 名>
```

它**不会**扫描任何目录去找 JSON（这一点和 Linux/macOS 不同）。
注册表没登记，JSON 写得再正确也永远不会被读。

---

## 二、host 名到底是哪个：`com.tonec.idm` 还是 `com.internetdownloadmanager.pdmbehavior`？

**这一条尚未证实。** 之前汇报里说"扩展代码实际连接的是 `com.tonec.idm`"，
但当时 `Diagnose` 脚本因编码问题从未成功运行过，而 `Repair` 脚本里并不包含这个字符串，
所以这个结论的来源无法追溯。

**不要猜。** 两种处理方式：

**A. 用一行命令实锤**（纯 ASCII，不需要任何脚本文件）：

```powershell
Get-ChildItem 'C:\path\to\extracted' -Recurse -Filter *.js | ForEach-Object {
  [regex]::Matches((Get-Content -Raw $_.FullName), '(?:connectNative|sendNativeMessage)\s*\(\s*[''"]([^''"]+)')
} | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

打印出来的就是扩展真正要连的 host 名。若什么都没打印，说明代码被压缩成了运行时拼接，
或者 MV3 转换后 background 脚本压根没被加载 —— 后者本身就是个要修的问题。

**B. 两个都注册。** `Setup-IdmIntegration.ps1` 默认就这么做：
自动检测 + 两个候选名各写一份 JSON、各登记一次注册表。
注册一个没人连的 host 名完全无害，这样就不必依赖上面那条结论是否正确。

---

## 三、根因按可能性排序

| # | 根因 | 为什么符合现象 |
|---|---|---|
| 1 | **注册表没有 host 登记项** | 便携版不写注册表，这正是"免安装"的代价。完全解释"进程从不出现" |
| 2 | **扩展 ID 不固定** | 无 `key` 时 ID 由**扩展目录绝对路径**哈希得到，重解压/换目录就变，手工白名单永远追不上 |
| 3 | **host 名注册错了** | 见上一节 |
| 4 | **JSON 编码不是 UTF-8** | 中文路径 + ANSI 保存 → Chrome 解析失败 |
| 5 | **IDM 启动时覆盖自己的 JSON** | 把 `allowed_origins` 刷回官方 ID，手工加的条目被吃掉 |
| 6 | **MV3 转换弄丢 `nativeMessaging` 权限** | 转换时容易连同 URL 权限一起挪进 `host_permissions` |
| 7 | **IDM 侧没就绪** | 见下一节 |

---

## 四、`Cannot launch IDM` 错误页说明了什么

已捕获到的完整原文：

> `Error: Cannot launch IDM, either IDM application is not installed, or some of its files are corrupted.`
> `To integrate IDM into Chrome, please install IDM first. If IDM is installed, please reinstall it.`
> **`Advanced browser integration must be enabled in the IDM options.`**

这是 IDM 扩展自己的 `welcome.html?error=1` 页面，**不是 Chrome 的报错**。
两点推论：

1. 最后那句是明确的操作要求：**IDM → 选项 → 常规 → 勾选"高级浏览器集成"**。
   便携版默认往往没开。这一步和注册表同等重要，漏了照样失败。
2. 这句提示既可能出现在"根本连不上 host"时，也可能出现在
   "host 起来了但找不到 `IDMan.exe` 而秒退"时。**光看这个页面无法区分**，
   所以必须用下面的 `sendNativeMessage` 拿 Chrome 的原始错误。

因此**不能靠"任务管理器里没有 IDMMsgHost.exe"断定 host 没被拉起** —— 它可能启动后立刻退出了。

---

## 五、关键：拿 Chrome 的原始错误（30 秒定位）

`chrome://extensions` → 该扩展 → 点 **Service Worker** 打开控制台：

```js
for (const n of ['com.internetdownloadmanager.pdmbehavior','com.tonec.idm'])
  chrome.runtime.sendNativeMessage(n, {}, r =>
    console.log(n, '->', r, chrome.runtime.lastError && chrome.runtime.lastError.message))
```

（装了 `sw-shim.js` 的话，直接执行 `idmProbe()` 效果相同。）

| 错误字符串 | 断在哪一环 | 对应根因 |
|---|---|---|
| `Specified native messaging host not found.` | 注册表没登记 / 键名与 JSON 的 `name` 不一致 / JSON 路径不存在或解析失败 | 1、3、4 |
| `Access to the specified native messaging host is forbidden.` | 扩展 ID 不在 `allowed_origins`，或条目结尾少斜杠，或没有 `nativeMessaging` 权限 | 2、5、6 |
| `Failed to start native messaging host.` | JSON 里 `path` 不可执行 / 路径编码错乱 / 权限不足 | 4 |
| `Native host has exited.` | **exe 确实被拉起了但自己退了** —— Chrome 侧已打通，是 IDM 侧问题 | 7 |
| 无错误、有响应返回 | 链路已通 | — |

---

## 六、执行顺序

扩展目前已从 Chrome 中被移除，所以要从头走一遍。
**只需要一个脚本文件** —— `Setup-IdmIntegration.ps1` 是自包含的，
不依赖工具包里其它任何文件（这是针对你们那边文件传输一直失败的设计）。

```powershell
# 先预览，不写任何东西
.\Setup-IdmIntegration.ps1 `
    -ExtensionDir 'C:\path\to\extracted' `
    -IdmDir 'E:\path\to\IDM' `
    -CrxPath 'E:\path\to\IDM\IDMGCExt.crx' `
    -WhatIfOnly

# 确认无误后去掉 -WhatIfOnly 实际执行
```

它会依次完成：定位 IDM → 从 CRX 提取公钥写入 `manifest.json` 固定扩展 ID →
检测 host 名并合并两个候选 → 写 host manifest（UTF-8 无 BOM）→
登记注册表（Chrome/Chromium/Edge，仅 HKCU，不需要管理员）→
登记 `IDMan.exe` 路径 → **回读校验并打印报告**。

然后按脚本末尾打印的步骤做：

1. 启动 `IDMan.exe` 并保持运行，**开启"高级浏览器集成"**
2. `chrome://extensions` → 开发者模式 → **加载已解压的扩展程序** → 选扩展目录
   → 确认显示的 ID 就是脚本打印的那个
3. **完全退出 Chrome**（任务管理器确认没有残留 `chrome.exe`）再重开
   —— native host 的注册表项只在浏览器启动时读取
4. Service Worker 控制台跑第五节那段，看原始错误

### 其余脚本（可选）

| 脚本 | 用途 |
|---|---|
| `Diagnose-IdmNativeMessaging.ps1` | 独立复查，按链路逐环打印 OK/FAIL |
| `Get-CrxKey.ps1` | 只做"提取公钥 / 固定扩展 ID"这一件事 |
| `Convert-ManifestToMv3.ps1` + `mv3/sw-shim.js` | 重做 MV2→MV3 转换 |

> `Repair-IdmNativeMessaging.ps1` 已删除 —— `Setup-IdmIntegration.ps1` 是它的严格超集。
> 如果你们本地还留着旧的那一份，删掉，别再跑它（它也带中文、同样跑不起来）。

---

## 七、完全不传文件的兜底方案

如果文件传输还是失败，下面这段可以直接粘进 PowerShell 跑。
纯 ASCII、无外部依赖，只做最关键的两件事：写 JSON + 登记注册表。
把前三个变量改成你们的实际路径和扩展 ID 即可。

```powershell
$ExtId  = 'PASTE_EXTENSION_ID_FROM_CHROME_EXTENSIONS_PAGE'
$MsgHost= 'E:\path\to\IDM\IDMMsgHost.exe'
$Out    = Join-Path $env:LOCALAPPDATA 'IDMNativeHost'

New-Item -ItemType Directory -Path $Out -Force | Out-Null
foreach ($hn in @('com.internetdownloadmanager.pdmbehavior','com.tonec.idm')) {
  $p = Join-Path $Out "$hn.json"
  $doc = [ordered]@{ name=$hn; description='IDM Native Messaging Host'; path=$MsgHost;
                     type='stdio'; allowed_origins=@("chrome-extension://$ExtId/") }
  [System.IO.File]::WriteAllText($p, ($doc | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding($false)))     # 必须无 BOM
  foreach ($root in @('HKCU:\Software\Google\Chrome\NativeMessagingHosts',
                      'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts')) {
    $k = Join-Path $root $hn
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -LiteralPath $k -Name '(default)' -Value $p
  }
  Write-Host "registered $hn -> $p"
}
```

若 IDM 装在中文路径下，把 `$MsgHost` 换成 8.3 短路径：

```powershell
(New-Object -ComObject Scripting.FileSystemObject).GetFile('E:\中文路径\IDMMsgHost.exe').ShortPath
```

---

## 八、设计说明

**host manifest 写到 `%LOCALAPPDATA%\IDMNativeHost\`，不动 IDM 目录里那份。**
IDM 启动时会重写它自己那份 JSON，把 `allowed_origins` 刷回官方 ID。
放到 IDM 不知道的路径，它就永远不会被覆盖 —— 根因 5 被结构性消除，
不需要靠只读属性或 ACL 去"锁"。

**中文路径自动改写成 8.3 短路径**（如 `E:\XIAZAI~1\IDM642~1\IDM\IDMMSG~1.EXE`）。
若该卷禁用了 8.3 名称（`fsutil 8dot3name query`），脚本会退回原路径并提示；
此时最省事的是把 IDM 移到纯英文路径。

**扩展目录建议搬离临时路径。** 现在的 `...\chats\2026-09-01\new-chat-4\...`
带日期和会话号，属于会被清理的位置（`git clone` 到该目录也已出现 Permission denied）。
建议移到 `%LOCALAPPDATA%\IDMExtension\`。固定 `key` 之后 ID 不再跟目录绑定，搬动是安全的。

---

## 九、已知限制

- `sw-shim.js` 用 `importScripts` 保留 MV2 的经典全局作用域（换 ES module 会让跨文件
  全局引用全部失效）。代价是不能用顶层 `await`，`localStorage` 模拟层异步灌数据：
  若脚本在顶层同步读 `localStorage`，第一次会读到空值。
  IDM 的 host 名是硬编码常量，不走 `localStorage`，不影响连接本身。
- MV3 的 `webRequest` 只能观察不能拦截改写，`webRequestBlocking` 会被转换脚本移除。
- service worker 空闲 30 秒被回收，`sw-shim.js` 用 30 秒 alarm 保活，
  但这不是官方保证的机制，长时间空闲后首次下载仍可能有一次重连延迟。
- 所有 PowerShell 脚本**未在真机运行过**（开发环境是 Linux 容器，没有 PowerShell）。
  已做的验证：纯 ASCII 校验、大括号/引号配对静态检查、
  CRX 解析与扩展 ID 推导用等价 Python 实现交叉验证（7 项断言通过）、
  `sw-shim.js` 通过 `node --check`。首次执行请先带 `-WhatIfOnly`。

---

## 十、退路

如果打通链路的时间成本超出预期，**装 IDM 官方完整版（非便携版）**是最省事的路径：
安装程序会一次性把注册表登记、host manifest、`IDMan.exe` 路径全部写对，
扩展侧只剩"加载已解压的扩展"这一步。
`Get-CrxKey.ps1` 和 `Convert-ManifestToMv3.ps1` 在那种情况下依然适用。
