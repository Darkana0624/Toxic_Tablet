# Milestone 2 — in-game test checklist (0.2.0)

Covers MVP §78A.21 steps 1–22 except Files and the App Store (milestone 3).
No database action needed: the tables already exist from 0.1.0.

## Demo scenario (MVP §78A.21)
1. Use the tablet → unlock (Enter / swipe; passcode if set).
2. Home screen shows Settings, Notes, Calculator, Clock and the dock.
3. Open **Notes** → pencil icon → type `Meeting tomorrow at 20:00.` (saves automatically).
4. **Esc** (or drag the bottom bar up) → home. Open **Calculator** → `2500 × 4 =` → `10000`.
5. From the server console / an admin: `/ipadnotify <id> You received $5,000` → a banner appears.
6. **F1** (or click the clock at top-left) → Notification Center. Esc closes it.
7. **F3** (or drag the bottom bar up and hold) → switcher → click Notes.
8. In Notes, click **⋯** at the top → **Split View** → click Calculator → both side by side.
9. **F2** (or click the battery at top-right) → Control Center → Dark Mode on/off — the whole UI changes at once.
10. Put the tablet away, reconnect, open it again → the note is still there, the theme is kept.

## Also check
| Area | Check |
|---|---|
| Settings › Face ID & Passcode | Owner can turn the passcode on/off and change it; a second player sees "only the owner" |
| Settings › Wallpaper | Four wallpapers, choice kept after reconnect |
| Settings › Notifications | Turning an app off stops its banners (still listed in the center) |
| Do Not Disturb | No banners while on (critical priority still shows) |
| Crash isolation | (dev) an app error shows "This application is temporarily unavailable" + Restart; F8 prints `[toxic_ipad:nui]` |
| Notify API | `exports.toxic_ipad:Notify(source, { app = 'settings', title = 'Bank', message = 'Paid $50' })` from another resource's server thread returns `true` |
| Closed tablet | Notify while the tablet is away → nothing on screen, appears in the center next time |
| resmon | Closed 0.00 ms; open on home ≤ 0.03 ms; stopwatch running only costs while visible |

Report screenshots of anything that looks wrong and any F8 / server console errors.
