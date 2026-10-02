# TOXIC iPAD — DECISION LOG & OPEN QUESTIONS (Phase 1)

| # | Date | Decision | Status |
|---|---|---|---|
| I0 | 2026-09-27 | toxic_ipad is a new resource designed from zero; the existing `ls_tablet` is **not** used as a base or reference | Owner decided |
| I1 | 2026-09-27 | Phase 1 delivers research + architecture only; code starts after approval | Owner decided |
| I2 | 2026-09-27 | MVP live testing on **Qbox**; toxic_core bridge written against spec §6 and enabled when `Core_apiVersion() == 1` | Owner decided |
| D1 | 2026-09-27 | **The item is the device**: serial in ox_inventory metadata; notes/files/settings belong to the device; owner recorded; non-owners need the passcode | Proposed |
| D2 | 2026-09-27 | External apps run in **iframes** from their own resource (`nui://<resource>/…`) with a postMessage SDK; built-in apps are lazy React components behind ErrorBoundaries | Proposed |
| D3 | 2026-09-27 | NUI stack: React 18 + TypeScript + Vite (`target chrome103`) + Zustand + CSS Modules/tokens + own spring engine; built `dist/` committed | Proposed |
| D4 | 2026-09-27 | No `backdrop-filter` (CEF M103 flicker): glass = pre-blurred wallpaper layer; world blur = game native | Proposed |
| D5 | 2026-09-27 | `Notify(target, data)` — a recipient argument added to the spec'd `Notify(data)` | Proposed |
| D6 | 2026-09-27 | One table beyond §78A.11: `toxic_ipad_files` (Files app is MVP) | Proposed |
| D7 | 2026-09-27 | Settings stored as one validated JSON document per device | Proposed |
| D8 | 2026-09-27 | No money functions in the MVP bridge (no MVP feature spends money) | Proposed |
| D9 | 2026-09-27 | Landscape only in MVP; portrait/rotation Phase 2 | Proposed |
| D10 | 2026-09-27 | ox_target is not an MVP dependency (no world objects in MVP) | Proposed |
| D11 | 2026-09-27 | Item definition requires `consume = 0`, `stack = false`, `server.export = 'toxic_ipad.useItem'`; boot check warns if wrong | Proposed |

## Open questions for the owner

1. **D1 — device-bound vs character-bound data.** Device-bound is realistic (steal/borrow a tablet, passcode protects it) and enables Lost Mode/transfer later. Character-bound means every tablet a character uses shows *their* data. Recommendation: device-bound.
2. **Trademark risk.** "iPad" and "iPadOS" are Apple trademarks. The resource id `toxic_ipad` is internal, but a Tebex product title and the in-game default label "Toxic iPad Pro / Toxic iPadOS 27" are public. Recommendation: keep `toxic_ipad` as the resource name, make every visible name config-driven, and ship defaults like **"Toxic Tab Pro" / "ToxicOS 27"** with the store title "Toxic Tablet". The owner's call — flagged because it affects branding and store listing.
3. **Clock source default**: in-game time (immersive) or real time (practical for meetings like "20:00 tomorrow")? Recommendation: game time on the lock/status bar, real date in Calendar-like apps later; Clock app shows both.
4. **Accent colour default**: neutral system blue (feels like a tablet) or Toxic green (brand)? Both ship as themes; which is default?
5. **qb-core / ESX adapters in the MVP** (§78A.14 says optional): skip until Phase 8? Recommendation: skip.
6. **Movement while the tablet is open**: default off (zero-cost, realistic "holding the tablet")? Recommendation: off, config switch available.
7. **Source control**: commit `toxic_ipad/docs` into the Toxic Framework repo now (`docs(toxic_ipad): phase 1 architecture`)?

## Risks carried into Phase 2
See RESEARCH §5 and the in-game assumptions list in RESEARCH §6 (world blur native, prop/anim defaults, iframe callback routing, postMessage origin, font rendering). Those five are verified first, before step 7 of the build order.
