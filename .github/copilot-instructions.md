# Copilot instructions — concise guide for code agents

## Project snapshot
- Two top-level components:
  - `bot/` — Node.js relay that incrementally tails a remote Factorio JSONL file and posts human-readable messages to Discord via webhook. See [bot/package.json](bot/package.json#L1) and [bot/src/relay.js](bot/src/relay.js#L1).
  - `mod/telemetry-mod/` — Factorio runtime-only mod that writes one JSON object per line to `script-output/telemetry.jsonl`. See [mod/telemetry-mod/control.lua](mod/telemetry-mod/control.lua#L1).

## Big picture / data flow
- Factorio (mod) -> `script-output/telemetry.jsonl` (JSON Lines) -> Relay (`bot/src/relay.js`) polls over SFTP/FTP, reads only new bytes (tail), parses each JSON line and posts to Discord. Relay persistence lives in [bot/relay_state.json](bot/relay_state.json#L1).

## Quickstart (developer)
- Run the relay locally:

```bash
cd bot
npm install
npm start
```

- Node >=20 is required (see [bot/package.json](bot/package.json#L1)). On Windows there's a helper `bot/run-hidden.vbs` that runs `src/relay.js` via the Node executable; inspect it when automating background runs.

## Important env vars and what they control
- `DISCORD_WEBHOOK_URL`: required — where messages are posted.
- `PROTOCOL`: `sftp` (default) or `ftp` — controls remote read implementation.
- `REMOTE_PATH`: remote file path (default `script-output/telemetry.jsonl`).
- `POLL_SECONDS`: poll interval (seconds).
- `TIMEZONE`, `QUIET_HOURS_START`, `QUIET_HOURS_END`: quiet-hour logic used to suppress pings.
- `PING_ROLE_ID`, `PING_ON_JOIN`, `PING_ON_CRITICAL_ONLY`: control role pings and when they are allowed.

## Project-specific patterns & gotchas
- Incremental tailing: `relay_state.json` stores `offset` and `carry`. Always preserve this file between runs to avoid duplicate posts or missed bytes.
- File rotation/truncation: Relay detects size shrink and resets `offset` to `0`.
- Deduping: Messages are de-duplicated in-memory for `DEDUP_SECONDS` (10s). Rapid identical lines may be suppressed.
- Quiet-hours & pings: The relay computes quiet periods using `luxon` and `TIMEZONE`. Pings are suppressed during quiet hours even if code calls include ping markers.
- Localization: `handleEvent` uses Polish-localized strings (keep phrasing intent intact). Don't hard-replace language unless coordinated with maintainers.
- Mod write backend: `control.lua` detects `helpers.write_file` vs `game.write_file` and buffers lines in `global.telemetry_buffer`. When testing mod behavior, emulate Factorio runtime or stub `game`/`helpers` accordingly.

## Event schema (preserve these fields)
- `type` (string): e.g., `join`, `leave`, `afk`, `death`, `research`. Relay relies on these values.
- `join/leave`: include `player`.
- `afk`: may include `afk_seconds` or `afk_ticks`.
- `death`: include `player`, `cause`, `cause_localised`, `cause_type`, `cause_force`, `damage_type`, `pos` (array).
- `research`: include `technology` / `technology_localised` / `player` / `force`.

If you change the schema in the mod, update `bot/src/relay.js` accordingly — this is a cross-component contract.

## Files to inspect (entry points and examples)
- Event handling & posting: [bot/src/relay.js](bot/src/relay.js#L1)
- Local state format: [bot/relay_state.json](bot/relay_state.json#L1)
- Windows helper to run relay: [bot/run-hidden.vbs](bot/run-hidden.vbs#L1)
- Mod writer + buffering/pruning: [mod/telemetry-mod/control.lua](mod/telemetry-mod/control.lua#L1)
- Mod usage notes and sample JSONL: [mod/telemetry-mod/README.md](mod/telemetry-mod/README.md#L1)

## Testing & debugging tips (concrete)
- Simulate mod output by appending valid JSON lines to a file and point `REMOTE_PATH` to it (use a local FTP/SFTP server to mimic protocol). Verify `relay_state.json` advances and `offset` increases.
- For faster iteration set `POLL_SECONDS` small (e.g., `2`) but remember deduping and rate-limits may suppress repeated posts.
- To test quiet-hours/pings, set `TIMEZONE` and `QUIET_HOURS_*` to include the current time and observe whether `PING_ROLE_ID` is omitted.

## Agent editing rules (must-follow)
- Preserve the event schema and `type` values unless you update both `mod` and `bot` together.
- Keep user-visible message intent (severity mapping in `handleEvent`) — changes to phrasing require approval.
- Don't embed ping markers into message content; use `PING_ROLE_ID` and allowed_mentions handling in `postToDiscord`.
- When editing `control.lua`, keep `detect_write_backend` and buffer prune/flush logic intact — it's responsible for bounding `telemetry.jsonl` size and age.

## When in doubt
- Ask: "Will this change require a complementary mod or relay update?" If yes, do not change the schema or message semantics without coordination.

---