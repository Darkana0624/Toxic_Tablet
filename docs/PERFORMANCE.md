# TOXIC iPAD — PERFORMANCE MODEL

Targets (§72): closed ≈ **0.00 ms**, open idle **0.01–0.03 ms** client resmon, active simple app "minimal". NUI is judged separately (frame time, memory) because CEF work does not show in resmon.

---

## 1. Client Lua

| State | Threads | Work |
|---|---|---|
| Closed | **none** | only the keybind handler and event listeners (no ticks) |
| Opening/closing | one short-lived thread (anim/prop load, ≤ 1 s) | `lib.requestAnimDict/Model`, attach prop |
| Open, default (`allowMovement = false`) | **none** | NUI focus without keep-input → the game gets no input, so no `DisableControlAction` loop is needed |
| Open, `allowMovement = true` (config) | one `Wait(0)` loop disabling look/attack controls | documented cost ≈ 0.02–0.04 ms, off by default |
| Game clock mode | none | clock is sent on open; the NUI advances it locally at the configured ms-per-game-minute; re-synced on `clock` events only when the server time changes (weather/time scripts) |

Death/cuff checks use bridge events (state bag / framework events), not polling.

## 2. Server Lua

- No per-player loops, no timers per device. Debounced flushes use one `SetTimeout` per dirty device, cancelled/merged on new writes.
- `playerDropped` / close → flush that device only.
- Rate buckets are lazily refilled on access (no ticking).
- Registry pushes are debounced (250 ms) and targeted to open sessions only.

## 3. Network

- Open = **one** client event with the boot payload (compressed shape: arrays of ids, no repeated labels; locale table only when its hash changed).
- Notifications push only to open sessions; closed devices just get a DB row.
- Large lists (notes, notifications) use `TriggerLatentClientEvent` above 16 KB.

## 4. Battery without ticks

```
level(now) = clamp(level_stamp − drain(openSeconds, closedSeconds, flags) + charge(chargingSeconds))
```
Stored: `battery_bp` + `battery_stamp`. Recomputed only on open, on close, and when a setting that changes the rate toggles (Low Power, brightness). The NUI animates the estimate locally between events; the server value is authoritative on each event. Hitting 0 % schedules **one** timeout for that open session (shutdown) — cancelled on close.

## 5. NUI

| Rule | Why |
|---|---|
| Closed = `display:none` on the device **and** every `rAF`/interval stopped (motion engine and clock stop themselves) | hidden pages still run timers |
| One minute tick for clocks, aligned to the minute boundary; stopwatch `rAF` only while visible and running | no 1 s intervals |
| Zustand selectors | a battery change re-renders one glyph |
| Lazy app chunks | shell < 350 KB gzip target |
| Virtualised lists above 100 rows (notes, notifications, files) | §78A.20 "large lists do not freeze" |
| Search debounced 150 ms, done on cached data in the NUI | no server round-trip per keystroke |
| Animate only `transform`/`opacity` (+ `filter` on the device during open) | compositor-only |
| No `backdrop-filter` (RESEARCH F2) | also a GPU saving |
| Background iframes `visibility:hidden` + `suspend`; LRU terminate above `maxLiveFrames` | memory ceiling |
| Wallpaper blur rendered once per wallpaper change | no per-frame blur |
| Images: `webp`, wallpapers ≤ 2560 px, lazy `decoding="async"` | 4K screens still ≤ 2.5 MB per wallpaper |

## 6. Measurement plan (Phase 10)

| Scenario | Metric | Pass |
|---|---|---|
| Closed, 30 min | resmon client/server | 0.00 ms |
| Open idle on home | resmon client | ≤ 0.03 ms |
| Notes with 500 notes, typing | NUI frame time (devtools) | < 16 ms p95 |
| 4 iframe apps + split | NUI memory | < 250 MB |
| 200 open/close cycles | leaks (entities, focus, JS heap) | none; heap returns to baseline ±10 % |
| 32/64/128 simulated players opening at once | server tick, DB q/s | no hitch > 5 ms; ≤ 4 queries per cold open, 0 warm |
