# IDM 扩展 Native Messaging 排障工具包

针对 Chrome 152（已彻底移除 MV2）下手工加载 IDM Integration Module 后
扩展持续报 `Cannot launch IDM`、`IDMMsgHost.exe` 从不出现在进程列表的问题。

---

## 一、结论：排查方向错了

`IDMMsgHost.exe` **从不被拉起**，说明 Chrome 压根没走到"启动 host"这一步。
之前的动作全部集中在改 JSON 里的 `allowed_origins` —— 但 `allowed_origins`
是**最后一道**校验，只有 Chrome 已经成功找到并解析了那份 JSON 才会用到它。

Windows 上 Chrome 查找 native messaging host 的路径**只有注册表**：

```
HKCU\Software\Google\Chrome\NativeMessagingHosts\<host 名>   (默认值 = JSON 的完整路径)
HKLM\Software\Google\Chrome\NativeMessagingHosts\<host 名>
```

它**不会**扫描任何目录去找 JSON（这一点和 Linux/macOS 不同 —— 那两个平台才是放
`NativeMessagingHosts/` 目录）。注册表没登记，JSON 写得再正确也永远不会被读。

而"注册表锁定"恰好还在你们的 ⏳ 未完成清单里 —— 这条链路很可能从头到尾没接上过。

---

## 二、根因按可能性排序

| # | 根因 | 为什么符合现象 |
|---|---|---|
| 1 | **注册表没有 host 登记项** | 便携版（免安装版）不写注册表，这正是"免安装"的代价。完全解释"进程从不出现" |
| 2 | **扩展 ID 不固定** | 解压加载且 `manifest.json` 无 `key` 时，ID 由**扩展目录的绝对路径**哈希得到。重新解压/换目录 ID 就变，手工维护的白名单永远追不上 |
| 3 | **JSON 编码不是 UTF-8** | 路径 `E:\下载软件\IDM 6.42 免安装版\...` 全是中文。JSON 若存成 ANSI/GBK，Chrome 的 UTF-8 解析直接失败 → 表现为 host not found。**你们只去掉了 BOM，没验证编码本身** |
| 4 | **IDM 启动时覆盖自己的 JSON** | IDM 会把 `allowed_origins` 刷回官方 ID，手工加的条目被吃掉。对应"重启 IDM 后又不行了" |
| 5 | **MV3 转换弄丢 `nativeMessaging` 权限** | 转换时容易把它连同 URL 权限一起挪进 `host_permissions`。此时 `chrome.runtime.connectNative` 直接不存在 |
| 6 | **host 起来了又秒退** | `Cannot launch IDM` 这句是 **IDM 侧**的提示而非 Chrome 的。便携版没在注册表登记 `IDMan.exe` 路径时，`IDMMsgHost.exe` 找不到主程序会立刻退出，快到用任务管理器根本看不见 |

第 6 条说明一件重要的事：**不能靠"进程列表里没有"来断定 host 没被拉起**。
必须拿 Chrome 的原始错误字符串来区分，见下一节。

---

## 三、先做这一步（30 秒定位）

`chrome://extensions` → 找到该扩展 → 点 **Service Worker** 打开控制台，执行：

```js
chrome.runtime.sendNativeMessage(
  'com.internetdownloadmanager.pdmbehavior',
  {},
  r => console.log('resp:', r, 'err:', chrome.runtime.lastError && chrome.runtime.lastError.message)
)
```

Chrome 返回的错误字符串直接对应病根：

| 错误字符串 | 断在哪一环 | 对应根因 |
|---|---|---|
| `Specified native messaging host not found.` | 注册表没登记 / 键名与 JSON 里 `name` 不一致 / JSON 路径不存在或解析失败 | 1、3 |
| `Access to the specified native messaging host is forbidden.` | 扩展 ID 不在 `allowed_origins`，或条目结尾少了斜杠，或没有 `nativeMessaging` 权限 | 2、4、5 |
| `Failed to start native messaging host.` | JSON 里 `path` 不可执行 / 路径编码错乱 / 权限不足 | 3 |
| `Native host has exited.` | **exe 确实被拉起了但自己退了** —— 是 IDM 侧问题，不是 Chrome 侧 | 6 |

