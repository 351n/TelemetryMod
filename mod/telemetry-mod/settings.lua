data:extend({
  {
    type = "string-setting",
    name = "telemetry-log-file",
    setting_type = "runtime-global",
    default_value = "telemetry.jsonl",
    allow_blank = false,
    order = "a"
  },
  {
    type = "bool-setting",
    name = "telemetry-output-jsonl-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a-a"
  },
  {
    type = "bool-setting",
    name = "telemetry-output-udp-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "a-b"
  },
  {
    type = "int-setting",
    name = "telemetry-udp-port",
    setting_type = "runtime-global",
    default_value = 34199,
    minimum_value = 1,
    maximum_value = 65535,
    order = "a-c"
  },
  {
    type = "bool-setting",
    name = "telemetry-output-rcon-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "a-d"
  },
  {
    type = "int-setting",
    name = "telemetry-rcon-window-events",
    setting_type = "runtime-global",
    default_value = 100,
    minimum_value = 1,
    maximum_value = 1000,
    order = "a-e"
  },
  {
    type = "int-setting",
    name = "telemetry-afk-interval-seconds",
    setting_type = "runtime-global",
    default_value = 15,
    minimum_value = 1,
    maximum_value = 3600,
    order = "b"
  },
  {
    type = "bool-setting",
    name = "telemetry-debug",
    setting_type = "runtime-global",
    default_value = false,
    order = "c"
  },
  {
    type = "bool-setting",
    name = "telemetry-debug-afk",
    setting_type = "runtime-global",
    default_value = false,
    order = "d"
  },
  {
    type = "bool-setting",
    name = "telemetry-afk-info-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "d-a"
  },
  {
    type = "int-setting",
    name = "telemetry-afk-info-threshold-seconds",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 10,
    maximum_value = 86400,
    order = "d-b"
  },
  {
    type = "int-setting",
    name = "telemetry-max-bytes",
    setting_type = "runtime-global",
    default_value = 51200,
    minimum_value = 1024,
    maximum_value = 10485760,
    order = "e"
  },
  {
    type = "int-setting",
    name = "telemetry-max-age-seconds",
    setting_type = "runtime-global",
    default_value = 86400,
    minimum_value = 1,
    maximum_value = 31536000,
    order = "f"
  },
  {
    type = "bool-setting",
    name = "telemetry-evolution-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "e-a"
  },
  {
    type = "int-setting",
    name = "telemetry-evolution-interval-seconds",
    setting_type = "runtime-global",
    default_value = 10,
    minimum_value = 1,
    maximum_value = 3600,
    order = "e-b"
  },
  {
    type = "double-setting",
    name = "telemetry-evolution-min-delta",
    setting_type = "runtime-global",
    default_value = 0.01,
    minimum_value = 0,
    maximum_value = 1,
    order = "e-c"
  },
  {
    type = "bool-setting",
    name = "telemetry-evolution-include-dominance",
    setting_type = "runtime-global",
    default_value = true,
    order = "e-d"
  },
  {
    type = "bool-setting",
    name = "telemetry-evolution-notify-chat",
    setting_type = "runtime-global",
    default_value = true,
    order = "e-e"
  },
  {
    type = "string-setting",
    name = "telemetry-evolution-surface-names",
    setting_type = "runtime-global",
    default_value = "nauvis",
    allow_blank = false,
    order = "e-f"
  },
  {
    type = "string-setting",
    name = "telemetry-evolution-force-name",
    setting_type = "runtime-global",
    default_value = "enemy",
    allow_blank = false,
    order = "e-g"
  },
  {
    type = "bool-setting",
    name = "telemetry-speaker-notify-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "e-h"
  },
  {
    type = "int-setting",
    name = "telemetry-speaker-notify-interval-seconds",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 1,
    maximum_value = 3600,
    order = "e-i"
  },
  {
    type = "int-setting",
    name = "telemetry-speaker-notify-cooldown-seconds",
    setting_type = "runtime-global",
    default_value = 60,
    minimum_value = 1,
    maximum_value = 86400,
    order = "e-j"
  },
  {
    type = "int-setting",
    name = "telemetry-speaker-notify-max-events-per-poll",
    setting_type = "runtime-global",
    default_value = 5,
    minimum_value = 1,
    maximum_value = 100,
    order = "e-k"
  }
})
