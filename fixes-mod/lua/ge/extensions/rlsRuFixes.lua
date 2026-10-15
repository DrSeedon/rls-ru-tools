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
--
-- Fix 3 (Job Broker "Auto-order"): broker.optimizeStops() is a nearest-neighbour walk whose only rule is
-- "delivery after its own pickup"; it ignores how much the vehicle can carry, so it happily chains pickups beyond
-- the cargo space. The wrapper below orders the same stops with (a) pickup before delivery, (b) running load never
-- above capacity, (c) minimal road distance (feasible greedy + cheapest insertion, then or-opt / 2-opt / swap).
-- Capacity = cargo containers of the seated vehicle + everything coupled to it (general.getMostRecentCargoContainerData
-- filtered by overhaul_playerVehicles.getPlayerVehicleIds). Unknown capacity -> pickup-before-delivery only.
-- Any error -> the original optimizeStops runs, so the button never breaks.
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

-- ---------------------------------------------------------------------------------------------------------------
-- Fix 3: capacity-aware auto-order
-- ---------------------------------------------------------------------------------------------------------------
local ROUTE = {
  dropCollectedPickups = true, -- a pickup whose cargo is already aboard is removed from the route (nothing to collect)
  trailerSlots = 1,           -- supplied trailers towed at once (one hitch); assumption, not enforced by the game code
  carContracts = 1,           -- ownerOpContracts.startBrokerContract: one car-hauling contract active at a time
  maxRouteQueries = 2500,     -- road-route lookups per press; beyond that straight-line distance is used
  maxEvaluations = 250000,    -- local-search move evaluations per start
}
M.routeConfig = ROUTE
local MATERIAL_TYPES = {fluid = true, dryBulk = true, cement = true, cash = true}
local EPS = 1e-6

