package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tools/?.lua;" .. package.path
local CPPC = require("wtop.collectors.cppc")
local Fixture = require("support.fixture_fs")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Report = require("wtop.report")
local base = "/sys/devices/system/cpu"
local path = base .. "/cpu0/acpi_cppc/"
local function specification()
  local spec = { files = {[base.."/online"]="0,2\n"}, dirs={
    [base]={"cpu02","cpu2","cpu0","cpu1048576","cpu1","cpu999999999999999999999999"} } }
  for _, id in ipairs({0,1,2}) do
    local values = { highest_perf=196, nominal_perf=150, lowest_nonlinear_perf=80,
      lowest_perf=10, guaranteed_perf=0, reference_perf=165, nominal_freq=3300, lowest_freq=0 }
    if id == 2 then values.nominal_perf=120; values.nominal_freq=2200 end
    for key,value in pairs(values) do spec.files[base.."/cpu"..id.."/acpi_cppc/"..key]=tostring(value).."\n" end
  end
  return spec
end
local spec = specification()
local fs = Fixture.new(spec)
local saved = fs.read
fs.read = function(self,file,limit)
  assert(not file:find("feedback_ctrs",1,true) and not file:find("wraparound_time",1,true),
    "reference discovery must not read the feedback counter interface")
  assert(not file:find("/cpu1/",1,true),"offline CPUs must not be queried")
  return saved(self,file,limit)
