# Factorio Telemetry Relay -> Discord

This Node.js app tails a Factorio JSON Lines telemetry file (`script-output/telemetry.jsonl`) over SFTP or FTP and forwards readable messages to Discord via webhook.

Quick start

1. Create a Discord webhook URL for the target channel.
2. Copy `.env.example` to `.env` and fill required values.
3. Install dependencies and run:

```bash
npm install
node src/relay.js
```

Behavior
- Polls the remote file every `POLL_SECONDS` (default: 15s).
- Reads only new bytes and handles truncation/rotation by resetting offset.
- Persists progress and dedupe state in `relay_state.json`.

Event mapping
- `join` -> critical message
- `leave` -> critical message
- `desync` -> critical message with reason details
- `afk` -> warning transitions only (`AFK` / `returned from AFK`)
- `death` -> info message
- `research` -> info message
- `evolution` -> critical only for selected threshold-up events
- `notify` -> forwards custom telemetry notices from mods (`severity`: `info`/`warning`/`critical`)

Quiet hours and pings
- Controlled by `TIMEZONE`, `QUIET_HOURS_START`, `QUIET_HOURS_END`.
- During quiet hours, non-critical messages are suppressed.
- AFK messages are excluded from quiet-hours summary.

State trimming
- `relay_state.json` is trimmed automatically:
  - bounded dedupe ids (`STATE_MAX_SENT_IDS`)
  - bounded suppressed events (`STATE_MAX_SUPPRESSED_EVENTS`)
  - bounded carry buffer (`STATE_MAX_CARRY_BYTES`)
  - stale/inactive player AFK entries pruned (`STATE_PLAYER_STALE_HOURS`, `STATE_MAX_PLAYERS`)
- Persistent dedupe excludes `afk` events to keep state small.

Files
- `src/relay.js` - main program
- `.env.example` - environment template
- `package.json` - dependencies