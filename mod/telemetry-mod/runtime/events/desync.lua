-- Desync telemetry handler (strict mode).

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local safe_player_name_from_index = assert(opts.safe_player_name_from_index, "safe_player_name_from_index is required")

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

  local function on_pre_player_left(event)
    local reason_id = event and event.reason
    if not is_desync_disconnect_reason(reason_id) then
      return
    end
    local name = safe_player_name_from_index(event and event.player_index)
    write_desync_telemetry_line((game and game.tick) or 0, name, reason_id)
  end

  return {
    on_pre_player_left = on_pre_player_left,
    is_desync_disconnect_reason = is_desync_disconnect_reason,
    write_desync_telemetry_line = write_desync_telemetry_line
  }
end

return M
