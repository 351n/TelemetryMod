-- Shared helpers for telemetry runtime code.
-- Keep this file free of game/runtime side effects so it is safe to require early.

local M = {}

-- Escape minimal set of characters for safe JSON strings.
function M.escape_json_string(value)
  if value == nil then return "" end
  local s = tostring(value)
  -- Order matters: escape backslash first.
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  return s
end

function M.is_localised(value)
  return type(value) == "table"
end

function M.localised_fallback(value)
  if not M.is_localised(value) then
    return tostring(value)
  end

  local key = value[1]
  if key == "" then
    local parts = {}
    for i = 2, #value do
      parts[#parts + 1] = M.localised_fallback(value[i])
    end
    return table.concat(parts)
  end

  if type(key) == "string" then
    if #value > 1 then
      local params = {}
      for i = 2, #value do
        params[#params + 1] = M.localised_fallback(value[i])
      end
      return key .. "(" .. table.concat(params, ",") .. ")"
    end
    return key
  end

  return tostring(value)
end

function M.with_prefix(message, prefix_key)
  local key = prefix_key or "telemetry-mod.prefix"
  if M.is_localised(message) then
    return { "", { key }, " ", message }
  end
  return "[telemetry-mod] " .. tostring(message)
end

function M.parse_surface_list(raw, fallback_surface)
  local list = {}
  local value = tostring(raw or "")
  for name in string.gmatch(value, "[^,%s;]+") do
    list[#list + 1] = name
  end
  if #list == 0 then
    list[#list + 1] = fallback_surface or "nauvis"
  end
  return list
end

function M.fmt_pct01(x)
  if x == nil then return "?" end
  local pct = math.floor((tonumber(x) or 0) * 1000 + 0.5) / 10 -- 0.1%
  return tostring(pct)
end

return M
