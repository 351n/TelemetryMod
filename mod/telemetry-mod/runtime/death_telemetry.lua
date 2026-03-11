-- Backward-compatible shim:
-- keep old require path (`runtime.death_telemetry`) working after moving
-- event handlers under `runtime/events/`.
return require("runtime.events.death")
