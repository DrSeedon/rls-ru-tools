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
