-- Factorio 2.0+: persistent mod state lives in the `storage` table (it was called `global` before 2.0).
-- This mod code still uses `global` internally, so we alias it to `storage` when running on 2.0.
if not global and storage then global = storage end
-- luacheck: globals game script remote defines rendering commands global storage helpers log

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

-- Evolution telemetry + alerts
local DEFAULT_EVOLUTION_ENABLED = true
local DEFAULT_EVOLUTION_INTERVAL_SECONDS = 10
local DEFAULT_EVOLUTION_MIN_DELTA = 0.01 -- log when evolution changes at least this much
local DEFAULT_EVOLUTION_INCLUDE_DOMINANCE = true -- include "dominance change" thresholds
local DEFAULT_EVOLUTION_NOTIFY_CHAT = true -- emit chat/server messages on thresholds
local DEFAULT_EVOLUTION_FORCE_NAME = "enemy" -- which force to observe (usually "enemy")
local DEFAULT_EVOLUTION_SURFACE_NAME = "nauvis" -- which surface to observe for evolution
local DEFAULT_EVOLUTION_SURFACE_NAMES = "nauvis" -- comma/space-separated surface names
local LOG_FILE = DEFAULT_LOG_FILE
local AFK_INTERVAL_TICKS = DEFAULT_AFK_INTERVAL_SECONDS * 60 -- ticks
local DEBUG = DEFAULT_DEBUG
local DEBUG_AFK = DEFAULT_DEBUG_AFK
local AFK_INFO_ENABLED = DEFAULT_AFK_INFO_ENABLED
local AFK_INFO_THRESHOLD_SECONDS = DEFAULT_AFK_INFO_THRESHOLD_SECONDS
local AFK_INFO_RETURN_SECONDS = DEFAULT_AFK_INFO_RETURN_SECONDS
local MAX_BYTES = DEFAULT_MAX_BYTES
local MAX_AGE_SECONDS = DEFAULT_MAX_AGE_SECONDS

local EVOLUTION_ENABLED = DEFAULT_EVOLUTION_ENABLED
local EVOLUTION_INTERVAL_TICKS = DEFAULT_EVOLUTION_INTERVAL_SECONDS * 60
local EVOLUTION_MIN_DELTA = DEFAULT_EVOLUTION_MIN_DELTA
local EVOLUTION_INCLUDE_DOMINANCE = DEFAULT_EVOLUTION_INCLUDE_DOMINANCE
local EVOLUTION_NOTIFY_CHAT = DEFAULT_EVOLUTION_NOTIFY_CHAT
local EVOLUTION_FORCE_NAME = DEFAULT_EVOLUTION_FORCE_NAME
local EVOLUTION_SURFACE_NAME = DEFAULT_EVOLUTION_SURFACE_NAME
local EVOLUTION_SURFACE_NAMES = { DEFAULT_EVOLUTION_SURFACE_NAME }
local EVOLUTION_SURFACE_NAMES_STR = DEFAULT_EVOLUTION_SURFACE_NAMES

-- Keep track of last registered nth_tick values so setting changes do not leave stale handlers behind.
local LAST_AFK_INTERVAL_TICKS = AFK_INTERVAL_TICKS
local LAST_EVOLUTION_INTERVAL_TICKS = EVOLUTION_INTERVAL_TICKS

local resolve_localised_or_request -- forward declaration
local emit_external_notify -- forward declaration

local common = require("runtime.common")
local evolution_runtime = require("runtime.evolution_thresholds")
local notify_runtime = require("runtime.notify")
local write_backend_runtime = require("runtime.write_backend")
local jsonl_buffer_runtime = require("runtime.jsonl_buffer")

local escape_json_string = common.escape_json_string
local is_localised = common.is_localised
local localised_fallback = common.localised_fallback
local fmt_pct01 = common.fmt_pct01
local notify_api = nil
local telemetry_writer = nil

local function with_prefix(message)
  return common.with_prefix(message, "telemetry-mod.prefix")
end

local function parse_surface_list(raw)
  return common.parse_surface_list(raw, DEFAULT_EVOLUTION_SURFACE_NAME)
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

local function ensure_telemetry_writer()
  if telemetry_writer then return telemetry_writer end
  telemetry_writer = jsonl_buffer_runtime.new({
    write_file_safe = write_file_safe,
    safe_game_print = safe_game_print,
    safe_log = safe_log,
    get_tick = function()
      return (game and game.tick) or 0
    end,
    get_config = function()
      return {
        log_file = LOG_FILE,
        max_bytes = MAX_BYTES,
        max_age_seconds = MAX_AGE_SECONDS,
        default_max_bytes = DEFAULT_MAX_BYTES,
        default_max_age_seconds = DEFAULT_MAX_AGE_SECONDS
      }
    end
  })
  return telemetry_writer
end

local function write_json_line(line, suppress_debug)
  local writer = ensure_telemetry_writer()
  writer.write_json_line(line, suppress_debug)
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

-- Evolution telemetry (enemy evolution factor) ---------------------------------

