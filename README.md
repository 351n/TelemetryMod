# TelemetryMod

TelemetryMod exports events from a running Factorio game or server as JSON. Use it to build integrations such as Discord notifications or OBS scene and source controls. It reports player activity, deaths, research, evolution and optional programmable-speaker alerts; other mods can emit notifications through its remote interface.

The mod provides three independently configurable outputs:

- **JSONL** — a bounded snapshot written to `script-output/telemetry.jsonl`; enabled by default.
- **UDP** — one best-effort datagram per event, sent to a localhost receiver.
- **RCON** — an on-demand snapshot of recent events through `/telemetry-export [limit]`.

## Requirements and installation

- TelemetryMod **0.3.0** targets Factorio **2.1** and has been tested on 2.1.24. For Factorio **2.0.76–2.0.x**, use version **0.2.0**.
- Install the release ZIP in Factorio's `mods` directory and enable it in the game. See the [mod README](mod/telemetry-mod/README.md) for installation, settings and transport details.
- The integration examples require Node.js **20 or later** and their own dependencies. Discord examples need a webhook; the OBS example needs a local OBS WebSocket server.

## Quick start

1. Install and enable the mod. JSONL output is active by default; enable UDP or RCON in the mod's runtime-global settings if needed.
2. Choose an integration in the [examples overview](examples/README.md) and follow its setup instructions. Copy its example configuration into a local file and keep credentials private.
3. For UDP, start Factorio with `--enable-lua-udp=34198` and configure the receiver on a separate port, `34199` by default. Factorio and the UDP receiver must run on the same host.

The examples include [Discord over JSONL](examples/discord-jsonl/README.md), [Discord over RCON](examples/discord-rcon/README.md), [Discord over UDP](examples/discord-udp/README.md) and [OBS over UDP](examples/obs/README.md). The OBS and Discord UDP examples cannot listen on the same port simultaneously; use a different transport for Discord if both integrations are needed.

UDP and the examples are best-effort integrations, not guaranteed-delivery queues. JSONL and RCON consumers establish an initial baseline and may miss events when snapshot overlap is lost. See the [examples overview](examples/README.md) for limitations.

## Development and releases

Run `npm test` in `examples/` and `examples/obs/` after installing each directory's dependencies. The [release checklist](mod/RELEASE_CHECKLIST.md) covers isolated Factorio tests, save compatibility and ZIP packaging; the [portal description](mod/MOD_PORTAL.md) is maintained separately.

The mod and repository examples are released under [The Unlicense](LICENSE). Dependencies retain their own licenses.
