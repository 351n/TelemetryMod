# Factorio Telemetry Relay -> Discord

This small Node.js app tails a Factorio mod's JSON Lines file (written to `script-output/telemetry.jsonl`) over SFTP or FTP and posts human-readable messages to a Discord channel via webhook.

Quick start

1. Create a Discord webhook for the target channel and copy its URL.
   - Server Settings -> Integrations -> Webhooks -> New Webhook -> copy Webhook URL.
2. Copy `.env.example` to `.env` and fill values (`DISCORD_WEBHOOK_URL`, `PROTOCOL`, connection details, etc.).
3. Install deps and run:

```bash
npm install
node src/relay.js
```

Where the Factorio mod writes telemetry: typically `script-output/telemetry.jsonl` on the host running Factorio. Set `REMOTE_PATH` accordingly.

Behavior
- Polls the remote file every `POLL_SECONDS` (default 15s).
- Reads only new bytes (incremental), handles truncation/rotation by resetting offset.
- Keeps local state in `relay_state.json` to avoid duplicate messages across restarts.

Events mapping
- join  -> 🟢 <player> wszedł na serwer
- leave -> ⚪ <player> wyszedł z serwera
- afk   -> keeps per-player AFK state and emits transitions only:
  - `afk_seconds >= AFK_ON_SECONDS` and previously not AFK -> 💬 "💤 <player> AFK"
  - `afk_seconds <= AFK_OFF_SECONDS` and previously AFK -> 🔔 "🔔 <player> wrócił z AFK"

Quiet hours and pings
- Controlled by `TIMEZONE`, `QUIET_HOURS_START` and `QUIET_HOURS_END` (supports intervals crossing midnight).
- If `PING_ROLE_ID` is set and not in quiet hours, the relay may ping the role for critical events (see `PING_ON_CRITICAL_ONLY`). During quiet hours no pings are issued.

Reliability
- Network operations have retries with exponential backoff.
- Identical messages are rate-limited (won't be sent more often than once per 10s).

Files
- `src/relay.js` – main program
- `.env.example` – example env vars
- `package.json` – dependencies

Questions or improvements
- You can extend event->severity mapping or add richer Discord embeds. If you want, I can add metrics, Prometheus, or a Dockerfile.
