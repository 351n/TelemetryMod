# Discord over RCON

Install dependencies from `examples/` with `npm install`. Copy `.env.example` to `.env`, set the webhook, RCON host, port and password, then run `node index.js` here. Enable the server's RCON interface and the mod's `telemetry-output-rcon-enabled` setting. Configure `RCON_LIMIT` no higher than the mod's RCON window; it defaults to 100. The first valid response is a baseline and is not sent.

RCON polls snapshots; it is not a push interface. Use a secure network path when connecting across hosts and see [the examples overview](../README.md) for overlap limitations.
