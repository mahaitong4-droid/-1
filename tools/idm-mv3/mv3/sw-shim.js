/*
 * sw-shim.js —— MV2 background page -> MV3 service worker 兼容层
 *
 * 用法：manifest.json 里写
 *     "background": { "service_worker": "sw-shim.js" }
 * 然后把原来 MV2 的 background.scripts 数组原样填进下面的 BACKGROUND_SCRIPTS。
 *
 * 为什么用 importScripts 而不是 ES module import：
 *   MV2 的 background 多个脚本之间靠【全局变量】互相引用。
 *   改成 module 后顶层 var/function 会变成模块作用域，跨文件引用会全部变成 undefined，
 *   表现就是"扩展加载正常但什么都不工作"。importScripts 保留经典全局作用域，行为和 MV2 一致。
 *   代价是不能用顶层 await（见下面 localStorage 的说明）。
 */

// 原 MV2 manifest 里 background.scripts 的内容，顺序必须保持一致
const BACKGROUND_SCRIPTS = ['background.js'];

// ---------------------------------------------------------------- window 别名
// MV2 background page 里的 window 就是全局对象；service worker 里没有 window。
self.window = self;
if (typeof globalThis !== 'undefined' && !globalThis.window) globalThis.window = globalThis;

// ---------------------------------------------------------------- localStorage
// service worker 里没有 localStorage。这里用内存缓存 + chrome.storage.local 回写模拟同步语义。
//
// 已知限制：service worker 每次冷启动时，缓存是【异步】从 chrome.storage.local 灌进来的。
// 如果被引入的脚本在顶层就同步读 localStorage，第一次会读到空值，之后才正确。
// IDM 的 native host 名是代码里的硬编码常量，不走 localStorage，所以不影响连接本身。
// 如果你的脚本确实在顶层依赖 localStorage，用 self.__shimReady.then(...) 包一层。
(function installLocalStorage() {
  const STORE_KEY = '__mv2_localStorage__';
  let cache = Object.create(null);
  let flushTimer = null;

  function flush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      try { chrome.storage.local.set({ [STORE_KEY]: cache }); } catch (e) { /* 忽略 */ }
    }, 0);
  }

  self.localStorage = {
    getItem(k) {
      k = String(k);
      return Object.prototype.hasOwnProperty.call(cache, k) ? cache[k] : null;
    },
    setItem(k, v) { cache[String(k)] = String(v); flush(); },
    removeItem(k) { delete cache[String(k)]; flush(); },
    clear() { cache = Object.create(null); flush(); },
    key(i) { const ks = Object.keys(cache); return i < ks.length ? ks[i] : null; },
    get length() { return Object.keys(cache).length; }
  };

  self.__shimReady = new Promise((resolve) => {
    try {
      chrome.storage.local.get(STORE_KEY, (got) => {
        const saved = got && got[STORE_KEY];
        if (saved) for (const k of Object.keys(saved)) {
          // 已经被脚本写过的键不覆盖，避免把新值冲掉
          if (!Object.prototype.hasOwnProperty.call(cache, k)) cache[k] = saved[k];
        }
        resolve();
      });
    } catch (e) { resolve(); }
  });
})();