local function write_evolution_telemetry_line(tick, trigger, force_name, evolution_factor, extra)
  extra = extra or {}
  local parts = {
    string.format('{"tick":%d,"type":"evolution","trigger":"%s","force":"%s","evolution_factor":%.6f',
      tick or ((game and game.tick) or 0),
      escape_json_string(trigger or "poll"),
      escape_json_string(force_name or (EVOLUTION_FORCE_NAME or "enemy")),
      tonumber(evolution_factor) or 0
    )
  }

  -- Optional fields (kept flat for easy downstream parsing)
  if extra.delta ~= nil then
    parts[#parts+1] = string.format(',"delta":%.6f', tonumber(extra.delta) or 0)
  end
  if extra.threshold ~= nil then
    parts[#parts+1] = string.format(',"threshold":%.6f', tonumber(extra.threshold) or 0)
  end
  if extra.threshold_kind ~= nil then
    parts[#parts+1] = string.format(',"threshold_kind":"%s"', escape_json_string(extra.threshold_kind))
  end
  if extra.threshold_key ~= nil then
    parts[#parts+1] = string.format(',"threshold_key":"%s"', escape_json_string(extra.threshold_key))
  end
  if extra.direction ~= nil then
    parts[#parts+1] = string.format(',"direction":"%s"', escape_json_string(extra.direction))
  end
  if extra.include_dominance ~= nil then
    parts[#parts+1] = string.format(',"include_dominance":%s', extra.include_dominance and "true" or "false")
  end
  if extra.message ~= nil then
    parts[#parts+1] = string.format(',"message":"%s"', escape_json_string(extra.message))
  end
  if extra.surface ~= nil then
    parts[#parts+1] = string.format(',"surface":"%s"', escape_json_string(extra.surface))
  end

  parts[#parts+1] = "}"
  write_json_line(table.concat(parts, ""))
end

local function raise_evolution_threshold_event(payload)
  pcall(function()
    if script and script.raise_event then
      script.raise_event(EVOLUTION_THRESHOLD_EVENT_ID, payload)
    end
  end)
end

local function ensure_evolution_state()
  if not global then return nil end
  global.telemetry_evolution = global.telemetry_evolution or {}
  local st = global.telemetry_evolution

  -- Migrate older single-surface format to per-surface map
  if st.last_checked_factor ~= nil or st.last_logged_factor ~= nil or st.unlogged_delta ~= nil or st.prev_poll_factor ~= nil then
    st.surfaces = st.surfaces or {}
    st.surfaces[DEFAULT_EVOLUTION_SURFACE_NAME] = {
      last_checked_factor = st.last_checked_factor,
      last_logged_factor = st.last_logged_factor,
      unlogged_delta = st.unlogged_delta or 0,
      prev_poll_factor = st.prev_poll_factor
    }
    st.last_checked_factor = nil
    st.last_logged_factor = nil
    st.unlogged_delta = nil
    st.prev_poll_factor = nil
  end

  st.surfaces = st.surfaces or {}
  return st
end

local function ensure_evolution_surface_state(surface_name)
  if not global then return nil end
  local st = ensure_evolution_state()
  if not st then return nil end
  st.surfaces = st.surfaces or {}
  st.surfaces[surface_name] = st.surfaces[surface_name] or {
    last_checked_factor = nil,
    last_logged_factor = nil,
    unlogged_delta = 0,
    prev_poll_factor = nil
  }
  return st.surfaces[surface_name]
end

local function emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name)
  -- Telemetry line (machine-readable + includes message for convenience)
  write_evolution_telemetry_line(tick, "threshold", force_name, current_factor, {
    threshold = th and th.value,
    threshold_kind = th and th.kind,
    threshold_key = th and th.key,
    direction = direction or "up",
    include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
    message = msg_string or "",
    surface = surface_name
  })

  -- Raise custom event for other mods to handle (they can ignore our message)
  raise_evolution_threshold_event({
    tick = tick,
    force_name = force_name,
    evolution_factor = current_factor,
    threshold = th and th.value,
    threshold_kind = th and th.kind,
    threshold_key = th and th.key,
    direction = direction or "up",
    include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
    message = msg_string or "",
    surface = surface_name
  })

  -- Built-in chat message (optional)
  if EVOLUTION_NOTIFY_CHAT and game and game.print and (msg_localised or (msg_string and msg_string ~= "")) then
    pcall(function()
      local pct = fmt_pct01(current_factor)
      local base = msg_localised or msg_string
      if surface_name and surface_name ~= "" and surface_name ~= DEFAULT_EVOLUTION_SURFACE_NAME then
        if pct then
          game.print(with_prefix({ "telemetry-mod.evolution-chat-surface", base, pct, surface_name }))
        else
          game.print(with_prefix({ "telemetry-mod.evolution-chat-surface-no-pct", base, surface_name }))
        end
      else
        if pct then
          game.print(with_prefix({ "telemetry-mod.evolution-chat", base, pct }))
        else
          game.print(with_prefix({ "telemetry-mod.evolution-chat-no-pct", base }))
        end
      end
    end)
  end
end

local function maybe_emit_threshold(th, force_obj, current_factor, direction, surface_name)
  local tick = (game and game.tick) or 0
  local force_name = (force_obj and force_obj.name) or (EVOLUTION_FORCE_NAME or "enemy")
  local msg_localised = th and th.message or ""

  local msg_string, pending = resolve_localised_or_request(msg_localised, force_obj)
  if pending then
    if not global then
      msg_string = localised_fallback(msg_localised)
      emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name)
      return
    end
    global.pending_evolution_translations = global.pending_evolution_translations or {}
    global.pending_evolution_translations[pending.id] = {
      tick = tick,
      request_tick = tick,
      force_name = force_name,
      surface = surface_name,
      evolution_factor = current_factor,
      threshold = th,
      direction = direction or "up",
      include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
      message_localised = msg_localised,
      locale = pending.locale,
      player_index = pending.player_index
    }
    return
  end

  emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name)
end

local function evolution_poll(event)
  if not game then return end
  if not EVOLUTION_ENABLED then return end

  local force_obj = get_observed_force()
  local thresholds = get_threshold_list()
  local min_delta = tonumber(EVOLUTION_MIN_DELTA) or 0

  for _, surface_name in ipairs(EVOLUTION_SURFACE_NAMES or { DEFAULT_EVOLUTION_SURFACE_NAME }) do
    local surface = nil
    if surface_name and game and game.surfaces then
      surface = game.surfaces[surface_name]
    end
    if surface then
      local raw_current = get_force_evolution_factor(force_obj, surface_name)
      local current = tonumber(raw_current) or 0
      local st = ensure_evolution_surface_state(surface_name)
      if not st then return end

      local last_checked = st.last_checked_factor
      if last_checked == nil then last_checked = current end

      -- Accumulate small changes between logs to avoid dropping slow evolution drift.
      st.unlogged_delta = st.unlogged_delta or 0
      local prev_poll = st.prev_poll_factor
      if prev_poll == nil then prev_poll = last_checked or current end
      local delta_since_prev = current - prev_poll
      st.prev_poll_factor = current
      st.unlogged_delta = st.unlogged_delta + delta_since_prev

      if math.abs(st.unlogged_delta) >= min_delta then
        write_evolution_telemetry_line(game.tick, "poll", force_obj.name, current, {
          delta = st.unlogged_delta,
          include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
          surface = surface_name
        })
        st.last_logged_factor = current
        st.unlogged_delta = 0
      else
        safe_log({ "telemetry-mod.evolution-poll-skipped" })
      end

      -- Threshold crossing detection
      if current >= last_checked then
        for i = 1, #thresholds do
          local th = thresholds[i]
          local v = th and th.value
          if v and last_checked < v and current >= v then
            maybe_emit_threshold(th, force_obj, current, "up", surface_name)
          end
        end
      else
        -- Evolution decreased (rare). Emit DOWN events for thresholds crossed downward (no chat by default).
        for i = #thresholds, 1, -1 do
          local th = thresholds[i]
          local v = th and th.value
          if v and last_checked >= v and current < v then
            -- Temporarily suppress chat if it's enabled (down events are usually noise)
            local old_chat = EVOLUTION_NOTIFY_CHAT
            EVOLUTION_NOTIFY_CHAT = false
            maybe_emit_threshold(th, force_obj, current, "down", surface_name)
            EVOLUTION_NOTIFY_CHAT = old_chat
          end
        end
      end

      st.last_checked_factor = current
    end
  end
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

local function get_disconnect_reason_name(reason_id)
  if reason_id == nil then return "unknown" end
  local reasons = nil
  pcall(function()
    if defines and defines.disconnect_reason then
      reasons = defines.disconnect_reason
    end
  end)
  if reasons then
    for name, value in pairs(reasons) do
      if value == reason_id then
        return tostring(name)
      end
    end
  end
  return tostring(reason_id)
end

-- Strict policy: treat only `desync_limit_reached` as a desync event.
local function is_desync_disconnect_reason(reason_id)
  local desync_reason_id = nil
  pcall(function()
    if defines and defines.disconnect_reason then
      desync_reason_id = defines.disconnect_reason.desync_limit_reached
    end
  end)
  if desync_reason_id == nil then return false end
  return reason_id == desync_reason_id
end

local function write_desync_telemetry_line(tick, player_name, reason_id)
  local safe_tick = tick or ((game and game.tick) or 0)
  local reason_name = get_disconnect_reason_name(reason_id)
  local line = string.format(
    '{"tick":%d,"type":"desync","player":"%s","reason":"%s","reason_id":%d}',
    safe_tick,
    escape_json_string(player_name or "unknown"),
    escape_json_string(reason_name),
    tonumber(reason_id) or -1
  )
  write_json_line(line)
end

-- Telemetry translation preferences (for human-readable names)
-- Default to English, fallback Polish if no English-speaking players are connected.
local PREFERRED_TLM_LOCALES = { "en", "pl" }
local DEFAULT_DEATH_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds
local DEFAULT_EVOLUTION_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds

local function tlm_locale_rank(loc)
  if not loc then return #PREFERRED_TLM_LOCALES + 1 end
  for i = 1, #PREFERRED_TLM_LOCALES do
    if loc == PREFERRED_TLM_LOCALES[i] then return i end
  end
  return #PREFERRED_TLM_LOCALES + 1
end

-- Pick a stable translator player:
-- 1) preferred locale order, 2) player name (A->Z), 3) smallest player index
-- If `force_obj` is provided, prefer players from that force, but fall back to any connected player.
local function pick_translator_player_tlm(force_obj)
  if not game or not game.connected_players then return nil end

  local function consider(best, p)
    if not (p and p.valid) then return best end
    local r = tlm_locale_rank(p.locale)
    local n = string.lower(tostring(p.name or ""))
    local idx = tonumber(p.index) or 0
    if (not best)
      or (r < best.r)
      or (r == best.r and n < best.n)
      or (r == best.r and n == best.n and idx < best.idx)
    then
      return { p = p, r = r, n = n, idx = idx }
    end
    return best
  end

  local best = nil
  -- First pass: same force (if specified)
  if force_obj then
    for _, p in pairs(game.connected_players) do
      if p and p.force == force_obj then
        best = consider(best, p)
      end
    end
  end
  -- Fallback: any force
  if not best then
    for _, p in pairs(game.connected_players) do
      best = consider(best, p)
    end
  end

  return best and best.p or nil
end

resolve_localised_or_request = function(localised_value, force_obj)
  if not is_localised(localised_value) then
    return tostring(localised_value), nil
  end
  local translator = pick_translator_player_tlm(force_obj)
  if translator and translator.valid and translator.request_translation then
    local id = nil
    local ok = pcall(function()
      id = translator.request_translation(localised_value)
    end)
    if ok and id then
      return nil, { id = id, locale = translator.locale, player_index = translator.index }
    end
  end
  return localised_fallback(localised_value), nil
end

local function get_entity_translation_cached(locale, entity_name)
  if not global or not locale or not entity_name then return nil end
  local cache = global.entity_translation_cache
  if cache and cache[locale] and cache[locale][entity_name] then
    return cache[locale][entity_name]
  end
  return nil
end

local function put_entity_translation_cached(locale, entity_name, translated)
  if not global or not locale or not entity_name or not translated then return end
  global.entity_translation_cache = global.entity_translation_cache or {}
  global.entity_translation_cache[locale] = global.entity_translation_cache[locale] or {}
  global.entity_translation_cache[locale][entity_name] = translated
end

-- Describe the cause of a player death in a robust way that tolerates mods.
local function describe_death_cause(event)
  local cause_name = nil
  local cause_localised = nil -- LocalisedString (needs client translation)
  local cause_type = nil
  local cause_force = nil
  local pos_x = nil
  local pos_y = nil
  local damage_type = nil

  -- damage type (LuaDamagePrototype)
  pcall(function()
    if event and event.damage_type and event.damage_type.name then
      damage_type = event.damage_type.name
    end
  end)

  -- event position (if provided by runtime)
  pcall(function()
    if event and event.position then
      pos_x = event.position.x
      pos_y = event.position.y
    end
  end)

  local cause = event and event.cause
  if cause then
    -- Most commonly a LuaEntity (userdata); access fields directly with pcall guards.
    pcall(function()
      if cause.valid == false then return end
      if cause.name then cause_name = cause.name end
      if cause.localised_name then cause_localised = cause.localised_name end
      if cause.type then cause_type = cause.type end
      if cause.force and cause.force.name then cause_force = cause.force.name end
      if (not pos_x) and cause.position then
        pos_x = cause.position.x
        pos_y = cause.position.y
      end
      -- If the killer is a character, include the owning player's name when possible.
      pcall(function()
        if cause_type == "character" and cause.player and cause.player.name then
          cause_name = "character:" .. tostring(cause.player.name)
        end
      end)
    end)

    -- Last resort fallback (avoid embedding "[LuaEntity: ...]" when we can)
    if not cause_name then
      cause_name = tostring(cause)
    end
  end

  return {
    cause_name = cause_name,
    cause_localised = cause_localised,
    cause_type = cause_type,
    cause_force = cause_force,
    damage_type = damage_type,
    pos_x = pos_x,
    pos_y = pos_y
  }
end

local function write_death_telemetry_line(tick, player_name, info, cause_localised_str)
  local pos_part = "null,null"
  if info and info.pos_x ~= nil and info.pos_y ~= nil then
    pos_part = tostring(info.pos_x) .. "," .. tostring(info.pos_y)
  end

  local cause_name = (info and info.cause_name) or "unknown"
  local cause_loc = cause_localised_str or cause_name

  local line = string.format(
    '{"tick":%d,"type":"death","player":"%s","cause":"%s","cause_localised":"%s","cause_type":"%s","cause_force":"%s","damage_type":"%s","pos":[%s]}',
    tick or ((game and game.tick) or 0),
    escape_json_string(player_name or "unknown"),
    escape_json_string(cause_name),
    escape_json_string(cause_loc),
    escape_json_string((info and info.cause_type) or ""),
    escape_json_string((info and info.cause_force) or ""),
    escape_json_string((info and info.damage_type) or ""),
    pos_part
  )
  write_json_line(line)
end

-- Prevent losing death events if translation never arrives (disconnect, etc.)
local function flush_stale_death_translations()
  if not global or not global.pending_death_translations or not game or not game.tick then return end
  local now = game.tick
  local timeout = DEFAULT_DEATH_TRANSLATION_TIMEOUT_TICKS
  for id, meta in pairs(global.pending_death_translations) do
    if meta and meta.request_tick and (now - meta.request_tick) > timeout then
      -- Fallback: localised = internal name
      write_death_telemetry_line(meta.tick or now, meta.player, meta.info, meta.info and meta.info.cause_name)
      global.pending_death_translations[id] = nil
    end
  end
end

-- Prevent losing evolution threshold events if translation never arrives
local function flush_stale_evolution_translations()
  if not global or not global.pending_evolution_translations or not game or not game.tick then return end
  local now = game.tick
  local timeout = DEFAULT_EVOLUTION_TRANSLATION_TIMEOUT_TICKS
  for id, meta in pairs(global.pending_evolution_translations) do
    if meta and meta.request_tick and (now - meta.request_tick) > timeout then
      local msg_string = localised_fallback(meta.message_localised or "")
      emit_threshold(meta.tick or now, meta.force_name, meta.evolution_factor or 0, meta.threshold, meta.direction, msg_string, meta.message_localised, meta.surface)
      global.pending_evolution_translations[id] = nil
    end
  end
end

-- Log player death; enrich with cause name, position, and translated localised name when available.
local function on_player_died(event)
  local tick = (game and game.tick) or 0
  local player_name = safe_player_name_from_index(event and event.player_index)
  local info = describe_death_cause(event)

  -- If we still don't have a position, try the player's current position.
  if (info.pos_x == nil or info.pos_y == nil) and game and event and event.player_index then
    local p = game.get_player(event.player_index)
    pcall(function()
      if p and p.valid and p.position then
        info.pos_x = info.pos_x or p.position.x
        info.pos_y = info.pos_y or p.position.y
      end
    end)
  end

  -- Determine force (for a better default translator choice)
  local force_obj = nil
  if game and event and event.player_index then
    local p = game.get_player(event.player_index)
    if p and p.valid and p.force then force_obj = p.force end
  end

  local cause_name = info.cause_name or "unknown"

  -- Try to translate cause.localised_name via a connected player
  local translator = pick_translator_player_tlm(force_obj)
  if translator and translator.valid and translator.locale then
    local cached = get_entity_translation_cached(translator.locale, cause_name)
    if cached then
      write_death_telemetry_line(tick, player_name, info, cached)
      return
    end

    if info.cause_localised and translator.request_translation then
      global.pending_death_translations = global.pending_death_translations or {}
      local id = nil
      local ok = pcall(function()
        id = translator.request_translation(info.cause_localised)
      end)
      if ok and id then
        global.pending_death_translations[id] = {
          tick = tick,
          request_tick = tick,
          player = player_name,
          info = info,
          locale = translator.locale,
          player_index = translator.index
        }
        return -- will be written in on_string_translated (or via timeout flush)
      end
    end
  end

  -- Fallback: localised = internal name
  write_death_telemetry_line(tick, player_name, info, cause_name)
end
-- Log join event
 
-- Describe research event robustly (handles modded techs/forces)
local function describe_research_event(event)
  local tech_name = nil
  local tech_localised = nil -- LocalisedString (needs client translation)
  local force_name = nil
  local player_name = nil
  pcall(function()
    if event then
      if event.research then
        local r = event.research
        if r.name then tech_name = r.name end
        if r.localised_name then tech_localised = r.localised_name end
        if r.force and r.force.name then force_name = r.force.name end
      end
      -- some runtimes may provide shorthand fields
      if not tech_name and event.research_name then tech_name = event.research_name end
      if not force_name and event.force and event.force.name then force_name = event.force.name end
      if event.player_index then player_name = safe_player_name_from_index(event.player_index) end
    end
  end)
  return { technology = tech_name, technology_localised = tech_localised, force = force_name, player = player_name }
end

-- Translation + caching for technology localised names (headless-safe)
-- We translate via a connected player's locale (request_translation -> on_string_translated).
local PREFERRED_TECH_LOCALES = { "en", "pl" } -- default: English, fallback Polish
local DEFAULT_TECH_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds

local function locale_rank(loc)
  if not loc then return #PREFERRED_TECH_LOCALES + 1 end
  for i = 1, #PREFERRED_TECH_LOCALES do
    if loc == PREFERRED_TECH_LOCALES[i] then return i end
  end
  return #PREFERRED_TECH_LOCALES + 1
end

-- Pick a stable "translator" player:
-- 1) preferred locale order, 2) player name (A->Z), 3) smallest player index
local function pick_translator_player(force)
  if not game or not game.connected_players then return nil end
  local best = nil
  for _, p in pairs(game.connected_players) do
    if p and p.valid and ((not force) or p.force == force) then
      local r = locale_rank(p.locale)
      local n = string.lower(tostring(p.name or ""))
      local idx = tonumber(p.index) or 0
      if (not best)
        or (r < best.r)
        or (r == best.r and n < best.n)
        or (r == best.r and n == best.n and idx < best.idx)
      then
        best = { p = p, r = r, n = n, idx = idx }
      end
    end
  end
  return best and best.p or nil
