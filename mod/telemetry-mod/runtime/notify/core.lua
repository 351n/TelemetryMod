-- Backward-compatible shim:
-- keep old require path (`runtime.notify.core`) working after moving
-- event handlers under `runtime/events/`.
return require("runtime.events.notify")
