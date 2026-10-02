# TOXIC iPAD — SECURITY MODEL

Threat model: players run Lua executors and devtools. They can trigger any net event, call any NUI callback, post any message from any iframe, and send any payload. **Only the server is trusted** (§65).

---

## 1. Trust boundaries

```
 untrusted ───────────────────────────────────────────────┐   trusted
 NUI page · iframe apps · client Lua · net events          │   server Lua · DB · exports from other server resources
                                                           │
                    guard.lua (every entry) ───────────────┘
```
Other **server** resources calling exports are trusted as server code but are still validated (a buggy integration must not corrupt data).

---

## 2. The complete client-reachable surface (0.4.0)

Everything the client can reach is a `lib.callback` named `toxic_ipad:server:<domain>:<action>` (the names in `shared/constants.lua` CALLBACKS — `guard.register` refuses any other) plus three net events. Each callback has a strict schema and a rate bucket (`config/server.lua` rateLimits).

| Callback | Requires | Bucket (per player / min) |
|---|---|---|
| `device:unlock` (method, pin?) | session | `unlock` 10, lockout §4 |
| `device:setPasscode` (current?, new?) | session, unlocked, **owner** | `passcode` 3 |
| `device:lock` | session | `power` 30 |
| `device:storage` | session, unlocked | `storage` 20 |
| `settings:patch` (partial doc) | session, unlocked | `settings` 60 |
| `notes:list/save/delete` | session, unlocked | `notes` 120 |
| `notif:list/read/clear` | session, unlocked | `notif` 60 |
| `apps:store/install/uninstall/permission` | session, unlocked, `access`, `removable`, declared permission | `apps` 30 |
| `appdata:get/set/remove` (app, key, value) | session, unlocked, app installed + accessible, external app | `appdata` 120, 64 KB/value, per-app quota |
| `files:list/recents/mkdir/rename/move/delete/saveNote` | session, unlocked | `files` 90 |
| `photos:ticket` (selfie?) | session, unlocked, Camera accessible + installed, uploader configured; per tablet ≤ 6/min, ≤ 60/h, photo count + storage | `camera` 20 |
| `photos:save` (ticket, url, location?) | the player's current ticket (single use, < 60 s, same tablet), https URL on the uploader's host allow-list | `camera` 20 |
| `photos:list/get/delete/favorite/toFiles` | session, unlocked, Photos accessible + installed | `photos` 90 |
| `battery:info` / `battery:powerbank` | session, unlocked; power bank enabled, item in the inventory (server `RemoveItem`), not charging, not full | `power` 30 |
| `findmy:list/lost/erase` (serial) | session, unlocked, Find My accessible; the serial must be **owned by the session's character** (server lookup) | `findmy` 20 |
| `device:erase` (removeOwner, pin?) | session, unlocked, **owner**, passcode (counts toward lockout) | `passcode` 3 |
| event `chargeEmpty` (slot) | no session, loaded + can use, slot holds a tablet, battery empty, power bank in inventory | `open` |
| event `station` (index) | station exists, player within radius + 3 m (OneSync position), carries a tablet | `power` |
| event `closed` | — (closes own session) | — |
| event `requestOpen` (keybind) | `allowKeybindOpen = true` on the server, carries a tablet | `open` |
| event `openApp` (client export) | carries a tablet, app access + installed | `open` |

There is **no** client path to: create a device, change ownership, send a notification, register an app, change battery or storage numbers, or save a file into another device.

---

## 3. Guard pipeline (every callback, in this order)

