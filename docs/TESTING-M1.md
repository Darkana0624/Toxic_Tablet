# Milestone 1 — in-game test checklist

Build 0.1.0 covers MVP build order steps 1–9: resource, config, framework bridge (Qbox),
ox_inventory item, device records, database, NUI root, the 80 % floating device, lock
screen with passcode / Face ID. Apps, dock and widgets are the next milestone.

Before testing: follow INSTALLATION.md and add `setr toxic_ipad:debug "true"` to server.cfg.

## A. Research assumptions (docs/RESEARCH.md §6) — please report each
| # | Check | Expected |
|---|---|---|
| A1 | Open the tablet with `worldBlur = 'native'`, then `ipad_blur timecycle` and reopen, then `ipad_blur none` | Which looks best? Does the blur flicker? |
| A2 | Prop + animation | Tablet held in the left hand, both hands on it, not clipping |
| A5 | Text is Inter (not a fallback font); Mongolian Ө/Ү render (`setr ox:locale "mn"`) | Same look as the preview screenshots |

(A3 and A4 — iframe apps — are tested in milestone 2.)

## B. Device
1. `/ipadgive <id>` → the item shows a description with "S/N TXP-…". 
2. Use it → character takes out the tablet, the device scales in (≈0.45 s), game visible and dimmed around it.
3. Size: the device is ~80 % of the screen height on 16:9, never touching the edges. Try `display.size = 0.9` and `0.75`.
4. Esc on the lock screen → tablet animates out, prop removed, mouse released immediately.
5. Use it again quickly 10× → no stuck mouse, no leftover props, no console errors.
6. `restart toxic_ipad` while the tablet is open → mouse released, prop removed.
7. Drop the item while open (drag it out of the inventory is not possible while focused — instead have a second player/admin remove it, or `/clearinv`) → tablet closes with "no longer in your inventory".

## C. Lock screen
1. First use: no passcode → Swipe up (drag the lower half up) or Enter → home.
2. Passcode (the Settings app arrives in milestone 2): with the tablet open, run `/ipadpin <your id> 1234`, press the power button twice (lock), swipe up:
   - as the owner → Face ID scan → home;
   - press "Use Passcode"/Cancel paths, type a wrong code 5× → "Tablet disabled, try again in 1 min"; reopening the tablet does **not** reset the lockout;
   - give the tablet to a second player → no Face ID for them, keypad only;
   - `/ipadpin <id>` (no pin) removes the passcode.
3. Power button (top edge, right) → screen off; click the screen → lock screen. Volume buttons (right edge) → volume HUD; reopen the tablet → the volume is remembered.
4. Wait 2 minutes on the home screen without input → screen turns off (auto-lock).

## D. Persistence
1. Change volume, close, reconnect, reopen → the volume is kept (settings persisted per device).
2. Battery: open for a few minutes → the percentage drops ~0.35 %/min; put it away → it charges 20 %/hour.

## E. Performance
1. `resmon` with the tablet closed → toxic_ipad 0.00 ms client and server.
2. Tablet open on the home screen → ≤ 0.03 ms client.

Report: screenshots of A1/A2, anything that differs from "Expected", and console errors (F8 and server).
