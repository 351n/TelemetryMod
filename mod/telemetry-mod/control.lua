-- Factorio 2.1 persistent mod state lives in the runtime `storage` table.
-- luacheck: globals game script remote defines rendering commands storage helpers log rcon

-- ...existing code...
-- telemetry-mod: runtime-only telemetry logger
-- Logs player join/leave and AFK polling to script-output/telemetry.jsonl as JSON Lines
-- Added optional debug output to server chat (game.print) and server log (log)

-- Defaults (will be overridden by runtime-global settings if present)
local DEFAULT_LOG_FILE = "telemetry.jsonl"
local DEFAULT_AFK_INTERVAL_SECONDS = 15
local DEFAULT_DEBUG = false
local DEFAULT_DEBUG_AFK = false
local DEFAULT_AFK_INFO_ENABLED = false
local DEFAULT_AFK_INFO_THRESHOLD_SECONDS = 300
local DEFAULT_AFK_INFO_RETURN_SECONDS = 60
local DEFAULT_MAX_BYTES = 50 * 1024 -- 50 KB
local DEFAULT_MAX_AGE_SECONDS = 24 * 60 * 60 -- 24 hours
local DEFAULT_JSONL_ENABLED = true
local DEFAULT_UDP_ENABLED = false
local DEFAULT_UDP_PORT = 34199
local DEFAULT_RCON_ENABLED = false
local DEFAULT_RCON_WINDOW_EVENTS = 100

-- Evolution telemetry + alerts
local DEFAULT_EVOLUTION_ENABLED = true
local DEFAULT_EVOLUTION_INTERVAL_SECONDS = 10
local DEFAULT_EVOLUTION_MIN_DELTA = 0.01 -- log when evolution changes at least this much
local DEFAULT_EVOLUTION_INCLUDE_DOMINANCE = true -- include "dominance change" thresholds
local DEFAULT_EVOLUTION_NOTIFY_CHAT = true -- emit chat/server messages on thresholds
local DEFAULT_EVOLUTION_FORCE_NAME = "enemy" -- which force to observe (usually "enemy")
local DEFAULT_EVOLUTION_SURFACE_NAME = "nauvis" -- which surface to observe for evolution
local DEFAULT_EVOLUTION_SURFACE_NAMES = "nauvis" -- comma/space-separated surface names
local DEFAULT_SPEAKER_NOTIFY_ENABLED = false
local DEFAULT_SPEAKER_NOTIFY_INTERVAL_SECONDS = 5
local DEFAULT_SPEAKER_NOTIFY_COOLDOWN_SECONDS = 60
local DEFAULT_SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL = 5
local LOG_FILE = DEFAULT_LOG_FILE
local AFK_INTERVAL_TICKS = DEFAULT_AFK_INTERVAL_SECONDS * 60 -- ticks
local DEBUG = DEFAULT_DEBUG
local DEBUG_AFK = DEFAULT_DEBUG_AFK
local AFK_INFO_ENABLED = DEFAULT_AFK_INFO_ENABLED
local AFK_INFO_THRESHOLD_SECONDS = DEFAULT_AFK_INFO_THRESHOLD_SECONDS
local AFK_INFO_RETURN_SECONDS = DEFAULT_AFK_INFO_RETURN_SECONDS
local MAX_BYTES = DEFAULT_MAX_BYTES
local MAX_AGE_SECONDS = DEFAULT_MAX_AGE_SECONDS
local JSONL_ENABLED = DEFAULT_JSONL_ENABLED
local UDP_ENABLED = DEFAULT_UDP_ENABLED
local UDP_PORT = DEFAULT_UDP_PORT
local RCON_ENABLED = DEFAULT_RCON_ENABLED
local RCON_WINDOW_EVENTS = DEFAULT_RCON_WINDOW_EVENTS

