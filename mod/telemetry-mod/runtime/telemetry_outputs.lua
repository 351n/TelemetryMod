-- Fan out already-encoded telemetry JSON to independently configurable outputs.

local M = {}

function M.new(opts)
  local write_file_safe = assert(opts.write_file_safe, "write_file_safe is required")
  local send_udp_safe = assert(opts.send_udp_safe, "send_udp_safe is required")
  local get_config = assert(opts.get_config, "get_config is required")
  local get_tick = opts.get_tick or function() return (game and game.tick) or 0 end
  local safe_game_print = opts.safe_game_print or function() end
  local safe_log = opts.safe_log or function() end
  local warning_log = opts.warning_log or function() end
  local last_udp_error = nil
  local last_jsonl_error = nil

  local function ensure_buffer()
    if not storage then return nil end
    storage.telemetry_buffer = storage.telemetry_buffer or { entries = {}, total_bytes = 0 }
    storage.telemetry_buffer.entries = storage.telemetry_buffer.entries or {}
    storage.telemetry_buffer.total_bytes = storage.telemetry_buffer.total_bytes or 0
    return storage.telemetry_buffer
  end

  local function prune_buffer(buffer, cfg)
    local entries = buffer.entries
    local max_age_ticks = (cfg.max_age_seconds or cfg.default_max_age_seconds) * 60
    local cutoff_tick = nil
    local now_tick = get_tick()
    if now_tick and max_age_ticks and max_age_ticks > 0 then
      cutoff_tick = now_tick - max_age_ticks
    end

    while #entries > 0 do
      local entry = entries[1]
      if cutoff_tick and entry.tick < cutoff_tick then
        buffer.total_bytes = buffer.total_bytes - entry.bytes
        table.remove(entries, 1)
      else
        break
      end
    end

    local max_bytes = cfg.max_bytes or cfg.default_max_bytes
    while buffer.total_bytes > max_bytes and #entries > 0 do
      local entry = table.remove(entries, 1)
      buffer.total_bytes = buffer.total_bytes - entry.bytes
    end
  end

  local function append_to_buffer(line, cfg)
    local buffer = ensure_buffer()
    if not buffer then return nil end

    local entry = { line = line, tick = get_tick(), bytes = #line + 1 }
    table.insert(buffer.entries, entry)
    buffer.total_bytes = buffer.total_bytes + entry.bytes
    prune_buffer(buffer, cfg)
    return buffer
  end

  local function flush_jsonl(buffer, cfg, suppress_debug)
    if not buffer then
      local ok, err = write_file_safe(cfg.log_file, "", false)
      if not ok then return false, err end
      return true
    end

    local lines = {}
    for index = 1, #buffer.entries do
      lines[index] = buffer.entries[index].line
    end
    local content = table.concat(lines, "\n")
    if content ~= "" then content = content .. "\n" end

    local ok, err = write_file_safe(cfg.log_file, content, false)
    if ok and not suppress_debug then
      safe_game_print({ "telemetry-mod.debug-wrote-buffer", tostring(#buffer.entries) })
      safe_log({ "telemetry-mod.debug-wrote-buffer-bytes", tostring(buffer.total_bytes) })
    end
    return ok, err
  end

  local function report_udp_error(err)
    local message = tostring(err or "unknown UDP failure")
    if message ~= last_udp_error then
      last_udp_error = message
      warning_log("UDP telemetry disabled for this attempt: " .. message)
    end
  end

  local function record(line, suppress_debug)
    suppress_debug = suppress_debug == true
    local cfg = get_config()
    local needs_buffer = cfg.jsonl_enabled or cfg.rcon_enabled
    local buffer = nil
    local jsonl_ok, jsonl_error = true, nil

    if needs_buffer then
      buffer = append_to_buffer(line, cfg)
    end

    if cfg.jsonl_enabled then
      if not buffer then
        jsonl_ok, jsonl_error = write_file_safe(cfg.log_file, line .. "\n", true)
      else
        jsonl_ok, jsonl_error = flush_jsonl(buffer, cfg, suppress_debug)
      end
      if not jsonl_ok then
        local message = tostring(jsonl_error or "unknown JSONL failure")
        if message ~= last_jsonl_error then
          last_jsonl_error = message
          warning_log("JSONL telemetry failed for this attempt: " .. message)
        end
      else
        last_jsonl_error = nil
      end
    end

    if cfg.udp_enabled then
      local ok, err = send_udp_safe(cfg.udp_port, line)
      if not ok then
        report_udp_error(err)
      else
        last_udp_error = nil
      end
    end

    if not jsonl_ok then return false, jsonl_error end
    return true
  end

  local function clear_jsonl_file()
    local cfg = get_config()
    if not cfg.jsonl_enabled then return true end
    return write_file_safe(cfg.log_file, "", false)
  end

  local function rcon_response(requested_limit)
    local cfg = get_config()
    local tick = get_tick()
    if not cfg.rcon_enabled then
      return string.format('{"schema":"telemetry-rcon/v1","tick":%d,"error":"rcon-disabled","events":[]}', tick)
    end

    local limit = tonumber(requested_limit) or cfg.rcon_window_events
    limit = math.max(1, math.min(math.floor(limit), cfg.rcon_window_events))
    local buffer = ensure_buffer()
    if not buffer then
      return string.format('{"schema":"telemetry-rcon/v1","tick":%d,"events":[]}', tick)
    end

    prune_buffer(buffer, cfg)
    local first = math.max(1, #buffer.entries - limit + 1)
    local lines = {}
    for index = first, #buffer.entries do
      lines[#lines + 1] = buffer.entries[index].line
    end
    return string.format('{"schema":"telemetry-rcon/v1","tick":%d,"events":[%s]}', tick, table.concat(lines, ","))
  end

  return {
    record = record,
    clear_jsonl_file = clear_jsonl_file,
    rcon_response = rcon_response
  }
end

return M
