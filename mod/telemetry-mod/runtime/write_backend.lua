-- Detect and use the available Factorio write backend.

local M = {}

function M.new()
  local write_backend = nil -- "helpers", "game", or false

  local function detect_write_backend()
    if write_backend ~= nil then
      return write_backend
    end

    -- Check helpers.write_file first (Factorio 2.0+)
    local ok, result = pcall(function()
      return (helpers ~= nil) and (type(helpers.write_file) == "function")
    end)
    if ok and result then
      write_backend = "helpers"
      return write_backend
    end

    -- Fallback: check game.write_file (older runtimes)
    ok, result = pcall(function()
      return (game ~= nil) and (type(game.write_file) == "function")
    end)
    if ok and result then
      write_backend = "game"
      return write_backend
    end

    write_backend = false
    return write_backend
  end

  local function write_file_safe(filename, content, append)
    local backend = detect_write_backend()
    if not backend then
      return false, "no write backend"
    end

    if backend == "helpers" then
      local ok, err = pcall(function()
        helpers.write_file(filename, content, append)
      end)
      return ok, err
    end

    if backend == "game" then
      local ok, err = pcall(function()
        game.write_file(filename, content, append)
      end)
      return ok, err
    end

    return false, "unsupported backend"
  end

  return {
    detect_write_backend = detect_write_backend,
    write_file_safe = write_file_safe
  }
end

return M
