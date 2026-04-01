-- Runtime helper for normalizing and emitting telemetry notify events.

local M = {}

local VALID_NOTIFY_LEVELS = { info = true, warning = true, critical = true }

function M.new(opts)
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local localised_fallback = assert(opts.localised_fallback, "localised_fallback is required")
  local safe_log = opts.safe_log or function() end
  local raise_event = opts.raise_event

  local function normalize_notify_level(raw_level)
    local level = string.lower(tostring(raw_level or "info"))
    if level == "warn" then level = "warning" end
    if level == "error" or level == "fatal" then level = "critical" end
    if VALID_NOTIFY_LEVELS[level] then
      return level
    end
    return "info"
  end

  local function normalize_notify_payload(payload, origin)
    local p = payload
    if type(p) ~= "table" then
      p = { message = payload }
    end

    local message = nil
    if p.message_localised then
      message = localised_fallback(p.message_localised)
    elseif p.message ~= nil then
      message = tostring(p.message)
    elseif p.text ~= nil then
      message = tostring(p.text)
    end
    if not message or message == "" then
      return nil, "notify payload requires message"
    end

    local function pick_text(...)
      local values = { ... }
      for i = 1, #values do
        local v = values[i]
        if v ~= nil then
          local s = tostring(v)
          if s ~= "" then
            return s
          end
        end
      end
      return nil
    end

    local data = {
      tick = (game and game.tick) or 0,
      source = pick_text(p.source, p.mod, p.producer) or "external",
      severity = normalize_notify_level(p.severity or p.level),
      message = message,
      origin = pick_text(origin, p.origin) or "unknown",
      player = pick_text(p.player, p.player_name),
      force = pick_text(p.force, p.force_name),
      surface = pick_text(p.surface, p.surface_name),
      category = pick_text(p.category),
      code = pick_text(p.code)
    }

    if type(p.tags) == "table" then
      data.tags = {}
      for _, raw_tag in pairs(p.tags) do
        local tag = tostring(raw_tag or "")
        if tag ~= "" then
          data.tags[#data.tags + 1] = tag
        end
      end
    end

    return data, nil
  end

  local function write_notify_telemetry_line(data)
    local parts = {
      string.format(
        '{"tick":%d,"type":"notify","source":"%s","severity":"%s","message":"%s","origin":"%s"',
        data.tick or ((game and game.tick) or 0),
        escape_json_string(data.source or "external"),
        escape_json_string(data.severity or "info"),
        escape_json_string(data.message or ""),
        escape_json_string(data.origin or "unknown")
      )
    }

    if data.player then
      parts[#parts + 1] = string.format(',"player":"%s"', escape_json_string(data.player))
    end
    if data.force then
      parts[#parts + 1] = string.format(',"force":"%s"', escape_json_string(data.force))
    end
    if data.surface then
      parts[#parts + 1] = string.format(',"surface":"%s"', escape_json_string(data.surface))
    end
    if data.category then
      parts[#parts + 1] = string.format(',"category":"%s"', escape_json_string(data.category))
    end
    if data.code then
      parts[#parts + 1] = string.format(',"code":"%s"', escape_json_string(data.code))
    end
    if data.tags and #data.tags > 0 then
      local tags = {}
      for i = 1, #data.tags do
        tags[#tags + 1] = '"' .. escape_json_string(data.tags[i]) .. '"'
      end
      parts[#parts + 1] = string.format(',"tags":[%s]', table.concat(tags, ","))
    end

    parts[#parts + 1] = "}"
    write_json_line(table.concat(parts, ""))
  end

  local function emit(payload, origin)
    local data, err = normalize_notify_payload(payload, origin)
    if not data then
      safe_log({ "telemetry-mod.notify-invalid", tostring(err) })
      return false, err
    end

    write_notify_telemetry_line(data)

    if raise_event then
      pcall(function()
        raise_event(data)
      end)
    end

    return true, nil
  end

  return {
    emit = emit
  }
end

return M