end

local function get_tech_translation_cached(locale, tech_name)
  if not global or not locale or not tech_name then return nil end
  local cache = global.tech_translation_cache
  if cache and cache[locale] and cache[locale][tech_name] then
    return cache[locale][tech_name]
  end
  return nil
end

local function put_tech_translation_cached(locale, tech_name, translated)
  if not global or not locale or not tech_name or not translated then return end
  global.tech_translation_cache = global.tech_translation_cache or {}
  global.tech_translation_cache[locale] = global.tech_translation_cache[locale] or {}
  global.tech_translation_cache[locale][tech_name] = translated
end

local function write_research_telemetry_line(tick, tech_name, tech_localised, force_name, player_name)
  local safe_tick = tick or ((game and game.tick) or 0)
  local localised = tech_localised or tech_name or "unknown"
  local line = string.format(
    '{"tick":%d,"type":"research","technology":"%s","technology_localised":"%s","force":"%s","player":"%s"}',
    safe_tick,
    escape_json_string(tech_name or "unknown"),
    escape_json_string(localised),
    escape_json_string(force_name or ""),
    escape_json_string(player_name or "")
  )
  write_json_line(line)
end

-- Prevent losing research events if translation never arrives (disconnect, etc.)
local function flush_stale_research_translations()
  if not global or not global.pending_research_translations or not game or not game.tick then return end
  local now = game.tick
  local timeout = DEFAULT_TECH_TRANSLATION_TIMEOUT_TICKS
  for id, meta in pairs(global.pending_research_translations) do
    if meta and meta.request_tick and (now - meta.request_tick) > timeout then
      write_research_telemetry_line(meta.tick or now, meta.technology, meta.technology, meta.force, meta.player)
      global.pending_research_translations[id] = nil
    end
  end
