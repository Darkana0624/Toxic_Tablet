/*!
 * Toxic iPad App SDK v1 — for third-party apps and widgets (docs/APP_SDK.md).
 * Load it from the tablet resource:
 *   <script src="https://cfx-nui-toxic_ipad/ui/sdk/toxic-ipad-sdk.js"></script>
 * then:
 *   const ipad = await ToxicIPad.connect();
 *
 * Your page runs inside an <iframe> of the tablet. It talks to the tablet OS
 * only through window.parent.postMessage; to talk to YOUR resource's Lua, use
 * your own NUI callbacks with your resource name written out:
 *   fetch('https://my_resource/myCallback', { method: 'POST', body: '{}' })
 *
 * Nothing here is trusted by the server: storage and permissions are checked
 * again server-side, and notifications can only be sent by server code
 * (exports.toxic_ipad:Notify).
 */
(function () {
  'use strict';

  var VERSION = 1;
  var HANDSHAKE_MS = 10000;
  var REQUEST_MS = 15000;
  var FORWARDED_KEYS = { Escape: 1, F1: 1, F2: 1, F3: 1 };

  if (window.ToxicIPad && window.ToxicIPad.version === VERSION) return;

  var parentWin = window.parent;
  var osOrigin = null; // learnt from the first reply; later messages must match
  var seq = 0;
  var pending = {};
  var listeners = { lifecycle: [], context: [], route: [], data: [] };
  var lastData; // widgets: the latest UpdateWidget data
  var api = null;
  var connecting = null;
  var errorCount = 0;

  function post(message) {
    if (!parentWin || parentWin === window) return;
    message.sdk = VERSION;
    parentWin.postMessage(message, osOrigin || '*');
  }

  function request(type, payload) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      var timer = setTimeout(function () {
        delete pending[id];
        reject(new Error('toxic-ipad: "' + type + '" timed out'));
      }, type === 'photos.pick' ? 300000 : type === 'confirm' || type === 'requestPermission' ? 120000 : REQUEST_MS);
      pending[id] = { resolve: resolve, reject: reject, timer: timer };
      post({ id: id, type: type, payload: payload || {} });
    });
  }

  function fire(type, payload) {
    post({ type: type, payload: payload || {} });
  }

  function emit(name, value) {
    var list = listeners[name] || [];
    for (var i = 0; i < list.length; i++) {
      try {
        list[i](value);
      } catch (e) {
        report(e);
      }
    }
  }

  function applyContext(ctx) {
    if (!ctx) return;
    var root = document.documentElement;
    root.setAttribute('data-theme', ctx.theme);
    root.setAttribute('data-ipad-kind', ctx.kind);
    root.setAttribute('data-orientation', ctx.orientation || 'landscape');
    if (ctx.locale) root.setAttribute('lang', ctx.locale);
    if (ctx.reducedMotion) root.setAttribute('data-reduced-motion', '');
    else root.removeAttribute('data-reduced-motion');
    root.style.setProperty('--ipad-unit', ctx.unit + 'px');
    root.style.setProperty('--ipad-text-scale', String(ctx.textScale || 1));
    root.style.setProperty('--ipad-safe-top', (ctx.safeArea ? ctx.safeArea.top : 0) + 'px');
    root.style.setProperty('--ipad-safe-bottom', (ctx.safeArea ? ctx.safeArea.bottom : 0) + 'px');
    var tokens = ctx.tokens || {};
    for (var name in tokens) {
      if (Object.prototype.hasOwnProperty.call(tokens, name) && /^--[\w-]+$/.test(name)) {
        // --label-1 → --ipad-label-1
        root.style.setProperty('--ipad-' + name.slice(2), tokens[name]);
      }
    }
    if (api && api.options.units) root.style.fontSize = ctx.unit + 'px';
  }

  function report(err) {
    errorCount++;
    if (errorCount > 50) return; // the OS counts too; stop flooding
    var message = err && (err.stack || err.message) ? String(err.stack || err.message) : String(err);
    fire('error', { message: message.slice(0, 2000) });
  }

  window.addEventListener('message', function (event) {
    if (event.source !== parentWin) return;
    var m = event.data;
    if (!m || m.sdk !== VERSION || typeof m.type !== 'string') return;
    if (osOrigin === null) osOrigin = /^https?:\/\//.test(event.origin) ? event.origin : '*';
    else if (osOrigin !== '*' && event.origin !== osOrigin) return;

    if (m.type === 'reply') {
      var p = pending[m.id];
      if (!p) return;
      delete pending[m.id];
      clearTimeout(p.timer);
      if (m.ok) p.resolve(m.value);
      else p.reject(new Error(m.err || 'error'));
    } else if (m.type === 'context') {
      if (api) {
        api.context = m.context;
        applyContext(m.context);
      }
      emit('context', m.context);
    } else if (m.type === 'lifecycle') {
      emit('lifecycle', m.event);
    } else if (m.type === 'route') {
      if (api) api.context.route = m.route;
      emit('route', m.route);
    } else if (m.type === 'data') {
      lastData = m.data;
      if (api) api.data = m.data;
      emit('data', m.data);
    }
  });

  window.addEventListener('error', function (e) {
    report(e.error || e.message);
  });
  window.addEventListener('unhandledrejection', function (e) {
    report(e.reason);
  });

  // A click inside the page: the tablet gives this window the focus (Split
  // View side, Slide Over). Clicks inside an iframe never reach the OS.
  window.addEventListener('pointerdown', function () {
    if (api) fire('pointer');
  }, true);

  // Esc and F1–F3 belong to the tablet unless the app handled them.
  window.addEventListener('keydown', function (e) {
    if (FORWARDED_KEYS[e.key] && !e.defaultPrevented) {
      e.preventDefault();
      fire('key', { key: e.key });
    }
  });

  function makeApi(result, options) {
    var readySent = false;
    return {
      version: VERSION,
      options: options,
      context: result.context,
      app: result.app,
      /** widgets: the latest data sent with exports.toxic_ipad:UpdateWidget (undefined until the first) */
      data: lastData,

      /** 'lifecycle' (launch|focus|blur|suspend|resume|close), 'context', 'route', 'data' (widgets) */
      on: function (name, fn) {
        if (listeners[name] && typeof fn === 'function') listeners[name].push(fn);
        return this;
      },
      off: function (name, fn) {
        var list = listeners[name] || [];
        var i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
        return this;
      },
      /** Tell the OS your first frame is drawn (removes the launch splash). */
      ready: function () {
        if (readySent) return;
        readySent = true;
        fire('ready');
      },
      close: function () {
        return request('close');
      },
      home: function () {
        return request('home');
      },
      setBadge: function (count) {
        return request('badge', { count: Math.max(0, Math.min(9999, Math.floor(Number(count) || 0))) });
      },
      /** { text, kind?: 'info'|'success'|'error' } — local, not a notification */
      toast: function (opts) {
        if (typeof opts === 'string') opts = { text: opts };
        return request('toast', { text: String(opts.text).slice(0, 200), kind: opts.kind });
      },
      /** { title, message?, confirm?, destructive? } → Promise<boolean> */
      confirm: function (opts) {
        return request('confirm', {
          title: String(opts.title).slice(0, 80),
          message: opts.message ? String(opts.message).slice(0, 300) : undefined,
          confirm: opts.confirm ? String(opts.confirm).slice(0, 24) : undefined,
          destructive: opts.destructive === true,
        });
      },
      /** → Promise<'granted'|'denied'|'prompt'> */
      permission: function (name) {
        return request('permission', { name: name });
      },
      /** Shows the system prompt once; → Promise<'granted'|'denied'|'prompt'> */
      requestPermission: function (name) {
        return request('requestPermission', { name: name });
      },
      /** Per-device key/value storage for your app (quota checked by the server). */
      storage: {
        get: function (key) {
          return request('storage.get', { key: key });
        },
        set: function (key, value) {
          return request('storage.set', { key: key, value: value });
        },
        remove: function (key) {
          return request('storage.remove', { key: key });
        },
      },
      /** The player's photos (needs 'photos' in your RegisterApp permissions). */
      photos: {
        /**
         * Opens the system photo picker. Asks for the 'photos' permission the
         * first time. → Promise<{ id, url, time, location, selfie } | null>
         * (null = the player cancelled; rejects when the permission is denied).
         */
        pick: function () {
          return request('photos.pick');
        },
      },
      /** Opens an installed app, optionally at a route. */
      openApp: function (appId, route) {
        return request('openApp', { app: appId, route: route || null });
      },
    };
  }

  window.ToxicIPad = {
    version: VERSION,
    /**
     * Connects to the tablet OS. Resolves with the SDK object once the OS
     * answered (rejects after 10 s, e.g. when the page is opened outside the
     * tablet). options.units = true sets <html> font-size to the OS unit, so
     * 1rem in your CSS equals 1rem in the OS.
     */
    connect: function (options) {
      if (connecting) return connecting;
      options = options || {};
      connecting = new Promise(function (resolve, reject) {
        var timer = setTimeout(function () {
          connecting = null;
          reject(new Error('toxic-ipad: no answer from the tablet (is this page running inside toxic_ipad?)'));
        }, HANDSHAKE_MS);
        request('hello', { version: VERSION }).then(function (result) {
          clearTimeout(timer);
          api = makeApi(result, options);
          applyContext(result.context);
          resolve(api);
        }, function (err) {
          clearTimeout(timer);
          connecting = null;
          reject(err);
        });
      });
      return connecting;
    },
  };
})();
