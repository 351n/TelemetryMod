-- Factorio 2.0+: persistent mod state lives in the `storage` table (it was called `global` before 2.0).
-- This mod code still uses `global` internally, so we alias it to `storage` when running on 2.0.
if not global and storage then global = storage end

-- ...existing code...
-- telemetry-mod: runtime-only telemetry logger
-- Logs player join/leave and AFK polling to script-output/telemetry.jsonl as JSON Lines
-- Added optional debug output to server chat (game.print) and server log (log)

-- Defaults (will be overridden by runtime-global settings if present)
local DEFAULT_LOG_FILE = "telemetry.jsonl"
local DEFAULT_AFK_INTERVAL_SECONDS = 15
local DEFAULT_DEBUG = false
local DEFAULT_DEBUG_AFK = false
local DEFAULT_MAX_BYTES = 50 * 1024 -- 50 KB
local DEFAULT_MAX_AGE_SECONDS = 24 * 60 * 60 -- 24 hours

local LOG_FILE = DEFAULT_LOG_FILE
local AFK_INTERVAL_TICKS = DEFAULT_AFK_INTERVAL_SECONDS * 60 -- ticks
local DEBUG = DEFAULT_DEBUG
local DEBUG_AFK = DEFAULT_DEBUG_AFK
local MAX_BYTES = DEFAULT_MAX_BYTES
local MAX_AGE_SECONDS = DEFAULT_MAX_AGE_SECONDS

-- Escape minimal set of characters for safe JSON strings
local function escape_json_string(s)
  if s == nil then return "" end
  s = tostring(s)
  -- order matters: escape backslash first
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  return s
end

local function safe_game_print(msg)
  if not DEBUG then return end
  pcall(function()
    if game and game.print then
      game.print("[telemetry-mod] " .. tostring(msg))
    end
  end)
end

local function safe_log(msg)
  if not DEBUG then return end
  pcall(function()
    -- global log() writes to factorio-current.log
    if log then
      log("[telemetry-mod] " .. tostring(msg))
    end
  end)
end

-- Check once whether game.write_file is available in this runtime.
-- We wrap the check in pcall because indexing the userdata may throw on some runtimes.
-- Detect which write_file backend is available in this runtime.
-- Factorio 2.0 moved write_file to `helpers.write_file`; older runtimes used `game.write_file`.
-- We detect once and cache the backend in WRITE_BACKEND.
local WRITE_BACKEND = nil -- "helpers", "game", or false
local function detect_write_backend()
  if WRITE_BACKEND ~= nil then
    return WRITE_BACKEND
  end
  -- Check helpers.write_file first (Factorio 2.0+)
  local ok, result = pcall(function()
    return (helpers ~= nil) and (type(helpers.write_file) == "function")
  end)
  if ok and result then
    WRITE_BACKEND = "helpers"
    return WRITE_BACKEND
  end
  -- Fallback: check game.write_file (older runtimes)
  ok, result = pcall(function()
    return (game ~= nil) and (type(game.write_file) == "function")
  end)
  if ok and result then
    WRITE_BACKEND = "game"
    return WRITE_BACKEND
  end
  WRITE_BACKEND = false
  return WRITE_BACKEND
end

local function write_file_safe(filename, content, append)
  local backend = detect_write_backend()
  if not backend then
    return false, "no write backend"
  end
  if backend == "helpers" then
    local ok, err = pcall(function()
      helpers.write_file(filename, content, append)
    end)
    return ok, err
  elseif backend == "game" then
    local ok, err = pcall(function()
      game.write_file(filename, content, append)
    end)
    return ok, err
  end
  return false, "unsupported backend"
end