end

-- Log technology researched/unlocked
local function on_research_finished(event)
  local info = describe_research_event(event)
  local tick = (game and game.tick) or 0

  local tech_name = info.technology or "unknown"
  local force_name = info.force or ""
  local player_name = info.player or ""

  -- Try to translate using a connected player (preferred locale order, then alphabetical).
  local force_obj = nil
  pcall(function()
    if event and event.research and event.research.force then force_obj = event.research.force end
    if (not force_obj) and game and game.forces and force_name ~= "" then force_obj = game.forces[force_name] end
  end)

  local translator = pick_translator_player(force_obj)
  if translator and translator.valid and translator.locale then
    local cached = get_tech_translation_cached(translator.locale, tech_name)
    if cached then
      write_research_telemetry_line(tick, tech_name, cached, force_name, player_name)
      return
    end

    if info.technology_localised and translator.request_translation then
      global.pending_research_translations = global.pending_research_translations or {}
      local id = nil
      local ok = pcall(function()
        id = translator.request_translation(info.technology_localised)
      end)
      if ok and id then
        global.pending_research_translations[id] = {
          tick = tick,
          request_tick = tick,
          technology = tech_name,
          force = force_name,
          player = player_name,
          locale = translator.locale,
          player_index = translator.index
        }
        return -- telemetry line will be written when on_string_translated arrives (or via timeout flush)
      end
    end
  end

  -- Fallback: log with localised = internal name
  write_research_telemetry_line(tick, tech_name, tech_name, force_name, player_name)
