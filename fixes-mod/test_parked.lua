logs={} function log(l,t,m) logs[#logs+1]=m end
local calls={}
local function vanillaCreate(amount, params) calls[#calls+1]='vanilla'; local out={} for i=1,amount do out[i]={model='m'..i,config='parked'} end return out end
local originalCreateGroup = vanillaCreate
local function rlsWrapped(amount, params) calls[#calls+1]='rls'; local _ = originalCreateGroup; return {} end
core_multiSpawn={createGroup=rlsWrapped,_rlsTrafficConfigFilterWrapped=true}
package.path="./lua/ge/extensions/?.lua;"..package.path
local M=require("rlsRuFixes"); M.onUpdate(); M.onUpdate()
local fails=0 local function check(c,m) if not c then fails=fails+1 print("FAIL "..m) end end
local g=core_multiSpawn.createGroup(5,{filters={Type={propparked=1},['Config Type']={police=0,other=1}}})
check(#g==5 and calls[#calls]=='vanilla', "parked uses vanilla: n="..#g.." last="..tostring(calls[#calls]))
local g2=core_multiSpawn.createGroup(5,{filters={Type={car=1,truck=1}}})
check(calls[#calls]=='rls', "traffic keeps RLS filter")
local g3=core_multiSpawn.createGroup(5,{filters={Type={propparked=1,car=1}}})
check(calls[#calls]=='rls', "mixed request keeps RLS filter")
check(M._isParkedIntent({filters={Type={PropParked=1}}})==true, "case-insensitive")
check(M._isParkedIntent({})==false and M._isParkedIntent(nil)==false, "no filters")
-- no upvalue -> left as is
package.loaded.rlsRuFixes=nil
core_multiSpawn={createGroup=function() return {} end,_rlsTrafficConfigFilterWrapped=true}
local M2=require("rlsRuFixes"); M2.onUpdate()
check(core_multiSpawn.__rlsRuParked==true and #core_multiSpawn.createGroup(3,{filters={Type={propparked=1}}})==0, "no upvalue: untouched")
print((fails==0) and "PARKED OK" or ("PARKED FAILS "..fails), "| log:", logs[1])