local EVOLUTION_ENABLED = DEFAULT_EVOLUTION_ENABLED
local EVOLUTION_INTERVAL_TICKS = DEFAULT_EVOLUTION_INTERVAL_SECONDS * 60
local EVOLUTION_MIN_DELTA = DEFAULT_EVOLUTION_MIN_DELTA
local EVOLUTION_INCLUDE_DOMINANCE = DEFAULT_EVOLUTION_INCLUDE_DOMINANCE
local EVOLUTION_NOTIFY_CHAT = DEFAULT_EVOLUTION_NOTIFY_CHAT
local EVOLUTION_FORCE_NAME = DEFAULT_EVOLUTION_FORCE_NAME
local EVOLUTION_SURFACE_NAME = DEFAULT_EVOLUTION_SURFACE_NAME
local EVOLUTION_SURFACE_NAMES = { DEFAULT_EVOLUTION_SURFACE_NAME }
local EVOLUTION_SURFACE_NAMES_STR = DEFAULT_EVOLUTION_SURFACE_NAMES
local SPEAKER_NOTIFY_ENABLED = DEFAULT_SPEAKER_NOTIFY_ENABLED
local SPEAKER_NOTIFY_INTERVAL_TICKS = DEFAULT_SPEAKER_NOTIFY_INTERVAL_SECONDS * 60
local SPEAKER_NOTIFY_COOLDOWN_TICKS = DEFAULT_SPEAKER_NOTIFY_COOLDOWN_SECONDS * 60
local SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL = DEFAULT_SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL

-- Keep track of last registered nth_tick values so setting changes do not leave stale handlers behind.
local LAST_AFK_INTERVAL_TICKS = AFK_INTERVAL_TICKS
local LAST_EVOLUTION_INTERVAL_TICKS = EVOLUTION_INTERVAL_TICKS

local resolve_localised_or_request -- forward declaration
local emit_external_notify -- forward declaration

local common = require("runtime.common")
local evolution_runtime = require("runtime.evolution_thresholds")
local notify_runtime = require("runtime.events.notify")
local join_event_runtime = require("runtime.events.join")
local leave_event_runtime = require("runtime.events.leave")
local desync_event_runtime = require("runtime.events.desync")
local afk_event_runtime = require("runtime.events.afk")
local evolution_event_runtime = require("runtime.events.evolution")
local speaker_notify_runtime = require("runtime.events.speaker_notify")
local speaker_gui_runtime = require("runtime.events.speaker_gui")
local write_backend_runtime = require("runtime.write_backend")
local udp_backend_runtime = require("runtime.udp_backend")
local telemetry_outputs_runtime = require("runtime.telemetry_outputs")
local translation_runtime = require("runtime.translation_runtime")
local death_telemetry_runtime = require("runtime.events.death")
local research_telemetry_runtime = require("runtime.events.research")
local lifecycle_runtime = require("runtime.lifecycle")

local escape_json_string = common.escape_json_string
local is_localised = common.is_localised
local localised_fallback = common.localised_fallback
local fmt_pct01 = common.fmt_pct01
local notify_api = nil
local join_event_api = nil
local leave_event_api = nil
local desync_event_api = nil
local afk_event_api = nil
local evolution_event_api = nil
local speaker_notify_api = nil
local speaker_gui_api = nil
local telemetry_writer = nil
local translation_api = nil
local death_telemetry_api = nil
local research_telemetry_api = nil
local lifecycle_api = nil

local function with_prefix(message)
  return common.with_prefix(message, "telemetry-mod.prefix")
end

local function parse_surface_list(raw)
  return common.parse_surface_list(raw, DEFAULT_EVOLUTION_SURFACE_NAME)
end

local function ensure_notify_state()
  if not storage then return nil end
  storage.telemetry_notify_state = storage.telemetry_notify_state or {}
  local st = storage.telemetry_notify_state
  st.speakers = st.speakers or {}
  st.speaker_enabled = st.speaker_enabled or {}
  st.speaker_gui_players = st.speaker_gui_players or {}
  return st
end

local function get_speaker_enabled(unit_key)
  local key = tostring(unit_key or "")
  if key == "" then return false end
  local st = ensure_notify_state()
  if not st then return false end
  return st.speaker_enabled[key] == true
end

local function set_speaker_enabled(unit_key, enabled)
  local key = tostring(unit_key or "")
  if key == "" then return end
  local st = ensure_notify_state()
  if not st then return end
  if enabled == true then
    st.speaker_enabled[key] = true
  else
    st.speaker_enabled[key] = nil
  end
