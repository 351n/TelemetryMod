# telemetry-mod

Runtime-only Factorio mod that writes one JSON object per line to `script-output/telemetry.jsonl`.

Overview
- Logs lightweight telemetry events (examples: `join`, `leave`, `afk`, `death`, `research`) so external relays can read and forward them.

Install
1. Pack the `telemetry-mod` folder as a ZIP (or copy the folder) into the game's `mods` directory.
2. Start the Factorio server/client. This mod is runtime-only (no data.lua) and has no in-game UI.
3. The log file appears in the game's `script-output` folder as `telemetry.jsonl`.

Config & defaults
- Defaults are defined in `control.lua`. Main defaults:
	- log file: `telemetry.jsonl`
	- AFK poll interval: 15 seconds (AFK interval ticks = 15 * 60)
	- Max bytes buffered: 50 KB (the mod bounds the file by size)
	- Max age: 24 hours
- The mod buffers lines in `global.telemetry_buffer` and flushes by overwriting the log file; it prunes by age and total bytes to keep the file bounded.
- If the runtime lacks a write backend, the mod falls back to best-effort writes or no-ops—see `detect_write_backend` in `control.lua` for details.

Testing / examples
Append valid JSON Lines to `script-output/telemetry.jsonl` (one JSON object per line). Example lines produced by the mod:

{"tick":1234,"type":"join","player":"PlayerOne"}
{"tick":1240,"type":"afk","player":"PlayerOne","afk_ticks":900,"afk_seconds":15}
{"tick":2000,"type":"leave","player":"PlayerOne"}

Notes for integrators
- Preserve the event schema (`type` values and required fields). External relays (e.g., `bot/src/relay.js`) depend on these fields.
- The mod attempts to provide localized `cause_localised` strings for deaths via a translator player; if unavailable it falls back to internal names.
- When testing the mod logic outside Factorio, stub `game`/`helpers` as `control.lua` checks for `helpers.write_file` vs `game.write_file`.

See `control.lua` for implementation details and `settings.lua` for any exposed runtime settings.
