package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local CPU = require("wtop.collectors.cpu_limits")
local GPU = require("wtop.collectors.gpu_limits")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local View = require("wtop.view_model")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Table = require("wtop.ui.widgets.table")
local Grid = require("wtop.ui.renderer.grid")
local Report = require("wtop.report")

local function fixture(files, dirs, links)
    return {
        read = function(_, path)
            local value = files[path]
            if type(value) == "function" then value = value() end
            if type(value) == "table" then return nil, value end
            if value == nil then return nil, { kind = "missing", message = "missing" } end
            return value
        end,
        list = function(_, path, maximum)
            local value = dirs and dirs[path]
            if not value then return nil, { kind = "missing", message = "missing" } end
            local result = {}
            for i = 1, math.min(maximum, #value) do result[i] = value[i] end
            return result, nil, #value > maximum
        end,
        readlink = function(_, path) return links and links[path] end,
    }
end
local function bytes(status, logged) return string.pack("<I4I4", status | (logged << 16), 0) end
local function find(list, id) for _, v in ipairs(list) do if v.id == id then return v end end end
local parsed = CPU.decode(bytes(1 << 10, (1 << 1) | (1 << 11)))
assert(parsed.active and find(parsed.reasons,"pl1").active)
assert(not find(parsed.reasons,"thermal").active and find(parsed.reasons,"thermal").logged)
assert(not find(parsed.reasons,"pl2_pl3").active and find(parsed.reasons,"pl2_pl3").logged)
assert(CPU.decode(bytes(0,1 << 10)).active == false, "a recorded PL1 flag is not a current PL1 limit")
assert(CPU.decode(bytes(0,0)).active == false)
assert(CPU.decode(bytes(4,0)).active == nil, "reserved bits do not acquire an invented reason")
assert(CPU.decode(bytes(4,0)).quality == "partial")
assert(CPU.decode(string.pack("<I4I4",0,1)).active==nil)
assert(CPU.decode("short") == nil)

local root = "/sys/devices/system/cpu"
local function cpuinfo(model)
    local records = {}
    for id=0,1 do records[#records+1] = "processor : "..id.."\nvendor_id : GenuineIntel\ncpu family : 6\nmodel : "..model.."\n\n" end
    return table.concat(records)
end
local files = { [root.."/online"]="0-1\n", ["/proc/cpuinfo"]=cpuinfo(186),
    [root.."/cpu0/topology/physical_package_id"]="0\n",
    [root.."/cpu1/topology/physical_package_id"]="0\n" }
local reads = 0
local collector = CPU.new({ fs=fixture(files), reader=function(id)
    assert(id==0); reads=reads+1; return bytes(1<<10,1<<11)
end })
assert(collector:probe({}).state=="available")
local sampled = collector:sample({now_ns=function()return 1000 end})
assert(sampled.status=="ok" and sampled.quality=="fresh" and reads==1)
local domain=sampled.data.domains[1]
assert(#sampled.data.domains==1 and #domain.logical_cpu_ids==2 and domain.scope=="cpu_package")
assert(domain.package_id==0 and domain.active and domain.observed_at_ns==1000)
local state=Snapshot.merge(nil,{cpu_limits=sampled},1,1000)
local full=Export.snapshot(state)
assert(full.cpu_limits.domains[1].active and find(full.cpu_limits.domains[1].reasons,"pl1").active)
local report=Report.render(full)
assert(report:find("Performance limit status",1,true) and report:find("pl2_pl3",1,true))
local compact=Export.agent(state).metrics.power.cpu_limits.domains[1]
assert(compact.active and compact.active_reasons[1]=="pl1" and compact.recorded_reasons[1]=="pl2_pl3")
collector.reader=function(id)if id==0 then return nil,"offline",5 end;return bytes(0,0)end
local fallback=collector:sample({now_ns=function()return 1500 end}).data.domains[1]
assert(fallback.cpu_id==1 and fallback.source=="/dev/cpu/1/msr" and fallback.active==false)

collector.reader=function()return nil,"permission denied",13 end
local denied=collector:sample({now_ns=function()return 2000 end})
assert(denied.data.denied_domains==1 and denied.data.domains[1].active==nil)
assert(denied.data.domains[1].quality=="denied" and denied.quality=="partial")
collector.reader=function()files[root.."/online"]="1\n";return bytes(1<<10,1<<10) end
local changed=collector:sample({now_ns=function()return 3000 end})
assert(changed.data.domains[1].quality=="gap" and changed.data.domains[1].active==nil)
assert(find(changed.data.domains[1].reasons,"pl1").active==nil)
files[root.."/online"]="0-1\n"
files["/proc/cpuinfo"]=cpuinfo(92) -- Atom/Goldmont's 0x64f uses a different layout.
collector.reader=function()error("must not read this CPU's register")end
assert(collector:probe({}).state=="unavailable" and collector:sample({}).status=="unavailable")
files["/proc/cpuinfo"]=cpuinfo(186)

-- i915 states are per GT, include PL4, and must be coherent across the two
-- rounds. Missing or unreadable attributes never become false states.
local base="/drm/card0/gt/gt0"
local attrs={"status","pl1","pl2","pl4","thermal","prochot","ratl","vr_thermalert","vr_tdc"}
local gpu_files={}
for _,a in ipairs(attrs)do gpu_files[base.."/throttle_reason_"..a]="0\n" end
local gpu_fs=fixture(gpu_files,{["/drm/card0/gt"]={"gt0"}})
local function gpu_sample()return GPU.i915(gpu_fs,"/drm/card0",8,4000).domains[1]end
assert(gpu_sample().active==false and gpu_sample().quality=="fresh")
gpu_files[base.."/throttle_reason_status"]="1\n"
gpu_files[base.."/throttle_reason_pl4"]="1\n"
assert(gpu_sample().active and find(gpu_sample().reasons,"pl4").active)
gpu_files[base.."/throttle_reason_status"]="0\n"
assert(gpu_sample().quality=="gap" and gpu_sample().active==nil)
gpu_files[base.."/throttle_reason_pl4"]="0\n"
gpu_files[base.."/throttle_reason_pl1"]=nil
assert(gpu_sample().active==false and gpu_sample().quality=="partial")
gpu_files[base.."/throttle_reason_status"]=nil
assert(gpu_sample().active==nil)
for _,a in ipairs(attrs)do gpu_files[base.."/throttle_reason_"..a]={kind="denied",message="denied"}end
assert(gpu_sample().quality=="denied" and gpu_sample().active==nil)
local n=0
for _,a in ipairs(attrs)do gpu_files[base.."/throttle_reason_"..a]="0\n"end
gpu_files[base.."/throttle_reason_pl1"]=function() n=n+1;return n%2==0 and "1\n" or "0\n"end
assert(gpu_sample().quality=="gap" and find(gpu_sample().reasons,"pl1").active==nil)
gpu_files[base.."/throttle_reason_pl1"]="2\n"
assert(gpu_sample().quality=="partial" and find(gpu_sample().reasons,"pl1")==nil)

local en=assert(I18n.new({locale="en-US"}))
assert(not table.concat(TUI.power_detail_lines({cpu_limits=sampled.data},en),"\n"):find("\nNo data",1,true))
local stale=Snapshot.merge(state,{cpu_limits={status="error",quality="error",timestamp_ns=2000}},2,2000)
assert(Export.snapshot(stale).cpu_limits.domains[1].active==nil)
assert(#Export.agent(stale).metrics.power.cpu_limits.domains[1].active_reasons==0)
assert(View.performance_limit_rows(stale,en)[1].current=="Stale")
local gpu_domain={id="gt0",scope="gpu_gt",quality="fresh",source="fixture",active=false,
    reasons={{id="pl1",active=false},{id="pl2",active=false}}}
local dual={cpu_limits=sampled.data,gpus={devices={{id="gpu0",card="card0",metrics={},
    performance_limits={domains={gpu_domain}}}}}}
local engine={history_values=function()return {}end}
local data=dual.gpus.devices[1].performance_limits
data.truncated=true
assert(View.build(engine,dual,en,{},"gpu").gpu_table.rows[1].limits=="Unknown")
data.truncated=false
data.domains[2]={id="gt1",scope="gpu_gt",quality="denied",reasons={}}
assert(View.build(engine,dual,en,{},"gpu").gpu_table.rows[1].limits=="Denied")
data.domains[2]=nil
local clocks={gpus={devices={{id="ioreg:123456789",card="ioreg:123456789",model_name="Apple M4",
    metrics={frequency_current_hz=1300000000,memory_used_bytes=1024,memory_total_bytes=8192},
    quality={frequency="estimated"}}}}}
local clock_model=View.build(engine,clocks,en,{},"gpu").gpu_table
local grid=Grid.new(98,5)
Table.render(grid,{x=1,y=1,width=98,height=5},clock_model,{},"full")
assert(grid:row_text(2):find("~1.3 GHz",1,true),
    "missing power caps must not displace a measured GPU clock")
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"})do
    local i=assert(I18n.new({locale=locale}))
    local rows=View.performance_limit_rows(dual,i)
    assert(#rows==2 and rows[1].current:find("PL1",1,true))
    assert(rows[1].recorded:find("PL2/PL3",1,true))
    local text=table.concat(TUI.power_detail_lines(dual,i),"\n")
    assert(text:find("package:0",1,true) and text:find("gt0",1,true))
    assert(text:find(i:t("limits.history_note"),1,true))
    assert(i:has("reason.cpu_limits_not_supported") and i:has("limits.reason.electrical"))
end
print("ok: CPU and GT limit status, recorded flags, source scope, permissions, model support, races and stale exports")