end

local function prune_speaker_state(seen_units)
  local st = ensure_notify_state()
  if not st then return end
  if not seen_units then return end

  for unit_key, _ in pairs(st.speaker_enabled) do
    if not seen_units[unit_key] then
      st.speaker_enabled[unit_key] = nil
    end
  end
end

local function safe_game_print(msg)
  if not DEBUG then return end
  pcall(function()
    if game and game.print then
      game.print(with_prefix(msg))
    end
  end)
end

local function safe_log(msg)
  if not DEBUG then return end
  pcall(function()
    -- global log() writes to factorio-current.log
    if log then
      log("[telemetry-mod] " .. localised_fallback(msg))
    end
  end)
end

local function safe_warning_log(message)
  pcall(function()
    if log then log("[telemetry-mod] " .. tostring(message)) end
  end)
end

-- Custom event raised when evolution crosses a threshold.
-- Other mods can subscribe via:
--   local id = remote.call("telemetry_mod","get_evolution_event_id")
--   script.on_event(id, function(e) ... end)
local EVOLUTION_THRESHOLD_EVENT_ID = script.generate_event_name()
local TELEMETRY_NOTIFY_EVENT_ID = script.generate_event_name()
local function get_observed_force()
  return evolution_runtime.get_observed_force(EVOLUTION_FORCE_NAME)
end

local get_force_evolution_factor = evolution_runtime.get_force_evolution_factor

local function get_threshold_list()
  return evolution_runtime.get_threshold_list(EVOLUTION_INCLUDE_DOMINANCE == true)
end

-- Remote interface for other mods / scripts
pcall(function()
  if remote and remote.add_interface then
    local exists = false
    pcall(function()
      if remote.interfaces and remote.interfaces["telemetry_mod"] then exists = true end
    end)
    if not exists then
      remote.add_interface("telemetry_mod", {
        get_evolution_event_id = function() return EVOLUTION_THRESHOLD_EVENT_ID end,
        get_notify_event_id = function() return TELEMETRY_NOTIFY_EVENT_ID end,
        get_enemy_evolution = function()
          local f = get_observed_force()
          if not f then return nil end
          return get_force_evolution_factor(f, EVOLUTION_SURFACE_NAME)
        end,
        get_evolution_config = function()
          return {
            enabled = EVOLUTION_ENABLED,
            interval_ticks = EVOLUTION_INTERVAL_TICKS,
            min_delta = EVOLUTION_MIN_DELTA,
            include_dominance = EVOLUTION_INCLUDE_DOMINANCE,
            notify_chat = EVOLUTION_NOTIFY_CHAT,
            force_name = EVOLUTION_FORCE_NAME,
            surface_names = EVOLUTION_SURFACE_NAMES_STR
          }
        end,
        get_evolution_thresholds = function()
          return get_threshold_list()
        end,
        notify = function(payload)
          if not emit_external_notify then
            return { ok = false, error = "notify backend not ready" }
          end
          local ok, err = emit_external_notify(payload, "remote")
          return { ok = ok, error = err }
        end
      })
    end
  end
end)

local write_backend = write_backend_runtime.new()
local write_file_safe = write_backend.write_file_safe
local udp_backend = udp_backend_runtime.new()
local send_udp_safe = udp_backend.send_udp_safe

local function ensure_telemetry_writer()
  if telemetry_writer then return telemetry_writer end
  telemetry_writer = telemetry_outputs_runtime.new({
    write_file_safe = write_file_safe,
    send_udp_safe = send_udp_safe,
    safe_game_print = safe_game_print,
    safe_log = safe_log,
    warning_log = safe_warning_log,
    get_tick = function()
      return (game and game.tick) or 0
    end,
    get_config = function()
      return {
        log_file = LOG_FILE,
        max_bytes = MAX_BYTES,
        max_age_seconds = MAX_AGE_SECONDS,
        jsonl_enabled = JSONL_ENABLED,
        udp_enabled = UDP_ENABLED,
        udp_port = UDP_PORT,
        rcon_enabled = RCON_ENABLED,
        rcon_window_events = RCON_WINDOW_EVENTS,
        default_max_bytes = DEFAULT_MAX_BYTES,
        default_max_age_seconds = DEFAULT_MAX_AGE_SECONDS
      }
    end
  })
  return telemetry_writer
