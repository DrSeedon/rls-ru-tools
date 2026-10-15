logs={} function log(l,t,m) logs[#logs+1]=m end
local stops={{id='s1',jobId='jA',kind='pickup'},{id='s2',jobId='jA',kind='delivery'}}
local plans={jA={id='jA'}}
local jobs={{id='jA',status='reserved',map='wcusa'},{id='jB',status='reserved',map='wcusa'},{id='jC',status='active',map='wcusa'},{id='jD',status='complete',map='wcusa'},{id='jE',status='reserved',map='italy'}}
local planCalls={}
career_modules_delivery_broker={
  getState=function() return {stops=stops,plans=plans,jobs=jobs,map='wcusa'} end,
  plan=function(id) planCalls[#planCalls+1]=id; if plans[id] then plans[id]=nil; for i=#stops,1,-1 do if stops[i].jobId==id then table.remove(stops,i) end end return true,'removed' end
    plans[id]={id=id}; stops[#stops+1]={id='p'..id,jobId=id,kind='pickup'}; stops[#stops+1]={id='d'..id,jobId=id,kind='delivery'}; return true,'Added to route.' end,
  optimizeStops=function() return true,'orig' end}
package.path="./lua/ge/extensions/?.lua;"..package.path
local M=require("rlsRuFixes"); M.onUpdate()
local br=career_modules_delivery_broker
br.getState()
local function ids() local t={} for _,s in ipairs(stops) do t[#t+1]=s.jobId end return table.concat(t,",") end
local fails=0 local function check(c,m) if not c then fails=fails+1 print("FAIL "..m) end end
check(#planCalls==2 and planCalls[1]=='jB' and planCalls[2]=='jC', "added jB,jC only: "..table.concat(planCalls,","))
check(ids()=="jA,jA,jB,jB,jC,jC", "stops "..ids())
-- user removes jB by hand; next getState must not re-add
br.plan('jB'); br.getState()
check(not ids():find("jB"), "jB stays removed: "..ids())
-- new reservation appears -> auto-added
jobs[#jobs+1]={id='jF',status='reserved',map='wcusa'}; br.getState()
check(ids():find("jF") ~= nil, "new jF auto-added")
print((fails==0) and "AUTOADD OK" or ("AUTOADD FAILS "..fails), "| stops:", ids(), "| log:", logs[#logs])
