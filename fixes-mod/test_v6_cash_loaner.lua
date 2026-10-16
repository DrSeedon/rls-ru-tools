-- Fix 9 (#488): cash contracts only get loaners with a cash container
local T = dofile("test_v6_common.lua")
local check = T.check
local profiles = {
  ["md_series/mediumboxtruck196979"] = {model = "md_series", config = "mediumboxtruck196979", capacityByType = {parcel = 40}, materialTypes = {}, parcelSlots = 40, hasCargoBoxes = true},
  ["md_series/large_money_transport_career"] = {model = "md_series", config = "large_money_transport_career", capacityByType = {}, materialTypes = {}, parcelSlots = 0, hasCargoBoxes = false},
  ["md_series/armor_x"] = {model = "md_series", config = "armor_x", capacityByType = {cash = 500}, materialTypes = {}, parcelSlots = 0, hasCargoBoxes = false},
  ["van/plainvan"] = {model = "van", config = "plainvan", capacityByType = {}, materialTypes = {}, parcelSlots = 0, hasCargoBoxes = true},
  ["us_semi/rigidtanker"] = {model = "us_semi", config = "rigidtanker", capacityByType = {fluid = 9000}, materialTypes = {fluid = true}, parcelSlots = 0, hasCargoBoxes = false},
}
core_vehicles = {getConfigParts = function(model, config)
  if config == "plainvan" then return {van_body = "van_body_armored_load_money"} end
  return {body = "generic"}
end}
local caps = {}
function caps.getProfile(offer) return offer and profiles[tostring(offer.model) .. "/" .. tostring(offer.config)] end
function caps.canDoParcelJob(offer)
  local p = caps.getProfile(offer)
  if not p or p.isTrailer then return false end
  return p.hasCargoBoxes or p.parcelSlots > 0
end
local MAT = {fluid = true, dryBulk = true, cement = true}
-- port of loanerCapabilities.lua:266-286
function caps.canHaulMaterial(offer, cargoType, minAmount)
  if cargoType == "cash" then return caps.canDoParcelJob(offer) end
  if not cargoType or not MAT[cargoType] then return false end
  local p = caps.getProfile(offer)
  if not p then return false end
  return p.materialTypes[cargoType] and true or false
end
-- internal caller pattern: pickBest(trucks, function(item) return M.canHaulMaterial(item, cargoType) end)
function caps.pick(list, cargoType)
  for _, item in ipairs(list) do if caps.canHaulMaterial(item, cargoType) then return item end end
end
career_modules_delivery_loanerCapabilities = caps
local box = {model = "md_series", config = "mediumboxtruck196979"}
local money = {model = "md_series", config = "large_money_transport_career"}
local armorCap = {model = "md_series", config = "armor_x"}
local partsVan = {model = "van", config = "plainvan"}
local tanker = {model = "us_semi", config = "rigidtanker"}
check(caps.canHaulMaterial(box, "cash") == true, "precondition: RLS gives the box truck to cash")
check(caps.pick({box, money}, "cash") == box, "precondition: RLS picks the box truck first")

local M = T.load(); M.onUpdate(); M.onUpdate()
check(caps.__rlsRuCash == true and T.countLog("cash-capacity check installed") == 1, "installed once")
check(caps.canHaulMaterial(box, "cash") == false, "box truck rejected for cash")
check(T.hasLog("cash loaner: md_series/mediumboxtruck196979 rejected for cash"), "rejection logged")
check(caps.canHaulMaterial(money, "cash") == true, "money transport (name) allowed")
check(caps.canHaulMaterial(armorCap, "cash") == true, "cash capacity allowed")
check(caps.canHaulMaterial(partsVan, "cash") == true, "money part allowed")
check(caps.pick({box, money}, "cash") == money, "internal M.canHaulMaterial call now picks the money truck")
local n = #logs
caps.canHaulMaterial(box, "cash")
check(#logs == n, "rejection logged once per config")
-- no-op: other cargo types and unknown profiles keep RLS answer
check(caps.canHaulMaterial(tanker, "fluid") == true and caps.canHaulMaterial(box, "fluid") == false, "fluid untouched")
check(caps.canHaulMaterial({model = "x", config = "y"}, "cash") == false, "unknown profile -> RLS answer")
-- error in evidence -> RLS answer
local savedGP = caps.getProfile
local first = true
caps.getProfile = function(o) if first then first = false; error("boom") end return savedGP(o) end
check(caps.canHaulMaterial(box, "cash") == true and T.hasLog("cash loaner: error"), "error -> RLS rule")
caps.getProfile = savedGP
T.done("CASH_LOANER")
