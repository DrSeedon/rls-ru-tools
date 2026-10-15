-- rls-ru-tools: nil-guards for vanilla career code that RLS loaner vehicles can trip.
--
-- Bug (RLS 2.7.2 + BeamNG 0.39.4): on a police/company loaner shift, career_modules_inventory.getCurrentVehicle()
-- returns an inventory id that is not in getVehicles(). Vanilla career_modules_vehiclePerformance.getVehicleClass()
-- then does `vehicle.certificationData` on nil (vehiclePerformance.lua:518) and the big map (missionScreen
-- resolvePlayerVehicleClass) and the pause menu (onMount) both fail -> "errors everywhere".
-- Fix: return nil for unknown inventory ids, exactly what the callers already handle ("no class info").
local M = {}

local GUARDED = {"getVehicleClass", "getAggregateScoresFromVehId"}

local function guard(mod, name)
  local orig = mod[name]
  if type(orig) ~= "function" then return false end
  mod[name] = function(inventoryId, ...)
    local inv = career_modules_inventory
    local vehicles = inv and inv.getVehicles and inv.getVehicles()
    if inventoryId == nil or type(vehicles) ~= "table" or vehicles[inventoryId] == nil then
      return nil
    end
    return orig(inventoryId, ...)
  end
  return true
end

local function ensure()
  local vp = career_modules_vehiclePerformance
  if vp and not vp.__rlsRuGuard then
    local n = 0
    for _, name in ipairs(GUARDED) do
      if guard(vp, name) then n = n + 1 end
    end
    vp.__rlsRuGuard = true
    log("I", "rlsRuFixes", "nil-guard installed on career_modules_vehiclePerformance (" .. n .. " functions)")
  end
end

M.onExtensionLoaded = ensure
M.onCareerActive = ensure
M.onUpdate = ensure -- one table lookup per frame; re-installs if the career module is reloaded

return M
