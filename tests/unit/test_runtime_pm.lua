local Reader = require("wtop.collectors.runtime_pm")
local PM = require("wtop.model.runtime_pm")
local Inventory = require("wtop.collectors.inventory")
local FS = require("wtop.linux.fs")
local Snapshot = require("wtop.model.snapshot")
local Export = require("wtop.export")
local Report = require("wtop.report")
local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")
local Json = require("wtop.format.json")
local path = "/sys/bus/pci/devices/0000:00:02.0"
local function fixture(extra, hook)
    local files = {
        [path .. "/vendor"]="0x8086", [path .. "/device"]="0x1234",
        [path .. "/class"]="0x030000", [path .. "/revision"]="0x01",
        [path .. "/power/runtime_status"]="suspended", [path .. "/power_state"]="D0",
        [path .. "/power/control"]="auto", [path .. "/power/runtime_active_time"]="4294967297",
        [path .. "/power/runtime_suspended_time"]="17000", [path .. "/power/autosuspend_delay_ms"]="-1",
        [path .. "/d3cold_allowed"]="0",
    }
    for k,v in pairs(extra or {})do files[path .. "/" .. k]=v end
    local reads={}
    local fs=FS.new({root="/",read_file=function(name,limit)
        reads[#reads+1]=name
        assert(not name:match("/config$")and not name:match("/resource%d*$")and not name:match("/serial$"))
        local value=hook and hook(name,files)or files[name]
        if value==false or value==nil then return nil,{kind="missing"}end
        if type(value)=="table"then return nil,value end
        if #value>limit then return nil,{kind="too_large"}end
        return value
    end,list_dir=function(name)
        if name=="/sys/bus/pci/devices"then return{"0000:00:02.0"}end
        return{}
    end,read_link=function()return nil,{kind="missing"}end})
    return fs,reads,files
end
local context={now_ns=function()return 1000000000 end}
local fs=fixture()
local raw=Reader.read(fs,path,context,true,function()return true end)
assert(raw.runtime_status=="suspended"and raw.pci_state=="D0"and raw.d3cold_allowed==false)
assert(raw.active_time_ms==4294967297 and raw.suspended_time_ms==17000 and raw.autosuspend_delay_ms==-1)
assert(raw.status=="ok"and not raw.state_changed)
local public=PM.public(raw,{status="ok",quality="fresh"},1000000000)
assert(public.quality=="fresh"and public.age_ms==0)
for _,value in ipairs({"-1","1.5","1e3","0xff","9223372036854775808",string.rep("1",65)})do
    local source=fixture({["power/runtime_active_time"]=value})
    local r=Reader.read(source,path,context,true)
    assert(r.active_time_ms==nil and r.status=="partial"and r.errors.active_time_ms=="error",value)
end
for _,value in ipairs({"-2147483648","2147483647"})do
    assert(Reader.read(fixture({["power/autosuspend_delay_ms"]=value}),path,context,true).autosuspend_delay_ms==tonumber(value))
end
for _,value in ipairs({"-2147483649","2147483648","+1","1.0"})do
    assert(Reader.read(fixture({["power/autosuspend_delay_ms"]=value}),path,context,true).autosuspend_delay_ms==nil)
end
local denied=Reader.read(fixture({["power/runtime_status"]={kind="denied"}}),path,context,true)
assert(denied.status=="partial"and denied.errors.runtime_status=="denied"and denied.runtime_status==nil)
local unsupported=Reader.read(fixture({["power/runtime_status"]="unsupported",
    ["power/autosuspend_delay_ms"]={kind="io_error",errno=5}}),path,context,true)
assert(unsupported.runtime_status=="unsupported"and unsupported.errors.autosuspend_delay_ms=="unavailable")
local n=0
local changing=Reader.read(fixture({},function(name)
    if name==path.."/power/runtime_status"then n=n+1;return n==1 and"active"or"suspended"end
end),path,context,true)
assert(changing.runtime_status=="suspended"and changing.state_changed and changing.errors.capture=="gap")
local replaced=Reader.read(fs,path,context,true,function()return false end)
assert(replaced.status=="unavailable"and replaced.active_time_ms==nil and replaced.pci_state==nil and replaced.errors.identity=="gap")
assert(PM.public(replaced,{status="ok",quality="fresh"},1000000000).quality=="unavailable")
local incoherent={};for key,value in pairs(raw)do incoherent[key]=value end
incoherent.status="partial";incoherent.errors={identity="gap"}
local hidden=PM.public(incoherent,nil,1000000000)
assert(hidden.status=="unavailable"and hidden.runtime_status==nil and hidden.active_time_ms==nil and hidden.d3cold_allowed==nil)
local absent={read=function()return nil,{kind="missing"}end}
assert(Reader.read(absent,path,context,true)==nil)
local all_denied={read=function()return nil,{kind="denied"}end}
assert(Reader.read(all_denied,path,context,true).status=="denied")
assert(PM.public(raw,{status="error",quality="stale"},1000000000).quality=="stale")
assert(PM.public(raw,{status="ok",quality="fresh"},92000000000).quality=="stale")
assert(PM.public(raw,nil,900000000).quality=="gap")
local floating={};for k,v in pairs(raw)do floating[k]=v end
floating.capture_started_ns=1000000000.25;floating.capture_finished_ns=1000000000.75;floating.observed_at_ns=1000000000.75
assert(PM.public(floating,nil,1000000001).quality=="fresh")
floating.capture_started_ns=2000000000
assert(PM.public(floating,nil,1000000001).quality=="gap")
local result=Inventory.new({fs=fs,pci_ids_paths={}}):sample(context)
assert(result.data.pci.devices[1].runtime_pm.active_time_ms==4294967297)
local old_kernel=fixture({revision=false})
assert(Inventory.new({fs=old_kernel,pci_ids_paths={}}):sample(context).data.pci.devices[1].runtime_pm.runtime_status=="suspended")
local vendor_reads=0
local replaced_fs=fixture({},function(name)
    if name==path.."/vendor"then vendor_reads=vendor_reads+1;return vendor_reads==1 and"0x8086"or"0x1002"end
end)
assert(Inventory.new({fs=replaced_fs,pci_ids_paths={}}):sample(context).data.pci.devices[1].runtime_pm.status=="unavailable")
local snapshot=Snapshot.merge(nil,{inventory=result},1,1000000000)
local before=Json.encode(snapshot)
local out=Export.snapshot(snapshot);local row=out.inventory.pci.devices[1].runtime_pm
assert(row.pci_state=="D0"and row.runtime_status=="suspended"and row.d3cold_allowed==false)
local agent=Export.agent(snapshot,{device_limit=1})
assert(agent.metrics.device_power.runtime_status_counts.suspended==1 and agent.metrics.device_power.pci_state_counts.D0==1)
assert(agent.top.device_power[1].id=="pci:0000:00:02.0"and agent.top.device_power[1].active_time_ms==4294967297)
assert(#agent.signals==0,"kernel PM reports and policies do not imply live health faults")
assert(Report.render(out):find("Device power management",1,true))
assert(before==Json.encode(snapshot),"public PM projection mutated its observation")
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","de-DE","fr-FR","es-ES","pt-BR","ru-RU"})do
    local i=assert(I18n.new({locale=locale}));local lines=table.concat(TUI.hardware_detail_lines(snapshot,"pci:0000:00:02.0",i,1000000000),"\n")
    for _,key in ipairs({"title","status","pci_state","active_time","suspended_time","d3cold","note"})do assert(lines:find(i:t("runtime_pm."..key),1,true),locale..key)end
    assert(lines:find("D0",1,true)and lines:find(i:t("runtime_pm.state.suspended"),1,true))
end
local stale=Snapshot.merge(snapshot,{inventory={status="error",quality="stale"}},2,2000000000)
local document=Export.agent(stale)
assert(document.metrics.device_power.runtime_status_counts.unknown==1 and not document.metrics.device_power.runtime_status_counts.suspended)
assert(document.top.device_power[1].quality=="stale")
local crowded={pci={devices={}}}
for j=1,8 do crowded.pci.devices[j]={address=tostring(j),runtime_pm=raw}end
local summary=PM.summary(crowded,nil,1000000000,1)
assert(summary.devices_total==8 and #summary.devices==1 and summary.devices_truncated and summary.runtime_status_counts.suspended==8)
local transitional={pci={devices={{address="a",runtime_pm=changing}}}}
assert(PM.summary(transitional,nil,1000000000,5).runtime_status_counts.unknown==1)
local usb_path="/sys/bus/usb/devices/1-2"
local function usb_fixture(replug)
    local reads,devnum= {},0
    local fields={idVendor="8087",idProduct="0026",busnum="1",devnum="3",
        ["power/runtime_status"]="active",["power/control"]="auto",
        ["power/runtime_active_time"]="1234",["power/runtime_suspended_time"]="5678"}
    return FS.new({root="/",read_file=function(name)
        reads[#reads+1]=name
        assert(not name:match("/power_state$")and not name:match("/d3cold_allowed$")and not name:match("/serial$"))
        local key=name:sub(#usb_path+2)
        if key=="devnum"then devnum=devnum+1;if replug and devnum>1 then return"4"end end
        if fields[key]then return fields[key]end
        return nil,{kind="missing"}
    end,list_dir=function(name)
        return name=="/sys/bus/usb/devices"and{"1-2"}or{}
    end,read_link=function()return nil,{kind="missing"}end}),reads
end
local usb_fs=usb_fixture()
local usb_result=Inventory.new({fs=usb_fs,pci_ids_paths={}}):sample(context)
assert(#usb_result.data.usb.devices==1)
local usb_pm=usb_result.data.usb.devices[1].runtime_pm
assert(usb_pm.runtime_status=="active"and usb_pm.active_time_ms==1234 and usb_pm.pci_state==nil and usb_pm.d3cold_allowed==nil)
local replugged=Inventory.new({fs=usb_fixture(true),pci_ids_paths={}}):sample(context)
assert(replugged.data.usb.devices[1].runtime_pm.status=="unavailable"and replugged.data.usb.devices[1].runtime_pm.active_time_ms==nil)
local usb_snapshot=Snapshot.merge(nil,{inventory=usb_result},1,1000000000)
assert(Export.snapshot(usb_snapshot).inventory.usb.devices[1].runtime_pm.suspended_time_ms==5678)
assert(Export.agent(usb_snapshot).metrics.device_power.runtime_status_counts.active==1)
print("ok: device runtime PM: readonly PCI/USB reports, exact accounting, policy distinction, identity/state fences, age, exports and ten locales")
