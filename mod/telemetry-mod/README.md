# telemetry-mod

Lightweight, runtime-only Factorio 2.0.76+ mod that emits one stable JSON object per telemetry event. JSONL, localhost UDP, and RCON export are independent outputs.

**Overview**
- Records small telemetry events (examples: `join`, `leave`, `desync`, `afk`, `death`, `research`, `evolution`) and can expose them through JSON Lines, UDP, or RCON.
- Provides a remote API for other runtime mods to emit `notify` telemetry lines without writing files directly.
- Emits evolution events (`type: "evolution"`) for periodic polling and on threshold crossings; evolution events may include optional dominance information.
- Emits `type: "desync"` on `on_pre_player_left_game` only when disconnect reason is `desync_limit_reached` (strict mode), with fields `reason` and `reason_id`.
- Can emit `type: "notify"` telemetry from `programmable-speaker` alerts based on configured circuit signal conditions, with anti-spam protections (rising-edge trigger, per-speaker cooldown, global per-scan cap).

**Install / Packaging**
1. Pack the `telemetry-mod` folder as a ZIP (or copy the folder) into Factorio's `mods` directory.
2. Alternatively, use the helper script `pack-mod.ps1` located in the `mod/` directory to produce a distributable archive.
3. Start the Factorio server or client. This is a runtime-only mod with no `data.lua`; it adds an opt-in checkbox to programmable speakers.
4. JSONL output is enabled by default; `telemetry.jsonl` appears in Factorio's `script-output` folder.

**Config & defaults**
- Defaults are defined in `control.lua`.
- Key defaults:
  - Log file: `telemetry.jsonl`
  - JSONL output: enabled
  - UDP output: disabled, destination port `34199`
  - RCON export: disabled, window of `100` events
  - AFK poll interval: 15 seconds (AFK ticks = 15 * 60)
  - Speaker notify scan interval: 5 seconds
  - Speaker notify cooldown per entity: 60 seconds
  - Speaker notify max events per scan: 5
  - Max buffered bytes: 50 KB (the mod bounds the file by size)
  - Max entry age: 24 hours
- The mod stores bounded, already-encoded JSON lines in `global.telemetry_buffer`. JSONL writes the current buffer; RCON returns its newest entries. UDP sends the current event immediately and does not retry.
- If the runtime environment lacks a write backend, `control.lua` detects this (`detect_write_backend`) and falls back to the best available approach or no-op.
- Speaker telemetry setup: enable the runtime setting `telemetry-speaker-notify-enabled`, then open a `programmable-speaker` and use the mod GUI checkbox (`Send telemetry from this speaker`). The speaker still needs `show alert` enabled, a circuit condition (`if <signal> ...`) and optional `alert message` (used as telemetry text).

**Output channels**

- `telemetry-output-jsonl-enabled` keeps the existing file contract. This is the default and is required by the JSONL Discord example; UDP and RCON examples use their respective outputs.
- `telemetry-output-udp-enabled` sends each JSON object as one datagram to `localhost:<telemetry-udp-port>`. Start the server or local Factorio instance with a separate source port, for example:

  ```text
  factorio --enable-lua-udp=34198
  ```

  A process on the same host then listens on the configured destination port (default `34199`). UDP is best-effort and local-only; the mod neither queues nor retries packets.
- `telemetry-output-rcon-enabled` permits an RCON client to execute:

  ```text
  /telemetry-export [limit]
  ```

  The result is one JSON response, such as `{"schema":"telemetry-rcon/v1","tick":1234,"events":[...]}`. `limit` is optional and cannot exceed `telemetry-rcon-window-events`. RCON is pull-only: it cannot push events asynchronously.

Any combination of the three settings is valid. If JSONL is disabled, the mod never clears or writes the configured telemetry file. If RCON is enabled, its snapshot is still constrained by the normal age and byte limits.

**Testing / examples**
- To test without running Factorio, append valid JSON Lines to `script-output/telemetry.jsonl` (one JSON object per line).
- Example lines produced by the mod:

