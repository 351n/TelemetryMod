# TelemetryMod integration examples

These are separate Node.js 20+ examples. Install the Discord dependencies once with `npm install` in `examples/`, then choose one input and follow its README:

- [Discord via JSONL over SFTP/FTP](discord-jsonl/README.md)
- [Discord via RCON](discord-rcon/README.md)
- [Discord via localhost UDP](discord-udp/README.md)
- [OBS via localhost UDP](obs/README.md) (install its own dependencies in `obs/`)

Copy each example's configuration template to its local `.env` or `config.json` and keep credentials private. Each Discord example stores its own `relay_state.json`; do not run multiple Discord examples for the same stream and webhook, as they can duplicate notifications.

The OBS and Discord UDP examples cannot both bind port 34199 at the same time. Use one UDP receiver and a different transport for Discord, such as RCON or JSONL.

Snapshot transports use longest suffix/prefix overlap. Factorio does not supply unique event identifiers: identical events and a fully pruned window can be ambiguous. On lost overlap or tick reset, the bridge logs a warning and sets a new baseline without replaying the window; some events can be lost. UDP is best-effort and has no history.

The Discord examples retry webhook failures, then log and drop the message; snapshot progress can advance even if delivery failed. They are non-critical examples, not a guaranteed-delivery queue. Automated tests use local test services; validate your own Factorio, Discord and OBS setup before relying on an integration.

Run `npm test` here for the Discord example tests, and run `npm test` in `obs/` for the OBS example tests. The repository's `scripts/test_factorio.ps1` additionally exercises Factorio → UDP → Discord bridge → a local test webhook; install these dependencies first. Real OBS, SFTP, FTP and Discord deployments still need their own end-to-end checks.

Repository examples are released under [The Unlicense](../LICENSE); dependencies retain their own licenses.
