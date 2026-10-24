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

-- Xe's aggregate file is a single observation, independent of the status and
-- per-reason files. Tile/GT identities must not collapse into one clock.
do
    local Fixture = require("support.fixture_fs")
    local path = "/drm/card0/device"
    local base = path .. "/tile0/gt0/freq0/throttle"
    local other = path .. "/tile2/gt1/freq0/throttle"
    local files = { [base .. "/reasons"] = "pl1 thermal\n", [other .. "/reasons"] = "none\n" }
    local function fs(extra)
        extra = extra or {}; extra.files = files; return Fixture.new(extra)
    end
    local function sample(source, maximum)
        return GPU.xe(source or fs(), path, maximum or 8, function() return 4000 end)
    end
    local source = fs()
    local original_read, aggregate_reads = source.read, 0
    function source:read(name, maximum)
        assert(name:match("/reasons$"), "aggregate Xe state queried racy individual attributes")
        aggregate_reads = aggregate_reads + 1
        return original_read(self, name, maximum)
    end
    local data = sample(source)
    assert(data.quality == "fresh" and data.enumeration_complete and aggregate_reads == 2)
    assert(#data.domains == 2 and data.domains[1].id == "tile0/gt0/freq0")
    local domain = data.domains[1]
    assert(domain.tile_id == 0 and domain.gt_id == 0 and domain.frequency_id == 0)
    assert(domain.source == base .. "/reasons" and domain.observed_at_ns == 4000)
    assert(domain.reading_kind == "aggregate_reasons" and domain.active)
    assert(find(domain.reasons, "pl1").active and find(domain.reasons, "thermal").active)
    assert(find(domain.reasons, "pl2") == nil, "aggregate active reasons are not support bits")
    assert(data.domains[2].active == false and #data.domains[2].reasons == 0)
    for _, text in ipairs({"", "none pl1", "pl1 pl1", "pl1\0", "vr_thermal vr_thermalert", string.rep("x",4097)}) do
        files[base .. "/reasons"] = text
        local invalid = sample().domains[1]
        assert(invalid.quality == "error" and invalid.active == nil)
    end
    files[base .. "/reasons"] = "soc_thermal mem_thermal iccmax pwrbrk soc_avg_thermal fastvmode psys_pl1 psys_pl2 p0_freq psys_crit\n"
    local newer = sample().domains[1]
    assert(newer.quality == "fresh" and #newer.reasons == 10)
    files[base .. "/reasons"] = "pl2 future_reason\n"
    local future = sample().domains[1]
    assert(future.active and future.quality == "partial" and future.unknown_reason_names[1] == "future_reason")
    local current = { gpus = { devices = { { id="gpu0",card="card0",metrics={},performance_limits={domains={future}} } } } }
    assert(View.performance_limit_rows(current,assert(I18n.new({locale="en-US"})))[1].current:find("Unknown flags",1,true))
    local exported = Export.snapshot(current).gpus.devices[1].performance_limits.domains[1]
    assert(exported.unknown_reason_names[1] == "future_reason" and exported.tile_id == 0)
    assert(Export.agent(current).top.gpus[1].performance_limits.domains[1].unknown_reason_names[1] == "future_reason")
    assert(Report.render(Export.snapshot(current)):find("future_reason (unknown)",1,true))
    current.quality={gpus={status="error",quality="stale"}}
    assert(not Report.render(Export.snapshot(current)):find("future_reason (unknown)",1,true))
    local denied = sample(fs({denied={[base.."/reasons"]=true}})).domains[1]
    assert(denied.quality == "denied" and denied.active == nil)
    files[base .. "/reasons"] = "none\n"
    local cut = sample(nil,1)
    assert(cut.truncated and not cut.enumeration_complete and #cut.domains == 1)
    local missing = sample(fs({denied={[path.."/tile2"]=true}}))
    assert(not missing.enumeration_complete and missing.quality == "partial")
    current.quality=nil;current.gpus.devices[1].performance_limits=missing
    assert(View.build({history_values=function()return{}end},current,assert(I18n.new({locale="en-US"})),{},"gpu").gpu_table.rows[1].limits=="Unknown")

    -- On older kernels only the listed per-reason files are supported. Two
    -- equal rounds are required; missing/denied reads never become false.
    files[base.."/reasons"],files[other.."/reasons"] = nil,nil
    files[base.."/status"],files[base.."/reason_pl1"],files[base.."/reason_thermal"]="0\n","0\n","0\n"
    local old = sample().domains[1]
    assert(old.active==false and old.quality=="fresh" and old.reading_kind=="individual_flags")
    assert(#old.reasons==2 and find(old.reasons,"pl2")==nil)
    files[base.."/status"],files[base.."/reason_pl1"]="1\n","1\n"
    old=sample().domains[1];assert(old.active and find(old.reasons,"pl1").active)
    local racing=fs();local original=racing.read;local reads=0
    function racing:read(name,maximum)
        if name==base.."/reason_pl1" then reads=reads+1;return reads==1 and "1\n" or "0\n" end
        return original(self,name,maximum)
    end
    local mixed=sample(racing).domains[1];assert(mixed.quality=="gap" and mixed.active==nil and #mixed.reasons==0)
    files[base.."/status"]="0\n"
    mixed=sample().domains[1];assert(mixed.active==nil and mixed.quality=="gap")
    local denied_flags=sample(fs({denied={[base.."/status"]=true,[base.."/reason_pl1"]=true,[base.."/reason_thermal"]=true}})).domains[1]
    assert(denied_flags.active==nil and denied_flags.quality=="denied")

    -- The actual DRM collector, not only the helper, must publish these domains.
    files[base.."/reasons"]="pl1\n"
    files["/drm/card0/dev"]="226:0\n"
    files[path.."/vendor"],files[path.."/device"],files[path.."/class"]="0x8086\n","0x56a0\n","0x030000\n"
    local drm_fs=fs({links={[path]="../../../devices/pci0000:00/0000:03:00.0",[path.."/driver"]="../../../../bus/pci/drivers/xe"}})
    local collector=require("wtop.collectors.gpu").new({fs=drm_fs,drm_path="/drm",proc_path="/proc",scan_processes=false})
    local result=collector:sample({fs=drm_fs,now_ns=function()return 4000 end})
    assert(result.status=="ok" and #result.data.devices==1)
    local device=result.data.devices[1]
    assert(device.driver=="xe" and device.capabilities.performance_limits and device.performance_limits.domains[1].active)
    for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"}) do
        local i=assert(I18n.new({locale=locale}))
        local state={gpus={devices={{id="gpu0",card="card0",metrics={},performance_limits={domains={newer}}}}}}
        local rendered=table.concat(TUI.power_detail_lines(state,i),"\n")
        assert(rendered:find(i:t("limits.reason.soc_thermal"),1,true))
        assert(rendered:find(i:t("limits.reason.psys_critical"),1,true))
        assert(not rendered:find(i:t("limits.history_note"),1,true))
    end
    print("ok: Xe aggregate/legacy current reasons, tile/GT identity, races, bounds, exports and translated UI")
end

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
-- NVML current event reasons are separate from supported capabilities and
-- have no historical latch. Preserve all 64 bits, including future reasons.
local function event(raw, supported, status, support_status)
    return GPU.nvml({ raw_hex=raw, supported_hex=supported, status_code=status or 0,
        supported_status_code=support_status or 0,
        source="nvmlDeviceGetCurrentClocksEventReasons" },5000)
end
local quiet=event("0x0000000000000000","0x00000000000007ff")
assert(quiet.quality=="fresh" and quiet.active==false)
assert(find(quiet.reasons,"software_power_cap").active==false)
local limited=event("0x0000000000000044","0x00000000000007ff")
assert(limited.active and limited.scope=="gpu_clock" and limited.observed_at_ns==5000)
assert(find(limited.reasons,"software_power_cap").active and find(limited.reasons,"hardware_thermal").active)
assert(find(limited.reasons,"idle").active==false and find(limited.reasons,"idle").logged==nil)
local idle=event("0x0000000000000001","0x00000000000001ff")
assert(idle.active and find(idle.reasons,"idle").active and not find(idle.reasons,"hardware_thermal").active)
assert(find(idle.reasons,"board_limit").supported==false and find(idle.reasons,"board_limit").active==nil)
local caps_missing=event("0x0000000000000004",nil,0,3)
assert(caps_missing.quality=="fresh" and caps_missing.active)
assert(find(caps_missing.reasons,"software_power_cap").active)
assert(find(caps_missing.reasons,"hardware_thermal").active==nil,
    "unsupported capability query does not invent false values for other flags")
local unknown=event("0x8000000000000004","0x80000000000007ff")
assert(unknown.quality=="partial" and unknown.active and unknown.unknown_status_hex=="0x8000000000000000")
assert(find(unknown.reasons,"software_power_cap").active)
assert(event("0xffffffffffffffff","0x00000000000007ff").active==nil)
assert(event("bad","0x00000000000007ff").quality=="error")
assert(event(nil,nil,4,4).quality=="denied" and event(nil,nil,4,4).active==nil)
assert(event(nil,nil,15,3).quality=="gap")
assert(event(nil,nil,13,13).quality=="unavailable")
assert(event("0x0000000000000004","0x0000000000000000").quality=="partial")
local vendor_state={gpus={devices={{id="nvml0",card="nvml0",metrics={},
    performance_limits={domains={limited}}}}}}
local exported=Export.snapshot(vendor_state).gpus.devices[1].performance_limits.domains[1]
assert(exported.raw_hex=="0x0000000000000044" and exported.supported_hex=="0x00000000000007ff")
assert(find(exported.reasons,"idle").supported==true)
local agent=Export.agent(vendor_state).top.gpus[1].performance_limits.domains[1]
assert(agent.active_reasons[1]=="software_power_cap" and #agent.recorded_reasons==0)
assert(agent.supported_hex=="0x00000000000007ff")
vendor_state.quality={gpus={quality="stale",status="error"}}
assert(not Export.agent(vendor_state).top.gpus[1].performance_limits.domains[1].active)
assert(#Export.agent(vendor_state).top.gpus[1].performance_limits.domains[1].active_reasons==0)
vendor_state.quality=nil
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"})do
    local i=assert(I18n.new({locale=locale}))
    local rendered=table.concat(TUI.power_detail_lines(vendor_state,i),"\n")
    assert(rendered:find(i:t("limits.reason.software_power_cap"),1,true))
    assert(rendered:find(i:t("limits.reason.hardware_thermal"),1,true))
    assert(rendered:find("0x0000000000000044",1,true) and rendered:find("0x00000000000007ff",1,true))
    assert(not rendered:find(i:t("limits.history_note"),1,true),"NVML current events do not become historical flags")
end
local unknown_state={gpus={devices={{id="gpu0",card="gpu0",metrics={},performance_limits={domains={unknown}}}}}}
assert(View.performance_limit_rows(unknown_state,en)[1].current:find("Unknown flags",1,true))

local NVML=require("wtop.collectors.nvml")
assert(NVML.normalize_bdf("0000:01:20.0")==nil and NVML.normalize_bdf("0000:01:00.8")==nil)
local entries={};local lookup={by_bdf={}}
local merged=NVML.merge(entries,lookup,{status="partial",truncated=true,devices={{index=0,
    name="NVIDIA fixture",pci_bdf="0000:03:1a.3",power_watts=42.25,power_limit_watts=355.5,
    power_measurement="average",power_interval_ns=1e9,power_average_watts=42.25,
    clock_events={status_code=0,raw_hex="0x0000000000000004",supported_status_code=0,supported_hex="0x00000000000007ff"},
    processes={{pid=4242,sm_percent=10,sample_timestamp_us=200,sample_window="driver_buffer"}},
}}},{used_ids={},now_ns=9000,include_processes=true})
assert(merged.status=="partial" and merged.truncated and entries[1].performance_limits.domains[1].observed_at_ns==9000)
assert(entries[1].processes.list[1].quality=="estimated" and entries[1].processes.list[1].sample_window=="driver_buffer")
local averaged={gpus={devices=entries,providers={nvml=merged}}}
local summary=Export.agent(averaged)
assert(summary.top.gpus[1].metrics.power_average_watts==42.25 and summary.top.gpus[1].metrics.power_interval_ns==1e9)
assert(summary.top.gpus[1].metrics.power_measurement=="average")
assert(summary.metrics.gpu.providers.nvml.truncated==true)
local rendered=table.concat(TUI.power_detail_lines(averaged,en),"\n")
assert(rendered:find("Average",1,true) and rendered:find("Sample window:",1,true))
local old_entries={}
NVML.merge(old_entries,{by_bdf={}},{devices={{index=0,name="Old power sample",pci_bdf="0000:03:00.0",
    power_watts=300,power_limit_watts=355.5,power_quality="stale",power_measurement="current",
    power_instant_watts=300,power_instant_quality="stale",power_instant_timestamp_us=1234}}},{used_ids={}})
local old_power={gpus={devices=old_entries}}
assert(Export.snapshot(old_power).gpus.devices[1].metrics.power_limit_percent==nil)
assert(Export.agent(old_power).top.gpus[1].metrics.power_limit_percent==nil)
assert(Export.agent(old_power).top.gpus[1].metrics.power_instant_quality=="stale")
assert(View.build(engine,old_power,en,{},"gpu").gpu_table.rows[1].power:find("Stale",1,true))
assert(table.concat(TUI.power_detail_lines(old_power,en),"\n"):find("Stale",1,true))
local cap_only={gpus={devices={{id="gpu0",card="gpu0",metrics={power_limit_watts=355.5,
    power_limit_source="nvml"}}}}}
assert(View.build(engine,cap_only,en,{},"gpu").gpu_table.rows[1].power_budget_source=="nvml")
local process_export=Export.snapshot(averaged).gpus.devices[1].processes.list[1]
assert(process_export.sample_window=="driver_buffer" and process_export.sample_timestamp_us==200)

print("ok: CPU, GT and NVML limit status, recorded flags, source scope, permissions, model support, races and stale exports")

-- Sysman flags are current-only, use the native sample time, and do not
-- invent per-reason support bits from a global throttle capability.
local sysman=GPU.levelzero({{index=0,kind="gpu",throttle_quality="fresh",throttle_raw_hex="0x00000000000003ff"}},123)[1]
assert(sysman.active and sysman.observed_at_ns==123 and #sysman.reasons==10)
for _,reason in ipairs(sysman.reasons) do assert(reason.active==true and reason.supported==nil) end
local unknown=GPU.levelzero({{throttle_quality="fresh",throttle_raw_hex="0x0000000000000400"}},123)[1]
assert(unknown.quality=="partial" and unknown.unknown_status_hex=="0x0000000000000400")
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"}) do
    local i=assert(I18n.new({locale=locale}))
    for _,reason in ipairs(sysman.reasons) do assert(i:has("limits.reason."..reason.id)) end
end

-- A global current-state synopsis needs complete package observations. A
-- supported subset, historical latch or denied package cannot establish zero.
do
    local Summary = require("wtop.model.cpu_limits")
    local Metric = require("wtop.ui.widgets.metric")
    local function domain(raw, quality, id)
        local value = assert(CPU.decode(string.pack("<I4I4", raw, 0)))
        value.id, value.scope, value.package_id = id or "package:0", "cpu_package", 0
        if quality then value.quality = quality end
        return value
    end
    local function data(domains, complete)
        return { schema = "dev.waterrun.wtop.cpu-limits/v1", domains = domains,
            roster_complete = true, coverage_complete = complete ~= false,
            domains_discovered = #domains, domains_supported = #domains,
            domains_observed = #domains }
    end
    local fresh = { status = "ok", quality = "fresh" }
    local active = data({ domain(1 << 10) })
    local result = Summary.reduce(active, fresh)
    assert(result.active == true and result.reasons[1] == "pl1" and result.complete)
    result = Summary.reduce(data({ domain((1 << 1) << 16) }), fresh)
    assert(result.active == false and #result.reasons == 0, "latched thermal is not current")
    for _, state in ipairs({ "stale", "denied", "error", "gap", "reset", "unavailable", "held", "estimated" }) do
        result = Summary.reduce(active, { status = "ok", quality = state })
        assert(result.active == nil and #result.reasons == 0, state)
    end
    result = Summary.reduce(data({ domain(1 << 10), domain(0) }), fresh)
    assert(result.active == nil and result.known_active == 0, "duplicate identities are ambiguous")
    result = Summary.reduce(data({ domain(0), domain(0, "denied", "package:1") }), fresh)
    assert(result.active == nil and not result.complete)
    result = Summary.reduce(data({ domain(0) }, false), fresh)
    assert(result.active == nil, "missing packages prevent a global inactive result")
    result = Summary.reduce(data({ domain(4) }), fresh)
    assert(result.active == nil, "unknown status bits do not imply inactivity")
    local snapshot = { cpu = { total = { utilization = 100 } }, cpu_limits = active,
        quality = { cpu_limits = fresh } }
    local engine = { history_values = function() return {} end }
    local en = assert(I18n.new({ locale = "en-US" }))
    local model = View.build(engine, snapshot, en, {}, "overview", nil, { cpu_overview = true })
    assert(model.cpu_overview.secondary_value == "Current limits: PL1")
    assert(Export.snapshot(snapshot).cpu_limits.coverage_complete)
    assert(Export.agent(snapshot).metrics.power.cpu_limits.coverage_complete)
    snapshot.quality.cpu_limits = { status = "ok", quality = "stale" }
    assert(Export.snapshot(snapshot).cpu_limits.coverage_complete == false)
    assert(Export.agent(snapshot).metrics.power.cpu_limits.coverage_complete == false)
    snapshot.quality.cpu_limits = fresh
    for id = 1, 12 do active.domains[#active.domains + 1] = domain(0, nil, "package:" .. id) end
    assert(Export.agent(snapshot).metrics.power.cpu_limits.truncated)
    assert(Export.agent(snapshot).metrics.power.cpu_limits.coverage_complete == false)
    local old_reduce = Summary.reduce
    Summary.reduce = function() error("hidden or process-only CPU synopsis ran") end
    View.build(engine, snapshot, en, {}, "processes")
    View.build(engine, snapshot, en, {}, "overview", nil, { memory_overview = true })
    Summary.reduce = old_reduce

    local scenarios = { data({ domain(0) }), data({ domain((1 << 1) << 16) }),
        data({ domain(1 << 10) }), data({ domain((1 << 10) | (1 << 12) | (1 << 1) | (1 << 6)) }),
        data({ domain(1 << 10) }, false), data({ domain(0, "denied") }), data({ domain(4) }) }
    for _, locale in ipairs({ "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "pt-BR", "ru-RU" }) do
        local translator = assert(I18n.new({ locale = locale }))
        for _, current in ipairs(scenarios) do
            snapshot.cpu_limits = current
            local models = View.build(engine, snapshot, translator, {}, "overview", nil, { cpu_overview = true })
            local cpu = models.cpu_overview
            cpu.display_value = "100.0%"
            for _, width in ipairs({ 12, 16, 28, 38, 58, 98 }) do
                local grid = Grid.new(width, 8)
                Metric.render(grid, { x = 1, y = 1, width = width, height = 8 }, cpu,
                    { panel_title = true }, "full")
                local line = grid:row_text(1)
                assert(line:find("100.0%", 1, true), "CPU value truncated")
                if width >= 38 then
                    local full = cpu.secondary_value
                    local short = cpu.secondary_values[1]
                    assert(line:find(full, 1, true) or line:find(short, 1, true),
                        "default80 CPU tile lost all limit-state context: " .. locale)
                end
            end
        end
    end
    local more = {}
    for name, value in pairs(files) do more[name] = value end
    more[root .. "/cpu1/topology/physical_package_id"] = "1\n"
    more["/proc/cpuinfo"] = "processor : 0\nvendor_id : GenuineIntel\ncpu family : 6\nmodel : 186\n\n"
        .. "processor : 1\nvendor_id : GenuineIntel\ncpu family : 6\nmodel : 92\n\n"
    local probe = CPU.new({ fs = fixture(more), reader = function(id)
        assert(id == 0, "unsupported package register was read")
        return bytes(0, 0)
    end })
    local mixed = probe:sample({ now_ns = function() return 8000 end })
    assert(mixed.quality == "partial" and mixed.data.roster_complete)
    assert(mixed.data.domains_discovered == 2 and mixed.data.domains_supported == 1
        and mixed.data.domains_observed == 1 and not mixed.data.coverage_complete)
    assert(Summary.reduce(mixed.data, { status = "ok", quality = "partial" }).active == nil)
    local coverage = View.cpu_limit_coverage_text({ cpu_limits = mixed.data }, en)
    assert(coverage:find("1/2", 1, true) and coverage:find("1 supported", 1, true))
end

-- Unknown-only records count towards the same CPUinfo cap. Skipping them could
-- admit an identity the original bounded roster never established.
do
    local base="/sys/devices/system/cpu"
    local input="ignored: one\n\nignored: two\n\nprocessor: 0\nvendor_id: GenuineIntel\ncpu family: 6\nmodel: 186\n"
    local data={ [base.."/online"]="0\n", ["/proc/cpuinfo"]=input,
        [base.."/cpu0/topology/physical_package_id"]="0\n" }
    local probes=0
    local limited=CPU.new({fs=fixture(data),max_cpus=1,reader=function()
        probes=probes+1;return bytes(0,0)
    end})
    assert(limited:probe({}).state=="unavailable")
    assert(limited:sample({}).status=="unavailable" and probes==0)
    data["/proc/cpuinfo"]=input:gsub("ignored: two\n\n", "", 1)
    assert(limited:sample({}).data.domains[1].active==false and probes==1)

    -- A model or vendor change during a successful read still invalidates it.
    for _, replacement in ipairs({"processor: 0\nvendor_id: GenuineIntel\ncpu family: 6\nmodel: 92\n",
        "processor: 0\nvendor_id: AuthenticAMD\ncpu family: 6\nmodel: 186\n"}) do
        data["/proc/cpuinfo"]="processor: 0\nvendor_id: GenuineIntel\ncpu family: 6\nmodel: 186\n"
        limited.reader=function()data["/proc/cpuinfo"]=replacement;return bytes(1<<10,0)end
        local raced=limited:sample({}).data.domains[1]
        assert(raced.quality=="gap" and raced.active==nil)
        for _, reason in ipairs(raced.reasons) do assert(reason.active==nil and reason.logged==nil) end
    end
end
