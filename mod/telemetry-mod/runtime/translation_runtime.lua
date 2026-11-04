-- Translation, caching and pending-translation lifecycle for telemetry events.

local M = {}

local PREFERRED_TLM_LOCALES = { "en", "pl" }
local PREFERRED_TECH_LOCALES = { "en", "pl" }
local DEFAULT_DEATH_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds
local DEFAULT_EVOLUTION_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds
local DEFAULT_TECH_TRANSLATION_TIMEOUT_TICKS = 10 * 60 -- 10 seconds

local function locale_rank(preferred_locales, loc)
  if not loc then return #preferred_locales + 1 end
  for i = 1, #preferred_locales do
    if loc == preferred_locales[i] then return i end
  end
  return #preferred_locales + 1
end

local function consider_player(best, p, preferred_locales)
  if not (p and p.valid) then return best end
  local r = locale_rank(preferred_locales, p.locale)
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

local function pick_translator_player(force_obj, preferred_locales, fallback_any_force)
  if not game or not game.connected_players then return nil end

  local best = nil
  if force_obj then
    for _, p in pairs(game.connected_players) do
      if p and p.force == force_obj then
        best = consider_player(best, p, preferred_locales)
      end
    end
  end

  if fallback_any_force and (not best) then
    for _, p in pairs(game.connected_players) do
      best = consider_player(best, p, preferred_locales)
    end
  end

  -- For tech translations keep legacy behavior:
  -- if force is provided, do not fallback to other forces.
  if (not force_obj) and (not best) then
    for _, p in pairs(game.connected_players) do
      best = consider_player(best, p, preferred_locales)
    end
  end

  return best and best.p or nil
end

function M.new(opts)
  local is_localised = assert(opts.is_localised, "is_localised is required")
  local localised_fallback = assert(opts.localised_fallback, "localised_fallback is required")

  local handlers = {
    write_death_line = nil,
    write_research_line = nil,
    emit_threshold = nil
  }

  local function get_cache(cache_key, locale, key)
    if not storage or not locale or not key then return nil end
    local cache = storage[cache_key]
    if cache and cache[locale] and cache[locale][key] then
      return cache[locale][key]
    end
    return nil
  end

  local function put_cache(cache_key, locale, key, translated)
    if not storage or not locale or not key or not translated then return end
    storage[cache_key] = storage[cache_key] or {}
    storage[cache_key][locale] = storage[cache_key][locale] or {}
    storage[cache_key][locale][key] = translated
  end

  local function pick_translator_player_tlm(force_obj)
    return pick_translator_player(force_obj, PREFERRED_TLM_LOCALES, true)
  end

  local function pick_translator_player_tech(force_obj)
    return pick_translator_player(force_obj, PREFERRED_TECH_LOCALES, false)
  end

  local function resolve_localised_or_request(localised_value, force_obj)
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

  local function flush_stale_death_translations()
    if not storage or not storage.pending_death_translations or not game or not game.tick then return end
    if not handlers.write_death_line then return end
    local now = game.tick
    local timeout = DEFAULT_DEATH_TRANSLATION_TIMEOUT_TICKS
    for id, meta in pairs(storage.pending_death_translations) do
      if meta and meta.request_tick and (now - meta.request_tick) > timeout then
        handlers.write_death_line(meta.tick or now, meta.player, meta.info, meta.info and meta.info.cause_name)
        storage.pending_death_translations[id] = nil
      end
    end
  end

  local function flush_stale_research_translations()
    if not storage or not storage.pending_research_translations or not game or not game.tick then return end
    if not handlers.write_research_line then return end
    local now = game.tick
    local timeout = DEFAULT_TECH_TRANSLATION_TIMEOUT_TICKS
    for id, meta in pairs(storage.pending_research_translations) do
      if meta and meta.request_tick and (now - meta.request_tick) > timeout then
        handlers.write_research_line(meta.tick or now, meta.technology, meta.technology, meta.force, meta.player)
        storage.pending_research_translations[id] = nil
      end
    end
  end

  local function flush_stale_evolution_translations()
    if not storage or not storage.pending_evolution_translations or not game or not game.tick then return end
    if not handlers.emit_threshold then return end
    local now = game.tick
    local timeout = DEFAULT_EVOLUTION_TRANSLATION_TIMEOUT_TICKS
    for id, meta in pairs(storage.pending_evolution_translations) do
      if meta and meta.request_tick and (now - meta.request_tick) > timeout then
        local msg_string = localised_fallback(meta.message_localised or "")
        handlers.emit_threshold(
          meta.tick or now,
          meta.force_name,
          meta.evolution_factor or 0,
          meta.threshold,
          meta.direction,
          msg_string,
          meta.message_localised,
          meta.surface
        )
        storage.pending_evolution_translations[id] = nil
      end
    end
  end

  local function on_string_translated(event)
    if not event or not storage then return end

    if storage.pending_research_translations then
      local meta = storage.pending_research_translations[event.id]
      if meta then
        storage.pending_research_translations[event.id] = nil

        if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
          return
        end

        local translated = meta.technology
        if event.translated and event.result then
          translated = event.result
          put_cache("tech_translation_cache", meta.locale, meta.technology, translated)
        end

        if handlers.write_research_line then
          handlers.write_research_line(meta.tick, meta.technology, translated, meta.force, meta.player)
        end
        return
      end
    end

    if storage.pending_death_translations then
      local meta = storage.pending_death_translations[event.id]
      if meta then
        storage.pending_death_translations[event.id] = nil

        if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
          return
        end

        local info = meta.info or {}
        local cause_name = info.cause_name or "unknown"
        local translated = cause_name
        if event.translated and event.result then
          translated = event.result
          put_cache("entity_translation_cache", meta.locale, cause_name, translated)
        end

        if handlers.write_death_line then
          handlers.write_death_line(meta.tick, meta.player, info, translated)
        end
      end
    end

    if storage.pending_evolution_translations then
      local meta = storage.pending_evolution_translations[event.id]
      if meta then
        storage.pending_evolution_translations[event.id] = nil

        if meta.player_index and event.player_index and meta.player_index ~= event.player_index then
          return
        end

        local msg_string = localised_fallback(meta.message_localised or "")
        if event.translated and event.result then
          msg_string = event.result
        end

        if handlers.emit_threshold then
          handlers.emit_threshold(
            meta.tick or ((game and game.tick) or 0),
            meta.force_name,
            meta.evolution_factor or 0,
            meta.threshold,
            meta.direction,
            msg_string,
            meta.message_localised,
            meta.surface
          )
        end
      end
    end
  end

  local function set_handlers(next_handlers)
    if not next_handlers then return end
    for k, v in pairs(next_handlers) do
      handlers[k] = v
    end
  end

  return {
    set_handlers = set_handlers,
    resolve_localised_or_request = resolve_localised_or_request,
    pick_translator_player_tlm = pick_translator_player_tlm,
    pick_translator_player_tech = pick_translator_player_tech,
    get_entity_translation_cached = function(locale, entity_name)
      return get_cache("entity_translation_cache", locale, entity_name)
    end,
    get_tech_translation_cached = function(locale, tech_name)
      return get_cache("tech_translation_cache", locale, tech_name)
    end,
    flush_stale_death_translations = flush_stale_death_translations,
    flush_stale_research_translations = flush_stale_research_translations,
    flush_stale_evolution_translations = flush_stale_evolution_translations,
    on_string_translated = on_string_translated
  }
end

return M
