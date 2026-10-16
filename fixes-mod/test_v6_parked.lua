-- Fix 6 (#422 risk): forklifts / loaders / forkable loads never come out of the parked passthrough
local T = dofile("test_v6_common.lua")
local check = T.check
local calls, pool = {}, nil
local function vanillaCreate(amount, params)
  calls[#calls + 1] = "vanilla"
  local out = {}
  for i = 1, amount do out[i] = pool[(i - 1) % #pool + 1] end
  return out
end
local originalCreateGroup = vanillaCreate
local function rlsWrapped(amount, params) calls[#calls + 1] = "rls"; local _ = originalCreateGroup; return {{model = "rls", config = "x"}} end
core_multiSpawn = {createGroup = rlsWrapped, _rlsTrafficConfigFilterWrapped = true}
local M = T.load(); M.onUpdate()
local parked = {filters = {Type = {propparked = 1}}}
pool = {{model = "pickup", config = "parked_a"}, {model = "TPUMedForklift", config = "FL45D Simplex"},
  {model = "TPUForkableLoads", config = "Crate"}, {model = "wl40", config = "Montevalle Block Forks Lite"},
  {model = "covet", config = "parked_b"}}
local g = core_multiSpawn.createGroup(5, parked)
check(#g == 2 and g[1].model == "pickup" and g[2].model == "covet", "only road cars kept: " .. #g)
check(T.hasLog("parked group: excluded 3 forklift/loader/prop config(s)"), "exclusion logged")
-- no-op: clean pool
local n = #logs
pool = {{model = "pickup", config = "parked_a"}, {model = "covet", config = "parked_b"}}
g = core_multiSpawn.createGroup(4, parked)
check(#g == 4 and calls[#calls] == "vanilla" and not T.hasLog("excluded 0"), "clean pool unchanged")
-- everything excluded -> RLS filtered path as before
pool = {{model = "TPUMedForklift", config = "FL55D Towbar"}}
g = core_multiSpawn.createGroup(3, parked)
check(calls[#calls] == "rls" and g[1].model == "rls", "all excluded -> RLS createGroup")
-- traffic requests untouched
core_multiSpawn.createGroup(3, {filters = {Type = {car = 1}}})
check(calls[#calls] == "rls", "traffic keeps RLS filter")
check(M._filterParkedGroup({{model = "pickup", config = "forklift_bed"}}) and #M._filterParkedGroup({{model = "pickup", config = "forklift_bed"}}) == 0, "config-name marker excluded")
T.done("PARKED_V6")