local function write_json_line(line, suppress_debug)
  -- Append a single JSON line (ensure newline at end)
  -- suppress_debug = true means do NOT emit chat/log debug for this write
  suppress_debug = (suppress_debug == true)
  -- Buffer the line in memory (persisted in `global`) and flush the buffer
  -- by overwriting the file. This lets us bound the file by size and age.
  if not global then
    -- if global storage unavailable, fall back to best-effort direct write
    local ok, err = write_file_safe(LOG_FILE, line .. "\n", true)
    if ok then
      if not suppress_debug then
        safe_game_print("wrote telemetry line")
        safe_log("wrote telemetry line: " .. line)
      end
    else
      if err and err ~= "no write backend" then
        safe_log("failed to write telemetry line: " .. tostring(err))
      end
    end
    return
  end

  -- Ensure buffer structure
  global.telemetry_buffer = global.telemetry_buffer or { entries = {}, total_bytes = 0 }
  local entry = { line = line, tick = (game and game.tick) or 0, bytes = (#line + 1) }
  table.insert(global.telemetry_buffer.entries, entry)
  global.telemetry_buffer.total_bytes = (global.telemetry_buffer.total_bytes or 0) + entry.bytes

  -- Prune by age (ticks) and by size (bytes)
  local function prune_buffer()
    local entries = global.telemetry_buffer.entries
    if not entries then return end
    local max_age_ticks = (MAX_AGE_SECONDS or DEFAULT_MAX_AGE_SECONDS) * 60
    local cutoff_tick = nil
    if game and game.tick and max_age_ticks and max_age_ticks > 0 then
      cutoff_tick = game.tick - max_age_ticks
    end
    -- drop entries older than cutoff
    while #entries > 0 do
      local e = entries[1]
      if cutoff_tick and e.tick < cutoff_tick then
        global.telemetry_buffer.total_bytes = global.telemetry_buffer.total_bytes - e.bytes
        table.remove(entries, 1)
      else
        break
      end
    end
    -- drop oldest until under size limit
    local max_bytes = MAX_BYTES or DEFAULT_MAX_BYTES
    while global.telemetry_buffer.total_bytes > max_bytes and #entries > 0 do
      local e = table.remove(entries, 1)
      global.telemetry_buffer.total_bytes = global.telemetry_buffer.total_bytes - e.bytes
    end
  end

  prune_buffer()

  -- Flush buffer by overwriting the log file with all kept lines
  local function flush_buffer_to_file()
    local entries = global.telemetry_buffer.entries
    if not entries then return end
    local content = ""
    for i = 1, #entries do
      content = content .. entries[i].line .. "\n"
    end
    local ok, err = write_file_safe(LOG_FILE, content, false)
    if ok then
      if not suppress_debug then
        safe_game_print("wrote telemetry buffer (" .. tostring(#entries) .. " lines)")
        safe_log("wrote telemetry buffer, bytes=" .. tostring(global.telemetry_buffer.total_bytes))
      end
    else
      if err and err ~= "no write backend" then
        safe_log("failed to write telemetry buffer: " .. tostring(err))
      end
    end
  end

  flush_buffer_to_file()
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

-- Telemetry translation preferences (for human-readable names)
-- Default to English, fallback Polish if no English-speaking players are connected.
local PREFERRED_TLM_LOCALES = { "en", "pl" }
local DEFAULT_DEATH_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds

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
    if not meta then return end
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

-- AFK polling: iterate connected_players only
local function afk_poll(event)
  if not game then return end
  flush_stale_research_translations()
  flush_stale_death_translations()
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
    end
  end
end

-- Setup event registrations
script.on_event(defines.events.on_player_joined_game, on_player_joined)
script.on_event(defines.events.on_player_left_game, on_player_left)
script.on_nth_tick(AFK_INTERVAL_TICKS, afk_poll)
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
  -- Try to clear the log using available backend (overwrite=false to clear)
  local ok, err = write_file_safe(LOG_FILE, "", false)
  if ok then
    safe_game_print("telemetry-mod initialized; telemetry log cleared")
    safe_log("telemetry-mod initialized; telemetry log cleared")
  else
    -- If there's no backend, avoid noisy errors; still notify presence in chat when possible
    if err and err ~= "no write backend" then
      safe_log("telemetry-mod init: write_file failed: " .. tostring(err))
    end
    safe_game_print("telemetry-mod initialized (write_file may be unavailable on this runtime)")
  end
end)

-- Ensure nth_tick is registered after a configuration change / load
script.on_configuration_changed(function(data)
  -- re-register nth tick to be safe after mod updates
  script.on_nth_tick(AFK_INTERVAL_TICKS, afk_poll)
  -- ensure translation state exists
  global.tech_translation_cache = global.tech_translation_cache or {}
  global.pending_research_translations = global.pending_research_translations or {}
  safe_game_print("telemetry-mod configuration changed; nth_tick re-registered")
  safe_log("telemetry-mod configuration changed")
end)

-- Read runtime-global settings (if available) and apply them at runtime.
local function read_setting(name, def)
  if settings and settings.global and settings.global[name] ~= nil then
    return settings.global[name].value
  end
  return def
end

local function apply_settings()
  LOG_FILE = tostring(read_setting("telemetry-log-file", DEFAULT_LOG_FILE) or DEFAULT_LOG_FILE)
  local secs = tonumber(read_setting("telemetry-afk-interval-seconds", DEFAULT_AFK_INTERVAL_SECONDS)) or DEFAULT_AFK_INTERVAL_SECONDS
  AFK_INTERVAL_TICKS = math.max(1, math.floor(secs)) * 60
  DEBUG = read_setting("telemetry-debug", DEFAULT_DEBUG) == true
  DEBUG_AFK = read_setting("telemetry-debug-afk", DEFAULT_DEBUG_AFK) == true

  -- max bytes and max age (seconds)
  MAX_BYTES = tonumber(read_setting("telemetry-max-bytes", DEFAULT_MAX_BYTES)) or DEFAULT_MAX_BYTES
  MAX_AGE_SECONDS = tonumber(read_setting("telemetry-max-age-seconds", DEFAULT_MAX_AGE_SECONDS)) or DEFAULT_MAX_AGE_SECONDS

  -- re-register nth tick with updated interval
  script.on_nth_tick(AFK_INTERVAL_TICKS, afk_poll)
end

-- Apply settings on load
apply_settings()

-- React to runtime setting changes
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if not event or not event.setting then return end
  if string.find(event.setting, "telemetry-") then
    apply_settings()
    safe_game_print("telemetry-mod settings updated")
    safe_log("telemetry-mod settings updated")
  end
end)