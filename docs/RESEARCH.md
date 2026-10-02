# TOXIC iPAD — PHASE 1 RESEARCH & FEASIBILITY

Status: **Phase 1 (research + architecture) — awaiting approval.** No production code exists yet.
Date: 2026-09-27. Scope: the MVP defined in the master prompt §78A, designed so that it grows into the full product (§0–§92) without a rewrite.

This file answers the master prompt §78: *what can be reproduced exactly, what must be simulated, what cannot be reproduced, and what needs an approximation* — and records the platform facts every other document depends on.

---

## 1. Verified platform facts

Each fact below was checked against source or the upstream tracker on the date above. Anything not verified is marked **ASSUMPTION** and has a verification step in §6.

| # | Fact | Source | Consequence for toxic_ipad |
|---|---|---|---|
| F1 | FiveM NUI runs **CEF / Chromium M103**. An M140 upgrade exists on a private branch, blocked on an AMD VRAM leak (Sept–Oct 2025). No public release found as of this date. | [citizenfx/fivem #3651](https://github.com/citizenfx/fivem/discussions/3651), [rfc #55](https://github.com/citizenfx/rfc/discussions/55) | Build target is **`chrome103`**. Not available: container queries (105), `:has()` (105), `dvh/svh` (108), CSS nesting (112), `color-mix()` (111), View Transitions (111). Tailwind v4 needs 111+ → not usable ([#3312](https://github.com/citizenfx/fivem/issues/3312)). |
| F2 | `backdrop-filter: blur()` **flickers** in-game on M103; open and untriaged (Feb 2026). | [citizenfx/fivem #3843](https://github.com/citizenfx/fivem/issues/3843) | "Glass" surfaces must **not** depend on `backdrop-filter`. See UI_SYSTEM §4 (pre-blurred wallpaper layer). |
| F3 | CSS inside the NUI page cannot see or blur the **game frame**. The NUI is composited over the game; `backdrop-filter` only samples NUI pixels. | CEF compositing model (F2 thread confirms blur only applies to NUI content) | The "blurred world behind the tablet" (§8) must be done with a **game-side** effect: a screen-blur or timecycle native. |
| F4 | ox_inventory **2.47.9**: an item with `server = { export = 'res.fn' }` calls `exports.res:fn(event, item, inventory, slot)` with `event = 'usingItem'` (return `false` cancels) then `'usedItem'`. | `ox_inventory/modules/items/shared.lua:49-50`, `server.lua:486-575` (commit 2026-08-27) | Tablet use is a **server** export → server validates before the client is told anything (§78A.13 flow). |
| F5 | Declaring `server.export` without `consume` makes ox_inventory set **`consume = 1`** (the tablet would be eaten on use). | `modules/items/shared.lua:32-33` | The item definition **must** contain `consume = 0`. Documented in INSTALLATION and checked at boot (warning). |
| F6 | The `createItem` hook receives `{ inventoryId, metadata, item, count, resource }`; returning a table **replaces the metadata**. | `modules/items/server.lua:224-234` | A serial number can be stamped the moment any tablet is created (shop, admin give, crafting) with no DB work in the hook. |
| F7 | `SetNuiFocus(hasFocus, hasCursor)` is per resource; an `<iframe>` inside the focused page receives input. NUI callbacks are routed by host: `fetch('https://<resource>/<cb>')` reaches `<resource>`'s `RegisterNUICallback`. | FiveM NUI docs; used by existing phone resources (LB Phone custom apps load `ui = "resource/ui/index.html"`, [docs](https://docs.lbscripts.com/phone/custom-apps/)) | Third-party apps can ship their UI inside **their own resource** and run in an iframe inside the tablet, talking to their own Lua. This is the basis of the App SDK. |
| F8 | FXServer provides `GetPasswordHash` / `VerifyPasswordHash` (bcrypt). | FiveM server natives | Passcodes are stored as bcrypt hashes; the plain PIN never touches the DB. |
| F9 | toxic_core is at **Phase 3.3** (identity, sessions, lifecycle). The public API in spec §6 (`Toxic.Session.getCharacterId`, `Toxic.Items.registerUsable`, `toxic_core:characterLoaded`…) is **designed but not exported yet**. | `Toxic Framework/toxic_core` (commit 26fe571), `docs/03-architecture-spec-v1.md` §6 | The toxic_core bridge is written against the spec and **activates only when** toxic_core reports `apiVersion() == 1`. MVP live testing runs on **Qbox** (decision D3). |
| F10 | qbx_core 1.24: `GetPlayer(src).PlayerData.citizenid`, `HasGroup(src, filter)`, events `QBCore:Server:PlayerLoaded` / `QBCore:Server:OnPlayerUnload`. | fivem-qbox-developer skill reference (extracted from installed qbx_core 1.24.0) | Qbox bridge surface is small: identifier, name, groups, loaded/unloaded. |

---

## 2. Feasibility matrix

Legend: **E** = reproducible exactly · **S** = simulated (gameplay model, no real hardware) · **A** = approximation (looks/feels the same, different mechanism) · **X** = not possible in FiveM, replaced or dropped.

### 2.1 Device and presentation
| Feature | Class | How |
|---|---|---|
| Floating device at ~80 % with correct aspect ratio | **E** | CSS math on the NUI root (UI_SYSTEM §2). Constraining axis = 80 %; the other follows the 4:3 ratio. |
| Game world visible and dimmed around the tablet | **E** | A transparent NUI root with a 15 % black scrim. |
| Game world **blurred** behind the tablet | **A** | Native screen blur / timecycle (F3). Strength is coarse (not "3 px"). Config: `none | native | timecycle`. |
| Metallic frame, glass, reflections, edge light | **E** | Layered CSS gradients + SVG (no Apple assets). |
| "Glass" translucency on panels (Control Center, dock) | **A** | Pre-blurred copy of the wallpaper clipped behind each panel (F2). Looks identical on static wallpapers; slightly stale over moving app content. |
| Open/close with spring motion (0.90→1.00, blur→clear) | **E** | `transform`/`opacity`/`filter` on the device node only. |
| Tablet prop in hand + animation | **E** | Networked object attached to a ped bone + anim dict (config). |
| Portrait orientation / rotation | **E** (Phase 2) | MVP is landscape only. |

### 2.2 Operating system
| Feature | Class | How |
|---|---|---|
| Lock screen, time/date, notifications preview | **E** | |
| Swipe to unlock | **A** | Pointer-drag on the home indicator; keyboard: `Enter`/`Space`. |
| PIN / passcode | **E** | Server-verified bcrypt (F8), lockout after N failures. |
| Face ID | **S** | Scan animation; succeeds **only if the server says the holder is the device owner**. No camera, no biometrics. |
| Home screen, pages, dock, folders, App Library | **E** | |
| Widgets (clock, battery) | **E** | Event-driven; no polling (PERFORMANCE §3). |
| Control Center / Notification Center | **E** | Top-edge pull gestures + click targets. |
| Multi-touch gestures, pinch | **X → A** | FiveM gives one pointer. Pinch → Ctrl+wheel. Edge swipes → drag from edge zones. Three-finger gestures dropped. |
| Keyboard | **E** | CEF gets real keyboard input when focused. On-screen keyboard is out of MVP scope. |
| Split View 50/50 | **E** | Inside the tablet viewport only. |
| Slide Over, Stage Manager, free resizing | **E** (Phase 2/5) | Window model already carries `x/y/w/h` so no redesign later. |
| Battery drain/charge | **S** | Lazy server calculation from timestamps — zero ticks (PERFORMANCE §4). |
| Storage capacity | **S** | Accounting of bytes used by notes/files/app data vs a capacity number. |
| Brightness | **A** | CSS `filter: brightness()` on the display node (does not change game brightness). |
| Volume | **E** | Scales every system sound played by the NUI. |
| Dark / light / automatic | **E** | "Automatic" follows the **in-game** clock (config) or real time. |
| Sleep / wake | **E** | Display off, NUI timers paused, focus kept or released (config). |

### 2.3 Apps (MVP)
| App | Class | Note |
|---|---|---|
| Settings, Notes, Calculator, Clock (+stopwatch), Files (virtual), App Store (static catalog) | **E** | All server-persisted where the spec requires it. |
| Camera, Photos, Maps, Messages, Browser… | — | **Out of MVP scope** (§78A.19). The SDK already supports them as iframe apps. |
| Real external web browsing | **X by policy** | §45: internal routes only; never an open URL bar to the internet. |

### 2.4 Things explicitly impossible or refused
- Emulating an Apple M5 or running iPadOS code → the "M5-class" label is **fiction text** in config (§2).
- Apple system fonts, SF Symbols, wallpapers, icons, sounds → **not used**. Inter (OFL) or a similar open font, and original icons/sounds.
- Access to the player's real filesystem → impossible in NUI and refused by §36; the Files app is a server-side virtual tree.
- Real biometrics/camera of the player's PC → not available and not wanted.

---

## 3. Research on the reference interaction model (observable behaviour only)

Studied from public behaviour of modern tablets; nothing extracted from any OS. What the MVP reproduces:

| Pattern | Observable behaviour | Toxic implementation |
|---|---|---|
| Launch zoom | App window grows from the icon's rect; wallpaper recedes slightly | Window node animates from the icon's `DOMRect` (FLIP), wallpaper `scale(1.03)` |
| Home gesture | Drag the bottom indicator up: app shrinks and follows the pointer; release above a threshold → home | Pointer-drag with velocity threshold; the same transition used by `Esc` |
| App switcher | Drag up and pause → cards of recent apps; swipe a card up to close | Recent list from the Window Manager; card = live-scaled window (built-in apps) or snapshot tile (iframe apps) |
| Split View | Two apps side by side, draggable divider snapping to 50/50 (MVP locks at 50/50) | `split` layout in the Window Manager |
| Control Center | Pull from the top-right; tiles grouped in modules | Top-right edge zone + status-bar click |
| Notification Center | Pull from the top-left/centre; grouped by app | Top-left edge zone |
| Lock screen | Clock large, notifications stacked below, unlock by swipe | As observed |
| Springs | Critically damped motion, ~350–500 ms, no bounce on system chrome | One spring preset table (UI_SYSTEM §5) |

---

## 4. Integration research summary

| System | Finding | Use in MVP |
|---|---|---|
| ox_inventory | F4–F6. Item must be `stack = false`, `consume = 0`, `close = true`. Serial in metadata via `createItem` hook. | Item is the device (ARCHITECTURE §5). All calls through `bridge/inventory/ox_inventory.lua`. |
| ox_lib | `lib.callback`, `lib.addKeybind`, `cache`, `locale`, `lib.requestAnimDict`, `lib.requestModel`, `lib.print` | Used directly; nothing re-implemented. |
| ox_target | Only needed for world objects (charging stations, kiosks) | **Not an MVP dependency.** Optional, Phase 2. |
| oxmysql | `MySQL.*.await`, parameterised, transactions | All SQL in `server/storage/*.lua`. |
| qbx_core | F10 | `bridge/framework/qbox.lua` — MVP live target. |
| toxic_core | F9 | `bridge/framework/toxic_core.lua` — written against spec §6, enabled when the API exists. |
| qb-core / ESX | Optional in MVP (§78A.14) | Bridge **interface** defined now; adapters in Phase 8 unless the owner asks earlier. |
| Phones (lb-phone, …) | Out of MVP | `bridge/phone/` folder reserved; nothing loaded. |

---

## 5. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| CEF M103 limits (F1) | Modern CSS unusable | Vite target `chrome103`, plain CSS modules + tokens, PostCSS only for autoprefix. Retest if FiveM ships M140. |
| backdrop-filter flicker (F2) | Glass looks broken | Never use it for chrome surfaces; wallpaper-copy technique. A config flag can enable real `backdrop-filter` for servers on a newer client. |
| Iframe apps cost memory | 20 live iframes ≈ 20 documents | Max live iframes (default 4); least-recent background app is **terminated** (state saved) — same as a real tablet. |
| toxic_core API changes before release | Bridge breaks | Bridge checks `apiVersion()`; one file to update. |
| React bundle size | Slow first open | Lazy-load each built-in app; target < 350 KB gzip for the shell. |
| Buyer cannot edit a built UI | Support load | Ship `web/dist` built; theme via CSS variables in `config/theme.lua` pushed at runtime so colours need no rebuild. |

---

## 6. Assumptions to verify in-game (first task of Phase 2)

1. **ASSUMPTION** `TriggerScreenblurFadeIn(ms)` / `TriggerScreenblurFadeOut(ms)` give an acceptable world blur while NUI is focused; else fall back to `SetTimecycleModifier('hud_def_blur')` + `SetTimecycleModifierStrength`.
2. **ASSUMPTION** Default prop `prop_cs_tablet` with anim `amb@code_human_in_bus_passenger_idles@female@tablet@base` / `base` on bone `60309` looks right (all in config).
3. **ASSUMPTION** An iframe at `https://cfx-nui-<resource>/...` inside toxic_ipad's page can `fetch('https://<resource>/cb')` its own NUI callbacks while toxic_ipad holds focus (behaviour used by existing phones; verify on build 10731+).
4. **ASSUMPTION** `window.parent.postMessage` between the tablet page and a `cfx-nui-*` iframe exposes a stable `event.origin` of `https://cfx-nui-<resource>` (used to authenticate SDK messages to the right app).
5. Font rendering of Inter `woff2` and SVG icons in CEF M103.
