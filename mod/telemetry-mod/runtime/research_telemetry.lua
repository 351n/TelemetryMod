-- Backward-compatible shim:
-- keep old require path (`runtime.research_telemetry`) working after moving
-- event handlers under `runtime/events/`.
return require("runtime.events.research")
