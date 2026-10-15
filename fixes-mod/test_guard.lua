logs = {}
function log(l, t, m) logs[#logs+1] = m end
career_modules_inventory = { getVehicles = function() return { [5] = { certificationData = {x=1} } } end }
career_modules_vehiclePerformance = { getVehicleClass = function(id)
  local v = career_modules_inventory.getVehicles()[id]; local c = v.certificationData; return {class={name="A"}} end,
  getAggregateScoresFromVehId = function(id) return career_modules_inventory.getVehicles()[id].certificationData end }
package.path = "./lua/ge/extensions/?.lua;" .. package.path
local M = require("rlsRuFixes")
M.onUpdate(); M.onUpdate()
local vp = career_modules_vehiclePerformance
print("unknown id ->", vp.getVehicleClass(99), vp.getAggregateScoresFromVehId(99))
print("nil id ->", vp.getVehicleClass(nil))
print("known id ->", vp.getVehicleClass(5).class.name, vp.getAggregateScoresFromVehId(5).x)
print("logs:", #logs, logs[1])
career_modules_vehiclePerformance = { getVehicleClass = function(id) return career_modules_inventory.getVehicles()[id].certificationData end }
M.onUpdate(); print("after reload unknown ->", career_modules_vehiclePerformance.getVehicleClass(42), #logs)
