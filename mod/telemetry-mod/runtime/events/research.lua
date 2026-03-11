-- Research telemetry handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local safe_player_name_from_index = assert(opts.safe_player_name_from_index, "safe_player_name_from_index is required")
  local get_force_by_name = assert(opts.get_force_by_name, "get_force_by_name is required")
  local translation_api = assert(opts.translation_api, "translation_api is required")

  local function describe_research_event(event)
    local tech_name = nil
    local tech_localised = nil
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
        if not tech_name and event.research_name then tech_name = event.research_name end
        if not force_name and event.force and event.force.name then force_name = event.force.name end
        if event.player_index then player_name = safe_player_name_from_index(event.player_index) end
      end
    end)
    return { technology = tech_name, technology_localised = tech_localised, force = force_name, player = player_name }
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

  local function on_research_finished(event)
    local info = describe_research_event(event)
    local tick = (game and game.tick) or 0

    local tech_name = info.technology or "unknown"
    local force_name = info.force or ""
    local player_name = info.player or ""

    local force_obj = nil
    pcall(function()
      if event and event.research and event.research.force then force_obj = event.research.force end
      if (not force_obj) and force_name ~= "" then force_obj = get_force_by_name(force_name) end
    end)

    local translator = translation_api.pick_translator_player_tech(force_obj)
    if translator and translator.valid and translator.locale then
      local cached = translation_api.get_tech_translation_cached(translator.locale, tech_name)
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
          return
        end
      end
    end

    write_research_telemetry_line(tick, tech_name, tech_name, force_name, player_name)
  end

  return {
    on_research_finished = on_research_finished,
    write_research_telemetry_line = write_research_telemetry_line
  }
end

return M
