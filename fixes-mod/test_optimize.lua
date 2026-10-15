-- luajit test_optimize.lua  (run from /tmp/route-opt)
-- Mocks the bits of BeamNG/RLS the capacity-aware auto-order touches; the "original" optimizeStops below is a
-- line-for-line port of broker.lua:347-371 using the same mocked road distance.
package.path = "./lua/ge/extensions/?.lua;" .. package.path
local fails, checks = 0, 0
local function check(cond, msg) checks = checks + 1; if not cond then fails = fails + 1; print("FAIL: " .. msg) end end

logs = {}
function log(l, t, m) logs[#logs + 1] = l .. " " .. m end
function getCurrentLevelIdentifier() return "west_coast_usa" end
local function deepcopy(t) if type(t) ~= "table" then return t end local r = {} for k, v in pairs(t) do r[k] = deepcopy(v) end return r end

-- road distance: Manhattan grid with a one-way penalty when driving east; optional failure mode
local routeFails, routeCalls = false, 0
local function road(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  return math.abs(dx) + math.abs(dy) + (dx > 0 and 0.15 * dx or 0)
end
package.preload["gameplay/route/route"] = function()
  return function()
    return {setupPath = function(self, a, b)
      routeCalls = routeCalls + 1
      if routeFails then self.path = {} return end
      self.path = {{distToTarget = road(a, b)}}
    end}
  end
end
package.preload["gameplay/delivery/brokerRules"] = function() return dofile("/tmp/rlsru/lua/ge/extensions/gameplay/delivery/brokerRules.lua") end
local rules = require("gameplay/delivery/brokerRules")

local START = {x = 0, y = 0, z = 0}
function getPlayerVehicle() return {getPosition = function() return START end, getID = function() return 1 end} end
core_camera = {getPosition = function() return START end}
career_modules_delivery_generator = {getLocationCoordinates = function(loc) return loc.pos end}
overhaul_playerVehicles = {getPlayerVehicleIds = function() return {1, 2} end}
local containers = {}
career_modules_delivery_general = {getMostRecentCargoContainerData = function() return containers end}

-- broker mock with live state tables
local state
local origCalls = 0
local function origOptimize()
  origCalls = origCalls + 1
  if #state.stops < 2 then return false, 'Add more stops to order them.' end
  local remaining, ordered, cur = deepcopy(state.stops), {}, START
  while #remaining > 0 do
    local bestI, bestD
    for i, stop in ipairs(remaining) do
      local blocked = false
      if stop.kind == 'delivery' then
        for _, o in ipairs(remaining) do if o ~= stop and o.jobId == stop.jobId and o.kind == 'pickup' then blocked = true break end end
      end
      if not blocked then
        local pos = stop.location.pos
        local d = pos and road(cur, pos) or math.huge
        if not bestD or d < bestD then bestI, bestD = i, d end
      end
    end
    if not bestI then break end
    local stop = table.remove(remaining, bestI)
    ordered[#ordered + 1] = stop; cur = stop.location.pos or cur
  end
  for _, stop in ipairs(remaining) do ordered[#ordered + 1] = stop end
  if not rules.validStopOrder(ordered) then return false, 'Could not order the stops.' end
  state.stops = ordered
  return true, 'Stops ordered by shortest drive.'
end
career_modules_delivery_broker = {
  getState = function()
    local jobs = {}
    for _, j in pairs(state.jobs) do jobs[#jobs + 1] = deepcopy(j) end
    return {stops = state.stops, plans = state.plans, jobs = jobs}
  end,
  optimizeStops = origOptimize,
}

local M = require("rlsRuFixes")
M.onUpdate(); M.onUpdate()
local br = career_modules_delivery_broker
check(br.__rlsRuOptimize and br.__rlsRuGuard, "both broker wrappers installed")

-- helpers ------------------------------------------------------------------------------------------------------
local rng = 12345
local function rand(n) rng = (rng * 1103515245 + 12345) % 2147483648; return rng % n end
local function P(x, y) return {x = x, y = y, z = 0} end
local function routeCost(stops)
  local total, cur = 0, START
  for _, s in ipairs(stops) do total = total + road(cur, s.location.pos); cur = s.location.pos end
  return total
end
local stopN = 0
local function addJob(st, id, kind, fields, from, tos)
  local job = {id = id, kind = kind, status = 'reserved', quantity = 1}
  for k, v in pairs(fields or {}) do job[k] = v end
  st.jobs[id] = job
  stopN = stopN + 1
  st.stops[#st.stops + 1] = {id = 'stop:' .. stopN, jobId = id, kind = 'pickup', location = {pos = from}}
  for _, to in ipairs(tos) do
    stopN = stopN + 1
    st.stops[#st.stops + 1] = {id = 'stop:' .. stopN, jobId = id, kind = 'delivery', location = {pos = to}}
  end
  return job
end
local function parcelBox(total, cargo) return {vehId = 1, containerId = 1, attachmentStatus = 'attached', cargoTypesLookup = {parcel = true}, totalCargoSlots = total, rawCargo = cargo or {}, transientCargo = {}} end
-- simulated load per dimension, using the same semantics as the game (deliveries release the job's load)
local function peakLoad(stops, jobs, dimOf, loadOf, initial)
  local run, peak, picked = {}, {}, {}
  for jid, v in pairs(initial or {}) do local d = dimOf(jobs[jid]); run[d] = (run[d] or 0) + v end
  for d, v in pairs(run) do peak[d] = v end
  local lastDel = {}
  for i, s in ipairs(stops) do if s.kind == 'delivery' then lastDel[s.jobId] = i end end
  for i, s in ipairs(stops) do
    local j = jobs[s.jobId]; local d = dimOf(j)
    if s.kind == 'pickup' then
      picked[s.jobId] = true
      run[d] = (run[d] or 0) + loadOf(j); peak[d] = math.max(peak[d] or 0, run[d])
    elseif lastDel[s.jobId] == i then
      run[d] = (run[d] or 0) - (picked[s.jobId] and loadOf(j) or 0) - ((initial or {})[s.jobId] or 0)
    end
  end
  return peak
end
local function sameSet(a, b)
  if #a ~= #b then return false end
  local seen = {}
  for _, s in ipairs(a) do seen[s] = true end
  for _, s in ipairs(b) do if not seen[s] then return false end end
  return true
end
local parcelDim = function(j) return j.kind end
local qtyOf = function(j) return j.quantity end

-- 1) random parcel instances with capacity: precedence, capacity, identity, distance vs capacity-aware greedy ------
for _, CAP in ipairs({4, 6}) do
local stats = {n = 0, sumOurs = 0, sumOrig = 0, origOver = 0, oursOver = 0, invalid = 0, better = 0, worseThanFeasibleGreedy = 0, sumGreedyCap = 0}
for inst = 1, 150 do
  local st = {jobs = {}, plans = {}, stops = {}}
  local nJobs = 3 + rand(10)
  for k = 1, nJobs do
    addJob(st, 'job:' .. inst .. ':' .. k, 'parcel', {quantity = 1 + rand(4)}, P(rand(2000) - 1000, rand(2000) - 1000), {P(rand(2000) - 1000, rand(2000) - 1000)})
  end
  -- original
  state = deepcopy(st); origOptimize(); local origOrder = state.stops
  local origCost = routeCost(origOrder)
  if peakLoad(origOrder, st.jobs, parcelDim, qtyOf).parcel > CAP then stats.origOver = stats.origOver + 1 end
  -- capacity-aware greedy only (no improvement) for reference, through the pure planner
  -- ours
  state = deepcopy(st); containers = {parcelBox(CAP)}
  local live = state.stops; local before = {}
  for i, s in ipairs(live) do before[i] = s end
  local ok, msg = br.optimizeStops()
  check(ok == true and msg == 'Stops ordered by shortest drive within cargo space.', "random cap instance ok: " .. tostring(msg))
  check(state.stops == live, "stops rewritten in place")
  check(sameSet(before, state.stops), "same stop objects")
  if not rules.validStopOrder(state.stops) then stats.invalid = stats.invalid + 1 end
  if peakLoad(state.stops, st.jobs, parcelDim, qtyOf).parcel > CAP then stats.oursOver = stats.oursOver + 1 end
  local c = routeCost(state.stops)
  -- feasible greedy cost from the log line
  local g = logs[#logs]:match("greedy (%d+)%->")
  stats.sumGreedyCap = stats.sumGreedyCap + (tonumber(g) or c)
  if tonumber(g) and c > tonumber(g) + 1 then stats.worseThanFeasibleGreedy = stats.worseThanFeasibleGreedy + 1 end
  stats.n = stats.n + 1; stats.sumOurs = stats.sumOurs + c; stats.sumOrig = stats.sumOrig + origCost
end
check(stats.invalid == 0, "capacity instances: all orders valid")
check(stats.oursOver == 0, "capacity instances: capacity never exceeded")
check(stats.worseThanFeasibleGreedy == 0, "capacity instances: never worse than capacity-aware greedy")
print(string.format("[cap=%d] %d instances: original greedy over capacity in %d; ours over capacity in %d; invalid %d",
  CAP, stats.n, stats.origOver, stats.oursOver, stats.invalid))
print(string.format("[cap=%d] total distance: ours %.0f, capacity-aware greedy %.0f (%.1f%% shorter), original (ignores capacity) %.0f",
  CAP, stats.sumOurs, stats.sumGreedyCap, 100 * (1 - stats.sumOurs / stats.sumGreedyCap), stats.sumOrig))

end

-- 2) unknown capacity -> precedence only; never longer than the original greedy -------------------------------
containers = {}
local s2 = {n = 0, ours = 0, orig = 0, worse = 0, strictlyBetter = 0, maxGain = 0}
for inst = 1, 200 do
  local st = {jobs = {}, plans = {}, stops = {}}
  local nJobs = 2 + rand(13)
  for k = 1, nJobs do
    addJob(st, 'u:' .. inst .. ':' .. k, 'parcel', {quantity = 1 + rand(6)}, P(rand(3000) - 1500, rand(3000) - 1500), {P(rand(3000) - 1500, rand(3000) - 1500)})
  end
  state = deepcopy(st); origOptimize(); local oc = routeCost(state.stops)
  state = deepcopy(st)
  local ok, msg = br.optimizeStops()
  check(ok == true and msg == 'Stops ordered by shortest drive.', "unknown capacity message")
  check(rules.validStopOrder(state.stops), "unknown capacity: valid order")
  local c = routeCost(state.stops)
  if c > oc + 1e-6 then s2.worse = s2.worse + 1 end
  if c < oc - 1e-6 then s2.strictlyBetter = s2.strictlyBetter + 1 end
  s2.maxGain = math.max(s2.maxGain, 1 - c / oc)
  s2.n = s2.n + 1; s2.ours = s2.ours + c; s2.orig = s2.orig + oc
end
check(s2.worse == 0, "unknown capacity: never longer than original greedy")
check(logs[#logs]:find("capacity unknown", 1, true) ~= nil, "unknown capacity logged")
print(string.format("[no capacity] %d instances (2-14 jobs): ours %.0f vs original %.0f -> %.1f%% shorter overall; better in %d, equal in %d, worse in %d; best single gain %.1f%%",
  s2.n, s2.ours, s2.orig, 100 * (1 - s2.ours / s2.orig), s2.strictlyBetter, s2.n - s2.strictlyBetter - s2.worse, s2.worse, 100 * s2.maxGain))

-- 3) already-loaded cargo + foreign cargo occupy capacity ---------------------------------------------------------
do
  local st = {jobs = {}, plans = {}, stops = {}}
  addJob(st, 'A', 'parcel', {quantity = 4, status = 'active'}, P(10, 0), {P(900, 0)})     -- aboard, pickup stop stale
  addJob(st, 'B', 'parcel', {quantity = 3}, P(20, 0), {P(30, 0)})                        -- near, but must wait for A
  state = deepcopy(st)
  -- box 9: A's 4 slots + 2 slots of unrelated (vanilla) cargo => 3 free; B (3) fits only... exactly; make it not fit:
  containers = {parcelBox(8, {{slots = 4, data = {brokerId = 'A'}}, {slots = 2, data = {}}})}
  local ok, msg = br.optimizeStops()
  local ids = {}
  for _, s in ipairs(state.stops) do ids[#ids + 1] = s.jobId .. "/" .. s.kind .. (s.collected and "*" or "") end
  local order = table.concat(ids, ",")
  check(ok and order == "A/delivery*,B/pickup,B/delivery", "loaded cargo counted, stale pickup removed: " .. order)
  check(rules.validStopOrder(state.stops), "loaded-cargo order valid")
  -- with room for both, B goes first (shorter), A's delivery still flagged collected
  state = deepcopy(st); containers = {parcelBox(12, {{slots = 4, data = {brokerId = 'A'}}, {slots = 2, data = {}}})}
  br.optimizeStops()
  ids = {}
  for _, s in ipairs(state.stops) do ids[#ids + 1] = s.jobId .. "/" .. s.kind end
  check(table.concat(ids, ",") == "B/pickup,B/delivery,A/delivery", "with room, nearby job first: " .. table.concat(ids, ","))
  -- moveStop-style validation still works on the result (delivery without pickup carries collected=true)
  local copy = deepcopy(state.stops); copy[1], copy[2] = copy[2], copy[1]
  check(not rules.validStopOrder(copy), "swapping B's legs is still rejected by brokerRules")
end

-- 4) trailers: one at a time; cars: one contract at a time; materials: tank size ---------------------------------
do
  containers = {}
  local st = {jobs = {}, plans = {}, stops = {}}
  addJob(st, 'T1', 'trailer', {}, P(10, 0), {P(1000, 0)})
  addJob(st, 'T2', 'trailer', {}, P(20, 0), {P(1010, 0)})
  addJob(st, 'C1', 'cars', {vehicles = {{status = 'pending'}}}, P(30, 0), {P(500, 500), P(600, 500)})
  addJob(st, 'C2', 'cars', {vehicles = {{status = 'pending'}}}, P(40, 0), {P(520, 500)})
  state = deepcopy(st); origOptimize()
  local origPeak = peakLoad(state.stops, st.jobs, function(j) return j.kind end, function() return 1 end)
  state = deepcopy(st)
  local ok = br.optimizeStops()
  local peak = peakLoad(state.stops, st.jobs, function(j) return j.kind end, function() return 1 end)
  check(ok and peak.trailer == 1 and peak.cars == 1, "one trailer / one car contract at a time")
  print(string.format("[trailers/cars] original peak trailers=%d cars=%d; ours trailers=%d cars=%d", origPeak.trailer, origPeak.cars, peak.trailer, peak.cars))

  -- materials: 9000 L tank; two fluid contracts of 6000 L each cannot ride together; dry bulk is separate
  containers = {{vehId = 1, attachmentStatus = 'attached', cargoTypesLookup = {fluid = true}, totalCargoSlots = 9000, rawCargo = {}, transientCargo = {}},
                {vehId = 3, attachmentStatus = 'attached', cargoTypesLookup = {parcel = true}, totalCargoSlots = 99, rawCargo = {}, transientCargo = {}}} -- vehId 3 is not ours
  st = {jobs = {}, plans = {}, stops = {}}
  addJob(st, 'F1', 'material', {subtype = 'fluid', quantity = 6000}, P(10, 0), {P(800, 0)})
  addJob(st, 'F2', 'material', {subtype = 'fluid', quantity = 6000}, P(20, 0), {P(810, 0)})
  addJob(st, 'F3', 'material', {subtype = 'fluid', quantity = 20000}, P(30, 0), {P(820, 0)}) -- bigger than the tank: one tankful
  addJob(st, 'D1', 'material', {subtype = 'dryBulk', quantity = 5000}, P(40, 0), {P(830, 0)}) -- no bulk body: not limited
  state = deepcopy(st)
  ok = br.optimizeStops()
  peak = peakLoad(state.stops, st.jobs, function(j) return j.subtype end, function(j) return math.min(j.quantity, 9000) end)
  check(ok and peak.fluid <= 9000, "fluid never above tank: " .. tostring(peak.fluid))
  check(logs[#logs]:find("fluid 0/9000", 1, true) ~= nil and not logs[#logs]:find("parcel", 1, true), "only own vehicles' containers counted")
end

-- 5) saved plans (not reserved yet) are ordered too; a plan row has kind/quantity but no status -----------------
do
  containers = {parcelBox(4)}
  local st = {jobs = {}, plans = {}, stops = {}}
  addJob(st, 'plan:1', 'parcel', {quantity = 3}, P(10, 0), {P(400, 0)})
  addJob(st, 'plan:2', 'parcel', {quantity = 3}, P(20, 0), {P(410, 0)})
  st.plans['plan:1'] = st.jobs['plan:1']; st.plans['plan:2'] = st.jobs['plan:2']; st.plans['plan:1'].status = nil; st.plans['plan:2'].status = nil
  st.jobs = {}
  state = deepcopy(st)
  local ok = br.optimizeStops()
  local peak = peakLoad(state.stops, state.plans, parcelDim, qtyOf)
  check(ok and peak.parcel <= 4, "plans respect capacity")
end

-- 6) fallbacks: error -> original; stop without position -> original; routing failure -> straight line --------------
do
  local st = {jobs = {}, plans = {}, stops = {}}
  addJob(st, 'E1', 'parcel', {quantity = 1}, P(10, 0), {P(30, 0)})
  addJob(st, 'E2', 'parcel', {quantity = 1}, P(20, 0), {P(40, 0)})
  state = deepcopy(st); containers = {parcelBox(4)}
  career_modules_delivery_general.getMostRecentCargoContainerData = function() error("boom") end
  origCalls = 0
  local ok, msg = br.optimizeStops()
  check(origCalls == 1 and ok == true and msg == 'Stops ordered by shortest drive.', "error falls back to original")
  check(logs[#logs]:find("error, using original", 1, true) ~= nil, "error logged")
  career_modules_delivery_general.getMostRecentCargoContainerData = function() return containers end

  state = deepcopy(st); state.stops[2].location.pos = nil; origCalls = 0
  ok = br.optimizeStops()
  check(origCalls == 1, "stop without position -> original")

  state = deepcopy(st); state.stops = {state.stops[1]}; origCalls = 0
  ok, msg = br.optimizeStops()
  check(origCalls == 1 and ok == false and msg == 'Add more stops to order them.', "<2 stops -> original message")

  M._resetRouteCache(); routeFails = true
  state = deepcopy(st); origCalls = 0
  ok = br.optimizeStops()
  check(ok and origCalls == 0 and rules.validStopOrder(state.stops), "routing failure -> straight-line, still ordered")
  check(logs[#logs]:find("straight%-line fallbacks") ~= nil and not logs[#logs]:find(" 0 straight%-line"), "fallbacks counted in log")
  routeFails = false
end

-- 7) performance: 15 jobs = 30 stops, all distinct points -----------------------------------------------------
do
  M._resetRouteCache(); containers = {parcelBox(10)}
  local st = {jobs = {}, plans = {}, stops = {}}
  for k = 1, 15 do addJob(st, 'p' .. k, 'parcel', {quantity = 1 + rand(4)}, P(rand(4000), rand(4000)), {P(rand(4000), rand(4000))}) end
  state = deepcopy(st); routeCalls = 0
  local t = os.clock(); local ok = br.optimizeStops(); local ms = (os.clock() - t) * 1000
  check(ok, "30 stops ok")
  print(string.format("[perf] 30 stops: %.0f ms CPU in LuaJIT (mock routing), %d route queries (cold cache)", ms, routeCalls))
  routeCalls = 0; state = deepcopy(st); br.optimizeStops()
  print(string.format("[perf] second press, same player position: %d route queries", routeCalls))
  print("[log] " .. logs[#logs])
end

print(string.format("%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
