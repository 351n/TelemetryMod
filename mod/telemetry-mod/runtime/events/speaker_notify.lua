-- Programmable speaker telemetry poller with anti-spam protections.

local M = {}

function M.new(opts)
  local emit_external_notify = assert(opts.emit_external_notify, "emit_external_notify is required")
  local localised_fallback = assert(opts.localised_fallback, "localised_fallback is required")
  local safe_log = opts.safe_log or function() end
  local get_config = assert(opts.get_config, "get_config is required")
  local is_speaker_enabled = assert(opts.is_speaker_enabled, "is_speaker_enabled is required")
  local prune_speaker_state = opts.prune_speaker_state or function() end

  local function trim(value)
    local s = tostring(value or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
  end

  local function safe_signal_key(signal_id)
    if type(signal_id) ~= "table" then return nil end
    local signal_name = trim(signal_id.name)
    if signal_name == "" then return nil end

    local signal_type = trim(signal_id.type)
    local quality = trim(signal_id.quality)
    local key = signal_name
    if signal_type ~= "" then
      key = signal_type .. "/" .. signal_name
    end
    if quality ~= "" then
      key = key .. "@" .. quality
    end
    return key
  end

  local function speaker_message(alert_message, signal_key, surface_name, position)
    local raw = alert_message
    if type(raw) == "table" then
      raw = localised_fallback(raw)
    end
    local message = trim(raw)
    if message ~= "" then return message end

    local pos_x = 0
    local pos_y = 0
    if position then
      pos_x = tonumber(position.x) or 0
      pos_y = tonumber(position.y) or 0
    end
    local signal_text = signal_key and ("Signal " .. signal_key) or "Signal"
    return string.format("%s triggered on %s @%.1f,%.1f", signal_text, surface_name or "unknown", pos_x, pos_y)
  end

  local function ensure_state_table()
    if not storage then return nil end
    storage.telemetry_notify_state = storage.telemetry_notify_state or {}
    storage.telemetry_notify_state.speakers = storage.telemetry_notify_state.speakers or {}
    return storage.telemetry_notify_state.speakers
  end

  local function should_emit_for_speaker(entity, state, cfg, tick, unit_key)
    local cb = entity and entity.get_control_behavior and entity.get_control_behavior()
    if not (cb and cb.valid and cb.circuit_condition) then
      state.active = false
      return false, nil
    end

    local alert = entity.alert_parameters
    local cond = cb.circuit_condition or {}
    local signal_key = safe_signal_key(cond.first_signal) or safe_signal_key(alert and alert.icon_signal_id)
    local telemetry_enabled = is_speaker_enabled(unit_key) == true
    local tracking_enabled = telemetry_enabled and alert and alert.show_alert == true and signal_key ~= nil
    local fulfilled = cond.fulfilled == true
    local active = tracking_enabled and fulfilled

    local was_active = state.active == true
    state.active = active
    if not active or was_active then
      return false, signal_key
    end

    local cooldown_ticks = tonumber(cfg.cooldown_ticks) or tonumber(cfg.default_cooldown_ticks) or 3600
    cooldown_ticks = math.max(1, math.floor(cooldown_ticks))
    local last_emit_tick = tonumber(state.last_emit_tick)
    if last_emit_tick and (tick - last_emit_tick) < cooldown_ticks then
      return false, signal_key
    end

    return true, signal_key
  end

  local function speaker_poll(event)
    if not game then return end
    local cfg = get_config() or {}
    if cfg.enabled ~= true then return end

    local tick = (event and event.tick) or game.tick or 0
    local max_events = tonumber(cfg.max_events_per_poll) or tonumber(cfg.default_max_events_per_poll) or 5
    max_events = math.max(1, math.floor(max_events))

    local state_by_unit = ensure_state_table()
    if not state_by_unit then return end

    local emitted = 0
    local seen_units = {}
    local seen_surfaces = {}

    for _, surface in pairs(game.surfaces or {}) do
      if surface and surface.valid and not seen_surfaces[surface.index] then
        seen_surfaces[surface.index] = true
        local speakers = surface.find_entities_filtered({ name = "programmable-speaker" })
        for _, speaker in pairs(speakers) do
          if emitted >= max_events then break end
          if speaker and speaker.valid and speaker.unit_number then
            local unit = tostring(speaker.unit_number)
            seen_units[unit] = true
            local state = state_by_unit[unit] or { active = false, last_emit_tick = nil }
            state_by_unit[unit] = state

            local can_emit, signal_key = should_emit_for_speaker(speaker, state, cfg, tick, unit)
            if can_emit then
              local alert = speaker.alert_parameters
              local message = speaker_message(alert and alert.alert_message, signal_key, surface.name, speaker.position)
              local severity = (alert and alert.show_on_map == true) and "critical" or "warning"
              local tags = { "programmable-speaker", "signal-trigger" }
              if signal_key then
                tags[#tags + 1] = "signal:" .. signal_key
              end

              local ok, err = emit_external_notify({
                source = "programmable-speaker",
                severity = severity,
                message = message,
                force = (speaker.force and speaker.force.name) or nil,
                surface = surface.name,
                category = "signal",
                code = "speaker-" .. unit,
                tags = tags
              }, "speaker")

              if ok then
                emitted = emitted + 1
                state.last_emit_tick = tick
              else
                safe_log({ "telemetry-mod.notify-invalid", tostring(err) })
              end
            end
          end
        end
      end
      if emitted >= max_events then break end
    end

    for unit, _ in pairs(state_by_unit) do
      if not seen_units[unit] then
        state_by_unit[unit] = nil
      end
    end
    prune_speaker_state(seen_units)
  end

  local function on_tick(event)
    local cfg = get_config() or {}
    if cfg.enabled ~= true then return end

    local interval_ticks = tonumber(cfg.interval_ticks) or tonumber(cfg.default_interval_ticks) or 300
    interval_ticks = math.max(1, math.floor(interval_ticks))
    local tick = (event and event.tick) or ((game and game.tick) or 0)
    if tick % interval_ticks ~= 0 then return end
    speaker_poll(event)
  end

  return {
    speaker_poll = speaker_poll,
    on_tick = on_tick
  }
end

return M
