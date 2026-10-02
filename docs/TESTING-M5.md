# Milestone 5 — in-game test checklist (0.6.0 · Power & ownership)

## Before you start
1. Replace the whole `toxic_ipad` folder; re-apply your config changes (new: `config/apps.lua` findmy, `config/shared.lua` `battery.powerBank`, `battery.stations`, `findMy`).
2. Restart. Console: `database migrations applied versions=4` once; no `config/apps.lua has no …` or `power bank item … is not defined` warnings.
3. For stations: set `battery.stations.enabled = true` and add one point near you, e.g. `{ coords = vec3(x, y, z), label = 'Test' }` (`/tx` → coords), `ensure ox_target`.

## Demo scenario
1. Get two power banks (`/giveitem <id> powerbank 2` or your admin menu) and a tablet.
2. **Settings › Battery** → Charging: "Not Charging", "Use Power Bank · 2 in inventory" → tap → toast, status "Power Bank · 100% left", one item gone from the inventory, the status-bar battery shows charging. Leave it open 2 minutes → the level rises ~10 %.
3. Use the **phone's** power bank as usual from the inventory → the phone charges exactly as before (the tablet does not react).
4. Empty tablet: open it and run `/ipadbattery <your id> 0` → it switches off. Use the item again → dialog "Tablet battery is empty · Use one Powerbank?" → Use → the tablet opens and charges.
5. **Station**: stand at the point → ox_target "Charge Tablet" → notice "Your tablet is charging". Walk 5 m away → within 5 s "You left the charging station".
6. **Find My** → your tablets: this one "With you"; a second tablet you own (give yourself another, open it once, drop it or put it in a stash) shows "Street · 5 min ago".
7. Select the other tablet → **Directions** → a GPS waypoint. **Mark As Lost** → message → Activate.
8. Another player (or you as another character) opens the lost tablet → lock screen "This tablet has been lost" + message; swipe / PIN / Face ID do nothing. Back on the owner: open it and unlock → toast "Lost Mode turned off".
9. Find My → **Erase This Tablet** on the other tablet → confirm → its notes/files/photos are gone when opened; you are still the owner.
10. **Settings › Transfer or Reset Tablet** → Erase and Remove Owner → confirm → passcode → the tablet closes; open it as another character → it is theirs, empty.
11. Admin: `/ipadwipe TXP-XXXXXXXXXX` → "Tablet erased"; with `owner` the owner is removed too.

## Also check
| Area | Check |
|---|---|
| Restart | Use a power bank, `restart toxic_ipad` mid-charge → reopen: it keeps charging with the rest. |
| Battery off | `battery.enabled = false` → no Charging section, no power bank prompt, stations do nothing. |
| Not owner | A non-owner sees "Only the owner of this tablet can erase it." in Transfer or Reset; Find My lists only tablets their character owns. |
| Erase while open | Erase from Find My a tablet another player has open → it closes for them ("This tablet was erased"). |
| Performance | `resmon` toxic_ipad ~0.00 ms idle; the station watcher runs only while something charges at a station (every 5 s). |
