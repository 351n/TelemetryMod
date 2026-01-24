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
  }
  ,
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
  }
})
