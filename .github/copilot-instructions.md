# TelemetryMod repository guide

## Components

- `mod/telemetry-mod/` is a runtime-only Factorio 2.1 mod. `control.lua` composes the runtime modules; `settings.lua` defines runtime settings and `locale/` contains English and Polish strings.
- `examples/` contains separate Node.js 20+ integrations: Discord over JSONL/SFTP or FTP, RCON, or localhost UDP, plus an OBS bridge over localhost UDP. Discord examples share code in `examples/discord-shared/`.
- `mod/pack-mod.ps1` packages the mod from `info.json`. `scripts/` and `tests/` contain isolated Factorio and integration checks.

## Data flow and contracts

- The mod emits stable JSON event objects through independently configurable JSONL, UDP and RCON outputs. Preserve event `type` values, fields and the `telemetry_mod` remote interface when changing the runtime; review example consumers for compatibility.
- Persistent state belongs in Factorio's `storage` table. Access it directly rather than caching an alias when `control.lua` loads; respect init, load and configuration-change lifecycle rules.
- `runtime/telemetry_outputs.lua` owns the bounded event buffer and routes output. JSONL is a rewritten snapshot, not an append-only stream. UDP is local and best-effort. RCON returns a read-only snapshot on request.
- Discord JSONL and RCON examples compare overlapping snapshots; their initial snapshot is a baseline. Loss of overlap can lose events. UDP has no history. Avoid promising guaranteed delivery.
- Discord and OBS UDP examples cannot bind the same port at the same time. Secrets and local state belong in ignored `.env`, `config.json` and `relay_state.json` files.
- Preserve Discord message intent, quiet hours, role-ping behavior and existing consumer contracts when making changes.

## Verification

- Run `npm test` in `examples/` and `examples/obs/` for their respective test suites.
- For a release, follow `mod/RELEASE_CHECKLIST.md`: test the packaged mod with the target Factorio runtime, including save/load and upgrade scenarios. `scripts/test_factorio.ps1` uses an isolated data directory; `scripts/test_upgrade.ps1` accepts an existing 2.0 save.
- Keep locale keys aligned across English and Polish, and update the mod README, portal copy and changelog when behavior changes.
- See `mod/telemetry-mod/README.md` and `examples/README.md` for setup, configuration and delivery limitations.
