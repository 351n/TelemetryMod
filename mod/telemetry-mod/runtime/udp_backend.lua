-- Safe wrapper around Factorio's localhost-only UDP helper.

local M = {}

function M.new()
  local function send_udp_safe(port, data)
    local ok, available = pcall(function()
      return helpers ~= nil and type(helpers.send_udp) == "function"
    end)
    if not ok or not available then
      return false, "helpers.send_udp is unavailable; start Factorio with --enable-lua-udp=<source-port>"
    end

    local sent, err = pcall(function()
      helpers.send_udp(port, data, 0)
    end)
    if not sent then
      return false, err
    end
    return true
  end

  return { send_udp_safe = send_udp_safe }
end

return M