end

local function write_json_line(line, suppress_debug)
  local writer = ensure_telemetry_writer()
  writer.record(line, suppress_debug)
end

local function ensure_notify_api()
  if notify_api then return notify_api end
  notify_api = notify_runtime.new({
    write_json_line = write_json_line,
    escape_json_string = escape_json_string,
    localised_fallback = localised_fallback,
    safe_log = safe_log,
    raise_event = function(data)
      if script and script.raise_event then
        script.raise_event(TELEMETRY_NOTIFY_EVENT_ID, {
          tick = data.tick,
          source = data.source,
          severity = data.severity,
          message = data.message,
          origin = data.origin,
          player = data.player,
          force = data.force,
          surface = data.surface,
          category = data.category,
          code = data.code,
          tags = data.tags
        })
      end
    end
  })
  return notify_api
end

emit_external_notify = function(payload, origin)
  local api = ensure_notify_api()
  return api.emit(payload, origin)
end

local function ensure_speaker_notify_api()
  if speaker_notify_api then return speaker_notify_api end
  speaker_notify_api = speaker_notify_runtime.new({
    emit_external_notify = function(payload, origin)
      if not emit_external_notify then
        return false, "notify backend not ready"
      end
      return emit_external_notify(payload, origin)
    end,
    localised_fallback = localised_fallback,
    safe_log = safe_log,
    is_speaker_enabled = get_speaker_enabled,
    prune_speaker_state = prune_speaker_state,
    get_config = function()
      return {
        enabled = SPEAKER_NOTIFY_ENABLED == true,
        interval_ticks = SPEAKER_NOTIFY_INTERVAL_TICKS,
        cooldown_ticks = SPEAKER_NOTIFY_COOLDOWN_TICKS,
        max_events_per_poll = SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL,
        default_interval_ticks = DEFAULT_SPEAKER_NOTIFY_INTERVAL_SECONDS * 60,
        default_cooldown_ticks = DEFAULT_SPEAKER_NOTIFY_COOLDOWN_SECONDS * 60,
        default_max_events_per_poll = DEFAULT_SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL
      }
    end
  })
  return speaker_notify_api
end

local function ensure_speaker_gui_api()
  if speaker_gui_api then return speaker_gui_api end
  speaker_gui_api = speaker_gui_runtime.new({
    get_speaker_enabled = get_speaker_enabled,
    set_speaker_enabled = set_speaker_enabled
  })
  return speaker_gui_api
end

-- Evolution telemetry (enemy evolution factor) ---------------------------------

local function ensure_evolution_event_api()
  if evolution_event_api then return evolution_event_api end
  evolution_event_api = evolution_event_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    fmt_pct01 = fmt_pct01,
    with_prefix = with_prefix,
    localised_fallback = localised_fallback,
    safe_log = safe_log,
    resolve_localised_or_request = function(localised_value, force_obj)
      if resolve_localised_or_request then
        return resolve_localised_or_request(localised_value, force_obj)
      end
      return localised_fallback(localised_value), nil
    end,
    raise_threshold_event = function(payload)
      pcall(function()
        if script and script.raise_event then
          script.raise_event(EVOLUTION_THRESHOLD_EVENT_ID, payload)
        end
      end)
    end,
    get_observed_force = get_observed_force,
    get_force_evolution_factor = get_force_evolution_factor,
    get_threshold_list = get_threshold_list,
    get_config = function()
      return {
        enabled = EVOLUTION_ENABLED,
        min_delta = EVOLUTION_MIN_DELTA,
        include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
        notify_chat = EVOLUTION_NOTIFY_CHAT == true,
        force_name = EVOLUTION_FORCE_NAME,
        surface_names = EVOLUTION_SURFACE_NAMES,
        default_surface_name = DEFAULT_EVOLUTION_SURFACE_NAME
      }
    end
  })
  return evolution_event_api
