# knb_cad — LAPD-style MDC + Dispatch

A mobile data computer (MDC) and dispatch system for police, sheriff and EMS: incident queue, live map, plate / person / weapon lookup,
LAPD-style reports, warrants and BOLOs, messaging, unit board and shift stats. Automatic alerts (gunshots, fights, carjackings, robberies…) open calls on their own.

## Requirements
`qbx_core`, `ox_lib`, `oxmysql`

## Installation
1. Put the `knb_cad` folder into your `resources` folder.
2. Import `sql/knb_cad.sql` into your database.
   **Warning:** this file drops and recreates the MDC tables (`cad_calls`, `cad_records`, `cad_bolos`). Existing MDC data is lost, so back up first if needed.
   Player, vehicle and inventory tables are not touched.
3. Add to `server.cfg` (after the requirements above):
   ```
   ensure knb_cad
   ```
4. Open `config.lua` and adjust it to your server (language, departments, jobs, permissions, penal code, jail hook).

## Commands and keys
| Command | Default key | Description |
|---|---|---|
| `/cad` | F10 | Open / close the MDC |
| `/cadrespond` | Y | Accept the latest alert: join the call + GPS route |
| `/panic` | – | Panic signal while on duty |
| `/cadmute` | – | Toggle the alert sound |
| `/cadclose` | – | Force-close the MDC |
| `/plate ABC123` | – | Quick plate lookup |
| `/911`, `/911a`, `/311` | – | Civilian reports (`/911a` = anonymous) |
| `/dispatchtest` | – | Sends 5 sample alerts to an on-duty officer (disable with `Config.Dispatch.TestCommand = false`) |

Command names and keys can be changed in `config.lua`; players can rebind keys in Settings > Key Bindings > FiveM.

**While the MDC is open:** F1 Available · F2 En route · F3 Code 6 · F4 Code 7 · F5 Report · F6 Transport · F7 Traffic stop · F8 Pedestrian stop ·
F9 Lookup · F10 Close · F11 Backup · F12 Panic (hold) · 1–8 switch tabs · ESC close

The MDC opens inside an emergency vehicle or next to a computer (see `Config.Access`).

## Language
Set `Config.Locale = 'en'` (or `'tr'`) in `config.lua`. All texts are in `locales/<code>.json`; to add a language, copy `en.json`,
translate the values (keep keys and `{1}`-style placeholders) and set `Config.Locale` to the new code.

## For developers
```lua
-- Client
exports['knb_cad']:SendAlert('Fight', { message = 'Fight in front of the bar' })
exports['knb_cad']:CustomAlert({ message = 'ATM ROBBERY', cadCode = 3, jobs = { 'leo' }, radius = 50.0, sprite = 108 })

-- Server
exports['knb_cad']:SendAlert('PrisonBreak', vector3(1845.0, 2585.0, 45.0), { message = 'Escapee reported' })
exports['knb_cad']:CreateCall({ title = 'TRAFFIC COLLISION', priority = 2, coords = coords, message = '...' })
exports['knb_cad']:GetCalls()
exports['knb_cad']:IsWanted(citizenid)   -- true if the citizen has an active warrant
```

## License
Copyright (C) 2026 kenobiali. knb_cad is free software, released under the **GNU General Public License v3.0 or later** (see the `LICENSE` file).

You may use, modify and redistribute it, including on your own server, as long as you keep the copyright and license notices and
provide the source code of any distributed version under the same license. It comes with no warranty.

The alert detection and dispatch logic is adapted from [Project Sloth ps-dispatch](https://github.com/Project-Sloth/ps-dispatch) (GPL-3.0).
See `NOTICE.md` for third-party material.