1. **Rate limit** — token bucket per `src × bucket`; over the limit → `rate_limited`; 5× the limit within a minute is logged as `security` (kicking is left to the server's anticheat).
2. **Session** — `session[src]` must exist (created only by the item-use path, ARCHITECTURE §4.1). No session → `no_session`.
3. **Holding check** — the session's slot still holds the serial (or the item moved inside the same inventory). Otherwise the session closes → `device_gone`. The ox_inventory `swapItems` hook also closes sessions proactively, for the mover **and** the inventories the tablet left or entered.
4. **Lock state** — everything except `device:unlock` / `device:lock` requires `session.unlocked` (set only by a successful unlock on the server).
5. **Schema** — `shared/validate.lua`: types, lengths, ranges, enums, array shape, no unknown keys → `bad_request`.
6. **Per-device lock** — one request per device at a time (`device.withLock`), so checks and writes separated by a database wait (quotas, entry limits, folder moves, first-use folder creation) cannot be raced. Waits up to 5 s → `busy`.
7. **Handler** — authorisation rules (owner-only passcode, `access` via `Framework.hasGroup`, installed, removable, declared permission) and SQL with the device id **from the session**, plus `AND device_id = ?` in every statement.

Errors return stable codes; the NUI localises them. No stack traces reach the client (§69).

---

## 4. Specific protections

| Threat | Protection |
|---|---|
| Fake device ownership | Owner set once server-side (`claimOwner`, atomic); no client input changes it. |
| Using someone else's tablet data | Data belongs to the device; the holder must pass the lock screen; Face ID only for the owner; PIN verified server-side. |
| Reading a locked tablet | Until unlock the client receives notifications **redacted** (no message; title only when "Show Previews" is on); the full list is fetched after unlock (`notif:list`). Applies to live notifications too. |
| Brute-forcing a passcode | bcrypt (`GetPasswordHash` / `VerifyPasswordHash`); 5 free attempts, then 1, 5 and 15 min lockouts, repeating; counted per device (dropping and picking up does not reset it). ≈ 96 guesses/day → a 4-digit PIN takes ~52 days on average; 6 digits are recommended for high-value tablets. |
| Duplicated tablet items | Two items with the same serial (metadata copied by another script) are never open at once: a second player gets `in_use`, logged as `security`. |
| Stolen / taken tablet | Taking the item from a player ends that player's session at once (swap hook); removal by scripts (`RemoveItem`) ends it on the next request. |
| Third-party app iframes using the tablet's NUI callbacks | Lua issues a random token per open, sent only to the tablet page; `call` and `close` without it are refused. Iframes (other origins) cannot read it. |
| Iframe app spoofing another app | The OS routes SDK messages only from the window's own iframe (`event.source`) **and** the origin derived server-side from `RegisterApp.ui`; storage requests carry the window's app id; the server checks installed + access. Note: the *player* controls their own client, so they can read/write any external app's storage on their own tablet — `ipad.storage` must never gate rewards (APP_SDK §3.3). |
| App id takeover | An app/widget id stays bound to the first resource that registered it until toxic_ipad restarts, so another resource cannot inherit its stored data and permissions. |
| Oversized payloads / storage exhaustion | Note 20 000 chars, title 120; app data 64 KB per value and a per-app quota (default 256 KB); 500 notes, 200 notifications, 2 000 file entries per device; folder depth ≤ 12; settings document schema-capped. |
| Folder cycles / runaway queries | Moves check ancestors and the moved tree's height; recursive CTEs are depth-bounded and scoped by `device_id`. |
| Event spam | Token buckets (§3); per-device serialisation. |
| Rendering injected markup | React escapes by default; no `innerHTML`/`dangerouslySetInnerHTML` in the OS; names and messages are rendered as text. |
| Third-party page reaching the OS | Sandboxed iframe (no top navigation, popups or `alert`), validated protocol (`web/src/sdk/protocol.ts`). |
| Icon/UI URL abuse | `icon`/`ui` must be `nui://<calling resource>/…`; `..` and other resources refused. |
| Photos: fake / foreign uploads | **Server capture (screencapture + Fivemanage, default when available):** the server captures and uploads; the address stored is the one Fivemanage returned to the server — clients send only the ticket. Client-upload mode (screenshot-basic): a photo row needs a server-issued ticket (one per player, one use, 60 s, bound to the tablet) and an https URL on the uploader's host allow-list (`photos.checkUrl`: no user-info, ports, query tricks or look-alike hosts). **Limit:** `r2.fivemanage.com` serves every Fivemanage customer's files, so a cheater who skips the upload can store *another existing* Fivemanage image URL in their own library. It is shown only as an `<img>` (never markup) on tablets that hold that library and to apps the holder picks it for. With `custom`, list only hosts you control. |
| Photos: abusing the owner's upload account | Upload targets come only from `photos:ticket`: per-tablet limits per minute and hour, reserved before the provider call (parallel requests cannot pass together), refused when the library or storage is full. The Fivemanage token stays on the server (`config/server.lua`, never in fxmanifest `files`, or a server convar). With screencapture the server uploads itself and no target reaches a client; otherwise each target is a one-time presigned URL. |
| Photos: third-party apps | `ipad.photos.pick()` needs the app's declared + granted `photos` permission; the player picks in a system sheet and the app receives only that photo. Apps cannot list the library, open the Camera (`openApp('camera')` refused) or reach `photos:*` (NUI token). The picker never renders on a locked tablet and is cancelled on close. |
| Widget data (`UpdateWidget`) | Only the resource that registered the widget; ≤ 8 KB JSON; delivered only to viewers allowed to see the widget (access groups, app installed). Kept per **device** while cached (whoever holds that tablet sees it); dropped when the widget re-registers. |
| Power bank shared with a phone resource | The tablet never registers the item's use; it only calls `RemoveItem` once per charge after all checks, then persists the remaining charge. |
| Station abuse | Server distance check on start and every 5 s, item still carried; stops on drop. |
| Find My / erase of someone else's tablet | Every serial is checked against `owner_identifier = <session character>` on the server; Lost Mode blocks unlock for non-owners (swipe, PIN and Face ID); an erase closes sessions, blocks opening that serial until committed, runs in one transaction and never writes the old record back. |
| Admin actions | `/ipadgive`, `/ipadnotify`, `/ipadpin` through `lib.addCommand` restricted to `config.server.adminAce`, logged. |

---

## 5. Logging
Log channel `toxic_ipad` (and `toxic_ipad:security`): rate-limit breaches, repeated bad requests, passcode lockouts, device-gone mid-session, admin actions. Serials are logged; identifiers are hashed-prefix only in public channels (toxic_core spec §18 rule).

---

## 6. Phase 9 audit plan
Scripted exploit tests (a test resource with an executor-like harness): call every callback without a session, with another player's serial in the payload, with oversized/malformed payloads, at 10× rate, after dropping the item, with a spoofed iframe origin. Each must return the documented error and change nothing in the DB.

## Milestone 3 additions (0.3.0)
| Threat | Mitigation |
|---|---|
| A third-party page reaching the OS | Sandboxed iframe (no top navigation, popups, `alert`); messages accepted only from the window's own iframe **and** the origin derived server-side from `RegisterApp.ui`; every payload validated (`web/src/sdk/protocol.ts`); unknown request types dropped. |
| A resource registering an app that points at another resource | `ui`/`icon` must be `nui://<calling resource>/…`; ids belong to the first resource that registered them. |
| App storage abuse | Keys pattern-checked, 64 KB per value, per-app quota (default 256 KB), rate bucket `appdata` 120/min; app id comes from the window, and the server re-checks installed + access. |
| Forged permission grants | Permissions are the tablet holder's consent; the server stores the answer but a player can always grant their own tablet's permissions. Documented as consent, not a security boundary (APP_SDK §3.5). |
| Files | Only ids and names from the client; `AND device_id = ?` on every statement; system roots immutable; moving a folder into itself refused via ancestor check; entry/depth/capacity limits. `SaveFile` is server-only. |
| Layout/settings tampering | The layout is part of the validated settings document (ids pattern-checked, sizes capped); a bad layout can only rearrange the player's own home screen. |