前三种是 Chrome 侧，用本工具包修。第四种是 IDM 侧，见第五节。

---

## 四、执行顺序

四个脚本，都用 PowerShell 5.1+ 跑，**全部只写 HKCU，不需要管理员权限**。

```powershell
cd tools\idm-mv3

# ① 固定扩展 ID（把 CRX 的原始公钥写回 manifest.json 的 key）
#    做完这步，扩展 ID 会变回官方 ID，IDM 自带的白名单直接命中，
#    从此不用再手工维护 allowed_origins，也不怕换目录。
.\Get-CrxKey.ps1 `
    -CrxPath 'E:\下载软件\IDM 6.42 免安装版\IDM 6.42 免安装版\IDM\IDMGCExt.crx' `
    -PatchManifest 'C:\Users\win\Doubao\chats\2026-09-01\new-chat-4\idm_ext\extracted\manifest.json'

# ② 重做 MV2->MV3 转换（顺带装上 service worker 兼容层）
#    若你们现有的转换已经能正常加载，也建议跑一次 -WhatIfOnly 对比差异，
#    重点看 nativeMessaging 是否还在 permissions 里。
.\Convert-ManifestToMv3.ps1 -ExtensionDir 'C:\...\idm_ext\extracted' -WhatIfOnly
.\Convert-ManifestToMv3.ps1 -ExtensionDir 'C:\...\idm_ext\extracted'

# ③ 修 native messaging 链路（注册表 + 独立 host manifest + 中文路径规避）
.\Repair-IdmNativeMessaging.ps1 `
    -ExtensionDir 'C:\...\idm_ext\extracted' `
    -IdmDir 'E:\下载软件\IDM 6.42 免安装版\IDM 6.42 免安装版\IDM' `
    -RegisterIdmExePath

# ④ 复查，应当全绿
.\Diagnose-IdmNativeMessaging.ps1 -ExtensionDir 'C:\...\idm_ext\extracted'
```

**② 之后必须到 `chrome://extensions` 点「重新加载」，③ 之后必须完全退出 Chrome 再重开**
（任务管理器确认没有残留 `chrome.exe`）。native host 的注册表项只在 Chrome 启动时读取。
测试期间保持 `IDMan.exe` 运行。

### 各脚本做了什么

- **`Get-CrxKey.ps1`** —— 解析 CRX2/CRX3 头部取出原始公钥，按 Chrome 的算法
  （`SHA-256(公钥)` 前 16 字节 → 十六进制 → `0-f` 映射到 `a-p`）算出官方扩展 ID，
  并把公钥写进 `manifest.json` 的 `key`。**这一步是治本的**：ID 一旦固定，
  根因 2 和 4 同时消失。
- **`Convert-ManifestToMv3.ps1`** —— 正确处理 permissions 拆分
  （URL 串移到 `host_permissions`，`nativeMessaging` 等 API 权限**留在** `permissions`）、
  `background.scripts` → `service_worker`、`browser_action` → `action`、
  CSP 字符串 → 对象、`web_accessible_resources` 结构升级、删除 `update_url`，
  并装上 `sw-shim.js`。
- **`Repair-IdmNativeMessaging.ps1`** —— 见下。
- **`Diagnose-IdmNativeMessaging.ps1`** —— 按链路顺序逐环检查并打印 OK/FAIL，
  含 JSON 编码（BOM 与 GBK）检测、`allowed_origins` 结尾斜杠检测、
  注册表键名与 JSON `name` 一致性检测。

### `Repair` 脚本的两个关键设计

