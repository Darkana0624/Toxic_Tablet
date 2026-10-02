# TOXIC iPAD — UI SYSTEM

Covers: NUI stack, the 80 % floating device, scaling, visual language, motion engine, input/gestures, focus, states, accessibility. Target runtime: **Chromium M103** (RESEARCH F1).

---

## 1. Stack

| Concern | Choice | Why |
|---|---|---|
| Framework | **React 18 + TypeScript** | The OS is an application with shared state across many surfaces (the skill's rule for when a framework earns its place). |
| Build | **Vite**, `build.target = 'chrome103'`, `base: './'`, output → `dist/` (committed) | Relative asset paths for `https://cfx-nui-toxic_ipad/`; buyers never need Node. |
| State | **Zustand**, one store per domain (§7) | Tiny, selector-based subscriptions → a battery tick re-renders the battery glyph only. |
| Styling | **CSS Modules + CSS custom properties** (tokens) | Tailwind v4 cannot run on M103; tokens are overridable at runtime from `config/theme.lua`. |
| Motion | **own spring engine** (`web/src/motion`, ~2 KB) driving `transform`/`opacity` | Spec §62 asks for a reusable engine with reduced-motion; avoids a 40 KB+ animation dependency. |
| Icons | Original SVG set in `web/src/assets/icons` | No Apple assets. |
| Font | **Inter** (OFL) `woff2`, 3 weights | Open licence, close optical feel. |
| Tests | Vitest (stores, window manager, validators) + Playwright (preview with mock bridge) | |

Code splitting: each built-in app is a lazy chunk (`dist/assets/*.js` listed by glob in `files{}`). The shell loads first; Notes/Calculator/etc. load on first launch.

---

## 2. The 80 % floating device

### 2.1 Geometry
The NUI root is `position: fixed; inset: 0` (input capture only, transparent). The device is a centred node whose size is computed, never `100vw/100vh` (§75).

```css
:root {
  --size: 0.80;                 /* from config.display.size, clamped 0.75–0.90 */
  --ratio: 1.3333;              /* model aspect incl. bezel (landscape 4:3) */
  --dev-h: min(calc(var(--size) * 100vh), calc(var(--size) * 100vw / var(--ratio)));
  --dev-w: calc(var(--dev-h) * var(--ratio));
}
.device { width: var(--dev-w); height: var(--dev-h); }
```
The constraining axis is exactly `size`; the other follows the ratio. Results:

| Screen | Device (landscape 4:3) | Covers |
|---|---|---|
| 1920×1080 | 1152×864 | 80 % height, 60 % width |
| 2560×1440 | 1536×1152 | 80 % height, 60 % width |
| 3440×1440 | 1536×1152 | 80 % height, 45 % width |
| 3840×2160 | 2304×1728 | 80 % height, 60 % width |
| 1280×1024 (5:4) | 1024×768 | 80 % width, 75 % height |

A `min-height: 480px` floor stops it becoming unusable on tiny windows; there is no max beyond the formula (it never reaches the edges because `size ≤ 0.90`).

### 2.2 Resolution-independent interior
All interior UI is laid out in **device points** on a logical 1366×1024 canvas. The root sets
`font-size: calc(var(--dev-h) / 1024 * 16)` on the display, and every size is in `rem` (1 rem = 16 logical points). Text stays sharp (no `transform: scale()` of the whole OS) and the layout is identical at 1080p and 4K. Iframe apps get the same unit through the SDK (APP_SDK §3.4).

### 2.3 Physical frame (layers, back to front)
1. **Shadow**: two stacked `box-shadow`s (ambient + key) on a static pseudo-element (never animated).
2. **Chassis**: aluminium frame — linear gradients with a thin specular edge; corner radius `calc(var(--dev-h) * 0.045)`.
3. **Buttons**: power (top-right), volume up/down (right edge) — real buttons: power = sleep/wake, volume = system volume HUD.
4. **Bezel** (black, ~2.4 % of height) with the front camera dot on the long edge.
5. **Display** (clipped, inner radius) → wallpaper, system UI, windows.
6. **Glass**: a single overlay with a very low-opacity diagonal reflection, `pointer-events: none`.

### 2.4 World around the tablet
- Scrim: `rgba(0,0,0,var(--overlay-opacity))` on the root, fades with the device.
- World blur: game-side (RESEARCH F3), controlled by the client `world.lua` (`none | native | timecycle`).

---

## 3. Visual language

Original "Toxic iPadOS" design, inspired by the observable hierarchy of modern tablets — not a copy of any asset.

- **Surfaces** (light / dark): `--sys-bg`, `--sys-grouped`, `--sys-fill-1..3`, `--sys-label-1..4`, `--sys-separator`, `--sys-tint` (accent; default a calm blue, overridable per server; Toxic green available as a theme).
- **Materials**: `thin | regular | thick` = tint + opacity values applied over the pre-blurred wallpaper (§4).
- **Type scale** (logical pt): large title 34, title 28/22/20, headline 17 semibold, body 17, callout 16, subheadline 15, footnote 13, caption 12. Minimum 12 pt logical, which is ≥ 13 px physical at 1080p.
- **Radii**: icon 22 % of icon size (squircle via SVG mask), widget 22 pt, window 18 pt, sheet 14 pt, control 10 pt.
- **Icons**: home icons 64 pt at default density, 6×4 grid + dock; label 12 pt.
- **Spacing**: 4 pt base grid.
Everything is a token on `:root`; `config/theme.lua` can override tokens at runtime.

---

## 4. Glass without `backdrop-filter`

Because of the M103 flicker (F2):
- On wallpaper change the NUI renders **one** blurred copy of the wallpaper (canvas `filter = 'blur(40px) saturate(1.6)'`, done once, cached as an object URL).
- Every glass panel (dock, Control Center, notification, widget) paints that blurred image as its background with `background-attachment` equivalent: `background-size: var(--disp-w) var(--disp-h); background-position: calc(-1 * panelX) calc(-1 * panelY)` — so it lines up with the wallpaper behind it — plus a material tint.
- Over an open app (e.g. Control Center above Notes) the material uses the tint only, at higher opacity. Visually the same; no live blur.
- `config.display.nativeBackdrop = true` switches to real `backdrop-filter` for servers whose clients run a fixed CEF.

---

## 5. Motion engine

`web/src/motion`: a critically damped / under-damped spring integrator on `requestAnimationFrame` that runs **only while something is animating** and stops itself.

| Preset | Stiffness / damping | Used for |
|---|---|---|
| `device` | 260 / 30 | open/close (scale .90→1, opacity, blur 8→0 px) ≈ 450 ms |
| `launch` | 300 / 32 | icon → window zoom (FLIP) |
| `snappy` | 420 / 36 | CC / NC sheets, switcher cards |
| `gentle` | 180 / 26 | widgets, wallpaper parallax |

Rules: animate only `transform`, `opacity`, and `filter` on the device node during open/close. Durations cap at 500 ms. **Reduced Motion** (setting + `prefers-reduced-motion`) replaces springs with 120 ms cross-fades. Low Power Mode also switches to reduced motion.

---

## 6. Input and gestures

One pointer (mouse), keyboard, and optional controller.

| Gesture | Pointer | Keyboard |
|---|---|---|
| Unlock | drag home indicator up (> 18 % height or velocity) | Enter / Space |
| Go home | drag home indicator up from an app | Esc (in app) |
| App switcher | drag up and hold 250 ms | Alt+Tab / F3 |
| Control Center | drag down from top-right edge zone, or click status icons | F2 |
| Notification Center | drag down from top-left/centre edge zone | F1 |
| Close tablet | Esc on home screen, power button | Esc / configurable keybind |
| Long press (edit home, context) | 450 ms hold | Shift+F10 / context key |
| Page swipe (home) | horizontal drag | ← → |
| Pinch (where apps want it) | Ctrl + wheel | Ctrl + / − |

A single gesture recogniser (`web/src/system/gestures.ts`) with edge zones, velocity tracking and cancellation. Controller navigation: arrow-key focus model is implemented (keyboard nav); gamepad mapping is Phase 2.

---

## 7. State architecture (§59)

| Store | Holds | Written by |
|---|---|---|
| `device` | serial, model, battery, charging, storage, lock state, power state, owner flag | server messages only |
| `system` | theme, wallpaper, brightness, volume, focus/DND, reduced motion, locale, CC/NC open | settings replies, user actions (then persisted) |
| `window` | windows, z-order, layout (single/split), recents | Window Manager only |
| `app` | registry (visible apps), installed set, badges, per-app runtime status | server messages |
| `user` | notifications list, unread counts | server messages + local read-state |
| `network` | pending requests, last error, `disconnected` flag | bridge layer |

No component calls `fetch` directly; everything goes through `web/src/bridge` (`request(name, payload)` with timeout, retry-once for reads, never for writes).

---

## 8. Focus (the rule that cannot fail)

Lua owns focus. The NUI only sends `close`. `closeDevice()` is the single path that releases `SetNuiFocus(false,false)`; it is also run from `onResourceStop`, player death (bridge), and if the NUI reports a fatal error. A watchdog: if the NUI fails to answer the `open` handshake within 3 s, the client releases focus and logs.

---

## 9. States every surface implements

loading · empty · error (with retry) · disabled · permission denied · disconnected · confirmation (destructive actions: delete note, uninstall app, erase). App crash → the app's window shows the localized "This application is temporarily unavailable" with **Close** and **Restart** (§68).

---

## 10. Accessibility (§64, MVP subset)

Text size (3 steps, scales `rem`), Reduced Motion, High Contrast (token set), sound toggle, full keyboard navigation with visible `:focus-visible` rings, `aria-label` on icon-only buttons, semantic elements. Controller navigation is Phase 2.
