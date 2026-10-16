-- Fix 7 (#468): one loaner cut only, never negative payout from loaner cuts
local T = dofile("test_v6_common.lua")
local check, near = T.check, T.near

-- port of RLS employment.lua:8893-8930 (applyEmploymentPayToBreakdown); onShift/employer configurable
local shift = {on = false, employer = nil}
local function rlsApply(originalRewards, breakdown, adjustedRewards)
  if not shift.on or not shift.employer or type(breakdown) ~= "table" or type(adjustedRewards) ~= "table" then
    return originalRewards, breakdown, adjustedRewards
  end
  local filtered, changed = {}, false
  for _, bd in ipairs(breakdown) do
    local strip = false
    if bd and bd.simpleBreakdownType == "loaner" then
      for key in pairs(bd.rewards or {}) do
        local orgId = type(key) == "string" and key:match("^(.*)Reputation$")
        if orgId and orgId == shift.employer then strip = true break end
      end
    end
    if strip then
      local cut = tonumber(bd.rewards and bd.rewards.money) or 0
      if cut ~= 0 then adjustedRewards.money = (tonumber(adjustedRewards.money) or 0) - cut; changed = true end
      local rep = {label = bd.label, rewards = {}, simpleBreakdownType = "loaner"}
      for k, v in pairs(bd.rewards or {}) do if k ~= "money" then rep.rewards[k] = v end end
      if next(rep.rewards) then table.insert(filtered, rep) end
    else
      table.insert(filtered, bd)
    end
  end
  if changed then return originalRewards, filtered, adjustedRewards end
  return originalRewards, breakdown, adjustedRewards
end
career_modules_delivery_employment = {applyEmploymentPayToBreakdown = rlsApply}

-- vanilla-shaped breakdown: one loaner entry per org, adjusted = original + sum(breakdown)
local function make(money, entries)
  local orig = {money = money}
  local bd = {}
  for _, e in ipairs(entries) do bd[#bd + 1] = e end
  local adj = {money = money}
  for _, e in ipairs(bd) do for k, v in pairs(e.rewards) do adj[k] = (adj[k] or 0) + v end end
  return orig, bd, adj
end
local function loaner(org, cut, money) return {label = string.format("Loaner Organization (%d%% cut)", cut * 100),
  rewards = {money = -cut * money, [org .. "Reputation"] = 5}, simpleBreakdownType = "loaner"} end

local M = T.load(); M.onUpdate(); M.onUpdate()
local emp = career_modules_delivery_employment
check(emp.__rlsRuLoanerCut == true, "installed")
check(T.countLog("single-loaner-cut fix installed") == 1, "one install log")

-- bug case: #468 truck from org A, trailer from org B, both 80%
local money = 8637
local o, b, a = make(money, {{label = "No Damage", rewards = {money = math.ceil(money * 0.05)}, simpleBreakdownType = "bonus"},
  loaner("hotrolled", 0.8, money), loaner("shuffleboard", 0.8, money)})
check(a.money < 0, "precondition: vanilla stacked cuts give negative payout " .. a.money)
local o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
local nCut, repA, repB = 0, false, false
for _, e in ipairs(b2) do
  if e.simpleBreakdownType == "loaner" then
    if e.rewards.money then nCut = nCut + 1 end
    if e.rewards.hotrolledReputation then repA = true end
    if e.rewards.shuffleboardReputation then repB = true end
  end
end
check(nCut == 1, "exactly one loaner money cut left, got " .. nCut)
check(repA and repB, "both orgs keep their reputation reward")
check(near(a2.money, money + 432 - 0.8 * money), "money = reward + bonus - one cut: " .. tostring(a2.money))
check(o2 == o, "originalRewards untouched")
check(T.hasLog("loaner cut: 2 loaner cuts -> 1"), "change logged")

-- different cut sizes: keep the largest
o, b, a = make(1000, {loaner("a", 0.5, 1000), loaner("b", 0.8, 1000), loaner("c", 0.3, 1000)})
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
local kept
for _, e in ipairs(b2) do if e.rewards.money then kept = e end end
check(kept and kept.rewards.bReputation and near(kept.rewards.money, -800), "largest (80%) cut kept")
check(near(a2.money, 200), "money 200, got " .. tostring(a2.money))

-- clamp: excessive damage zeroes the reward, the single loaner cut must not push below zero
o, b, a = make(1000, {{label = "Excessive Damage", rewards = {money = -1000}, simpleBreakdownType = "bonus"}, loaner("a", 0.8, 1000)})
check(near(a.money, -800), "precondition clamp case")
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
check(near(a2.money, 0), "payout clamped to 0, got " .. tostring(a2.money))
local loanerEntry
for _, e in ipairs(b2) do if e.simpleBreakdownType == "loaner" then loanerEntry = e end end
check(loanerEntry and loanerEntry.rewards.money == nil and loanerEntry.rewards.aReputation == 5, "cut removed, rep kept")

-- no-op: one loaner, positive payout -> identical tables returned
o, b, a = make(1000, {loaner("a", 0.5, 1000)})
local before = #logs
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
check(b2 == b and a2 == a and near(a2.money, 500), "single cut untouched")
check(#logs == before, "no log on no-op")
-- no-op: no loaner at all
o, b, a = make(1000, {{label = "No Damage", rewards = {money = 50}, simpleBreakdownType = "bonus"}})
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
check(b2 == b and a2 == a and a2.money == 1050, "no loaner untouched")

-- on shift: RLS strips the employer's cut first, the other org's single cut stays
shift.on, shift.employer = true, "a"
o, b, a = make(1000, {loaner("a", 0.8, 1000), loaner("b", 0.5, 1000)})
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, a)
check(near(a2.money, 500), "on shift: employer cut stripped by RLS, other org 50% stays: " .. tostring(a2.money))
shift.on = false

-- error inside the fix -> RLS result returned unchanged
local bad = setmetatable({}, {__index = function() error("boom") end})
o, b = make(1000, {loaner("a", 0.8, 1000), loaner("b", 0.8, 1000)})
o2, b2, a2 = emp.applyEmploymentPayToBreakdown(o, b, bad)
check(b2 == b and a2 == bad and T.hasLog("loaner cut: error"), "error falls back to original result")

-- module table replaced -> re-installed
career_modules_delivery_employment = {applyEmploymentPayToBreakdown = rlsApply}
M.onUpdate()
check(career_modules_delivery_employment.__rlsRuLoanerCut == true and T.countLog("single-loaner-cut fix installed") == 2, "re-install on new module table")
T.done("LOANER_CUT")