end

local function evolution_poll(event)
  ensure_evolution_event_api().evolution_poll(event)
end

local function safe_player_name_from_index(index)
  if not index then return "unknown" end
  local p = nil
  -- game.get_player may return nil if player disconnected; guard it
  if game and game.get_player then p = game.get_player(index) end
  if p and p.valid and p.name then
    return p.name
  else
    return "index:" .. tostring(index)
  end
end

-- Translation + death/research telemetry modules ------------------------------

local function ensure_translation_api()
  if translation_api then return translation_api end
  translation_api = translation_runtime.new({
    is_localised = is_localised,
    localised_fallback = localised_fallback
  })
  return translation_api
end

local function get_player_force_by_index(player_index)
  if not (game and player_index) then return nil end
  local p = game.get_player(player_index)
  if p and p.valid and p.force then
    return p.force
  end
  return nil
end

local function get_force_by_name(force_name)
  if not (game and game.forces and force_name and force_name ~= "") then return nil end
  return game.forces[force_name]
end

local function ensure_join_event_api()
  if join_event_api then return join_event_api end
  join_event_api = join_event_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line
  })
  return join_event_api
end

local function ensure_leave_event_api()
  if leave_event_api then return leave_event_api end
  leave_event_api = leave_event_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    safe_player_name_from_index = safe_player_name_from_index
  })
  return leave_event_api
end

local function ensure_desync_event_api()
  if desync_event_api then return desync_event_api end
  desync_event_api = desync_event_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    safe_player_name_from_index = safe_player_name_from_index
  })
  return desync_event_api
end

local function ensure_death_telemetry_api()
  if death_telemetry_api then return death_telemetry_api end
  death_telemetry_api = death_telemetry_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    safe_player_name_from_index = safe_player_name_from_index,
    get_player_force_by_index = get_player_force_by_index,
    translation_api = ensure_translation_api()
  })
  return death_telemetry_api
end

local function ensure_research_telemetry_api()
  if research_telemetry_api then return research_telemetry_api end
  research_telemetry_api = research_telemetry_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    safe_player_name_from_index = safe_player_name_from_index,
    get_force_by_name = get_force_by_name,
    translation_api = ensure_translation_api()
  })
  return research_telemetry_api
end

local function ensure_player_telemetry_apis()
  local tr = ensure_translation_api()
  local death_api = ensure_death_telemetry_api()
  local research_api = ensure_research_telemetry_api()
  tr.set_handlers({
    write_death_line = death_api.write_death_telemetry_line,
    write_research_line = research_api.write_research_telemetry_line,
    emit_threshold = function(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name)
      ensure_evolution_event_api().emit_threshold(
        tick,
        force_name,
        current_factor,
        th,
        direction,
        msg_string,
        msg_localised,
        surface_name,
        EVOLUTION_NOTIFY_CHAT == true,
        EVOLUTION_INCLUDE_DOMINANCE == true
      )
    end
  })
  return tr, death_api, research_api
end

resolve_localised_or_request = function(localised_value, force_obj)
  local tr = ensure_player_telemetry_apis()
  return tr.resolve_localised_or_request(localised_value, force_obj)
end

local function flush_stale_death_translations()
  local tr = ensure_player_telemetry_apis()
  tr.flush_stale_death_translations()
end

local function flush_stale_research_translations()
  local tr = ensure_player_telemetry_apis()
  tr.flush_stale_research_translations()
end

local function flush_stale_evolution_translations()
  local tr = ensure_player_telemetry_apis()
  tr.flush_stale_evolution_translations()
end

local function ensure_afk_event_api()
  if afk_event_api then return afk_event_api end
  afk_event_api = afk_event_runtime.new({
    escape_json_string = escape_json_string,
    write_json_line = write_json_line,
    with_prefix = with_prefix,
    get_config = function()
      return {
        debug_afk = DEBUG_AFK == true,
        afk_info_enabled = AFK_INFO_ENABLED == true,
        afk_info_threshold_seconds = AFK_INFO_THRESHOLD_SECONDS,
        afk_info_return_seconds = AFK_INFO_RETURN_SECONDS,
        default_afk_info_threshold_seconds = DEFAULT_AFK_INFO_THRESHOLD_SECONDS,
        default_afk_info_return_seconds = DEFAULT_AFK_INFO_RETURN_SECONDS
      }
    end,
    flush_stale_research_translations = flush_stale_research_translations,
    flush_stale_death_translations = flush_stale_death_translations,
    flush_stale_evolution_translations = flush_stale_evolution_translations
  })
  return afk_event_api
