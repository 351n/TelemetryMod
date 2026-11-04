# Mod Portal listing — Telemetry Mod

This file is the publication copy for the Factorio Mod Portal. Keep it outside `telemetry-mod/`: it documents the release, but is not mod runtime content.

## Title

Telemetry Mod

## Short summary

Runtime telemetry for Factorio 2.1: compatible JSONL, localhost UDP, and on-demand RCON export.

## Full description

Telemetry Mod records small, stable JSON telemetry events from a running Factorio game or server. It is designed for operators and local integrations that need observable events without changing game prototypes. An opt-in checkbox in the programmable-speaker interface controls speaker telemetry.

### What it records

- Player join, leave, AFK, death, and strict desync events.
- Research and enemy-evolution updates, including threshold crossings.
- Programmable-speaker alerts when explicitly enabled per speaker.
- `notify` events emitted by other runtime mods through the stable `telemetry_mod` remote interface.

### Choose one, two, or all three outputs

- **JSONL** is enabled by default. It keeps the existing `script-output/telemetry.jsonl` contract, including one JSON object per line, so existing relays remain compatible.
- **UDP** is an optional best-effort localhost datagram for every event. It sends the same JSON object as JSONL, without the trailing newline. Start Factorio with `--enable-lua-udp=34198`; the receiver listens on the separately configured destination port (default `34199`).
- **RCON** is an optional pull interface. With RCON output enabled, run `/telemetry-export [limit]` through RCON to receive one JSON envelope containing the newest buffered events. It never pushes asynchronously and never consumes the buffer.

Each output is independently configurable at runtime. Turning JSONL off means the mod does not touch the telemetry file. UDP failures, a missing UDP startup flag, or an unavailable UDP API are contained: they are logged once and do not stop the game, JSONL, or RCON.

### Requirements and compatibility

- Factorio **2.1**; version 0.3.0 was tested on 2.1.24. For Factorio 2.0.76–2.0.x, use Telemetry Mod 0.2.0.
- No data stage changes and no required dependencies beyond base Factorio.
- UDP is deliberately localhost-only and requires the explicit Factorio startup flag above.
- RCON must be enabled and secured by the server operator. Treat exported telemetry as operator data.

### Configuration

Runtime-global settings control JSONL, UDP, and RCON independently:

- `telemetry-output-jsonl-enabled`
- `telemetry-output-udp-enabled`
- `telemetry-udp-port`
- `telemetry-output-rcon-enabled`
- `telemetry-rcon-window-events`

The shared in-memory buffer remains bounded by the existing event-age and byte limits. An RCON request can therefore return fewer events than its requested window.

### Source and support

Source code, installation notes, and issue reporting: <https://github.com/351n/TelemetryMod>

The mod and repository examples are released under The Unlicense; dependencies retain their own licenses.

## Suggested portal category

Utilities

## Upload checklist

- Upload `dist/telemetry-mod_<version>.zip` created by `mod/pack-mod.ps1`.
- Use `telemetry-mod/thumbnail.png` as the portal thumbnail.
- Paste the **Short summary** and **Full description** above into the portal fields.
- Confirm the published version and Factorio target match `telemetry-mod/info.json`.
- Run the isolated Factorio smoke test and inspect the ZIP before publishing.
