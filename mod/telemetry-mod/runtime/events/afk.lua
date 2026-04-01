-- AFK polling telemetry handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local with_prefix = assert(opts.with_prefix, "with_prefix is required")
  local get_config = assert(opts.get_config, "get_config is required")
  local flush_stale_research_translations = assert(opts.flush_stale_research_translations, "flush_stale_research_translations is required")
  local flush_stale_death_translations = assert(opts.flush_stale_death_translations, "flush_stale_death_translations is required")
  local flush_stale_evolution_translations = assert(opts.flush_stale_evolution_translations, "flush_stale_evolution_translations is required")

  local function afk_poll(event)
    if not game then return end

    flush_stale_research_translations()
    flush_stale_death_translations()
    flush_stale_evolution_translations()

    local cfg = get_config() or {}
    local debug_afk = cfg.debug_afk == true
    local afk_info_enabled = cfg.afk_info_enabled == true
    local afk_info_threshold_seconds = tonumber(cfg.afk_info_threshold_seconds) or tonumber(cfg.default_afk_info_threshold_seconds) or 300
    local afk_info_return_seconds = tonumber(cfg.afk_info_return_seconds) or tonumber(cfg.default_afk_info_return_seconds) or 60

    for _, player in pairs(game.connected_players or {}) do
      if player and player.valid then
        local afk_ticks = tonumber(player.afk_time) or 0
        local afk_seconds = math.floor(afk_ticks / 60)
        local line = string.format(
          '{"tick":%d,"type":"afk","player":"%s","afk_ticks":%d,"afk_seconds":%d}',
          game.tick,
          escape_json_string(player.name or "unknown"),
          afk_ticks,
          afk_seconds
        )

        -- suppress debug output for AFK lines unless explicitly enabled
        write_json_line(line, not debug_afk)

        if afk_info_enabled and game.print then
          global.telemetry_afk_state = global.telemetry_afk_state or {}
          local st = global.telemetry_afk_state[player.index] or { is_afk = false }
          if (not st.is_afk) and afk_seconds >= afk_info_threshold_seconds then
            st.is_afk = true
            global.telemetry_afk_state[player.index] = st
            pcall(function()
              game.print(with_prefix({ "telemetry-mod.afk-on", player.name or "unknown", tostring(afk_seconds) }))
            end)
          elseif st.is_afk and afk_seconds <= afk_info_return_seconds then
            st.is_afk = false
            global.telemetry_afk_state[player.index] = st
            pcall(function()
              game.print(with_prefix({ "telemetry-mod.afk-off", player.name or "unknown" }))
            end)
          end
        end
      end
    end
  end

  return {
    afk_poll = afk_poll
  }
end

return M
