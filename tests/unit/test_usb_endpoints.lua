package.path = "./src/?.lua;./src/?/init.lua;./tools/?.lua;" .. package.path
local Usb = require("wtop.format.usb_endpoints")
local FS = require("wtop.linux.fs")
local Inventory = require("wtop.collectors.inventory")
local Export = require("wtop.export")
local Json = require("wtop.format.json")
local Decoder = require("wtop.core.json")
local Report = require("wtop.report")
local Hardware = require("wtop.model.hardware")
local TUI = require("wtop.tui")
local ViewModel = require("wtop.view_model")
local I18n = require("wtop.i18n")
local Validator = require("agent_schema")
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function ep(address, attributes, interval)
  return { name = string.format("ep_%02x", address), bLength = "07\n",
    bEndpointAddress = string.format("%02x\n", address), bmAttributes = string.format("%02x", attributes),
    wMaxPacketSize = "1040\n", bInterval = "01\n", interval = interval or "125us\n", errors = {} }
end
local function raw_snapshot(number, endpoints, declared)
  return { guarded = true, fields = { bInterfaceNumber = string.format("%02x", number or 0),
    bAlternateSetting = "00", bNumEndpoints = string.format("%02x", declared or #endpoints),
    bInterfaceClass = "03", bInterfaceSubClass = "01", bInterfaceProtocol = "02", errors = {} },
    total = #endpoints, total_known = true, truncated = false, endpoints = endpoints,
    source_target = "../../../devices/pci0000:00/usb1/1-1/1-1:1." .. tostring(number or 0),
    driver_target = "../../../../bus/usb/drivers/usbhid", interface = "Cached function" }
end
local path = "/sys/bus/usb/devices/1-1:1.0"
local raw = raw_snapshot(0, { ep(1, 0, "0ms"), ep(2, 2, "0ms"), ep(0x81, 3) })
local good = Usb.decode(raw, path, 30)
assert(good.status == "ok" and good.quality == "fresh" and #good.list == 3)
assert(good.list[1].direction == "both" and good.list[1].transfer_type == "control")
assert(good.list[2].direction == "out" and good.list[2].interval_microseconds == 0)
assert(good.list[3].direction == "in" and good.list[3].interval_microseconds == 125)
assert(good.list[3].max_packet_sysfs_value == 0x1040 and good.list[3].max_packet_bytes == 64)
assert(good.list[3].additional_transactions_known == false and good.list[3].bytes_per_second == nil)
assert(Usb.hex("0xFF\n",255) == 255 and Usb.hex("100",255) == nil)
for _, input in ipairs({ "0xGG", "12\0", "1.5", "fffffffff", "-1", string.rep("0",33) }) do
  assert(Usb.hex(input,65535) == nil)
end
for _, field in ipairs({"bLength","bEndpointAddress","bmAttributes","wMaxPacketSize","bInterval","interval"}) do
  local changed = copy(raw); changed.endpoints[3][field] = nil; changed.endpoints[3].errors[field] = 13
  local detail = Usb.decode(changed,path,30)
  assert(detail.quality == "partial" and detail.list[3].issues[1].status == "denied")
end
do
  local changed = copy(raw); changed.endpoints[3].bEndpointAddress = "82"
  local row = Usb.decode(changed,path,30).list[3]
  assert(row.address == nil and row.number == nil and row.direction == nil and row.quality == "partial")
  changed = copy(raw); changed.endpoints[3].bLength = "06"
  assert(Usb.decode(changed,path,30).list[3].descriptor_length == nil)
  for _, interval in ipairs({"-1ms","1ns","1.5ms","1 ms","99999999999ms","1ms\0"}) do
    changed = copy(raw); changed.endpoints[3].interval = interval
    assert(Usb.decode(changed,path,30).list[3].interval_microseconds == nil)
  end
  changed = copy(raw); changed.endpoints[3].interval = "256ms\n"
  assert(Usb.decode(changed,path,30).list[3].interval_microseconds == 256000)
  changed = copy(raw); changed.endpoints[3].name = "ep_00"
  assert(Usb.decode(changed,path,30).quality == "partial")
  changed = copy(raw); changed.endpoints[3] = copy(changed.endpoints[2])
  assert(#Usb.decode(changed,path,30).list == 2)
  changed = copy(raw); changed.fields.bNumEndpoints = "04"
  assert(Usb.decode(changed,path,30).quality == "partial")
end
local limited = Usb.decode(raw,path,2)
assert(limited.quality == "truncated" and limited.truncated and #limited.list == 2 and limited.total == 3)
do
  local incomplete=copy(raw);incomplete.total_known=false;incomplete.truncated=true
  local detail=Usb.decode(incomplete,path,30)
  assert(detail.total==nil and detail.observed_count==3 and not detail.total_known)
  assert(Usb.public(detail,false).total==nil)
end
local empty = Usb.decode(raw_snapshot(0,{}),path,30)
assert(empty.quality == "fresh" and empty.total == 0 and #empty.list == 0)
for kind, status in pairs({ changed="gap", denied="denied", missing="unavailable", unavailable="unavailable", io_error="error" }) do
  local detail = Usb.unavailable({kind=kind},path)
  assert(detail.status == status and detail.list == nil and detail.total == nil)
  assert(Usb.public(detail,false).observation_current == false)
end
assert(Usb.decode({guarded=false},path,30).list == nil)
do
  local private = copy(good)
  private.serial = "DO_NOT_EXPORT_USB_PRIVATE"
  private.list[1].raw_descriptor = private.serial
  private.list[1].issues[1] = { field="vendor_payload",status="error",raw=private.serial }
  local public = Usb.public(private,false,30)
  assert(not Json.encode(public):find(private.serial,1,true))
  assert(public.observation_current and public.list[2].interval_microseconds == 0)
  local stale = Usb.public(private,true,30)
  assert(stale.quality == "stale" and stale.list[1].quality == "stale" and not stale.observation_current)
  assert(Usb.public(private,false,1).truncated)
end

-- A provided fake reader cannot accidentally call the host's new native API.
do
  local native = require("wtop.native"); local original = native.read_usb_interface
  native.read_usb_interface = function() error("host USB snapshot reached by fake FS") end
  local ok, failure = pcall(function()
    local fs = FS.new({read_file=function()return nil end,list_dir=function()return{}end})
    local value, err = fs:usb_interface(path,30)
    assert(value == nil and err.kind == "unavailable")
  end)
  native.read_usb_interface = original; assert(ok,failure)
  local available=native.available
  native.available=true
  native.read_usb_interface=function()return nil,"changed source",151,"changed"end
  ok,failure=pcall(function()
    local value,err=FS.new():usb_interface(path,30)
    assert(value==nil and err.kind=="changed" and err.errno==151)
  end)
  native.read_usb_interface=original;native.available=available;assert(ok,failure)
  assert(not pcall(FS.new,{usb_interface=true}))
  local seen
  local fs = FS.new({root="/fixture",usb_interface=function(actual,limit)
    seen={actual,limit};return raw
  end})
  assert(fs:usb_interface(path,30)==raw and seen[1]=="/fixture"..path and seen[2]==30)
  assert(select(2,fs:usb_interface(path,31)).kind=="invalid")
end

local function collector(interface_count, endpoint_count, first_failure)
  local entries, admitted = {"1-1"}, 0
  for number=0,interface_count-1 do entries[#entries+1]="1-1:1."..number end
  local records={}
  for direction=0,1 do for number=1,15 do records[#records+1]=ep(number+direction*128,2,"0ms") end end
  local fs=FS.new({
    read_file=function(filename)
      local leaf=filename:match("([^/]+)$")
      if filename:find("/1-1/",1,true) then
        local values={idVendor="1234",idProduct="5678",busnum="1",devnum="3",product="Fixture"}
        if values[leaf]then return values[leaf] end
      end
      local number=tonumber(filename:match("1%-1:1%.(%d+)/"))
      if number then
        local value=raw_snapshot(number,{},endpoint_count).fields[leaf]
        if value then return value end
      end
      return nil,{kind="missing"}
    end,
    list_dir=function(directory)
      if directory=="/sys/bus/usb/devices"then return entries end
      return{},nil,false
    end,
    read_link=function()return nil,{kind="missing"}end,
    usb_interface=function(filename,limit)
      local number=tonumber(filename:match("%.(%d+)$"))
      if first_failure and number==0 then admitted=admitted+limit;return nil,{kind="changed"} end
      local rows={};for index=1,math.min(endpoint_count,limit)do rows[index]=copy(records[index])end
      admitted=admitted+#rows
      local snapshot=raw_snapshot(number,rows,endpoint_count)
      snapshot.total=endpoint_count;snapshot.truncated=endpoint_count>#rows
      return snapshot
    end,
  })
  local result=Inventory.new({fs=fs,pci_names={lookup=function()return{}end}}):sample({})
  return result,admitted
end
local inventory,admitted=collector(11,30)
assert(inventory.status=="ok" and inventory.quality=="truncated" and admitted==256)
assert(inventory.data.usb.endpoints_truncated and #inventory.data.usb.interfaces==11)
local total=0;for _,interface in ipairs(inventory.data.usb.interfaces)do total=total+#interface.endpoint_details.list end
assert(total==256)
local failed,attempted=collector(11,30,true)
assert(attempted==256 and failed.data.usb.interfaces[1].endpoint_details.status=="gap")
local sample=collector(1,3)
do
  local partial=copy(raw)
  partial.fields.bInterfaceNumber=nil;partial.fields.errors.bInterfaceNumber=13
  local fs=FS.new({read_file=function()return nil,{kind="missing"}end,
    list_dir=function(directory)return directory=="/sys/bus/usb/devices"and{"1-1:1.0"}or{}end,
    read_link=function()return nil end,usb_interface=function()return partial end})
  local result=Inventory.new({fs=fs,pci_names={lookup=function()return{}end}}):sample({})
  local interface=assert(result.data.usb.interfaces[1])
  assert(interface.interface_number==nil and interface.endpoint_details.quality=="partial")
  assert(interface.endpoint_details.issues[1].status=="denied")
end
local state={sequence=1,timestamp_ns=1000000000,inventory=sample.data,quality={},cpu={},memory={},pressure={},disks={},processes={},
  cpu_frequency={},mounts={},workloads={},connections={},network={},gpus={},sensors={}}
-- A healthy peer bus does not turn an unavailable namespace into zero devices.
do
  local function namespace(bus,kind,mode)
    local fs=FS.new({
      list_dir=function(directory)
        local selected=directory=="/sys/bus/"..bus.."/devices"
        if selected and kind then return nil,{kind=kind} end
        if selected and mode=="empty"then return{}end
        if directory=="/sys/bus/pci/devices"then return{"0000:00:02.0"},nil,selected and mode=="truncated"end
        if directory=="/sys/bus/usb/devices"then return{"1-1"},nil,selected and mode=="truncated"end
        return{}end,
      read_file=function(filename)
        local leaf=filename:match("([^/]+)$")
        local pci=filename:find("/0000:00:02.0/",1,true)
        local usb=filename:find("/1-1/",1,true)
        local values=pci and{vendor="8086",device="1234",class="030000",revision="01"}
          or usb and{idVendor="1234",idProduct="5678",busnum="1",devnum="3"}or{}
        return values[leaf],{kind="missing"}
      end,
      read_link=function()return nil,{kind="missing"}end,
    })
    local result=Inventory.new({fs=fs,pci_names={names=function()return nil,nil end}}):sample({})
    local snapshot=copy(state);snapshot.inventory=result.data
    return result,snapshot
  end
  for _,bus in ipairs({"pci","usb"})do
    for kind,status in pairs({denied="denied",missing="unavailable",io_error="error"})do
      local result,snapshot=namespace(bus,kind)
      local source=result.data[bus]
      assert(result.status=="ok"and source.status==status and source.total==nil and not source.total_known)
      assert(source.devices_seen==nil and not source.enumeration_complete)
      local public=Export.snapshot(snapshot).inventory[bus]
      assert(public.status==status and public.quality==status and public.total==nil and not public.total_known)
      assert(Hardware.build(snapshot).partial)
      local text=ViewModel.build({history_values=function()return{}end},snapshot,
        assert(I18n.new("en-US")),{},"system").system_devices.status_text
      local labels={denied="Denied",unavailable="Unavailable",error="Error"}
      assert(text:find(bus:upper().." "..labels[status],1,true)and not text:find(bus:upper().." 0",1,true))
      assert(Report.render(Export.snapshot(snapshot)):find((bus=="usb"and"USB interface"or"PCI device").." source: "..status,1,true))
      if bus=="usb"then
        local metric=Export.agent(snapshot).metrics.usb
        assert(metric.status==status and metric.quality==status and metric.interfaces_total==nil
          and not metric.interface_total_known and metric.enumeration_complete==false)
      end
    end
    local result,snapshot=namespace(bus,nil,"empty")
    assert(result.data[bus].total==0 and result.data[bus].total_known and result.data[bus].enumeration_complete)
    assert(Export.snapshot(snapshot).inventory[bus].total==0)
    local text=ViewModel.build({history_values=function()return{}end},snapshot,
      assert(I18n.new("en-US")),{},"system").system_devices.status_text
    assert(text:find(bus:upper().." 0",1,true))
    if bus=="usb"then assert(Export.agent(snapshot).metrics.usb.interfaces_total==0)end
    result,snapshot=namespace(bus,nil,"truncated")
    assert(result.data[bus].status=="partial"and result.data[bus].total==nil and not result.data[bus].total_known)
    assert(result.data[bus].devices_seen==1 and not result.data[bus].enumeration_complete)
    if bus=="usb"then
      local metric=Export.agent(snapshot).metrics.usb
      assert(metric.interfaces_total==nil and metric.interfaces_seen==0 and metric.quality=="partial"
        and metric.interfaces_truncated)
    end
  end
  local private=copy(state);private.inventory.usb.enumeration_complete={raw="DO_NOT_EXPORT_USB_PRIVATE"}
  private.inventory.usb.devices_seen={raw="DO_NOT_EXPORT_USB_PRIVATE"}
  private.inventory.usb.interfaces_seen={raw="DO_NOT_EXPORT_USB_PRIVATE"}
  private.inventory.usb.source={raw="DO_NOT_EXPORT_USB_PRIVATE"}
  assert(not Json.encode(Export.snapshot(private)):find("DO_NOT_EXPORT_USB_PRIVATE",1,true))
end
local graph=Hardware.build(state)
assert(graph.by_id["usb-interface:1-1:1.0"].parent_id=="usb:1-1")
state.inventory.usb.interfaces[1].endpoint_details.raw="DO_NOT_EXPORT_USB_PRIVATE"
local snapshot=Export.snapshot(state)
assert(#snapshot.inventory.usb.interfaces[1].endpoint_details.list==3)
assert(not Json.encode(snapshot):find("DO_NOT_EXPORT_USB_PRIVATE",1,true))
local agent=Export.agent(state)
assert(#agent.top.usb_interfaces==1 and #agent.top.usb_interfaces[1].endpoint_details.list==3)
assert(agent.metrics.usb.interfaces_total==1 and not agent.metrics.usb.interfaces_truncated)
local schema_file=assert(io.open("docs/agent-v1.schema.json","rb"))
local schema=assert(Decoder.decode(schema_file:read("*a")));schema_file:close()
local errors=assert(Validator.validate(agent,schema));assert(#errors==0,table.concat(errors,"\n"))
local report=Report.render(snapshot)
assert(report:find("USB endpoint observations",1,true) and report:find("USB endpoints",1,true)
  and report:find("ep_01",1,true) and report:find("Interval (us)",1,true))
for _,locale in ipairs({"en-US","zh-CN","zh-TW","fr-FR","ru-RU","de-DE","es-ES","pt-BR","ja-JP","ko-KR"})do
  local i18n=assert(I18n.new(locale))
  for _,key in ipairs({"usb_endpoint","usb_transfer_type","usb_direction","usb_max_packet","usb_interval_code","usb_interval_us","usb_endpoint_note"})do
    assert(i18n:has("inventory."..key),locale..":"..key)
  end
  local lines=table.concat(TUI.hardware_detail_lines(state,"usb-interface:1-1:1.0",i18n),"\n")
  assert(lines:find("0x01",1,true) and lines:find("64",1,true) and not lines:find("DO_NOT_EXPORT_USB_PRIVATE",1,true))
end
state.quality.inventory={status="error",quality="stale"}
local stale=Export.snapshot(state).inventory.usb.interfaces[1].endpoint_details
assert(stale.quality=="stale" and not stale.observation_current and stale.list[1].quality=="stale")
assert(Export.agent(state).metrics.usb.quality=="stale")
state.inventory=inventory.data;state.quality={}
agent=Export.agent(state)
assert(#agent.top.usb_interfaces==5 and agent.metrics.usb.interfaces_total==11
  and agent.metrics.usb.interfaces_truncated and agent.metrics.usb.endpoints_truncated)
agent.top.usb_interfaces[6]=copy(agent.top.usb_interfaces[1])
assert(#assert(Validator.validate(agent,schema))>0)
agent.top.usb_interfaces[6]=nil
agent.top.usb_interfaces[1].endpoint_details.list[31]=copy(agent.top.usb_interfaces[1].endpoint_details.list[1])
assert(#assert(Validator.validate(agent,schema))>0)
print("ok: USB cached endpoint decode, unknown/zero/stale/privacy, bounded attempts, all exports, schema and10locale details")
return true
