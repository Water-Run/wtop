package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Session = require("wtop.model.gpu_power_session")
local Observations = require("wtop.collectors.gpu_observations")
local GPU = require("wtop.collectors.gpu")
local Windows = require("wtop.collectors.windows_gpu")
local Fixture = require("support.fixture_fs")
local Export = require("wtop.export")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local function near(a,b) assert(type(a)=="number"and math.abs(a-b)<1e-8,tostring(a).." != "..tostring(b)) end
local function device(watts,kind)
    return { id="0000:01:00.0",pci_bdf="0000:01:00.0",vendor_uuid="GPU-test",vendor_id="0x10de",device_id="0x1234",
        identity_quality="fresh",driver="test",driver_version="1",model_name="GPU",
        metrics={power_watts=watts,power_measurement=kind or "driver_snapshot",power_scope="asic"},quality={power="fresh"} }
end
local function step(d,before,source,now,captured)
    local devices={d};Session.attach(devices,before,source,{sample_started_ns=captured or now},now,{})
    d.power_sessions=Session.rows(d,source,now,{quality="fresh"});return devices,d.power_sessions
end
local function nvidia(instant,average,stamp)
    local d=device(instant,"current");d.metrics.power_scope=nil
    d.metrics.power_instant_watts,d.metrics.power_average_watts=instant,average
    d.metrics.power_instant_timestamp_us,d.metrics.power_average_timestamp_us=stamp,stamp
    d.metrics.power_instant_quality,d.metrics.power_average_quality="fresh","fresh"
    d.metrics.power_average_interval_ns=1e9
    return d
