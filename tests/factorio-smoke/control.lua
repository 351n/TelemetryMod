-- Runtime smoke checks for Telemetry Mod outputs. Runs only in an isolated test save.

if not global and storage then global = storage end

local outputs = require("__telemetry-mod__.runtime.telemetry_outputs")

local function expect(condition, message)
  if not condition then error("TELEMETRY_SMOKE failed: " .. message) end
end

local function run_output_unit_checks()
  local tick = 100
  local config = {
    log_file = "unit.jsonl",
    max_bytes = 1024,
    max_age_seconds = 60,
    default_max_bytes = 1024,
    default_max_age_seconds = 60,
    jsonl_enabled = true,
    udp_enabled = false,
    udp_port = 34199,
    rcon_enabled = false,
    rcon_window_events = 10
  }
  local writes, packets, warnings = {}, {}, {}
  local udp_fails = false
  local jsonl_fails = false
  global.telemetry_buffer = nil

  local router = outputs.new({
    write_file_safe = function(filename, content, append)
      writes[#writes + 1] = { filename = filename, content = content, append = append }
      if jsonl_fails then return false, "test JSONL failure" end
      return true
    end,
    send_udp_safe = function(port, payload)
      if udp_fails then return false, "test UDP failure" end
      packets[#packets + 1] = { port = port, payload = payload }
      return true
    end,
    get_config = function() return config end,
    get_tick = function() return tick end,
    warning_log = function(message) warnings[#warnings + 1] = message end
  })

  expect(router.record('{"type":"alpha"}') == true, "JSONL/RCON record")
  expect(#writes == 1 and writes[1].content == '{"type":"alpha"}\n', "JSONL payload")
  expect(router.rcon_response(10):find('"error":"rcon-disabled"', 1, true) ~= nil, "disabled RCON response")

  config.udp_enabled = true
  config.rcon_enabled = true
  jsonl_fails = true
  local ok, err = router.record('{"type":"jsonl-failure"}')
  expect(ok == false and err == "test JSONL failure", "JSONL error remains observable")
  expect(#packets == 1 and packets[1].payload == '{"type":"jsonl-failure"}', "UDP emits despite JSONL failure")
  expect(router.rcon_response(10):find('"type":"jsonl-failure"', 1, true) ~= nil, "RCON retains event despite JSONL failure")
  expect(#warnings == 1, "JSONL failure logged")
  router.record('{"type":"jsonl-failure-again"}')
  expect(#warnings == 1, "repeated JSONL failure not spammed")
  jsonl_fails = false
  expect(router.record('{"type":"jsonl-recovered"}') == true, "JSONL recovers")
  jsonl_fails = true
  router.record('{"type":"jsonl-failure-after-recovery"}')
  expect(#warnings == 2, "JSONL failure logged again after recovery")
  jsonl_fails = false
  writes, packets, warnings = {}, {}, {}

  config.jsonl_enabled = false
  config.rcon_enabled = false
  config.udp_enabled = true
  tick = tick + 1
  expect(router.record('{"type":"beta"}') == true, "UDP-only record")
  expect(#writes == 0, "UDP-only avoids file writes")
  expect(#packets == 1 and packets[1].port == 34199 and packets[1].payload == '{"type":"beta"}', "UDP payload")

  config.udp_enabled = false
  tick = tick + 1
  expect(router.record('{"type":"gamma"}') == true, "disabled outputs record")
  expect(#writes == 0 and #packets == 1, "disabled outputs are quiet")

  config.udp_enabled = true
  udp_fails = true
  tick = tick + 1
  expect(router.record('{"type":"delta"}') == true, "UDP failure is non-fatal")
  expect(#warnings == 1, "UDP failure is logged once")
  expect(router.record('{"type":"epsilon"}') == true and #warnings == 1, "same UDP failure is not spammed")

  udp_fails = false
  config.udp_enabled = false
  config.rcon_enabled = true
  config.rcon_window_events = 1
  config.max_bytes = 20
  global.telemetry_buffer = nil
  tick = tick + 1
  router.record('{"type":"first"}')
  tick = tick + 1
  router.record('{"type":"second"}')
  local snapshot = router.rcon_response(100)
  expect(snapshot:find('"type":"second"', 1, true) ~= nil, "RCON keeps newest event")
  expect(snapshot:find('"type":"first"', 1, true) == nil, "RCON limit and byte trimming")
end

script.on_init(function()
  run_output_unit_checks()
  local result = remote.call("telemetry_mod", "notify", {
    source = "smoke",
    severity = "warning",
    message = "output smoke event",
    surface = "nauvis",
    tags = { "smoke" }
  })
  expect(result and result.ok == true, "remote notify remains available")
  log("TELEMETRY_SMOKE PASS")
end)
