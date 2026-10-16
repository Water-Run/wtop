package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Parser = require("wtop.format.windows_storage")
local Health = require("wtop.model.storage_health")
local Export = require("wtop.export")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")

local descriptor = string.pack("<I4I4i2i2I2c10I2i2i2i2BBBBI4",
    40,40,140,125,1,string.rep("\0",10),0,40,125,-32768,0,0,0,0,0)
assert(#descriptor == 40)
local temperature = assert(Parser.temperatures(descriptor))
assert(temperature.channels[1].input == 40 and temperature.channels[1].thresholds.crit == 140)
assert(temperature.channels[1].under_threshold_celsius == nil)
local sensor_only = descriptor:sub(1,24)..string.pack("<I2",1)..descriptor:sub(27)
assert(Parser.temperatures(sensor_only).channels[1].thresholds.crit == nil,
    "a device composite limit must not become an individual sensor's critical threshold")
for i = 0, 39 do assert(Parser.temperatures(descriptor:sub(1,i)) == nil) end
assert(Parser.temperatures(string.pack("<I4I4",40,5000)..descriptor:sub(9)) == nil)
assert(Parser.temperatures(descriptor:sub(1,12)..string.pack("<I2",33)..descriptor:sub(15)) == nil)
local sentinel = descriptor:sub(1,26)..string.pack("<i2",-32768)..descriptor:sub(29)
assert(Parser.temperatures(sentinel).channels[1].input == nil)
local function replace(bytes, offset, value)
    return bytes:sub(1,offset-1)..value..bytes:sub(offset+#value)
end
local page = string.rep("\0",512)
page = replace(page,2,string.pack("<I2",313))
page = replace(page,4,string.char(100,10,255))
page = replace(page,33,string.rep("\255",16))
local nvme = assert(Parser.nvme(page))
assert(math.abs(nvme.temperature_celsius-39.85)<1e-10)
assert(nvme.percentage_used == 255 and nvme.critical_warning == 0)
assert(nvme.data_unit_bytes == 512000 and nvme.data_units_rounded_up and nvme.percentage_used_lower_bound)
assert(nvme.data_units_read == "340282366920938463463374607431768211455")
assert(nvme.data_units_written == "0")
assert(Parser.nvme(page:sub(1,511)) == nil)
assert(Parser.nvme(replace(page,2,"\0\0")).temperature_celsius == nil)
assert(Parser.nvme(replace(page,2,"\255\255")).temperature_celsius == nil)

local ata = string.pack("<I2",1)..string.char(194,0,0,40,40,40,0,0,0,0,0,0)..string.rep("\0",498)
local sum=0;for i=1,511 do sum=sum+ata:byte(i)end
ata=ata:sub(1,511)..string.char((-sum)%256)
local decoded=assert(Parser.ata(ata))
assert(decoded.attributes[1].id==194 and decoded.attributes[1].raw_hex=="000000000028")
assert(decoded.temperature_celsius==nil, "an ATA attribute ID is not a temperature definition")
assert(Parser.ata(replace(ata,512,string.char((ata:byte(512)+1)%256)))==nil)

local disk={id="PhysicalDrive0",name="Disk 0",_health_key="PRIVATE\0SERIAL",identity={model="Drive"}}
local health={id=disk.id,_health_key=disk._health_key,quality="fresh",temperature=temperature,nvme=nvme}
local snapshot={timestamp_ns=1000000000,disks={devices={disk}},disk_health={devices={health}},
    quality={disks={status="ok",quality="fresh"},disk_health={status="ok",quality="fresh",value_timestamp_ns=1000000000}}}
assert(Health.match(snapshot,disk)==health)
local current=assert(Health.temperature(snapshot,disk));assert(current.headroom_celsius==100)
local exported=Export.snapshot(snapshot)
assert(exported.disks.devices[1].temperature.headroom_celsius==100)
assert(exported.disk_health.devices[1].nvme.data_units_read==nvme.data_units_read)
local json=require("wtop.format.json")
local text=assert(json.encode(exported));assert(not text:find("PRIVATE",1,true)and not text:find("SERIAL",1,true))
local view=ViewModel.build({history_values=function()return{}end},snapshot,assert(I18n.new({locale="en-US"})),{},"storage")
assert(view.disk_table.rows[1].temperature=="40 °C"and view.disk_table.rows[1].critical=="140 °C")
health._health_key="OTHER";assert(Health.match(snapshot,disk)==nil);health._health_key=disk._health_key
snapshot.disk_health.devices[2]=health;assert(Health.match(snapshot,disk)==nil);snapshot.disk_health.devices[2]=nil
snapshot.timestamp_ns=17000000000
assert(Health.temperature(snapshot,disk).quality=="stale"and Health.temperature(snapshot,disk).headroom_celsius==nil)
snapshot.timestamp_ns=0;assert(Health.temperature(snapshot,disk).headroom_celsius==nil)
snapshot.timestamp_ns=1000000000;snapshot.quality.disks.quality="stale"
assert(Health.match(snapshot,disk)==health and Health.temperature(snapshot,disk).quality=="fresh",
    "a fresh health response revalidates its own exact identity while the I/O source is stalled")
snapshot.quality.disks.quality="fresh"
local Wire=require("wtop.core.worker_wire")
local closes,opens=0,0
local fake={hardware_worker_sources={disk_health=true}}
function fake.hardware_worker_open(id,config)
    assert(id=="disk_health")
    local options=Wire.decode(config);assert(options.deep==true and options.disk_number==0)
    opens=opens+1;return {}
end
function fake.hardware_worker_query()
    return Wire.encode({capability={state="available",available=true},result={
        status="ok",quality="fresh",timestamp_ns=1000000000,
        data={devices={health}},
    }}),{sample_started_ns=1000000000,sample_finished_ns=1000000000}
end
function fake.hardware_worker_close()closes=closes+1;return true end
local inspector=require("wtop.inspectors.windows_storage").new({native=fake})
local ctx={snapshot=snapshot,now_ns=function()return 1000000000 end}
local entities=inspector:enumerate(ctx);assert(#entities==1 and entities[1].key==disk._health_key)
local inspected=inspector:inspect(ctx,entities[1]);assert(inspected.status=="ok"and #inspected.sections>0 and not inspected.cached)
assert(opens==1 and closes==0)
assert(inspector:inspect(ctx,entities[1]).cached);assert(opens==1)
disk._health_key="REPLACED"
assert(inspector:inspect(ctx,entities[1]).reason=="storage_identity_changed"and closes==1)
disk._health_key=health._health_key
health.temperature,health.nvme,health.query_errors=nil,nil,{ata=5}
health.quality="unavailable"
local denied=inspector:inspect(ctx,entities[1])
assert(denied.status=="denied"and denied.quality=="denied"and #denied.sections==1,
    "query error fields alone must not produce a successful health verdict")
inspector:close()
assert(closes==2)
health.temperature,health.nvme,health.query_errors,health.quality=temperature,nvme,{},"fresh"
local direct=require("wtop.collectors.windows_storage").new({native={collect_disk_health=function()
    return {devices={{id="PhysicalDrive0",raw_health={temperature_data=descriptor,nvme_data=page,
        temperature_error=0,nvme_error=0,ata_error=0}}}}
end},_hardware_direct=true})
assert(direct:sample({safe_mode=true,now_ns=ctx.now_ns}).reason=="safe_mode")
local result=direct:sample(ctx)
assert(result.status=="ok"and result.data.devices[1].nvme.data_units_read==nvme.data_units_read)
-- A successful temperature-property query can contain no usable samples.
local function temperature_result(bytes)
 local reader=require("wtop.collectors.windows_storage").new({_hardware_direct=true,native={
  collect_disk_health=function()return {devices={{raw_health={temperature_data=bytes,nvme_data=page,
   temperature_error=0,nvme_error=0,ata_error=0}}}}end}})
 return reader:sample(ctx).data.devices[1]
end
local sentinel_fallback=temperature_result(sentinel)
assert(math.abs(sentinel_fallback.temperature.channels[1].input-39.85)<1e-10)
assert(sentinel_fallback.temperature.channels[1].source=="NVMe SMART/Health Information Log")
assert(sentinel_fallback.temperature.channels[1].thresholds.crit==nil)
assert(sentinel_fallback.temperature.critical_celsius==140,
 "descriptor metadata must survive without being reassigned to another source")
local empty=replace(descriptor,13,string.pack("<I2",0))
local empty_fallback=temperature_result(empty)
assert(#empty_fallback.temperature.channels==1 and empty_fallback.temperature.channels[1].input~=nil)
assert(temperature_result(descriptor).temperature.channels[1].input==40,
 "a valid property measurement retains precedence over the fallback")
return true
