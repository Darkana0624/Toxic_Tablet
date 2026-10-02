# toxic_ipad_hello — App SDK example

A complete third-party app for **toxic_ipad**: one app and one home-screen widget,
shipped in its own resource. It is also the in-game test for the SDK.

## Install (test server)
1. Copy this folder to your `resources` (next to `toxic_ipad`, **not inside it**).
2. `server.cfg`: `ensure toxic_ipad` then `ensure toxic_ipad_hello`.
3. Open the tablet → **App Store** → **Hello** → **Get**.
4. Home screen → press and hold → **+** → add the **Hello** widget.

## What it shows
| Feature | Where |
|---|---|
| `RegisterApp` / `RegisterWidget` | `server.lua` |
| Re-registering when toxic_ipad restarts | `server.lua` (`onResourceStart`) |
| `ipad.storage` (per tablet, server-side quota) | Tap button, widget counter |
| `ipad.requestPermission('location')` + server check `HasPermission` | "Where am I?" |
| Your own NUI callbacks from inside the tablet | `fetch('https://toxic_ipad_hello/whereAmI')` → `client.lua` |
| Server-only notifications (`exports.toxic_ipad:Notify`) | "Send me a notification" |
| `toast`, `confirm`, `setBadge`, lifecycle, routes, language | `web/index.html` |

Read `toxic_ipad/docs/APP_SDK.md` for the full API.
