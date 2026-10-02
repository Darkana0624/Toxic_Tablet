# toxic_ipad

Toxic Scripts virtual tablet OS for FiveM. Status: **0.7.0 — Phase 2 complete (M4 Camera & Photos, M5 Power & ownership, M6 Multitasking & orientation) — needs an in-game check.**

Install: [docs/INSTALLATION.md](docs/INSTALLATION.md) · Test: [docs/TESTING-M4.md](docs/TESTING-M4.md) · [docs/TESTING-M5.md](docs/TESTING-M5.md) · [docs/TESTING-M6.md](docs/TESTING-M6.md) · Phase 2 plan: [docs/PHASE2.md](docs/PHASE2.md) · [CHANGELOG.md](CHANGELOG.md)

Tests: `lua5.4 tests/run.lua` (Lua, from this folder) · `cd web && npm ci && npm test && npm run build` (NUI).

| Document | Contents |
|---|---|
| [docs/RESEARCH.md](docs/RESEARCH.md) | Verified platform facts (CEF M103, ox_inventory item flow), feasibility matrix, risks, in-game assumptions |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, resource layout, open/close/operation flows, device model, bridges, public API, config, build order |
| [docs/UI_SYSTEM.md](docs/UI_SYSTEM.md) | NUI stack, 80 % floating device math, visual language, glass technique, motion, gestures, stores, focus |
| [docs/APP_SDK.md](docs/APP_SDK.md) | RegisterApp, iframe SDK, lifecycle, widgets, deep links, example app |
| [docs/WINDOW_MANAGER.md](docs/WINDOW_MANAGER.md) | Window model, operations, split view, resource budget, switcher |
| [docs/DATABASE.md](docs/DATABASE.md) | Schema, settings document, query catalogue, caching, migrations |
| [docs/SECURITY.md](docs/SECURITY.md) | Client-reachable surface, guard pipeline, protections, audit plan |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Thread budget, zero-tick battery, NUI rules, measurement plan |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Decision log and open questions for approval |

Third-party app example: [examples/toxic_ipad_hello](examples/toxic_ipad_hello) (copy it next to `toxic_ipad`, not inside it).