end
local a,first=step(nvidia(10,20,100),nil,"nvml",1e9)
assert(#first==2 and first[1].metric=="power_instant_watts"and first[2].metric=="power_average_watts")
assert(first[1].sample_time_basis=="provider_timestamp"and first[1].samples==1)
local b,repeated=step(nvidia(10,20,100),a,"nvml",2e9)
assert(repeated[1].samples==1 and repeated[1].last_timestamp_ns==1e9,"SDK timestamp replay was counted again")
local c,changed=step(nvidia(30,40,200),b,"nvml",3e9)
near(changed[1].average_watts,20);near(changed[2].average_watts,30)
assert(changed[1].samples==2 and changed[1].current_watts==30)
assert(first[1].samples==1,"a new observation modified the prior snapshot")
local _,inconsistent=step(nvidia(99,40,200),c,"nvml",4e9)
assert(inconsistent[1].samples==2 and inconsistent[1].current_watts==nil and inconsistent[1].quality=="gap")
local _,old=step(nvidia(5,6,50),c,"nvml",4e9,2e9)
assert(old[1].samples==2 and old[1].quality=="stale"and old[1].last_timestamp_ns==3e9)
local _,clock_reset=step(nvidia(7,9,50),c,"nvml",4e9)
assert(clock_reset[1].samples==1 and clock_reset[1].minimum_watts==7)
local _,global_reset=step(nvidia(7,9,50),c,"nvml",1e9)
assert(global_reset[1].samples==1)
for _,quality in ipairs({"stale","gap","error","denied","held"})do
    local d=nvidia(90,100,300);d.metrics.power_instant_quality=quality
    local _,rows=step(d,c,"nvml",4e9)
    assert(rows[1].samples==2 and rows[1].current_watts==nil,quality)
end
local invalid=nvidia(10,20,0)
local _,no_stamp=step(invalid,nil,"nvml",1e9);assert(#no_stamp==0,"modern NVML fields without a valid sample timestamp acquired statistics")
local _,future=step(nvidia(10,20,400),c,"nvml",4e9,5e9)
assert(future[1].samples==2 and future[1].current_watts==nil)

local adl,point=step(device(10),nil,"adl",1e9)
local adl2;adl2,point=step(device(30),adl,"adl",2e9)
near(point[1].average_watts,20);assert(point[1].scope=="asic"and point[1].average_kind=="samples")
assert(point[1].energy_joules==nil and point[1].covered_time_ns==nil and point[1].sample_time_basis=="query_capture")
local _,same_capture=step(device(30),adl2,"adl",3e9,2e9)
assert(same_capture[1].samples==2 and same_capture[1].current_watts==30)
local _,changed_capture=step(device(50),adl2,"adl",3e9,2e9)
assert(changed_capture[1].samples==2 and changed_capture[1].quality=="gap"and not changed_capture[1].current_watts)
local absent=device(nil);local _,held=step(absent,adl2,"adl",3e9)
assert(held[1].samples==2 and held[1].quality=="unavailable"and held[1].current_watts==nil)
local _,method=step(device(40,"device_sample"),adl2,"adl",3e9);assert(method[1].samples==1)
for _,field in ipairs({"vendor_uuid","device_id","driver","driver_version","model_name"})do
    local d=device(40);d[field]="changed";local _,rows=step(d,adl2,"adl",3e9);assert(rows[1].samples==1,field)
end
local intel=device(10,"average");intel.vendor_id="0x8086";intel.metrics.power_scope="package";intel.metrics.power_interval_ns=1e9
local ze=step(intel,nil,"levelzero",1e9)
local intel2=device(20,"average");intel2.vendor_id="0x8086";intel2.metrics.power_scope="package";intel2.metrics.power_interval_ns=3e9
local _,windows=step(intel2,ze,"levelzero",4e9)
near(windows[1].average_watts,15)
assert(windows[1].minimum_interval_ns==1e9 and windows[1].maximum_interval_ns==3e9,"varying averaging windows discarded the session")
assert(windows[1].energy_joules==nil,"overlapping vendor averages were integrated as energy")
local board=device(40,"average");board.metrics.power_scope="card";board.metrics.board_power_watts=40
local _,board_rows=step(board,nil,"levelzero",1e9)
assert(#board_rows==1 and board_rows[1].metric=="board_power_watts","card reading alias was counted as another power plane")
local smi=device(0,"average");smi.vendor_id="0x1002"
local _,zero=step(smi,nil,"amdsmi",1e9);assert(zero[1].minimum_watts==0 and zero[1].samples==1)
local unknown={device(10)};Session.attach(unknown,nil,"adl",{},1e9,{})
assert(#Session.rows(unknown[1],"adl",1e9,{})==0,"unknown capture time produced independent samples")
local duplicate={device(10),device(20)};Session.attach(duplicate,nil,"adl",{sample_started_ns=1e9},1e9,{})
assert(not duplicate[1]._power_session_points and not duplicate[2]._power_session_points)
local headless=device(10);headless.pci_bdf=nil;headless.identity_quality="estimated"
local _,identified=step(headless,nil,"adl",1e9);assert(#identified==1,"headless UUID identity was discarded")
local anonymous=device(10);anonymous.pci_bdf=nil;anonymous.vendor_uuid=nil
local _,unidentified=step(anonymous,nil,"adl",1e9);assert(#unidentified==0)
local reused={device(10)};Session.attach(reused,nil,"adl",{sample_started_ns=1e9},1e9,{})
Session.attach(reused,reused,"adl",{sample_started_ns=1e9},1e9,{})
assert(Session.rows(reused[1],"adl",1e9,{})[1].samples==1)

-- Actual Linux collector joins and retained-provider publication, without a
-- GPU/driver requirement. The native packet shape goes through both adapters.
local now,watts,stamp,failed=1e9,10,100,false
local function provider()
    if failed then return nil,"nvml_query_timeout"end
    return {sample_started_ns=now,sample_finished_ns=now,driver_version="1",devices={{index=0,uuid="GPU-end-to-end",
        pci_bdf="0000:01:00.0",vendor_id="0x10de",device_id="0x1234",name="NVIDIA API fixture",
        power_watts=watts,power_quality="fresh",power_measurement="current",power_limit_watts=60,
        power_instant_watts=watts,power_average_watts=watts+10,power_instant_timestamp_us=stamp,power_average_timestamp_us=stamp,
        power_instant_quality="fresh",power_average_quality="fresh",power_average_interval_ns=1e9}}}
end
local fs=Fixture.new({dirs={["/sys/class/drm"]={},["/proc"]={}}})
local context={now_ns=function()return now end,fs=fs,scan_gpu_processes=false}
local collector=GPU.new({fs=fs,scan_processes=false,nvml=provider,amdsmi=false,levelzero=false})
local one=collector:sample(context);assert(#one.data.devices[1].power_sessions==2)
now,watts,stamp=2e9,30,200;local two=collector:sample(context,one)
near(two.data.devices[1].power_sessions[1].average_watts,20)
now,failed=3e9,true;local retained=collector:sample(context,two)
assert(retained.data.devices[1].power_sessions[1].samples==2 and retained.data.devices[1].power_sessions[1].quality=="stale")
assert(not retained.data.devices[1].power_sessions[1].current_watts)
now,failed,watts,stamp=4e9,false,50,300;local recovered=collector:sample(context,retained)
near(recovered.data.devices[1].power_sessions[1].average_watts,30)
assert(recovered.data.devices[1].power_sessions[1].samples==3)
local function target()
    local t={};for k,v in pairs(recovered.data.devices[1])do t[k]=v end;return t
end
local alternate=target();alternate.vendor_id="0X10DE";alternate.device_id="0X1234"
collector._observations:publish_power_sessions({alternate},{},now)
assert(#alternate.power_sessions==2,"equivalent PCI ID spelling broke the association")
local contradictory=target();contradictory.vendor_uuid="different-GPU"
collector._observations:publish_power_sessions({contradictory},{},now)
assert(#contradictory.power_sessions==0,"statistics crossed a contradictory UUID")
local twins={target(),target()};collector._observations:publish_power_sessions(twins,{},now)
assert(#twins[1].power_sessions==0 and #twins[2].power_sessions==0,"ambiguous target identities acquired statistics")
local record=collector._observations.sources.nvml.records[1];local anchor=record.anchor
record.anchor="old-anchor";local moved=target()
collector._observations:publish_power_sessions({moved},{[moved.pci_bdf]="new-anchor"},now)
assert(#moved.power_sessions==0,"statistics crossed a changed DRM anchor");record.anchor=anchor
local base_input
local base={probe=function()return {available=true}end,sample=function()
    base_input={devices={{id="adapter0",pci_bdf="0000:01:00.0",vendor_id="0x10de",device_id="0x1234",driver="test",
        identity_quality="fresh",metrics={},quality={},capabilities={}}}}
    return {status="ok",quality="fresh",timestamp_ns=now,sample_started_ns=now,data=base_input}
end}
local native=Windows.new(base,{nvml_provider=provider,levelzero_provider=false,adl_provider=false},{})
local win1=native:sample(context);assert(#win1.data.devices[1].power_sessions==2)
now,watts,stamp=5e9,70,400;local win2=native:sample(context)
assert(win2.data.devices[1].power_sessions[1].samples==2)
assert(base_input.devices[1].power_sessions==nil,"GPU statistics mutated cached host inventory")

local snapshot={timestamp_ns=now,gpus=recovered.data,quality={gpus={status="ok",quality="fresh"}}}
local public=Export.snapshot(snapshot)
near(public.gpus.devices[1].power_sessions[1].average_watts,30)
local encoded=assert(require("wtop.format.json").encode(public))
assert(not encoded:find("_power_session",1,true)and not encoded:find("_accepted_watts",1,true))
local agent=Export.agent(snapshot,{device_limit=1});assert(#agent.top.gpus[1].power_sessions==2)
assert(Report.render(public):find("GPU API power statistics",1,true))
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"})do
    local tr=assert(I18n.new({locale=locale}));local text=table.concat(TUI.power_detail_lines(snapshot,tr),"\n")
    assert(text:find(tr:t("power.api_statistics"),1,true)and text:find(tr:t("power.reading.instant"),1,true),locale)
    assert(text:find(tr:t("power.reading.average"),1,true)and not text:find("power.reading.",1,true),locale)
end
snapshot.quality.gpus={status="error",quality="fresh"}
local bad=Export.snapshot(snapshot).gpus.devices[1].power_sessions[1]
assert(bad.quality=="error"and bad.current_watts==nil and bad.samples==3)
local aged=Session.public(recovered.data.devices[1],now+20e9)[1]
assert(aged.quality=="stale"and aged.current_watts==nil)
assert(#Session.public(recovered.data.devices[1],1e9)==0,"future session statistics were exported")
local invalid_public={};for k,v in pairs(changed[1])do invalid_public[k]=v end
invalid_public.provider_timestamp_us=nil
assert(#Session.public({power_sessions={invalid_public}},now)==0,"provider sample identity was fabricated")
invalid_public.average_kind="time_weighted";invalid_public.sample_time_basis="query_capture"
invalid_public.covered_time_ns=2e9;invalid_public.energy_joules=40
assert(#Session.public({power_sessions={invalid_public}},now)==0,"API windows became a time-integrated series")
collector:stop();native:close()
print("ok: independent GPU API reading channels, sample identity/cache, scope/epoch guards, Linux/Windows joins and shared consumers")