end

-- Receive translation results and emit research telemetry with technology_localised
local function on_string_translated(event)
  if not event or not global then return end

  -- Research translation results
  if global.pending_research_translations then
    local meta = global.pending_research_translations[event.id]
    if meta then
      global.pending_research_translations[event.id] = nil

      -- best-effort sanity check: ensure this is the same player we requested from
      if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
        return
      end

      local translated = meta.technology
      if event.translated and event.result then
        translated = event.result
        put_tech_translation_cached(meta.locale, meta.technology, translated)
      end

      write_research_telemetry_line(meta.tick, meta.technology, translated, meta.force, meta.player)
      return
    end
  end

  -- Death translation results (cause_localised)
  if global.pending_death_translations then
    local meta = global.pending_death_translations[event.id]
    if meta then
      global.pending_death_translations[event.id] = nil

      if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
        return
      end

      local info = meta.info or {}
      local cause_name = info.cause_name or "unknown"
      local translated = cause_name
      if event.translated and event.result then
        translated = event.result
        put_entity_translation_cached(meta.locale, cause_name, translated)
      end

      write_death_telemetry_line(meta.tick, meta.player, info, translated)
    end
  end

  -- Evolution threshold translation results (message)
  if global.pending_evolution_translations then
    local meta = global.pending_evolution_translations[event.id]
    if meta then
      global.pending_evolution_translations[event.id] = nil

      if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
        return
      end

      local msg_string = localised_fallback(meta.message_localised or "")
      if event.translated and event.result then
        msg_string = event.result
      end

      emit_threshold(meta.tick or ((game and game.tick) or 0), meta.force_name, meta.evolution_factor or 0, meta.threshold, meta.direction, msg_string, meta.message_localised, meta.surface)
    end
  end
