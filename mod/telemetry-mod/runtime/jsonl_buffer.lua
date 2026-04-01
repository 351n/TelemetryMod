-- Buffered JSONL writer for telemetry output.

local M = {}

function M.new(opts)
  local write_file_safe = assert(opts.write_file_safe, "write_file_safe is required")
  local safe_game_print = opts.safe_game_print or function() end
  local safe_log = opts.safe_log or function() end
  local get_config = assert(opts.get_config, "get_config is required")
  local get_tick = opts.get_tick or function() return (game and game.tick) or 0 end

  local function write_json_line(line, suppress_debug)
    suppress_debug = (suppress_debug == true)
    local cfg = get_config()
    local log_file = cfg.log_file

    -- If global storage is unavailable, fallback to best-effort append.
    if not global then
      local ok, err = write_file_safe(log_file, line .. "\n", true)
      if ok then
        if not suppress_debug then
          safe_game_print({ "telemetry-mod.debug-wrote-line" })
          safe_log({ "telemetry-mod.debug-wrote-line-with", line })
        end
      else
        if err and err ~= "no write backend" then
          safe_log({ "telemetry-mod.debug-write-line-failed", tostring(err) })
        end
      end
      return
    end

    global.telemetry_buffer = global.telemetry_buffer or { entries = {}, total_bytes = 0 }
    local entry = { line = line, tick = get_tick(), bytes = (#line + 1) }
    table.insert(global.telemetry_buffer.entries, entry)
    global.telemetry_buffer.total_bytes = (global.telemetry_buffer.total_bytes or 0) + entry.bytes

    local function prune_buffer()
      local entries = global.telemetry_buffer.entries
      if not entries then return end
      local max_age_ticks = (cfg.max_age_seconds or cfg.default_max_age_seconds) * 60
      local cutoff_tick = nil
      local now_tick = get_tick()
      if now_tick and max_age_ticks and max_age_ticks > 0 then
        cutoff_tick = now_tick - max_age_ticks
      end

      while #entries > 0 do
        local e = entries[1]
        if cutoff_tick and e.tick < cutoff_tick then
          global.telemetry_buffer.total_bytes = global.telemetry_buffer.total_bytes - e.bytes
          table.remove(entries, 1)
        else
          break
        end
      end

      local max_bytes = cfg.max_bytes or cfg.default_max_bytes
      while global.telemetry_buffer.total_bytes > max_bytes and #entries > 0 do
        local e = table.remove(entries, 1)
        global.telemetry_buffer.total_bytes = global.telemetry_buffer.total_bytes - e.bytes
      end
    end

    prune_buffer()

    local function flush_buffer_to_file()
      local entries = global.telemetry_buffer.entries
      if not entries then return end

      local content = ""
      for i = 1, #entries do
        content = content .. entries[i].line .. "\n"
      end

      local ok, err = write_file_safe(log_file, content, false)
      if ok then
        if not suppress_debug then
          safe_game_print({ "telemetry-mod.debug-wrote-buffer", tostring(#entries) })
          safe_log({ "telemetry-mod.debug-wrote-buffer-bytes", tostring(global.telemetry_buffer.total_bytes) })
        end
      else
        if err and err ~= "no write backend" then
          safe_log({ "telemetry-mod.debug-write-buffer-failed", tostring(err) })
        end
      end
    end

    flush_buffer_to_file()
  end

  return {
    write_json_line = write_json_line
  }
end

return M
