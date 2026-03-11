-- Evolution threshold definitions and helper functions.

local M = {}

local EVOLUTION_THRESHOLDS_CORE = {
  { value = 0.20, kind = "tier", key = "medium_biter", message = { "telemetry-mod.evolution-core-medium-biter" } },
  { value = 0.25, kind = "tier", key = "small_spitter", message = { "telemetry-mod.evolution-core-small-spitter" } },
  { value = 0.30, kind = "tier", key = "medium_worm", message = { "telemetry-mod.evolution-core-medium-worm" } },
  { value = 0.40, kind = "tier", key = "medium_spitter", message = { "telemetry-mod.evolution-core-medium-spitter" } },
  { value = 0.50, kind = "tier", key = "big_biter_spitter_worm", message = { "telemetry-mod.evolution-core-big-biter-spitter-worm" } },
  { value = 0.60, kind = "tier", key = "no_small_biter", message = { "telemetry-mod.evolution-core-no-small-biter" } },
  { value = 0.70, kind = "tier", key = "no_small_spitter", message = { "telemetry-mod.evolution-core-no-small-spitter" } },
  { value = 0.90, kind = "tier", key = "behemoth", message = { "telemetry-mod.evolution-core-behemoth" } }
}

local EVOLUTION_THRESHOLDS_RAMPANT_FIXED = {
  { value = 0.10, kind = "tier", key = "tier_2", message = { "telemetry-mod.evolution-rampant-tier-2" } },
  { value = 0.22, kind = "tier", key = "tier_3", message = { "telemetry-mod.evolution-rampant-tier-3" } },
  { value = 0.38, kind = "tier", key = "tier_4", message = { "telemetry-mod.evolution-rampant-tier-4" } },
  { value = 0.47, kind = "tier", key = "tier_5", message = { "telemetry-mod.evolution-rampant-tier-5" } },
  { value = 0.65, kind = "tier", key = "tier_6", message = { "telemetry-mod.evolution-rampant-tier-6" } },
  { value = 0.74, kind = "tier", key = "tier_7", message = { "telemetry-mod.evolution-rampant-tier-7" } },
  { value = 0.80, kind = "tier", key = "tier_8", message = { "telemetry-mod.evolution-rampant-tier-8" } },
  { value = 0.85, kind = "tier", key = "tier_9", message = { "telemetry-mod.evolution-rampant-tier-9" } },
  { value = 0.91, kind = "tier", key = "tier_10", message = { "telemetry-mod.evolution-rampant-tier-10" } },
  { value = 0.936, kind = "tier", key = "tier_10_25", message = { "telemetry-mod.evolution-rampant-tier-10-25" } },
  { value = 0.943, kind = "tier", key = "tier_10_33", message = { "telemetry-mod.evolution-rampant-tier-10-33" } },
  { value = 0.955, kind = "tier", key = "tier_10_50", message = { "telemetry-mod.evolution-rampant-tier-10-50" } },
  { value = 0.9705, kind = "tier", key = "tier_10_75", message = { "telemetry-mod.evolution-rampant-tier-10-75" } }
}

local EVOLUTION_THRESHOLDS_DOMINANCE = {
  { value = 0.36, kind = "dominance", key = "medium_biter_majority", message = { "telemetry-mod.evolution-dominance-medium-biter-majority" } },
  { value = 0.68, kind = "dominance", key = "big_biter_majority", message = { "telemetry-mod.evolution-dominance-big-biter-majority" } },
  { value = 0.78, kind = "dominance", key = "big_spitter_majority", message = { "telemetry-mod.evolution-dominance-big-spitter-majority" } },
  { value = 0.916, kind = "dominance", key = "behemoth_visible_10", message = { "telemetry-mod.evolution-dominance-behemoth-visible-10" } },
  { value = 0.938, kind = "dominance", key = "behemoth_visible_20", message = { "telemetry-mod.evolution-dominance-behemoth-visible-20" } }
}

local function is_rampant_fixed_loaded()
  if script and script.active_mods then
    return script.active_mods["RampantFixed"] ~= nil
  end
  if game and game.active_mods then
    return game.active_mods["RampantFixed"] ~= nil
  end
  return false
end

function M.get_observed_force(force_name)
  if not game or not game.forces then return nil end
  if force_name and game.forces[force_name] then
    return game.forces[force_name]
  end
  return game.forces.enemy
end

function M.get_force_evolution_factor(force_obj, surface_name)
  if not (force_obj and force_obj.valid) then return nil end
  local surface = nil
  if surface_name and game and game.surfaces then
    surface = game.surfaces[surface_name]
  end
  if force_obj.get_evolution_factor then
    local ok, value = pcall(function()
      if surface then
        return force_obj.get_evolution_factor(surface)
      end
      return force_obj.get_evolution_factor()
    end)
    if ok then return value end
  end
  local ok, value = pcall(function()
    return force_obj.evolution_factor
  end)
  if ok then return value end
  return nil
end

function M.get_threshold_list(include_dominance)
  local list = {}
  local core = is_rampant_fixed_loaded() and EVOLUTION_THRESHOLDS_RAMPANT_FIXED or EVOLUTION_THRESHOLDS_CORE
  for i = 1, #core do
    list[#list + 1] = core[i]
  end
  if (not is_rampant_fixed_loaded()) and include_dominance then
    for i = 1, #EVOLUTION_THRESHOLDS_DOMINANCE do
      list[#list + 1] = EVOLUTION_THRESHOLDS_DOMINANCE[i]
    end
  end
  table.sort(list, function(a, b) return (a.value or 0) < (b.value or 0) end)
  return list
end

return M