end
local collector = CPPC.new({fs=fs})
local function sample() return collector:sample({now_ns=function() return 1000000000 end}) end
assert(collector:probe({}).state=="available")
local result = sample()
assert(result.status=="ok" and result.quality=="fresh" and result.data.consistent)
assert(#result.data.cpus==2 and result.data.cpus[1].id==0 and result.data.cpus[2].id==2)
local row=result.data.cpus[1]
assert(row.highest_performance==196 and row.nominal_performance==150
  and row.lowest_nonlinear_performance==80 and row.lowest_performance==10
  and row.guaranteed_performance==nil and row.reference_performance==165
  and row.nominal_frequency_hz==3300000000 and row.lowest_frequency_hz==nil
  and result.data.cpus[2].nominal_frequency_hz==2200000000)
local state=Snapshot.new(1,1000000000)
state=Snapshot.merge(state,{cppc=result},1,1000000000)
-- CPPC remains usable when procfs/CPUInfo is absent. Its verified logical
-- identities create independent roots, with no physical containment implied.
do
  local Hardware = require("wtop.model.hardware")
  local graph = Hardware.build(state)
  local cpu = assert(graph.by_id["cpu:0"], "CPPC-only CPU must be discoverable")
  assert(cpu.kind == "thread" and cpu.resource == "cppc" and cpu.resource_id == 0
    and cpu.parent_id == nil and cpu.package_id == nil and cpu.cpu_ids[1] == 0)
  assert(cpu.device.package_id_known == false and cpu.device.core_id_known == false)
  assert(graph.by_id["cpu:2"] and not graph.by_id["package:0"] and #graph.nodes == 2)
  local exported = Export.snapshot(state).inventory.topology.nodes
  assert(#exported == 2 and exported[1].resource == "cppc")
  for _, locale in ipairs({"en-US","zh-CN","zh-TW","fr-FR","de-DE","es-ES","pt-BR","ru-RU","ja-JP","ko-KR"}) do
    local lang=assert(I18n.new({locale=locale}))
    local lines=table.concat(TUI.hardware_detail_lines(state,"cpu:0",lang,2000000000),"\n")
    assert(lines:find(lang:t("cppc.title"),1,true) and lines:find(lang:t("cppc.nominal_frequency"),1,true))
  end
  local original, quality = state.cppc.cpus, state.quality.cppc
  state.cppc.cpus={original[1],original[1],original[2]}
  local ambiguous=Hardware.build(state)
  assert(not ambiguous.by_id["cpu:0"] and ambiguous.by_id["cpu:2"] and ambiguous.partial)
  state.cppc.cpus=original
  for _, tag in ipairs({"stale","gap","denied","error","unavailable","reset","held","missing"}) do
    state.quality.cppc={status="ok",quality=tag}
    assert(not Hardware.build(state).by_id["cpu:0"],tag)
  end
  state.quality.cppc={status="denied",quality="fresh"}
  assert(not Hardware.build(state).by_id["cpu:0"])
  state.quality.cppc=quality
  local saved_consistent,saved_quality=original[1].consistent,original[1].quality
  for _, tag in ipairs({"stale","gap","denied","error","unavailable"}) do
    original[1].quality=tag
    assert(not Hardware.build(state).by_id["cpu:0"],tag)
  end
  original[1].quality="partial"
  assert(Hardware.build(state).by_id["cpu:0"],"valid identity survives a partial reference")
  original[1].consistent=false
  assert(not Hardware.build(state).by_id["cpu:0"])
  original[1].consistent,original[1].quality=saved_consistent,saved_quality
  state.cppc.cpus={}
  for id=0,512 do state.cppc.cpus[#state.cppc.cpus+1]={id=id,source=base.."/cpu"..id.."/acpi_cppc",consistent=true,quality="fresh"} end
  local bounded=Hardware.build(state)
  assert(#bounded.nodes==512 and bounded.truncated)
  -- A duplicate after the display prefix still invalidates its selected ID.
  state.cppc.cpus[513]=state.cppc.cpus[1]
  assert(not Hardware.build(state).by_id["cpu:0"])
  for index=514,8193 do state.cppc.cpus[index]=original[2] end
  local oversized=Hardware.build(state)
  assert(#oversized.nodes==0 and oversized.truncated)
  state.cppc.cpus={false,{}, {id=-1}, {id=0.5}, {id=1048576}, original[2]}
  local malformed=Hardware.build(state)
  assert(malformed.partial and #malformed.nodes==1 and malformed.by_id["cpu:2"])
  state.cppc.cpus=original
end
state.cpu_info={topology={logical_cpus={{id=0,core_id=0,package_id=0,core_key="0:0",source=base.."/cpu0/topology"}}}}
do
  local graph=require("wtop.model.hardware").build(state)
  assert(graph.by_id["cpu:0"].resource=="cpu_info" and graph.by_id["cpu:0"].parent_id=="core:0:0")
  assert(graph.by_id["cpu:2"].resource=="cppc" and not graph.by_id["cpu:2"].parent_id)
end
local output=Export.snapshot(state)
assert(output.cppc.cpus[1].nominal_frequency_hz==3300000000
  and output.cppc.cpus[1].guaranteed_performance==nil and output.cppc.cpus[1].quality=="fresh")
local agent=Export.agent(state)
assert(agent.metrics.cpu.cppc.cpus[1].nominal_performance==150)
local one=Export.agent(state,{device_limit=1}).metrics.cpu.cppc
assert(#one.cpus==1 and one.cpu_count==2 and one.truncated)
local schema_file=assert(io.open("docs/agent-v1.schema.json","rb"))
local schema=assert(require("wtop.core.json").decode(schema_file:read("a")));schema_file:close()
local Validator=require("agent_schema")
assert(#Validator.validate(agent,schema)==0)
for index=3,6 do agent.metrics.cpu.cppc.cpus[index]={id=index,quality="fresh"} end
assert(#Validator.validate(agent,schema)>0,"schema must enforce the bounded CPPC list")
local report=Report.render(output)
assert(report:find("ACPI CPPC performance references",1,true) and report:find("3.30 GHz",1,true)
  and report:find("not percentages",1,true))
for _,locale in ipairs({"en-US","zh-CN","zh-TW","fr-FR","de-DE","es-ES","pt-BR","ru-RU","ja-JP","ko-KR"}) do
  local lang=assert(I18n.new({locale=locale}))
  local lines=table.concat(TUI.hardware_detail_lines(state,"cpu:0",lang,2000000000),"\n")
  for _,key in ipairs({"title","highest","nominal","lowest_nonlinear","lowest","guaranteed",
    "reference","nominal_frequency","lowest_frequency","note"}) do
    assert(lines:find(lang:t("cppc."..key),1,true),locale..": "..key)
  end
  assert(lang:diagnostics().format_errors==0)
end
state.quality.cppc.quality="stale"
assert(Export.snapshot(state).cppc.cpus[1].quality=="stale"
  and Export.agent(state).metrics.cpu.cppc.cpus[1].quality=="stale")
local stale=table.concat(TUI.hardware_detail_lines(state,"cpu:0",assert(I18n.new({locale="en-US"}))),"\n")
assert(stale:find("Quality: Stale",1,true))

-- Optional firmware fields and missing old-kernel directories stay absent.
spec.files[path.."nominal_freq"]=nil
spec.files[path.."lowest_freq"]="0\n"
spec.files[path.."guaranteed_perf"]=nil
assert(sample().data.cpus[1].quality=="fresh")
spec.files[path.."guaranteed_perf"]="151\n"
local inconsistent=sample().data.cpus[1]
assert(inconsistent.quality=="partial" and inconsistent.guaranteed_performance==151)
spec.files[path.."guaranteed_perf"]="9\n"
assert(sample().data.cpus[1].quality=="partial")
spec.files[path.."guaranteed_perf"]="150\n"
assert(sample().data.cpus[1].quality=="fresh")
spec.files[path.."lowest_freq"]="4000\n"
spec.files[path.."nominal_freq"]="3300\n"
assert(sample().data.cpus[1].quality=="partial")
spec.files[path.."lowest_freq"]="0\n"
for _,token in ipairs({"-1","1.2","nan","inf","4294967296","1e3",string.rep("1",65),""}) do
  spec.files[path.."highest_perf"]=token.."\n"
  local bad=sample()
  assert(bad.quality=="partial" and bad.data.cpus[1].quality=="partial"
    and bad.data.cpus[1].highest_performance==nil and #bad.data.cpus[1].issues>0,token)
end
spec.files[path.."highest_perf"]="149\n"
assert(sample().data.cpus[1].quality=="partial","invalid performance ordering")
spec.files[path.."highest_perf"]="196\n"
spec.files[path.."lowest_nonlinear_perf"]="0\n"
assert(sample().data.cpus[1].quality=="partial","zero mandatory performance")
spec.files[path.."lowest_nonlinear_perf"]="80\n"
spec.files[path.."nominal_freq"]="1000001\n"
assert(sample().data.cpus[1].nominal_frequency_hz==nil)

local reads=0
fs.read=function(self,file,limit)
  if file==path.."highest_perf" then reads=reads+1;return reads==1 and "196\n" or "195\n" end
  return saved(self,file,limit)
end
assert(sample().data.cpus[1].quality=="gap","dynamic reference must not form a consistent mixed observation")
local online_reads=0
fs.read=function(self,file,limit)
  if file==base.."/online" then online_reads=online_reads+1;return online_reads==1 and "0,2\n" or "2\n" end
  return saved(self,file,limit)
end
local hotplug=sample()
assert(not hotplug.data.consistent and hotplug.quality=="partial")
for _,cpu in ipairs(hotplug.data.cpus) do assert(cpu.quality=="gap" and not cpu.consistent) end
fs.read=saved
local limited=CPPC.new({fs=fs,max_cpus=1}):sample({})
assert(limited.data.truncated and limited.quality=="partial" and #limited.data.cpus==1)
local unavailable=CPPC.new({fs=Fixture.new({dirs={[base]={"cpu0"}},files={[base.."/online"]="0\n"}})})
assert(unavailable:probe({}).state=="unavailable" and unavailable:sample({}).status=="unavailable")
local denied_spec=specification();denied_spec.files[path.."highest_perf"]=nil
local denied=CPPC.new({fs=Fixture.new(Fixture.merge(denied_spec,{denied={[path.."highest_perf"]=true}}))}):sample({})
assert(denied.data.cpus[1].quality=="partial" and denied.data.cpus[1].issues[1].status=="denied")
local bad_online=specification();bad_online.files[base.."/online"]="0-junk\n"
assert(CPPC.new({fs=Fixture.new(bad_online)}):sample({}).status=="error")
for _,options in ipairs({{max_cpus=0},{max_entries=0},{interval_ms=0},{base_path="relative"}}) do
  assert(not pcall(CPPC.new,options))
end

-- Registering references must retain the low discovery cadence even with a
-- fast dashboard interval, and snapshots/recordings preserve their own slot.
local engine=require("wtop.engine").new({collectors={cppc=CPPC.new({fs=fs})},interval_ms=100})
assert(engine.scheduler:task("cppc").interval_ms==30000)
assert(engine.scheduler:task("cppc").background_interval_ms==60000)
engine:stop()
return true
