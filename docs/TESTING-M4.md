# Milestone 4 — in-game test checklist (0.5.0 · Camera & Photos)

## Before you start
1. Replace the whole `toxic_ipad` folder (new: `bridge/uploader/`, `client/camera.lua`, `server/photos.lua`, `server/storage/photos.lua`, `migrations/0003_photos.sql`, `config/*`, `ui/`, `ui/sdk/`). Re-apply your own config changes to the new config files.
2. `server.cfg`:
   ```cfg
   ensure screenshot-basic      # before toxic_ipad
   ensure toxic_ipad
   ensure toxic_ipad_hello      # optional (updated example: copy it again)
   # Fivemanage token: config/server.lua  uploader.fivemanage.token = 'your-token'
   ```
3. Restart. Console: `database migrations applied versions=3` once. No `Camera is off: …` warning.

## Demo scenario
1. Open the tablet → the home screen has **Camera** and **Photos**.
2. **Camera** → the tablet steps aside, the view moves to your eyes, the viewfinder shows PHOTO · 1.0× and key hints.
3. Move the mouse → you look around and your character turns with the camera. Mouse wheel → zoom (1.0× → 3.3×).
4. Left click → the overlay disappears for a moment, white flash, the thumbnail (bottom left) shows the photo, counter 1.
5. **E** → selfie: the camera is in front of your face; move the mouse to frame; left click.
6. **Backspace** (or right click / Esc) → the tablet comes back; the Camera window lists the photos you took.
7. Tap a thumbnail → **Photos** opens that photo: date, time and street at the top.
8. Viewer: arrow keys / swipe → next and previous; **Favorite** (heart) → back → **Favorites** filter shows it; **Selfies** shows the selfie.
9. Viewer → **Save to Files** → toast → **Files** › Documents → `IMG_xxxx.jpg` → tap it → Photos opens the photo.
10. Photos → **Select** → pick two → **Delete** → confirm → gone; the Files entry of a deleted photo is gone too.
11. Settings › **Tablet Storage** → Photos with its size and count.
12. **Hello** (example app) → **Pick a photo** → the system asks for Photos access → **Allow** → a picker sheet → choose one → the photo shows in the Hello page. Deny it on another tablet → "Photo access is off".
13. Add the **Hello** widget to the home screen → open Hello → **Tap (+1)** → the widget number changes live (UpdateWidget).

## Also check
| Area | Check |
|---|---|
| Camera exit paths | Put the tablet away with the item while in camera mode (drop / give), die, get cuffed, `restart toxic_ipad` → the normal game camera and mouse always come back. |
| Esc | In camera mode Esc leaves the camera — the pause menu does not open. |
| Voice / chat | Push-to-talk and chat work in camera mode. |
| HUD | The minimap and HUD are hidden while the camera is active and come back after. |
| Limits | More than 6 photos in a minute → "Try again" style error on the viewfinder (`rate_limited`). |
| No uploader | Remove the token and restart → no Camera app, console explains why; Photos still opens. |
| screenshot-basic late | `stop screenshot-basic` → Camera disappears within a second; `start screenshot-basic` → it comes back. |
| Auto-Lock | With Auto-Lock at 30 s, stay in camera mode for a minute → you can still take photos; the tablet does not lock under you. |
| Locked tablet | Open Hello's picker, then put the tablet away (not with Esc) and reopen → the lock screen shows, no picker. |
| Other player | Give the tablet to another player → they see the photos only after the passcode (if set). |
| Performance | `resmon`: toxic_ipad ~0.00 ms with the tablet away; camera mode only adds its one per-frame loop while the viewfinder is shown. |

## Report back
Anything that behaves differently, with the F8 lines starting `[toxic_ipad` and the server console lines around it.
