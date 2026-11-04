-- Evolution telemetry and threshold event handler.

local M = {}

function M.new(opts)
  local escape_json_string = assert(opts.escape_json_string, "escape_json_string is required")
  local write_json_line = assert(opts.write_json_line, "write_json_line is required")
  local fmt_pct01 = assert(opts.fmt_pct01, "fmt_pct01 is required")
  local with_prefix = assert(opts.with_prefix, "with_prefix is required")
  local localised_fallback = assert(opts.localised_fallback, "localised_fallback is required")
  local safe_log = opts.safe_log or function() end
  local resolve_localised_or_request = assert(opts.resolve_localised_or_request, "resolve_localised_or_request is required")
  local raise_threshold_event = assert(opts.raise_threshold_event, "raise_threshold_event is required")
  local get_observed_force = assert(opts.get_observed_force, "get_observed_force is required")
  local get_force_evolution_factor = assert(opts.get_force_evolution_factor, "get_force_evolution_factor is required")
  local get_threshold_list = assert(opts.get_threshold_list, "get_threshold_list is required")
  local get_config = assert(opts.get_config, "get_config is required")

  local function write_evolution_telemetry_line(tick, trigger, force_name, evolution_factor, extra)
    extra = extra or {}
    local cfg = get_config() or {}
    local parts = {
      string.format(
        '{"tick":%d,"type":"evolution","trigger":"%s","force":"%s","evolution_factor":%.6f',
        tick or ((game and game.tick) or 0),
        escape_json_string(trigger or "poll"),
        escape_json_string(force_name or (cfg.force_name or "enemy")),
        tonumber(evolution_factor) or 0
      )
    }

    if extra.delta ~= nil then
      parts[#parts + 1] = string.format(',"delta":%.6f', tonumber(extra.delta) or 0)
    end
    if extra.threshold ~= nil then
      parts[#parts + 1] = string.format(',"threshold":%.6f', tonumber(extra.threshold) or 0)
    end
    if extra.threshold_kind ~= nil then
      parts[#parts + 1] = string.format(',"threshold_kind":"%s"', escape_json_string(extra.threshold_kind))
    end
    if extra.threshold_key ~= nil then
      parts[#parts + 1] = string.format(',"threshold_key":"%s"', escape_json_string(extra.threshold_key))
    end
    if extra.direction ~= nil then
      parts[#parts + 1] = string.format(',"direction":"%s"', escape_json_string(extra.direction))
    end
    if extra.include_dominance ~= nil then
      parts[#parts + 1] = string.format(',"include_dominance":%s', extra.include_dominance and "true" or "false")
    end
    if extra.message ~= nil then
      parts[#parts + 1] = string.format(',"message":"%s"', escape_json_string(extra.message))
    end
    if extra.surface ~= nil then
      parts[#parts + 1] = string.format(',"surface":"%s"', escape_json_string(extra.surface))
    end

    parts[#parts + 1] = "}"
    write_json_line(table.concat(parts, ""))
  end

  local function ensure_evolution_state()
    if not storage then return nil end
    local cfg = get_config() or {}
    local default_surface_name = cfg.default_surface_name or "nauvis"

    storage.telemetry_evolution = storage.telemetry_evolution or {}
    local st = storage.telemetry_evolution

    -- Migrate older single-surface format to per-surface map.
    if st.last_checked_factor ~= nil or st.last_logged_factor ~= nil or st.unlogged_delta ~= nil or st.prev_poll_factor ~= nil then
      st.surfaces = st.surfaces or {}
      st.surfaces[default_surface_name] = {
        last_checked_factor = st.last_checked_factor,
        last_logged_factor = st.last_logged_factor,
        unlogged_delta = st.unlogged_delta or 0,
        prev_poll_factor = st.prev_poll_factor
      }
      st.last_checked_factor = nil
      st.last_logged_factor = nil
      st.unlogged_delta = nil
      st.prev_poll_factor = nil
    end

    st.surfaces = st.surfaces or {}
    return st
  end

  local function ensure_evolution_surface_state(surface_name)
    if not storage then return nil end
    local st = ensure_evolution_state()
    if not st then return nil end
    st.surfaces = st.surfaces or {}
    st.surfaces[surface_name] = st.surfaces[surface_name] or {
      last_checked_factor = nil,
      last_logged_factor = nil,
      unlogged_delta = 0,
      prev_poll_factor = nil
    }
    return st.surfaces[surface_name]
  end

  local function emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name, chat_enabled, include_dominance)
    write_evolution_telemetry_line(tick, "threshold", force_name, current_factor, {
      threshold = th and th.value,
      threshold_kind = th and th.kind,
      threshold_key = th and th.key,
      direction = direction or "up",
      include_dominance = include_dominance == true,
      message = msg_string or "",
      surface = surface_name
    })

    raise_threshold_event({
      tick = tick,
      force_name = force_name,
      evolution_factor = current_factor,
      threshold = th and th.value,
      threshold_kind = th and th.kind,
      threshold_key = th and th.key,
      direction = direction or "up",
      include_dominance = include_dominance == true,
      message = msg_string or "",
      surface = surface_name
    })

    if chat_enabled and game and game.print and (msg_localised or (msg_string and msg_string ~= "")) then
      local cfg = get_config() or {}
      local default_surface_name = cfg.default_surface_name or "nauvis"
      pcall(function()
        local pct = fmt_pct01(current_factor)
        local base = msg_localised or msg_string
        if surface_name and surface_name ~= "" and surface_name ~= default_surface_name then
          if pct then
            game.print(with_prefix({ "telemetry-mod.evolution-chat-surface", base, pct, surface_name }))
          else
            game.print(with_prefix({ "telemetry-mod.evolution-chat-surface-no-pct", base, surface_name }))
          end
        else
          if pct then
            game.print(with_prefix({ "telemetry-mod.evolution-chat", base, pct }))
          else
            game.print(with_prefix({ "telemetry-mod.evolution-chat-no-pct", base }))
          end
        end
      end)
    end
  end

  local function maybe_emit_threshold(th, force_obj, current_factor, direction, surface_name, chat_enabled, include_dominance)
    local cfg = get_config() or {}
    local tick = (game and game.tick) or 0
    local force_name = (force_obj and force_obj.name) or (cfg.force_name or "enemy")
    local msg_localised = th and th.message or ""

    local msg_string, pending = resolve_localised_or_request(msg_localised, force_obj)
    if pending then
      if not storage then
        msg_string = localised_fallback(msg_localised)
        emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name, chat_enabled, include_dominance)
        return
      end
      storage.pending_evolution_translations = storage.pending_evolution_translations or {}
      storage.pending_evolution_translations[pending.id] = {
        tick = tick,
        request_tick = tick,
        force_name = force_name,
        surface = surface_name,
        evolution_factor = current_factor,
        threshold = th,
        direction = direction or "up",
        include_dominance = include_dominance == true,
        message_localised = msg_localised,
        locale = pending.locale,
        player_index = pending.player_index
      }
      return
    end

    emit_threshold(tick, force_name, current_factor, th, direction, msg_string, msg_localised, surface_name, chat_enabled, include_dominance)
  end

  local function evolution_poll(event)
    if not game then return end
    local cfg = get_config() or {}
    if not cfg.enabled then return end

    local include_dominance = cfg.include_dominance == true
    local notify_chat = cfg.notify_chat == true
    local surface_names = cfg.surface_names or { cfg.default_surface_name or "nauvis" }
    local min_delta = tonumber(cfg.min_delta) or 0

    local force_obj = get_observed_force()
    local thresholds = get_threshold_list()

    for _, surface_name in ipairs(surface_names) do
      local surface = nil
      if surface_name and game.surfaces then
        surface = game.surfaces[surface_name]
      end
      if surface then
        local raw_current = get_force_evolution_factor(force_obj, surface_name)
        local current = tonumber(raw_current) or 0
        local st = ensure_evolution_surface_state(surface_name)
        if not st then return end

        local last_checked = st.last_checked_factor
        if last_checked == nil then last_checked = current end

        st.unlogged_delta = st.unlogged_delta or 0
        local prev_poll = st.prev_poll_factor
        if prev_poll == nil then prev_poll = last_checked or current end
        local delta_since_prev = current - prev_poll
        st.prev_poll_factor = current
        st.unlogged_delta = st.unlogged_delta + delta_since_prev

        if math.abs(st.unlogged_delta) >= min_delta then
          write_evolution_telemetry_line(game.tick, "poll", (force_obj and force_obj.name) or (cfg.force_name or "enemy"), current, {
            delta = st.unlogged_delta,
            include_dominance = include_dominance,
            surface = surface_name
          })
          st.last_logged_factor = current
          st.unlogged_delta = 0
        else
          safe_log({ "telemetry-mod.evolution-poll-skipped" })
        end

        if current >= last_checked then
          for i = 1, #thresholds do
            local th = thresholds[i]
            local v = th and th.value
            if v and last_checked < v and current >= v then
              maybe_emit_threshold(th, force_obj, current, "up", surface_name, notify_chat, include_dominance)
            end
          end
        else
          for i = #thresholds, 1, -1 do
            local th = thresholds[i]
            local v = th and th.value
            if v and last_checked >= v and current < v then
              maybe_emit_threshold(th, force_obj, current, "down", surface_name, false, include_dominance)
            end
          end
        end

        st.last_checked_factor = current
      end
    end
  end

  local function baseline_observed_evolution(trigger_name)
    local cfg = get_config() or {}
    local include_dominance = cfg.include_dominance == true
    local surface_names = cfg.surface_names or { cfg.default_surface_name or "nauvis" }

    local f = get_observed_force()
    if not (f and f.valid) then return end

    ensure_evolution_state()
    for _, surface_name in ipairs(surface_names) do
      local surface = game and game.surfaces and game.surfaces[surface_name]
      if surface then
        local st = ensure_evolution_surface_state(surface_name)
        local current = tonumber(get_force_evolution_factor(f, surface_name)) or 0
        st.last_checked_factor = current
        st.last_logged_factor = current
        st.unlogged_delta = 0
        st.prev_poll_factor = current
        write_evolution_telemetry_line((game and game.tick) or 0, trigger_name or "init", f.name, current, {
          include_dominance = include_dominance,
          surface = surface_name
        })
      end
    end
  end

  return {
    write_evolution_telemetry_line = write_evolution_telemetry_line,
    ensure_evolution_state = ensure_evolution_state,
    ensure_evolution_surface_state = ensure_evolution_surface_state,
    emit_threshold = emit_threshold,
    evolution_poll = evolution_poll,
    baseline_observed_evolution = baseline_observed_evolution
  }
end

return M