end



-- Log join event
local function on_player_joined(event)
  local name = "unknown"
  if event and event.player_index then
    local p = game.get_player(event.player_index)
    if p and p.valid and p.name then
      name = p.name
    else
      name = "index:" .. tostring(event.player_index)
    end
  end
  local line = string.format('{"tick":%d,"type":"join","player":"%s"}',
    (game and game.tick) or 0, escape_json_string(name))
  write_json_line(line)
end

-- Log leave event (player may already be nil)
local function on_player_left(event)
  local name = safe_player_name_from_index(event and event.player_index)
  local line = string.format('{"tick":%d,"type":"leave","player":"%s"}',
    (game and game.tick) or 0, escape_json_string(name))
  write_json_line(line)
end

-- Detect strict desync case before the player fully leaves.
local function on_pre_player_left(event)
  local reason_id = event and event.reason
  if not is_desync_disconnect_reason(reason_id) then
    return
  end
  local name = safe_player_name_from_index(event and event.player_index)
  write_desync_telemetry_line((game and game.tick) or 0, name, reason_id)
end

-- AFK polling: iterate connected_players only
local function afk_poll(event)
  if not game then return end
  flush_stale_research_translations()
  flush_stale_death_translations()
  flush_stale_evolution_translations()
  for _, player in pairs(game.connected_players) do
    if player and player.valid then
      local afk_ticks = tonumber(player.afk_time) or 0
      local afk_seconds = math.floor(afk_ticks / 60)
      local line = string.format(
        '{"tick":%d,"type":"afk","player":"%s","afk_ticks":%d,"afk_seconds":%d}',
        game.tick,
        escape_json_string(player.name or "unknown"),
        afk_ticks,
        afk_seconds
      )
      -- suppress debug output for AFK lines unless explicitly enabled
      write_json_line(line, not DEBUG_AFK)

      if AFK_INFO_ENABLED and game and game.print then
        global.telemetry_afk_state = global.telemetry_afk_state or {}
        local st = global.telemetry_afk_state[player.index] or { is_afk = false }
        if (not st.is_afk) and afk_seconds >= (AFK_INFO_THRESHOLD_SECONDS or DEFAULT_AFK_INFO_THRESHOLD_SECONDS) then
          st.is_afk = true
          global.telemetry_afk_state[player.index] = st
          pcall(function()
            game.print(with_prefix({ "telemetry-mod.afk-on", player.name or "unknown", tostring(afk_seconds) }))
          end)
        elseif st.is_afk and afk_seconds <= (AFK_INFO_RETURN_SECONDS or DEFAULT_AFK_INFO_RETURN_SECONDS) then
          st.is_afk = false
          global.telemetry_afk_state[player.index] = st
          pcall(function()
            game.print(with_prefix({ "telemetry-mod.afk-off", player.name or "unknown" }))
          end)
        end
      end
    end
  end
