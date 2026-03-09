# telemetry-mod

Lightweight, runtime-only Factorio mod that writes one JSON object per line to `script-output/telemetry.jsonl`.

**Overview**
- Records small telemetry events (examples: `join`, `leave`, `afk`, `death`, `research`, `evolution`) in JSON Lines format so external relays can read and forward them.
- Emits evolution events (`type: "evolution"`) for periodic polling and on threshold crossings; evolution events may include optional dominance information.

**Install / Packaging**
1. Pack the `telemetry-mod` folder as a ZIP (or copy the folder) into Factorio's `mods` directory.
2. Alternatively, use the helper script `pack-mod.ps1` located in the `mod/` directory to produce a distributable archive.
3. Start the Factorio server or client. This is a runtime-only mod (no `data.lua`, no in-game UI).
4. The output file `telemetry.jsonl` will appear in Factorio's `script-output` folder.

**Config & defaults**
- Defaults are defined in `control.lua`.
- Key defaults:
  - Log file: `telemetry.jsonl`
  - AFK poll interval: 15 seconds (AFK ticks = 15 * 60)
  - Max buffered bytes: 50 KB (the mod bounds the file by size)
  - Max entry age: 24 hours
- The mod buffers lines in `global.telemetry_buffer` and periodically overwrites the log file; it prunes entries by age and total bytes to keep the file bounded.
- If the runtime environment lacks a write backend, `control.lua` detects this (`detect_write_backend`) and falls back to the best available approach or no-op.

**Testing / examples**
- To test without running Factorio, append valid JSON Lines to `script-output/telemetry.jsonl` (one JSON object per line).
- Example lines produced by the mod:

{"tick":1234,"type":"join","player":"PlayerOne"}
{"tick":1240,"type":"afk","player":"PlayerOne","afk_ticks":900,"afk_seconds":15}
{"tick":2000,"type":"leave","player":"PlayerOne"}
{"tick":3500,"type":"evolution","trigger":"threshold","force":"enemy","evolution_factor":0.5,"threshold":0.5,"threshold_kind":"tier","threshold_key":"big_biter_spitter_worm","direction":"up","include_dominance":true,"message":"Enemy evolution 50%: big biters/spitters and big worms may appear."}

**Localization**
- The mod includes localization files under `locale/` (`en` and `pl`). Update translations in the appropriate locale files.

**Notes for integrators / relays**
- Preserve the event schema (the `type` values and required fields). External relays (for example, [bot/src/relay.js](bot/src/relay.js#L1)) depend on these fields.
- The mod attempts to provide `cause_localised` strings for death events via a translator player; if unavailable it falls back to internal names.
- Do not change the semantics of fields without coordinating matching updates in both the mod and any relay components.

**Files to review**
- `control.lua` — main mod logic.
- `settings.lua` — potential runtime settings (if present).
- `locale/` — localization and translations.
- `pack-mod.ps1` — helper script for packaging the mod (in the `mod/` folder).

If you want, I can create a sample `telemetry.jsonl` with test events or update the relay documentation with an example `bot` configuration.
