logs={} function log(l,t,m) logs[#logs+1]=m end
local stops={{id='s1',jobId='j1'},{id='s2',jobId='j1'},{id='s3',jobId='j2'},{id='s4',jobId='plan1'},{id='s5',jobId='ghost'},{id='s6',jobId='j3'}}
local plans={plan1={id='plan1'}, j1={id='j1'}}
career_modules_delivery_broker={getState=function() return {stops=stops,plans=plans,jobs={{id='j1',status='complete'},{id='j2',status='active'},{id='j3',status='cancelled'}}} end}
package.path="./lua/ge/extensions/?.lua;"..package.path
local M=require("rlsRuFixes"); M.onUpdate(); M.onUpdate()
local st=career_modules_delivery_broker.getState()
local ids={} for _,s in ipairs(stops) do ids[#ids+1]=s.id end
print("stops left:", table.concat(ids,","), "| plans j1:", tostring(plans.j1), "plan1:", tostring(plans.plan1~=nil), "| same table:", tostring(st.stops==stops))
print("logs:", #logs, logs[#logs])
