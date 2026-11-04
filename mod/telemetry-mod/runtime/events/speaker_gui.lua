-- Mod GUI for per-speaker telemetry opt-in.

local M = {}

local GUI_FRAME_NAME = "telemetry_mod_speaker_frame"
local GUI_CHECKBOX_NAME = "telemetry_mod_speaker_enabled_checkbox"

function M.new(opts)
  local get_speaker_enabled = assert(opts.get_speaker_enabled, "get_speaker_enabled is required")
  local set_speaker_enabled = assert(opts.set_speaker_enabled, "set_speaker_enabled is required")

  local function trim(value)
    local s = tostring(value or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
  end

  local function get_player(player_index)
    if not (game and game.get_player and player_index) then return nil end
    local p = game.get_player(player_index)
    if p and p.valid then return p end
    return nil
  end

  local function ensure_notify_state()
    if not storage then return nil end
    storage.telemetry_notify_state = storage.telemetry_notify_state or {}
    local st = storage.telemetry_notify_state
    st.speaker_gui_players = st.speaker_gui_players or {}
    return st
  end

  local function set_player_opened_unit(player_index, unit_key)
    local st = ensure_notify_state()
    if not st then return end
    if unit_key and unit_key ~= "" then
      st.speaker_gui_players[tostring(player_index)] = tostring(unit_key)
    else
      st.speaker_gui_players[tostring(player_index)] = nil
    end
  end

  local function get_player_opened_unit(player_index)
    local st = ensure_notify_state()
    if not st then return nil end
    local value = st.speaker_gui_players[tostring(player_index)]
    if value == nil then return nil end
    local key = trim(value)
    if key == "" then return nil end
    return key
  end

  local function destroy_gui_for_player(player)
    if not (player and player.valid) then return end
    local root = player.gui.left[GUI_FRAME_NAME]
    if root and root.valid then
      root.destroy()
    end
  end

  local function is_programmable_speaker(entity)
    return entity and entity.valid and entity.name == "programmable-speaker" and entity.unit_number ~= nil
  end

  local function build_gui_for_player(player, entity)
    destroy_gui_for_player(player)
    if not is_programmable_speaker(entity) then
      set_player_opened_unit(player.index, nil)
      return
    end

    local unit_key = tostring(entity.unit_number)
    set_player_opened_unit(player.index, unit_key)
    local enabled = get_speaker_enabled(unit_key) == true

    local root = player.gui.left.add({
      type = "frame",
      name = GUI_FRAME_NAME,
      direction = "vertical",
      caption = { "telemetry-mod.speaker-gui-title" }
    })
    root.style.top_padding = 8
    root.style.bottom_padding = 8
    root.style.left_padding = 8
    root.style.right_padding = 8

    root.add({
      type = "checkbox",
      name = GUI_CHECKBOX_NAME,
      state = enabled,
      caption = { "telemetry-mod.speaker-gui-enable" },
      tags = {
        telemetry_speaker_toggle = true,
        speaker_unit_key = unit_key
      }
    })
    root.add({
      type = "label",
      caption = { "telemetry-mod.speaker-gui-help" }
    })
  end

  local function on_gui_opened(event)
    if not event or not event.player_index then return end
    local player = get_player(event.player_index)
    if not player then return end

    local entity = event.entity
    if event.gui_type == defines.gui_type.entity and is_programmable_speaker(entity) then
      build_gui_for_player(player, entity)
      return
    end

    set_player_opened_unit(player.index, nil)
    destroy_gui_for_player(player)
  end

  local function on_gui_closed(event)
    if not event or not event.player_index then return end
    local player = get_player(event.player_index)
    if not player then return end
    set_player_opened_unit(player.index, nil)
    destroy_gui_for_player(player)
  end

  local function on_gui_checked_state_changed(event)
    if not (event and event.element and event.element.valid and event.player_index) then return end
    local element = event.element
    if element.name ~= GUI_CHECKBOX_NAME then return end

    local tags = element.tags or {}
    if tags.telemetry_speaker_toggle ~= true then return end

    local unit_key = trim(tags.speaker_unit_key)
    if unit_key == "" then
      unit_key = get_player_opened_unit(event.player_index) or ""
    end
    if unit_key == "" then return end

    set_speaker_enabled(unit_key, element.state == true)
  end

  local function on_entity_settings_pasted(event)
    if not event then return end
    local source = event.source
    local destination = event.destination
    if not (is_programmable_speaker(source) and is_programmable_speaker(destination)) then return end

    local source_key = tostring(source.unit_number)
    local destination_key = tostring(destination.unit_number)
    local source_enabled = get_speaker_enabled(source_key) == true
    set_speaker_enabled(destination_key, source_enabled)
  end

  return {
    on_gui_opened = on_gui_opened,
    on_gui_closed = on_gui_closed,
    on_gui_checked_state_changed = on_gui_checked_state_changed,
    on_entity_settings_pasted = on_entity_settings_pasted
  }
end

return M
