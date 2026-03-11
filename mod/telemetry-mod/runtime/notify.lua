-- Backward-compatible shim:
-- keep old require path (`runtime.notify`) working after moving event
-- handlers under `runtime/events/`.
return require("runtime.events.notify")
