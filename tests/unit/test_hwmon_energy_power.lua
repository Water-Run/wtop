package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path
local Fixture = require("support.fixture_fs")
local Hwmon = require("wtop.collectors.hwmon")
local Model = require("wtop.model.sensor_power")
local Export = require("wtop.export")
local View = require("wtop.view_model")
local TUI = require("wtop.tui")
local Report = require("wtop.report")
local I18n = require("wtop.i18n")
local JSON = require("wtop.format.json")
local base = "/hwmon/hwmon0"
local files = { [base.."/name"]="xe\n",[base.."/energy1_input"]="100000000\n",
    [base.."/energy1_label"]="Card\n",
    [base.."/energy2_input"]="200000000\n",[base.."/energy1_enable"]="1\n",[base.."/power1_max"]="50000000\n",
    [base.."/power1_cap"]="80000000\n",[base.."/power2_max"]="30000000\n",
    [base.."/power1_max_interval"]="28000\n",[base.."/power1_cap_interval"]="2\n" }
local links = { [base]="../../devices/gpu0/hwmon/hwmon0",[base.."/device"]="../../gpu0",
    [base.."/device/driver"]="../../bus/pci/drivers/xe" }
local now, delay, fs, previous, collector = 1000000000, 0
local function setup()
    fs = Fixture.new({files=files,links=links})
    local original=fs.read
    function fs:read(path,limit)
        local content,err=original(self,path,limit)
        if path:match("/energy%d+_input$")then now=now+delay end
        return content,err
    end
    collector=Hwmon.new({fs=fs,base_path="/hwmon"});previous=nil
end
local function sample()
    previous=collector:sample({fs=fs,now_ns=function()return now end},previous)
    return previous.data.devices[1].by_id["energy:1"].power