end

local function on_player_died(event)
  local _, death_api = ensure_player_telemetry_apis()
  death_api.on_player_died(event)
end

local function on_research_finished(event)
  local _, _, research_api = ensure_player_telemetry_apis()
  research_api.on_research_finished(event)
end

local function on_string_translated(event)
  local tr = ensure_player_telemetry_apis()
  tr.on_string_translated(event)
end
local function on_player_joined(event)
  ensure_join_event_api().on_player_joined(event)
end

local function on_player_left(event)
  ensure_leave_event_api().on_player_left(event)
end

local function on_pre_player_left(event)
  ensure_desync_event_api().on_pre_player_left(event)
end

local function afk_poll(event)
  ensure_afk_event_api().afk_poll(event)
end

local function on_tick(event)
  ensure_speaker_notify_api().on_tick(event)
end

local function on_gui_opened(event)
  ensure_speaker_gui_api().on_gui_opened(event)
end

local function on_gui_closed(event)
  ensure_speaker_gui_api().on_gui_closed(event)
end

local function on_gui_checked_state_changed(event)
  ensure_speaker_gui_api().on_gui_checked_state_changed(event)
end

local function on_entity_settings_pasted(event)
  ensure_speaker_gui_api().on_entity_settings_pasted(event)
end

local function ensure_runtime_state()
  if not storage then return end
  storage.telemetry_buffer = storage.telemetry_buffer or { entries = {}, total_bytes = 0 }
  storage.tech_translation_cache = storage.tech_translation_cache or {}
  storage.entity_translation_cache = storage.entity_translation_cache or {}
  storage.pending_research_translations = storage.pending_research_translations or {}
  storage.pending_death_translations = storage.pending_death_translations or {}
  storage.pending_evolution_translations = storage.pending_evolution_translations or {}
  storage.telemetry_afk_state = storage.telemetry_afk_state or {}
  ensure_notify_state()
  storage.telemetry_evolution = storage.telemetry_evolution or { last_checked_factor = nil, last_logged_factor = nil }
end

local function baseline_observed_evolution(trigger_name)
  ensure_evolution_event_api().baseline_observed_evolution(trigger_name)
end

local apply_settings -- forward declaration

-- Read runtime-global settings (if available) and apply them at runtime.
local function read_setting(name, def)
  if settings and settings.global and settings.global[name] ~= nil then
    return settings.global[name].value
  end
  return def
end

