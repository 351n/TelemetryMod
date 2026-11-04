# Telemetry OBS Bridge

A separate local Node.js 20+ process connects TelemetryMod UDP events to existing OBS scenes and sources. It does not create an overlay or change source content.

## Setup

1. In OBS Studio 28 or later, enable the WebSocket server under **Tools → WebSocket Server Settings** and set a password. Create the scenes and scene items you want to control.
2. Run `npm install` in this directory. Copy `config.example.json` to `config.json`, set the OBS URL and password, and enable and configure the desired actions. `config.json` is ignored by Git; do not commit credentials.
3. Start Factorio with `--enable-lua-udp=34198`. Enable `telemetry-output-udp-enabled` in the mod's runtime-global settings and set `telemetry-udp-port` to `34199`, matching the bridge's `udpPort`. The two ports have different roles: Factorio's source port is 34198; the bridge listens on 34199.
4. Run `npm start` from this directory (or `node src/index.js path/to/config.json`). Factorio, OBS and the bridge must run on the same host.

All actions are disabled by default. Set `actions.afk.player` to the exact player name, configure the AFK and return thresholds (the return threshold must be lower), and supply both scene names. The first AFK sample establishes the state without changing scenes. Later threshold crossings switch scenes.

For `death` and `research`, `scene` is the name of the OBS scene containing `source`, and `durationMs` is how long the source is shown. The bridge restores its previous visibility afterward; a repeated event extends the timer. Configure distinct scene items for the two alert types. Sources may be visible already; that visibility is preserved.

The bridge reconnects to OBS but does not queue disconnected events. If OBS disconnects or the bridge stops while an alert is visible, its pending restore is cancelled; check source visibility afterward. UDP is best-effort. Avoid other software binding the same UDP port.

Run `npm test` for the automated suite. With OBS running and configured, use a local UDP sender to send `{"type":"death","tick":1,"player":"PlayerName"}` to 127.0.0.1:34199 and verify the configured item appears and returns to its prior state. Repeat with `research` and use actual AFK samples for scene switching.
