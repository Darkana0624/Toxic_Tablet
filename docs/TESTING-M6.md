# Milestone 6 — in-game test checklist (0.7.0 · Multitasking & orientation)

Replace the `toxic_ipad` folder (only the NUI, `shared/settings.lua`, `config/shared.lua` and `server/main.lua` changed; no database migration). Restart.

## Split View ratios
1. Open Notes → ••• → Split View → pick Calculator.
2. Drag the black divider left → release → it snaps to ⅓ (Notes narrow). Drag right → ⅔. Near ½ → ½.
3. Drag it all the way to the left edge → Calculator goes full screen.
4. Split Notes + Calculator again → the last ratio comes back.

## Slide Over
5. Open Files, then Notes → ••• → **Slide Over** → Notes floats on the right over Files.
6. Click Files → Files takes the keyboard; click Notes → Notes does. Esc with Notes focused → it slides away; the grey tab on the right edge brings it back.
7. Drag the grabber (top of the Slide Over window) to the right → it goes away.
8. Notes' ••• → Full Screen → Notes is a normal app again.
9. With an SDK app (Hello) in Slide Over: clicking inside it gives it the focus (Esc hides it).

## Portrait
10. Control Center → **Landscape** tile → the tablet turns to portrait (animation). Home: widgets on top, 4 icons per row.
11. Open Settings, Notes, Files, Photos, Find My, App Store → single-column layouts. Split View in portrait is ½ | ½.
12. **Rotation Lock** on → the rotate tile shows "Rotation Lock is on". Off → rotate back.
13. Put the tablet away and open it → it opens in the orientation you left.
14. `config/shared.lua` `display.portrait = false` → no rotate tiles, always landscape.

## Also check
| Area | Check |
|---|---|
| Esc order | window menu → sheets → switcher → pick → Slide Over → home → put away |
| Home gesture | swipe up with Slide Over visible → home; Slide Over hidden; opening an app → edge tab |
| Switcher | Slide Over app appears as a card; tapping it opens it full screen |
| Performance | dragging the divider moves only the divider; apps re-lay out once on release |