// ---------------------------------------------------------------- XMLHttpRequest
// service worker 里没有 XHR，只有 fetch。这里提供一个够用的最小实现。
if (typeof XMLHttpRequest === 'undefined') {
  self.XMLHttpRequest = class XMLHttpRequestShim {
    constructor() {
      this.readyState = 0;
      this.status = 0;
      this.statusText = '';
      this.responseText = '';
      this.response = '';
      this.responseType = '';
      this.timeout = 0;
      this.onload = null;
      this.onerror = null;
      this.onreadystatechange = null;
      this._headers = {};
      this._respHeaders = '';
      this._aborted = false;
      this._listeners = Object.create(null);
    }
    addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
    removeEventListener(type, fn) {
      const l = this._listeners[type];
      if (l) this._listeners[type] = l.filter((f) => f !== fn);
    }
    _emit(type) {
      const ev = { type, target: this };
      const direct = this['on' + type];
      if (typeof direct === 'function') { try { direct.call(this, ev); } catch (e) { console.error(e); } }
      for (const fn of this._listeners[type] || []) { try { fn.call(this, ev); } catch (e) { console.error(e); } }
    }
    _setState(s) {
      this.readyState = s;
      if (typeof this.onreadystatechange === 'function') {
        try { this.onreadystatechange.call(this, { type: 'readystatechange', target: this }); }
        catch (e) { console.error(e); }
      }
    }
    open(method, url) { this._method = method; this._url = url; this._setState(1); }
    setRequestHeader(k, v) { this._headers[k] = v; }
    getAllResponseHeaders() { return this._respHeaders; }
    getResponseHeader(name) {
      const want = String(name).toLowerCase();
      for (const line of this._respHeaders.split('\r\n')) {
        const i = line.indexOf(':');
        if (i > 0 && line.slice(0, i).toLowerCase() === want) return line.slice(i + 1).trim();
      }
      return null;
    }
    abort() { this._aborted = true; this._setState(0); this._emit('abort'); }
    send(body) {
      const init = { method: this._method || 'GET', headers: this._headers };
      if (body != null && init.method !== 'GET' && init.method !== 'HEAD') init.body = body;
      fetch(this._url, init).then(async (res) => {
        if (this._aborted) return;
        this.status = res.status;
        this.statusText = res.statusText;
        const hs = [];
        res.headers.forEach((v, k) => hs.push(k + ': ' + v));
        this._respHeaders = hs.join('\r\n');
        this._setState(2);
        this._setState(3);
        const text = await res.text();
        this.responseText = text;
        this.response = this.responseType === 'json' ? safeJson(text) : text;
        this._setState(4);
        this._emit('load');
      }).catch((err) => {
        if (this._aborted) return;
        console.error('[idm-shim] XHR 失败:', this._url, err);
        this.status = 0;
        this._setState(4);
        this._emit('error');
      });
    }
  };
  function safeJson(t) { try { return JSON.parse(t); } catch (e) { return null; } }
}

// ---------------------------------------------------------------- native messaging 日志包装
// 这是排查 "Cannot launch IDM" 最有用的一段：
// 把 Chrome 的原始错误字符串打出来，而不是只看扩展自己的提示。
(function wrapNativeMessaging() {
  if (!chrome.runtime || !chrome.runtime.connectNative) {
    console.error('[idm-shim] chrome.runtime.connectNative 不存在 —— manifest 缺 "nativeMessaging" 权限');
    return;
  }
  try {
    const rawConnect = chrome.runtime.connectNative.bind(chrome.runtime);
    chrome.runtime.connectNative = function (name) {
      console.log('[idm-shim] connectNative ->', name);
      const port = rawConnect(name);
      port.onDisconnect.addListener(() => {
        const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
        console.error('[idm-shim] native port 断开:', name, '| Chrome 报错:', err || '(无)');
      });
      return port;
    };

    const rawSend = chrome.runtime.sendNativeMessage.bind(chrome.runtime);
    chrome.runtime.sendNativeMessage = function (name, msg, cb) {
      return rawSend(name, msg, function (resp) {
        const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
        if (err) console.error('[idm-shim] sendNativeMessage 失败:', name, '|', err);
        if (typeof cb === 'function') cb(resp);
      });
    };
  } catch (e) {
    console.warn('[idm-shim] 包装 native messaging 失败（不影响功能）:', e);
  }
})();

// 手工探针：在 Service Worker 控制台执行 idmProbe() 即可看到 Chrome 的原始错误
self.idmProbe = function (hostName) {
  const name = hostName || 'com.internetdownloadmanager.pdmbehavior';
  chrome.runtime.sendNativeMessage(name, {}, (resp) => {
    const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
    console.log('[idmProbe] host =', name, '| 响应 =', resp, '| 错误 =', err || '(无)');
  });
};

// ---------------------------------------------------------------- 保活
// MV3 service worker 空闲 30 秒就会被回收，连着的 native port 也跟着断。
// alarm 每 30 秒触发一次事件，把空闲计时器重置掉。
// 需要 manifest.permissions 里有 "alarms"。周期最小值是 0.5 分钟。
if (chrome.alarms) {
  chrome.alarms.create('idm-sw-keepalive', { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((a) => {
    if (a.name === 'idm-sw-keepalive') { /* 空处理即可，触发本身就会重置空闲计时 */ }
  });
} else {
  console.warn('[idm-shim] 没有 alarms 权限，service worker 会在 30 秒空闲后被回收，native 连接随之断开');
}

// ---------------------------------------------------------------- 载入原 background 脚本
// 必须放在最后：上面的 window / localStorage / XHR 都要先就位。
// importScripts 只能在 service worker 首次求值期间调用，所以不能包在异步回调里。
try {
  importScripts(...BACKGROUND_SCRIPTS);
  console.log('[idm-shim] 已载入:', BACKGROUND_SCRIPTS.join(', '));
} catch (e) {
  console.error('[idm-shim] 载入 background 脚本失败:', e);
}
