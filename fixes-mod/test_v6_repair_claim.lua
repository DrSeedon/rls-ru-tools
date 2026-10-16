-- Fix 8 (#352): makeRepairClaim with {deductible = {money = N}}
local T = dofile("test_v6_common.lua")
local check = T.check
local claims = {}
-- port of RLS insurance.lua:663-667 + the history deductible read (line 696)
local function rlsMakeRepairClaim(invVehId, costs, vehInfo)
  local totalCost = 0
  for _, cost in pairs(costs) do totalCost = totalCost + cost end
  claims[#claims + 1] = {id = invVehId, total = totalCost, deductible = costs.deductible or 0, costs = costs}
  return true
end
career_modules_insurance_insurance = {makeRepairClaim = rlsMakeRepairClaim}
check(not pcall(rlsMakeRepairClaim, 1, {deductible = {money = 1000}}, {}), "precondition: RLS throws on table cost")

local M = T.load(); M.onUpdate(); M.onUpdate()
local ins = career_modules_insurance_insurance
check(ins.__rlsRuRepairClaim == true and T.countLog("table-cost fix installed") == 1, "installed once")

-- bug case: missionManager.lua:695 shape
local ok = pcall(ins.makeRepairClaim, 7, {deductible = {money = 1000}}, {})
check(ok and claims[#claims].total == 1000 and claims[#claims].deductible == 1000, "money repair: total 1000")
check(T.hasLog("repair claim: table-shaped cost normalised"), "change logged")
ok = pcall(ins.makeRepairClaim, 7, {deductible = {vouchers = 1}}, {})
check(ok and claims[#claims].total == 0, "voucher repair: money 0")

-- no-op: numeric cost passes the very same table
local n = #logs
local costs = {deductible = 500}
ins.makeRepairClaim(8, costs, {})
check(claims[#claims].costs == costs and claims[#claims].total == 500 and #logs == n, "numeric cost untouched, no log")

-- re-install on module reload
career_modules_insurance_insurance = {makeRepairClaim = rlsMakeRepairClaim}
M.onUpdate()
check(career_modules_insurance_insurance.__rlsRuRepairClaim == true, "re-installed")
T.done("REPAIR_CLAIM")