apply_settings = function()
  LOG_FILE = tostring(read_setting("telemetry-log-file", DEFAULT_LOG_FILE) or DEFAULT_LOG_FILE)
  JSONL_ENABLED = read_setting("telemetry-output-jsonl-enabled", DEFAULT_JSONL_ENABLED) == true
  UDP_ENABLED = read_setting("telemetry-output-udp-enabled", DEFAULT_UDP_ENABLED) == true
  UDP_PORT = math.max(1, math.min(65535, math.floor(tonumber(read_setting("telemetry-udp-port", DEFAULT_UDP_PORT)) or DEFAULT_UDP_PORT)))
  RCON_ENABLED = read_setting("telemetry-output-rcon-enabled", DEFAULT_RCON_ENABLED) == true
  RCON_WINDOW_EVENTS = math.max(1, math.min(1000, math.floor(tonumber(read_setting("telemetry-rcon-window-events", DEFAULT_RCON_WINDOW_EVENTS)) or DEFAULT_RCON_WINDOW_EVENTS)))

  -- AFK polling interval
  local secs = tonumber(read_setting("telemetry-afk-interval-seconds", DEFAULT_AFK_INTERVAL_SECONDS)) or DEFAULT_AFK_INTERVAL_SECONDS
  local new_afk_ticks = math.max(1, math.floor(secs)) * 60
  if LAST_AFK_INTERVAL_TICKS and LAST_AFK_INTERVAL_TICKS ~= new_afk_ticks then
    pcall(function() script.on_nth_tick(LAST_AFK_INTERVAL_TICKS, nil) end)
  end
  AFK_INTERVAL_TICKS = new_afk_ticks
  LAST_AFK_INTERVAL_TICKS = AFK_INTERVAL_TICKS

  DEBUG = read_setting("telemetry-debug", DEFAULT_DEBUG) == true
  DEBUG_AFK = read_setting("telemetry-debug-afk", DEFAULT_DEBUG_AFK) == true
  AFK_INFO_ENABLED = read_setting("telemetry-afk-info-enabled", DEFAULT_AFK_INFO_ENABLED) == true
  AFK_INFO_THRESHOLD_SECONDS = tonumber(read_setting("telemetry-afk-info-threshold-seconds", DEFAULT_AFK_INFO_THRESHOLD_SECONDS)) or DEFAULT_AFK_INFO_THRESHOLD_SECONDS

  -- max bytes and max age (seconds)
  MAX_BYTES = tonumber(read_setting("telemetry-max-bytes", DEFAULT_MAX_BYTES)) or DEFAULT_MAX_BYTES
  MAX_AGE_SECONDS = tonumber(read_setting("telemetry-max-age-seconds", DEFAULT_MAX_AGE_SECONDS)) or DEFAULT_MAX_AGE_SECONDS

  -- Re-register nth tick with updated interval
  script.on_nth_tick(AFK_INTERVAL_TICKS, afk_poll)

  -- Evolution telemetry + alerts
  local old_force_name = EVOLUTION_FORCE_NAME
  EVOLUTION_ENABLED = read_setting("telemetry-evolution-enabled", DEFAULT_EVOLUTION_ENABLED) == true
  local evo_secs = tonumber(read_setting("telemetry-evolution-interval-seconds", DEFAULT_EVOLUTION_INTERVAL_SECONDS)) or DEFAULT_EVOLUTION_INTERVAL_SECONDS
  local new_evo_ticks = math.max(1, math.floor(evo_secs)) * 60
  EVOLUTION_INTERVAL_TICKS = new_evo_ticks
  EVOLUTION_MIN_DELTA = tonumber(read_setting("telemetry-evolution-min-delta", DEFAULT_EVOLUTION_MIN_DELTA)) or DEFAULT_EVOLUTION_MIN_DELTA
  EVOLUTION_INCLUDE_DOMINANCE = read_setting("telemetry-evolution-include-dominance", DEFAULT_EVOLUTION_INCLUDE_DOMINANCE) == true
  EVOLUTION_NOTIFY_CHAT = read_setting("telemetry-evolution-notify-chat", DEFAULT_EVOLUTION_NOTIFY_CHAT) == true
  local old_surface_names_str = EVOLUTION_SURFACE_NAMES_STR
  EVOLUTION_SURFACE_NAMES_STR = tostring(read_setting("telemetry-evolution-surface-names", DEFAULT_EVOLUTION_SURFACE_NAMES) or DEFAULT_EVOLUTION_SURFACE_NAMES)
  EVOLUTION_SURFACE_NAMES = parse_surface_list(EVOLUTION_SURFACE_NAMES_STR)
  EVOLUTION_FORCE_NAME = tostring(read_setting("telemetry-evolution-force-name", DEFAULT_EVOLUTION_FORCE_NAME) or DEFAULT_EVOLUTION_FORCE_NAME)
  SPEAKER_NOTIFY_ENABLED = read_setting("telemetry-speaker-notify-enabled", DEFAULT_SPEAKER_NOTIFY_ENABLED) == true
  local speaker_interval_secs = tonumber(read_setting("telemetry-speaker-notify-interval-seconds", DEFAULT_SPEAKER_NOTIFY_INTERVAL_SECONDS)) or DEFAULT_SPEAKER_NOTIFY_INTERVAL_SECONDS
  SPEAKER_NOTIFY_INTERVAL_TICKS = math.max(1, math.floor(speaker_interval_secs)) * 60
  local speaker_cooldown_secs = tonumber(read_setting("telemetry-speaker-notify-cooldown-seconds", DEFAULT_SPEAKER_NOTIFY_COOLDOWN_SECONDS)) or DEFAULT_SPEAKER_NOTIFY_COOLDOWN_SECONDS
  SPEAKER_NOTIFY_COOLDOWN_TICKS = math.max(1, math.floor(speaker_cooldown_secs)) * 60
  local speaker_max_events = tonumber(read_setting("telemetry-speaker-notify-max-events-per-poll", DEFAULT_SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL)) or DEFAULT_SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL
  SPEAKER_NOTIFY_MAX_EVENTS_PER_POLL = math.max(1, math.floor(speaker_max_events))
  if storage and not SPEAKER_NOTIFY_ENABLED and storage.telemetry_notify_state then
    storage.telemetry_notify_state.speakers = {}
  end

  -- Avoid leaving stale nth_tick handlers behind
  if LAST_EVOLUTION_INTERVAL_TICKS and (LAST_EVOLUTION_INTERVAL_TICKS ~= EVOLUTION_INTERVAL_TICKS or not EVOLUTION_ENABLED) then
    pcall(function() script.on_nth_tick(LAST_EVOLUTION_INTERVAL_TICKS, nil) end)
  end
  LAST_EVOLUTION_INTERVAL_TICKS = EVOLUTION_INTERVAL_TICKS

  if EVOLUTION_ENABLED then
    script.on_nth_tick(EVOLUTION_INTERVAL_TICKS, evolution_poll)
  end

  -- If the observed force changed, baseline the evolution state (prevents retro-trigger spam).
  if storage and (old_force_name ~= EVOLUTION_FORCE_NAME or old_surface_names_str ~= EVOLUTION_SURFACE_NAMES_STR) then
    pcall(function()
      baseline_observed_evolution("config")
    end)
  end