end
setup()
local first=sample();assert(first.power_watts==nil and first.power_quality=="gap")
assert(first.scope=="card" and #first.limits==2)
now=2000000000;files[base.."/energy1_input"]="110000000\n"
local second=sample();assert(second.power_watts==10 and second.power_interval_ns==1000000000)
assert(second.power_quality=="measured" and second.power_session.samples==1)
local old=JSON.encode(previous.data)
now=4000000000;files[base.."/energy1_input"]="150000000\n"
local prior=previous;local third=sample()
assert(JSON.encode(prior.data)==old,"new power mutated an earlier snapshot")
assert(third.power_watts==20 and third.power_interval_ns==2000000000)
assert(math.abs(third.power_session.average_watts-50/3)<1e-10)
assert(third.power_session.covered_time_ns==3000000000 and third.power_session.energy_joules==50)
assert(third.power_session.minimum_watts==10 and third.power_session.maximum_watts==20)
local power=Model.public(previous.data.devices[1].by_id["energy:1"],now)
assert(power and power.limits[1].percent==40 and power.limits[2].percent==25)
assert(power.limits[1].headroom_watts==30 and power.limits[2].headroom_watts==60)
assert(power.limits[1].window_ns==28000000000 and power.limits[2].window_ns==2000000)
local state={timestamp_ns=now,sensors=previous.data,gpus={devices={{id="card0",card="card0",driver="xe",metrics={},
    hwmon_refs={{class="hwmon0"}}}}}}
local en=assert(I18n.new({locale="en-US"}));local engine={history_values=function()return{}end}
local row=View.build(engine,state,en,{},"gpu").gpu_table.rows[1]
assert(row.power=="20.0 W" and row.power_percent==40 and row.power_scope=="Card")
local function energy_one(document)for _,c in ipairs(document.sensors.devices[1].channels)do if c.id=="energy:1"then return c end end end
local full=Export.snapshot(state);local channel=energy_one(full)
assert(channel.energy_microjoules==150000000 and channel.power.power_interval_ns==2000000000)
assert(channel.power.limits[2].percent==25 and channel.power.power_session.average_kind=="time_weighted")
local agent=Export.agent(state).metrics.sensors
assert(agent.energy_power_total==2 and agent.energy_power[1].power_watts==20)
assert(agent.energy_power[2].scope=="package" and #agent.energy_power[2].limits==1)
local report=Report.render(full)
assert(report:find("Energy-derived sensor power",1,true)and report:find("2.000 s",1,true))
for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"})do
    local i=assert(I18n.new({locale=locale}));local text=table.concat(TUI.power_detail_lines(state,i),"\n")
    assert(text:find(i:t("power.measurement.energy_delta"),1,true))
    assert(text:find("PL1",1,true)and text:find("PL2",1,true))
    local sensors=table.concat(TUI.sensor_detail_lines(state,i,now),"\n")
    assert(sensors:find(i:t("power.session_weighted"),1,true))
    assert(sensors:find(i:t("power.scope.package"),1,true)and sensors:find("PL1",1,true))
end
state.quality={sensors={status="error",quality="stale"}}
full=Export.snapshot(state);assert(energy_one(full).power.power_watts==nil)
assert(energy_one(full).power.limits[1].percent==nil)
assert(View.build(engine,state,en,{},"gpu").gpu_table.rows[1].power_percent==nil)
state.quality=nil

-- Exact clocks and counters must retain tiny differences at long uptimes.
setup();now=9007199254741000;files[base.."/energy1_input"]="8999999999999990\n";sample()
now=now+1;files[base.."/energy1_input"]="8999999999999991\n";power=sample()
assert(power.power_watts==1000 and power.power_interval_ns==1)
now=now+1;files[base.."/energy1_input"]="8999999999999991\n";assert(sample().power_watts==0)
now=now+1;files[base.."/energy1_input"]="10\n";assert(sample().power_quality=="reset")
now=now+1000000000;files[base.."/energy1_input"]="10000010\n";assert(sample().power_session.samples==1)

-- Invalid or absent reads break the energy window; recovery warms up.
files[base.."/energy1_enable"]="0\n";now=now+1000000000
power=sample();assert(power.power_watts==nil and power.power_quality=="unavailable")
files[base.."/energy1_enable"]="1\n";now=now+1000000000;assert(sample().power_watts==nil)
now=now+1000000000;files[base.."/energy1_input"]="20000010\n";assert(sample().power_watts==10)
files[base.."/energy1_input"]="-1\n";now=now+1000000000;assert(sample().power_watts==nil)
files[base.."/energy1_input"]="30000010\n";now=now+1000000000;assert(sample().power_watts==nil)
now=now+16000000000;files[base.."/energy1_input"]="40000010\n";assert(sample().power_watts==nil)
now=now+1000000000;files[base.."/energy1_input"]="50000010\n";assert(sample().power_watts==10)
local prior_state=previous
fs=Fixture.new({files=files,links=links});now=now+1000000000
assert(sample().power_watts==nil,"changing the filesystem reused energy history")
links[base]="../../devices/replacement/hwmon/hwmon0";fs=Fixture.new({files=files,links=links});now=now+1000000000
assert(sample().power_watts==nil)

-- Generic numbering cannot match a rail to a cap, and slow reads keep their
-- own capture windows rather than borrowing completion time from the batch.
links[base.."/device/driver"]="../../bus/pci/drivers/example";setup();now=1000000000;delay=500000000;sample()
now=2000000000;files[base.."/energy1_input"]="60000010\n";power=sample()
assert(power.power_watts==nil and power.scope==nil and #power.limits==0)
delay=0;now=4000000000;files[base.."/energy1_input"]="70000010\n";sample()
now=5000000000;files[base.."/energy1_input"]="80000010\n";power=sample();assert(power.power_watts==10 and #power.limits==0)

-- A denied/ENODATA counter breaks the next window, even if another channel
-- remains readable. A changed source during the batch cannot seed a delta.
local original=fs.read;local failure
function fs:read(path,limit)
    if path==base.."/energy1_input" and failure then return nil,{kind=failure,message=failure} end
    return original(self,path,limit)
end
failure="denied";now=6000000000;power=sample();assert(power.power_quality=="denied" and power.power_watts==nil)
failure=nil;now=7000000000;files[base.."/energy1_input"]="90000010\n";assert(sample().power_watts==nil)
now=8000000000;files[base.."/energy1_input"]="100000010\n";assert(sample().power_watts==10)
failure="unavailable";now=9000000000;assert(sample().power_watts==nil)
failure=nil;now=10000000000;assert(sample().power_watts==nil)
local original_link=fs.readlink;local link_reads=0
function fs:readlink(path)
    if path==base then link_reads=link_reads+1;if link_reads%2==0 then return "../../devices/other/hwmon/hwmon0"end end
    return original_link(self,path)
end
now=11000000000;sample();now=12000000000;files[base.."/energy1_input"]="110000010\n"
assert(sample().power_watts==nil,"a changing class link created a cross-device energy delta")

-- A zero wall is disabled, not zero watts. Changing a label or sampling time
-- breaks continuity; repeated and backward captures do not add statistics.
links[base.."/device/driver"]="../../bus/pci/drivers/xe";files[base.."/power1_max"]="0\n"
setup();now=1000000000;files[base.."/energy1_input"]="100000000\n";sample()
now=2000000000;files[base.."/energy1_input"]="110000000\n";power=sample()
assert(power.limits[1].enabled==false and power.limits[1].power_limit_watts==0)
local public=Model.public(previous.data.devices[1].by_id["energy:1"],now)
assert(public.limits[1].percent==nil and public.limits[2].percent==12.5)
assert(sample().power_watts==nil and sample().power_session.samples==1)
now=1500000000;assert(sample().power_watts==nil)
now=3000000000;files[base.."/energy1_input"]="120000000\n";power=sample()
files[base.."/energy1_label"]="Other domain\n";now=4000000000
power=sample();assert(power.power_watts==nil and power.power_session==nil)
now=5000000000;files[base.."/energy1_input"]="130000000\n";assert(sample().power_session.samples==1)
local data=previous.data;local copies={data.devices[1],data.devices[1]}
Model.attach(copies,data,now,false)
assert(copies[1].by_id["energy:1"].power.power_watts==nil,"duplicate device identity was accepted")
print("ok: hwmon energy watts, exact deltas/times, weighted windows, Xe typed caps, unknown rails, reset/gaps/identity and shared UI/exports")

do
    local function fixture(name, driver, values)
        local f={ [base.."/name"]=name.."\n" }
        for key,value in pairs(values)do f[base.."/"..key]=value end
        local source=Fixture.new({files=f,links={ [base]="../../devices/gpu0/hwmon/hwmon0",
            [base.."/device"]="../../gpu0",[base.."/device/driver"]="../../bus/pci/drivers/"..driver }})
        local c=Hwmon.new({fs=source,base_path="/hwmon"});local prior;local timestamp=1000000000
        return function()
            prior=c:sample({fs=source,now_ns=function()return timestamp end},prior);timestamp=timestamp+1000000000
            return prior.data,prior.timestamp_ns
        end,f,source
    end
    local sample_card,values=fixture("i915","i915",{energy1_input="100000000\n",power1_max="50000000\n",
        power1_cap="99000000\n",power1_crit="200000000\n",power1_max_interval="28000\n"})
    sample_card();values[base.."/energy1_input"]="125000000\n"
    local data,timestamp=sample_card();local card=data.devices[1].by_id["energy:1"].power
    assert(card.scope=="card"and card.power_watts==25 and #card.limits==1)
    assert(card.limits[1].id=="long_term"and card.limits[1].power_limit_watts==50,
        "i915 I1 and unknown cap attributes became PL2")
    local ip=fixture("i915","i915",{power1_input="20000000\n",power1_max="50000000\n",power1_crit="100000000\n"})
    local idata,itime=ip();local instant=idata.devices[1].by_id["power:1"].power
    assert(instant.power_watts==20 and instant.scope=="card"and #instant.limits==1)
    assert(Model.public(idata.devices[1].by_id["power:1"],itime).limits[1].percent==40)
    local sample_gt,gtvalues=fixture("i915_gt3","i915",{energy1_input="100000000\n",power1_max="50000000\n"})
    sample_gt();gtvalues[base.."/energy1_input"]="110000000\n"
    local gt=sample_gt().devices[1].by_id["energy:1"].power
    assert(gt.scope=="gpu_gt"and gt.power_watts==10 and #gt.limits==0)
    local unknown=fixture("i915_alias","i915",{energy1_input="100000000\n",power1_max="50000000\n"})
    assert(unknown().devices[1].by_id["energy:1"].power.scope==nil)

    local sample_point,pointvalues,pointfs=fixture("xe","xe",{power1_input="30000000\n",power1_average="40000000\n",
        power1_average_interval="500\n",power1_max="60000000\n",power1_cap="120000000\n",power1_enable="1\n"})
    local data,at=sample_point();local point=data.devices[1].by_id["power:1"].power
    assert(point.power_watts==30 and point.measurement=="current"and point.source:match("/power1_input$"))
    assert(point.power_session.average_kind=="samples"and point.power_session.energy_joules==nil)
    local sample_channel=data.devices[1].by_id["power:1"]
    sample_channel.errors.input={status="denied",reason="denied"}
    Model.attach(data.devices,nil,at,false)
    assert(sample_channel.power.measurement=="average"and sample_channel.power.power_watts==40)
    sample_channel.errors.input=nil
    Model.attach(data.devices,nil,at,false)
    local original=pointfs.read;local deny_input=false
    function pointfs:read(path,maximum)
        if deny_input and path==base.."/power1_input"then return nil,{kind="denied",message="denied"}end
        return original(self,path,maximum)
    end
    pointvalues[base.."/power1_input"]="50000000\n";data,at=sample_point();point=data.devices[1].by_id["power:1"].power
    assert(point.power_session.samples==2 and point.power_session.average_watts==40)
    local old_data=data;local unchanged=JSON.encode(data)
    deny_input=true;data,at=sample_point();point=data.devices[1].by_id["power:1"].power
    assert(point.measurement=="average"and point.power_watts==40 and point.power_interval_ns==500000000)
    assert(point.source:match("/power1_average$")and point.power_session.samples==1)
    assert(point.power_session.average_kind=="samples"and point.power_session.covered_time_ns==nil)
    assert(JSON.encode(old_data)==unchanged,"switching direct/average source mutated an older snapshot")
    local snap={timestamp_ns=at,sensors=data,gpus={devices={{id="card0",card="card0",metrics={},hwmon_refs={{class="hwmon0"}}}}}}
    local row=View.build(engine,snap,en,{},"gpu").gpu_table.rows[1]
    assert(row.power=="40.0 W"and math.abs(row.power_percent-200/3)<1e-9)
    local exported=Export.snapshot(snap);local agent=Export.agent(snap).metrics.sensors
    assert(agent.hwmon_power_total==1 and agent.hwmon_power[1].measurement=="average")
    assert(agent.hwmon_power[1].power_session.energy_joules==nil and agent.energy_power_total==0)
    local report=Report.render(exported)
    assert(report:find("Direct hwmon power",1,true)and report:find("0.500 s",1,true))
    assert(not report:find("Session averages are time-weighted",1,true))
    for _,locale in ipairs({"en-US","zh-CN","zh-TW","ja-JP","ko-KR","fr-FR","de-DE","es-ES","pt-BR","ru-RU"})do
        local i=assert(I18n.new({locale=locale}));local text=table.concat(TUI.power_detail_lines(snap,i),"\n")
        assert(text:find(i:t("power.session_sampled"),1,true)and text:find("PL1",1,true)and text:find("PL2",1,true))
        assert(not text:find(i:t("power.session_weighted"),1,true))
        assert(not text:find(i:t("power.session_energy"),1,true))
    end
    pointvalues[base.."/power1_enable"]="0\n";data=sample_point();point=data.devices[1].by_id["power:1"].power
    assert(point.power_watts==nil)
    snap.timestamp_ns=at+1000000000;snap.sensors=data
    row=View.build(engine,snap,en,{},"gpu").gpu_table.rows[1]
    assert(row.power_percent==nil and row.power_limit~="—","a cap-only device lost its known wall")
    snap.quality={sensors={status="error",quality="stale"}}
    local stale=Export.agent(snap).metrics.sensors.hwmon_power[1]
    assert(stale.power_watts==nil and stale.limits[1].percent==nil)
    local fault=fixture("xe","xe",{power1_input="30000000\n",power1_max="60000000\n",power1_fault="1\n"})
    local bad=fault().devices[1].by_id["power:1"].power
    assert(bad.power_watts==nil and bad.power_quality=="error")
    print("ok: i915 card/GT scopes and Intel direct/average/cap-only channels, source refresh and sample-count statistics")
end
