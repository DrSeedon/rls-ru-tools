-- Fix 11 (#457): unique marketplace offer ids
local T = dofile("test_v6_common.lua")
local check = T.check
math.randomseed(42)
local listedVehicles = {
  {id = 6, offers = {{id = 111, value = 1}, {id = 111, value = 2}, {value = 3}}},          -- duplicate + missing
  {id = 7, offers = {["1"] = {value = 4}, ["2"] = {value = 5}, [1] = {id = 222, value = 6}}}, -- 2.6.5 object keys
  {id = 8, offers = {{id = 333, value = 7}}},
}
-- mirrors marketplace.lua: findOfferById + getListings closures over the local listedVehicles
local function findOfferById(offerId)
  for _, listing in ipairs(listedVehicles) do
    for i, offer in ipairs(listing.offers) do if offer.id == offerId then return listing, i, offer end end
  end
end
local function getListings()
  local copy = {}
  for i, l in ipairs(listedVehicles) do copy[i] = l end
  return copy
end
local mp = {getListings = getListings, findOfferById = findOfferById}
career_modules_marketplace = mp
local M = T.load(); M.onUpdate()
check(type(mp.__rlsRuOffers) == "function" and T.countLog("offer-id fix installed") == 1, "installed")
-- ensure() already checked the live table once (load path)
check(T.hasLog("marketplace offers (load): 3 id(s) assigned, 1 duplicate id(s) renumbered, 2 offer(s) re-keyed"), "load-time sanitize logged: " .. tostring(logs[#logs]))
local seen, all = {}, 0
for _, l in ipairs(listedVehicles) do
  local n = 0
  for k in pairs(l.offers) do n = n + 1; check(type(k) == "number", "array keys only") end
  check(n == #l.offers, "no holes")
  for _, o in ipairs(l.offers) do
    all = all + 1
    check(o.id ~= nil and not seen[o.id], "unique id " .. tostring(o.id)); seen[o.id] = true
  end
end
check(all == 7, "no offer lost: " .. all)
check(listedVehicles[1].offers[1].id == 111 and listedVehicles[2].offers[1].id == 222 and listedVehicles[3].offers[1].id == 333, "first occurrences keep their id")
local _, idx, o = findOfferById(listedVehicles[1].offers[2].id)
check(o and o.value == 2, "second duplicate now reachable by id")
-- no-op: clean data -> no change, no log
local n = #logs
mp.getListings()
check(#logs == n, "clean list: no log")
-- new save loaded (new table) with a duplicate -> fixed on the next getListings call
listedVehicles = {{id = 9, offers = {{id = 5, value = 1}, {id = 5, value = 2}}}}
mp.getListings()
check(listedVehicles[1].offers[1].id == 5 and listedVehicles[1].offers[2].id ~= 5, "getListings path fixes duplicates")
check(T.hasLog("marketplace offers (getListings): 0 id(s) assigned, 1 duplicate"), "getListings path logged")
-- and by the periodic check without opening the menu
listedVehicles = {{id = 10, offers = {{value = 1}}}}
for _ = 1, 301 do M.onUpdate() end
check(listedVehicles[1].offers[1].id ~= nil, "periodic load check assigns id")
-- sanitizer on garbage input
check(M._sanitizeOffers(nil).assigned == 0 and M._sanitizeOffers({{offers = "x"}, 5}).assigned == 0, "garbage tolerated")
T.done("MARKETPLACE")