local function straight(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local roadCache, roadCacheMap, roadCacheSize = {}, nil, 0
local roadStats = {queries = 0, fallbacks = 0}
local function levelId()
  local ok, id = pcall(function() return getCurrentLevelIdentifier() end)
  return ok and id or ''
end
-- Same lookup broker.lua's local distance() uses: gameplay/route/route + setupPath + path[1].distToTarget.
local function roadDistance(a, b)
  local lvl = levelId()
  if roadCacheMap ~= lvl or roadCacheSize >= 8192 then roadCache = {}; roadCacheMap = lvl; roadCacheSize = 0 end
  local key = string.format('%.0f:%.0f:%.0f>%.0f:%.0f:%.0f', a.x, a.y, a.z or 0, b.x, b.y, b.z or 0)
  local hit = roadCache[key]
  if hit then return hit end
  local d
  if roadStats.queries < ROUTE.maxRouteQueries then
    roadStats.queries = roadStats.queries + 1
    local ok, v = pcall(function()
      local route = require('gameplay/route/route')()
      route:setupPath(a, b)
      return route.path and route.path[1] and route.path[1].distToTarget
    end)
    d = ok and tonumber(v) or nil
    if d and (d ~= d or d < 0 or d == math.huge) then d = nil end
  end
  if d then roadCache[key] = d; roadCacheSize = roadCacheSize + 1; return d end
  roadStats.fallbacks = roadStats.fallbacks + 1
  return straight(a, b) -- not cached: routing is retried on the next press
end
M._roadDistance = roadDistance
M._resetRouteCache = function() roadCache, roadCacheMap, roadCacheSize = {}, nil, 0 end

-- ---- pure planner -------------------------------------------------------------------------------------------
-- P.stops[i] = {job=jobKey, pickup=bool, p=pointIndex}; P.jobs[jobKey] = {dim, initial, pick, hasPickup, nDel}
-- P.cap[dim] = limit for constrained dims; P.base[dim] = load aboard at the start; P.d(i,j) = distance of points.
local function feasible(P, seq)
  local run, picked, left = {}, {}, {}
  for d, v in pairs(P.base) do run[d] = v end
  for k = 1, #seq do
    local s = P.stops[seq[k]]
    local j = P.jobs[s.job]
    if s.pickup then
      if picked[s.job] then return false end
      picked[s.job] = true
      local d = j.dim
      if d and P.cap[d] then
        run[d] = (run[d] or 0) + j.pick
        if run[d] > P.cap[d] + EPS then return false end
      end
    else
      if j.hasPickup and not picked[s.job] then return false end
      local c = (left[s.job] or j.nDel) - 1
      left[s.job] = c
      if c == 0 and j.dim and P.cap[j.dim] then
        run[j.dim] = (run[j.dim] or 0) - j.initial - (picked[s.job] and j.pick or 0)
      end
    end
  end
  return true
end

local function cost(P, seq)
  local total, prev = 0, 0
  for k = 1, #seq do
    local p = P.stops[seq[k]].p
    total = total + P.d(prev, p); prev = p
  end
  return total
end

-- Nearest feasible stop first; same candidate order and strict '<' tie-break as broker.optimizeStops.
local function greedy(P)
  local n, used, seq, cur = #P.stops, {}, {}, 0
  local run, picked, left = {}, {}, {}
  for d, v in pairs(P.base) do run[d] = v end
  for _ = 1, n do
    local best, bestD
    for i = 1, n do
      if not used[i] then
        local s = P.stops[i]; local j = P.jobs[s.job]
        local ok
        if s.pickup then
          ok = not (j.dim and P.cap[j.dim]) or (run[j.dim] or 0) + j.pick <= P.cap[j.dim] + EPS
        else
          ok = not j.hasPickup or picked[s.job]
        end
        if ok then
          local d = P.d(cur, s.p)
          if not bestD or d < bestD then best, bestD = i, d end
        end
      end
    end
    if not best then return nil end
    used[best] = true; seq[#seq + 1] = best
    local s = P.stops[best]; local j = P.jobs[s.job]
    cur = s.p
    if s.pickup then
      picked[s.job] = true
      if j.dim and P.cap[j.dim] then run[j.dim] = (run[j.dim] or 0) + j.pick end
    else
      local c = (left[s.job] or j.nDel) - 1; left[s.job] = c
      if c == 0 and j.dim and P.cap[j.dim] then
        run[j.dim] = (run[j.dim] or 0) - j.initial - (picked[s.job] and j.pick or 0)
      end
    end
  end
  return seq
end

-- Cheapest feasible insertion, job by job (loads already aboard first, then farthest pickup first).
local function insertion(P)
  local order, firstStop, byJob = {}, {}, {}
  for i, s in ipairs(P.stops) do
    if not byJob[s.job] then byJob[s.job] = {}; order[#order + 1] = s.job; firstStop[s.job] = i end
    local list = byJob[s.job]
    if s.pickup then table.insert(list, 1, i) else list[#list + 1] = i end
  end
  local function key(job)
    local j = P.jobs[job]
    local far = 0
    for _, i in ipairs(byJob[job]) do far = math.max(far, P.d(0, P.stops[i].p)) end
    return (j.initial or 0) > 0 and 1 or 0, far
  end
  local keys = {}
  for _, job in ipairs(order) do local a, b = key(job); keys[job] = {a, b} end
  table.sort(order, function(x, y)
    if keys[x][1] ~= keys[y][1] then return keys[x][1] > keys[y][1] end
    if keys[x][2] ~= keys[y][2] then return keys[x][2] > keys[y][2] end
    return firstStop[x] < firstStop[y]
  end)
  local seq = {}
  for _, job in ipairs(order) do
    local lo = 1
    for _, si in ipairs(byJob[job]) do
      local bestPos, bestC
      for pos = lo, #seq + 1 do
        table.insert(seq, pos, si)
        local c = cost(P, seq)
        if (not bestC or c < bestC - EPS) and feasible(P, seq) then bestPos, bestC = pos, c end
        table.remove(seq, pos)
      end
      if not bestPos then return nil end
      table.insert(seq, bestPos, si)
      if P.stops[si].pickup then lo = bestPos + 1 end
    end
  end
  return seq
end

-- Local search: or-opt (move 1-3 consecutive stops), 2-opt (reverse a segment), swap. First improvement, repeated.
local function improve(P, seq)
  local n = #seq
  local best = cost(P, seq)
  local evals = 0
  local cand = {}
  local function try()
    evals = evals + 1
    local c = cost(P, cand)
    if c < best - 1e-6 and feasible(P, cand) then
      for i = 1, n do seq[i] = cand[i] end
      best = c
      return true
    end
    return false
  end
  local improved = true
  while improved and evals < ROUTE.maxEvaluations do
    improved = false
    -- or-opt
    for L = 1, math.min(3, n - 1) do
      for i = 1, n - L + 1 do
        local rest = {}
        for x = 1, n do if x < i or x > i + L - 1 then rest[#rest + 1] = seq[x] end end
        for k = 1, n - L + 1 do
          if k ~= i then
            local w = 0
            for x = 1, k - 1 do w = w + 1; cand[w] = rest[x] end
            for x = i, i + L - 1 do w = w + 1; cand[w] = seq[x] end
            for x = k, #rest do w = w + 1; cand[w] = rest[x] end
            if try() then improved = true; break end
          end
        end
        if improved or evals >= ROUTE.maxEvaluations then break end
      end
      if improved or evals >= ROUTE.maxEvaluations then break end
    end
    -- 2-opt
    if not improved then
      for i = 1, n - 1 do
        for k = i + 1, n do
          for x = 1, n do cand[x] = seq[x] end
          local a, b = i, k
          while a < b do cand[a], cand[b] = cand[b], cand[a]; a = a + 1; b = b - 1 end
          if try() then improved = true; break end
        end
        if improved or evals >= ROUTE.maxEvaluations then break end
      end
    end
    -- swap
    if not improved then
      for i = 1, n - 1 do
        for k = i + 1, n do
          for x = 1, n do cand[x] = seq[x] end
          cand[i], cand[k] = cand[k], cand[i]
          if try() then improved = true; break end
        end
        if improved or evals >= ROUTE.maxEvaluations then break end
      end
    end
  end
  return seq, best, evals
end

-- Returns best feasible order (list of stop indices), its cost, and diagnostics; nil if no feasible order exists.
local function plan(P)
  local starts, info = {}, {}
  local g = greedy(P)
  if g then starts[#starts + 1] = {name = 'greedy', seq = g} end
  local ins = insertion(P)
  if ins then starts[#starts + 1] = {name = 'insertion', seq = ins} end
  local cur = {}
  for i = 1, #P.stops do cur[i] = i end
  if feasible(P, cur) then starts[#starts + 1] = {name = 'current', seq = cur} end
  local bestSeq, bestCost, bestName
  for _, st in ipairs(starts) do
    local c0 = cost(P, st.seq)
    local seq, c, evals = improve(P, st.seq)
    info[#info + 1] = string.format('%s %.0f->%.0f (%d evals)', st.name, c0, c, evals)
    if not bestCost or c < bestCost - 1e-6 then bestSeq, bestCost, bestName = seq, c, st.name end
  end
  return bestSeq, bestCost, bestName, info
end
M._planner = {feasible = feasible, cost = cost, greedy = greedy, insertion = insertion, improve = improve, plan = plan}

-- ---- game-state adapter -------------------------------------------------------------------------------------
local function readCapacity(jobsById)
  local g = career_modules_delivery_general
  if not (g and g.getMostRecentCargoContainerData) then return {known = false, reason = 'no cargo-container API'} end
  local list = g.getMostRecentCargoContainerData()
  if type(list) ~= 'table' or not list[1] then return {known = false, reason = 'no cargo containers scanned yet'} end
  local ids = {}
  local pv = overhaul_playerVehicles
  if pv and pv.getPlayerVehicleIds then
    for _, id in ipairs(pv.getPlayerVehicleIds() or {}) do ids[id] = true end
  end
  if not next(ids) then
    local v = getPlayerVehicle and getPlayerVehicle(0)
    local id = v and v.getID and v:getID()
    if id then ids[id] = true end
  end
  if not next(ids) then return {known = false, reason = 'no player vehicle'} end
  local byContract = {}
  for id, j in pairs(jobsById) do
    if j.kind == 'material' and j.nativeId ~= nil then byContract[j.nativeId] = id end
  end
  local cap, used, byJob, count = {}, {}, {}, 0
  for _, con in ipairs(list) do
    if ids[con.vehId] and con.attachmentStatus ~= 'lost' then
      local types, dims = con.cargoTypesLookup or {}, {}
      if types.parcel then dims[1] = 'parcel'
      else for t, on in pairs(types) do if on and MATERIAL_TYPES[t] then dims[#dims + 1] = t end end end
      if dims[1] then
        count = count + 1
        local u = 0
        local function eat(c)
          local slots = tonumber(c.slots) or 0
          u = u + slots
          local data = c.data or {}
          local jid = data.brokerId
          if jid == nil and data.materialContractId ~= nil then jid = byContract[data.materialContractId] end
          if jid ~= nil then byJob[jid] = (byJob[jid] or 0) + slots end
        end
        for _, c in ipairs(con.rawCargo or {}) do eat(c) end
        for _, c in ipairs(con.transientCargo or {}) do eat(c) end
        for _, d in ipairs(dims) do
          cap[d] = (cap[d] or 0) + (tonumber(con.totalCargoSlots) or 0)
          used[d] = (used[d] or 0) + u
        end
      end
    end
  end
  if count == 0 then return {known = false, reason = 'player vehicle has no cargo containers'} end
  return {known = true, cap = cap, used = used, byJob = byJob, containers = count}
end
M._readCapacity = readCapacity

local function dimOf(row)
  local kind = row and row.kind
  if kind == 'parcel' then return 'parcel' end
  if kind == 'material' then return MATERIAL_TYPES[row.subtype] and row.subtype or nil end
  if kind == 'trailer' then return 'trailer' end
  if kind == 'cars' then return 'cars' end
  return nil
end

local function positionOf(loc)
  local g = career_modules_delivery_generator
  if not (loc and g and g.getLocationCoordinates) then return nil end
  local ok, pos = pcall(g.getLocationCoordinates, loc)
  return ok and pos or nil
end

local function playerPos()
  local v = getPlayerVehicle and getPlayerVehicle(0)
  if v then return v:getPosition() end
  return core_camera and core_camera.getPosition and core_camera.getPosition() or nil
end

local function fmt(n) return string.format('%.0f', tonumber(n) or 0) end

-- Returns true,message on success; nil,reason to hand over to the original optimizeStops.
local function planAndApply(br)
  local clock = os and os.clock or function() return 0 end
  local t0 = clock()
  local st = br.getState()
  local stops = type(st) == 'table' and st.stops
  if type(stops) ~= 'table' or #stops < 2 then return nil, 'fewer than 2 stops' end
  local jobsById, plans = {}, type(st.plans) == 'table' and st.plans or {}
  for _, j in ipairs(st.jobs or {}) do if j.id ~= nil then jobsById[j.id] = j end end

  -- jobs referenced by the route
  local J, pickups = {}, {}
  for _, s in ipairs(stops) do
    if type(s) ~= 'table' or s.jobId == nil or (s.kind ~= 'pickup' and s.kind ~= 'delivery') then return nil, 'unexpected stop' end
    local jid = s.jobId
    if not J[jid] then
      local row = jobsById[jid] or plans[jid]
      J[jid] = {row = row, dim = dimOf(row), nDel = 0, nPick = 0, hasPickup = false}
    end
    if s.kind == 'pickup' then J[jid].nPick = J[jid].nPick + 1 else J[jid].nDel = J[jid].nDel + 1 end
  end

  local capInfo = readCapacity(jobsById)
  local dropped = {}
  for jid, j in pairs(J) do
    if j.nPick > 1 then return nil, 'job with several pickups' end
    local row, status = j.row or {}, j.row and j.row.status
    local qty = math.max(0, tonumber(row.quantity) or 0)
    local loaded, fully, initial, pick = false, false, 0, 0
    local aboard = capInfo.known and capInfo.byJob[jid] or 0
    if row.kind == 'parcel' then
      loaded = status == 'active'; fully = loaded
      initial = loaded and aboard or 0; pick = loaded and 0 or qty
    elseif row.kind == 'material' then
      local inTransit = math.max(0, tonumber(row.inTransit) or 0)
      loaded = status == 'active' and inTransit > 0
      local toLoad = math.max(0, (tonumber(row.remaining) or qty) - inTransit)
      fully = loaded and toLoad <= 0
      initial = loaded and aboard or 0; pick = toLoad
    elseif row.kind == 'trailer' then
      loaded = status == 'active'; fully = loaded
      initial = loaded and 1 or 0; pick = loaded and 0 or 1
    elseif row.kind == 'cars' then
      loaded = status == 'active'
      local pending = false
      for _, v in ipairs(row.vehicles or {}) do if v.status == 'pending' then pending = true end end
      fully = loaded and not pending
      initial = loaded and 1 or 0; pick = loaded and 0 or 1
    end
    j.loaded, j.fully, j.initial, j.pick = loaded, fully, initial, pick
    j.drop = j.nPick == 1 and fully and ROUTE.dropCollectedPickups
    j.markCollected = fully and (j.drop or j.nPick == 0)
    j.hasPickup = j.nPick == 1 and not j.drop
    if j.drop then dropped[jid] = true end
  end

  -- capacity per dimension
  local cap, base, notes = {}, {}, {}
  if capInfo.known then
    for d, total in pairs(capInfo.cap) do
      if total > 0 then
        local attributed = 0
        for _, j in pairs(J) do if j.dim == d then attributed = attributed + j.initial end end
        local other = math.max(0, (capInfo.used[d] or 0) - attributed)
        local eff = total - other
        if eff > EPS then
          cap[d] = eff
          notes[#notes + 1] = string.format('%s %s/%s (other cargo %s)', d, fmt(attributed), fmt(total), fmt(other))
        else
          notes[#notes + 1] = string.format('%s full of other cargo (%s/%s) -> not limited', d, fmt(other), fmt(total))
        end
      end
    end
  else
    notes[#notes + 1] = 'capacity unknown (' .. tostring(capInfo.reason) .. ') -> pickup-before-delivery only'
  end
  if ROUTE.trailerSlots and ROUTE.trailerSlots > 0 then cap.trailer = ROUTE.trailerSlots end
  if ROUTE.carContracts and ROUTE.carContracts > 0 then cap.cars = ROUTE.carContracts end
  for jid, j in pairs(J) do
    local d = j.dim
    if d and cap[d] then
      local room = math.max(0, cap[d] - j.initial)
      if j.pick > room + EPS then
        if j.row and j.row.kind == 'parcel' then
          notes[#notes + 1] = string.format('job %s needs %s slots, only %s fit -> carried alone', tostring(jid), fmt(j.pick), fmt(room))
        end
        j.pick = room
      end
      base[d] = (base[d] or 0) + j.initial
    end
  end

  -- points (deduplicated by position) and planner stops
  local start = playerPos()
  if not start then return nil, 'no player position' end
  local pts, ptIndex = {[0] = start}, {}
  local P = {stops = {}, jobs = J, cap = cap, base = base}
  local live = {}
  for _, s in ipairs(stops) do
    if not (s.kind == 'pickup' and dropped[s.jobId]) then
      local pos = positionOf(s.location)
      if not pos then return nil, 'stop without position (' .. tostring(s.id) .. ')' end
      local k = string.format('%.0f:%.0f:%.0f', pos.x, pos.y, pos.z or 0)
      local idx = ptIndex[k]
      if not idx then idx = #pts + 1; pts[idx] = pos; ptIndex[k] = idx end
      P.stops[#P.stops + 1] = {job = s.jobId, pickup = s.kind == 'pickup', p = idx}
      live[#live + 1] = s
    end
  end
  if #P.stops == 0 then return nil, 'no stops left' end
  local memo = {}
  roadStats.queries, roadStats.fallbacks = 0, 0
  P.d = function(i, k)
    if i == k then return 0 end
    local row = memo[i]
    if not row then row = {}; memo[i] = row end
    local v = row[k]
    if not v then v = roadDistance(pts[i], pts[k]); row[k] = v end
    return v
  end

  local seq, total, startName, info = plan(P)
  if not seq then return nil, 'no order fits the cargo space' end
  local plain = greedy({stops = P.stops, jobs = J, cap = {}, base = {}, d = P.d})
  local plainCost = plain and cost(P, plain) or nil

  -- validate with the broker's own rule on a proxy before touching live data
  local ordered, proxy = {}, {}
  for k, si in ipairs(seq) do
    local s = live[si]
    ordered[k] = s
    proxy[k] = {id = s.id, kind = s.kind, jobId = s.jobId,
      collected = s.collected or (s.kind == 'delivery' and J[s.jobId].markCollected) or nil}
  end
  local okRules, rules = pcall(require, 'gameplay/delivery/brokerRules')
  if okRules and type(rules) == 'table' and rules.validStopOrder and not rules.validStopOrder(proxy) then
    return nil, 'result failed brokerRules.validStopOrder'
  end

  -- commit in place: getState().stops is the broker's live state.stops table
  for k, s in ipairs(ordered) do
    if s.kind == 'delivery' and J[s.jobId].markCollected then s.collected = true end
  end
  for i = #stops, 1, -1 do stops[i] = nil end
  for k, s in ipairs(ordered) do stops[k] = s end

  local nDropped = 0
  for _ in pairs(dropped) do nDropped = nDropped + 1 end
  log('I', 'rlsRuFixes', string.format(
    'auto-order: %d stops (%d collected pickup(s) removed); %s; road %s m vs plain greedy %s m; start=%s [%s]; %d route queries, %d straight-line fallbacks; %.0f ms',
    #ordered, nDropped, table.concat(notes, '; '), fmt(total), plainCost and fmt(plainCost) or '?', tostring(startName),
    table.concat(info, ', '), roadStats.queries, roadStats.fallbacks, (clock() - t0) * 1000))
  local limited = false
  for d in pairs(cap) do if d ~= 'trailer' and d ~= 'cars' then limited = true end end
  return true, limited and 'Stops ordered by shortest drive within cargo space.' or 'Stops ordered by shortest drive.'
end
M._planAndApply = planAndApply

local function autoOrder(br, orig, ...)
  local ok, res, msg = pcall(planAndApply, br)
  if ok and res then return res, msg end
  if not ok then log('W', 'rlsRuFixes', 'auto-order: error, using original optimizeStops: ' .. tostring(res))
  else log('I', 'rlsRuFixes', 'auto-order: ' .. tostring(msg) .. ' -> original optimizeStops') end
  return orig(...)
end

-- Fix 4 (Job Broker): every load in "My loads" (reserved or in progress on this map) is added to the route plan
-- automatically, once per session, instead of clicking "Add to route" on each. A load the player later removes from
-- the route by hand is not re-added in the same session (seen-set). Uses the broker's own M.plan(jobId).
local autoAddSeen = {}
local function autoAddLoads(br, st)
  if type(st) ~= "table" or type(st.stops) ~= "table" or type(br.plan) ~= "function" then return 0 end
  local plans = type(st.plans) == "table" and st.plans or {}
  local inRoute = {}
  for _, s in ipairs(st.stops) do if s and s.jobId ~= nil then inRoute[s.jobId] = true end end
  local added = 0
  for _, j in ipairs(st.jobs or {}) do
    local id = j and j.id
    if id ~= nil and not autoAddSeen[id] and (j.status == "reserved" or j.status == "active")
        and (st.map == nil or j.map == nil or j.map == st.map) then
      autoAddSeen[id] = true
      if not inRoute[id] and plans[id] == nil then
        local ok, res = pcall(br.plan, id)
        if ok and res then added = added + 1 end
      end
    end
  end
  return added
end
M._autoAddLoads = autoAddLoads
M._resetAutoAdd = function() autoAddSeen = {} end

local function ensureBroker()
  local br = career_modules_delivery_broker
  if not br then return end
  if not br.__rlsRuGuard and type(br.getState) == "function" then
    local orig = br.getState
    br.getState = function(...)
      local st = orig(...)
      local ok, n = pcall(pruneRoute, st)
      if ok and n and n > 0 then log("I", "rlsRuFixes", "route plan: pruned " .. n .. " finished/orphan stop(s)") end
      local ok2, a = pcall(autoAddLoads, br, st)
      if ok2 and a and a > 0 then log("I", "rlsRuFixes", "route plan: auto-added " .. a .. " load(s) from My loads") end
      return st
    end
    br.__rlsRuGuard = true
    log("I", "rlsRuFixes", "route-plan pruning installed on career_modules_delivery_broker")
  end
  if not br.__rlsRuOptimize and type(br.optimizeStops) == "function" and type(br.getState) == "function" then
    local orig = br.optimizeStops
    br.optimizeStops = function(...) return autoOrder(br, orig, ...) end
    br.__rlsRuOptimize = true
    log("I", "rlsRuFixes", "capacity-aware auto-order installed on career_modules_delivery_broker")
  end
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
