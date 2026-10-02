# TOXIC iPAD — WINDOW MANAGER

The Window Manager (WM) owns every app surface inside the tablet display. It never renders outside the display node, so "fullscreen" always means "fills the tablet display" (§76).

MVP scope (§78A.5–6): open, close, minimize, restore, focus, blur, switch, recents, **Split View 50/50**. Not in MVP: free resizing, Slide Over, Stage Manager, three apps. The data model already has geometry so those arrive without a redesign.

---

## 1. Data model

```ts
type WindowState = 'active' | 'background' | 'minimized' | 'closed';

interface AppWindow {
  id: string;            // 'w_<n>' monotonic
  appId: string;
  state: WindowState;
  zIndex: number;
  // geometry in logical points (UI_SYSTEM §2.2); MVP derives it from the layout
  x: number; y: number; w: number; h: number;
  mode: 'full' | 'split-left' | 'split-right';   // Phase 2+: 'slideover' | 'floating'
  route: string | null;
  openedAt: number; lastActiveAt: number;
  live: boolean;         // DOM/iframe present (false after termination)
  crashed: boolean;
}

interface WMState {
  windows: Record<string, AppWindow>;
  layout: { kind: 'home' } | { kind: 'single'; win: string } | { kind: 'split'; left: string; right: string };
  recents: string[];     // window ids, most recent first, max config.multitasking.recents
  focused: string | null;
}
```
One instance per app (MVP): launching an app that already has a window focuses it.

---

## 2. Operations (pure reducer, unit-tested)

| Operation | Effect |
|---|---|
| `launch(appId, route?)` | existing window → `focus`; else create, `mode: full`, layout `single`, push to recents; enforce live-frame budget (§4) |
| `focus(id)` | previous focused → `background` (+ `blur`); target → `active` (+ `focus`/`resume`) |
| `minimize(id)` | → `minimized`, layout → `home` (the "go home" gesture) |
| `restore(id)` | from switcher/dock → `focus` |
| `close(id)` | → `closed`, removed from recents, iframe/component destroyed |
| `split(leftId, rightId)` | layout `split`; both `active` for rendering, one has input focus |
| `unsplit(keepId)` | other → `background` |
| `switchTo(id)` | from the switcher; keeps a split pair together if `id` is in it |
| `terminate(id)` | OS-initiated: `live=false`, keeps the card in recents (relaunch on restore) |
| `crash(id, error)` | `crashed=true`, shows the unavailable screen (APP_SDK §4) |

Every transition emits exactly one lifecycle event to the app host. Illegal transitions (e.g. `focus` on a closed window) are no-ops with a debug log — never a throw.

---

## 3. Layouts

```
single                          split (50 / 50, MVP locked)
┌────────────────────────┐     ┌───────────┬────────────┐
│ status bar (overlaid)  │     │  Notes    ┃ Calculator │
│                        │     │           ┃            │
│        app             │     │           ┃            │
│                        │     │           ┃            │
│      ─── home ───      │     │    ───────┃───────     │
└────────────────────────┘     └───────────┴────────────┘
```
- Split is entered by: dragging an app from the dock onto the left/right third of a running app, or the window's "⋯" multitasking menu → Split View → pick from the home grid (both give the same result, the menu is the discoverable path for mouse users).
- The divider is visible and draggable **only to exit** (drag to an edge closes that side). Arbitrary ratios are Phase 2 (`w` already stored).
- The home indicator in split mode goes home with both apps minimized as a pair.

---

## 4. Resource budget

- `maxLiveFrames` (default 4) counts live iframe windows. Launching a 5th terminates the least-recently-active **background** iframe window (`suspend` → 1 s grace → remove). Built-in apps count 0.25 each (cheap) but the same LRU rule applies above 8 live windows.
- Background iframes receive `suspend` and are set `visibility: hidden` (no painting). Built-in apps receive `active=false` through `useAppActive()`; timers/animations inside apps must key off it (lint helper + review checklist).
- Sleep / tablet closed: all apps get `suspend`. The tablet closing **does not** destroy windows by default: reopening within `resumeWindowSeconds` (default 300) restores the previous layout — like picking the tablet back up. After that, windows are closed and recents persist in settings.

---

## 5. App switcher

Cards laid out horizontally, most recent first. A card shows: built-in → the live component scaled 0.6 inside a clipped container (cheap, no screenshots); iframe → the live iframe scaled the same way if live, else the app icon on its background colour (FiveM gives no way to screenshot an iframe). Swipe a card up to `close`, click to `switchTo`, split pairs show as one double card.

---

## 6. Launch/close animation

FLIP from the icon's `DOMRect` to the window rect with the `launch` spring (UI_SYSTEM §5); the wallpaper and home grid scale to 1.03 and fade. Close reverses into the icon if it is visible, otherwise shrinks to the home indicator.

---

## 7. Persistence

Persisted in the device settings document: recents (app ids only, not window ids), last layout (if within `resumeWindowSeconds`), dock order, home grid pages and folders (§78A.10 "App Layout / Dock Layout"). Window geometry is not persisted in MVP.

---

## 8. Phase 2 · M6 (0.7.0): Split ratios, Slide Over, portrait

**Split ratios.** `Layout.split.ratio` is the left side's share: ⅓ · ½ · ⅔ (`SPLIT_RATIOS`). Drag the divider; on release it snaps to the nearest ratio (`snapRatio`). Dragging within 14 % of an edge closes that side (the other app goes full screen). The last ratio of each app pair (`"leftApp|rightApp"`) is remembered for the session (`WMState.ratios`). While dragging only the divider moves; the apps re-lay out once, on release. Portrait is always ½ (a ⅓ side would be 16 rem wide); a portrait drag can only close a side and never overwrites the landscape ratio.

**Slide Over.** `WMState.slide = { win, hidden, focused } | null` — one window floating on the right (26 rem, or 46 % of the display), above the layout. Window menu › Slide Over (needs an app to stay underneath: the other Split View side or the most recent app). The grabber swipes it away (`hidden`, suspended); the edge tab brings it back. It floats over apps only: on the home screen and while picking a Split View partner it is hidden. A click (or an SDK app's click, forwarded by `toxic-ipad-sdk.js`) moves the focus between Slide Over and the app underneath; Esc with Slide Over focused hides it. Full Screen from its menu, launching it from the home screen, the app switcher, or picking it as a Split View partner takes it out of Slide Over. `onScreen()` / `focusOf()` include it; `enforceLimit` never closes it.

**Portrait.** `settings.display.orientation` (`landscape` | `portrait`) and `orientationLock`, validated by the server (`shared/settings.lua`); `config/shared.lua` `display.portrait = false` disables it. Control Center: **Portrait/Landscape** (rotate) and **Rotation Lock**. `computeGeometry(..., portrait)` turns the device: the display stays 64 rem tall (same text size) and becomes ~48 rem wide. `html.portrait` switches CSS: home grid 4 × 6 (4 × 4 under the widget rows — the same 24/16 capacity, so the saved layout is shared by both orientations), built-in apps use their compact layouts. The device rotates 90° into place (spring). SDK `context.orientation` + `data-orientation` on `<html>`.

