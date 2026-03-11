-- Lifecycle and event registration wiring.

local M = {}

function M.new(opts)
  local handlers = assert(opts.handlers, "handlers is required")
  local get_afk_interval_ticks = assert(opts.get_afk_interval_ticks, "get_afk_interval_ticks is required")
  local get_evolution_interval_ticks = assert(opts.get_evolution_interval_ticks, "get_evolution_interval_ticks is required")
  local ensure_runtime_state = assert(opts.ensure_runtime_state, "ensure_runtime_state is required")
  local baseline_init_evolution = assert(opts.baseline_init_evolution, "baseline_init_evolution is required")
  local clear_log_file = assert(opts.clear_log_file, "clear_log_file is required")
  local apply_settings = assert(opts.apply_settings, "apply_settings is required")
  local is_telemetry_setting = assert(opts.is_telemetry_setting, "is_telemetry_setting is required")
  local safe_game_print = opts.safe_game_print or function() end
  local safe_log = opts.safe_log or function() end

  local function on_init()
    ensure_runtime_state()
    pcall(function()
      baseline_init_evolution()
    end)

    local ok, err = clear_log_file()
    if ok then
      safe_game_print({ "telemetry-mod.init-cleared" })
      safe_log({ "telemetry-mod.init-cleared" })
    else
      if err and err ~= "no write backend" then
        safe_log({ "telemetry-mod.init-write-failed", tostring(err) })
      end
      safe_game_print({ "telemetry-mod.init-no-backend" })
    end
  end

  local function on_configuration_changed(data)
    if global then
      ensure_runtime_state()
    end

    pcall(function()
      apply_settings()
    end)

    safe_game_print({ "telemetry-mod.config-changed" })
    safe_log({ "telemetry-mod.config-changed" })
  end

  local function on_runtime_mod_setting_changed(event)
    if not event or not event.setting then return end
    if is_telemetry_setting(event.setting) then
      apply_settings()
      safe_game_print({ "telemetry-mod.settings-updated" })
      safe_log({ "telemetry-mod.settings-updated" })
    end
  end

  local function register()
    script.on_event(defines.events.on_player_joined_game, handlers.on_player_joined)
    script.on_event(defines.events.on_player_left_game, handlers.on_player_left)
    pcall(function() script.on_event(defines.events.on_pre_player_left_game, handlers.on_pre_player_left) end)
    script.on_nth_tick(get_afk_interval_ticks(), handlers.afk_poll)
    script.on_nth_tick(get_evolution_interval_ticks(), handlers.evolution_poll)
    pcall(function() script.on_event(defines.events.on_player_died, handlers.on_player_died) end)
    pcall(function() script.on_event(defines.events.on_research_finished, handlers.on_research_finished) end)
    pcall(function() script.on_event(defines.events.on_string_translated, handlers.on_string_translated) end)
    script.on_init(on_init)
    script.on_configuration_changed(on_configuration_changed)
    script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
  end

  return {
    register = register
  }
end

return M
