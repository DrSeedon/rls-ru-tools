-- Fix 10 (#353/#355): nil position never reaches map.findClosestRoad
local T = dofile("test_v6_common.lua")
local check = T.check
map = {findClosestRoad = function(pos) local _ = pos.x; return "n1", 1, 0 end} -- vanilla map.lua:2518 indexes pos
local scanner = {}
function scanner.getDistanceBetweenLocations(a, b) map.findClosestRoad(a); map.findClosestRoad(b); return 42, true end
package.loaded["gameplay/delivery/facilityScanner"] = scanner
career_modules_delivery_generator = {distanceBetween = scanner.getDistanceBetweenLocations}
check(not pcall(scanner.getDistanceBetweenLocations, nil, {x = 1}), "precondition: nil crashes")

local M = T.load(); M.onUpdate(); M.onUpdate()
check(scanner.__rlsRuDist and career_modules_delivery_generator.__rlsRuDist, "installed on both")
check(T.countLog("nil-position guard installed") == 2, "two install logs")
local d, rel = scanner.getDistanceBetweenLocations(nil, {x = 1})
check(d == 0 and rel == false, "nil A -> 0,false")
d, rel = career_modules_delivery_generator.distanceBetween({x = 1}, nil)
check(d == 0 and rel == false, "generator export nil B -> 0,false")
check(T.hasLog("distance guard: nil position (A)"), "hit logged")
-- no-op
d, rel = scanner.getDistanceBetweenLocations({x = 1}, {x = 2})
check(d == 42 and rel == true, "valid positions -> original")
T.done("DISTANCE")
