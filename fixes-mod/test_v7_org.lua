logs={} function log(l,t,m) logs[#logs+1]=l..":"..m end
local origCalls=0
freeroam_organizations={getOrganizations=function() return {police={id='police'}} end,
  getOrganization=function(id) origCalls=origCalls+1; log("E","","Could not find organization with id "..tostring(id)) end}
package.path="./lua/ge/extensions/?.lua;"..package.path
local M=require("rlsRuFixes"); M.onUpdate()
local fails=0 local function check(c,m) if not c then fails=fails+1 print("FAIL "..m) end end
local o=freeroam_organizations
check(o.getOrganization('police').id=='police', "known org returned")
local n0=#logs
for i=1,500 do check(o.getOrganization(nil)==nil,"nil id") check(o.getOrganization('')==nil,"empty id") end
local errs=0 for _,l in ipairs(logs) do if l:find("^E:") then errs=errs+1 end end
check(errs==0, "no error lines: "..errs)
check(#logs-n0==2, "two once-only warnings, got "..(#logs-n0))
print((fails==0) and "ORG OK" or ("ORG FAILS "..fails))
