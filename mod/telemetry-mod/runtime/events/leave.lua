-- Leave event telemetry handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local safe_player_name_from_index = assert(opts.safe_player_name_from_index, "safe_player_name_from_index is required")

  local function on_player_left(event)
    local name = safe_player_name_from_index(event and event.player_index)
    local line = string.format(
      '{"tick":%d,"type":"leave","player":"%s"}',
      (game and game.tick) or 0,
      escape_json_string(name)
    )
    write_json_line(line)
  end

  return {
    on_player_left = on_player_left
  }
end

return M
