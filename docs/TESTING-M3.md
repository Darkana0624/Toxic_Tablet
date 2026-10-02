# Milestone 3 — in-game test checklist (0.3.0)

Covers MVP §78A.21 steps 11–20 (Files, App Store, widgets, third-party app) plus home edit mode.

## Before you start
1. Replace the whole `toxic_ipad` folder (new: `config/apps.lua` content, `server/*`, `ui/`, `ui/sdk/`, `migrations/0002_app_removals.sql`).
2. Copy `toxic_ipad/examples/toxic_ipad_hello` to your resources **next to** `toxic_ipad` (not inside it) and add `ensure toxic_ipad_hello` after `ensure toxic_ipad`.
3. Restart. The server console shows `database migrations applied versions=2` once, then `app registered app=hello_demo resource=toxic_ipad_hello`.

## Demo scenario
1. Open the tablet → home: Clock and Battery widgets on the left, dock = Settings, Files, Notes, App Store.
2. **Notes** → open a note → share icon (arrow up) → toast "Saved to Files › Documents".
3. **Files** → Documents → the note file is there → tap it → Notes opens that note.
4. Files → **New Folder** (folder + icon) → type a name → Enter. Right-click (or •••) the note file → **Move** → into the new folder.
5. **App Store** → **Hello** → **Get** → it appears on the home screen.
6. Open **Hello** → Tap (+1) a few times → **Where am I?** → the system asks for Location → **Allow** → your street is shown (this proves the app can call its own resource's NUI callbacks from inside the tablet — research assumption A3).
7. Hello → **Send me a notification** → a banner "Hello" arrives (server-only Notify). Tap it → Hello opens with `route: /from-notification` in its log.
8. Home → press and hold an icon → icons jiggle. Drag Calculator onto Clock and hold → a folder "Utilities" appears. Drag an app into the dock and back. **+** → add the **Hello** widget → it shows your tap count. **Done**.
9. Settings › **Privacy & Security** → Location → Hello is On; turn it off → "Where am I?" now says access is off.
10. Settings › **Tablet Storage** → ToxicOS, App Data (Hello), Files, Notes.
11. Press and hold → **−** on Hello → Delete → it disappears (and its widget); App Store shows **Get** again.
12. Put the tablet away and open it again → layout, folder and widgets are kept.

## Also check
| Area | Check |
|---|---|
| Resource restart | `restart toxic_ipad_hello` with Hello open → "temporarily unavailable"; after it started, Restart works again |
| Third-party errors | Hello's page errors print in F8 as `[toxic_ipad:nui] app hello_demo: …`; the OS keeps working |
| Esc inside Hello | goes home like any app |
| Split View | Files + Hello side by side; Hello's Layout row says `split` |
| Language | `setr ox:locale "mn"` → Hello and the OS in Mongolian |
| `OpenApp` | from a server console script: `exports.toxic_ipad:OpenApp(<id>, 'settings', '/storage')` — with the tablet closed it opens, and Settings opens at Storage after unlock |
| `SaveFile` | `exports.toxic_ipad:SaveFile(<id>, { name = 'Report.pdf', mime = 'application/pdf', sizeBytes = 245000 })` → appears in Files › Downloads (live if Files is open) |
| Reset | Settings › Home Screen & Widgets › Reset → default layout, nothing deleted |
| resmon | Home with widgets ≤ 0.03 ms; an idle Hello app costs nothing on the Lua side |

Report anything that looks wrong with a screenshot, and F8 / server console errors.
