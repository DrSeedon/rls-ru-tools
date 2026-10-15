-- rls-ru-tools: nil-guards for vanilla career code that RLS loaner vehicles can trip.
--
-- Bug (RLS 2.7.2 + BeamNG 0.39.4): on a police/company loaner shift, career_modules_inventory.getCurrentVehicle()
-- returns an inventory id that is not in getVehicles(). Vanilla career_modules_vehiclePerformance.getVehicleClass()
-- then does `vehicle.certificationData` on nil (vehiclePerformance.lua:518) and the big map (missionScreen
-- resolvePlayerVehicleClass) and the pause menu (onMount) both fail -> "errors everywhere".
-- Fix: return nil for unknown inventory ids, exactly what the callers already handle ("no class info").
--
-- Fix 2 (Job Broker route plan): broker.lua removes route stops only on cancel/abandon/un-plan, never when a job is
-- delivered, so finished loads stay in "Route plan" forever and cannot be removed from the UI. getState() returns
-- the live state.stops / state.plans tables, so we prune them in place: stops whose job is complete/cancelled, and
-- stops that point to neither a job nor a saved plan.
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

local DONE = {complete = true, cancelled = true}

local function pruneRoute(st)
  if type(st) ~= "table" or type(st.stops) ~= "table" then return 0 end
  local jobs, plans = {}, type(st.plans) == "table" and st.plans or {}
  for _, j in ipairs(st.jobs or {}) do if j.id ~= nil then jobs[j.id] = j end end
  local removed = 0
  for i = #st.stops, 1, -1 do
    local id = st.stops[i] and st.stops[i].jobId
    local job = id ~= nil and jobs[id] or nil
    if id == nil or (job and DONE[job.status]) or (not job and plans[id] == nil) then
      table.remove(st.stops, i); removed = removed + 1
    end
  end
  for id, _ in pairs(plans) do
    local job = jobs[id]
    if job and DONE[job.status] then plans[id] = nil end
  end
  return removed
end
M._pruneRoute = pruneRoute

local function ensureBroker()
  local br = career_modules_delivery_broker
  if not br or br.__rlsRuGuard or type(br.getState) ~= "function" then return end
  local orig = br.getState
  br.getState = function(...)
    local st = orig(...)
    local ok, n = pcall(pruneRoute, st)
    if ok and n and n > 0 then log("I", "rlsRuFixes", "route plan: pruned " .. n .. " finished/orphan stop(s)") end
    return st
  end
  br.__rlsRuGuard = true
  log("I", "rlsRuFixes", "route-plan pruning installed on career_modules_delivery_broker")
end

local function ensure()
  ensureBroker()
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