end

-- Setup event registrations
script.on_event(defines.events.on_player_joined_game, on_player_joined)
script.on_event(defines.events.on_player_left_game, on_player_left)
pcall(function() script.on_event(defines.events.on_pre_player_left_game, on_pre_player_left) end)
script.on_nth_tick(AFK_INTERVAL_TICKS, afk_poll)
script.on_nth_tick(EVOLUTION_INTERVAL_TICKS, evolution_poll)
-- Register player death event (guarded handler)
pcall(function() script.on_event(defines.events.on_player_died, on_player_died) end)
-- Register research finished event (guarded)
pcall(function() script.on_event(defines.events.on_research_finished, on_research_finished) end)
-- Register string translation event (guarded)
pcall(function() script.on_event(defines.events.on_string_translated, on_string_translated) end)

-- Clear log file on init. Comment out the next line if you prefer to keep previous logs.
script.on_init(function()
  -- Initialize in-memory buffer persisted in `global` and try to clear the on-disk log.
  global.telemetry_buffer = { entries = {}, total_bytes = 0 }
  -- Translation state for research telemetry
  global.tech_translation_cache = global.tech_translation_cache or {}
  global.pending_research_translations = global.pending_research_translations or {}
  -- Translation state for evolution telemetry
  global.pending_evolution_translations = global.pending_evolution_translations or {}
  -- AFK info state
  global.telemetry_afk_state = global.telemetry_afk_state or {}
  -- Foundation for custom telemetry producers (remote notify/entity signals in future)
  global.telemetry_notify_state = global.telemetry_notify_state or {}
  -- Evolution telemetry state
  global.telemetry_evolution = global.telemetry_evolution or { last_checked_factor = nil, last_logged_factor = nil }
  pcall(function()
    local f = get_observed_force()
    if f and f.valid then
      -- Baseline to current factor to avoid "catch-up spam" after enabling the mod.
      ensure_evolution_state()
      for _, surface_name in ipairs(EVOLUTION_SURFACE_NAMES or { DEFAULT_EVOLUTION_SURFACE_NAME }) do
        local surface = game.surfaces[surface_name]
        if surface then
          local st = ensure_evolution_surface_state(surface_name)
          local current = tonumber(get_force_evolution_factor(f, surface_name)) or 0
          st.last_checked_factor = current
          st.last_logged_factor = current
          st.unlogged_delta = 0
          st.prev_poll_factor = current
          write_evolution_telemetry_line((game and game.tick) or 0, "init", f.name, current, {
            include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
            surface = surface_name
          })
        end
      end
    end
  end)

  -- Try to clear the log using available backend (overwrite=false to clear)
  local ok, err = write_file_safe(LOG_FILE, "", false)
  if ok then
    safe_game_print({ "telemetry-mod.init-cleared" })
    safe_log({ "telemetry-mod.init-cleared" })
  else
    -- If there's no backend, avoid noisy errors; still notify presence in chat when possible
    if err and err ~= "no write backend" then
      safe_log({ "telemetry-mod.init-write-failed", tostring(err) })
    end
    safe_game_print({ "telemetry-mod.init-no-backend" })
  end
end)