```jsonl
{"tick":1234,"type":"join","player":"PlayerOne"}
{"tick":1240,"type":"afk","player":"PlayerOne","afk_ticks":900,"afk_seconds":15}
{"tick":2000,"type":"leave","player":"PlayerOne"}
{"tick":2050,"type":"desync","player":"PlayerOne","reason":"desync_limit_reached","reason_id":123}
{"tick":3500,"type":"evolution","trigger":"threshold","force":"enemy","evolution_factor":0.5,"threshold":0.5,"threshold_kind":"tier","threshold_key":"big_biter_spitter_worm","direction":"up","include_dominance":true,"message":"Enemy evolution 50%: big biters/spitters and big worms may appear."}
{"tick":3600,"type":"notify","source":"my_mod","severity":"warning","message":"Rocket silo low power","origin":"remote","surface":"nauvis","tags":["power","silo"]}
{"tick":4200,"type":"notify","source":"programmable-speaker","severity":"warning","message":"Iron buffer low","origin":"speaker","surface":"nauvis","category":"signal","code":"speaker-1234","tags":["programmable-speaker","signal-trigger","signal:virtual/signal-I"]}
```

Remote interface (`telemetry_mod`)
- `notify(payload)` -> emits a `type:"notify"` telemetry line and raises a runtime event for subscribers.
- `get_notify_event_id()` -> returns custom event id raised for `notify` payloads.
- Existing evolution API remains unchanged (`get_evolution_event_id`, `get_enemy_evolution`, etc.).

Example:
```lua
remote.call("telemetry_mod", "notify", {
  source = "my_mod",
  severity = "warning", -- info|warning|critical (warn/error aliases are normalized)
  message = "Assembler line is starved",
  surface = "nauvis",
  tags = { "production", "inputs" }
})
```

**Localization**
- The mod includes localization files under `locale/` (`en` and `pl`). Update translations in the appropriate locale files.

**Release / Mod Portal**
- Before publishing, install Node.js 20+ dependencies with `npm ci --prefix examples`, then run `pwsh -File scripts/test_factorio.ps1` from the repository root with PowerShell 7 and Factorio 2.0.77 installed. The isolated test exercises JSONL/UDP/RCON, runtime settings, local UDP-to-Discord webhook integration, and ZIP contents. Pass `-FactorioExe <path>` if Factorio is installed elsewhere.
- Run `pwsh -File scripts/test_upgrade.ps1` to create a save with the actual 0.1.11 source at Git commit `1f7eda2` and load it with the current mod. This test requires that reference commit to exist locally.
- The [repository release materials](https://github.com/351n/TelemetryMod/tree/main/mod) include portal copy and the release checklist; these are outside the distributable ZIP.
- `pack-mod.ps1` writes `dist/telemetry-mod_<version>.zip`; the archive contains exactly one versioned mod root and excludes local saves, logs, test files, and development metadata.

**Notes for integrators / relays**
- Preserve the event schema (the `type` values and required fields). The [Discord and OBS examples](https://github.com/351n/TelemetryMod/tree/main/examples) depend on these fields.
- The mod attempts to provide `cause_localised` strings for death events via a translator player; if unavailable it falls back to internal names.
- Death telemetry includes `surface` when it can be resolved from event/cause/player context.
- Do not change the semantics of fields without coordinating matching updates in both the mod and any relay components.

**Files to review**
- `control.lua` - main mod logic.
- `runtime/common.lua` - shared string/locale/surface helpers.
- `runtime/evolution_thresholds.lua` - evolution threshold definitions and selection logic.
- `runtime/write_backend.lua` - backend detection for `helpers.write_file` / `game.write_file`.
- `runtime/telemetry_outputs.lua` - bounded telemetry buffer plus JSONL, UDP, and RCON output routing.
- `runtime/udp_backend.lua` - safe wrapper for Factorio's localhost UDP helper.
- `runtime/translation_runtime.lua` - translation request/caching flow + stale pending resolution.
- `runtime/lifecycle.lua` - event registration + init/config/runtime-setting lifecycle wiring.
- `runtime/events/join.lua` - join event output.
- `runtime/events/leave.lua` - leave event output.
- `runtime/events/desync.lua` - strict desync detection/output.
- `runtime/events/afk.lua` - periodic AFK polling/output.
- `runtime/events/evolution.lua` - evolution polling, threshold crossings and chat/event emission.
- `runtime/events/notify.lua` - normalization and emission of `type:"notify"` telemetry.
- `runtime/events/speaker_notify.lua` - programmable-speaker signal polling + anti-spam notify emission.
- `runtime/events/speaker_gui.lua` - per-speaker mod GUI checkbox and persistence.
- `runtime/events/death.lua` - death event enrichment and output formatting.
- `runtime/events/research.lua` - research event extraction and output formatting.
- `settings.lua` - runtime output and telemetry settings.
- `locale/` - localization and translations.
- `LICENSE` - The Unlicense, also included in the distributable ZIP.
