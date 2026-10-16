# rls_ru_fixes — runtime fix mod

Separate tiny mod (does not touch RLS files). Zip the *contents* of this folder and drop it into `mods/`:

```bash
cd fixes-mod && zip -r ../rls_ru_fixes.zip scripts lua
```

## Fix 1: big map / pause menu crash after a loaner (police) shift
Symptom: after taking a police/company vehicle (`beginAssignment jobKind=police`) and later opening the big map or
the pause menu, both fail with

```
FATAL LUA ERROR: lua/ge/extensions/career/modules/vehiclePerformance.lua:518: attempt to index local 'vehicle' (a nil value)
  ... freeroam_vueBigMap.enterBigMap(...)
Lifecycle hook onMount failed for route pause: ...vehiclePerformance.lua:518 ...
```

Cause: vanilla `career_modules_vehiclePerformance.getVehicleClass(invId)` reads `getVehicles()[invId].certificationData`
without a nil check, and `missionScreen.resolvePlayerVehicleClass()` passes `career_modules_inventory.getCurrentVehicle()`,
which can be an id that is not in `getVehicles()` (seen right after an RLS police loaner shift — likely, inferred from the log order).

Fix: `rlsRuFixes` wraps `getVehicleClass` and `getAggregateScoresFromVehId` to return `nil` for unknown ids (callers
already handle "no class info"); re-installs itself if the career module is reloaded.

Status: unit-tested with mocks (`luajit test_guard.lua`); in-game confirmation pending.

## Fix 2: finished loads never leave the Job Broker route plan
`broker.lua` removes route stops only on cancel / abandon / un-plan, never when a job is delivered, so the
"Route plan" tab fills up with finished loads ("Unavailable load") that can't be removed from the UI.
`getState()` returns the live `state.stops` / `state.plans` tables, so the wrapper prunes them in place: stops whose job
is `complete`/`cancelled`, and stops pointing to neither a job nor a saved plan. Test: `luajit test_route.lua`.
Note: the "Clear markers" button only clears the ground-marker line on the road (`core_groundMarkers.setPath(nil)`), it never touched the stop list.

## Fix 3: capacity-aware "Auto-order" for the Job Broker route plan
The stock `optimizeStops` is a greedy nearest-neighbour by road distance that only keeps pickup-before-delivery; it
ignores cargo space, so it can plan pickups that don't fit. The wrapper reads the player vehicle's (and attached
trailers') cargo containers from the delivery module's cached container data, counts cargo already on board, keeps
pickup → delivery precedence and never exceeds capacity per cargo type, builds three starts (greedy, cheapest insertion,
current order) and improves them with or-opt / 2-opt / swap moves using the same road-distance routing as the broker.
On any error it falls back to the original. Mock tests: `luajit test_optimize.lua` (1324 checks; vs stock: 0 overloads
instead of 58/150 at 4 slots, ~13 % shorter routes). In-game: not confirmed yet — grep `rlsRuFixes` in beamng.log.

## Fix 4: all "My loads" go into the route plan automatically
Every reserved / in-progress load on the current map is added to the route plan once per session via the broker's own `plan(jobId)` — no more clicking "Add to route" on each. A load removed from the route by hand is not re-added in the same session. Test: `luajit test_autoadd.lua`.

## Fix 5: parked cars never spawned
RLS `gameplay/trafficConfigFilter` wraps `core_multiSpawn.createGroup` and drops configs with no engine / zero power as "broken rollers". Parking requests only `Type=propparked` configs — static parked variants without engines by design — so the parked group was always empty (`Traffic group short after filter: want N, got 0` → `Parked vehicle group is empty!`). For parked-only requests the fix calls the unfiltered vanilla `createGroup` (the RLS wrapper's upvalue `originalCreateGroup`); police stays excluded by the request's own Config Type filter; everything else keeps the RLS filter. Test: `luajit test_parked.lua`.

## v6 fixes (from the RLS issue tracker; mock-tested, in-game confirmation pending)
- **#468** only one loaner cut applies (the largest) when truck and trailer come from different orgs; payout never goes negative from cuts (wraps `career_modules_delivery_employment.applyEmploymentPayToBreakdown`). Vehicle-delivery path not covered (local function).
- **#352** "repair before race" hang: `makeRepairClaim` normalises `{money=N}` → `N` (same idea as PR #479).
- **#488** cash contracts only get a loaner with cash capacity (wraps `canHaulMaterial`).
- **#353/#355** nil-position guard on `getDistanceBetweenLocations` / generator `distanceBetween` (mostly already guarded in 2.7.2).
- **#457** duplicate marketplace offer ids in old saves are renumbered on load.
- Parked passthrough excludes forklifts / forkable loads.
Run `bash run_all_tests.sh`.