1. **host manifest 写到 `%LOCALAPPDATA%\IDMNativeHost\`，不动 IDM 目录里那份。**
   IDM 启动时会重写它自己那份 JSON，把 `allowed_origins` 刷回官方 ID。
   放到 IDM 不知道的路径，它就永远不会被覆盖 —— 这样根因 4 被结构性消除，
   不需要靠设只读属性或 ACL 去"锁"。

2. **IDM 装在中文路径下时，JSON 里的 `path` 自动改写成 8.3 短路径**
   （如 `E:\XIAZAI~1\IDM642~1\IDM\IDMMSG~1.EXE`），纯 ASCII，彻底绕开编码问题。
   若该卷禁用了 8.3 名称生成（`fsutil 8dot3name query`），脚本会退回原路径并给出提示 ——
   此时最省事的办法是把 IDM 便携版整个移到纯英文路径（如 `D:\IDM`）后重跑。

---

## 五、如果错误是 `Native host has exited.`

这说明 Chrome 侧已经全部打通，问题在 IDM 便携版自己：
`IDMMsgHost.exe` 被拉起后找不到 `IDMan.exe` 就会立刻退出，扩展显示的正是 `Cannot launch IDM`。

便携版通常没有在注册表登记主程序路径。`Repair` 脚本加 `-RegisterIdmExePath` 会写：

```
HKCU\Software\DownloadManager\ExePath = <IdmDir>\IDMan.exe
```

同时确保：先手工启动一次 `IDMan.exe` 并保持运行，让它自建配置项，再测试扩展。

---

## 六、关于剩下的"锁定"任务

- **注册表锁定**：不需要。我们的 host manifest 在 IDM 不知道的路径下，没有被覆盖的风险。
  给注册表加 Deny ACE 反而会让日后升级 IDM 时出现难以排查的故障。
- **扩展目录权限锁定**：比加 ACL 更要紧的是**先把扩展目录挪出临时路径**。
  现在的 `C:\Users\win\Doubao\chats\2026-09-01\new-chat-4\idm_ext\extracted`
  带日期和会话号，属于会被清理的路径。建议移到 `%LOCALAPPDATA%\IDMExtension\` 之类的稳定位置。
  做完第 ① 步（写入 `key`）后 ID 不再跟目录绑定，**搬目录不会再导致 ID 变化**，可以放心移动。
- Chrome 152 下解压加载的扩展仍需保持**开发者模式**开启，这一点无法用 ACL 规避。

---

## 七、已知限制

- `sw-shim.js` 用 `importScripts` 保留 MV2 的经典全局作用域（换成 ES module
  会让顶层 `var`/`function` 变成模块作用域，跨文件全局引用全部失效）。
  代价是不能用顶层 `await`，所以 `localStorage` 模拟层的数据是**异步**灌入的：
  若被引入的脚本在顶层就同步读 `localStorage`，第一次会读到空值。
  IDM 的 native host 名是代码里的硬编码常量，不走 `localStorage`，不影响连接本身。
- MV3 的 `webRequest` 只能观察不能拦截改写，`webRequestBlocking` 会被转换脚本移除。
  IDM 主要靠观察请求头 + `downloads` 接管，通常够用；若确实需要拦截，
  得改用 `declarativeNetRequest` 重写，那是另一项工程。
- service worker 会在空闲 30 秒后被回收，连着的 native port 随之断开。
  `sw-shim.js` 用 30 秒周期的 alarm 保活（需要 `alarms` 权限），
  但这不是官方保证的机制，长时间空闲后首次触发下载仍可能有一次重连延迟。

---

## 八、退路

如果打通链路的时间成本超出预期，**装 IDM 官方的完整版（非便携版）**是最省事的路径：
安装程序会一次性把注册表登记、host manifest、`IDMan.exe` 路径全部写对，
扩展侧只剩"加载解压后的扩展"这一步。本工具包的 `Get-CrxKey.ps1` 和
`Convert-ManifestToMv3.ps1` 在那种情况下依然适用。
