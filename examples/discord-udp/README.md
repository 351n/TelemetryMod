# Discord over UDP

Install dependencies from `examples/` with `npm install`. Copy `.env.example` to `.env`, set the webhook and run `node index.js` here. Run Factorio on the same machine with `--enable-lua-udp=34198`, enable the mod's UDP output and set its destination port to `34199` or the configured `UDP_PORT`. Source and destination ports must be different.

UDP events have no history and delivery is best-effort. The OBS UDP example cannot bind the same port concurrently; see [the examples overview](../README.md).