local apply_settings -- forward declaration

-- Ensure nth_tick is registered after a configuration change / load
script.on_configuration_changed(function(data)
  -- ensure translation state exists
  if global then
    global.tech_translation_cache = global.tech_translation_cache or {}
    global.pending_research_translations = global.pending_research_translations or {}
    global.telemetry_evolution = global.telemetry_evolution or { last_checked_factor = nil, last_logged_factor = nil }
    global.pending_evolution_translations = global.pending_evolution_translations or {}
    global.telemetry_afk_state = global.telemetry_afk_state or {}
    global.telemetry_notify_state = global.telemetry_notify_state or {}
  end

  -- Re-apply settings and re-register nth_tick handlers safely
  pcall(function()
    if apply_settings then apply_settings() end
  end)

  safe_game_print({ "telemetry-mod.config-changed" })
  safe_log({ "telemetry-mod.config-changed" })
end)

-- Read runtime-global settings (if available) and apply them at runtime.
local function read_setting(name, def)
  if settings and settings.global and settings.global[name] ~= nil then
    return settings.global[name].value
  end
  return def
end

apply_settings = function()
  LOG_FILE = tostring(read_setting("telemetry-log-file", DEFAULT_LOG_FILE) or DEFAULT_LOG_FILE)

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

  -- Avoid leaving stale nth_tick handlers behind
  if LAST_EVOLUTION_INTERVAL_TICKS and (LAST_EVOLUTION_INTERVAL_TICKS ~= EVOLUTION_INTERVAL_TICKS or not EVOLUTION_ENABLED) then
    pcall(function() script.on_nth_tick(LAST_EVOLUTION_INTERVAL_TICKS, nil) end)
  end
  LAST_EVOLUTION_INTERVAL_TICKS = EVOLUTION_INTERVAL_TICKS

  if EVOLUTION_ENABLED then
    script.on_nth_tick(EVOLUTION_INTERVAL_TICKS, evolution_poll)
  end

  -- If the observed force changed, baseline the evolution state (prevents retro-trigger spam).
  if global and (old_force_name ~= EVOLUTION_FORCE_NAME or old_surface_names_str ~= EVOLUTION_SURFACE_NAMES_STR) then
    pcall(function()
      local f = get_observed_force()
      if f and f.valid then
        ensure_evolution_state()
        for _, surface_name in ipairs(EVOLUTION_SURFACE_NAMES or { DEFAULT_EVOLUTION_SURFACE_NAME }) do
          local surface = game.surfaces[surface_name]
          if surface then
            local st = ensure_evolution_surface_state(surface_name)
            local current = tonumber(get_force_evolution_factor(f, surface_name)) or 0
            st.last_checked_factor = current
            st.last_logged_factor = current
            st.unlogged_delta = 0
            st.prev_poll_factor = current
            write_evolution_telemetry_line((game and game.tick) or 0, "config", f.name, current, {
              include_dominance = EVOLUTION_INCLUDE_DOMINANCE == true,
              surface = surface_name
            })
          end
        end
      end
    end)
  end
end

-- Apply settings on load
apply_settings()

-- React to runtime setting changes
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if not event or not event.setting then return end
  if string.find(event.setting, "telemetry-") then
    apply_settings()
    safe_game_print({ "telemetry-mod.settings-updated" })
    safe_log({ "telemetry-mod.settings-updated" })
  end
end)
