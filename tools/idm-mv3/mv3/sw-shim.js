/*
 * sw-shim.js - MV2 background page -> MV3 service worker compatibility layer
 *
 * Usage: in manifest.json set
 *     "background": { "service_worker": "sw-shim.js" }
 * and list the original MV2 background.scripts entries below, in the same order.
 *
 * ASCII-only on purpose. These files get moved around by hand, through web fetches and
 * chat clients, and every hop is a chance for a re-encode. Staying in ASCII removes that
 * whole class of failure.
 *
 * Why importScripts instead of ES module imports:
 *   MV2 background scripts reference each other through GLOBAL variables. As ES modules,
 *   top-level var/function become module-scoped, so every cross-file reference silently
 *   becomes undefined - the extension loads but nothing works. importScripts keeps the
 *   classic global scope that MV2 code expects. The cost is no top-level await, which is
 *   why the localStorage emulation below is hydrated asynchronously.
 */

// The original MV2 background.scripts list, in the original order.
const BACKGROUND_SCRIPTS = ['background.js'];

// ---------------------------------------------------------------- window alias
// In an MV2 background page, window IS the global object. A service worker has no window.
self.window = self;
if (typeof globalThis !== 'undefined' && !globalThis.window) globalThis.window = globalThis;

// ---------------------------------------------------------------- localStorage
// Service workers have no localStorage. This emulates the synchronous API over an
// in-memory cache that is written through to chrome.storage.local.
//
// Known limitation: the cache is hydrated ASYNCHRONOUSLY on every cold start of the
// service worker. A script that reads localStorage at top level will see empty values on
// the first tick and correct ones afterwards. IDM's native host name is a hardcoded
// constant rather than a stored setting, so this does not affect the connection itself.
// If your own code needs the values at top level, wrap it in self.__shimReady.then(...).
(function installLocalStorage() {
  const STORE_KEY = '__mv2_localStorage__';
  let cache = Object.create(null);
  let flushTimer = null;

  function flush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      try { chrome.storage.local.set({ [STORE_KEY]: cache }); } catch (e) { /* ignore */ }
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
          // Do not clobber keys the script has already written since startup.
          if (!Object.prototype.hasOwnProperty.call(cache, k)) cache[k] = saved[k];
        }
        resolve();
      });
    } catch (e) { resolve(); }
  });
})();

// ---------------------------------------------------------------- XMLHttpRequest
// Service workers have fetch but no XHR. This is a minimal but usable stand-in.
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
        console.error('[idm-shim] XHR failed:', this._url, err);
        this.status = 0;
        this._setState(4);
        this._emit('error');
      });
    }
  };
  function safeJson(t) { try { return JSON.parse(t); } catch (e) { return null; } }
}

// ---------------------------------------------------------------- native messaging logging
// The single most useful thing when debugging "Cannot launch IDM": surface Chrome's own
// error string instead of only the extension's generic message.
(function wrapNativeMessaging() {
  if (!chrome.runtime || !chrome.runtime.connectNative) {
    console.error('[idm-shim] chrome.runtime.connectNative is missing - the manifest has no "nativeMessaging" permission');
    return;
  }
  try {
    const rawConnect = chrome.runtime.connectNative.bind(chrome.runtime);
    chrome.runtime.connectNative = function (name) {
      console.log('[idm-shim] connectNative ->', name);
      const port = rawConnect(name);
      port.onDisconnect.addListener(() => {
        const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
        console.error('[idm-shim] native port disconnected:', name, '| Chrome says:', err || '(no error)');
      });
      return port;
    };

    const rawSend = chrome.runtime.sendNativeMessage.bind(chrome.runtime);
    chrome.runtime.sendNativeMessage = function (name, msg, cb) {
      return rawSend(name, msg, function (resp) {
        const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
        if (err) console.error('[idm-shim] sendNativeMessage failed:', name, '|', err);
        if (typeof cb === 'function') cb(resp);
      });
    };
  } catch (e) {
    console.warn('[idm-shim] could not wrap native messaging (harmless):', e);
  }
})();

// Manual probe: run idmProbe() in the Service Worker console to see Chrome's raw error.
// Called with no argument it tries both known IDM host names.
self.idmProbe = function (hostName) {
  const names = hostName ? [hostName] : ['com.internetdownloadmanager.pdmbehavior', 'com.tonec.idm'];
  for (const name of names) {
    chrome.runtime.sendNativeMessage(name, {}, (resp) => {
      const err = chrome.runtime.lastError && chrome.runtime.lastError.message;
      console.log('[idmProbe]', name, '| response:', resp, '| error:', err || '(none)');
    });
  }
};

// ---------------------------------------------------------------- keepalive
// An MV3 service worker is reclaimed after about 30 seconds idle, taking any open native
// port with it. An alarm firing every 30 seconds resets that idle timer.
// Requires "alarms" in manifest.permissions. 0.5 minutes is the minimum period.
if (chrome.alarms) {
  chrome.alarms.create('idm-sw-keepalive', { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((a) => {
    if (a.name === 'idm-sw-keepalive') { /* empty on purpose: the event itself resets the timer */ }
  });
} else {
  console.warn('[idm-shim] no alarms permission; the service worker will be reclaimed after 30s idle and the native connection will drop');
}

// ---------------------------------------------------------------- load the original scripts
// Must come last: window, localStorage and XHR all have to be in place first.
// importScripts is only callable during the service worker's initial evaluation, so this
// cannot be deferred into an async callback.
try {
  importScripts(...BACKGROUND_SCRIPTS);
  console.log('[idm-shim] loaded:', BACKGROUND_SCRIPTS.join(', '));
} catch (e) {
  console.error('[idm-shim] failed to load background scripts:', e);
}
