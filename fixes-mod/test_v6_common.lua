-- shared helpers for test_v6_*.lua (luajit test_v6_x.lua, run from /tmp/fix6)
package.path = "./lua/ge/extensions/?.lua;" .. package.path
logs = {}
function log(l, t, m) logs[#logs + 1] = l .. " " .. tostring(m) end
local T = {fails = 0, checks = 0}
function T.check(c, m) T.checks = T.checks + 1; if not c then T.fails = T.fails + 1; print("FAIL: " .. m) end end
function T.near(a, b) return math.abs((a or 0) - (b or 0)) < 1e-6 end
function T.hasLog(pat) for _, l in ipairs(logs) do if l:find(pat, 1, true) then return true end end return false end
function T.countLog(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end return n end
function T.load() package.loaded.rlsRuFixes = nil; return require("rlsRuFixes") end
function T.done(name)
  print(string.format("%s: %d checks, %d failed", name, T.checks, T.fails))
  if T.fails > 0 then os.exit(1) end
end
return T
