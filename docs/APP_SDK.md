# TOXIC iPAD — APP SDK (v1)

Any resource (toxic_police, toxic_banking, a buyer's own script) adds a native-feeling app and widget to the tablet **without editing toxic_ipad**. A broken app never takes the OS down (§68).

A complete, working example ships in [`examples/toxic_ipad_hello`](../examples/toxic_ipad_hello) — copy it next to `toxic_ipad` and `ensure` it.

---

## 1. Two kinds of app, one contract

| | Built-in | External |
|---|---|---|
| Code lives in | `toxic_ipad/web/src/apps/<id>` | the app's own resource |
| Rendered as | React component inside an **error boundary** | **`<iframe>`** of `https://cfx-nui-<resource>/<file>` |
| Registered by | `config/apps.lua` | `exports.toxic_ipad:RegisterApp(def)` |
| Talks to its server via | toxic_ipad callbacks | its **own** NUI callbacks → its own Lua |
| Theme, language, dialogs, storage, permissions | OS stores | the SDK (postMessage) |

Why iframes: a separate document has its own JS heap and CSS. An exception, an endless loop or a stylesheet in a police app cannot break the Window Manager or leak into another app, and the author can use any framework. The iframe is sandboxed (`allow-scripts allow-same-origin allow-forms`): it cannot navigate the tablet page, open popups or `alert()` (which would freeze NUI).

---

## 2. Registering (server side of your resource)

```lua
local function register()
    exports.toxic_ipad:RegisterApp({
        id          = 'police_mdt',                          -- [a-z0-9_]{3,32}, unique, not "folder_…"
        name        = { en = 'MDT', mn = 'Цагдаа' },         -- a string, or one string per language
        ui          = 'nui://toxic_police/web/index.html',   -- a file of THIS resource (listed in files{})
        icon        = 'nui://toxic_police/web/icon.svg',     -- optional; svg/png/webp of this resource
        category    = 'police',     -- social|communication|business|government|police|medical|entertainment|utilities|other
        order       = 50,           -- home/store order (default 100)
        version     = '1.0.0',
        developer   = 'Toxic Scripts',
        description = { en = 'Incidents, warrants and BOLOs.', mn = '...' },
        install     = 'store',      -- 'store' (default: player installs it) | 'preinstalled'
        removable   = true,         -- default true
        permissions = { 'location' },  -- any of location, camera, photos, contacts, microphone
        storage     = { quotaKB = 256 },  -- SDK storage per tablet, 16–4096 (default 256)
        sizeMB      = 12.5,         -- shown in the App Store only
        access      = { groups = { police = 0 } },  -- job/gang → minimum grade; checked on the server
    })
end

-- toxic_ipad may start before or after you: register in both cases.
CreateThread(function() if GetResourceState('toxic_ipad') == 'started' then register() end end)
AddEventHandler('onResourceStart', function(r) if r == 'toxic_ipad' then register() end end)
```

Returns `true` or `false, err` (`bad_request`, `app_id_taken`, `limit`). A refused definition prints every problem to the server console, e.g. `RegisterApp.ui: must be "nui://toxic_police/<file>"`. Unknown keys are refused (a typo is reported, not ignored).

Server behaviour:
- The id belongs to the calling resource (`GetInvokingResource()`); another resource cannot take it. Calling again from the same resource updates the app.
- `ui` and `icon` must point at the calling resource; the tablet derives the iframe origin (`https://cfx-nui-<resource>`) from it and accepts SDK messages only from that origin **and** that iframe.
- When your resource stops, its apps and widgets disappear from every tablet at once; open windows show "temporarily unavailable". When it starts again and registers, they come back.
- Registrations may happen before toxic_ipad finished booting (the registry exists at load time). toxic_ipad also fires the local server event `toxic_ipad:server:ready` after boot.
- Up to 64 external apps and 32 external widgets.
- An id stays bound to its first resource until toxic_ipad restarts (another resource cannot take over its stored data).

`exports.toxic_ipad:UnregisterApp(id)` removes your own app.

### Visibility
Per player and per tablet, on the server: `access` must pass **and** the app must be installed on that tablet (store apps: from the App Store; preinstalled apps: unless the player deleted them). The client only ever receives the filtered list.

---

## 3. Inside the app — `toxic-ipad-sdk.js`

### 3.1 Include
```html
<link rel="stylesheet" href="https://cfx-nui-toxic_ipad/ui/sdk/toxic-ipad-sdk.css"> <!-- optional -->
<script src="https://cfx-nui-toxic_ipad/ui/sdk/toxic-ipad-sdk.js"></script>
<script>
  ToxicIPad.connect().then((ipad) => { /* … */ ipad.ready(); });
</script>
```
`connect()` resolves after the handshake (rejects after 10 s — e.g. the page was opened outside the tablet). If a page never connects, the tablet shows "temporarily unavailable" with a Retry button after 10 s.

`ToxicIPad.connect({ units: true })` also sets `<html>` font-size to the OS unit, so `1rem` in your CSS equals `1rem` in the OS at every resolution.

### 3.2 Context — `ipad.context`
```ts
{
  sdk: 1, kind: 'app' | 'widget', appId, route,   // route: deep link or null
  theme: 'light' | 'dark', locale: 'en' | 'mn' | …, textScale, reducedMotion, highContrast,
  layout: 'full' | 'split', size: 'small' | 'medium' | null,   // size: widgets
  unit, safeArea: { top, bottom, left, right },   // px; status bar / home indicator
  tokens: { '--accent': '#0a84ff', '--label-1': …, … }
}
```
The SDK applies it for you: `data-theme`, `lang`, `data-reduced-motion` on `<html>`, and CSS variables `--ipad-accent`, `--ipad-label-1…3`, `--ipad-sys-bg`, `--ipad-sys-grouped`, `--ipad-sys-cell`, `--ipad-fill-2`, `--ipad-separator`, `--ipad-red`…, `--ipad-safe-top`, `--ipad-safe-bottom`, `--ipad-unit`.

### 3.3 API
| Call | Returns | Notes |
|---|---|---|
| `ipad.on('lifecycle', fn)` | | `launch` · `focus` · `blur` · `suspend` · `resume` · `close` |
| `ipad.on('context', fn)` | | theme / language / layout / text size changed |
| `ipad.on('route', fn)` | | deep link while running (`OpenApp`, a notification's `route`) |
| `ipad.ready()` | | first frame drawn: removes the launch splash |
| `ipad.close()` / `ipad.home()` | Promise | leave the app |
| `ipad.setBadge(n)` | Promise | icon badge (display only; 0 clears) |
| `ipad.toast({ text, kind? })` | Promise | short local message (`info` · `success` · `error`); only while visible |
| `ipad.confirm({ title, message?, confirm?, destructive? })` | Promise\<boolean\> | system dialog |
| `ipad.permission(name)` | Promise\<'granted' \| 'denied' \| 'prompt'\> | |
| `ipad.requestPermission(name)` | same | shows the system prompt once; the answer is stored on the tablet |
| `ipad.storage.get(key)` / `.set(key, value)` / `.remove(key)` | Promise | JSON values, per tablet, server-side, quota-checked; keys `[A-Za-z0-9_\-.:]{1,64}`, ≤ 64 KB per value |
| `ipad.context.orientation` | `'landscape'` \| `'portrait'` | also `data-orientation` on `<html>`; `context.layout` is `'split'` in narrow layouts (Split View ⅓/½, Slide Over, portrait) — design a single-column layout for it |
| `ipad.openApp(appId, route?)` | Promise | opens an installed app (not `camera`: only the player opens the Camera) |
| `ipad.photos.pick()` | Promise\<{ id, url, time, location, selfie } \| null\> | system photo picker; declare `permissions = { 'photos' }`; asks once; `null` = cancelled; rejects with `permission_denied` |

Errors reject the promise with a code: `quota`, `too_large`, `not_installed`, `rate_limited`, `busy`, `timeout`…

> `ipad.storage` lives on the player's own tablet and the player controls their own client: treat it like browser storage — drafts, preferences, UI state. Never use it to decide rewards, money or permissions; keep those on your server.

**Notifications cannot be sent from the iframe.** They are server-only: `exports.toxic_ipad:Notify(src, { app = 'police_mdt', title, message, route? })`. A tap on it opens your app with `route`.

**Keys:** Esc and F1–F3 belong to the tablet (Esc = back / home). If your page handles Esc itself (e.g. closes its own dialog), call `event.preventDefault()` and the tablet leaves it alone.

**Errors** in your page (`window.onerror`, unhandled rejections) are printed in F8 as `[toxic_ipad:nui] app <id>: …`. More than 20 in a minute marks the app unavailable for this session (Retry resets it).

### 3.4 Talking to your own Lua
Inside the tablet your page is an iframe of **your** resource, so your own NUI callbacks work — write the resource name out:
```js
const res = await fetch('https://toxic_police/lookupPlate', { method: 'POST', body: JSON.stringify({ plate }) });
```
```lua
RegisterNUICallback('lookupPlate', function(data, cb) cb(lib.callback.await('toxic_police:lookup', false, data.plate)) end)
```
Treat it as any client request: validate and authorise on your server.

### 3.5 Permissions on your server
```lua
if exports.toxic_ipad:HasPermission(source, 'police_mdt', 'location') then … end
```
`true` only when the player's **open** tablet granted the permission. A permission is the tablet holder's consent; it is not a security boundary against the player (they could grant it themselves) — use it to respect choices, not to protect data.

### 3.6 Transport and trust (for reviewers)
- iframe → OS: `window.parent.postMessage({ sdk: 1, id, type, payload }, origin)`; OS → iframe: `{ sdk: 1, type: 'reply' | 'context' | 'lifecycle' | 'route', … }`.
- The OS routes a message only if `event.source` is the iframe it created for that window **and** `event.origin` equals the origin the server derived from `RegisterApp.ui`. Payloads are validated (`web/src/sdk/protocol.ts`); unknown types are dropped.
- Storage and permission requests carry the **window's** app id, never one from the message; the server checks again that the app is installed and accessible for this player.
- Widgets may only use `hello`, `ready`, `storage.get`, `openApp` and `error`.

---

## 4. Lifecycle

| Event | When |
|---|---|
| `launch` | right after `connect()` resolves |
| `focus` / `blur` | the window gains / loses keyboard focus (Split View) |
| `suspend` / `resume` | the window leaves / returns to the screen (home, switcher). The iframe stays alive but should stop timers. |
| `close` | best effort before the iframe is removed |

Windows survive putting the tablet away for up to 5 minutes.

---

## 5. Widgets

```lua
exports.toxic_ipad:RegisterWidget({
    id    = 'police_calls',                            -- unique
    name  = { en = 'Calls', mn = 'Дуудлага' },
    ui    = 'nui://toxic_police/web/widget.html',
    sizes = { 'small' },                               -- 'small' (11×11) and/or 'medium' (23×11 OS units)
    app   = 'police_mdt',                              -- optional: shown only when that app is installed
    access = { groups = { police = 0 } },              -- optional
})
```
A widget is the same kind of page with the SDK (`kind: 'widget'`, `size` in the context). Players add it from the home screen: press and hold → **+**. Built-in widgets: Clock and Battery. Widgets never poll the server: read `ipad.storage` on load, open your app on tap (`ipad.openApp`).

### 5.2 Live widget data — `UpdateWidget`
Push data from **your server** to your widget on open tablets:
```lua
exports.toxic_ipad:UpdateWidget(src, 'police_calls', { open = 4, last = 'Alta St' })   -- ≤ 8 KB JSON
-- target: player source | { serial = 'TXP-…' } | { identifier = '<citizenid>' } (open tablets only)
```
```js
const show = (d) => { if (d) el.textContent = d.open; };
show(ipad.data);           // latest value, if one was pushed before the widget loaded
ipad.on('data', show);     // every UpdateWidget
```
Only the resource that registered the widget can update it. No database access — safe to call often (e.g. on your own events, not every frame). The last value stays with the **tablet** while the server keeps it in memory and is replayed when it opens — to whoever holds it, so don't push one player's private data to a tablet others may pick up. It is dropped when your resource restarts.

---

## 6. Deep links

`exports.toxic_ipad:OpenApp(src, 'police_mdt', '/incidents/42')` launches or focuses the app and delivers the route (`context.route` at launch, `route` event later). A closed tablet is opened first and the app starts after unlock. Built-in routes: `settings:/battery`, `/privacy`, `/storage`, `/homescreen`…; `notes:/note/<id>`; `appstore:/app/<id>`.

---

### Client exports (the player's own tablet)
```lua
exports.toxic_ipad:IsOpen()                      -- boolean
exports.toxic_ipad:Close()                       -- closes it if open
exports.toxic_ipad:OpenApp('police_mdt', '/incidents/42')  -- goes through the server's OpenApp rules
```

### Photos from your server
```lua
local photos = exports.toxic_ipad:GetPhotos(src, 10)   -- newest first, 1–50
-- { { id, url, selfie, location, time, serial }, … }  (call from a thread / event handler)
```
For evidence lockers, MDT attachments, social apps. `target` like `Notify`.

## 7. Files from your resource

```lua
exports.toxic_ipad:SaveFile(src, {
    folder = 'Downloads',             -- or 'Documents'
    name = 'Report 0421.pdf',
    mime = 'application/pdf',
    sizeBytes = 245000,               -- virtual size, counts toward the tablet's storage
    ref = 'app:police_mdt:/reports/421',  -- opening the file opens your app at that route
})
```
Files are virtual entries (name, size, reference) — never binary data. `target` works like `Notify` (player source, `{ serial = }` or `{ identifier = }`).

---

## 8. Versioning
`exports.toxic_ipad:SdkVersion()` → `1`. The SDK script and the exports keep backward compatibility within v1; breaking changes bump the version with one deprecation release in between.

---

## 9. Checklist for app authors
- [ ] `ui`, `icon` and every page file listed in your `fxmanifest.lua` `files {}`.
- [ ] Register on your start **and** on `onResourceStart('toxic_ipad')`.
- [ ] `ipad.ready()` after your first render.
- [ ] Texts for `ipad.context.locale` (at least `en`).
- [ ] Stop timers on `suspend`.
- [ ] Everything your NUI callbacks do is validated on your server.
