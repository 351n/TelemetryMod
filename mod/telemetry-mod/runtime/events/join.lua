-- Join event telemetry handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")

  local function on_player_joined(event)
    local name = "unknown"
    if event and event.player_index and game and game.get_player then
      local p = game.get_player(event.player_index)
      if p and p.valid and p.name then
        name = p.name
      else
        name = "index:" .. tostring(event.player_index)
      end
    end

    local line = string.format(
      '{"tick":%d,"type":"join","player":"%s"}',
      (game and game.tick) or 0,
      escape_json_string(name)
    )
    write_json_line(line)
  end

  return {
    on_player_joined = on_player_joined
  }
end

return M