end

local function telemetry_export_command(command)
  if command and command.player_index then
    local player = game and game.get_player(command.player_index)
    if player then player.print({ "telemetry-mod.rcon-player-only" }) end
    return
  end

  local response = ensure_telemetry_writer().rcon_response(command and command.parameter)
  pcall(function()
    if rcon and rcon.print then rcon.print(response) end
  end)
end

local function register_rcon_command()
  pcall(function()
    commands.add_command("telemetry-export", { "telemetry-mod.rcon-command-help" }, telemetry_export_command)
  end)
end

local function is_telemetry_setting(name)
  return string.find(name or "", "telemetry-") ~= nil
end

-- Apply settings on load
apply_settings()

local function ensure_lifecycle_api()
  if lifecycle_api then return lifecycle_api end
  lifecycle_api = lifecycle_runtime.new({
    handlers = {
      on_player_joined = on_player_joined,
      on_player_left = on_player_left,
      on_pre_player_left = on_pre_player_left,
      afk_poll = afk_poll,
      evolution_poll = evolution_poll,
      on_tick = on_tick,
      on_gui_opened = on_gui_opened,
      on_gui_closed = on_gui_closed,
      on_gui_checked_state_changed = on_gui_checked_state_changed,
      on_entity_settings_pasted = on_entity_settings_pasted,
      on_player_died = on_player_died,
      on_research_finished = on_research_finished,
      on_string_translated = on_string_translated
    },
    get_afk_interval_ticks = function() return AFK_INTERVAL_TICKS end,
    get_evolution_interval_ticks = function() return EVOLUTION_INTERVAL_TICKS end,
    ensure_runtime_state = ensure_runtime_state,
    baseline_init_evolution = function() baseline_observed_evolution("init") end,
    clear_log_file = function() return ensure_telemetry_writer().clear_jsonl_file() end,
    apply_settings = function() apply_settings() end,
    is_telemetry_setting = is_telemetry_setting,
    safe_game_print = safe_game_print,
    safe_log = safe_log
  })
  return lifecycle_api
end

ensure_lifecycle_api().register()
register_rcon_command()
