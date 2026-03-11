-- Death telemetry handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local safe_player_name_from_index = assert(opts.safe_player_name_from_index, "safe_player_name_from_index is required")
  local get_player_force_by_index = assert(opts.get_player_force_by_index, "get_player_force_by_index is required")
  local translation_api = assert(opts.translation_api, "translation_api is required")

  local function describe_death_cause(event)
    local cause_name = nil
    local cause_localised = nil -- LocalisedString (needs client translation)
    local cause_type = nil
    local cause_force = nil
    local pos_x = nil
    local pos_y = nil
    local damage_type = nil

    pcall(function()
      if event and event.damage_type and event.damage_type.name then
        damage_type = event.damage_type.name
      end
    end)

    pcall(function()
      if event and event.position then
        pos_x = event.position.x
        pos_y = event.position.y
      end
    end)

    local cause = event and event.cause
    if cause then
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
        pcall(function()
          if cause_type == "character" and cause.player and cause.player.name then
            cause_name = "character:" .. tostring(cause.player.name)
          end
        end)
      end)

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

  local function on_player_died(event)
    local tick = (game and game.tick) or 0
    local player_name = safe_player_name_from_index(event and event.player_index)
    local info = describe_death_cause(event)

    if (info.pos_x == nil or info.pos_y == nil) and game and event and event.player_index then
      local p = game.get_player(event.player_index)
      pcall(function()
        if p and p.valid and p.position then
          info.pos_x = info.pos_x or p.position.x
          info.pos_y = info.pos_y or p.position.y
        end
      end)
    end

    local force_obj = get_player_force_by_index(event and event.player_index)
    local cause_name = info.cause_name or "unknown"

    local translator = translation_api.pick_translator_player_tlm(force_obj)
    if translator and translator.valid and translator.locale then
      local cached = translation_api.get_entity_translation_cached(translator.locale, cause_name)
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
          return
        end
      end
    end

    write_death_telemetry_line(tick, player_name, info, cause_name)
  end

  return {
    on_player_died = on_player_died,
    write_death_telemetry_line = write_death_telemetry_line
  }
end

return M
